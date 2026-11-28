#!/usr/bin/env bash
# The next step of each issue, from what GitHub shows (aw-coordinate subagent mode, subagent-mode.md): the facts of
# screening and routing that need no judgement. Reads only; starts nothing.
#
#   plan.sh <issue>...        (`#12` and `12` are the same)
#
# One line per issue, tab-separated: `#<n>  <step>  <detail>`. Steps, first match wins:
#   skip     closed | held: label on-hold | merge held: label <l> | waiting for a decision | fog: label needs-direction
#   lead     an open PR closes the issue but has no `## Review` yet (the lead goes on at the review route)
#   review   its `## Review` is `route: reviewer` and nobody reviewed yet (no `by:`)
#   fix      its `## Review` has a finding `-> open` and fewer than 2 fix rounds are settled on the log
#   hold     a finding is `-> open` after the rounds the rules allow (a `route: lead` review: the lead used its 2; a
#            `route: reviewer` review: 2 settled fix rounds): never another fix round, the coordinator holds the merge
#   delta-review  the review is complete but a settled fix round has no delta marker on the log: its delta-review is due
#   merge    its `## Review` is complete: merge-pr.sh prep decides the rest
# The rounds come from the issue's coordination log (`decide.sh log --path <n>`). Only the coordinator writes the round
# markers, as exact lines, each when it has read the worker's final line and before it runs `plan.sh`:
#   round: fix <k> settled <sha>            a fix worker ended `FIXED` (<sha>: the PR's head); k = the round, 1 then 2
#   round: delta <k> settled open=<m>       the delta-review of round k ended `REVIEWED` with m findings open
#   round: delta <k> skipped                the rules skip it (the round changed only docs or comments)
# plan.sh counts only those lines (a worker's "fix round 1 done" is free text and ignored); a fix round is reviewed only
# when a delta marker with the same k exists. No log on this machine counts as no round.
#   design   label needs-design
#   lead     label needs-spec or ready
#   screen   no lane label: the coordinator gives it a lane by the triage rule first
#   unknown  the issue could not be read
# Detail: `lane=<label>`, and for work that exists `pr=<n> branch=<head>` (the branch a later stage takes over) or
# `branch=<b>` (a local or remote `<type>/<n>-*`, `proto/<n>-*` or Orca's `<user>/<type>-<n>-*` branch without an open PR).
# What it cannot know stays with the coordinator: batches, dependencies, order (reference/coordination.md).
# Exit: 0 every issue read, 1 one could not be read, 64 usage.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../bin/lib.sh
. "$DIR/../../bin/lib.sh"
[ $# -gt 0 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "plan.sh: jq is required" >&2; exit 64; }
wf_load
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0
# every open PR, read once; its body decides which issues it closes (GitHub's search does not match `#<n>` reliably)
prs_ok=1; count=0
if gh pr list --state open --limit 300 --json number,headRefName,body >"$TMP/p" 2>/dev/null && count=$(jq -e 'length' "$TMP/p" 2>/dev/null); then :
else prs_ok=0; fi
[ "$count" -lt 300 ] 2>/dev/null || prs_ok=0 # a full page may have cut PRs off: never route as if the rest were not there

review_state() { # review_state <body file>: none | unreviewed | open | complete (the `## Review` section only)
  awk '
    /^## Review[[:space:]]*$/ { on = 1; seen = 1; next }
    on && /^## / { on = 0 }
    on && /by:/ { by = 1 }
    on && /^- .*-> open[[:space:]]*$/ { open = 1 }
    END { if (!seen) print "none"; else if (open) print "open"; else if (!by) print "unreviewed"; else print "complete" }
  ' "$1"
}
closes() { # closes <body file> <n>: 0 when a line-leading Closes/Fixes/Resolves names #<n> of this repo
  grep -Eiq "^[[:space:]-]*(closes|fixes|resolves) +([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#$2([^0-9]|\$)" "$1" # as merge-pr.sh issues_of
}
branch_of() { # branch_of <n>: a stage branch of the issue without a PR (local first, then origin), or nothing
  git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null |
    sed 's#^origin/##' | grep -E "^((proto|fix|feat|test|docs|chore)/|[^/]+/(proto|fix|feat|test|docs|chore)-)$1-" | head -1
}
review_route() { # review_route <body file>: lead | reviewer | "" (the route line of the `## Review` section)
  awk '/^## Review[[:space:]]*$/ { on = 1; next } on && /^## / { on = 0 } on && /^route:/ { sub(/^route:[[:space:]]*/, ""); sub(/[[:space:]·].*/, ""); print; exit }' "$1"
}
log_rounds() { # log_rounds <n>: "<settled fix rounds> <1 when a settled fix round has no delta marker, i.e. its delta-review is due>"
  # Only the coordinator's exact marker lines count (after the timestamp): `round: fix <k> settled <sha>`,
  # `round: delta <k> settled open=<m>` and `round: delta <k> skipped`. Worker text ("fix round 1 done") never matches.
  local f; f=$("$DIR/../../bin/decide.sh" log --path "$1" 2>/dev/null) || f=""
  [ -n "$f" ] && [ -f "$f" ] || { echo "0 0"; return; }
  grep '^- ' "$f" | awk '
    # fields: 1 "-", 2 timestamp, 3 "round:", 4 fix|delta, 5 k
    $0 ~ /^- [^ ]+ round: fix [0-9]+ settled [0-9a-f]+$/ { if (!($5 in fx)) { fx[$5] = 1; r++ } }
    $0 ~ /^- [^ ]+ round: delta [0-9]+ (settled open=[0-9]+|skipped)$/ { dl[$5] = 1 }
    END { due = 0; for (k in fx) if (!(k in dl)) due = 1; print r + 0, due }'
}

for arg in "$@"; do
  n=${arg#\#}
  case "$n" in ''|*[!0-9]*) echo "plan.sh: not an issue number: $arg" >&2; exit 64 ;; esac
  line() { printf '#%s\t%s\t%s\n' "$n" "$1" "$2"; }
  if ! gh issue view "$n" --json state,labels >"$TMP/i" 2>/dev/null || ! state=$(jq -er .state "$TMP/i" 2>/dev/null); then
    line unknown "gh issue view failed"; rc=1; continue
  fi
  labels=$(jq -r '.labels[].name' "$TMP/i")
  lab() { printf '%s\n' "$labels" | grep -qxF -- "$1"; }
  lane=""; for l in needs-design needs-spec ready; do if lab "$l"; then lane=$l; break; fi; done
  [ "$state" != CLOSED ] || { line skip closed; continue; }
  ! lab on-hold || { line skip "held: label on-hold"; continue; }

  # the open PR that closes it: never routed as if there were none when the list could not be read
  [ $prs_ok = 1 ] || { line unknown "gh pr list failed"; rc=1; continue; }
  pr=""; head=""; i=0
  while [ "$i" -lt "$count" ]; do
    jq -r ".[$i].body // \"\"" "$TMP/p" | tr -d '\r' >"$TMP/b"
    if closes "$TMP/b" "$n"; then pr=$(jq -r ".[$i].number" "$TMP/p"); head=$(jq -r ".[$i].headRefName" "$TMP/p"); break; fi
    i=$((i + 1))
  done
  [ -n "$pr" ] || : >"$TMP/b"
  detail="lane=${lane:-none}"
  if [ -n "$pr" ]; then detail="$detail pr=$pr branch=$head"
  else b=$(branch_of "$n"); [ -z "$b" ] || detail="$detail branch=$b"; fi

  if lab needs-decision; then line skip "waiting for a decision (decide.sh status) $detail"; continue; fi
  if [ -n "$pr" ]; then
    case $(review_state "$TMP/b") in
      none) line lead "$detail" ;;
      unreviewed) line review "$detail" ;;
      open)
        read -r rounds _ <<<"$(log_rounds "$n")"
        if [ "$(review_route "$TMP/b")" = lead ] || [ "$rounds" -ge 2 ]; then line hold "fix rounds used (lead: 2, settled: $rounds) $detail"; else line fix "$detail"; fi ;;
      complete)
        read -r _ due <<<"$(log_rounds "$n")"
        if [ "$due" = 1 ] && [ "$(review_route "$TMP/b")" != lead ]; then line delta-review "$detail"; continue; fi
        held=""; for h in $WF_HOLD_LABELS; do if lab "$h"; then held=$h; break; fi; done
        if [ -n "$held" ]; then line skip "merge held: label $held $detail"; else line merge "$detail"; fi ;;
    esac
    continue
  fi
  if lab needs-direction; then line skip "fog: label needs-direction"; continue; fi
  case "$lane" in
    needs-design) line design "$detail" ;;
    needs-spec|ready) line lead "$detail" ;;
    *) line screen "$detail" ;;
  esac
done
exit $rc
