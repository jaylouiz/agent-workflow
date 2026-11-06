#!/usr/bin/env bash
# Global SessionStart hook (registered by install.sh): notices a newly installed Orca version that the workflow has
# not been reviewed against, writes the impact report (prepare.sh), and starts /orca-update-review in the session
# (initialUserMessage: Claude Code submits it as the first user turn). The skill itself asks before it changes
# anything. Cheap when nothing changed (one plist read); ~5 s once per new version. Never blocks a session: every
# failure exits 0.
#
# Every fresh session shows the user one status line (systemMessage: terminal only, no model context), so a quiet
# check is visibly a passing one: "reviewed, workflow setup up to date" or "review pending".
# Silent when: Orca is not installed (cloud sessions), the session is resumed or compacted, or a dispatched Orca
# worker meets a pending version. The review starts once per new version and day, only in an interactive session
# (CLAUDE_CODE_ENTRYPOINT=cli; `claude -p` and SDK runs get the status line and do not use up the day's start).
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/lib.sh"

input=$(cat 2>/dev/null || :)
case "$(printf '%s' "$input" | jq -r '.source // empty' 2>/dev/null)" in resume | compact) exit 0 ;; esac
to=$(installed_version)
[ -n "$to" ] || exit 0
from=$(reviewed_version)
status() { jq -n --arg m "Orca update check: $1" '{systemMessage: $m}' 2>/dev/null; exit 0; }
pending="Orca $to is new (reviewed: $from), workflow review pending: /orca-update-review"
[ "$from" = "$to" ] && status "Orca $to is reviewed, workflow setup up to date."

# A dispatched worker must not be sidetracked (same lookup as worker-done-stop.sh).
if [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && command -v jq >/dev/null 2>&1; then
  orca orchestration worker-list --json --full 2>/dev/null \
    | jq -e --arg h "$ORCA_TERMINAL_HANDLE" '[.result.workers[]? | select(.agentTerminalHandle == $h and .dispatchStatus == "dispatched")] | length > 0' >/dev/null 2>&1 \
    && exit 0
fi

mkdir -p "$UPDATES_DIR" 2>/dev/null || exit 0
report="$UPDATES_DIR/$to.md"
stamp="$UPDATES_DIR/$to.announced"
today=$(date +%F)
[ "$(cat "$stamp" 2>/dev/null)" = "$today" ] && status "$pending"
[ "${CLAUDE_CODE_ENTRYPOINT:-}" = cli ] || status "$pending"
echo "$today" >"$stamp"

# Prepared in the foreground (~5 s, once per new version): a detached job does not survive the hook runner
# ending the hook's process group. Capped at 20 s; on failure the skill runs prepare.sh itself.
if [ -s "$report" ] || perl -e 'alarm 20; exec @ARGV' bash "$DIR/prepare.sh" "$from" "$to" --out "$report" \
     >"$UPDATES_DIR/$to.log" 2>&1 </dev/null; then
  state="ready at $report"
else
  state="not prepared (see $UPDATES_DIR/$to.log); the skill runs prepare.sh first"
fi

start="Run /orca-update-review: Orca was updated $from -> $to and agent-workflow has not been reviewed against it. The impact report is $state. (Started automatically by the SessionStart Orca update check; after the review, continue with whatever I ask next.)"
jq -n --arg u "$start" --arg m "Orca update check: Orca $to is new (reviewed: $from), starting /orca-update-review" \
  '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", initialUserMessage: $u}}' 2>/dev/null || exit 0
