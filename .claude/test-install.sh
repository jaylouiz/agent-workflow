#!/usr/bin/env bash
# Tests for install.sh in a throwaway CLAUDE_CONFIG_DIR: links, recorded choices, dev mode, global rules, uninstall.
# Run: bash .claude/test-install.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
unset WF_GLOBAL_SETTINGS AW_INSTALL_INTERACTIVE
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }

# PATH: real tools the script needs, stub gh/claude/orca; a second dir adds jq so a test can drop it.
mkdir -p "$T/bin" "$T/jq"
for t in bash git python3 readlink ln mkdir rm cp mv mktemp cat grep sed date dirname basename head tail tr wc cut sort awk printf env chmod touch ls; do
  p=$(command -v "$t" 2>/dev/null) && case "$p" in /*) ln -s "$p" "$T/bin/$t" ;; esac
done
for t in gh claude orca; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$t"; chmod +x "$T/bin/$t"; done
ln -s "$(command -v jq)" "$T/jq/jq"
P="$T/bin:$T/jq"

new() { C="$T/c$((n))"; mkdir -p "$C"; } # fresh config dir per scenario
run() { CLAUDE_CONFIG_DIR=$C PATH=$P bash "$ROOT/install.sh" "$@" </dev/null >"$T/out" 2>&1; }
setting() { sed -n "s/^$1=//p" "$C/agent-workflow-settings.sh" | tail -1; }
hooks() { jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("orca-update-review/check.sh"))] | length' "$C/settings.json"; }
imp() { echo "@$C/agent-workflow/global/CLAUDE.md"; }

# fresh --yes: every skill but the maintainer's orca-update-review, balanced models, nothing global
new; echo '{}' >"$C/settings.json"; run --yes; rc=$?
eq "fresh: exit 0" "$rc" 0
check "fresh: build skill linked" '[ "$(readlink "$C/skills/build-gh-issue")" = "$ROOT/skills/build-gh-issue" ]'
check "fresh: no orca-update-review link" '[ ! -e "$C/skills/orca-update-review" ]'
check "fresh: checkout linked" '[ "$(readlink "$C/agent-workflow")" = "$ROOT" ]'
eq "fresh: default model" "$(setting WF_MODEL_DEFAULT)" sonnet
eq "fresh: strong model" "$(setting WF_MODEL_STRONG)" opus
eq "fresh: fast model" "$(setting WF_MODEL_FAST)" haiku
eq "fresh: heavy model" "$(setting WF_MODEL_HEAVY)" claude-fable-5-2
eq "fresh: dev off" "$(setting WF_INSTALL_DEV)" 0
eq "fresh: rules off" "$(setting WF_INSTALL_GLOBAL_RULES)" off
check "fresh: no CLAUDE.md" '[ ! -e "$C/CLAUDE.md" ]'
eq "fresh: no hook" "$(hooks)" 0
check "fresh: says what is next" 'grep -q "/init-issue-workflow" "$T/out"'
run --yes
eq "fresh: rerun keeps one WF_MODEL_DEFAULT line" "$(grep -c '^WF_MODEL_DEFAULT=' "$C/agent-workflow-settings.sh")" 1

# dev mode: the skill link only, never a SessionStart hook; --no-dev takes the link away
new; echo '{}' >"$C/settings.json"; run --yes --dev
check "dev: orca-update-review linked" '[ -L "$C/skills/orca-update-review" ]'
eq "dev: no hook" "$(hooks)" 0
eq "dev: recorded" "$(setting WF_INSTALL_DEV)" 1
run; check "dev: unattended rerun keeps the link" '[ -L "$C/skills/orca-update-review" ]'
eq "dev: rerun adds no hook" "$(hooks)" 0
run --no-dev
check "no-dev: link removed" '[ ! -e "$C/skills/orca-update-review" ] && [ ! -L "$C/skills/orca-update-review" ]'
eq "no-dev: recorded" "$(setting WF_INSTALL_DEV)" 0

# migration: the maintainer's machine with the retired hook (next to another SessionStart hook), CLAUDE.md link, no
# settings file, unattended: the hook goes, the other hook and dev mode stay
new
jq -n --arg c "bash \"$C/skills/orca-update-review/check.sh\"" '{hooks: {SessionStart: [{matcher: "startup|clear", hooks: [{type: "command", command: $c, timeout: 30}]}, {hooks: [{type: "command", command: "echo other"}]}]}}' >"$C/settings.json"
ln -s "$ROOT/global/CLAUDE.md" "$C/CLAUDE.md"
run
eq "migration removes the retired hook" "$(hooks)" 0
eq "migration keeps the other hook" "$(jq '.hooks.SessionStart | length' "$C/settings.json")" 1
check "migration: settings.json backup" '[ -f "$C/settings.json.bak" ]'
check "migration keeps dev: link" '[ -L "$C/skills/orca-update-review" ]'
check "migration keeps the CLAUDE.md link" '[ "$(readlink "$C/CLAUDE.md")" = "$ROOT/global/CLAUDE.md" ]'
eq "migration records dev" "$(setting WF_INSTALL_DEV)" 1
eq "migration records the link" "$(setting WF_INSTALL_GLOBAL_RULES)" link

# model presets, kept on rerun
new; run --yes --models quality
eq "quality: default" "$(setting WF_MODEL_DEFAULT)" opus
eq "quality: fast" "$(setting WF_MODEL_FAST)" sonnet
run --yes; eq "quality kept on rerun" "$(setting WF_MODEL_DEFAULT)" opus
run --yes --models nope; eq "unknown preset: exit 2" "$?" 2
run --yes --models custom; eq "custom is no preset (the terminal asks every tier): exit 2" "$?" 2
new; run --yes --models budget; eq "budget: heavy maps to opus" "$(setting WF_MODEL_HEAVY)" opus

# per-tier flags win over the preset; a rerun never overwrites a set tier; an install from before the heavy tier gets it
new; run --yes --models quality --model-heavy opus --model-fast haiku
eq "flag over preset: heavy" "$(setting WF_MODEL_HEAVY)" opus
eq "flag over preset: fast" "$(setting WF_MODEL_FAST)" haiku
eq "preset where no flag: default" "$(setting WF_MODEL_DEFAULT)" opus
run --yes; eq "rerun keeps the flagged heavy tier" "$(setting WF_MODEL_HEAVY)" opus
run --yes --model-strong claude-opus-5-5; eq "one flag changes one tier" "$(setting WF_MODEL_STRONG)" claude-opus-5-5
eq "one flag leaves the others" "$(setting WF_MODEL_HEAVY)" opus
run --yes --model-heavy 'op us'; eq "bad model id: exit 2" "$?" 2
eq "bad model id: nothing changed" "$(setting WF_MODEL_HEAVY)" opus
new; printf 'WF_MODEL_DEFAULT=haiku\nWF_MODEL_STRONG=sonnet\nWF_MODEL_FAST=haiku\n' >"$C/agent-workflow-settings.sh"; run --yes
eq "old install: tiers kept" "$(setting WF_MODEL_STRONG)" sonnet
eq "old install: heavy added" "$(setting WF_MODEL_HEAVY)" claude-fable-5-2

# global rules: link when there is no CLAUDE.md, import line into a real one
new; run --yes --global-rules
check "rules link" '[ "$(readlink "$C/CLAUDE.md")" = "$ROOT/global/CLAUDE.md" ]'
eq "rules link recorded" "$(setting WF_INSTALL_GLOBAL_RULES)" link
run --yes --no-global-rules
check "no rules removes the link" '[ ! -e "$C/CLAUDE.md" ] && [ ! -L "$C/CLAUDE.md" ]'
new; echo '# mine' >"$C/CLAUDE.md"; run --yes --global-rules; run --yes --global-rules
eq "import keeps the user's file first" "$(head -1 "$C/CLAUDE.md")" "# mine"
eq "import line once" "$(grep -cxF "$(imp)" "$C/CLAUDE.md")" 1
check "import backup" 'ls "$C"/CLAUDE.md.bak.* >/dev/null 2>&1'
eq "import recorded" "$(setting WF_INSTALL_GLOBAL_RULES)" import

# never overwrites a real file or directory where a link belongs
new; mkdir -p "$C/skills/build-gh-issue"; run --yes; rc=$?
eq "real dir: exit 0" "$rc" 0
check "real dir: left alone and named" '[ -d "$C/skills/build-gh-issue" ] && [ ! -L "$C/skills/build-gh-issue" ] && grep -q "skills/build-gh-issue" "$T/out"'

# a link to a removed skill of this checkout is dropped
new; mkdir -p "$C/skills"; ln -s "$ROOT/skills/gone-skill" "$C/skills/gone-skill"; run --yes
check "stale link removed" '[ ! -L "$C/skills/gone-skill" ]'

# interactive answers: one per tier (default, strong, fast, heavy), then the global rules
new; printf 'sonnet\nsonnet\n\nopus\nn\n' | CLAUDE_CONFIG_DIR=$C PATH=$P AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" >"$T/out" 2>&1
eq "interactive: strong answered" "$(setting WF_MODEL_STRONG)" sonnet
eq "interactive: Enter takes the default (fast)" "$(setting WF_MODEL_FAST)" haiku
eq "interactive: heavy answered" "$(setting WF_MODEL_HEAVY)" opus
check "interactive: heavy prompt names the opus fallback" 'grep -q "heavy (.*no Fable access: opus) \[claude-fable-5-2\]" "$T/out"'
printf '\n\n\n\nn\n' | CLAUDE_CONFIG_DIR=$C PATH=$P AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" >"$T/out" 2>&1
check "interactive rerun shows the set value" 'grep -q "heavy (.*) \[opus\]" "$T/out"'
eq "interactive rerun: Enter keeps it" "$(setting WF_MODEL_HEAVY)" opus
printf '\n\n\n\nn\n' | CLAUDE_CONFIG_DIR=$C PATH=$P AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" --model-heavy claude-fable-5-2 >"$T/out" 2>&1
check "interactive: a flagged tier is not asked" '! grep -q "heavy (" "$T/out"'
eq "interactive: the flag sets it" "$(setting WF_MODEL_HEAVY)" claude-fable-5-2
eq "interactive: rules off" "$(setting WF_INSTALL_GLOBAL_RULES)" off
check "interactive: shows the rule headings" 'grep -q "Out-of-scope opportunities" "$T/out"'

# the template copied as the settings file (no active model lines): Enter takes the defaults, uncommented
new; cp "$ROOT/reference/global-settings.sh" "$C/agent-workflow-settings.sh"
printf '\n\n\n\nn\n' | CLAUDE_CONFIG_DIR=$C PATH=$P AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" >"$T/out" 2>&1; rc=$?
eq "custom from the template: exit 0" "$rc" 0
eq "custom from the template: default tier" "$(setting WF_MODEL_DEFAULT)" sonnet
eq "custom from the template: fast tier" "$(setting WF_MODEL_FAST)" haiku
eq "custom from the template: heavy tier" "$(setting WF_MODEL_HEAVY)" claude-fable-5-2
eq "custom from the template: heavy written once" "$(grep -c 'WF_MODEL_HEAVY=' "$C/agent-workflow-settings.sh")" 1
check "custom from the template: skills linked" '[ -L "$C/skills/build-gh-issue" ]'

# a template line uncommented as the template says (value plus trailing comment) reads as the bare value
new; printf 'WF_MODEL_DEFAULT=opus     # lead workers\nWF_MODEL_STRONG=opus\nWF_MODEL_FAST=haiku\n' >"$C/agent-workflow-settings.sh"
printf '\n\n\n\nn\n' | CLAUDE_CONFIG_DIR=$C PATH=$P AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" >"$T/out" 2>&1
eq "uncommented line: kept as the bare value" "$(sed -n 's/^WF_MODEL_DEFAULT=\([a-z]*\).*/\1/p' "$C/agent-workflow-settings.sh")" opus
check "uncommented line: prompt shows the bare value" 'grep -qF "default (normal lead, design and fix workers) [opus]" "$T/out"'

# --check: missing jq fails and changes nothing
new; CLAUDE_CONFIG_DIR=$C PATH="$T/bin" bash "$ROOT/install.sh" --check >"$T/out" 2>&1; rc=$?
eq "check without jq: exit 1" "$rc" 1
check "check names jq" 'grep -q "jq" "$T/out"'
check "check changes nothing" '[ -z "$(ls -A "$C")" ]'
new; CLAUDE_CONFIG_DIR=$C PATH=$P bash "$ROOT/install.sh" --check >/dev/null 2>&1; eq "check with all tools: exit 0" "$?" 0

# uninstall: links and import line go, the settings file stays
new; echo '{}' >"$C/settings.json"; echo '# mine' >"$C/CLAUDE.md"; run --yes --dev --global-rules; run --uninstall
check "uninstall: no skill links into the checkout" '! ls -l "$C/skills" 2>/dev/null | grep -qF "$ROOT"'
check "uninstall: no checkout link" '[ ! -L "$C/agent-workflow" ]'
eq "uninstall: no hook" "$(hooks)" 0
eq "uninstall: no import line" "$(grep -cxF "$(imp)" "$C/CLAUDE.md")" 0
check "uninstall: settings kept and said" '[ -f "$C/agent-workflow-settings.sh" ] && grep -q "kept" "$T/out"'

run --frob; eq "unknown flag: exit 2" "$?" 2

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
