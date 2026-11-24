#!/usr/bin/env bash
# GitHub's native issue status (Backlog, Todo, In progress, In review, Done, …) next to the phase labels: the skills
# say which phase an issue enters, this script writes the status and, while WF_PHASE_LABELS is on, the label.
#
#   issue-status.sh phase <n> design|build|review|backlog
#        design   Design starts:            status In progress, label phase:design
#        build    Specify or Build starts:  status In progress, label phase:build
#        review   Build opened the PR:      status In review (the PR itself is the rule clients read; no label)
#        backlog  the Design handover:      status Backlog, label phase:design removed
#   issue-status.sh set <n> <status name>   set the status by its name
#   issue-status.sh get <n>                 print the status name (empty: none, or the repo has no statuses)
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

usage() { echo "usage: issue-status.sh phase <n> design|build|review|backlog | set <n> <status name> | get <n>" >&2; exit 64; }
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

case "${1:-}" in
  phase)
    number "${2:-}"
    case "${3:-}" in
      design)
        repo
        phase_label "$2" phase:design 5319E7 "Phase UX Design: a design round is running or waits on feedback"
        set_status "$2" "In progress"
        ;;
      build)
        repo
        phase_label "$2" phase:build 1D76DB "Phase Build: specify, build or review running, or PR open"
        set_status "$2" "In progress"
        ;;
      review)
        repo
        set_status "$2" "In review"
        ;;
      backlog)
        repo
        # removed whatever the switch says: a label written before the cut-over must not keep the issue in UX Design
        if gh issue view "$2" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx 'phase:design'; then
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
