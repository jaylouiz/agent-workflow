#!/usr/bin/env bash
# Tests for next.sh with a stubbed `orca` and `gh` (offline). Run: bash skills/orchestrate-gh-issues/test-next.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/.claude" "$T/ledger"; git -C "$T/repo" init -q
cat >"$T/bin/gh" <<'EOF2'
#!/usr/bin/env bash
case "$*" in "issue view"*) echo "Some issue" ;; *) exit 1 ;; esac
EOF2
# Stub orca: logs every call to $T/calls; behaviour from files in $T/state (dispatch_status, active, fail_start).
cat >"$T/bin/orca" <<'EOF2'
#!/usr/bin/env bash
S=$STUB_STATE
echo "$*" >>"$S/calls"
[ "$1" = orchestration ] || exit 1
case "$2" in
  worker-show) echo "{\"ok\":true,\"result\":{\"dispatch\":{\"id\":\"ctx_aaa111\",\"status\":\"$(cat "$S/dispatch_status")\"}}}" ;;
  worker-release) echo '{"ok":true,"result":{"releaseState":"released"}}' ;;
  worker-list)
    n=$(cat "$S/active"); printf '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_old","dispatchStatus":"completed"}'
    for ((i = 0; i < n; i++)); do printf ',{"dispatchId":"ctx_w%s","dispatchStatus":"dispatched"}' "$i"; done
    printf ']}}\n' ;;
  task-create)
    if [ -f "$S/fail_create" ]; then echo "create boom" >&2; exit 1; fi
    echo '{"ok":true,"result":{"task":{"id":"task_0123456789ab"}}}' ;;
  worker-start)
    if [ -f "$S/fail_start" ]; then echo "boom" >&2; echo '{"ok":false,"failedStage":"launch"}'; exit 1; fi
    echo '{"ok":true,"result":{"dispatchId":"ctx_beef00112233"}}' ;;
  *) exit 1 ;;
esac
EOF2
chmod +x "$T/bin/gh" "$T/bin/orca"
export PATH="$T/bin:$PATH" STUB_STATE="$T/state"; mkdir -p "$T/state"
cd "$T/repo" || exit 1
echo 'WF_PORTS=39201-39202' >.claude/issue-workflow.sh

fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
reset() { : >"$T/state/calls"; rm -f "$T/state/fail_start" "$T/state/fail_create"; echo completed >"$T/state/dispatch_status"; echo 0 >"$T/state/active"; rm -rf "$T/ledger"; mkdir -p "$T/ledger"; }
NEXT() { bash "$DIR/next.sh" "$@"; }
q() { NEXT queue --ledger "$T/ledger" "$@" >/dev/null; }

# happy path: settle one worker, port freed, next task started (a legacy --delivery is ignored)
reset
echo "39201 #4 lead" >"$T/ledger/ports"
q "#7 lead" lead 7 --tier Standard -- --agent claude --model sonnet --effort high --worktree new-top-level --name fix-7-x
out=$(NEXT settle --dispatch ctx_aaa111 --delivery d1 --port 39201 --ledger "$T/ledger" --run run_x 2>"$T/err"); rc=$?
calls=$(cat "$T/state/calls")
check "happy: exit 0" '[ $rc = 0 ]'
check "happy: order proof, release, slots, create, start (no ack)" '[ "$(printf "%s\n" "$calls" | awk "{print \$2}" | tr "\n" " ")" = "worker-show worker-release worker-list task-create worker-start " ]'
check "happy: release passes dispatch" 'printf "%s" "$calls" | grep -q "^orchestration worker-release --dispatch ctx_aaa111"'
check "happy: port 39201 released, next task got a port" '! grep -q "^39201 #4" "$T/ledger/ports" && grep -q "#7 lead" "$T/ledger/ports"'
check "happy: no check call (V3: no ack, no waiter)" '! printf "%s" "$calls" | grep -q "^orchestration check"'
check "happy: worker-start gets task and args" 'printf "%s" "$calls" | grep -q "^orchestration worker-start --task task_0123456789ab --agent claude --model sonnet --effort high --worktree new-top-level --name fix-7-x --json --run run_x"'
check "happy: spec file written with PORT line" 'grep -q "^PORT=" "$T/ledger/7-lead.spec"'
check "happy: started line" 'printf "%s" "$out" | grep -q "^started: #7 lead task=task_0123456789ab dispatch=ctx_beef00112233 port=39201"'
check "happy: end-turn line last" 'printf "%s\n" "$out" | tail -1 | grep -q "^next: end your turn"'
check "happy: queue drained" '[ ! -s "$T/ledger/queue" ]'

# failed start: loud, named stage, recorded, not retried, end-turn line still printed
reset
q "#8 lead" lead 8 -- --agent claude
q "#9 lead" lead 9 -- --agent claude
touch "$T/state/fail_start"
out=$(NEXT settle --dispatch ctx_aaa111 --ledger "$T/ledger" 2>"$T/err"); rc=$?
check "failed start: exit 1" '[ $rc = 1 ]'
check "failed start: names the stage" 'grep -q "stage start failed" "$T/err" && grep -q "#8 lead" "$T/err"'
check "failed start: end-turn line still printed" 'printf "%s" "$out" | grep -q "^next: end your turn"'
check "failed start: recorded" 'grep -q "#8 lead" "$T/ledger/failed-starts"'
check "failed start: started once, next task untouched" '[ "$(grep -c "^orchestration worker-start" "$T/state/calls")" = 1 ] && grep -q "^#9 lead" "$T/ledger/queue" && ! grep -q "^#8" "$T/ledger/queue"'

# failed task-create: recorded in failed-starts, port released, next task untouched, end-turn line printed
reset
q "#8 lead" lead 8 -- --agent claude
q "#9 lead" lead 9 -- --agent claude
touch "$T/state/fail_create"
out=$(NEXT settle --dispatch ctx_aaa111 --ledger "$T/ledger" 2>"$T/err"); rc=$?
check "failed create: exit 1, stage task-create named" '[ $rc = 1 ] && grep -q "stage task-create failed" "$T/err" && grep -q "#8 lead" "$T/err"'
check "failed create: recorded in failed-starts" 'grep -q "^#8 lead.*task-create" "$T/ledger/failed-starts"'
check "failed create: port released" '! grep -q "#8 lead" "$T/ledger/ports"'
check "failed create: no worker-start, next task untouched" '! grep -q "worker-start" "$T/state/calls" && grep -q "^#9 lead" "$T/ledger/queue" && ! grep -q "^#8" "$T/ledger/queue"'
check "failed create: end-turn line still printed" 'printf "%s" "$out" | grep -q "^next: end your turn"'

# spec.sh args with spaces survive queue -> fill as an array
reset
q "#7 lead" lead 7 --tier "Fix - 3 mediums" -- --agent claude --name "a b"
out=$(NEXT start --ledger "$T/ledger" 2>"$T/err"); rc=$?
check "spaced args: exit 0, started" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "^started: #7 lead"'
check "spaced args: tier reaches the spec" 'grep -q "Fix - 3 mediums" "$T/ledger/7-lead.spec"'
check "spaced args: worker-start arg kept whole" 'grep -q -- "--agent claude --name a b --json" "$T/state/calls"'
NEXT queue --ledger "$T/ledger" "#8 lead" lead 8 --tier "a	b" >/dev/null 2>&1; rc=$?
check "queue rejects a tab in an arg (exit 64, not queued)" '[ $rc = 64 ] && [ ! -s "$T/ledger/queue" ]'

# not settled: nothing released, exit 2
reset
echo dispatched >"$T/state/dispatch_status"
q "#7 lead" lead 7 -- --agent claude
out=$(NEXT settle --dispatch ctx_aaa111 --delivery d1 --ledger "$T/ledger" 2>"$T/err"); rc=$?
check "unsettled: exit 2" '[ $rc = 2 ]'
check "unsettled: stage proof named" 'grep -q "stage proof failed" "$T/err"'
check "unsettled: no release or start" '! grep -qE "worker-release|--ack|worker-start" "$T/state/calls"'
check "unsettled: task stays queued" '[ -s "$T/ledger/queue" ]'

# slots full: settled and released, nothing started, task stays queued
reset
echo 3 >"$T/state/active"
q "#7 lead" lead 7 -- --agent claude
out=$(NEXT settle --dispatch ctx_aaa111 --ledger "$T/ledger" --max 3 2>&1); rc=$?
check "slots full: exit 0, released, not started" '[ $rc = 0 ] && grep -q "^orchestration worker-release" "$T/state/calls" && ! grep -q "worker-start" "$T/state/calls" && printf "%s" "$out" | grep -q "slots: 3/3 busy, 1 queued"'

# no free port: task stays queued, exit 0
reset
printf '39201 #1 lead\n39202 #2 lead\n' >"$T/ledger/ports"
q "#7 lead" lead 7 -- --agent claude
out=$(NEXT start --ledger "$T/ledger" 2>&1); rc=$?
check "no port: exit 0, stays queued, nothing created" '[ $rc = 0 ] && [ -s "$T/ledger/queue" ] && ! grep -q "task-create" "$T/state/calls" && printf "%s" "$out" | grep -q "port: none free"'

# empty queue
reset
out=$(NEXT start --ledger "$T/ledger" 2>&1); rc=$?
check "empty queue: exit 0 with end-turn line" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "queue: empty" && printf "%s" "$out" | grep -q "^next: end your turn"'

# the skill dir itself at a path with a space (worker worktrees can live under such paths): re-run this suite from a copy
if [ -z "${WF_TEST_SPACED:-}" ]; then
  mkdir -p "$T/a b/skill"; cp "$DIR"/*.sh "$DIR/task-template.md" "$T/a b/skill/"
  sout=$(cd "$T" && WF_TEST_SPACED=1 PATH="$T/bin:$PATH" bash "$T/a b/skill/test-next.sh" 2>&1); rc=$?
  check "suite passes from a skill dir with a space" '[ $rc = 0 ]'
  [ $rc = 0 ] || printf "%s\n" "$sout" | sed "s/^/  spaced: /"
fi

# usage
NEXT settle --ledger "$T/ledger" >/dev/null 2>&1; rc=$?; check "settle without --dispatch exits 64" '[ $rc = 64 ]'
NEXT bogus >/dev/null 2>&1; rc=$?; check "unknown command exits 64" '[ $rc = 64 ]'

echo "next: $((n - fail))/$n passed"
[ $fail = 0 ]
