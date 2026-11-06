#!/usr/bin/env bash
# Records the reviewed Orca state: the installed version, the orchestration guide and the --help of every command
# the workflow uses, into snapshot/ (committed). Run at the end of /orca-update-review, also when a version is
# skipped: the next report then diffs against what was reviewed. Silences the SessionStart check for this version.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/lib.sh"
v=$(installed_version)
[ -n "$v" ] || { echo "snapshot.sh: Orca not installed" >&2; exit 1; }
# Collect everything first and touch $SNAP only when it is complete: a partial command list or a failed guide fetch
# must never replace the baseline (a transient `orca … --help` failure once deleted 9 of 11 saved helps).
cmds=$(bash "$DIR/touchpoints.sh" commands) || { echo "snapshot.sh: command list incomplete, $SNAP left untouched" >&2; exit 1; }
mkdir -p "$SNAP"
T=$(mktemp -d "$SNAP/.new.XXXXXX") || { echo "snapshot.sh: cannot stage in $SNAP" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/help"
# An exit-0 fetch that printed nothing (or only whitespace) is as bad as a failed one: it would save an empty baseline.
orca skills get orchestration >"$T/orchestration-guide.md" 2>/dev/null && has_content "$T/orchestration-guide.md" || { echo "snapshot.sh: \`orca skills get orchestration\` failed or printed nothing (guide fetch), $SNAP left untouched" >&2; exit 1; }
n=0
while read -r line; do
  [ -n "$line" ] || continue
  # same test as touchpoints.sh: a Usage line (the exit code of --help is not part of it)
  # shellcheck disable=SC2086
  $line --help >"$T/help/$(help_name "$line").txt" 2>&1
  has_usage "$T/help/$(help_name "$line").txt" "$line" || { echo "snapshot.sh: \`$line --help\` printed no Usage line, $SNAP left untouched" >&2; exit 1; }
  n=$((n + 1))
done <<<"$cmds"
# $T sits inside $SNAP (same filesystem): each step is a rename, the old help/ goes away only after the new one is in place.
fail() { echo "snapshot.sh: swapping the new baseline in failed: $1" >&2; exit 1; }
[ ! -e "$SNAP/help" ] || mv "$SNAP/help" "$T/help.old" || fail "cannot move help/ aside, nothing changed"
mv "$T/help" "$SNAP/help" || { [ ! -e "$T/help.old" ] || mv "$T/help.old" "$SNAP/help"; fail "cannot move the new help/ in, old help/ restored"; }
mv "$T/orchestration-guide.md" "$SNAP/orchestration-guide.md" || fail "guide not replaced (new help/ is in place; rerun)"
echo "$v" >"$SNAP/version"
echo "snapshot: Orca $v, guide + $n command helps in $SNAP"
