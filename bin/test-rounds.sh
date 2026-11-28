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
  "pr view") # the head from $T/head, the body from $T/body-<pr> (default: closes nothing)
    [ -f "$T/head" ] || exit 1
    jq -n --arg h "$(cat "$T/head")" --arg b "$(cat "$T/body-$3" 2>/dev/null)" '{headRefOid: $h, body: $b}' ;;
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
eq "no log: no round" "$(st 10 1)" "0 0 none"
eq "state creates no log" "$(ls "$L" | wc -l | tr -d ' ')" 0

# the whole sequence of one PR (#10 for issue 1): start -> fixed -> delta, then round 2
head_is aaa111
eq "AC16 start opens round 1 with the PR head" "$(r start 1 10)" "round=1 started aaa111"
eq "AC16 its marker names the PR" "$(last 1)" "round: fix 1 started aaa111 pr=10"
eq "state: round 1 started" "$(st 10 1)" "1 1 started"
head_is bbb222
eq "AC16 a second start goes on with the same round" "$(r start '#1' '#10')" "round=1 goes on (started before, nothing written)"
eq "AC16 a second start writes nothing" "$(marks 1)" 1
eq "AC17 fixed settles the round in flight" "$(r fixed 1 10)" "round=1 settled bbb222"
eq "AC17 its marker" "$(last 1)" "round: fix 1 settled bbb222 pr=10"
eq "state: round 1 settled" "$(st 10 1)" "1 1 settled"
eq "AC17 a second fixed writes nothing" "$(r fixed 1 10); $(marks 1)" "round=1 settled before (nothing written); 2"
eq "AC16 start while a settled round waits for its delta-review: exit 1" "$(rc start 1 10)" 1
eq "AC16 ... and nothing written" "$(marks 1)" 2
eq "AC18 delta settles the round" "$(r delta 1 10 open=1)" "round=1 delta settled open=1"
eq "AC18 its marker" "$(last 1)" "round: delta 1 settled open=1 pr=10"
eq "state: nothing in flight, one round used" "$(st 10 1)" "1 0 none"
eq "AC18 delta without a round in flight: exit 0, nothing written" "$(r delta 1 10 open=0); $(rc delta 1 10 open=0); $(marks 1)" "round=0 no fix round in flight (nothing written); 0; 3"
eq "AC17 fixed again after the round's delta marker: exit 1, no new round" "$(rc fixed 1 10); $(marks 1); $(st 10 1)" "1; 3; 1 0 none"
head_is ccc333
eq "round 2 opens" "$(r start 1 10)" "round=2 started ccc333"
eq "AC18 a delta on a started round settles it (the session was lost before FIXED was read)" "$(r delta 1 10 skipped)" "round=2 delta skipped"
eq "its marker" "$(last 1)" "round: delta 2 skipped pr=10"
eq "state: two rounds used" "$(st 10 1)" "2 0 none"
eq "AC16 both rounds used: start refuses a third, exit 1" "$(rc start 1 10); $(marks 1); $(st 10 1)" "1; 5; 2 0 none"

# AC17: fixed without a started round writes nothing
head_is ddd444
eq "fixed without a start: exit 1, nothing written" "$(rc fixed 2 20); $(marks 2)" "1; 0"

# AC16: the PR cannot be read: nothing written
rm "$T/head"
eq "start without a readable PR: exit 1" "$(rc start 3 30)" 1
eq "delta without a readable PR: exit 1" "$(rc delta 1 10 open=0)" 1
echo "not a sha" >"$T/head"
eq "start with a head that is no sha: exit 1" "$(rc start 3 30)" 1
eq "... nothing written" "$(marks 3)" 0
head_is aaa111

# AC11: lines written before the PR was recorded count for every PR; AC7: a delta marker for k settles every round up to k
logf 4 "round: fix 1 settled abc1234"; logf 4 "round: fix 2 settled def5678"
eq "a settled marker without a started one and without pr=: in flight" "$(st 40 4)" "2 2 settled"
logf 4 "round: delta 2 settled open=0"
eq "two fix rounds, one delta-review for both: nothing in flight" "$(st 40 4)" "2 0 none"
logf 5 "round: fix 1 settled abc1234"; logf 5 "round: delta 1 settled open=1"; logf 5 "round: fix 2 started def5678"
eq "an earlier delta does not settle a later round" "$(st 50 5)" "2 2 started"

# AC9: only the exact lines count
logf 6 "fix round 1 (PR #60)"; logf 6 "fix round 1 done: 3 fixed"; logf 6 "round: fix 1 settled abc1234 and more"
logf 6 "round: fix 1 settled abc1234 "; logf 6 "note round: fix 1 settled abc1234"; logf 6 "round: fix 1 started"
logf 6 "round: fix 1 started XYZ"; logf 6 "round: fix one started abc1234"; logf 6 "round: delta 1 settled"; logf 6 "round: delta 1 settled open=x"
logf 6 "round: fix 1 started abc1234 pr=60 and more"; logf 6 "round: fix 1 started abc1234 pr=x"; logf 6 "round: fix 1 started abc1234 for pr=60"
printf 'round: fix 1 started abc1234\n' >>"$L/6.md" # no `- <timestamp> ` in front
eq "free text and inexact lines count nothing" "$(st 60 6)" "0 0 none"

# AC23: a marker counts for its PR only: an earlier PR of the issue, closed without a merge, leaves no round behind
logf 7 "round: fix 1 started abc1234 pr=70"; logf 7 "round: fix 1 settled abc1234 pr=70"; logf 7 "round: delta 1 settled open=1 pr=70"; logf 7 "round: fix 2 started abc1234 pr=70"
eq "the PR the markers name: round 2 in flight" "$(st 70 7)" "2 2 started"
eq "the issue's next PR: no round" "$(st 71 7)" "0 0 none"
eq "... and its first round opens as round 1" "$(r start 7 71)" "round=1 started aaa111"
eq "the two PRs keep their own rounds" "$(st 70 7) / $(st 71 7)" "2 2 started / 1 1 started"
eq "a delta of the new PR settles its own round only" "$(r delta 7 71 open=0); $(st 70 7) / $(st 71 7)" "round=1 delta settled open=0; 2 2 started / 1 0 none"

# AC12: a batch PR (#80 closes 8 and 9): one round count over both logs, whichever issue a command names
printf 'Summary\n\nCloses #8\n- Fixes acme/widgets#9\n' >"$T/body-80"
r start 8 80 >/dev/null; r fixed 8 80 >/dev/null; r delta 8 80 open=1 >/dev/null
eq "state over both issues" "$(st 80 8 '#9')" "1 0 none"
eq "start under the other issue opens round 2, not a second round 1" "$(r start 9 80)" "round=2 started aaa111"
eq "... on that issue's log" "$(last 9)" "round: fix 2 started aaa111 pr=80"
eq "state over both issues: round 2 in flight" "$(st 80 9 8)" "2 2 started"
eq "fixed under the first issue settles the round the other log opened" "$(r fixed 8 80)" "round=2 settled aaa111"
eq "delta under either issue settles it" "$(r delta 9 80 open=0); $(st 80 8 9)" "round=2 delta settled open=0; 2 0 none"

# usage
eq "no command: 64" "$(rc)" 64
eq "state without an issue: 64" "$(rc state 10)" 64
eq "state with a non-number: 64" "$(rc state 10 x7)" 64
eq "start without a PR: 64" "$(rc start 1)" 64
eq "AC18 delta with another argument: 64" "$(rc delta 5 50 done)" 64
eq "delta without the PR: 64" "$(rc delta 5 open=0)" 64
eq "delta open= without a number: 64" "$(rc delta 5 50 open=)" 64
eq "usage errors write nothing" "$(marks 5)" 3
eq "gh is asked for the PR only" "$(cut -d' ' -f1-2 "$T/calls" | sort -u | tr '\n' ',')" "pr view,"

# AC24: a log that cannot be located (no repo to resolve) is no "no round": state fails, a write writes nothing
eq "state with an unusable WF_REPO: exit 1, nothing printed" "$(WF_REPO=nope bash "$DIR/rounds.sh" state 10 1 2>/dev/null; echo "rc=$?")" "rc=1"
eq "start with an unusable WF_REPO: exit 1" "$(WF_REPO=nope bash "$DIR/rounds.sh" start 3 30 >/dev/null 2>&1; echo $?); $(marks 3)" "1; 0"

echo "rounds: $((n - fail))/$n passed"
[ $fail = 0 ]
