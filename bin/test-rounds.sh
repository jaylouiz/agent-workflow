#!/usr/bin/env bash
# Tests for rounds.sh: the round markers of a PR in subagent mode, written and read back (offline; `gh` is a stub that
# serves the PR head). Routing on the state is tested in skills/aw-coordinate/test-plan.sh. Run: bash bin/test-rounds.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
export WF_REPO=acme/widgets WF_ISSUE_LOG_DIR="$T/logs" T; L="$T/logs/acme/widgets"; mkdir -p "$L" "$T/bin"
cat >"$T/bin/gh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"$T/calls"
case "$1 $2" in
  "pr view") [ -f "$T/head" ] && cat "$T/head" || exit 1 ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
cd "$T" || exit 1

fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
r() { bash "$DIR/rounds.sh" "$@" 2>&1; }
rc() { bash "$DIR/rounds.sh" "$@" >/dev/null 2>&1; echo $?; }
st() { bash "$DIR/rounds.sh" state "$@"; }
marks() { [ -f "$L/$1.md" ] && grep -c ' round: ' "$L/$1.md" || echo 0; } # marker lines on an issue's log
last() { tail -1 "$L/$1.md" | cut -d' ' -f3-; }
logf() { printf -- '- 2026-11-28T00:00Z %s\n' "$2" >>"$L/$1.md"; }
head_is() { echo "$1" >"$T/head"; }

# AC15: state reads only; no log is no round
eq "no log: no round" "$(st 1)" "0 0 none"
eq "state creates no log" "$(ls "$L" | wc -l | tr -d ' ')" 0

# the whole sequence of one PR: start -> fixed -> delta, then round 2
head_is aaa111
eq "AC16 start opens round 1 with the PR head" "$(r start 1 10)" "round=1 started aaa111"
eq "AC16 its marker" "$(last 1)" "round: fix 1 started aaa111"
eq "state: round 1 started" "$(st 1)" "1 1 started"
head_is bbb222
eq "AC16 a second start goes on with the same round" "$(r start '#1' 10)" "round=1 goes on (started before, nothing written)"
eq "AC16 a second start writes nothing" "$(marks 1)" 1
eq "AC17 fixed settles the round in flight" "$(r fixed 1 10)" "round=1 settled bbb222"
eq "AC17 its marker" "$(last 1)" "round: fix 1 settled bbb222"
eq "state: round 1 settled" "$(st 1)" "1 1 settled"
eq "AC17 a second fixed writes nothing" "$(r fixed 1 10); $(marks 1)" "round=1 settled before (nothing written); 2"
eq "AC16 start while a settled round waits for its delta-review: exit 1" "$(rc start 1 10)" 1
eq "AC16 ... and nothing written" "$(marks 1)" 2
eq "AC18 delta settles the round" "$(r delta 1 open=1)" "round=1 delta settled open=1"
eq "AC18 its marker" "$(last 1)" "round: delta 1 settled open=1"
eq "state: nothing in flight, one round used" "$(st 1)" "1 0 none"
eq "AC18 delta without a round in flight: exit 0, nothing written" "$(r delta 1 open=0); $(rc delta 1 open=0); $(marks 1)" "round=0 no fix round in flight (nothing written); 0; 3"
head_is ccc333
eq "round 2 opens" "$(r start 1 10)" "round=2 started ccc333"
eq "AC18 a delta on a started round settles it (the session was lost before FIXED was read)" "$(r delta 1 skipped)" "round=2 delta skipped"
eq "its marker" "$(last 1)" "round: delta 2 skipped"
eq "state: two rounds used" "$(st 1)" "2 0 none"

# AC17: fixed without a start (a log written before the started marker existed) opens and settles the next round
head_is ddd444
eq "fixed without a start settles the next round" "$(r fixed 2 20)" "round=1 settled ddd444"
eq "state: settled" "$(st 2)" "1 1 settled"

# AC16: the PR head cannot be read: nothing written
rm "$T/head"
eq "start without a readable head: exit 1" "$(rc start 3 30)" 1
eq "fixed without a readable head: exit 1" "$(rc fixed 3 30)" 1
echo "not a sha" >"$T/head"
eq "start with a head that is no sha: exit 1" "$(rc start 3 30)" 1
eq "... nothing written" "$(marks 3)" 0
head_is aaa111

# AC7: a delta marker for k settles every round up to k
logf 4 "round: fix 1 settled abc1234"; logf 4 "round: fix 2 settled def5678"; logf 4 "round: delta 2 settled open=0"
eq "two fix rounds, one delta-review for both: nothing in flight" "$(st 4)" "2 0 none"
logf 5 "round: fix 1 settled abc1234"; logf 5 "round: delta 1 settled open=1"; logf 5 "round: fix 2 started def5678"
eq "an earlier delta does not settle a later round" "$(st 5)" "2 2 started"

# AC9: only the exact lines count
logf 6 "fix round 1 (PR #60)"; logf 6 "fix round 1 done: 3 fixed"; logf 6 "round: fix 1 settled abc1234 and more"
logf 6 "round: fix 1 settled abc1234 "; logf 6 "note round: fix 1 settled abc1234"; logf 6 "round: fix 1 started"
logf 6 "round: fix 1 started XYZ"; logf 6 "round: fix one started abc1234"; logf 6 "round: delta 1 settled"; logf 6 "round: delta 1 settled open=x"
printf 'round: fix 1 started abc1234\n' >>"$L/6.md" # no `- <timestamp> ` in front
eq "free text and inexact lines count nothing" "$(st 6)" "0 0 none"

# AC12: a batch PR: the markers of every issue it closes
eq "several issues: the union of their markers" "$(st 3 5 '#6')" "2 2 started"
eq "several issues, none in flight" "$(st 6 4 3)" "2 0 none"

# usage
eq "no command: 64" "$(rc)" 64
eq "state without an issue: 64" "$(rc state)" 64
eq "state with a non-number: 64" "$(rc state x7)" 64
eq "start without a PR: 64" "$(rc start 1)" 64
eq "AC18 delta with another argument: 64" "$(rc delta 5 done)" 64
eq "delta open= without a number: 64" "$(rc delta 5 open=)" 64
eq "usage errors write nothing" "$(marks 5)" 3

eq "gh is asked for the PR head only" "$(cut -d' ' -f1-4 "$T/calls" | sort -u | tr '\n' ',')" "pr view 10 --json,pr view 20 --json,pr view 30 --json,"

# no repo to resolve: state counts no round
mkdir -p "$T/norepo"
eq "state outside a repo, no WF_REPO: no round" "$(cd "$T/norepo" && env -u WF_REPO bash "$DIR/rounds.sh" state 1)" "0 0 none"

echo "rounds: $((n - fail))/$n passed"
[ $fail = 0 ]
