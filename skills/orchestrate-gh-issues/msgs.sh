#!/usr/bin/env bash
# Compact view of an `orca orchestration check --json` result (the check an Orca wake names; reading acks it).
# Usage: orca orchestration check --json [--run <id>] | msgs.sh   or   msgs.sh <saved output file>
# Prints the delivery id, then one line per non-heartbeat message (pre-V3 heartbeats are only counted).
set -euo pipefail
input=$(cat "${1:-/dev/stdin}")
# The output can hold several JSON documents plus a harness "[exited ...]" line; use the last delivery, else the last error.
printf '%s\n' "$input" | sed -n '/^{/,$p' | grep -v '^\[exited with code' | jq -cs '
  ([ .[] | objects | select(.ok == false) | "error \(.error.code): \(.error.message)" ] | last) as $err
  | [ .[] | objects | .result? | objects | select(.deliveryId != null or .messages != null) ] | last
  | if . == null then ($err // "no delivery") else
      "delivery \(.deliveryId // "-") heartbeats=\([.messages[] | select(.type == "heartbeat")] | length)",
      (.messages[] | select(.type != "heartbeat")
        | "\(.type) \(.id) \((.payload // {}) | (if type == "string" then fromjson else . end) | "task=\(.taskId // "-") dispatch=\(.dispatchId // "-") outcome=\(.outcome // "-") report=\(.reportPath // "-")")\n  \(.subject // ""): \(.body // "" | .[0:5000])")
    end' -r 2>/dev/null || { echo "unparseable output; tail:"; printf '%s\n' "$input" | tail -c 800; }
