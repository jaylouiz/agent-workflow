#!/usr/bin/env bash
# Stop hook, registered in the worker-stage skills' frontmatter (build/specify/design-gh-issue). A dispatched Orca
# worker must settle its dispatch (`worker_done`) before it ends; this blocks the stop once (exit 2) when it has not.
#
# Orca sets only ORCA_TERMINAL_HANDLE in the session env, so the dispatch comes from
# `orca orchestration worker-list --json --full` (agentTerminalHandle == handle, dispatchStatus == dispatched).
# Allowed to stop (exit 0): no handle / no dispatched row (ordinary terminal, coordinator, settled worker);
# stop_hook_active (already blocked once); the transcript sent worker_done for that dispatch; the worker waits for
# an answer (an `orchestration ask` or `--type escalation` send after the last user message); any tool or
# parse problem (fail open: a hook bug must never trap a session).
# A worker that ends its turn to wait on its own run_in_background job is not detected: the one-time block message
# tells it to end the turn again instead of sending worker_done early (the second stop passes).
set -uo pipefail

input=$(cat)
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v orca >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = true ] && exit 0
handle=${ORCA_TERMINAL_HANDLE:-}
[ -n "$handle" ] || exit 0

row=$(orca orchestration worker-list --json --full 2>/dev/null | jq -r --arg h "$handle" '
  [.result.workers[]? | select(.agentTerminalHandle == $h and .dispatchStatus == "dispatched")] | first // empty
  | "\(.dispatchId)\t\(.taskId)"' 2>/dev/null) || exit 0
[ -n "$row" ] || exit 0
dispatch=${row%%$'\t'*}; task=${row#*$'\t'}
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

# Exit 0 if settled or waiting, 3 if neither (blocks). Any python error also fails open.
DISPATCH=$dispatch python3 -I -c '
import json, os, sys
d = os.environ["DISPATCH"]
last_user = -1
cmds = []  # (entry index, command) of every Bash call
for i, line in enumerate(open(sys.argv[1], encoding="utf-8", errors="replace")):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    c = (e.get("message") or {}).get("content")
    if e.get("type") == "user":
        if isinstance(c, str) or any(isinstance(b, dict) and b.get("type") == "text" for b in (c or [])):
            last_user = i
    elif e.get("type") == "assistant" and isinstance(c, list):
        for b in c:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                cmds.append((i, str((b.get("input") or {}).get("command", ""))))
for i, cmd in cmds:
    if "orchestration send" in cmd and "worker_done" in cmd and d in cmd:
        sys.exit(0)
    if i > last_user and "orchestration" in cmd and ("orchestration ask" in cmd or ("orchestration send" in cmd and "--type escalation" in cmd)):
        sys.exit(0)
sys.exit(3)
' "$transcript" 2>/dev/null
rc=$?
[ $rc = 3 ] || exit 0
cat >&2 <<MSG
worker-done-stop.sh: you are the dispatched worker for task $task (dispatch $dispatch) and have not settled it, so you cannot end yet.
If your work is finished, send exactly once: orca orchestration send --from <your orca_session_id> --type worker_done --subject "<status>" --body "<what you did, found, what is left>" --task-id $task --dispatch-id $dispatch --outcome succeeded|failed
(full command and your session id are in your task preamble).
If you are only waiting (on your own run_in_background job such as an E2E run, or on an ask/escalation answer), the work is not done: do NOT send worker_done yet, just end your turn again. This block fires once per stop, so the second stop passes and Orca wakes you when the job or the answer arrives.
MSG
exit 2
