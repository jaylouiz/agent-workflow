#!/usr/bin/env bash
# Compact view of an `orca orchestration check --json` result (the check an Orca wake names; reading acks it).
# Usage: orca orchestration check --json [--run <id>] | msgs.sh   or   msgs.sh <saved output file>
# Prints the delivery id, then one line per non-heartbeat message (pre-V3 heartbeats are only counted); a finished
# worker's worker_done gets Orca's `follow_up` (1.4.255+) as a `next:` line, the command for more work on it.
set -euo pipefail
input=$(cat "${1:-/dev/stdin}")
# The output can hold several JSON documents plus a harness "[exited ...]" line; use the last delivery, else the last error.
printf '%s\n' "$input" | sed -n '/^{/,$p' | grep -v '^\[exited with code' | jq -cs '
  ([ .[] | objects | select(.ok == false) | "error \(.error.code): \(.error.message)" ] | last) as $err
  | [ .[] | objects | .result? | objects | select(.deliveryId != null or .messages != null) ] | last
  | if . == null then ($err // "no delivery") else
      "delivery \(.deliveryId // "-") heartbeats=\([.messages[] | select(.type == "heartbeat")] | length)",
      (.messages[] | select(.type != "heartbeat")
        | "\(.type) \(.id) \((.payload // {}) | (if type == "string" then fromjson else . end) | "task=\(.taskId // "-") dispatch=\(.dispatchId // "-") outcome=\(.outcome // "-") report=\(.reportPath // "-")")\n  \(.subject // ""): \(.body // "" | .[0:5000])"
          + (.follow_up // null | if . == null then "" else "\n  next: " + (
              if .kind == "send" then "send --to dispatch:\(.dispatchId)\(if .active then " (follow-up running)" else "" end)"
              elif .kind == "worker_start_on" then "worker-start --on \(.server) (paired host)"
              elif .kind == "worker_start" then "worker-start (no worker left)"
              else tojson end) end))
    end' -r 2>/dev/null || { echo "unparseable output; tail:"; printf '%s\n' "$input" | tail -c 800; }
