#!/usr/bin/env bash
# Create the agent-workflow labels in the current repo (gh label create --force: creates or updates name, colour and
# description). The lane, phase and marker labels match what the skills create on first use; the hold labels come
# from the repo's WF_HOLD_LABELS (.claude/issue-workflow.sh; on-hold is always one of them).
#
#   labels.sh [--dry-run]    --dry-run prints the gh commands instead of running them
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../bin/lib.sh
. "$DIR/../../bin/lib.sh"
DRY=0
case "${1:-}" in --dry-run) DRY=1 ;; "") ;; *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;; esac
wf_load

LABELS="needs-design|0E8A16|UX direction open: prototype or sketch before spec
needs-spec|C2E0C6|Rough idea, spec not written yet
ready|0052CC|Spec confirmed, ready to build
phase:design|5319E7|Phase UX Design: a design round is running or waits on feedback
phase:build|1D76DB|Phase Build: specify, build or review running, or PR open
ux-impact|C5DEF5|Changes what the user sees: Look after Done
needs-decision|D93F0B|Parked: waits for a user decision
agent-decided|FBCA04|Has agent decisions the user has not reviewed
inbox|EDEDED|Unsorted out-of-scope finding, needs triage
needs-direction|D4C5F9|Direction open: the user sets it"
for h in $WF_HOLD_LABELS; do LABELS="$LABELS
$h|B60205|Hold: stops the pipeline (issue-workflow config)"; done

fail=0
while IFS='|' read -r name color desc; do
  if [ "$DRY" = 1 ]; then
    printf 'gh label create %q --force --color %s --description %q\n' "$name" "$color" "$desc"
  else
    gh label create "$name" --force --color "$color" --description "$desc" >/dev/null 2>&1 || { echo "labels.sh: could not create $name" >&2; fail=1; }
  fi
done <<<"$LABELS"
exit $fail
