#!/usr/bin/env bash
# Print a complete Orca task spec for one issue and stage, from task-template.md (orchestrate-gh-issues section 4).
#
#   spec.sh <lead|design|review|delta-review|fix> <issue> --ledger <run ledger dir>
#           [--tier <text>] [--model <alias>: default the settings' WF_MODEL_STRONG for review and delta-review, else WF_MODEL_DEFAULT] [--branch <b>] [--pr <n>] [--wt <path>] [--extra <file>] [--batch <n,m,...>: lead only, the other issues of a batch] [--no-port] [--interactive]
#   spec.sh release-port <port> --ledger <dir>     drop a reservation when its worker settled
#
# Assigns the first port in the project's WF_PORTS (.claude/issue-workflow.sh) that is neither listening nor
# reserved in <ledger>/ports, records it there ("<port> #<n> <stage>") and ends the spec with `PORT=<port>`.
# Pass --no-port only for stages that start no dev server (delta-review, or a review of a PR with no UI or layout change); a review of a UI or page-layout PR keeps its port so the reviewer can render findings.
# Exit: 3 no free port, 64 usage.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"
die() { echo "spec.sh: $*" >&2; exit 64; }

stage=${1:-}; n=${2:-}
[ -n "$stage" ] && [ -n "$n" ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
shift 2
tier="Standard - default"; model=""; branch=""; pr=""; wt=""; ledger=""; extra=""; want_port=1; interactive=0; batch=""
while [ $# -gt 0 ]; do
  case "$1" in --no-port|--interactive) ;; --*) case "${2-}" in ""|--*) die "$1 needs a value, got '${2-}' (an empty unquoted variable is dropped by zsh)" ;; esac ;; esac
  case "$1" in
    --tier) tier=${2:?}; shift 2 ;;
    --model) model=${2:?}; shift 2 ;;
    --branch) branch=${2:?}; shift 2 ;;
    --pr) pr=${2:?}; shift 2 ;;
    --wt) wt=${2:?}; shift 2 ;;
    --ledger) ledger=${2:?}; shift 2 ;;
    --extra) [ -r "$2" ] || die "--extra file not readable: $2 (a spec without its notes would go out silently)"; extra="$extra $2"; shift 2 ;;
    --batch) batch=${2:?}; shift 2 ;;
    --no-port) want_port=0; shift ;;
    --interactive) interactive=1; shift ;;
    *) die "unknown flag $1" ;;
  esac
done
[ -n "$ledger" ] || die "--ledger <run ledger dir> is required (ledger.sh dir <run_id>)"
mkdir -p "$ledger"; touch "$ledger/ports"
# absolute: a worker in a worktree has .git as a file, so a relative .git/agent-ledgers path breaks there
ledger=$(cd "$ledger" && pwd -P)

if [ "$stage" = release-port ]; then
  grep -v "^$n " "$ledger/ports" >"$ledger/ports.tmp"; mv "$ledger/ports.tmp" "$ledger/ports"; exit 0
fi
case "$stage" in lead|design|review|delta-review|fix) ;; *) die "unknown stage '$stage'" ;; esac
grep -q "<!-- stage:$stage -->" "$DIR/task-template.md" || die "no template block for $stage"

wf_load
if [ -z "$model" ]; then case $stage in review|delta-review) model=$WF_MODEL_STRONG ;; *) model=$WF_MODEL_DEFAULT ;; esac; fi
port=""
if [ "$want_port" = 1 ]; then
  lo=${WF_PORTS%-*}; hi=${WF_PORTS#*-}
  for ((p = lo; p <= hi; p++)); do
    grep -q "^$p " "$ledger/ports" && continue
    lsof -ti "tcp:$p" -sTCP:LISTEN >/dev/null 2>&1 && continue
    port=$p; break
  done
  [ -n "$port" ] || { echo "spec.sh: no free port in $WF_PORTS (reservations: $ledger/ports)" >&2; exit 3; }
  echo "$port #$n $stage" >>"$ledger/ports"
fi

title=$(gh issue view "$n" --json title -q .title 2>/dev/null) || title="(title unavailable)"
if [ -z "$branch" ]; then
  case "$stage" in
    design) branch="proto/$n-<slug>" ;;
    *) branch="the profile's branch name for #$n (e.g. fix/$n-<slug>)" ;;
  esac
fi
# decide.sh gets the repo from WF_REPO, so a worker running it from /tmp or a scratch dir still posts to the right issue
# from the ledger dir (inside the run repo's .git), not the caller's cwd: a cwd in the skill dir read agent-workflow's origin
repo=$(cd "$ledger" && wf_repo_slug 2>/dev/null) || repo=$(wf_repo_slug) || repo=""
decide="~/.claude/skills/orchestrate-gh-issues/decide.sh"
[ -z "$repo" ] || decide="WF_REPO=$repo $decide"
if [ $interactive = 1 ]; then
  questions='Interactive issue: put every question for the user (Specify approaches with your recommendation, any open choice) through the preamble'"'"'s `ask` and use the reply; the coordinator relays it to the user. One-way choices still park.'
else
  questions="No questions to the user."
fi

TITLE=$title N=$n STAGE=$stage TIER=$tier MODEL=$model BRANCH=$branch PR=${pr:-"(see issue)"} WT=${wt:-"(this worktree)"} \
MODEL_STRONG=$WF_MODEL_STRONG MODEL_FAST=$WF_MODEL_FAST PORT=${port:-"(none: no dev server for this stage)"} LEDGER=$ledger SKILLDIR="~/.claude/skills/orchestrate-gh-issues" DECIDE="$decide" \
QUESTIONS=$questions STAGEKEY=$stage python3 -I -c '
import os, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
def block(name):
    m = re.search(r"<!-- %s -->\n(.*?)<!-- /%s -->" % (re.escape(name), name.split(":")[0]), t, re.S)
    return m.group(1)
out = block("common") + block("stage:" + os.environ["STAGEKEY"])
out = re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: os.environ.get(m.group(1), m.group(0)), out)
sys.stdout.write(out)
' "$DIR/task-template.md"
if [ -n "$batch" ]; then
  [ "$stage" = lead ] || die "--batch is for the lead stage only"
  b=$(printf "%s" "$batch" | tr ',' ' ' | sed 's/[^0-9 ]//g; s/ \{1,\}/, #/g; s/^/#/')
  echo "BATCH: this lead owns #$n and also $b, one branch, one PR with a \`Closes\` line for each. Run every step above for each issue in turn (Specify if needed, Build); done only when the PR closes all of them. Skipping one is a failed task."
fi
[ -n "$extra" ] && { echo "Notes:"; for x in $extra; do cat "$x"; echo; done; }
[ -n "$port" ] && echo "PORT=$port"
exit 0
