#!/usr/bin/env bash
# Tests for compat/: every old script path (skills/<old skill name>/<file> before the rename) still resolves to the
# moved file and runs from there, and nothing under compat/ registers a skill. Run: bash bin/test-compat.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$DIR/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
export WF_PROTO_DIR="$T/proto-serve" # never the real prototype-server registry
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }

R="$ROOT/compat/renames"
OLD=$(awk '$2 == "aw-orchestrate" { print $1 }' "$R") # the coordinator skill's old name: the folder the scripts lived in
C="$ROOT/compat/$OLD"
check "the rename map names the old coordinator skill" '[ -n "$OLD" ]'
check "the compat folder exists" '[ -d "$C" ]'
check "no SKILL.md anywhere under compat/ (no skill under an old name)" '[ -z "$(find "$ROOT/compat" -name SKILL.md)" ]'

# every shared script that moved to bin/, and everything that stayed with the coordinator skill
MOVED="decide.sh decision_format.py issue-status.sh guard.sh worker-done-stop.sh settings.sh lib.sh proto-serve.sh merge-pr.sh sweep.sh"
STAYED="next.sh spec.sh msgs.sh task-template.md wave-template.md"
for f in $MOVED; do
  check "$f lives in bin/" '[ -f "$ROOT/bin/$f" ] && [ ! -L "$ROOT/bin/$f" ]'
  check "old path of $f is a relative link" '[ -L "$C/$f" ] && case "$(readlink "$C/$f")" in /*) false ;; *) true ;; esac'
  check "old path of $f resolves to bin/$f" '[ "$C/$f" -ef "$ROOT/bin/$f" ]'
done
for f in $STAYED; do
  check "$f stays with the coordinator skill" '[ -f "$ROOT/skills/aw-orchestrate/$f" ] && [ ! -e "$ROOT/bin/$f" ]'
  check "old path of $f resolves to the skill" '[ "$C/$f" -ef "$ROOT/skills/aw-orchestrate/$f" ]'
done
for f in $MOVED $STAYED; do case $f in *.sh) check "$f is executable through the old path" '[ -x "$C/$f" ]' ;; esac; done
eq "compat holds exactly these entries" "$(ls "$C" | sort | tr '\n' ' ')" "$(printf '%s\n' $MOVED $STAYED | sort | tr '\n' ' ')"
check "no dangling link under compat/" '[ -z "$(find "$ROOT/compat" -type l ! -exec test -e {} \; -print)" ]'

# through an install-style link (~/.claude/skills/<old name> -> compat/<old name>) the scripts find their siblings
mkdir -p "$T/claude/skills" "$T/repo"; ln -s "$C" "$T/claude/skills/$OLD"; O="$T/claude/skills/$OLD"
git -C "$T/repo" init -q; cd "$T/repo" || exit 1
eq "old settings.sh path runs (sources lib.sh next to it)" "$(bash "$O/settings.sh" get WF_MODEL_FAST)" haiku
printf '<!-- decision-note -->\nshort note\n' >"$T/note.md"
bash "$O/decide.sh" check "$T/note.md" >/dev/null 2>&1; eq "old decide.sh path runs (finds decision_format.py)" "$?" 0
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"'"$T/repo"'"}' | bash "$O/guard.sh" 2>&1); eq "old guard.sh path runs as a hook" "$?:$out" "0:"
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title x --body y"},"cwd":"'"$T/repo"'"}' | bash "$O/guard.sh" 2>&1); eq "old guard.sh path still blocks" "$?" 2
out=$(echo '{}' | env -u ORCA_TERMINAL_HANDLE bash "$O/worker-done-stop.sh" 2>&1); eq "old worker-done-stop.sh path runs" "$?" 0
printf 'a.txt\n' >"$T/files"
eq "old merge-pr.sh path runs" "$(bash "$O/merge-pr.sh" route --files "$T/files" | awk '{print $1}')" "lead:"
bash "$O/spec.sh" bogus 1 --ledger "$T" >/dev/null 2>&1; eq "old spec.sh path runs (finds bin/lib.sh and its template)" "$?" 64
bash "$O/next.sh" bogus >/dev/null 2>&1; eq "old next.sh path runs" "$?" 64
check "old msgs.sh path runs" 'echo "{\"ok\":true,\"result\":{\"deliveryId\":\"d1\",\"messages\":[]}}" | PATH="$PATH" bash "$O/msgs.sh" 2>/dev/null | grep -q "^delivery d1"'

# the friction ledger: every running session and worker spec names it under the retro skill's old name
OLDR=$(awk '$2 == "aw-retro" { print $1 }' "$R"); L="$ROOT/compat/$OLDR/ledger.sh"
check "old ledger.sh path resolves to the retro skill" '[ -n "$OLDR" ] && [ -L "$L" ] && [ "$L" -ef "$ROOT/skills/aw-retro/ledger.sh" ]'
eq "the retro compat folder holds only the ledger" "$(ls "$ROOT/compat/$OLDR")" "ledger.sh"
ln -s "$ROOT/compat/$OLDR" "$T/claude/skills/$OLDR"
bash "$T/claude/skills/$OLDR/ledger.sh" -f "$T/ledger.md" add win 1 compat "old path writes" >/dev/null 2>&1
check "old ledger.sh path runs (add writes the ledger file)" 'grep -q "old path writes" "$T/ledger.md"'
is_old() { awk -v n="$1" '$1 == n { f = 1 } END { exit !f }' "$R"; }
eq "compat holds only the folders of renamed skills" "$(for d in "$ROOT"/compat/*/; do b=$(basename "$d"); is_old "$b" || echo "$b"; done)" ""

# the rename map names every skill of this checkout once, and no old name is a skill
eq "every skill folder is a new name in the map" "$(ls "$ROOT/skills" | sort | tr '\n' ' ')" "$(grep -v '^#' "$R" | awk 'NF { print $2 }' | sort | tr '\n' ' ')"
check "no old name is a skill folder" '! grep -v "^#" "$R" | awk "NF { print \$1 }" | while read -r o; do [ -e "$ROOT/skills/$o" ] && echo hit; done | grep -q hit'

echo "compat: $((n - fail))/$n passed"
[ $fail = 0 ]
