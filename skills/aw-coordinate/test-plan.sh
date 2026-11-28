#!/usr/bin/env bash
# Tests for plan.sh: a dry run of screening facts and routing on a fixture repo. `gh` is a stub that serves fixture
# files and records every call: no network, no Claude, nothing written. Run: bash skills/aw-coordinate/test-plan.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
export WF_REPO=acme/widgets WF_ISSUE_LOG_DIR="$T/logs"; mkdir -p "$T/logs/acme/widgets"
export FIX="$T/fix"; mkdir -p "$T/bin" "$FIX" "$T/repo/.claude"
cat >"$T/bin/gh" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"${CALLS:-$FIX/calls}"
case "$1 $2" in
  "issue view") [ -f "$FIX/issue-$3.json" ] && cat "$FIX/issue-$3.json" || exit 1 ;;
  "pr list")
    [ ! -f "$FIX/prs.fail" ] || exit 1
    jq -s 'add // []' "$FIX"/prs-*.json ;;
  "pr view") # rounds.sh reads the PR (head and body) when it writes a marker
    jq -s --argjson n "$3" --arg h "${PR_HEAD:-abc1234}" 'add | map(select(.number == $n))[0] | {headRefOid: $h, body: .body}' "$FIX"/prs-*.json ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
q() { git -c user.email=t@t -c user.name=t "$@"; }
cd "$T/repo" || exit 1
git init -q; q commit -q --allow-empty -m init
git remote add origin https://github.com/acme/widgets.git

issue() { # issue <n> <STATE> [label...]
  local n=$1 s=$2 l; shift 2
  l=$(for x in "$@"; do printf '{"name":"%s"},' "$x"; done)
  printf '{"state":"%s","labels":[%s]}\n' "$s" "${l%,}" >"$FIX/issue-$n.json"
}
pr() { # pr <issue> <pr number> <head> <body with \n escapes>
  jq -n --argjson num "$2" --arg head "$3" --arg body "$(printf '%b' "$4")" '[{number: $num, headRefName: $head, body: $body}]' >"$FIX/prs-$1.json"
}
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
step() { bash "$DIR/plan.sh" "$1" 2>&1 | cut -f2,3 | tr '\t' ' '; }

issue 1 OPEN ready
issue 2 OPEN needs-spec bug
issue 3 OPEN needs-design
issue 4 CLOSED ready
issue 5 OPEN ready on-hold
issue 6 OPEN needs-spec needs-decision
issue 7 OPEN ready phase:build;        pr 7 70 feat/7-a 'Summary\n\nCloses #7\n'
issue 8 OPEN ready;                    pr 8 80 fix/8-b 'Closes #8\r\n\r\n## Review\r\nroute: reviewer · risk area: bin/guard.sh\r\n'
issue 9 OPEN ready;                    pr 9 90 fix/9-c 'Closes #9\n\n## Review\nroute: reviewer · by: opus\n- [medium] wrong exit code (a.sh:3) -> open\n- [high] x (b.sh:1) -> fixed abc\nlows: 0\n'
issue 10 OPEN ready;                   pr 10 100 feat/10-d 'Closes #10\n\n## Review\nroute: lead · by: sonnet\n- [medium] y (a.sh:3) -> fixed abc\nlows: 1 (naming)\n\n## Notes\n- [low] z -> open\n'
issue 11 OPEN ready do-not-merge;      pr 11 110 feat/11-e 'Closes #11\n\n## Review\nroute: lead · by: sonnet\nlows: 0\n'
issue 12 OPEN bug
issue 13 OPEN needs-spec needs-direction
issue 15 OPEN ready;                   pr 15 150 feat/150-f 'Mentions #15 in passing.\n\nCloses #150\n'
issue 16 OPEN needs-design;            q branch proto/16-sheet
issue 17 OPEN ready needs-decision;    pr 17 170 feat/17-g 'Closes #17\n\n## Review\nroute: lead · by: sonnet\nlows: 0\n'
issue 18 OPEN ready;                   pr 18 180 feat/18-h '- Fixes acme/widgets#18\n- closes #19\n'
issue 19 OPEN ready
issue 20 OPEN ready;                   pr 20 200 feat/20-i 'Closes #20\n\n## Review\nroute: lead · by: sonnet\n- [medium] y (a.sh:3) -> open\nlows: 0\n'
issue 21 OPEN ready;                   pr 21 210 fix/21-j 'Closes #21\n\n## Review\nroute: reviewer · by: opus\n- [medium] y (a.sh:3) -> fixed abc\nlows: 0\n'
issue 22 OPEN ready;                   pr 22 220 fix/22-k 'Closes #22\n\n## Review\nroute: reviewer · by: opus\n- [medium] y (a.sh:3) -> open\nlows: 0\n'
issue 23 OPEN ready;                   pr 23 230 fix/23-l 'Closes #23\n\n## Review\nroute: reviewer · by: opus\n- [medium] y (a.sh:3) -> open\nlows: 0\n'
issue 24 OPEN ready;                   pr 24 240 fix/24-m 'Closes #24\n\n## Review\nroute: reviewer · by: opus\n- [medium] y (a.sh:3) -> fixed abc\nlows: 0\n'
issue 25 OPEN ready;                   q branch alice/feat-25-orca-style
issue 26 OPEN ready;                   q branch fix/26-plain
issue 27 OPEN ready;                   q branch alice/feat-270-other
issue 28 OPEN ready;                   pr 28 280 fix/28-n 'Closes #28\n\n## Review\nroute: reviewer · by: opus\n- [medium] y (a.sh:3) -> fixed abc\nlows: 0\n'
issue 29 OPEN ready;                   pr 29 290 fix/29-o 'Closes #29\n\n## Review\nroute: reviewer · by: opus\n- [medium] y (a.sh:3) -> open\nlows: 0\n'
issue 30 OPEN ready;                   pr 30 300 fix/30-p 'Closes #30\n\n## Review\nroute: reviewer · by: opus\n- [medium] y (a.sh:3) -> fixed abc\nlows: 0\n'
logf() { printf -- '- 2026-11-28T00:00Z %s\n' "$2" >>"$T/logs/acme/widgets/$1.md"; }
logf 21 "round: fix 1 settled abc1234"
logf 22 "fix round 1 (PR #220)"; logf 22 "fix round 1 done: 3 fixed"; logf 22 "round: fix 1 settled abc1234"; logf 22 "round: delta 1 settled open=1"
logf 23 "round: fix 1 settled abc1234"; logf 23 "round: delta 1 settled open=1"; logf 23 "round: fix 2 settled def5678"; logf 23 "round: delta 2 settled open=1"
logf 24 "round: fix 1 settled abc1234"; logf 24 "round: delta 1 skipped"
logf 28 "fix round 1 (PR #280)"; logf 28 "fix round 1 done: fixed"; logf 28 "round: fix 1 settled abc1234"; logf 28 "round: delta 1 settled open=0"
logf 29 "fix round 1 done: fixed"; logf 29 "fix round 2 done: fixed"
logf 30 "round: fix 1 settled abc1234 and more"; logf 30 "round: fix 1 settled abc1234 "; logf 30 "note round: fix 1 settled abc1234"

eq "ready: the lead builds it" "$(step 1)" "lead lane=ready"
eq "needs-spec: the lead specifies first" "$(step '#2')" "lead lane=needs-spec"
eq "needs-design: a design round" "$(step 3)" "design lane=needs-design"
eq "closed: skipped" "$(step 4)" "skip closed"
eq "on-hold: skipped, no stage" "$(step 5)" "skip held: label on-hold"
eq "parked on a decision: skipped" "$(step 6)" "skip waiting for a decision (decide.sh status) lane=needs-spec"
eq "open PR without a review: the lead goes on" "$(step 7)" "lead lane=ready pr=70 branch=feat/7-a"
eq "route reviewer, not reviewed yet (CRLF body)" "$(step 8)" "review lane=ready pr=80 branch=fix/8-b"
eq "an open finding, no marker: fix round 1" "$(step 9)" "fix lane=ready pr=90 branch=fix/9-c round=1"
eq "review complete (an open line in a later section does not count)" "$(step 10)" "merge lane=ready pr=100 branch=feat/10-d"
eq "review complete but a hold label: no merge" "$(step 11)" "skip merge held: label do-not-merge lane=ready pr=110 branch=feat/11-e"
eq "no lane label: the coordinator screens it" "$(step 12)" "screen lane=none"
eq "fog: skipped" "$(step 13)" "skip fog: label needs-direction"
eq "a PR that only mentions the issue is not its PR" "$(step 15)" "lead lane=ready"
eq "a stage branch without a PR is named" "$(step 16)" "design lane=needs-design branch=proto/16-sheet"
eq "a held merge waits for its decision" "$(step 17)" "skip waiting for a decision (decide.sh status) lane=ready pr=170 branch=feat/17-g"
eq "Fixes owner/repo#n in a list closes" "$(step 18)" "lead lane=ready pr=180 branch=feat/18-h"
eq "a batch PR closes its second issue too" "$(step 19)" "lead lane=ready pr=180 branch=feat/18-h"
eq "route lead, finding still open after the lead's rounds: hold, no third fix round" "$(step 20)" "hold fix rounds used (lead: 2, used: 0) lane=ready pr=200 branch=feat/20-i"
eq "AC11 a settled marker without a started one (a log from before): delta-review, never merge" "$(step 21)" "delta-review lane=ready pr=210 branch=fix/21-j round=1"
eq "round 1 settled and its delta-review reopened a line (worker free text 'fix round 1' ignored): fix, not hold" "$(step 22)" "fix lane=ready pr=220 branch=fix/22-k round=2"
eq "round 2 settled with its delta-review still open: hold" "$(step 23)" "hold fix rounds used (lead: 2, used: 2) lane=ready pr=230 branch=fix/23-l"
eq "a delta marker 'skipped' for the same k: merge" "$(step 24)" "merge lane=ready pr=240 branch=fix/24-m"
eq "a delta already settled for k: merge, no second delta-review (worker free text ignored)" "$(step 28)" "merge lane=ready pr=280 branch=fix/28-n"
eq "AC9 worker free text 'fix round 1/2 done' counts no round: fix round 1" "$(step 29)" "fix lane=ready pr=290 branch=fix/29-o round=1"
eq "AC9 inexact marker lines (extra text, trailing space, a prefix) count nothing: merge" "$(step 30)" "merge lane=ready pr=300 branch=fix/30-p"
eq "Orca's <user>/<type>-<n>-* branch is work in progress" "$(step 25)" "lead lane=ready branch=alice/feat-25-orca-style"
eq "a <type>/<n>-* branch is work in progress" "$(step 26)" "lead lane=ready branch=fix/26-plain"
eq "Orca branch of another issue (270) is not issue 27's" "$(step 27)" "lead lane=ready"

# --- the round state machine (bin/rounds.sh writes the markers as the coordinator does; plan.sh routes at every point
# where a session can get lost). `open` / `complete` = the PR's `## Review` with or without a finding `-> open`.
rounds() { CALLS="$T/seq-calls" bash "$DIR/../../bin/rounds.sh" "$@" >/dev/null 2>&1; } # its gh calls stay out of $FIX/calls
review() { # review <issue> <pr> <open|complete> [route] [also closes]
  local l='- [medium] y (a.sh:3) -> fixed abc'; [ "$3" = complete ] || l='- [medium] y (a.sh:3) -> open'
  pr "$1" "$2" "fix/$1-seq" "Closes #$1\n${5:+Closes #$5\n}\n## Review\nroute: ${4:-reviewer} · by: opus\n$l\nlows: 0\n"
}
S40="lane=ready pr=400 branch=fix/40-seq"
issue 40 OPEN ready; review 40 400 open
eq "AC1 lost before the round is opened (open): fix round 1" "$(step 40)" "fix $S40 round=1"
rounds start 40 400
eq "AC2 lost after start, the worker changed nothing (open): the same round goes on" "$(step 40)" "fix $S40 round=1"
rounds start 40 400
eq "AC2 a second start counts no second round" "$(grep -c 'round: fix' "$T/logs/acme/widgets/40.md") $(step 40)" "1 fix $S40 round=1"
review 40 400 complete
eq "AC3 lost while the fix worker runs, its lines already -> fixed: delta-review, never merge" "$(step 40)" "delta-review $S40 round=1"
PR_HEAD=def5678 rounds fixed 40 400
eq "AC4 lost after FIXED, before the delta-review: delta-review" "$(step 40)" "delta-review $S40 round=1"
review 40 400 open
eq "AC5/AC8 lost during the delta-review after it reopened a line, or FIXED with a new open line: delta-review, not fix" "$(step 40)" "delta-review $S40 round=1"
rounds delta 40 400 open=1
eq "AC6 after the delta marker, a line open: fix round 2" "$(step 40)" "fix $S40 round=2"
rounds start 40 400
eq "round 2 started, open: round 2 goes on (no hold, no round 3)" "$(step 40)" "fix $S40 round=2"
rounds fixed 40 400
eq "AC8 round 2 ended FIXED with a new open line: delta-review first, not hold" "$(step 40)" "delta-review $S40 round=2"
review 40 400 complete
eq "round 2 settled, complete: delta-review" "$(step 40)" "delta-review $S40 round=2"
rounds delta 40 400 open=1; review 40 400 open
eq "AC6 after round 2 and its delta-review, a line open: hold" "$(step 40)" "hold fix rounds used (lead: 2, used: 2) $S40"
rounds start 40 400
eq "AC16 a start after both rounds opens no third: still hold" "$(step 40)" "hold fix rounds used (lead: 2, used: 2) $S40"
eq "AC24 the round state cannot be read: unknown, exit 1, never merge" "$(WF_REPO=nope bash "$DIR/plan.sh" 40 2>&1 | cut -f2,3 | cut -d' ' -f1-4; WF_REPO=nope bash "$DIR/plan.sh" 40 >/dev/null 2>&1; echo $?)" "unknown	round state unreadable (rounds.sh
1"
review 40 400 complete
eq "AC6 after round 2 and its delta-review, complete: merge" "$(step 40)" "merge $S40"

issue 41 OPEN ready; review 41 410 complete
rounds start 41 410; rounds fixed 41 410; rounds delta 41 410 open=0
eq "AC6 one round, delta open=0: merge" "$(step 41)" "merge lane=ready pr=410 branch=fix/41-seq"
rounds start 41 410; rounds delta 41 410 skipped
eq "a round whose delta-review the rules skip: merge" "$(step 41)" "merge lane=ready pr=410 branch=fix/41-seq"

issue 42 OPEN ready; review 42 420 complete
logf 42 "round: fix 1 settled abc1234"; logf 42 "round: fix 2 settled def5678"; logf 42 "round: delta 2 settled open=0"
eq "AC7 two fix rounds, one delta-review for both, complete: merge, no delta-review again" "$(step 42)" "merge lane=ready pr=420 branch=fix/42-seq"
review 42 420 open
eq "AC7 ... with a line open: hold" "$(step 42)" "hold fix rounds used (lead: 2, used: 2) lane=ready pr=420 branch=fix/42-seq"

issue 43 OPEN ready; issue 44 OPEN ready; review 43 430 complete reviewer 44
rounds start 43 430
eq "AC12 a batch PR, markers on the first issue's log: its own step" "$(step 43)" "delta-review lane=ready pr=430 branch=fix/43-seq round=1"
eq "AC12 ... and the same step for the second issue" "$(step 44)" "delta-review lane=ready pr=430 branch=fix/43-seq round=1"
rounds fixed 43 430; rounds delta 43 430 open=1; rounds start 44 430
eq "AC12 round 2 opened under the second issue: both show round 2 in flight, never merge" "$(step 43 | cut -d' ' -f1,5); $(step 44 | cut -d' ' -f1,5)" "delta-review round=2; delta-review round=2"

issue 47 OPEN ready; review 47 470 complete
logf 47 "round: fix 1 started abc1234 pr=469"; logf 47 "round: fix 1 settled abc1234 pr=469"; logf 47 "round: delta 1 settled open=1 pr=469"; logf 47 "round: fix 2 started abc1234 pr=469"
eq "AC23 rounds of the issue's earlier PR (closed without a merge) do not count: merge" "$(step 47)" "merge lane=ready pr=470 branch=fix/47-seq"
review 47 470 open
eq "AC23 ... and its first finding gets fix round 1, not hold" "$(step 47)" "fix lane=ready pr=470 branch=fix/47-seq round=1"

issue 45 OPEN ready; review 45 450 open lead
rounds start 45 450
eq "AC13 route lead with a round in flight (started, open): the round goes on" "$(step 45)" "fix lane=ready pr=450 branch=fix/45-seq round=1"
rounds fixed 45 450; review 45 450 complete lead
eq "AC13 route lead, round settled, complete: delta-review, never merge" "$(step 45)" "delta-review lane=ready pr=450 branch=fix/45-seq round=1"
rounds delta 45 450 open=1; review 45 450 open lead
eq "AC13 route lead, no round in flight, a line open: hold" "$(step 45)" "hold fix rounds used (lead: 2, used: 1) lane=ready pr=450 branch=fix/45-seq"

issue 46 OPEN ready do-not-merge; review 46 460 complete
rounds start 46 460
eq "a hold label does not hide a round in flight" "$(step 46)" "delta-review lane=ready pr=460 branch=fix/46-seq round=1"
rounds delta 46 460 open=0
eq "... and holds the merge once the round is reviewed" "$(step 46)" "skip merge held: label do-not-merge lane=ready pr=460 branch=fix/46-seq"
eq "AC10 no marker (rounds under the Orca coordinator, or no log here): open is fix round 1, complete is merge" "$(step 9 | cut -d' ' -f1,5) / $(step 10 | cut -d' ' -f1)" "fix round=1 / merge"
eq "AC14 only fix and delta-review carry round=" "$(for i in 1 3 7 8 10 11 20; do step $i; done | grep -c 'round=')" 0

out=$(bash "$DIR/plan.sh" 14 2>&1); rc=$?
eq "unreadable issue: unknown, exit 1" "$rc/$(printf '%s' "$out" | cut -f2)" "1/unknown"
: >"$FIX/prs.fail"; out=$(bash "$DIR/plan.sh" 1 2>&1); rc=$?; rm "$FIX/prs.fail"
eq "unreadable PR list: unknown, never routed as if there were no PR" "$rc/$(printf '%s' "$out" | cut -f2,3 | tr '\t' ' ')" "1/unknown gh pr list failed"

# a full page of 300 PRs may have cut some off: unknown, never routed as if there were none
jq -n '[range(0;300) | {number: (1000 + .), headRefName: "x", body: ""}]' >"$FIX/prs-big.json"
out=$(bash "$DIR/plan.sh" 1 2>&1); rc=$?; rm "$FIX/prs-big.json"
eq "300 open PRs (page full): unknown, exit 1" "$rc/$(printf '%s' "$out" | cut -f2)" "1/unknown"

# lost session after the fix worker pushed (head moved since start, lines already `fixed`): rounds.sh refuses to skip the review
issue 48 OPEN ready; review 48 480 complete
PR_HEAD=aaa0001 rounds start 48 480
eq "lost session after the push: started round, lines fixed: delta-review, never merge" "$(step 48)" "delta-review lane=ready pr=480 branch=fix/48-seq round=1"
PR_HEAD=bbb0002 rounds delta 48 480 skipped
eq "delta skipped on a head that moved since start is refused: still delta-review" "$(step 48)" "delta-review lane=ready pr=480 branch=fix/48-seq round=1"

# the whole hand-over in one call: one line per issue, in the order given, exit 1 only because #14 is unreadable
out=$(bash "$DIR/plan.sh" 1 '#3' 14 9 10 4 2>&1); rc=$?
eq "several issues: one line each, input order" "$(printf '%s\n' "$out" | cut -f1,2 | tr '\t' ' ' | tr '\n' ',')" "#1 lead,#3 design,#14 unknown,#9 fix,#10 merge,#4 skip,"
eq "several issues: exit 1 names the unreadable one" "$rc" 1
out=$(bash "$DIR/plan.sh" 1 3 2>&1); eq "all readable: exit 0" "$?" 0

bash "$DIR/plan.sh" >/dev/null 2>&1; eq "no issue: usage, exit 64" "$?" 64
bash "$DIR/plan.sh" 1 x7 >/dev/null 2>&1; eq "not a number: exit 64" "$?" 64

# a dry run: it only reads
eq "only read calls reach gh" "$(cut -d' ' -f1,2 "$FIX/calls" | sort -u | tr '\n' ',')" "issue view,pr list,"
eq "nothing changed in the repo" "$(git status --porcelain)$(git worktree list | wc -l | tr -d ' ')" "1"

echo "plan: $((n - fail))/$n passed"
[ $fail = 0 ]
