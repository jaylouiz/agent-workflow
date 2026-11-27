#!/usr/bin/env bash
# Tests for install.sh in a throwaway CLAUDE_CONFIG_DIR: links, recorded choices, dev mode, global rules, uninstall,
# the rename migration (stale links, rename map, compat link) and the CLAUDE_CONFIG_DIR warning (throwaway HOME).
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
for t in bash git python3 readlink ln mkdir rm cp mv mktemp cat grep sed date dirname basename head tail tr wc cut sort awk printf env chmod touch ls uname id; do
  p=$(command -v "$t" 2>/dev/null) && case "$p" in /*) ln -s "$p" "$T/bin/$t" ;; esac
done
for t in gh claude orca; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$t"; chmod +x "$T/bin/$t"; done
ln -s "$(command -v jq)" "$T/jq/jq"
P="$T/bin:$T/jq"

new() { C="$T/c$((n))"; mkdir -p "$C"; } # fresh config dir per scenario
run() { CLAUDE_CONFIG_DIR=$C PATH=$P bash "$ROOT/install.sh" "$@" </dev/null >"$T/out" 2>&1; }
setting() { sed -n "s/^$1=//p" "$C/agent-workflow-settings.sh" | tail -1; }
# The old skill names live only in compat/renames ("<old> <new>" per line); the retired hook sat under the old name.
renames() { grep -v -e '^#' -e '^[[:space:]]*$' "$ROOT/compat/renames"; }
OLD_REVIEW=$(renames | awk '$2 == "aw-orca-review" { print $1 }')
hooks() { jq --arg h "$OLD_REVIEW/check.sh" '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains($h))] | length' "$C/settings.json"; }
imp() { echo "@$C/agent-workflow/global/CLAUDE.md"; }

# fresh --yes: every skill but the maintainer's aw-orca-review, balanced models, nothing global
new; echo '{}' >"$C/settings.json"; run --yes; rc=$?
eq "fresh: exit 0" "$rc" 0
check "fresh: build skill linked" '[ "$(readlink "$C/skills/aw-build")" = "$ROOT/skills/aw-build" ]'
check "fresh: no aw-orca-review link" '[ ! -e "$C/skills/aw-orca-review" ]'
check "fresh: checkout linked" '[ "$(readlink "$C/agent-workflow")" = "$ROOT" ]'
eq "fresh: default model" "$(setting WF_MODEL_DEFAULT)" sonnet
eq "fresh: strong model" "$(setting WF_MODEL_STRONG)" opus
eq "fresh: fast model" "$(setting WF_MODEL_FAST)" haiku
eq "fresh: heavy model" "$(setting WF_MODEL_HEAVY)" claude-fable-5-2
eq "fresh: dev off" "$(setting WF_INSTALL_DEV)" 0
eq "fresh: rules off" "$(setting WF_INSTALL_GLOBAL_RULES)" off
check "fresh: no CLAUDE.md" '[ ! -e "$C/CLAUDE.md" ]'
eq "fresh: no hook" "$(hooks)" 0
check "fresh: says what is next" 'grep -q "/aw-setup" "$T/out"'
run --yes
eq "fresh: rerun keeps one WF_MODEL_DEFAULT line" "$(grep -c '^WF_MODEL_DEFAULT=' "$C/agent-workflow-settings.sh")" 1

# dev mode: the skill link only, never a SessionStart hook; --no-dev takes the link away
new; echo '{}' >"$C/settings.json"; run --yes --dev
check "dev: aw-orca-review linked" '[ -L "$C/skills/aw-orca-review" ]'
eq "dev: no hook" "$(hooks)" 0
eq "dev: recorded" "$(setting WF_INSTALL_DEV)" 1
run; check "dev: unattended rerun keeps the link" '[ -L "$C/skills/aw-orca-review" ]'
eq "dev: rerun adds no hook" "$(hooks)" 0
run --no-dev
check "no-dev: link removed" '[ ! -e "$C/skills/aw-orca-review" ] && [ ! -L "$C/skills/aw-orca-review" ]'
eq "no-dev: recorded" "$(setting WF_INSTALL_DEV)" 0

# migration: the maintainer's machine with the retired hook (next to another SessionStart hook), CLAUDE.md link, no
# settings file, unattended: the hook goes, the other hook and dev mode stay
new
jq -n --arg c "bash \"$C/skills/$OLD_REVIEW/check.sh\"" '{hooks: {SessionStart: [{matcher: "startup|clear", hooks: [{type: "command", command: $c, timeout: 30}]}, {hooks: [{type: "command", command: "echo other"}]}]}}' >"$C/settings.json"
ln -s "$ROOT/global/CLAUDE.md" "$C/CLAUDE.md"
check "migration: the fixture holds the retired hook" '[ -n "$OLD_REVIEW" ] && [ "$(hooks)" = 1 ]'
run
eq "migration removes the retired hook" "$(hooks)" 0
eq "migration keeps the other hook" "$(jq '.hooks.SessionStart | length' "$C/settings.json")" 1
check "migration: settings.json backup" '[ -f "$C/settings.json.bak" ]'
check "migration keeps dev: link" '[ -L "$C/skills/aw-orca-review" ]'
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
new; mkdir -p "$C/skills/aw-build"; run --yes; rc=$?
eq "real dir: exit 0" "$rc" 0
check "real dir: left alone and named" '[ -d "$C/skills/aw-build" ] && [ ! -L "$C/skills/aw-build" ] && grep -q "skills/aw-build" "$T/out"'

# a link to a removed skill of this checkout is dropped
new; mkdir -p "$C/skills"; ln -s "$ROOT/skills/gone-skill" "$C/skills/gone-skill"; run --yes
check "stale link removed" '[ ! -L "$C/skills/gone-skill" ]'
check "stale link of an unknown name: no rename map" '! grep -q "skills were renamed" "$T/out"'

# rename migration: an install from before the rename has one link per old skill name into skills/; a rerun removes
# them, links the new names, turns the old coordinator skill's link into the compat link and prints the rename map
eq "rename map: seven skills" "$(renames | wc -l | tr -d ' ')" 7
new; mkdir -p "$C/skills"
renames | while read -r old _; do ln -s "$ROOT/skills/$old" "$C/skills/$old"; done
run --yes --dev; rc=$?
eq "rename: exit 0" "$rc" 0
while read -r old new_name; do
  check "rename: /$new_name is a skill of this checkout" '[ -f "$ROOT/skills/$new_name/SKILL.md" ] && grep -qx "name: $new_name" "$ROOT/skills/$new_name/SKILL.md"'
  check "rename: $new_name linked" '[ "$(readlink "$C/skills/$new_name")" = "$ROOT/skills/$new_name" ]'
  check "rename: map line for $old" 'grep -qxF "  /$old -> /$new_name" "$T/out"'
  check "rename: no skill under the old name $old" '[ ! -e "$C/skills/$old/SKILL.md" ] && [ ! -e "$ROOT/skills/$old" ]'
  if [ -d "$ROOT/compat/$old" ]; then
    check "rename: $old is the compat link" '[ "$(readlink "$C/skills/$old")" = "$ROOT/compat/$old" ]'
  else
    check "rename: old link $old removed" '[ ! -L "$C/skills/$old" ]'
  fi
done <<EOF2
$(renames)
EOF2
check "rename: every installed skill starts with aw-" '[ -z "$(for d in "$C"/skills/*/; do [ -f "$d/SKILL.md" ] && basename "$d"; done | grep -v "^aw-")" ]'
run --yes; check "rename: a second run prints no map" '! grep -q "skills were renamed" "$T/out"'
new; run --yes
check "fresh install: no rename map" '! grep -q "skills were renamed" "$T/out"'
for d in "$ROOT"/compat/*/; do
  d=${d%/}; b=$(basename "$d")
  check "compat: $b linked on a fresh install" '[ "$(readlink "$C/skills/$b")" = "$d" ]'
  check "compat: $b registers no skill" '[ ! -e "$C/skills/$b/SKILL.md" ]'
  [ ! -e "$d/settings.sh" ] || check "compat: an old script path runs through the install" '[ "$(bash "$C/skills/$b/settings.sh" get WF_MODEL_FAST)" = haiku ]'
  [ ! -e "$d/ledger.sh" ] || check "compat: the old ledger path runs through the install" 'bash "$C/skills/$b/ledger.sh" kinds | grep -q .'
done
check "the settings hint names the bin path" 'grep -qF "bash $C/agent-workflow/bin/settings.sh show" "$T/out"'
check "the bin path runs through the checkout link" '[ "$(WF_GLOBAL_SETTINGS=$C/agent-workflow-settings.sh bash "$C/agent-workflow/bin/settings.sh" get WF_MODEL_FAST)" = haiku ]'

# the login LaunchAgent starts proto-serve.sh from bin/ (macOS only; the plist dir is redirected, launchctl skipped)
if [ "$(uname)" = Darwin ]; then
  new; CLAUDE_CONFIG_DIR=$C PATH=$P AW_LAUNCHAGENTS_DIR="$T/agents" bash "$ROOT/install.sh" --yes --proto-agent </dev/null >"$T/out" 2>&1
  check "proto agent: runs bin/proto-serve.sh" 'grep -qF "$C/agent-workflow/bin/proto-serve.sh" "$T/agents"/*.plist && [ -f "$C/agent-workflow/bin/proto-serve.sh" ]'
fi

# CLAUDE_CONFIG_DIR is not supported: a dir other than ~/.claude is warned about on install and with --check; the
# standard dir (unset, or set to ~/.claude) is not. HOME is a throwaway dir, so the real ~/.claude is never touched.
WARN="is not supported: hooks and paths assume ~/.claude"
new; H="$T/home$n"; mkdir -p "$H"
HOME=$H CLAUDE_CONFIG_DIR=$C PATH=$P bash "$ROOT/install.sh" --yes </dev/null >"$T/out" 2>"$T/err"; rc=$?
eq "custom config dir: install still exits 0" "$rc" 0
check "custom config dir: install warns on stderr, naming the dir" 'grep -qF "WARNING: CLAUDE_CONFIG_DIR=$C $WARN" "$T/err"'
check "custom config dir: the warning names the supported setup" 'grep -q "Supported setup: links in ~/.claude" "$T/err"'
check "custom config dir: nothing written to the throwaway ~/.claude" '[ ! -e "$H/.claude" ]'
HOME=$H CLAUDE_CONFIG_DIR=$C PATH=$P bash "$ROOT/install.sh" --check >"$T/out" 2>&1; rc=$?
eq "custom config dir: --check exit unchanged" "$rc" 0
check "custom config dir: --check reports it" 'grep -qF "warn     CLAUDE_CONFIG_DIR=$C $WARN" "$T/out"'
env -u CLAUDE_CONFIG_DIR HOME="$H" PATH="$P" bash "$ROOT/install.sh" --yes </dev/null >"$T/out" 2>&1; rc=$?
eq "standard dir: exit 0" "$rc" 0
check "standard dir: links in ~/.claude" '[ "$(readlink "$H/.claude/skills/aw-build")" = "$ROOT/skills/aw-build" ] && [ "$(readlink "$H/.claude/agent-workflow")" = "$ROOT" ]'
check "standard dir: no warning" '! grep -q "CLAUDE_CONFIG_DIR" "$T/out"'
env -u CLAUDE_CONFIG_DIR HOME="$H" PATH="$P" bash "$ROOT/install.sh" --check >"$T/out" 2>&1
check "standard dir: --check has no warning" '! grep -q "CLAUDE_CONFIG_DIR" "$T/out"'
HOME=$H CLAUDE_CONFIG_DIR="$H/.claude/" PATH=$P bash "$ROOT/install.sh" --yes </dev/null >"$T/out" 2>&1
check "CLAUDE_CONFIG_DIR set to ~/.claude (trailing slash): no warning" '! grep -q "is not supported" "$T/out"'
# the hooks the skills register resolve in the standard install (what the warning is about)
for s in aw-build aw-specify aw-ui-design aw-orchestrate; do
  for h in $(awk '/^---$/{c++} c==1' "$ROOT/skills/$s/SKILL.md" | sed -n 's/.*command: "\\"\$HOME\\"\(.*\)"$/\1/p'); do
    check "$s hook $h resolves in ~/.claude" '[ -x "$H$h" ]'
  done
done
check "hook commands were found in the frontmatter" '[ -n "$(awk "/^---\$/{c++} c==1" "$ROOT/skills/aw-build/SKILL.md" | grep "agent-workflow/bin/guard.sh")" ]'

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
check "custom from the template: skills linked" '[ -L "$C/skills/aw-build" ]'

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
# lsof is optional: without it --check still passes and names it with a brew and an apt hint; with it, it is ok
new; CLAUDE_CONFIG_DIR=$C PATH=$P bash "$ROOT/install.sh" --check >"$T/out" 2>&1; eq "check with all required tools: exit 0" "$?" 0
check "check without lsof: optional, prototype preview servers, brew and apt hint" 'grep -q "missing  lsof (optional): prototype preview servers: .*brew install lsof.*apt install lsof" "$T/out"'
mkdir -p "$T/lsof"; printf '#!/bin/sh\nexit 0\n' >"$T/lsof/lsof"; chmod +x "$T/lsof/lsof"
new; CLAUDE_CONFIG_DIR=$C PATH="$P:$T/lsof" bash "$ROOT/install.sh" --check >"$T/out" 2>&1; eq "check with lsof: exit 0" "$?" 0
check "check with lsof: ok" 'grep -q "ok       lsof" "$T/out"'

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
