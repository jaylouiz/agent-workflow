#!/usr/bin/env bash
# Coordinator helper: settle a finished worker and start the next queued task in ONE call (orchestrate-gh-issues
# sections 2 and 6). Replaces the manual release / release-port / spec / task-create / worker-start sequence.
# Orca V3 (1.4.246+): reading mail with `check` acknowledges it and Orca wakes the coordinator, so there is no ack
# step and no waiter to re-arm; a legacy --delivery flag is accepted and ignored.
#
#   next.sh settle --dispatch <id> --ledger <dir> [--port <p>] [--run <run_id>] [--max <n>]
#        1 proof     worker-show: the dispatch must be completed or failed (a worker_done was accepted); else
#                    exit 2 and nothing is touched. Read the worker_done message (msgs.sh) before calling.
#        2 release   worker-release (idempotent; Orca would also close the worker ~2 min after worker_done)
#        3 port      spec.sh release-port <p> (with --port)
#        4 start     the queue, below
#   next.sh start  --ledger <dir> [--run <run_id>] [--max <n>]     only step 4 (first wave, or after queueing)
#   next.sh queue  --ledger <dir> "<task title>" <spec.sh args, without --ledger> [-- <worker-start args>]
#        append a runnable task, e.g.
#          next.sh queue --ledger L "#7 lead" lead 7 --tier Standard --model sonnet -- --agent claude --model sonnet \
#                  --worktree new-top-level --name fix-7-x
#        worker-start args default to `--agent claude`. Each arg is kept whole (spaces are fine, e.g. --tier "Fix - 3
#        mediums"); an arg must not contain a tab or newline (use --extra <file> for long text).
#        Queue only tasks whose dependencies are done: the queue order is the start order.
#        Title convention the duplicate guard reads: `#<n> <stage>`; a batch names every issue up front: `#9+#11 lead (batch)`.
#
#   next.sh watch  --dispatch <id> [--dispatch <id>...] [--interval <s>] [--max-secs <s>] [--run <run_id>]
#        fallback when this session gets no Orca wake (e.g. it runs as a background job): run it as a background
#        command; it polls worker-show (takes no mail) and exits 0 with `changed: <dispatch> <status>` when a dispatch
#        is no longer in the status it had at the first look (or already completed/failed then). Exit 2 `unchanged`
#        after --max-secs (default: until a change), 1 on an unreadable worker-show.
#   --force (start, settle): start a queued task although a non-terminal Task of the Run already names its issue.
#
# Step 5 starts queued tasks while a slot is free (dispatched workers in the Run < --max, default WF_MAX_WORKERS)
# and a port is free (spec.sh exit 3 leaves the task queued): spec.sh > <ledger>/<n>-<stage>.spec, task-create,
# worker-start. A queued task whose issue (`#<n>` leading the title, `#7+#8` batch titles included, or the spec's own `Issue #<n>` header) another
# non-terminal Task of the Run already names is skipped as `duplicate` (failed-starts, exit 1 at the end): a second
# coordinator, or a rerun, must not start a second lead. A failed step is never retried and never hidden: the task goes to <ledger>/failed-starts, the
# script exits 1 and names the stage (spec | task-create | start). A port reserved for a failed start stays
# reserved until you have checked `worker-list` (an outcome_unknown start may be running).
# Every run ends with the end-turn line: end your turn, Orca wakes you when a worker reports, asks or stops.
# Exit: 0 ok (also: queue empty, slots full, no free port), 1 stage failed or a duplicate skipped, 2 not settled, 64 usage.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

run=""
endturn() { echo "next: end your turn; Orca wakes you when a worker reports, asks or stops (never run check --wait)"; }
die() { echo "next.sh: $*" >&2; exit 64; }
fail() { # fail <stage> <message> [exit code]
  echo "next.sh: stage $1 failed: $2" >&2; endturn; exit "${3:-1}"
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
orca_o() { # orca_o <stage> <orchestration args...>: stdout in $TMP/out; fail the stage on a non-zero exit
  local stage=$1; shift
  orca orchestration "$@" >"$TMP/out" 2>"$TMP/err" || fail "$stage" "orca orchestration $1 exited non-zero: $(head -c 400 "$TMP/err" "$TMP/out" | tr '\n' ' ')"
}
run_flag() { [ -n "$run" ] && echo "--run $run"; return 0; }

cmd=${1:-}
[ -n "$cmd" ] || { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
shift

if [ "$cmd" = queue ]; then
  [ "${1:-}" = --ledger ] && [ -n "${2:-}" ] || die "queue: --ledger <dir> first"
  ledger=$2; shift 2
  title=${1:-}; [ -n "$title" ] || die "queue: task title missing"
  shift
  spec=(); start=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do spec+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  start=("$@")
  [ ${#spec[@]} -ge 2 ] || die "queue: spec.sh args need <stage> <issue>"
  for ((i = 0; i < ${#spec[@]}; i++)); do # a missing notes file now, not a silently note-less spec at the later start
    [ "${spec[i]}" = --extra ] && [ ! -r "${spec[i+1]:-}" ] && die "queue: --extra file not readable: ${spec[i+1]:-}"
  done
  [ ${#start[@]} -gt 0 ] || start=(--agent claude)
  mkdir -p "$ledger"
  # One queue line: title TAB spec args TAB start args; the args of a field are joined by US (0x1f), so they keep spaces.
  US=$'\x1f'; join() { local IFS=$US; printf '%s' "$*"; }
  for a in "$title" "${spec[@]}" "${start[@]}"; do
    case "$a" in *$'\t'* | *$'\n'* | *"$US"*) die "queue: an arg contains a tab/newline: use --extra <file>" ;; esac
  done
  printf '%s\t%s\t%s\n' "$title" "$(join "${spec[@]}")" "$(join "${start[@]}")" >>"$ledger/queue"
  echo "queued: $title ($(wc -l <"$ledger/queue" | tr -d ' ') in queue)"
  exit 0
fi

if [ "$cmd" = watch ]; then
  ds=(); interval=20; maxs=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dispatch) ds+=("${2:?}"); shift 2 ;;
      --interval) interval=${2:?}; shift 2 ;;
      --max-secs) maxs=${2:?}; shift 2 ;;
      --run) shift 2 ;; # accepted for symmetry; worker-show needs only the dispatch
      *) die "watch: unknown flag $1" ;;
    esac
  done
  [ ${#ds[@]} -gt 0 ] || die "watch: --dispatch <id> required"
  case "$interval$maxs" in *[!0-9]* | "") die "watch: --interval and --max-secs are whole seconds" ;; esac
  first=(); t0=$SECONDS
  while :; do
    i=0
    for d in "${ds[@]}"; do
      orca_o watch worker-show --dispatch "$d" --json --full
      st=$(jq -r '.result.dispatch.status // empty' "$TMP/out" 2>/dev/null)
      [ -n "$st" ] || { echo "next.sh: watch: worker-show $d unreadable" >&2; exit 1; }
      if [ -z "${first[i]:-}" ]; then
        first[i]=$st
        case "$st" in completed | failed) echo "changed: $d $st"; exit 0 ;; esac
      elif [ "$st" != "${first[i]}" ]; then echo "changed: $d $st"; exit 0; fi
      i=$((i + 1))
    done
    if [ "$maxs" -gt 0 ] && [ $((SECONDS - t0)) -ge "$maxs" ]; then echo "unchanged: ${ds[*]}"; exit 2; fi
    sleep "$interval"
  done
fi

case "$cmd" in settle|start) ;; *) die "unknown command '$cmd'" ;; esac
ledger=""; dispatch=""; port=""; max=""; force=0; DUP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) ledger=${2:?}; shift 2 ;;
    --dispatch) dispatch=${2:?}; shift 2 ;;
    --delivery) shift 2 ;; # legacy (pre-V3 ack), ignored
    --port) port=${2:?}; shift 2 ;;
    --run) run=${2:?}; shift 2 ;;
    --max) max=${2:?}; shift 2 ;;
    --force) force=1; shift ;;
    *) die "unknown flag $1" ;;
  esac
done
[ -n "$ledger" ] || die "--ledger <run ledger dir> is required"
[ "$cmd" = start ] || [ -n "$dispatch" ] || die "settle: --dispatch <id> is required"
mkdir -p "$ledger"; touch "$ledger/queue"
wf_load
max=${max:-${WF_MAX_WORKERS:-3}}

settle() {
  orca_o proof worker-show --dispatch "$dispatch" --json --full
  local st
  st=$(jq -r '.result.dispatch.status // empty' "$TMP/out" 2>/dev/null)
  case "$st" in
    completed | failed) echo "settled: $dispatch is $st" ;;
    *) fail proof "dispatch $dispatch is '${st:-unknown}', not completed/failed (no worker_done accepted): nothing released" 2 ;;
  esac
  orca_o release worker-release --dispatch "$dispatch" --json
  echo "released: $dispatch ($(grep -oE 'already_released|release_pending|release_unknown|released|retained' "$TMP/out" | head -1))"
  if [ -n "$port" ]; then
    bash "$DIR/spec.sh" release-port "$port" --ledger "$ledger" >/dev/null || fail port "spec.sh release-port $port"
    echo "port freed: $port"
  fi
}

count_active() { # sets ACTIVE: dispatched workers in the Run (no subshell: a failing stage must exit the script)
  # shellcheck disable=SC2046
  orca_o slots worker-list --json --full --limit 100 $(run_flag)
  ACTIVE=$(jq -r '[.result.workers[]? | select(.dispatchStatus == "dispatched")] | length' "$TMP/out") || fail slots "unreadable worker-list"
}

drop_line() { tail -n +2 "$ledger/queue" >"$ledger/queue.tmp"; mv "$ledger/queue.tmp" "$ledger/queue"; }
free_port() { [ -z "${1:-}" ] || bash "$DIR/spec.sh" release-port "$1" --ledger "$ledger" >/dev/null 2>&1; return 0; }
park_failed() { printf '%s\t%s\n' "$1" "$2" >>"$ledger/failed-starts"; }

dup_task() { # dup_task <issue>: sets DUPINFO to id and status of a non-terminal Task of the Run that names #<issue> (title or spec head)
  # shellcheck disable=SC2046
  orca_o duplicate task-list --json --full $(run_flag)
  jq -e '.result.tasks | type == "array"' "$TMP/out" >/dev/null 2>&1 || fail duplicate "unreadable task-list"
  DUPINFO=$(jq -r --arg n "$1" '.result.tasks[]? | select((.status // "") as $s | ["completed", "failed", "cancelled"] | index($s) | not)
    | select(([.task_title // "" | scan("^#[0-9]+(?:\\+#[0-9]+)*") | split("+") | map(ltrimstr("#")) | index($n)] | any(. != null)) or ((.spec // "")[0:60] | test("^ *Issue #" + $n + "([^0-9]|$)"))) | "\(.id) (\(.status))"' "$TMP/out" | head -1)
}

fill() {
  local line title specs starts spec start stage n sf tid did p
  while [ -s "$ledger/queue" ]; do
    count_active
    if [ "$ACTIVE" -ge "$max" ]; then
      echo "slots: $ACTIVE/$max busy, $(wc -l <"$ledger/queue" | tr -d ' ') queued"; return 0
    fi
    line=$(head -1 "$ledger/queue")
    IFS=$'\t' read -r title specs starts <<<"$line"
    IFS=$'\x1f' read -r -a spec <<<"$specs"; IFS=$'\x1f' read -r -a start <<<"$starts"
    stage=${spec[0]}; n=${spec[1]}; sf="$ledger/$n-$stage.spec"
    DUPINFO=""; [ $force = 1 ] || dup_task "$n"
    if [ -n "$DUPINFO" ]; then
      drop_line; park_failed "$title" "duplicate of $DUPINFO"; DUP="$DUP $title"
      echo "next.sh: stage duplicate: '$title' skipped, Task $DUPINFO already names #$n (another coordinator, or a rerun); --force starts it anyway" >&2
      continue
    fi
    bash "$DIR/spec.sh" "${spec[@]}" --ledger "$ledger" >"$sf" 2>"$TMP/err"; local rc=$?
    if [ $rc = 3 ]; then echo "port: none free, '$title' stays queued"; return 0; fi
    if [ $rc != 0 ]; then
      drop_line; park_failed "$title" "spec"
      fail spec "'$title': spec.sh exit $rc: $(head -c 300 "$TMP/err" | tr '\n' ' ')"
    fi
    p=$(sed -n 's/^PORT=//p' "$sf")
    drop_line
    # Nothing is running yet, so a failed task-create parks the task and gives its port back.
    # shellcheck disable=SC2046
    if ! orca orchestration task-create --spec-file "$sf" --task-title "$title" --json $(run_flag) >"$TMP/out" 2>"$TMP/err"; then
      park_failed "$title" "task-create"; free_port "$p"
      fail task-create "'$title': orca orchestration task-create exited non-zero (port ${p:-none} released): $(head -c 400 "$TMP/err" "$TMP/out" | tr '\n' ' ')"
    fi
    tid=$(grep -oE 'task_[0-9a-f]+' "$TMP/out" | head -1)
    [ -n "$tid" ] || { park_failed "$title" "task-create"; free_port "$p"; fail task-create "'$title': no task id in the reply (port ${p:-none} released)"; }
    # shellcheck disable=SC2046
    if ! orca orchestration worker-start --task "$tid" "${start[@]}" --json $(run_flag) >"$TMP/out" 2>"$TMP/err"; then
      park_failed "$title" "start task=$tid"
      fail start "'$title' task $tid not started (task stays created, port ${p:-none} stays reserved until you checked worker-list; do not rerun blindly): $(head -c 400 "$TMP/err" "$TMP/out" | tr '\n' ' ')"
    fi
    did=$(grep -oE 'ctx_[0-9a-f]+' "$TMP/out" | head -1)
    cp "$TMP/out" "${sf%.spec}.receipt.json" 2>/dev/null || true # launch.requested vs launch.effective for the final report
    echo "started: $title task=$tid dispatch=${did:-?} port=${p:-none} spec=$sf"
  done
  echo "queue: empty, nothing more to start"
}

[ "$cmd" = settle ] && settle
fill
endturn
[ -z "$DUP" ] || exit 1
exit 0
