#!/usr/bin/env bash
# Fix and delta-review rounds of a PR in aw-coordinate's subagent mode (skills/aw-coordinate/subagent-mode.md): the one
# place that writes the round markers on an issue's coordination log (`decide.sh log`) and reads them back. plan.sh and
# `merge-pr.sh prep` route on `state`; the coordinator writes with `start`, `fixed` and `delta`, never by hand.
#
#   rounds.sh state <issue>...          one line: `<rounds used> <round in flight, or 0> <started|settled|none>`, over the
#                                       logs of all the issues named (a batch PR closes several). Reads only.
#   rounds.sh start <issue> <pr>        before a fix worker starts: opens the next round (`round: fix <k> started <head>`).
#                                       A started round still in flight goes on: nothing written, the same round printed.
#                                       Exit 1, nothing written: a settled round waits for its delta-review, or the PR
#                                       head could not be read.
#   rounds.sh fixed <issue> <pr>        the fix worker ended `FIXED`: `round: fix <k> settled <head>` for the round in
#                                       flight (the next round when none was started). A second call writes nothing.
#   rounds.sh delta <issue> open=<m>|skipped
#                                       a delta-review ended `REVIEWED … open=<m>`, or the rules skip it: the delta marker
#                                       of the round in flight. No round in flight: nothing written, exit 0 (so it may
#                                       follow every `REVIEWED`).
#
# The markers are exact lines after the log's `- <timestamp> `; anything else (a worker's "fix round 1 done") counts
# nothing:
#   round: fix <k> started <sha>        round: fix <k> settled <sha>
#   round: delta <k> settled open=<m>   round: delta <k> skipped
# F = the highest k of a fix marker = the rounds used; D = the highest k of a delta marker (it settles every round up
# to k). A round is in flight while F > D: `settled` when round F has its settled marker, else `started`. A log that is
# not on this machine counts as no round.
# Every write prints `round=<k> <what happened>`. Exit: 0 done, 1 refused (nothing written), 64 usage.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
num() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }

state() { # state <issue>...
  local n f
  for n in "$@"; do
    f=$("$DIR/decide.sh" log --path "$n" 2>/dev/null) || continue
    [ ! -f "$f" ] || cat "$f"
  done | awk '
    # fields: 1 "-", 2 timestamp, 3 "round:", 4 fix|delta, 5 k, 6 started|settled|skipped
    /^- [^ ]+ round: fix [0-9]+ (started|settled) [0-9a-f]+$/ { k = $5 + 0; if (k > F) F = k; if ($6 == "settled") st[k] = 1 }
    /^- [^ ]+ round: delta [0-9]+ (settled open=[0-9]+|skipped)$/ { k = $5 + 0; if (k > D) D = k }
    END { if (F > D) print F, F, ((F in st) ? "settled" : "started"); else print F + 0, 0, "none" }'
}
head_of() { # head_of <pr>: the PR head sha, or exit 1
  local sha
  sha=$(gh pr view "$1" --json headRefOid -q .headRefOid 2>/dev/null) || sha=""
  case "$sha" in '' | *[!0-9a-f]*) echo "rounds.sh: cannot read the head of PR #$1 (nothing written)" >&2; return 1 ;; esac
  echo "$sha"
}
mark() { # mark <issue> <marker>
  "$DIR/decide.sh" log "$1" "$2" || { echo "rounds.sh: could not write the marker to the log of #$1" >&2; exit 1; }
}

cmd=${1:-}; shift || true
case "$cmd" in
  state)
    [ $# -gt 0 ] || usage
    for a in "$@"; do num "${a#\#}" || usage; done
    state "${@#\#}" ;;
  start | fixed)
    n=${1:-}; n=${n#\#}; pr=${2:-}; pr=${pr#\#}
    [ $# -eq 2 ] && num "$n" && num "$pr" || usage
    read -r used k phase <<<"$(state "$n")"
    if [ "$cmd" = start ]; then
      case "$phase" in
        started) echo "round=$k goes on (started before, nothing written)"; exit 0 ;;
        settled) echo "rounds.sh: fix round $k of #$n waits for its delta-review: no new round (nothing written)" >&2; exit 1 ;;
      esac
      sha=$(head_of "$pr") || exit 1
      k=$((used + 1)); mark "$n" "round: fix $k started $sha"; echo "round=$k started $sha"
    else
      [ "$phase" != settled ] || { echo "round=$k settled before (nothing written)"; exit 0; }
      sha=$(head_of "$pr") || exit 1
      [ "$phase" = started ] || k=$((used + 1))
      mark "$n" "round: fix $k settled $sha"; echo "round=$k settled $sha"
    fi ;;
  delta)
    n=${1:-}; n=${n#\#}; res=${2:-}
    [ $# -eq 2 ] && num "$n" || usage
    case "$res" in skipped) what=skipped ;; open=*) num "${res#open=}" || usage; what="settled $res" ;; *) usage ;; esac
    read -r used k phase <<<"$(state "$n")"
    [ "$phase" != none ] || { echo "round=0 no fix round in flight (nothing written)"; exit 0; }
    mark "$n" "round: delta $k $what"; echo "round=$k delta $what" ;;
  *) usage ;;
esac
