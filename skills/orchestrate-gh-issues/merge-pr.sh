#!/usr/bin/env bash
# Merge-queue steps for the orchestrate-gh-issues coordinator (and the lead's review routing).
# `gh pr merge` is NOT in here: it stays the coordinator's own call between prep and after, so the project's
# pre-merge gate hook (PreToolUse on that command) still fires.
#
#   merge-pr.sh route <pr> | --files <file> [--lines <n>]
#        "lead: <reason>" or "reviewer: <reason>". reviewer when a changed file matches WF_RISK_GLOBS or the
#        changed lines (WF_IGNORE_GLOBS not counted; they never mask a risk file) exceed WF_REVIEW_LINES.
#   merge-pr.sh review-check <body file> [--route lead|reviewer]
#        exit 0 when the PR body's `## Review` is complete: reviewed (`by:`), no finding `-> open`, and not
#        `route: lead` where the route says reviewer. Else exit 1 with the reasons.
#   merge-pr.sh prep <pr>
#        refuse on a hold label, an open needs-decision, no `Closes #<n>` (opt-out: `No-issue: <reason>`) or a
#        failing review-check; then, in the PR's worktree (wf_install first when the base brought a package.json change),
#        merge the base branch in when behind (no rebase, no force-push), wf_verify (+ wf_build when
#        wf_build_needed), push. Prints "ready: gh pr merge <pr> --merge".
#   merge-pr.sh after <pr> "<summary>"
#        PR must be merged: print its gate row (WF_CHECKS_TSV), wf_after_merge, wf_deploy_check, and post the
#        summary on the closed issue via decide.sh note, then delete its coordination log, then sweep.sh --pr <pr>:
#        remove the PR's worktree and branches (and every other finished one). A failing sweep never fails `after`.
#   merge-pr.sh sweep [--dry-run]
#        remove the worktrees and branches of finished work (sweep.sh has the rules): a <type>/<n>-* (or Orca's
#        <gitUsername>/<type>-<n>-*) branch whose PR is merged or closed, a
#        proto/<n>-* branch whose issue is closed (after: also the merged PR's own branch, whatever its name). Keeps, with
#        the reason printed, the main checkout, the current directory, uncommitted or unpushed work and worktrees an
#        Orca worker still uses.
# Project facts: <repo>/.claude/issue-workflow.sh (template: agent-workflow reference/project-config.sh).
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"
die() { echo "merge-pr.sh: $*" >&2; exit 64; }

route_files() { # route_files <file list> <changed lines or empty>
  local list=$1 lines=${2:-0} f risk=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ${#WF_RISK_GLOBS[@]} -gt 0 ] && wf_match "$f" "${WF_RISK_GLOBS[@]}"; then risk="$risk $f"; fi
  done <"$list"
  if [ -n "$risk" ]; then echo "reviewer: risk area:$(echo "$risk" | tr ' ' '\n' | head -3 | tr '\n' ' ')"
  elif [ "$lines" -gt "$WF_REVIEW_LINES" ]; then echo "reviewer: $lines changed lines > $WF_REVIEW_LINES"
  else echo "lead: no risk area, $lines changed lines"; fi
}

route_pr() { # route_pr <pr>: file list and line count (without ignored files) from GitHub
  local pr=$1 tmp lines=0 path add del
  tmp=$(mktemp)
  gh pr view "$pr" --json files -q '.files[] | "\(.path)\t\(.additions)\t\(.deletions)"' >"$tmp.tsv" || die "gh pr view $pr failed"
  cut -f1 "$tmp.tsv" >"$tmp"
  while IFS=$'\t' read -r path add del; do
    wf_match "$path" "${WF_IGNORE_GLOBS[@]+"${WF_IGNORE_GLOBS[@]}"}" || lines=$((lines + add + del))
  done <"$tmp.tsv"
  route_files "$tmp" "$lines"; rm -f "$tmp" "$tmp.tsv"
}

review_check() { # review_check <body file> [route]
  local body=$1 want=${2:-} sec problems=""
  sec=$(awk '/^## Review[[:space:]]*$/{on=1; next} on && /^## /{exit} on' "$body")
  if ! grep -q '^## Review[[:space:]]*$' "$body"; then
    echo "review: '## Review' section missing in the PR body"; return 1
  fi
  printf '%s\n' "$sec" | grep -Eq '^route: .*by: ' || problems="$problems\nreview: not reviewed yet (no 'by:' on the route line)"
  local open; open=$(printf '%s\n' "$sec" | grep -E '^- \[(medium|high|critical)\].*-> *open[[:space:]]*$' || true)
  [ -z "$open" ] || problems="$problems\nreview: open finding(s):\n$open"
  if [ "$want" = reviewer ] && printf '%s\n' "$sec" | grep -Eq '^route: *lead'; then
    problems="$problems\nreview: route says reviewer but the lead reviewed: start a reviewer worker (spec.sh review)"
  fi
  [ -z "$problems" ] && return 0
  printf '%b\n' "${problems#\\n}"; return 1
}

issues_of() { # issues_of <body file>: every issue a line-leading Closes/Fixes/Resolves reference closes
  grep -Eio '^[[:space:]-]*(closes|fixes|resolves) +([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' "$1" | grep -Eo '[0-9]+$'
}

worktree_of() { # worktree path that has <branch> checked out
  git worktree list --porcelain | awk -v b="refs/heads/$1" '/^worktree /{p=substr($0,10)} $0=="branch " b {print p; exit}'
}

cmd=${1:-}; shift || true
wf_load
case "$cmd" in
  route)
    if [ "${1:-}" = --files ]; then
      [ -f "${2:-}" ] || die "route --files <file>"
      lines=0; [ "${3:-}" = --lines ] && lines=${4:?}
      route_files "$2" "$lines"
    else
      [ -n "${1:-}" ] || die "route <pr>"
      route_pr "$1"
    fi ;;
  issues-of)
    [ -f "${1:-}" ] || die "issues-of <body file>"
    issues_of "$1" ;;
  review-check)
    [ -f "${1:-}" ] || die "review-check <body file> [--route lead|reviewer]"
    want=""; [ "${2:-}" = --route ] && want=${3:-}
    review_check "$1" "$want" ;;
  prep)
    pr=${1:?usage: prep <pr>}
    info=$(gh pr view "$pr" --json state,headRefName,baseRefName,labels,body) || die "gh pr view $pr failed"
    [ "$(jq -r .state <<<"$info")" = OPEN ] || die "PR #$pr is not open"
    head=$(jq -r .headRefName <<<"$info"); base=$(jq -r .baseRefName <<<"$info")
    stop=""
    for l in $(jq -r '.labels[].name' <<<"$info"); do
      for h in $WF_HOLD_LABELS; do [ "$l" = "$h" ] && stop="$stop\nhold: PR label $l"; done
    done
    bodyf=$(mktemp); jq -r .body <<<"$info" >"$bodyf"
    issues=$(issues_of "$bodyf" || true)
    # A PR without an issue (e.g. the user's own PR added to a run) opts out with a line-leading `No-issue: <reason>`
    [ -n "$issues" ] || grep -Eq '^No-issue: [^[:space:]]' "$bodyf" ||
      stop="$stop\nPR body has no line-leading 'Closes #<n>' (or 'No-issue: <reason>')"
    for n in $issues; do # every closed issue (a batch PR closes several); a failed lookup holds (fail closed)
      ilabels=$(gh issue view "$n" --json labels -q '.labels[].name') || die "gh issue view $n failed: cannot check holds"
      for l in $ilabels; do
        [ "$l" = needs-decision ] && stop="$stop\nhold: issue #$n has an open needs-decision"
        for h in $WF_HOLD_LABELS; do [ "$l" = "$h" ] && stop="$stop\nhold: issue #$n label $l"; done
      done
    done
    r=$(route_pr "$pr") && [ -n "$r" ] || die "route for PR #$pr failed"
    echo "route $r"
    msg=$(review_check "$bodyf" "${r%%:*}") || stop="$stop\n$msg"
    rm -f "$bodyf"
    if [ -n "$stop" ]; then printf 'NOT READY #%s:%b\n' "$pr" "$stop"; exit 1; fi
    wt=$(worktree_of "$head")
    [ -n "$wt" ] || die "no local worktree has $head checked out; check it out (git worktree add) and rerun"
    git -C "$wt" fetch -q origin "$base" "$head" || die "fetch failed in $wt"
    behind=0; git -C "$wt" merge-base --is-ancestor "origin/$base" HEAD || behind=1
    unpushed=0; [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$wt" rev-parse "origin/$head")" ] || unpushed=1
    if [ $behind = 1 ]; then
      echo "behind origin/$base: merging it in ($wt)"
      premerge=$(git -C "$wt" rev-parse HEAD)
      if ! git -C "$wt" merge -q --no-edit "origin/$base"; then
        git -C "$wt" merge --abort
        die "merge conflict with origin/$base in $wt (merge aborted): route to a fix worker (spec.sh fix --extra: merge origin/$base, resolve, verify, push)"
      fi
    fi
    # a worktree with its own node_modules misses dependencies the merge brought in (verify: command not found)
    if [ $behind = 1 ] && wf_has wf_install && git -C "$wt" diff --name-only "$premerge" HEAD | grep -qx package.json; then
      (cd "$wt" && wf_run wf_install) || die "dependency install failed in $wt (nothing pushed)"
    fi
    if [ $behind = 1 ] || [ $unpushed = 1 ]; then # the head GitHub merges must be the verified one
      (cd "$wt" && wf_run wf_verify) || die "verify failed on the combined head in $wt (nothing pushed)"
      if wf_has wf_build_needed && (cd "$wt" && wf_build_needed "origin/$base"); then
        (cd "$wt" && wf_run wf_build) || die "build failed on the combined head in $wt (nothing pushed)"
      fi
      git -C "$wt" push -q origin "HEAD:$head" || die "push failed in $wt"
    else
      echo "up to date with origin/$base, pushed"
    fi
    echo "ready: gh pr merge $pr --merge" ;;
  after)
    pr=${1:?usage: after <pr> "<summary>"}; summary=${2:?usage: after <pr> "<summary>"}
    info=$(gh pr view "$pr" --json state,headRefOid) || die "gh pr view $pr failed"
    [ "$(jq -r .state <<<"$info")" = MERGED ] || die "PR #$pr is not merged"
    sha=$(jq -r .headRefOid <<<"$info")
    if [ -n "$WF_CHECKS_TSV" ] && [ -f "$WF_CHECKS_TSV" ]; then
      row=$(grep -F "$sha" "$WF_CHECKS_TSV" | tail -1)
      echo "gate: ${row:-no row for $sha (a stamped pass writes none)}"
    fi
    main=$(wf_main_root); [ -n "$main" ] || die "cannot find the main checkout"
    origcwd=$PWD
    cd "$main" || die "cd $main failed"
    wf_load # the main checkout's config, not a worktree's copy
    rc=0
    wf_run wf_after_merge || { rc=1; echo "WARN: wf_after_merge failed in $main"; }
    wf_run wf_deploy_check || rc=1
    bodyf=$(mktemp); gh pr view "$pr" --json body -q .body >"$bodyf" || die "gh pr view $pr failed"
    for n in $(issues_of "$bodyf" || true); do
      "$DIR/decide.sh" note "$n" "$summary" && echo "summary posted on #$n"
      # GitHub sometimes leaves a `Closes` issue open after the merge (W83: #621 #629 #625, #670)
      if [ "$(gh issue view "$n" --json state -q .state 2>/dev/null)" = OPEN ]; then
        gh issue close "$n" --reason completed >/dev/null 2>&1 && echo "closed #$n (GitHub left it open after merging #$pr)" \
          || { rc=1; echo "WARN: #$n is still open after merging #$pr"; }
      fi
      "$DIR/decide.sh" log --rm "$n" # the coordination log ends with the issue
    done
    rm -f "$bodyf"
    "$DIR/sweep.sh" --pr "$pr" --cwd "$origcwd" || echo "WARN: sweep did not finish cleanly (see above); after is not affected"
    exit $rc ;;
  sweep)
    for a in "$@"; do [ "$a" = --dry-run ] || die "sweep [--dry-run]"; done
    exec "$DIR/sweep.sh" "$@" ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$cmd" ] || exit 64 ;;
esac
