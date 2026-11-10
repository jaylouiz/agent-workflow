#!/usr/bin/env bash
# Decision inbox on GitHub issues: one-way questions park their issue (label `needs-decision`) instead of
# blocking a worker; two-way decisions are recorded (label `agent-decided`) and never block. The user answers
# by commenting on the issue, any time; the coordinator sweeps with `status` and batches pings with `digest`.
#
#   decide.sh request <n> <file>   post a decision request (first line of <file> = the one-line question; a line
#                                  `Preview: <url>` is shown under it in the digest), park
#   decide.sh record  <n> <file>   post a decision the agent made (chosen, alternatives, why, cost to switch)
#   decide.sh answer  <n> <text> [D<k>]   post an answer the user gave elsewhere (chat) as the issue's answer
#   decide.sh resolve <n> <text> [D<k>]   unpark: drop `needs-decision`, post "resuming with: <text>"
#   decide.sh followup <n> <m> [D<k>]     note that change request on #n became issue #m
#                                  (answer/resolve/followup act on the newest decision unless D<k> is given: pass the
#                                  id `status` printed, an older decision can be the one that was answered or challenged)
#   decide.sh note    <n> <text>   any other agent comment a human reads (the closing summary): marked, so never read as the user's
#   decide.sh log     <n> <text>   agent-to-agent coordination (stage start, progress, PR link, fix round, resume text):
#                                  appended to the issue's coordination log, never posted on the issue
#   decide.sh log --path <n> | --rm <n> | --prune
#                                  the log file's path; delete one issue's log; delete the logs of closed issues
#   decide.sh check   <file>       comment cap: visible text (outside <details>, comments, images) at most
#                                  $WF_COMMENT_CAP chars (1500), no visible line over 400; request/record and guard.sh run it
#   decide.sh status               answered / waiting requests, change requests on agent-decided issues
#   decide.sh digest [--due FILE] [--idle] [--cap SEC]
#                                  bundled list of waiting requests. With --due: print and exit 0 only when the
#                                  run is idle (--idle) or the oldest request not yet listed in FILE is older
#                                  than --cap (default 7200); then add the listed ids to FILE. Else exit 1.
#
# The repo is $WF_REPO (owner/repo) when set, else the current checkout's origin; with neither, every subcommand
# but `check` exits 64 before writing anything (a worker in /tmp must not post to a guessed repo, or to none).
# Agents comment with the user's GitHub account, so authorship cannot tell an answer from an agent comment.
# Every comment this script writes carries a `<!-- decision-<kind> D<k> -->` marker; any later comment without
# one counts as the user's, and belongs to the decision it names (`D<k>: …`, see `scan`) else to the nearest earlier
# marker (a note's replies are dropped). Hence: agents comment on an issue with decisions only through this script (`note`).
# GitHub's label filter lags a few seconds behind `gh issue edit --add-label`; sweeps run minutes apart.
# The issue thread is for the human: what was decided and what waits on them. Coordination between agents goes to
# the coordination log, $WF_ISSUE_LOG_DIR (default ~/.claude/issue-logs)/<owner>/<repo>/<n>.md, outside the work
# tree; a fresh worker reads it, Tandem may show it, and `merge-pr.sh after` deletes it.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

die() { echo "decide.sh: $*" >&2; exit 64; }

labels() {
  gh label create needs-decision --force --color D93F0B --description "Parked: waits for a user decision" >/dev/null
  gh label create agent-decided --force --color FBCA04 --description "Has agent decisions the user has not reviewed" >/dev/null
}

comments() { gh issue view "$1" --json comments --jq '.comments'; }

decision_id() { # <issue> [D<k>]: the id a write command targets (number only); default the newest, a given one must exist
  local id
  case "${2:-}" in
    "") id=$(( $(next_id "$1") - 1 )); [ "$id" -ge 1 ] || die "issue $1 has no decision request or record" ;;
    D[0-9]*[!0-9]*|D) die "not a decision id: $2" ;;
    D[0-9]*) id=${2#D}
      comments "$1" | jq -e --arg re "<!-- decision-(request|record) D$id -->" 'any(.[]; .body | test($re))' >/dev/null \
        || die "issue $1 has no decision $2" ;;
    *) die "not a decision id: $2" ;;
  esac
  echo "$id"
}

next_id() {
  comments "$1" | jq -r '[.[].body | scan("<!-- decision-(?:request|record) D([0-9]+) -->") | .[0] | tonumber] | (max // 0) + 1'
}

post() { gh issue comment "$1" --body-file "$2" >/dev/null; } # <n> <body file>

# Visible text: what a reader sees before expanding anything. Prints "<chars> <longest line>".
visible() {
  python3 -I -c '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = re.sub(r"(?is)<details>.*?</details>", "", t)
t = re.sub(r"(?s)<!--.*?-->", "", t)
t = re.sub(r"!\[[^\]]*\]\([^)]*\)|<img[^>]*>", "", t)
t = re.sub(r"https?://\S+", "<url>", t)
lines = [l.strip() for l in t.splitlines() if l.strip()]
print(sum(len(l) for l in lines), max([len(l) for l in lines] or [0]))' "$1"
}

check() { # <file>: exit 65 with the reason when the comment is too long for a human to scan
  local cap=${WF_COMMENT_CAP:-1500} chars longest
  read -r chars longest < <(visible "$1")
  [ "$chars" -le "$cap" ] || { echo "decide.sh check: $chars visible chars, cap $cap. Keep the headline, options and recommendation; fold the rest into <details><summary>Details</summary> … </details>, or move coordination to 'decide.sh log'." >&2; return 65; }
  [ "$longest" -le 400 ] || { echo "decide.sh check: a visible line has $longest chars (max 400). Break it into a list or short paragraphs." >&2; return 65; }
  # GitHub ends an HTML block only at a blank line: text right after </details> (a "### b:" heading) renders raw.
  local glued
  glued=$(python3 -I -c '
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for i, l in enumerate(lines[:-1], 1):
    if l.rstrip().endswith("</details>") and lines[i].strip():
        print(i); break' "$1")
  [ -z "$glued" ] || { echo "decide.sh check: line $glued ends with </details> and the next line is not blank, so GitHub renders the following Markdown (headings, lists) as raw text. Add a blank line after </details>." >&2; return 65; }
}

need_repo() { # sets REPO; loud, before any write, when there is none. WF_REPO also pins every gh call (GH_REPO)
  REPO=$(wf_repo_slug) || REPO=""
  [[ $REPO =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$ && $REPO != */. && $REPO != */.. ]] \
    || die "cannot tell which repo this is (got '${REPO:-none}'): not in a checkout with a GitHub origin, and WF_REPO is unset or not owner/repo. Run it inside the checkout, or set WF_REPO=<owner/repo>. Nothing was written."
  [ -z "${WF_REPO:-}" ] || export GH_REPO=$REPO # unset: gh keeps its own (fork-aware) resolution, as before
}

log_dir() { echo "${WF_ISSUE_LOG_DIR:-$HOME/.claude/issue-logs}/$REPO"; }

# Per decision (D<k> with a request or record marker): its last marker and the unmarked comments it owns after it.
# An unmarked comment owns to D<k> when its first text starts `D<k>:` and a request/record D<k> is earlier in the
# thread (Tandem writes that prefix on every reply, so a challenge to D2 stays D2's while a later request D3 is
# open); any other unmarked comment owns to the nearest earlier marked comment, a note included: a note has no
# decision, so a reply to it (`rec D1, note look, "y"`) belongs to none and is dropped, exactly as Tandem reads it.
# Output (US-separated, \x1f: a tab IFS would collapse an empty answer field and shift the preview into it): number, url, last kind, id, question, age seconds, answer text (newlines flattened), preview link
# An empty <label> scans every issue of that state: a request whose `needs-decision` label was dropped by hand (or lags)
# must still show up, so status and digest scan unlabeled.
scan() { # <label|""> <state>
  gh issue list ${1:+--label "$1"} --state "$2" --limit 100 --json number,url,comments | jq -r '
    def owner($cs; $e):
      ($e.pre) as $p
      | if $p != null and ([$cs[] | select(.key < $e.key and .c != null and (.c.kind == "request" or .c.kind == "record") and .c.id == $p)] | length) > 0
        then $p
        else ([$cs[] | select(.key < $e.key and .any)] | last | .c.id // null) end;
    .[] | . as $i
    | ([.comments | to_entries[] | . as $e
        | {key: $e.key, v: $e.value,
           any: ($e.value.body | test("<!-- decision-")),
           c: (if ($e.value.body | test("<!-- decision-(?!note)")) then ($e.value.body | capture("<!-- decision-(?<kind>[a-z]+) D(?<id>[0-9]+) -->")? // null) else null end),
           pre: (($e.value.body | capture("\\A\\s*D(?<n>[0-9]+):")? | .n) // null)}]) as $cs
    | ([$cs[] | select(.any | not) | . + {own: owner($cs; .)}]) as $un
    | ([$cs[] | select(.c != null and (.c.kind == "request" or .c.kind == "record")) | .c.id] | reduce .[] as $x ([]; if index($x) then . else . + [$x] end)) as $ids
    | $ids[] | . as $id
    | ([$cs[] | select(.c != null and .c.id == $id)]) as $ms
    | ($ms | last) as $m
    | ([$ms[] | select(.c.kind == "request" or .c.kind == "record")] | last) as $q
    | ([$un[] | select(.own == $id and .key > $m.key) | .v.body]) as $after
    | [$i.number, $i.url,
       (if $m.c.kind == "answer" then "answered" else $m.c.kind end), "D\($id)",
       ($q.v.body | split("\n") | map(select(test("^(<!--|###|$)") | not)) | first // "-" | .[0:120]),
       (now - ($q.v.createdAt | fromdateiso8601) | floor),
       ((if $m.c.kind == "answer" then [$m.v.body | split("\n")[1:] | join(" ") | sub("^Answer from the user \\(via the coordinator\\): "; "")] else [] end) + $after
        | join(" / ") | gsub("\\s+"; " ") | .[0:400]),
       ($q.v.body | split("\n") | map(select(test("^Preview: "))) | first // "" | sub("^Preview: "; ""))]
    | map(tostring | gsub("\u001f"; " ")) | join("\u001f")'
}

age() { local s=$1; if [ "$s" -ge 3600 ]; then echo "$((s / 3600))h"; else echo "$((s / 60))m"; fi; }

cmd=${1:-}; shift || true
case "$cmd" in request|record|answer|resolve|followup|note|log|status|digest) need_repo ;; esac
case "$cmd" in
  request|record)
    [ $# -eq 2 ] && [ -s "$2" ] || die "usage: $cmd <issue> <file>"
    labels; id=$(next_id "$1"); tmp=$(mktemp)
    if [ "$cmd" = request ]; then
      { echo "<!-- decision-request D$id -->"; echo "### Decision needed (D$id): parked"; echo; cat "$2"; echo
        echo "---"; echo "Answer in a comment here (\`B\`, or free text); with other decisions on this issue start it with \`D$id:\`. The run picks it up at its next checkpoint."; } >"$tmp"
      check "$tmp" || { rm -f "$tmp"; exit 65; }
      post "$1" "$tmp"; gh issue edit "$1" --add-label needs-decision >/dev/null
    else
      { echo "<!-- decision-record D$id -->"; echo "### Agent decision (D$id): not blocking"; echo; cat "$2"; echo
        echo "---"; echo "To change it, comment here, starting with \`D$id:\` so it reaches this decision and not a later one. To accept, remove the \`agent-decided\` label."; } >"$tmp"
      check "$tmp" || { rm -f "$tmp"; exit 65; }
      post "$1" "$tmp"; gh issue edit "$1" --add-label agent-decided >/dev/null
    fi
    rm -f "$tmp"; echo "D$id"
    ;;
  answer|resolve)
    [ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: $cmd <issue> <text> [D<k>]"
    id=$(decision_id "$1" "${3:-}"); tmp=$(mktemp)
    if [ "$cmd" = answer ]; then
      printf '<!-- decision-answer D%s -->\nAnswer from the user (via the coordinator): %s\n' "$id" "$2" >"$tmp"
      post "$1" "$tmp"
    else
      printf '<!-- decision-resolved D%s -->\nResumed (D%s).\n' "$id" "$id" >"$tmp"
      post "$1" "$tmp"; gh issue edit "$1" --remove-label needs-decision >/dev/null
      "$0" log "$1" "resumed D$id with: $2" || echo "decide.sh: coordination log not written" >&2
    fi
    rm -f "$tmp"
    ;;
  note)
    [ $# -eq 2 ] || die "usage: note <issue> <text>"
    tmp=$(mktemp); printf '<!-- decision-note -->\n%s\n' "$2" >"$tmp"; post "$1" "$tmp"; rm -f "$tmp"
    ;;
  log)
    case "${1:-}" in
      --path) [ $# -eq 2 ] || die "usage: log --path <issue>"; echo "$(log_dir)/$2.md" ;;
      --rm) [ $# -eq 2 ] || die "usage: log --rm <issue>"; rm -f "$(log_dir)/$2.md" ;;
      --prune)
        d=$(log_dir); [ -d "$d" ] || exit 0
        for f in "$d"/*.md; do
          [ -e "$f" ] || continue; n=$(basename "$f" .md)
          [ "$(gh issue view "$n" --json state --jq .state 2>/dev/null)" = CLOSED ] && rm -f "$f" && echo "pruned #$n"
        done; true ;;
      *)
        [ $# -eq 2 ] || die "usage: log <issue> <text>"
        d=$(log_dir); mkdir -p "$d"; f="$d/$1.md"
        [ -s "$f" ] || printf '# Coordination log #%s (%s)\n\n' "$1" "$REPO" >"$f"
        printf -- '- %s %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$(printf '%s' "$2" | tr '\n' ' ')" >>"$f" ;;
    esac
    ;;
  check)
    [ $# -eq 1 ] && [ -f "$1" ] || die "usage: check <file>"
    check "$1"
    ;;
  followup)
    [ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: followup <issue> <new issue> [D<k>]"
    id=$(decision_id "$1" "${3:-}"); tmp=$(mktemp)
    printf '<!-- decision-followup D%s -->\nChange request moved to #%s.\n' "$id" "$2" >"$tmp"
    post "$1" "$tmp"; rm -f "$tmp"
    ;;
  status)
    scan "" open | while IFS=$'\x1f' read -r n url kind id q secs ans _prev; do
      if [ "$kind" = answered ] || { [ "$kind" = request ] && [ -n "$ans" ]; }; then
        echo "answered #$n $id: $ans"
      elif [ "$kind" = request ]; then
        echo "waiting  #$n $id ($(age "$secs")): $q"
      fi
    done
    scan agent-decided open | while IFS=$'\x1f' read -r n url kind id q secs ans _prev; do
      if { [ "$kind" = record ] || [ "$kind" = followup ]; } && [ -n "$ans" ]; then echo "change   #$n $id: $ans"; fi
    done
    ;;
  digest)
    due=""; idle=0; cap=7200
    while [ $# -gt 0 ]; do
      case "$1" in
        --due) due=${2:?}; shift 2 ;;
        --idle) idle=1; shift ;;
        --cap) cap=${2:?}; shift 2 ;;
        *) die "unknown digest flag $1" ;;
      esac
    done
    rows=$(scan "" open | awk -F'\037' '$3 == "request" && $7 == ""' | sort -t$'\037' -k6,6nr)
    [ -n "$rows" ] || { [ -n "$due" ] && exit 1; echo "no open decision requests"; exit 0; }
    if [ -n "$due" ]; then
      touch "$due"
      fire=$idle
      while IFS=$'\x1f' read -r n url kind id q secs ans _prev; do
        grep -qx "#$n $id" "$due" || { [ "$secs" -ge "$cap" ] && fire=1; }
      done <<<"$rows"
      [ "$fire" = 1 ] || exit 1
    fi
    count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    repo=$(gh repo view --json url --jq .url)
    echo "$count decision(s) need you:"
    while IFS=$'\x1f' read -r n url kind id q secs ans prev; do
      echo "- #$n $id ($(age "$secs")): $q  $url"
      [ -n "$prev" ] && echo "  preview: $prev"
      [ -n "$due" ] && { grep -qx "#$n $id" "$due" || echo "#$n $id" >>"$due"; }
    done <<<"$rows"
    reviews=$(gh issue list --label agent-decided --state all --limit 100 --json number --jq length)
    echo "Answer on the issue or here (\"385: B\"). All: $repo/issues?q=is:open+label:needs-decision"
    echo "FYI $reviews issue(s) with agent decisions to review: $repo/issues?q=label:agent-decided"
    ;;
  *) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$cmd" ] || exit 64 ;;
esac
