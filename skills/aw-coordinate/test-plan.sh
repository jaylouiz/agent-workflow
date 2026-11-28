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
echo "$*" >>"$FIX/calls"
case "$1 $2" in
  "issue view") [ -f "$FIX/issue-$3.json" ] && cat "$FIX/issue-$3.json" || exit 1 ;;
  "pr list")
    [ ! -f "$FIX/prs.fail" ] || exit 1
    jq -s 'add // []' "$FIX"/prs-*.json ;;
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
logf() { printf -- '- 2026-11-28T00:00Z %s\n' "$2" >>"$T/logs/acme/widgets/$1.md"; }
logf 21 "fix round 1 (PR #210)"
logf 22 "fix round 1 (PR #220)"
logf 23 "fix round 1 (PR #230)"; logf 23 "delta-review done (PR #230)"; logf 23 "fix round 2 (PR #230)"
logf 24 "fix round 1 (PR #240)"; logf 24 "delta-review skipped"

eq "ready: the lead builds it" "$(step 1)" "lead lane=ready"
eq "needs-spec: the lead specifies first" "$(step '#2')" "lead lane=needs-spec"
eq "needs-design: a design round" "$(step 3)" "design lane=needs-design"
eq "closed: skipped" "$(step 4)" "skip closed"
eq "on-hold: skipped, no stage" "$(step 5)" "skip held: label on-hold"
eq "parked on a decision: skipped" "$(step 6)" "skip waiting for a decision (decide.sh status) lane=needs-spec"
eq "open PR without a review: the lead goes on" "$(step 7)" "lead lane=ready pr=70 branch=feat/7-a"
eq "route reviewer, not reviewed yet (CRLF body)" "$(step 8)" "review lane=ready pr=80 branch=fix/8-b"
eq "an open finding: a fix round" "$(step 9)" "fix lane=ready pr=90 branch=fix/9-c"
eq "review complete (an open line in a later section does not count)" "$(step 10)" "merge lane=ready pr=100 branch=feat/10-d"
eq "review complete but a hold label: no merge" "$(step 11)" "skip merge held: label do-not-merge lane=ready pr=110 branch=feat/11-e"
eq "no lane label: the coordinator screens it" "$(step 12)" "screen lane=none"
eq "fog: skipped" "$(step 13)" "skip fog: label needs-direction"
eq "a PR that only mentions the issue is not its PR" "$(step 15)" "lead lane=ready"
eq "a stage branch without a PR is named" "$(step 16)" "design lane=needs-design branch=proto/16-sheet"
eq "a held merge waits for its decision" "$(step 17)" "skip waiting for a decision (decide.sh status) lane=ready pr=170 branch=feat/17-g"
eq "Fixes owner/repo#n in a list closes" "$(step 18)" "lead lane=ready pr=180 branch=feat/18-h"
eq "a batch PR closes its second issue too" "$(step 19)" "lead lane=ready pr=180 branch=feat/18-h"
eq "route lead, finding still open after the lead's rounds: hold, no third fix round" "$(step 20)" "hold fix rounds used (lead: 2, logged: 0) lane=ready pr=200 branch=feat/20-i"
eq "a fix without its delta-review: delta-review, never merge" "$(step 21)" "delta-review lane=ready pr=210 branch=fix/21-j"
eq "reviewer route, 1 fix round logged, a finding open: fix" "$(step 22)" "fix lane=ready pr=220 branch=fix/22-k"
eq "reviewer route, 2 fix rounds logged, a finding open: hold" "$(step 23)" "hold fix rounds used (lead: 2, logged: 2) lane=ready pr=230 branch=fix/23-l"
eq "a delta-review skipped on the log: merge" "$(step 24)" "merge lane=ready pr=240 branch=fix/24-m"
eq "Orca's <user>/<type>-<n>-* branch is work in progress" "$(step 25)" "lead lane=ready branch=alice/feat-25-orca-style"
eq "a <type>/<n>-* branch is work in progress" "$(step 26)" "lead lane=ready branch=fix/26-plain"
eq "Orca branch of another issue (270) is not issue 27's" "$(step 27)" "lead lane=ready"

out=$(bash "$DIR/plan.sh" 14 2>&1); rc=$?
eq "unreadable issue: unknown, exit 1" "$rc/$(printf '%s' "$out" | cut -f2)" "1/unknown"
: >"$FIX/prs.fail"; out=$(bash "$DIR/plan.sh" 1 2>&1); rc=$?; rm "$FIX/prs.fail"
eq "unreadable PR list: unknown, never routed as if there were no PR" "$rc/$(printf '%s' "$out" | cut -f2,3 | tr '\t' ' ')" "1/unknown gh pr list failed"

# a full page of 300 PRs may have cut some off: unknown, never routed as if there were none
jq -n '[range(0;300) | {number: (1000 + .), headRefName: "x", body: ""}]' >"$FIX/prs-big.json"
out=$(bash "$DIR/plan.sh" 1 2>&1); rc=$?; rm "$FIX/prs-big.json"
eq "300 open PRs (page full): unknown, exit 1" "$rc/$(printf '%s' "$out" | cut -f2)" "1/unknown"

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
