#!/usr/bin/env bash
# Friction ledger for agent sessions: one line per thing that cost time, written the moment it happens,
# so the end-of-session retro does not depend on memory (or on context that compaction dropped).
#
#   ledger.sh [-f FILE] add <kind> <minutes> <target> "<what | suspected cause | fix idea>"
#   ledger.sh [-f FILE] check [-l LABEL] -- <command...>   run it, pass output and exit code through, log duration
#   ledger.sh [-f FILE] path          print the ledger file
#   ledger.sh dir [NAME]              print (and create) the shared ledger dir, e.g. one per orchestration run
#   ledger.sh kinds                   list entry kinds
#   ledger.sh due [PATH...]           is a retro worth running? exit 0 = due, 1 = skip (the ledgers stay for the next one)
#   ledger.sh close [PATH...]         after a retro: move every ledger with entries into processed/<date>/ (kept 30 days)
#
# Default FILE: <git common dir>/agent-ledgers/<branch>-<session>.md (outside the work tree, survives worktree
# removal, visible to every worktree of the repo). Orchestrated workers get an explicit -f from their spec.
set -uo pipefail

KINDS='rediscovery         worked out something that should have been written down
wrong-instruction   an instruction (skill, CLAUDE.md, profile, spec) was wrong or outdated
missing-instruction needed a rule or fact nobody wrote down
rule-overload       instructions conflicted, a rule was buried and missed, or there were too many to follow
spec-gap            the input (issue spec, brief, task spec) was unclear or incomplete: name the stage that wrote it
tool-failure        a command, hook, tool or test failed or flaked for reasons outside the change
overkill            a check or step cost more than the change'"'"'s scope justified
escaped             a defect got past a stage or check that should have caught it: name both
wait                blocked: permission prompt, server, coordinator, user
back-and-forth      a round trip (ask, fix round, rework) better input would have avoided
win                 something that saved real time and must survive a cleanup'

die() { echo "ledger.sh: $*" >&2; exit 64; }

base_dir() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common="${TMPDIR:-/tmp}"
  printf '%s/agent-ledgers' "$common"
}

file=""
if [ "${1:-}" = "-f" ]; then file=${2:?-f needs a path}; shift 2; fi
if [ -z "$file" ]; then
  branch=$(git branch --show-current 2>/dev/null | tr '/' '-')
  sid=${CLAUDE_CODE_SESSION_ID:-$PPID}
  file="$(base_dir)/${branch:-detached}-${sid:0:8}.md"
fi

append() {
  mkdir -p "$(dirname "$file")"
  [ -s "$file" ] || printf '# ledger %s (%s, %s)\n\n' "$(basename "$file" .md)" "$(git branch --show-current 2>/dev/null || echo -)" "$(date +%F)" >"$file"
  printf '%s\n' "$1" >>"$file"
}

cmd=${1:-}; shift || true
case "$cmd" in
  add)
    [ $# -eq 4 ] || die 'usage: add <kind> <minutes> <target> "<what | cause | fix idea>"'
    printf '%s\n' "$KINDS" | awk '{print $1}' | grep -qx -- "$1" || die "unknown kind '$1'; one of: $(printf '%s\n' "$KINDS" | awk '{print $1}' | paste -sd' ' -)"
    append "- [$1] ${2}m -> $3: $4 ($(date +%H:%M))"
    ;;
  check)
    label=""
    if [ "${1:-}" = "-l" ]; then label=${2:?-l needs a label}; shift 2; fi
    [ "${1:-}" = "--" ] && shift
    [ $# -gt 0 ] || die 'usage: check [-l LABEL] -- <command...>'
    start=$(date +%s)
    "$@"; rc=$?
    secs=$(( $(date +%s) - start ))
    append "- [check] ${label:-$*}: $((secs / 60))m$((secs % 60))s exit=$rc ($(date +%H:%M))"
    exit $rc
    ;;
  path) printf '%s\n' "$file" ;;
  dir)
    d="$(base_dir)${1:+/$1}"; mkdir -p "$d" && printf '%s\n' "$d" ;;
  kinds) printf '%s\n' "$KINDS" ;;
  due)
    # Due when the unprocessed ledgers hold RETRO_MIN_MINUTES (default 5) of friction, or any entry whose kind
    # means an instruction or a check was wrong (escaped, wrong-instruction). Wins and [check] lines do not count.
    # PATH: ledger files or dirs (searched two levels deep); default: every unprocessed ledger of this repository.
    [ $# -gt 0 ] || set -- "$(base_dir)"
    lines=$(for p in "$@"; do
      if [ -d "$p" ]; then find "$p" -maxdepth 2 -name '*.md' -not -path '*/processed/*' -exec cat {} + 2>/dev/null; elif [ -f "$p" ]; then cat "$p"; fi
    done | grep -E '^- \[[a-z-]+\] [0-9]+m -> ' | grep -v '^- \[win\]')
    entries=$(printf '%s' "$lines" | grep -c . || true)
    mins=$(printf '%s\n' "$lines" | sed -n 's/^- \[[a-z-]*\] \([0-9]*\)m -> .*/\1/p' | awk '{s+=$1} END {print s+0}')
    strong=$(printf '%s\n' "$lines" | grep -cE '^- \[(escaped|wrong-instruction)\]' || true)
    if [ "$mins" -ge "${RETRO_MIN_MINUTES:-5}" ] || [ "$strong" -gt 0 ]; then
      echo "retro due: $entries entries, $mins min, $strong escaped or wrong-instruction"; exit 0
    fi
    echo "retro skipped: $entries entries, $mins min, none escaped or wrong-instruction (ledgers kept for the next retro)"; exit 1
    ;;
  close)
    # Processed ledgers leave the scan without being destroyed: a ledger that stays behind would keep `due` true
    # for ever, and a deleted one cannot be checked again. Only files that hold entries move; specs, receipts and
    # notes in a run dir stay where they are.
    [ $# -gt 0 ] || set -- "$(base_dir)"
    dest="$(base_dir)/processed/$(date +%F)"; moved=0
    for p in "$@"; do
      if [ -d "$p" ]; then find "$p" -maxdepth 2 -name '*.md' -not -path '*/processed/*' 2>/dev/null; elif [ -f "$p" ]; then printf '%s\n' "$p"; fi
    done | while IFS= read -r f; do
      grep -qE '^- \[[a-z-]+\] ' "$f" 2>/dev/null || continue
      mkdir -p "$dest" && mv "$f" "$dest/$(basename "$(dirname "$f")")-$(basename "$f")" && echo "closed $f"
    done
    find "$(base_dir)/processed" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -r {} + 2>/dev/null
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$cmd" ] || exit 64 ;;
esac
