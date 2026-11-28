#!/usr/bin/env bash
# GitHub's native issue status (Backlog, Todo, In progress, In review, Done, …) next to the phase labels: the skills
# say which phase an issue enters, this script writes the status and, while WF_PHASE_LABELS is on, the label.
#
#   issue-status.sh phase <n> design|build|review|backlog
#        design   Design starts:            status In progress, labels phase:design and needs-design
#        build    Specify or Build starts:  status In progress, label phase:build
#        review   Build opened the PR:      status In review (the PR itself is the rule clients read; no label)
#        backlog  the Design handover:      status Backlog, label phase:design removed
#        design and build also remove the fog label needs-direction: a stage that starts means the issue has a lane
#   issue-status.sh fog <n>                 fog (the triage rule): add the label needs-direction; the lane label stays
#   issue-status.sh set <n> <status name>   set the status by its name
#   issue-status.sh get <n>                 print the status name (empty: none, or the repo has no statuses)
#   issue-status.sh cutover [--apply]       the phase label cut-over, for any repo: every open issue with phase:design or
#        phase:build gets its status set from the label (In progress; an existing In progress or In review stays), and
#        only after a re-read shows a started status the label goes (phase:design also makes sure of the lane
#        needs-design, the rule that reads UX Design). Without --apply it only prints the plan. Safe to rerun.
#
# Best effort: a repo without statuses, a name it does not have or a failed call print a note on stderr and exit 0,
# so no skill stops on a status. Labels stay the fallback clients read. Exit 64: usage, or no repo to act on.
# Statuses are looked up by name on every write (`planningStatuses`), never by a remembered id. `Todo` is not written
# here: it means "handed to an agent, not started yet" and belongs to the client that hands over (Tandem).
# WF_PHASE_LABELS=off (global settings file or repo config) stops the phase:* label writes; the status stays.
# The repo is $WF_REPO (owner/repo) when set, else the current checkout's origin.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"
wf_load

usage() { echo "usage: issue-status.sh phase <n> design|build|review|backlog | fog <n> | set <n> <status name> | get <n> | cutover [--apply]" >&2; exit 64; }
note() { echo "issue-status.sh: $*" >&2; }
number() { case "${1:-}" in "" | *[!0-9]*) usage ;; esac; }

REPO=""
repo() { # sets REPO (owner/repo), or exits 64: never act on a guessed repo
  REPO=$(wf_repo_slug) || REPO=""
  case "$REPO" in */*) ;; *) note "no repo: set WF_REPO or run inside a checkout with a GitHub origin"; exit 64 ;; esac
  [ -z "${WF_REPO:-}" ] || export GH_REPO=$REPO # WF_REPO also pins the label calls, as in decide.sh
}

QUERY='query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { planningStatuses(first: 50) { nodes { id name } } issue(number: $number) { id status { name } } } }'
MUTATION='mutation($issueId: ID!, $statusId: ID!) { setIssueStatus(input: { issueId: $issueId, statusId: $statusId }) { issue { number } } }'

lookup() { # lookup <n> <status name>: prints "<issue id> <TAB> <current status> <TAB> <status id>" (empty fields when missing)
  gh api graphql -f query="$QUERY" -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F number="$1" \
    --jq "[.data.repository.issue.id // \"\", .data.repository.issue.status.name // \"\", ((.data.repository.planningStatuses.nodes // []) | map(select(.name == \"$2\")) | .[0].id // \"\")] | @tsv"
}

set_status() { # set_status <n> <status name>: best effort, always 0
  local n=$1 name=$2 row issue current status
  case "$name" in *[!A-Za-z0-9\ ]* | "") note "not a status name: '$name'"; return 0 ;; esac
  row=$(lookup "$n" "$name" 2>/dev/null) || { note "#$n: status not set to $name (GitHub did not answer, or this repo has no issue statuses)"; return 0; }
  # by position: an empty middle field would collapse under `IFS=tab read`
  issue=$(printf '%s' "$row" | cut -f1); current=$(printf '%s' "$row" | cut -f2); status=$(printf '%s' "$row" | cut -f3)
  [ -n "$issue" ] || { note "#$n: no such issue in $REPO, status not set"; return 0; }
  [ -n "$status" ] || { note "#$n: $REPO has no status named $name, status not set"; return 0; }
  [ "$current" != "$name" ] || return 0
  gh api graphql -f query="$MUTATION" -f issueId="$issue" -f statusId="$status" >/dev/null 2>&1 ||
    note "#$n: status not set to $name (the write failed)"
  return 0
}

phase_label() { # phase_label <n> <label> <color> <description>: add the phase label unless WF_PHASE_LABELS is off; best effort
  [ "${WF_PHASE_LABELS:-on}" != off ] || return 0
  gh label create "$2" --force --color "$3" --description "$4" >/dev/null 2>&1 || :
  gh issue edit "$1" --add-label "$2" >/dev/null 2>&1 || note "#$1: label $2 not added"
}

has_label() { gh issue view "$1" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx "$2"; } # has_label <n> <label>

FOG=needs-direction # the fog label (docs/contract.md): set by `fog`, gone once a stage starts
clear_fog() { # clear_fog <n>: best effort
  has_label "$1" "$FOG" || return 0
  gh issue edit "$1" --remove-label "$FOG" >/dev/null 2>&1 || note "#$1: label $FOG not removed"
}

started() { case "$1" in "In progress" | "In review") return 0 ;; *) return 1 ;; esac; } # started <status name>
status_of() { lookup "$1" "" 2>/dev/null | cut -f2; } # status_of <n>: empty on none or failure

cutover() { # cutover <apply 0|1>: see the header; best effort, always 0
  local apply=$1 design build n lab cur plan
  design=$(gh issue list --state open --label phase:design --limit 500 --json number --jq '.[].number' 2>/dev/null) || design=""
  build=$(gh issue list --state open --label phase:build --limit 500 --json number --jq '.[].number' 2>/dev/null) || build=""
  [ "$apply" = 1 ] && echo "cutover $REPO (apply)" || echo "cutover $REPO (dry run, nothing written; --apply writes)"
  [ -n "$design$build" ] || { echo "nothing to do: no open issue carries a phase:* label"; return 0; }
  for n in $design $build; do
    # an issue with both labels is done once, as design
    if printf '%s\n' "$design" | grep -qx "$n"; then lab=phase:design; else lab=phase:build; fi
    if [ "$lab" = phase:build ] && printf '%s\n' "$design" | grep -qx "$n"; then continue; fi
    cur=$(status_of "$n")
    if started "$cur"; then plan="status $cur stays"; else plan="status ${cur:-none} -> In progress"; fi
    [ "$lab" != phase:design ] || plan="$plan, lane needs-design ensured"
    if [ "$apply" != 1 ]; then echo "#$n $lab: $plan, remove $lab"; continue; fi
    if ! started "$cur"; then
      set_status "$n" "In progress"
      cur=$(status_of "$n")
      started "$cur" || { echo "#$n $lab: kept (the status could not be set)"; continue; }
    fi
    if [ "$lab" = phase:design ] && ! has_label "$n" needs-design; then
      gh issue edit "$n" --add-label needs-design >/dev/null 2>&1 || { echo "#$n $lab: kept (lane needs-design not added)"; continue; }
    fi
    # only the labels it has: gh refuses to remove one the issue lacks
    have=$(gh issue view "$n" --json labels --jq '.labels[].name' 2>/dev/null) || have=""
    rm=""
    for l in phase:design phase:build; do printf '%s\n' "$have" | grep -qx "$l" && rm="$rm --remove-label $l"; done
    # shellcheck disable=SC2086
    if [ -z "$rm" ] || gh issue edit "$n" $rm >/dev/null 2>&1; then echo "#$n $lab: $plan, label removed"
    else echo "#$n $lab: kept (label not removed)"; fi
  done
  return 0
}

case "${1:-}" in
  cutover)
    case "${2:-}" in "") a=0 ;; --apply) a=1 ;; *) usage ;; esac
    [ $# -le 2 ] || usage
    repo
    cutover "$a"
    ;;
  fog)
    number "${2:-}"
    repo
    gh label create "$FOG" --force --color D4C5F9 --description "Direction open: the user sets it" >/dev/null 2>&1 || :
    gh issue edit "$2" --add-label "$FOG" >/dev/null 2>&1 || note "#$2: label $FOG not added"
    ;;
  phase)
    number "${2:-}"
    case "${3:-}" in
      design)
        repo
        phase_label "$2" phase:design 5319E7 "Phase UX Design: a design round is running or waits on feedback"
        # the lane too: status In progress reads as UX Design only in the lane needs-design (a redesign of a ready issue, a design batch member)
        gh issue edit "$2" --add-label needs-design >/dev/null 2>&1 || note "#$2: label needs-design not added"
        clear_fog "$2"
        set_status "$2" "In progress"
        ;;
      build)
        repo
        phase_label "$2" phase:build 1D76DB "Phase Build: specify, build or review running, or PR open"
        clear_fog "$2"
        set_status "$2" "In progress"
        ;;
      review)
        repo
        set_status "$2" "In review"
        ;;
      backlog)
        repo
        # removed whatever the switch says: a label written before the cut-over must not keep the issue in UX Design
        if has_label "$2" phase:design; then
          gh issue edit "$2" --remove-label phase:design >/dev/null 2>&1 || note "#$2: label phase:design not removed"
        fi
        set_status "$2" "Backlog"
        ;;
      *) usage ;;
    esac
    ;;
  set)
    number "${2:-}"
    [ -n "${3:-}" ] || usage
    repo
    set_status "$2" "$3"
    ;;
  get)
    number "${2:-}"
    repo
    lookup "$2" "" 2>/dev/null | cut -f2 || :
    ;;
  *) usage ;;
esac
exit 0
