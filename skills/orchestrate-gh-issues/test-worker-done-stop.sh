#!/usr/bin/env bash
# Tests for worker-done-stop.sh (Stop hook) with a stubbed `orca` and synthetic transcripts.
# Run: bash skills/orchestrate-gh-issues/test-worker-done-stop.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# Stub orca: `worker-list` prints $T/workers.json (or fails when $T/orca_fail exists).
cat >"$T/bin/orca" <<'EOF2'
#!/usr/bin/env bash
[ -f "$STUB_DIR/orca_fail" ] && exit 1
[ "$2" = worker-list ] && cat "$STUB_DIR/workers.json"
EOF2
chmod +x "$T/bin/orca"
export PATH="$T/bin:$PATH" STUB_DIR="$T"
H=structworker_me
D=ctx_mine1234
workers() { # workers <status of my dispatch>
  cat >"$T/workers.json" <<EOF2
{"ok":true,"result":{"workers":[
 {"dispatchId":"ctx_other0001","taskId":"task_o","dispatchStatus":"dispatched","agentTerminalHandle":"structworker_other"},
 {"dispatchId":"$D","taskId":"task_me","dispatchStatus":"$1","agentTerminalHandle":"$H"}]}}
EOF2
}
# Transcript lines: u = user text, r = tool result, b <cmd> = assistant Bash call, x = unrelated blob entry.
tr_line() {
  case "$1" in
    u) jq -nc '{type:"user",message:{role:"user",content:[{type:"text",text:"go"}]}}' ;;
    r) jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",content:"ok"}]}}' ;;
    b) jq -nc --arg c "$2" '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' ;;
    x) jq -nc '{type:"api-request-blob",role:"user"}' ;;
  esac
}
WD="orca orchestration send --from s --type worker_done --subject x --body y --task-id task_me --dispatch-id $D --outcome succeeded"
ASK='orca orchestration ask --from s --question "which?"'
ESC="orca orchestration send --from s --type escalation --subject Blocked --body z --task-id task_me --dispatch-id $D"

fail=0; n=0
# run <label> <want exit> <transcript spec...>   (env: HANDLE, ACTIVE=true|false)
run() {
  local label=$1 want=$2; shift 2
  : >"$T/tr.jsonl"
  while [ $# -gt 0 ]; do
    case "$1" in b) tr_line b "$2" >>"$T/tr.jsonl"; shift 2 ;; *) tr_line "$1" >>"$T/tr.jsonl"; shift ;; esac
  done
  local out got
  out=$(jq -n --arg t "$T/tr.jsonl" --argjson a "${ACTIVE:-false}" '{hook_event_name:"Stop",stop_hook_active:$a,transcript_path:$t}' \
    | ORCA_TERMINAL_HANDLE="${HANDLE-$H}" bash "$DIR/worker-done-stop.sh" 2>&1)
  got=$?; n=$((n + 1))
  [ "$got" = "$want" ] || { fail=$((fail + 1)); echo "FAIL [$label] want $want got $got: $out"; }
  LAST_OUT=$out
}

workers dispatched
run "no worker_done: blocked" 2 u b "git status" r x
case $LAST_OUT in *task_me*"$D"*) ;; *) fail=$((fail + 1)); n=$((n + 1)); echo "FAIL [message names task and dispatch]: $LAST_OUT" ;; esac
case $LAST_OUT in *run_in_background*"end your turn again"*) ;; *) fail=$((fail + 1)); n=$((n + 1)); echo "FAIL [message tells a waiting worker to end the turn again]: $LAST_OUT" ;; esac
run "waiting on own background job: blocked once, then the second stop passes" 2 u b "pnpm e2e" r
ACTIVE=true run "waiting on own background job, second stop: allowed" 0 u b "pnpm e2e" r
run "worker_done sent: allowed" 0 u b "$WD" r
run "worker_done for another dispatch: blocked" 2 u b "${WD//$D/ctx_older9999}" r
run "pending ask: allowed" 0 u b "$ASK" r
run "pending escalation: allowed" 0 u b "$ESC" r
run "ask answered by a new user message: blocked again" 2 u b "$ASK" r u b "git log" r
run "ask, answer, worker_done: allowed" 0 u b "$ASK" r u b "$WD" r
ACTIVE=true run "stop_hook_active: allowed" 0 u b "git status" r
HANDLE="" run "no handle (ordinary terminal): allowed" 0 u b "git status" r
HANDLE=structworker_coordinator run "handle without a dispatch row: allowed" 0 u r
workers completed
run "dispatch already settled: allowed" 0 u b "git status" r
workers dispatched
: >"$T/orca_fail"; run "worker-list fails: fail open" 0 u r; rm -f "$T/orca_fail"
echo "not json" >"$T/workers.json"; run "unreadable worker-list: fail open" 0 u r
workers dispatched

# unreadable transcript, missing jq/orca
out=$(jq -n '{stop_hook_active:false,transcript_path:"/nonexistent"}' | ORCA_TERMINAL_HANDLE=$H bash "$DIR/worker-done-stop.sh" 2>&1); got=$?; n=$((n + 1))
[ $got = 0 ] || { fail=$((fail + 1)); echo "FAIL [missing transcript: fail open] got $got"; }
out=$(echo '{}' | PATH="/usr/bin:/bin" ORCA_TERMINAL_HANDLE=$H bash "$DIR/worker-done-stop.sh" 2>&1); got=$?; n=$((n + 1))
[ $got = 0 ] || { fail=$((fail + 1)); echo "FAIL [no orca on PATH: fail open] got $got: $out"; }

# registered as Stop hook next to guard.sh in the worker-stage skills
for s in build-gh-issue specify-gh-issue design-gh-issue; do
  n=$((n + 1))
  awk '/^---$/{c++} c==1' "$DIR/../$s/SKILL.md" | grep -q 'orchestrate-gh-issues/worker-done-stop.sh' || { fail=$((fail + 1)); echo "FAIL [$s registers worker-done-stop.sh]"; }
done

echo "worker-done-stop: $((n - fail))/$n passed"
[ $fail = 0 ]
