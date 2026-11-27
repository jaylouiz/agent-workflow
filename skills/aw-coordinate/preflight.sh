#!/usr/bin/env bash
# Preflight of /aw-coordinate (SKILL.md section 0, step 1): which runner drives the stages. With the `orca` CLI it is
# Orca; without it (or when asked) the skill runs in subagent mode (subagent-mode.md). Run: preflight.sh [--subagents]
# Exit: 0 Orca mode (prints nothing, or one warning line when Orca is older than ORCA_MIN of bin/lib.sh: the run
# goes on), 69 subagent mode: no `orca` on PATH, or --subagents (the user asked for it). The line on stdout says
# which and is passed on to the user. 64 usage.
set -u
MODE='subagent mode: the stages run as Claude Code subagents, each in a git worktree of its own. Go on with subagent-mode.md in this skill'"'"'s directory.'
case "${1:-}" in
  "") ;;
  --subagents) echo "Asked for $MODE"; exit 69 ;;
  *) echo "preflight.sh: unknown argument: $1 (usage: preflight.sh [--subagents])" >&2; exit 64 ;;
esac
if command -v orca >/dev/null 2>&1; then
  SRC=${BASH_SOURCE[0]}; case $SRC in */*) SRC=${SRC%/*} ;; *) SRC=. ;; esac # no dirname: the PATH may be bare
  LIB="$SRC/../../bin/lib.sh"
  if [ -f "$LIB" ]; then
    # shellcheck source=../../bin/lib.sh
    . "$LIB"
    note=$(wf_orca_note) || note=""
    [ -z "$note" ] || echo "Warning: $note"
  fi
  exit 0
fi
echo "No \`orca\` on PATH (https://github.com/stablyai/orca is optional): $MODE"
exit 69
