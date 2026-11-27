#!/usr/bin/env bash
# Tests for install.sh in a throwaway CLAUDE_CONFIG_DIR: links, recorded choices, dev mode, global rules, uninstall,
# the rename migration (stale links, rename map, compat link), the CLAUDE_CONFIG_DIR warning (throwaway HOME), the
# version and external-skill notes of --check, the systemd user unit (stubbed uname and systemctl, redirected unit dir)
# and --update (throwaway origin and clones). Nothing here reads or writes the real ~/.claude or the real login agents.
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

# fresh config dir per scenario; the login-agent dirs are redirected too, so no run ever sees or writes the real ones
new() { C="$T/c$((n))"; mkdir -p "$C"; export AW_LAUNCHAGENTS_DIR="$T/la$n" AW_SYSTEMD_USER_DIR="$T/units$n"; }
stub() { mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" >"$1/$2"; chmod +x "$1/$2"; } # stub <dir> <tool> <sh body>
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
eq "rename map: seven skills" "$(renames | awk '{ print $2 }' | sort -u | wc -l | tr -d ' ')" 7
eq "rename map: eight old names (the coordinator skill was renamed twice)" "$(renames | awk '{ print $1 }' | sort -u | wc -l | tr -d ' ')" 8
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
# the coordinator skill's second rename, from the install as it is before it: every aw- skill linked, the coordinator
# under its previous aw- name, the first old names as compat links. A rerun links the new name, turns the previous name
# into its compat link (old script paths keep running) and prints the map.
PREV=$(renames | awk '$2 == "aw-coordinate" && $1 ~ /^aw-/ { print $1 }')
check "second rename: the map names the previous aw- name" '[ -n "$PREV" ] && [ -d "$ROOT/compat/$PREV" ]'
new; mkdir -p "$C/skills"
for d in "$ROOT"/skills/*/; do b=$(basename "$d"); [ "$b" != aw-coordinate ] || b=$PREV; ln -s "$ROOT/skills/$b" "$C/skills/$b"; done
for d in "$ROOT"/compat/*/; do d=${d%/}; b=$(basename "$d"); [ "$b" = "$PREV" ] || ln -s "$d" "$C/skills/$b"; done
run --yes --dev; rc=$?
eq "second rename: exit 0" "$rc" 0
check "second rename: aw-coordinate linked" '[ "$(readlink "$C/skills/aw-coordinate")" = "$ROOT/skills/aw-coordinate" ]'
check "second rename: the previous name is the compat link" '[ "$(readlink "$C/skills/$PREV")" = "$ROOT/compat/$PREV" ]'
check "second rename: no skill under the previous name" '[ ! -e "$C/skills/$PREV/SKILL.md" ]'
check "second rename: the map is printed with the previous name" 'grep -qxF "  /$PREV -> /aw-coordinate" "$T/out"'
bash "$C/skills/$PREV/next.sh" bogus >/dev/null 2>&1; eq "second rename: an old coordinator script path runs through the install" "$?" 64
check "second rename: the other skills keep their links" '[ "$(readlink "$C/skills/aw-build")" = "$ROOT/skills/aw-build" ] && [ "$(readlink "$C/skills/aw-orca-review")" = "$ROOT/skills/aw-orca-review" ]'
run --yes --dev; check "second rename: a second run prints no map" '! grep -q "skills were renamed" "$T/out"'
run --uninstall; check "second rename: uninstall removes the compat link too" '[ ! -L "$C/skills/$PREV" ] && [ ! -L "$C/skills/aw-coordinate" ]'
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
  new; run --yes --proto-agent
  check "proto agent: runs bin/proto-serve.sh" 'grep -qF "$C/agent-workflow/bin/proto-serve.sh" "$AW_LAUNCHAGENTS_DIR"/*.plist && [ -f "$C/agent-workflow/bin/proto-serve.sh" ]'
fi

# Linux: the same flag installs a systemd user unit. uname and systemctl are stubs first on PATH (the suite runs on
# macOS and Linux alike), the unit dir is redirected; the stub logs every systemctl call.
UNIT=agent-workflow-proto-serve.service
stub "$T/linux" uname 'echo Linux'
stub "$T/sysd" uname 'echo Linux'
stub "$T/sysd" systemctl 'echo "$*" >>"$SYSTEMCTL_LOG"'
export SYSTEMCTL_LOG="$T/systemctl.log"
lrun() { CLAUDE_CONFIG_DIR=$C PATH="$T/sysd:$P" bash "$ROOT/install.sh" "$@" </dev/null >"$T/out" 2>&1; }
new; : >"$SYSTEMCTL_LOG"; lrun --yes --proto-agent; rc=$?
U="$AW_SYSTEMD_USER_DIR/$UNIT"
eq "unit on: exit 0" "$rc" 0
check "unit on: the unit file is in the redirected dir" '[ -f "$U" ]'
check "unit on: runs bin/proto-serve.sh ensure in a login shell" 'grep -qxF "ExecStart=/bin/bash -lc '"'"'bash \"$C/agent-workflow/bin/proto-serve.sh\" ensure'"'"'" "$U"'
check "unit on: oneshot that leaves the servers running" 'grep -qx "Type=oneshot" "$U" && grep -qx "RemainAfterExit=yes" "$U" && grep -qx "KillMode=process" "$U"'
check "unit on: started at login" 'grep -qx "WantedBy=default.target" "$U"'
eq "unit on: reloaded, then enabled and started" "$(cat "$SYSTEMCTL_LOG")" "--user daemon-reload
--user enable --now $UNIT"
eq "unit on: recorded" "$(setting WF_INSTALL_PROTO_AGENT)" 1
check "unit on: said" 'grep -q "systemd user unit" "$T/out"'
check "unit on: no LaunchAgent on Linux" '[ ! -e "$AW_LAUNCHAGENTS_DIR" ]'
: >"$SYSTEMCTL_LOG"; lrun --yes
check "unit rerun: the recorded choice keeps the unit, nothing is reloaded" '[ -f "$U" ] && ! grep -qv -e is-enabled "$SYSTEMCTL_LOG"'
lrun --yes --no-proto-agent
check "unit off: file removed" '[ ! -e "$U" ]'
eq "unit off: disabled and stopped, then reloaded" "$(grep -v is-enabled "$SYSTEMCTL_LOG")" "--user disable --now $UNIT
--user daemon-reload"
eq "unit off: recorded" "$(setting WF_INSTALL_PROTO_AGENT)" 0
lrun --yes --proto-agent; lrun --uninstall
check "unit: uninstall removes it" '[ ! -e "$U" ]'
# a unit file from an install whose settings file is gone: the choice is read from disk
new; lrun --yes --proto-agent; rm "$C/agent-workflow-settings.sh"; lrun --yes
eq "unit: found on disk, kept and recorded" "$([ -f "$AW_SYSTEMD_USER_DIR/$UNIT" ] && setting WF_INSTALL_PROTO_AGENT)" 1
# a systemctl that fails (no user session): warned, the install still succeeds and the unit file stays for the next login
stub "$T/sysd-fail" uname 'echo Linux'; stub "$T/sysd-fail" systemctl 'exit 1'
new; CLAUDE_CONFIG_DIR=$C PATH="$T/sysd-fail:$P" bash "$ROOT/install.sh" --yes --proto-agent </dev/null >"$T/out" 2>&1; rc=$?
check "unit: failing systemctl is a warning, exit 0, file kept" '[ $rc = 0 ] && grep -q "systemctl --user enable --now $UNIT failed" "$T/out" && [ -f "$AW_SYSTEMD_USER_DIR/$UNIT" ]'
# the enable that failed is retried by the next install (unchanged file, unit not enabled), and a success says so
stub "$T/sysd-retry" uname 'echo Linux'
stub "$T/sysd-retry" systemctl 'echo "$*" >>"$SYSTEMCTL_LOG"; case $2 in is-enabled) [ -f "$SYSTEMCTL_LOG.on" ] ;; enable) touch "$SYSTEMCTL_LOG.on" ;; esac'
rm -f "$SYSTEMCTL_LOG.on"; : >"$SYSTEMCTL_LOG"
new; CLAUDE_CONFIG_DIR=$C PATH="$T/sysd-fail:$P" bash "$ROOT/install.sh" --yes --proto-agent </dev/null >"$T/out" 2>&1
check "unit retry: the failed enable tells the next run retries it" 'grep -q "the next install.sh or --update retries it" "$T/out"'
CLAUDE_CONFIG_DIR=$C PATH="$T/sysd-retry:$P" bash "$ROOT/install.sh" --yes </dev/null >"$T/out" 2>&1
check "unit retry: unchanged unit, not enabled -> enable --now again, said" 'grep -qx -e "--user enable --now $UNIT" "$SYSTEMCTL_LOG" && grep -q "enabled the systemd user unit" "$T/out"'
: >"$SYSTEMCTL_LOG"; CLAUDE_CONFIG_DIR=$C PATH="$T/sysd-retry:$P" bash "$ROOT/install.sh" --yes </dev/null >"$T/out" 2>&1
check "unit retry: once enabled, no further enable" '! grep -q -e "enable --now" "$SYSTEMCTL_LOG"'
# a still-failing retry warns again, exit 0
new; CLAUDE_CONFIG_DIR=$C PATH="$T/sysd-fail:$P" bash "$ROOT/install.sh" --yes --proto-agent </dev/null >"$T/out" 2>&1
CLAUDE_CONFIG_DIR=$C PATH="$T/sysd-fail:$P" bash "$ROOT/install.sh" --yes </dev/null >"$T/out" 2>&1; rc=$?
check "unit retry: still failing -> warned again, exit 0" '[ $rc = 0 ] && grep -q "enable --now $UNIT failed" "$T/out"'
# Linux without systemd: a warning, nothing installed, recorded off
new; CLAUDE_CONFIG_DIR=$C PATH="$T/linux:$P" bash "$ROOT/install.sh" --yes --proto-agent </dev/null >"$T/out" 2>&1; rc=$?
check "no systemctl: exit 0, warned, no unit" '[ $rc = 0 ] && grep -q "needs systemd (no systemctl on PATH)" "$T/out" && [ ! -e "$AW_SYSTEMD_USER_DIR" ]'
eq "no systemctl: recorded off" "$(setting WF_INSTALL_PROTO_AGENT)" 0
# another platform: the warning names both supported ones
stub "$T/other" uname 'echo SunOS'
new; CLAUDE_CONFIG_DIR=$C PATH="$T/other:$P" bash "$ROOT/install.sh" --yes --proto-agent </dev/null >"$T/out" 2>&1
check "other platform: warning names macOS and Linux" 'grep -q "macOS (LaunchAgent) and Linux (systemd --user) only" "$T/out"'
# the interactive prompt offers the unit on Linux as it offers the LaunchAgent on macOS; not without systemctl
new; : >"$SYSTEMCTL_LOG"; printf '\n\n\n\nn\ny\n' | CLAUDE_CONFIG_DIR=$C PATH="$T/sysd:$P" AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" >"$T/out" 2>&1
check "interactive on Linux: asks for the systemd user unit" 'grep -q "Restart them at login with a systemd user unit? (y/n) \[n\]" "$T/out"'
check "interactive on Linux: y installs it" '[ -f "$AW_SYSTEMD_USER_DIR/$UNIT" ] && [ "$(setting WF_INSTALL_PROTO_AGENT)" = 1 ]'
new; printf '\n\n\n\nn\ny\n' | CLAUDE_CONFIG_DIR=$C PATH="$T/linux:$P" AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" >"$T/out" 2>&1
check "interactive on Linux without systemctl: not asked" '! grep -q "Restart them at login" "$T/out" && [ "$(setting WF_INSTALL_PROTO_AGENT)" = 0 ]'
stub "$T/mac" uname 'echo Darwin'
new; printf '\n\n\n\nn\nn\n' | CLAUDE_CONFIG_DIR=$C PATH="$T/mac:$P" AW_INSTALL_INTERACTIVE=1 bash "$ROOT/install.sh" >"$T/out" 2>&1
check "interactive on macOS: asks for the LaunchAgent as before" 'grep -q "Restart them at login with a LaunchAgent? (y/n) \[n\]" "$T/out"'

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
for s in aw-build aw-specify aw-ui-design aw-coordinate; do
  for h in $(awk '/^---$/{c++} c==1' "$ROOT/skills/$s/SKILL.md" | sed -n 's/.*command: "\\"\$HOME\\"\(.*\)"$/\1/p'); do
    check "$s hook $h resolves in ~/.claude" '[ -x "$H$h" ]'
  done
done
# a config dir under $HOME gets the portable import line (@~/...), once, and --no-global-rules takes it out again
new; H="$T/home$n"; mkdir -p "$H/cfg"; echo '# mine' >"$H/cfg/CLAUDE.md"
hrun() { HOME=$H CLAUDE_CONFIG_DIR="$H/cfg" PATH=$P bash "$ROOT/install.sh" "$@" </dev/null >"$T/out" 2>&1; }
hrun --yes --global-rules; hrun --yes --global-rules
eq "config dir under HOME: the import line starts with @~/" "$(grep -c -xF '@~/cfg/agent-workflow/global/CLAUDE.md' "$H/cfg/CLAUDE.md")" 1
check "config dir under HOME: the line resolves to the linked rules" '[ -f "$H/cfg/agent-workflow/global/CLAUDE.md" ]'
eq "config dir under HOME: recorded as import" "$(sed -n 's/^WF_INSTALL_GLOBAL_RULES=//p' "$H/cfg/agent-workflow-settings.sh")" import
hrun --yes --no-global-rules
eq "config dir under HOME: the import line is removed, the user's text stays" "$(cat "$H/cfg/CLAUDE.md")" "# mine"
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

# --check: bash is required, shellcheck optional
check "check lists bash" 'grep -q "ok       bash" "$T/out"'
check "check without shellcheck: optional" 'grep -q "missing  shellcheck (optional)" "$T/out"'
# --check: gh older than GH_MIN and Orca older than ORCA_MIN are warnings that name both versions; the exit code stays 0
GH_MIN=$(sed -n 's/^GH_MIN=//p' "$ROOT/bin/lib.sh"); ORCA_MIN=$(sed -n 's/^ORCA_MIN=//p' "$ROOT/bin/lib.sh")
check "lib.sh holds GH_MIN and ORCA_MIN as plain lines" '[ -n "$GH_MIN" ] && [ -n "$ORCA_MIN" ]'
vcheck() { stub "$T/v$n" gh "echo 'gh version $1 (2026-01-01)'"; stub "$T/v$n" orca "echo '$2'"; new; CLAUDE_CONFIG_DIR=$C PATH="$T/v$n:$P" bash "$ROOT/install.sh" --check >"$T/out" 2>&1; }
vcheck 2.98.9 1.4.100; rc=$?
eq "old gh and Orca: --check still exits 0" "$rc" 0
check "old gh: warning names both versions and --attach" 'grep -q "warn     gh 2.98.9 is older than $GH_MIN: .*--attach" "$T/out"'
check "old Orca: warning names both versions" 'grep -q "warn     Orca 1.4.100 is older than the supported minimum $ORCA_MIN" "$T/out"'
vcheck "$GH_MIN" "$ORCA_MIN"
check "gh and Orca at the minimum: no warning" '! grep -q "is older than" "$T/out"'
vcheck 2.100.0 "orca 1.5.0"
check "newer gh and Orca (two-digit minor, prefixed output): no warning" '! grep -q "is older than" "$T/out"'
# --check: external skills are a found / not found note from skills/ and the plugin registry; never a failure
new; mkdir -p "$C/skills/ui-canvas" "$C/plugins"; echo '{"version":2,"plugins":{"impeccable@impeccable":[{}]}}' >"$C/plugins/installed_plugins.json"
CLAUDE_CONFIG_DIR=$C PATH=$P bash "$ROOT/install.sh" --check >"$T/out" 2>&1; rc=$?
eq "external skills: exit 0" "$rc" 0
check "external skills: ui-canvas found in skills/" 'grep -q "found      ui-canvas (skills/ui-canvas)" "$T/out"'
check "external skills: impeccable found as a plugin" 'grep -q "found      impeccable (plugin)" "$T/out"'
check "external skills: code-review is built into Claude Code (a claude on PATH)" 'grep -q "found      code-review (built into Claude Code)" "$T/out"'
mkdir -p "$T/noclaude"; for t in "$T"/bin/*; do [ "${t##*/}" = claude ] || ln -sf "$t" "$T/noclaude/"; done
CLAUDE_CONFIG_DIR=$C PATH="$T/noclaude:$T/jq" bash "$ROOT/install.sh" --check >"$T/out" 2>&1
check "external skills: code-review not found without claude, with what it is for" 'grep -q "not found  code-review: the review step" "$T/out"'

# the retired hook path somewhere else in settings.json (a permission rule): no jq error, nothing removed, no dev mode
new; jq -n --arg c "Bash($C/skills/$OLD_REVIEW/check.sh)" '{permissions: {allow: [$c]}}' >"$C/settings.json"; cp "$C/settings.json" "$T/before.json"
run --yes; rc=$?
eq "hook path outside SessionStart: exit 0" "$rc" 0
check "hook path outside SessionStart: no error" '! grep -q -e "Cannot iterate" -e "could not update" "$T/out"'
check "hook path outside SessionStart: settings.json untouched" 'cmp -s "$C/settings.json" "$T/before.json" && [ ! -e "$C/settings.json.bak" ]'
eq "hook path outside SessionStart: dev is not inferred" "$(setting WF_INSTALL_DEV)" 0
# one SessionStart group holding the retired hook and a hook of the user: only the retired one goes
new; jq -n --arg c "bash \"$C/skills/$OLD_REVIEW/check.sh\"" '{hooks: {SessionStart: [{hooks: [{type: "command", command: $c}, {type: "command", command: "echo mine"}]}]}}' >"$C/settings.json"
run --yes
eq "shared group: the retired hook is gone" "$(hooks)" 0
eq "shared group: the user's hook stays" "$(jq -r '.hooks.SessionStart[0].hooks[].command' "$C/settings.json")" "echo mine"

# a full model ID on a tier that subagents use is warned about (it is still recorded); heavy takes one silently
new; run --yes --model-strong claude-opus-5-5
check "model ID on the strong tier: warned" 'grep -q "WF_MODEL_STRONG=claude-opus-5-5 is a full model ID" "$T/out"'
new; run --yes --model-fast us.anthropic.claude-haiku-5-5-v1:0
check "Bedrock-style model ID on the fast tier: warned" 'grep -q "WF_MODEL_FAST=us.anthropic.claude-haiku-5-5-v1:0 is a full model ID" "$T/out"'
check "model ID on the heavy tier (the shipped default): no warning" '! grep -q "WF_MODEL_HEAVY=.* is a full model ID" "$T/out"'

# the installed revision is recorded on every install
new; run --yes
eq "install records the checkout's HEAD" "$(setting WF_INSTALLED_REV)" "$(git -C "$ROOT" rev-parse HEAD)"

# --update, in throwaway repos: `origin` is a copy of this work tree (tracked and new files) with its own history, each
# scenario clones it as the user's checkout and installs from the clone into a fresh config dir.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# No background maintenance in the fixtures: a detached repack after a commit races with the next local clone, which
# copies the object directory (seen as "unable to read tree" in the clone with git 2.54).
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0
O="$T/origin"; mkdir -p "$O"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do [ -e "$f" ] || continue; mkdir -p "$O/$(dirname "$f")"; cp -P "$f" "$O/$f"; done)
git -C "$O" init -q -b main; git -C "$O" add -A; git -C "$O" commit -q -m "first"; git -C "$O" tag v1.0.0
commit() { git -C "$O" add -A; git -C "$O" commit -q -m "$1"; } # commit <subject>: everything changed in origin
clone() { new; K="$T/k$n"; git clone -q "$O" "$K"; CLAUDE_CONFIG_DIR=$C PATH=$P bash "$K/install.sh" --yes </dev/null >/dev/null 2>&1; } # the user's checkout, installed
urun() { CLAUDE_CONFIG_DIR=$C PATH=$P bash "$K/install.sh" --update </dev/null >"$T/out" 2>&1; }
head_of() { git -C "$1" rev-parse HEAD; }
RESTART="Restart open Claude sessions and coordinators to load the new skills."

clone; eq "update fixture: the install recorded the clone's HEAD" "$(setting WF_INSTALLED_REV)" "$(head_of "$K")"
urun; rc=$?
eq "no-op: exit 0" "$rc" 0
check "no-op: says it is up to date, with the version" 'grep -q "Already up to date (v1.0.0)" "$T/out"'
check "no-op: no rerun, no restart line" '! grep -q -e "agent-workflow installed" -e "Restart open" "$T/out"'

# a commit that touches neither the skill list nor install.sh: pulled and listed, no install rerun
echo "note" >>"$O/README.md"; commit "docs: a note"
urun; rc=$?
eq "clean: exit 0" "$rc" 0
eq "clean: the checkout is at origin's HEAD" "$(head_of "$K")" "$(head_of "$O")"
check "clean: lists the commit since the last update" 'grep -q "^1 commit(s) since the last update (after v1.0.0):" "$T/out" && grep -q "docs: a note" "$T/out"'
check "clean: no install rerun" '! grep -q "agent-workflow installed" "$T/out" && grep -q "the links stay as they are" "$T/out"'
eq "clean: ends with the restart line" "$(tail -1 "$T/out")" "$RESTART"
eq "clean: records the new revision" "$(setting WF_INSTALLED_REV)" "$(head_of "$K")"
check "clean: no Breaking block without a Breaking entry" '! grep -q "BREAKING" "$T/out"'

# dirty: a changed tracked file refuses before anything is pulled; an untracked file alone does not
echo "more" >>"$O/README.md"; commit "docs: more"
before=$(head_of "$K"); echo "local" >>"$K/LICENSE"
urun; rc=$?
eq "dirty: exit 1" "$rc" 1
check "dirty: says why and that nothing was pulled" 'grep -q "local changes to tracked files" "$T/out" && grep -q "Nothing was pulled" "$T/out"'
eq "dirty: HEAD unchanged" "$(head_of "$K")" "$before"
eq "dirty: recorded revision unchanged" "$(setting WF_INSTALLED_REV)" "$before"
git -C "$K" checkout -q -- LICENSE; echo "mine" >"$K/my-notes.txt"
urun; rc=$?
check "untracked file only: the update runs" '[ $rc = 0 ] && [ "$(head_of "$K")" = "$(head_of "$O")" ] && [ -f "$K/my-notes.txt" ]'

# a new skill, a new release tag and a Breaking entry: install rerun, version jump, the entry highlighted
clone
mkdir -p "$O/skills/aw-extra"; printf -- '---\nname: aw-extra\ndescription: test\n---\n' >"$O/skills/aw-extra/SKILL.md"
python3 - "$O/CHANGELOG.md" <<'PYCL'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
new = "## [1.1.0] - 2099-01-01\n\n### Breaking\n\n- `/aw-old` is gone: use `/aw-extra`,\n  which takes the same arguments.\n\n### Added\n\n- `/aw-extra`.\n\n"
i = s.index("## [Unreleased]"); j = s.find("\n## ", i + 1)
if j < 0:
    s += "\n"; j = len(s) - 1
open(p, "w", encoding="utf-8").write(s[:j + 1] + new + s[j + 1:])
PYCL
commit "feat: aw-extra"; git -C "$O" tag v1.1.0
urun; rc=$?
eq "new skill: exit 0" "$rc" 0
check "new skill: the install was rerun" 'grep -q "rerunning the install" "$T/out" && grep -q "agent-workflow installed" "$T/out"'
check "new skill: linked from the checkout" '[ "$(readlink "$C/skills/aw-extra")" = "$K/skills/aw-extra" ]'
check "new skill: version jump" 'grep -qxF "Version: v1.0.0 → v1.1.0" "$T/out"'
check "new skill: Breaking block with the new entry only, joined across its lines" '[ "$(grep -c "^  ! " "$T/out")" = 1 ] && grep -qF "  ! [1.1.0]: \`/aw-old\` is gone: use \`/aw-extra\`, which takes the same arguments." "$T/out"'
check "new skill: the Breaking heading stands out" 'grep -q "^BREAKING CHANGES since your last update" "$T/out"'
eq "new skill: ends with the restart line" "$(tail -1 "$T/out")" "$RESTART"
eq "new skill: records the new revision" "$(setting WF_INSTALLED_REV)" "$(head_of "$K")"
urun; check "new skill: a second update is a no-op" 'grep -q "Already up to date (v1.1.0)" "$T/out"'
# commits after the tag: the jump names them
clone; echo "x" >>"$O/README.md"; commit "docs: after the release"
git -C "$K" reset -q --hard v1.0.0; CLAUDE_CONFIG_DIR=$C PATH=$P bash "$K/install.sh" --yes </dev/null >/dev/null 2>&1
urun; check "past the tag: the jump counts the commits after it" 'grep -qxF "Version: v1.0.0 → v1.1.0 (+1 commits after it)" "$T/out"'

# install.sh itself changed: rerun, by the pulled file
clone; echo "# a later version" >>"$O/install.sh"; commit "chore: install.sh"
urun; rc=$?
check "install.sh changed: rerun by the new file" '[ $rc = 0 ] && grep -q "rerunning the install" "$T/out" && grep -q "agent-workflow installed" "$T/out" && tail -1 "$K/install.sh" | grep -q "a later version"'
eq "install.sh changed: ends with the restart line" "$(tail -1 "$T/out")" "$RESTART"

# a pull done by hand is still reported (and relinked) by the next --update: it counts from the recorded revision
clone; mkdir -p "$O/skills/aw-more"; printf -- '---\nname: aw-more\ndescription: test\n---\n' >"$O/skills/aw-more/SKILL.md"; commit "feat: aw-more"
git -C "$K" pull -q --ff-only
urun; rc=$?
check "after a manual pull: the commit is reported and the skill linked" '[ $rc = 0 ] && grep -q "feat: aw-more" "$T/out" && [ -L "$C/skills/aw-more" ]'

# local commits that diverge: the pull fails, exit 1, nothing else changes
clone; echo "y" >>"$O/README.md"; commit "docs: upstream"
echo "z" >>"$K/LICENSE"; git -C "$K" commit -q -am "local"; before=$(head_of "$K")
urun; rc=$?
check "diverged: exit 1, said, HEAD unchanged" '[ $rc = 1 ] && grep -q "git pull --ff-only failed" "$T/out" && [ "$(head_of "$K")" = "$before" ]'

# not a git checkout (a downloaded copy): refused
new; mkdir -p "$T/copy$n"; cp -R "$O/install.sh" "$O/bin" "$O/reference" "$O/compat" "$T/copy$n/"
CLAUDE_CONFIG_DIR=$C PATH=$P bash "$T/copy$n/install.sh" --update </dev/null >"$T/out" 2>&1; rc=$?
check "no git checkout: exit 1 and said" '[ $rc = 1 ] && grep -q "is not a git checkout" "$T/out"'

# uninstall: links and import line go, the settings file stays
new; echo '{}' >"$C/settings.json"; echo '# mine' >"$C/CLAUDE.md"; run --yes --dev --global-rules; run --uninstall
check "uninstall: no skill links into the checkout" '! ls -l "$C/skills" 2>/dev/null | grep -qF "$ROOT"'
check "uninstall: no checkout link" '[ ! -L "$C/agent-workflow" ]'
eq "uninstall: no hook" "$(hooks)" 0
eq "uninstall: no import line" "$(grep -cxF "$(imp)" "$C/CLAUDE.md")" 0
check "uninstall: settings kept and said" '[ -f "$C/agent-workflow-settings.sh" ] && grep -q "kept" "$T/out"'

# run through the ~/.claude/agent-workflow link (the documented rerun): ROOT must be the physical checkout, never the
# link itself, else the link is repointed at itself and every skill link fails with "too many levels of symbolic links"
clone; echo "# upstream" >>"$O/README.md"; commit "docs: via link"
LNK="$C/agent-workflow"
check "via link: fixture is a link to the clone" '[ "$(readlink "$LNK")" = "$K" ]'
CLAUDE_CONFIG_DIR=$C PATH=$P bash "$LNK/install.sh" --yes </dev/null >"$T/out" 2>&1; rc=$?
check "via link: install exit 0, no loop" '[ $rc = 0 ] && ! grep -q "too many levels" "$T/out"'
eq "via link: the link still points at the clone" "$(readlink "$LNK")" "$K"
check "via link: skill links resolve" '[ -f "$C/skills/aw-build/SKILL.md" ]'
CLAUDE_CONFIG_DIR=$C PATH=$P bash "$LNK/install.sh" --update </dev/null >"$T/out" 2>&1; rc=$?
check "via link: --update exit 0, no loop" '[ $rc = 0 ] && ! grep -q "too many levels" "$T/out"'
eq "via link: --update left the link alone" "$(readlink "$LNK")" "$K"
check "via link: the update pulled" '[ "$(head_of "$K")" = "$(head_of "$O")" ]'

run --frob; eq "unknown flag: exit 2" "$?" 2

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
