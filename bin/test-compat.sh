#!/usr/bin/env bash
# Tests for compat/: every old script path (skills/<old skill name>/<file> before the rename) still resolves to the
# moved file and runs from there, nothing under compat/ registers a skill, and no old skill name is left in the text
# outside compat/. Run: bash bin/test-compat.sh
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
COORD=aw-coordinate
OLDS=$(awk -v s="$COORD" '$2 == s { print $1 }' "$R") # every name the coordinator skill had: the folders its scripts lived in
eq "the rename map names both old names of the coordinator skill" "$(echo $OLDS | wc -w | tr -d ' ')" 2
check "no SKILL.md anywhere under compat/ (no skill under an old name)" '[ -z "$(find "$ROOT/compat" -name SKILL.md)" ]'

# every shared script that moved to bin/, and everything that stayed with the coordinator skill
MOVED="decide.sh decision_format.py issue-status.sh guard.sh worker-done-stop.sh settings.sh lib.sh proto-serve.sh merge-pr.sh sweep.sh"
STAYED="next.sh spec.sh msgs.sh task-template.md wave-template.md"
for f in $MOVED; do check "$f lives in bin/" '[ -f "$ROOT/bin/$f" ] && [ ! -L "$ROOT/bin/$f" ]'; done
for f in $STAYED; do check "$f stays with the coordinator skill" '[ -f "$ROOT/skills/$COORD/$f" ] && [ ! -e "$ROOT/bin/$f" ]'; done
check "no dangling link under compat/" '[ -z "$(find "$ROOT/compat" -type l ! -exec test -e {} \; -print)" ]'
has() { case " $HAS " in *" $1 "*) return 0 ;; esac; return 1; }
mkdir -p "$T/claude/skills" "$T/repo"; git -C "$T/repo" init -q

for OLD in $OLDS; do
  C="$ROOT/compat/$OLD"
  check "[$OLD] the compat folder exists" '[ -d "$C" ]'
  # the name from before the move to bin/ held the shared scripts too; the later aw- name only ever held the coordinator's own
  case $OLD in aw-*) HAS=$STAYED ;; *) HAS="$MOVED $STAYED" ;; esac
  for f in $HAS; do
    check "[$OLD] old path of $f is a relative link" '[ -L "$C/$f" ] && case "$(readlink "$C/$f")" in /*) false ;; *) true ;; esac'
    if [ -e "$ROOT/bin/$f" ]; then
      check "[$OLD] old path of $f resolves to bin/$f" '[ "$C/$f" -ef "$ROOT/bin/$f" ]'
    else
      check "[$OLD] old path of $f resolves to the skill" '[ "$C/$f" -ef "$ROOT/skills/$COORD/$f" ]'
    fi
    case $f in *.sh) check "[$OLD] $f is executable through the old path" '[ -x "$C/$f" ]' ;; esac
  done
  eq "[$OLD] compat holds exactly these entries" "$(ls "$C" | sort | tr '\n' ' ')" "$(printf '%s\n' $HAS | sort | tr '\n' ' ')"

  # through an install-style link (~/.claude/skills/<old name> -> compat/<old name>) the scripts find their siblings
  ln -s "$C" "$T/claude/skills/$OLD"; O="$T/claude/skills/$OLD"
  cd "$T/repo" || exit 1
  if has settings.sh; then
    eq "[$OLD] old settings.sh path runs (sources lib.sh next to it)" "$(bash "$O/settings.sh" get WF_MODEL_FAST)" haiku
    printf '<!-- decision-note -->\nshort note\n' >"$T/note.md"
    bash "$O/decide.sh" check "$T/note.md" >/dev/null 2>&1; eq "[$OLD] old decide.sh path runs (finds decision_format.py)" "$?" 0
    out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"'"$T/repo"'"}' | bash "$O/guard.sh" 2>&1); eq "[$OLD] old guard.sh path runs as a hook" "$?:$out" "0:"
    out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title x --body y"},"cwd":"'"$T/repo"'"}' | bash "$O/guard.sh" 2>&1); eq "[$OLD] old guard.sh path still blocks" "$?" 2
    out=$(echo '{}' | env -u ORCA_TERMINAL_HANDLE bash "$O/worker-done-stop.sh" 2>&1); eq "[$OLD] old worker-done-stop.sh path runs" "$?" 0
    printf 'a.txt\n' >"$T/files"
    eq "[$OLD] old merge-pr.sh path runs" "$(bash "$O/merge-pr.sh" route --files "$T/files" | awk '{print $1}')" "lead:"
  fi
  bash "$O/spec.sh" bogus 1 --ledger "$T" >/dev/null 2>&1; eq "[$OLD] old spec.sh path runs (finds bin/lib.sh and its template)" "$?" 64
  out=$(bash "$O/spec.sh" lead 7 --no-port --ledger "$T" 2>/dev/null); eq "[$OLD] old spec.sh path prints a spec from its template" "$?:$(printf '%s' "$out" | grep -c '{{')" "0:0"
  bash "$O/next.sh" bogus >/dev/null 2>&1; eq "[$OLD] old next.sh path runs" "$?" 64
  check "[$OLD] old msgs.sh path runs" 'echo "{\"ok\":true,\"result\":{\"deliveryId\":\"d1\",\"messages\":[]}}" | PATH="$PATH" bash "$O/msgs.sh" 2>/dev/null | grep -q "^delivery d1"'
  check "[$OLD] old template paths read" 'grep -q . "$O/task-template.md" && grep -q . "$O/wave-template.md"'
done

# the friction ledger: every running session and worker spec names it under the retro skill's old name
OLDR=$(awk '$2 == "aw-retro" { print $1 }' "$R"); L="$ROOT/compat/$OLDR/ledger.sh"
check "old ledger.sh path resolves to the retro skill" '[ -n "$OLDR" ] && [ -L "$L" ] && [ "$L" -ef "$ROOT/skills/aw-retro/ledger.sh" ]'
eq "the retro compat folder holds only the ledger" "$(ls "$ROOT/compat/$OLDR")" "ledger.sh"
ln -s "$ROOT/compat/$OLDR" "$T/claude/skills/$OLDR"
bash "$T/claude/skills/$OLDR/ledger.sh" -f "$T/ledger.md" add win 1 compat "old path writes" >/dev/null 2>&1
check "old ledger.sh path runs (add writes the ledger file)" 'grep -q "old path writes" "$T/ledger.md"'
is_old() { awk -v n="$1" '$1 == n { f = 1 } END { exit !f }' "$R"; }
eq "compat holds only the folders of renamed skills" "$(for d in "$ROOT"/compat/*/; do b=$(basename "$d"); is_old "$b" || echo "$b"; done)" ""

# the rename map names every skill of this checkout, and no old name is a skill
eq "every skill folder is a new name in the map" "$(ls "$ROOT/skills" | sort | tr '\n' ' ')" "$(grep -v '^#' "$R" | awk 'NF { print $2 }' | sort -u | tr '\n' ' ')"
eq "no old name is listed twice" "$(grep -v '^#' "$R" | awk 'NF { print $1 }' | sort | uniq -d)" ""
check "no old name is a skill folder" '! grep -v "^#" "$R" | awk "NF { print \$1 }" | while read -r o; do [ -e "$ROOT/skills/$o" ] && echo hit; done | grep -q hit'

# old-name check: no old skill name of the map is left in the text of this checkout. Outside compat/ (the map, the old
# paths) only history may name a skill as it was called then: the files matching OLD_NAME_OK (basename globs).
OLD_NAME_OK="CHANGELOG* retro-log.md"
old_name_hits() { # old_name_hits <root>: `<file>:<line>:<text>` of every old skill name in the TRACKED files of <root> (git grep), compat/ left out
  local root=$1 o x
  set --
  for o in $(grep -v '^#' "$R" | awk 'NF { print $1 }'); do set -- "$@" -e "$o"; done
  set -- "$@" -- . ':(exclude)compat'
  for x in $OLD_NAME_OK; do set -- "$@" ":(exclude,glob)**/$x"; done
  git -C "$root" grep -nIF "$@" || true
}
F="$T/oldnames"; mkdir -p "$F/skills/x" "$F/compat/any" "$F/.claude" "$F/docs" "$F/node_modules/p"; git -C "$F" init -q
echo "run /$COORD" >"$F/skills/x/SKILL.md"
for o in $OLDS; do echo "$o" >>"$F/compat/any/README.md"; echo "then /$o ran" >>"$F/.claude/retro-log.md"; echo "$o" >>"$F/CHANGELOG.md"; done
git -C "$F" add -A
eq "old-name check: compat/ and history files may name an old skill" "$(old_name_hits "$F")" ""
for o in $OLDS; do
  mkdir -p "$F/docs" "$F/.claude"; echo "see /$o section 5" >"$F/docs/a.md"; git -C "$F" add docs/a.md
  eq "old-name check: $o in a doc is reported" "$(old_name_hits "$F")" "docs/a.md:1:see /$o section 5"
  git -C "$F" rm -qf docs/a.md; echo "~/.claude/skills/$o/next.sh" >"$F/.claude/profile.md"; git -C "$F" add .claude/profile.md
  eq "old-name check: $o in a dot folder is reported" "$(old_name_hits "$F" | cut -d: -f1,2)" ".claude/profile.md:1"
  git -C "$F" rm -qf .claude/profile.md
done
# only tracked files count: untracked or ignored content (.claude/worktrees/, node_modules/, scratch files) never fails the check
echo "node_modules/" >"$F/.gitignore"; git -C "$F" add .gitignore
for o in $OLDS; do echo "/$o" >"$F/scratch.md"; echo "$o" >"$F/node_modules/p/x.md"; done
eq "old-name check: untracked and gitignored files naming an old skill are not reported" "$(old_name_hits "$F")" ""
rm "$F/scratch.md"
hits=$(old_name_hits "$ROOT"); n=$((n + 1))
if [ -n "$hits" ]; then
  fail=$((fail + 1)); echo "FAIL [no old skill name outside compat/]"; printf '%s\n' "$hits" | cut -c1-200 | sed 's/^/  /'
  echo "  Use the new name (compat/renames: <old> <new>). Only compat/ and history files ($OLD_NAME_OK) keep an old one."
fi

echo "compat: $((n - fail))/$n passed"
[ $fail = 0 ]
