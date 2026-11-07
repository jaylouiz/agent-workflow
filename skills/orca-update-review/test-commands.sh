#!/usr/bin/env bash
# Offline tests for touchpoints.sh commands, prepare.sh and snapshot.sh against a stubbed orca CLI (never the real one).
# Run: bash skills/orca-update-review/test-commands.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/skills/orca-update-review" "$T/skills/other" "$T/snap/help" "$T/updates"
cp "$DIR/touchpoints.sh" "$DIR/prepare.sh" "$DIR/snapshot.sh" "$DIR/lib.sh" "$T/skills/orca-update-review/"
S=$T/skills/orca-update-review
# Prose mentions: two real commands under one group, one bare group, and words that only look like commands.
printf 'run `orca orchestration send` then `orca orchestration check`, `orca skills get x`, `orca worktree show`,\nthe orca orchestration guide, and orca is great, orca does things.\n' >"$T/skills/other/use.md"
# Stub: `<group> [<cmd>] --help` prints a Usage line for the known commands, "Unknown command" otherwise; the group named
# in $STUB_BROKEN (or "any") prints nothing and fails, like an Orca that is not ready yet.
cat >"$T/bin/orca" <<'EOF2'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "skills get orchestration" ]; then [ -n "${STUB_BROKEN:-}" ] && exit 1; echo "guide text"; exit 0; fi
args=("$@"); last=$((${#args[@]} - 1)); [ "${args[$last]}" = --help ] || exit 2
unset 'args[$last]'; cmd="${args[*]}"
if [ "${STUB_BROKEN:-}" = any ] || [ "${STUB_BROKEN:-}" = "${args[0]}" ]; then exit 1; fi
case "$cmd" in
  orchestration | "orchestration send" | "orchestration check" | "skills get" | skills | worktree | "worktree show")
    printf 'orca\n\nUsage: orca %s [options]\n' "$cmd"; [ -z "${STUB_RC1:-}" ] || exit 1 ;;
  *) printf 'Unknown command: %s\n\norca\n\nUsage: orca <command> [options]\n' "$cmd" ;;
esac
EOF2
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/gh"
chmod +x "$T/bin/orca" "$T/bin/gh"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.4.300" "$T/Info.plist" >/dev/null 2>&1
export PATH="$T/bin:$PATH" HOME="$T/home" ORCA_PLIST="$T/Info.plist" ORCA_SNAPSHOT_DIR="$T/snap" ORCA_UPDATES_DIR="$T/updates"
unset STUB_BROKEN ORCA_TOUCHPOINT_DIRS
fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
baseline() { # a saved snapshot of the three healthy commands + a version
  rm -rf "$T/snap"; mkdir -p "$T/snap/help"; echo 1.4.299 >"$T/snap/version"; echo "old guide" >"$T/snap/orchestration-guide.md"
  for h in orchestration-send orchestration-check skills-get orchestration worktree-show; do echo "Usage: saved $h" >"$T/snap/help/$h.txt"; done
}
sum() { (cd "$T/snap" && find . -type f | sort | xargs cat | cksum); }

# --- healthy stub: unchanged behaviour (prose words dropped, real commands and the bare group kept)
out=$(bash "$S/touchpoints.sh" commands 2>"$T/err"); rc=$?
check "healthy: exit 0" '[ $rc = 0 ]'
check "healthy: exactly the real commands" '[ "$out" = "$(printf "orca orchestration\norca orchestration check\norca orchestration send\norca skills get\norca worktree show")" ]'
check "healthy: nothing on stderr" '[ ! -s "$T/err" ]'

# --- called through a symlinked skill dir (~/.claude/skills/<skill> -> the checkout, as install.sh links it and the
# SessionStart hook calls it): the same list, never an empty scan reported as "all unchanged"
mkdir -p "$T/link/skills"; ln -s "$S" "$T/link/skills/orca-update-review"
lout=$(bash "$T/link/skills/orca-update-review/touchpoints.sh" commands 2>"$T/err"); rc=$?
check "symlinked: exit 0" '[ $rc = 0 ]'
check "symlinked: same list as the real path" '[ "$lout" = "$out" ]'

# --- no touchpoint found at all: an error, never an empty list
mv "$T/skills/other/use.md" "$T/use.md.off"
eout=$(bash "$S/touchpoints.sh" commands 2>"$T/err"); rc=$?
check "empty scan: exits non-zero" '[ $rc != 0 ]'
check "empty scan: says so on stderr" 'grep -q "no orca command" "$T/err"'
check "empty scan: prints no list" '[ -z "$eout" ]'
mv "$T/use.md.off" "$T/skills/other/use.md"

# --- Orca not ready: every entry point fails loudly
for broken in orchestration any; do
  export STUB_BROKEN=$broken
  out=$(bash "$S/touchpoints.sh" commands 2>"$T/err"); rc=$?
  check "$broken broken: touchpoints exits non-zero" '[ $rc != 0 ]'
  check "$broken broken: touchpoints names the group on stderr" 'grep -q "orca orchestration" "$T/err"'
  check "$broken broken: touchpoints prints no partial list" '[ -z "$out" ]'

  baseline; before=$(sum); rm -f "$T/updates/r.md"
  bash "$S/prepare.sh" 1.4.299 1.4.300 --out "$T/updates/r.md" >"$T/pout" 2>"$T/err"; rc=$?
  check "$broken broken: prepare exits non-zero" '[ $rc != 0 ]'
  check "$broken broken: prepare says why and writes no \"unchanged\" report" '[ ! -e "$T/updates/r.md" ] && grep -q "incomplete" "$T/err" && ! grep -q unchanged "$T/pout" "$T/err"'

  baseline; before=$(sum)
  bash "$S/snapshot.sh" >"$T/sout" 2>"$T/err"; rc=$?
  check "$broken broken: snapshot exits non-zero" '[ $rc != 0 ]'
  check "$broken broken: snapshot leaves the baseline untouched" '[ "$(sum)" = "$before" ] && [ "$(cat "$T/snap/version")" = 1.4.299 ]'
  check "$broken broken: snapshot names the reason" 'grep -q "incomplete" "$T/err"'
done
unset STUB_BROKEN

# --- the command list is fine but `orca skills get orchestration` fails: snapshot still leaves the baseline untouched
baseline; before=$(sum)
STUB_BROKEN=none; export STUB_BROKEN
# group "skills" is listed healthy, but `orca skills get orchestration` fails
mv "$T/bin/orca" "$T/bin/orca.real"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "skills get" ] && [ "${3:-}" = orchestration ] && exit 1\nexec "%s" "$@"\n' "$T/bin/orca.real" >"$T/bin/orca"; chmod +x "$T/bin/orca"
bash "$S/snapshot.sh" >"$T/sout" 2>"$T/err"; rc=$?
check "guide fetch fails: snapshot exits non-zero, baseline untouched" '[ $rc != 0 ] && [ "$(sum)" = "$before" ]'
mv "$T/bin/orca.real" "$T/bin/orca"; unset STUB_BROKEN

# --- snapshot.sh: an exit-0 guide fetch that prints nothing (or only whitespace) is a failed fetch, never the new baseline (#33)
for mode in empty blank; do
  baseline; before=$(sum)
  mv "$T/bin/orca" "$T/bin/orca.real"
  case $mode in empty) body='exit 0' ;; blank) body='printf "  \\n\\n\\t\\n"; exit 0' ;; esac
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "skills get" ] && [ "${3:-}" = orchestration ] && { %s; }\nexec "%s" "$@"\n' "$body" "$T/bin/orca.real" >"$T/bin/orca"; chmod +x "$T/bin/orca"
  bash "$S/snapshot.sh" >"$T/sout" 2>"$T/err"; rc=$?
  check "guide fetch $mode: snapshot exits non-zero, names the guide fetch" '[ $rc != 0 ] && grep -q "guide fetch" "$T/err"'
  check "guide fetch $mode: snapshot leaves snapshot/ untouched, version not bumped" '[ "$(sum)" = "$before" ] && [ "$(cat "$T/snap/version")" = 1.4.299 ] && [ -z "$(find "$T/snap" -name ".new.*")" ]'
  mv "$T/bin/orca.real" "$T/bin/orca"
done

# --- same for prepare.sh: a failed or empty guide fetch is an error naming the fetch, never an all-lines-removed diff
for mode in fails empty blank; do
  baseline; rm -f "$T/updates/g.md"
  mv "$T/bin/orca" "$T/bin/orca.real"
  case $mode in fails) body='exit 1' ;; empty) body='exit 0' ;; blank) body='printf "  \\n\\n\\t\\n"; exit 0' ;; esac
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "skills get" ] && [ "${3:-}" = orchestration ] && { %s; }\nexec "%s" "$@"\n' "$body" "$T/bin/orca.real" >"$T/bin/orca"; chmod +x "$T/bin/orca"
  bash "$S/prepare.sh" 1.4.299 1.4.300 --out "$T/updates/g.md" >"$T/pout" 2>"$T/err"; rc=$?
  check "guide fetch $mode: prepare exits non-zero" '[ $rc != 0 ]'
  check "guide fetch $mode: prepare names the guide fetch and writes no report" '[ ! -e "$T/updates/g.md" ] && grep -q "guide fetch" "$T/err" && ! grep -q "^-" "$T/pout" "$T/err"'
  mv "$T/bin/orca.real" "$T/bin/orca"
done
# healthy fetch: the saved guide ("old guide") against "guide text" is a normal diff, not an error
baseline; bash "$S/prepare.sh" 1.4.299 1.4.300 --out "$T/updates/g.md" >/dev/null 2>"$T/err"; rc=$?
check "healthy guide: prepare exits 0 and diffs the guide" '[ $rc = 0 ] && grep -q "^-old guide" "$T/updates/g.md" && grep -q "^+guide text" "$T/updates/g.md"'

# --- healthy: prepare reports all unchanged / changed per saved help; snapshot rewrites the baseline completely
baseline
for h in orchestration orchestration-send orchestration-check skills-get worktree-show; do
  case $h in
    orchestration) u="orca orchestration";; orchestration-send) u="orca orchestration send";; orchestration-check) u="orca orchestration check";;
    skills-get) u="orca skills get";; worktree-show) u="orca worktree show";;
  esac
  printf 'orca\n\nUsage: %s [options]\n' "$u" >"$T/snap/help/$h.txt"
done
bash "$S/prepare.sh" 1.4.299 1.4.300 --out "$T/updates/ok.md" >/dev/null 2>"$T/err"; rc=$?
check "healthy: prepare exits 0 and counts the 5 commands" '[ $rc = 0 ] && grep -q "all unchanged (5 commands)" "$T/updates/ok.md"'
echo "Usage: changed" >"$T/snap/help/skills-get.txt"
bash "$S/prepare.sh" 1.4.299 1.4.300 --out "$T/updates/ch.md" >/dev/null 2>&1
check "healthy: prepare still diffs a changed help" 'grep -q "orca skills get" "$T/updates/ch.md" && ! grep -q "all unchanged" "$T/updates/ch.md"'
rm -f "$T/snap/help/worktree-show.txt"; echo stale >"$T/snap/help/gone.txt"
out=$(bash "$S/snapshot.sh" 2>"$T/err"); rc=$?
check "healthy: snapshot exits 0, rewrites version and guide" '[ $rc = 0 ] && [ "$(cat "$T/snap/version")" = 1.4.300 ] && [ "$(cat "$T/snap/orchestration-guide.md")" = "guide text" ]'
check "healthy: snapshot leaves no staging residue in snapshot/" '[ -z "$(find "$T/snap" -name ".new.*" -o -name "help.old")" ]'
check "healthy: snapshot saves all 5 helps, drops a stale one" '[ "$(ls "$T/snap/help" | wc -l | tr -d " ")" = 5 ] && [ ! -e "$T/snap/help/gone.txt" ] && [ -e "$T/snap/help/worktree-show.txt" ]'

# --- a successful --help may exit non-zero (the Usage line decides): list and snapshot still work
baseline; STUB_RC1=1 bash "$S/snapshot.sh" >/dev/null 2>"$T/err"; rc=$?
check "help exits 1 but prints Usage: snapshot succeeds" '[ $rc = 0 ] && [ "$(cat "$T/snap/version")" = 1.4.300 ]'
# --- a listed command whose help turns into garbage between list and snapshot: untouched
baseline; before=$(sum)
mv "$T/bin/orca" "$T/bin/orca.real"
printf '#!/usr/bin/env bash\n[ "$*" = "orchestration send --help" ] && [ -f "%s/flaky" ] && { echo oops; exit 1; }\nexec "%s" "$@"\n' "$T" "$T/bin/orca.real" >"$T/bin/orca"; chmod +x "$T/bin/orca"
# first call (touchpoints) must see Usage, a later one must not: flip the flag once the list is built
sed -i '' 's|^cmds=\$(bash "\$DIR/touchpoints.sh" commands) .*|&; touch "$ORCA_FLAKY"|' "$S/snapshot.sh"
ORCA_FLAKY="$T/flaky" bash "$S/snapshot.sh" >/dev/null 2>"$T/err"; rc=$?
check "help loses its Usage line after listing: snapshot refuses, baseline untouched" '[ $rc != 0 ] && grep -q "no Usage line" "$T/err" && [ "$(sum)" = "$before" ]'
mv "$T/bin/orca.real" "$T/bin/orca"

# --- prepare.sh: a per-command --help without a Usage line (transient failure) is a failed fetch naming the command, not an all-lines-removed diff (#34)
for mode in error nothing; do
  baseline; rm -f "$T/updates/h.md"; rm -f "$T/flaky"
  cp "$DIR/prepare.sh" "$S/prepare.sh"
  # the command list is built first (healthy), then the flag flips so the per-command --help below it fails
  sed -i '' 's|^cmds=\$(bash "\$DIR/touchpoints.sh" commands) .*|&; touch "$ORCA_FLAKY"|' "$S/prepare.sh"
  mv "$T/bin/orca" "$T/bin/orca.real"
  case $mode in error) body='echo "Error: connection refused"; exit 1' ;; nothing) body='exit 0' ;; esac
  printf '#!/usr/bin/env bash\n[ "$*" = "orchestration send --help" ] && [ -f "%s/flaky" ] && { %s; }\nexec "%s" "$@"\n' "$T" "$body" "$T/bin/orca.real" >"$T/bin/orca"; chmod +x "$T/bin/orca"
  ORCA_FLAKY="$T/flaky" bash "$S/prepare.sh" 1.4.299 1.4.300 --out "$T/updates/h.md" >"$T/pout" 2>"$T/err"; rc=$?
  check "help $mode: prepare exits non-zero naming the command" '[ $rc != 0 ] && grep -q "orca orchestration send --help" "$T/err" && grep -q "no Usage line" "$T/err"'
  check "help $mode: prepare writes no report and no all-lines-removed diff" '[ ! -e "$T/updates/h.md" ] && ! grep -q "^-" "$T/pout" "$T/err"'
  mv "$T/bin/orca.real" "$T/bin/orca"
done
cp "$DIR/prepare.sh" "$S/prepare.sh"
# healthy helps: the same report as before (nothing flagged, nothing diffed)
baseline
for h in orchestration orchestration-send orchestration-check skills-get worktree-show; do printf 'orca\n\nUsage: orca %s [options]\n' "$(printf '%s' "$h" | sed 's/-/ /g; s/^orchestration$/orchestration/')" >"$T/snap/help/$h.txt"; done
bash "$S/prepare.sh" 1.4.299 1.4.300 --out "$T/updates/h.md" >/dev/null 2>"$T/err"; rc=$?
check "healthy helps: prepare still exits 0 with all unchanged" '[ $rc = 0 ] && grep -q "all unchanged (5 commands)" "$T/updates/h.md" && [ ! -s "$T/err" ]'

echo "commands: $((n - fail))/$n passed"
[ $fail = 0 ]
