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
  task-list) if [ -f "$S/tasks" ]; then cat "$S/tasks"; else echo '{"ok":true,"result":{"tasks":[]}}'; fi ;;
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
reset() { : >"$T/state/calls"; rm -f "$T/state/fail_start" "$T/state/fail_create" "$T/state/tasks"; echo completed >"$T/state/dispatch_status"; echo 0 >"$T/state/active"; rm -rf "$T/ledger"; mkdir -p "$T/ledger"; }
NEXT() { bash "$DIR/next.sh" "$@"; }
q() { NEXT queue --ledger "$T/ledger" "$@" >/dev/null; }

# happy path: settle one worker, port freed, next task started (a legacy --delivery is ignored)
reset
echo "39201 #4 lead" >"$T/ledger/ports"
q "#7 lead" lead 7 --tier Standard -- --agent claude --model sonnet --effort high --worktree new-top-level --name fix-7-x
out=$(NEXT settle --dispatch ctx_aaa111 --delivery d1 --port 39201 --ledger "$T/ledger" --run run_x 2>"$T/err"); rc=$?
calls=$(cat "$T/state/calls")
check "happy: exit 0" '[ $rc = 0 ]'
check "happy: order proof, release, slots, create, start (no ack)" '[ "$(printf "%s\n" "$calls" | awk "{print \$2}" | tr "\n" " ")" = "worker-show worker-release worker-list task-list task-create worker-start " ]'
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

# #11 item 1: a non-terminal Task of the Run that names the issue blocks a second start
reset
tasks() { printf '{"ok":true,"result":{"tasks":[%s]}}' "$1" >"$T/state/tasks"; }
q "#7 lead" lead 7 -- --agent claude
q "#8 lead" lead 8 -- --agent claude
tasks '{"id":"task_other","task_title":"build 7 (other session)","status":"dispatched","spec":"Issue #7: Fix. Stage: lead."},{"id":"task_x","task_title":"#70 lead","status":"dispatched","spec":"Issue #70: y"}'
out=$(NEXT start --ledger "$T/ledger" 2>"$T/err"); rc=$?
check "duplicate: exit 1, names Task and --force" '[ $rc = 1 ] && grep -q "stage duplicate" "$T/err" && grep -q "task_other (dispatched)" "$T/err" && grep -q -- "--force" "$T/err"'
check "duplicate: #7 not created or started, #8 (and #70 is no match) goes on" '[ "$(grep -c "^orchestration task-create" "$T/state/calls")" = 1 ] && grep -q "^started: #8 lead" <<<"$out"'
check "duplicate: recorded, no port held, queue drained" 'grep -q "^#7 lead.*duplicate of task_other" "$T/ledger/failed-starts" && ! grep -q "#7 lead" "$T/ledger/ports" && [ ! -s "$T/ledger/queue" ]'
check "duplicate: end-turn line still printed" 'printf "%s" "$out" | grep -q "^next: end your turn"'
reset; tasks '{"id":"task_f","task_title":"#8 lead (follow-up to #7)","status":"dispatched","spec":"x"},{"id":"task_b","task_title":"#3+#7 lead (batch)","status":"dispatched","spec":"x"}'
q "#7 lead" lead 7 -- --agent claude
out=$(NEXT start --ledger "$T/ledger" 2>"$T/err"); rc=$?
check "a batch title #3+#7 blocks #7, the follow-up title does not" '[ $rc = 1 ] && grep -q "task_b" "$T/err" && ! grep -q "task_f" "$T/err"'
reset; tasks '{"id":"task_dep","task_title":"#8 lead","status":"dispatched","spec":"Issue #8: depends on #7 and #17."}'
q "#7 lead" lead 7 -- --agent claude
out=$(NEXT start --ledger "$T/ledger" 2>&1); rc=$?
check "a Task that only mentions #7 in its spec text does not block #7" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "^started: #7 lead"'
NEXT watch --dispatch ctx_aaa111 --interval abc >/dev/null 2>&1; rc=$?; check "watch rejects a non-numeric interval (64)" '[ $rc = 64 ]'
reset; tasks '{"id":"task_old","task_title":"#7 lead","status":"completed","spec":"Issue #7: Fix."}'
q "#7 lead" lead 7 -- --agent claude
out=$(NEXT start --ledger "$T/ledger" 2>&1); rc=$?
check "terminal Task of the same issue does not block (retry)" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "^started: #7 lead"'
reset; tasks '{"id":"task_live","task_title":"#7 lead","status":"dispatched","spec":""}'
q "#7 lead" lead 7 -- --agent claude
out=$(NEXT start --ledger "$T/ledger" --force 2>&1); rc=$?
check "--force starts anyway" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "^started: #7 lead"'
reset; echo 'not json' >"$T/state/tasks"
q "#7 lead" lead 7 -- --agent claude
NEXT start --ledger "$T/ledger" >/dev/null 2>"$T/err"; rc=$?
check "unreadable task-list fails closed, nothing created" '[ $rc = 1 ] && grep -q "stage duplicate failed" "$T/err" && ! grep -q "task-create" "$T/state/calls"'

# #11 item 3: a missing --extra file is refused at queue time
reset
NEXT queue --ledger "$T/ledger" "#7 lead" lead 7 --extra "$T/nope.md" >/dev/null 2>"$T/err"; rc=$?
check "queue rejects a missing --extra file" '[ $rc = 64 ] && grep -q "not readable" "$T/err" && [ ! -s "$T/ledger/queue" ]'
echo notes >"$T/notes.md"
NEXT queue --ledger "$T/ledger" "#7 lead" lead 7 --extra "$T/notes.md" >/dev/null 2>&1; rc=$?
check "queue accepts a readable --extra file" '[ $rc = 0 ] && [ -s "$T/ledger/queue" ]'

# #11 item 2: watch polls worker-show, never takes mail
reset; echo dispatched >"$T/state/dispatch_status"
out=$(NEXT watch --dispatch ctx_aaa111 --interval 0 --max-secs 1 2>&1); rc=$?
check "watch: unchanged after --max-secs exits 2" '[ $rc = 2 ] && printf "%s" "$out" | grep -q "^unchanged: ctx_aaa111"'
check "watch: reads worker-show only (no check)" 'grep -q "^orchestration worker-show" "$T/state/calls" && ! grep -q "^orchestration check" "$T/state/calls"'
echo completed >"$T/state/dispatch_status"
out=$(NEXT watch --dispatch ctx_aaa111 --interval 0 2>&1); rc=$?
check "watch: already settled reports at once" '[ $rc = 0 ] && [ "$out" = "changed: ctx_aaa111 completed" ]'
# a change between polls: the stub flips the status after the first call
echo dispatched >"$T/state/dispatch_status"
( sleep 1; echo failed >"$T/state/dispatch_status" ) &
out=$(NEXT watch --dispatch ctx_aaa111 --interval 1 --max-secs 20 2>&1); rc=$?; wait
check "watch: a status change exits 0" '[ $rc = 0 ] && [ "$out" = "changed: ctx_aaa111 failed" ]'
NEXT watch >/dev/null 2>&1; rc=$?; check "watch without --dispatch exits 64" '[ $rc = 64 ]'

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
