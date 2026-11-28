#!/usr/bin/env bash
# Fix and delta-review rounds of a PR in aw-coordinate's subagent mode (skills/aw-coordinate/subagent-mode.md): the one
# place that writes the round markers on an issue's coordination log (`decide.sh log`) and reads them back. plan.sh and
# `merge-pr.sh prep` route on `state`; the coordinator writes with `start`, `fixed` and `delta`, never by hand.
#
#   rounds.sh state <pr> <issue>...     one line: `<rounds used> <round in flight, or 0> <started|settled|none>`, the
#                                       rounds of that PR over the logs of all the issues named (a batch PR closes
#                                       several). Reads only. Exit 1, nothing printed: a log could not be located.
#   rounds.sh start <issue> <pr>        before a fix worker starts: opens the next round on the issue's log. A started
#                                       round still in flight goes on: nothing written, the same round printed.
#                                       Exit 1, nothing written: a settled round waits for its delta-review, or both
#                                       rounds the rules allow are used (plan.sh shows `hold`).
#   rounds.sh fixed <issue> <pr>        the fix worker ended `FIXED`: settles the started round. A second call writes
#                                       nothing. No round in flight: a fix nobody recorded (the PR head is not the one
#                                       the last round settled) opens the next round and settles it, so its delta-review
#                                       is due; the same head again writes nothing.
#   rounds.sh delta <issue> <pr> open=<m>|skipped
#                                       a delta-review ended `REVIEWED … open=<m>`, or the rules skip it: the delta marker
#                                       of the round in flight. No round in flight: nothing written, exit 0.
# The three writes read the PR (its head, and the issues it closes: the round is counted over all their logs, whichever
# issue's log a marker went to); when it cannot be read, or does not close the issue named, they exit 1 and write nothing.
#
# The markers are exact lines after the log's `- <timestamp> `; anything else (a worker's "fix round 1 done") counts
# nothing:
#   round: fix <k> started <sha> pr=<pr>        round: fix <k> settled <sha> pr=<pr>
#   round: delta <k> settled open=<m> pr=<pr>   round: delta <k> skipped pr=<pr>
# A marker counts for its PR only (an issue's earlier PR, closed without a merge, leaves no round behind); a line
# without ` pr=<pr>` (written before the PR was recorded) counts for every PR. F = the highest k of a fix marker = the
# rounds used; D = the highest k of a delta marker (it settles every round up to k). A round is in flight while F > D:
# `settled` when round F has its settled marker, else `started`. No log on this machine counts as no round.
# Every write prints `round=<k> <what happened>`. Exit: 0 done, 1 refused or unreadable (nothing written), 64 usage.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAX=2 # fix rounds per PR (reference/coordination.md, "Review route")
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
num() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
[ -z "${WF_REPO:-}" ] || export GH_REPO=$WF_REPO # the PR is read from the repo the logs belong to (as decide.sh does)

state() { # state <pr> <issue>...: "<used> <in flight or 0> <phase> <sha the highest fix round settled, or ->"; 1 = unreadable
  local pr=$1 n f; shift
  : >"$TMP/logs"
  for n in "$@"; do
    f=$("$DIR/decide.sh" log --path "$n" 2>"$TMP/err") && [ -n "$f" ] ||
      { echo "rounds.sh: cannot locate the coordination log of #$n: $(head -c 300 "$TMP/err")" >&2; return 1; }
    [ ! -f "$f" ] || cat "$f" >>"$TMP/logs" 2>"$TMP/err" ||
      { echo "rounds.sh: cannot read the coordination log of #$n: $(head -c 300 "$TMP/err")" >&2; return 1; }
  done
  awk -v pr="pr=$pr" '
    # fields: 1 "-", 2 timestamp, 3 "round:", 4 fix|delta, 5 k, 6 started|settled|skipped, last: pr=<pr> when recorded
    $NF ~ /^pr=/ && $NF != pr { next }
    /^- [^ ]+ round: fix [0-9]+ (started|settled) [0-9a-f]+( pr=[0-9]+)?$/ { k = $5 + 0; if (k > F) F = k; if ($6 == "settled") st[k] = $7 }
    /^- [^ ]+ round: delta [0-9]+ (settled open=[0-9]+|skipped)( pr=[0-9]+)?$/ { k = $5 + 0; if (k > D) D = k }
    END { sha = (F in st) ? st[F] : "-"; if (F > D) print F, F, ((F in st) ? "settled" : "started"), sha; else print F + 0, 0, "none", sha }' "$TMP/logs"
}
pr_state() { # pr_state <issue> <pr>: sets sha, used, k, phase from the PR and the logs of every issue it closes; 1 = unreadable
  local s
  gh pr view "$2" --json headRefOid,body >"$TMP/pr" 2>/dev/null && sha=$(jq -er .headRefOid "$TMP/pr" 2>/dev/null) || sha=""
  case "$sha" in '' | *[!0-9a-f]*) echo "rounds.sh: cannot read PR #$2 (nothing written)" >&2; return 1 ;; esac
  jq -r '.body // ""' "$TMP/pr" | tr -d '\r' >"$TMP/body"
  "$DIR/merge-pr.sh" issues-of "$TMP/body" >"$TMP/issues" 2>/dev/null # nothing listed: the PR closes nothing, or the list failed
  grep -qx "$1" "$TMP/issues" || { echo "rounds.sh: PR #$2 does not close #$1 (no line-leading 'Closes #$1' in its body): nothing written" >&2; return 1; }
  # shellcheck disable=SC2046
  s=$(state "$2" $(cat "$TMP/issues")) || return 1
  read -r used k phase last <<<"$s"
}
mark() { # mark <issue> <pr> <marker>
  "$DIR/decide.sh" log "$1" "$3 pr=$2" || { echo "rounds.sh: could not write the marker to the log of #$1" >&2; exit 1; }
}

cmd=${1:-}; shift || true
case "$cmd" in
  state)
    pr=${1:-}; pr=${pr#\#}; shift || true
    num "$pr" && [ $# -gt 0 ] || usage
    for a in "$@"; do num "${a#\#}" || usage; done
    s=$(state "$pr" "${@#\#}") || exit 1
    echo "${s% *}" ;;
  start | fixed | delta)
    n=${1:-}; n=${n#\#}; pr=${2:-}; pr=${pr#\#}
    num "$n" && num "$pr" || usage
    command -v jq >/dev/null 2>&1 || { echo "rounds.sh: jq is required" >&2; exit 64; }
    case "$cmd" in
      delta)
        [ $# -eq 3 ] || usage
        case "$3" in skipped) what=skipped ;; open=*) num "${3#open=}" || usage; what="settled $3" ;; *) usage ;; esac ;;
      *) [ $# -eq 2 ] || usage ;;
    esac
    pr_state "$n" "$pr" || exit 1
    case "$cmd:$phase" in
      start:started) echo "round=$k goes on (started before, nothing written)" ;;
      start:settled) echo "rounds.sh: fix round $k of PR #$pr waits for its delta-review: no new round (nothing written)" >&2; exit 1 ;;
      start:none)
        [ "$used" -lt $MAX ] || { echo "rounds.sh: PR #$pr used its $used fix rounds: no new round, the merge is held (nothing written)" >&2; exit 1; }
        k=$((used + 1)); mark "$n" "$pr" "round: fix $k started $sha"; echo "round=$k started $sha" ;;
      fixed:started) mark "$n" "$pr" "round: fix $k settled $sha"; echo "round=$k settled $sha" ;;
      fixed:settled) echo "round=$k settled before (nothing written)" ;;
      fixed:none)
        if [ "$last" = "$sha" ]; then echo "round=$used settled before (nothing written)"
        else k=$((used + 1)); mark "$n" "$pr" "round: fix $k settled $sha"; echo "round=$k settled $sha (no round was started: opened and settled)"; fi ;;
      delta:none) echo "round=0 no fix round in flight (nothing written)" ;;
      delta:*) mark "$n" "$pr" "round: delta $k $what"; echo "round=$k delta $what" ;;
    esac ;;
  *) usage ;;
esac
