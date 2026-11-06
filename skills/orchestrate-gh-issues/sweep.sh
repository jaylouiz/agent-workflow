#!/usr/bin/env bash
# Remove the worktrees and branches of finished work (called by `merge-pr.sh after` and `merge-pr.sh sweep`).
#
#   sweep.sh [--dry-run] [--pr <n>] [--cwd <dir>]
#
# Finished work: a worktree on a `<type>/<n>-*` branch (type fix|feat|test|docs|chore; Orca's `<gitUsername>/<type>-<n>-*`
# form too) whose PR is merged or closed, or on a `proto/<n>-*` branch whose issue <n> is closed; with --pr <n> also the
# worktree on the head branch of merged PR <n>, whatever its name (a PR without an issue). Each one is removed through Orca
# (`orca worktree rm --worktree path:<wt> --delete-branch`; plain `git worktree remove` + `git branch -d` when Orca
# does not manage it), and the remote head branch of a merged PR is deleted when it still sits on the PR's head.
# One line per removal; every worktree kept gets a `kept <path> (<branch>): <reason>` line.
# Never removed: the main checkout, the current directory (--cwd, default $PWD), a worktree with uncommitted or
# untracked changes, commits that are on no remote branch and not in a merged PR, a worktree an unfinished Orca
# worker uses (`orca orchestration worker-list`), an open PR, a branch that matches no finished-work pattern and is not
# the head of the --pr PR.
# Whatever cannot be proven (gh, fetch, run-list or worker-list failing or unreadable) keeps the worktree.
#   --dry-run  print what would be removed, change nothing
#   --pr <n>   also clean up merged PR <n>: the worktree on its head branch whatever the branch is called (same keep
#              rules; not for a fork's PR), its local branch without a worktree, and its remote head branch
# Exit: 0 clean run, 1 something could not be checked or removed (the output says what), 64 usage.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"
die() { echo "sweep.sh: $*" >&2; exit 64; }

dry=0; prn=""; cwd=$PWD
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --pr) prn=${2:-}; [ -n "$prn" ] || die "--pr <n>"; shift ;;
    --cwd) cwd=${2:-}; [ -n "$cwd" ] || die "--cwd <dir>"; shift ;;
    *) die "usage: sweep.sh [--dry-run] [--pr <n>] [--cwd <dir>]" ;;
  esac
  shift
done

rp() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
cwdp=$(rp "$cwd")
main=$(wf_main_root); [ -n "$main" ] || die "not in a git repository"
cd "$main" || die "cd $main failed"
rc=0; removed=0; kept=0
say_kept() { echo "kept $1 (${2:-detached}): $3"; kept=$((kept + 1)); }

if ! git fetch -q --prune origin 2>/dev/null; then
  echo "sweep: git fetch failed: nothing removed (remote branches unknown)"; exit 1
fi

# --pr <n>: the PR's head branch is finished work whatever its name, once the PR is merged. A fork's PR never names
# a local branch (the same name can be unrelated work). Failing to read it only means no extra branch is recognised.
pr_state=""; pr_head=""; pr_oid=""; pr_match=""; pr_viewfail=0
if [ -n "$prn" ]; then
  if info=$(gh pr view "$prn" --json state,headRefName,headRefOid,isCrossRepository 2>/dev/null) &&
     pr_state=$(jq -er .state <<<"$info") && pr_head=$(jq -er .headRefName <<<"$info") && pr_oid=$(jq -er .headRefOid <<<"$info"); then
    [ "$pr_state" != MERGED ] || [ "$(jq -r '.isCrossRepository // false' <<<"$info")" = true ] || pr_match=$pr_head
  else pr_viewfail=1; pr_state=""; pr_head=""; pr_oid=""; fi
fi

# Orca: which worktrees it manages, which paths an unfinished worker uses. orca missing = no Orca workers.
# The busy list reads every Run (without --run Orca scopes worker-list to the Run bound to this terminal), every page
# and every row; whatever cannot be read completely sets busy_err and the sweep keeps everything.
have_orca=0; orca_wts=""; busy=""; busy_err=""
orca_pages() { # orca_pages <kind: run-list|worker-list> <jq filter per page> [orca args]: all pages' filter output on stdout
  local kind=$1 filter=$2 cur="" out i; shift 2
  for i in $(seq 1 200); do # bounded: an endless nextCursor must not hang the sweep
    out=$(orca orchestration "$kind" "$@" --limit 100 ${cur:+--cursor "$cur"} --json 2>/dev/null) || return 1
    jq -r "$filter" <<<"$out" || return 1
    cur=$(jq -r '.result.nextCursor // empty' <<<"$out") || return 1
    [ -n "$cur" ] || return 0
  done
  return 1
}
if command -v orca >/dev/null 2>&1; then
  have_orca=1
  out=$(orca worktree list --json 2>/dev/null) && orca_wts=$(jq -r '.result.worktrees[].path' <<<"$out" 2>/dev/null)
  runs=$(orca_pages run-list '.result.runs | if type == "array" then .[].id else error("runs") end') || busy_err="orca run-list failed"
  if [ -z "$busy_err" ]; then
    # a dispatch that reported (succeeded/failed/stopped) no longer uses its worktree; unknown states count as busy;
    # a released terminal is gone; a row without workspace names no worktree
    wfilter='.result.workers | if type == "array" then .[] else error("workers") end | select(.terminalState != "released")
      | select(.state | IN("succeeded","failed","stopped","completed","cancelled","abandoned") | not)
      | (.workspace | strings) | sub("^.*::"; "")'
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      more=$(orca_pages worker-list "$wfilter" --run "$r") || { busy_err="orca worker-list failed"; break; }
      busy="$busy
$more"
    done <<<"$runs"
  fi
fi
in_list() { # in_list <path> <newline list>: realpath comparison
  local p; p=$(rp "$1")
  while IFS= read -r l; do [ -n "$l" ] && [ "$(rp "$l")" = "$p" ] && return 0; done <<<"$2"
  return 1
}

pr_info() { # pr_info <branch>: "<state> <number> <headRefOid>" of the decisive PR (open > merged > latest closed), or empty
  local j
  j=$(gh pr list --state all --head "$1" --json number,state,headRefOid --limit 50 2>/dev/null) || return 1
  jq -r 'def rank: if .state=="OPEN" then 0 elif .state=="MERGED" then 1 else 2 end;
           sort_by([rank, -.number]) | first // empty | "\(.state) \(.number) \(.headRefOid)"' <<<"$j"
}
in_pr() { # in_pr <commit> <pr head oid>: the commit is the PR's head or part of its history
  git cat-file -e "$2^{commit}" 2>/dev/null && git merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

delete_remote() { # delete_remote <branch> <pr> <oid>: merged PR's head branch, only if it still is the PR's head
  local b=$1 n=$2 oid=$3 tip kids
  tip=$(git rev-parse -q --verify "refs/remotes/origin/$b") || return 0
  if [ "$tip" != "$oid" ]; then echo "kept remote branch origin/$b: moved after PR #$n"; return 0; fi
  kids=$(gh pr list --state open --base "$b" --json number -q '.[].number' 2>/dev/null) || { echo "kept remote branch origin/$b: cannot check PRs based on it"; rc=1; return 0; }
  if [ -n "$kids" ]; then echo "kept remote branch origin/$b: open PR based on it ($(echo $kids | tr ' ' ','))"; return 0; fi
  if [ $dry = 1 ]; then echo "would delete remote branch origin/$b"; return 0; fi
  if git push -q origin --delete "$b" 2>/dev/null; then echo "deleted remote branch origin/$b"; removed=$((removed + 1))
  else echo "WARN: could not delete remote branch origin/$b"; rc=1; fi
}

delete_branch() { # delete_branch <branch> <why>: local branch, only called once its commits are proven safe
  local b=$1
  git show-ref --verify -q "refs/heads/$b" || return 0
  if [ $dry = 1 ]; then echo "would remove branch $b"; return 0; fi
  if git branch -d "$b" >/dev/null 2>&1 || git branch -D "$b" >/dev/null 2>&1; then
    echo "removed branch $b ($2)"; removed=$((removed + 1))
  else echo "WARN: could not remove branch $b"; rc=1; fi
}

handled=""
sweep_one() { # sweep_one <path> <branch ref or empty> <flags>
  local wt=$1 ref=$2 flags=$3 b n kind st pn oid head unpushed why wtp info err
  b=${ref#refs/heads/}
  [ "$wt" = "$main" ] && { say_kept "$wt" "$b" "main checkout"; return; }
  case "$flags" in *prunable*) say_kept "$wt" "$b" "directory missing (git worktree prune)"; return ;; esac
  wtp=$(rp "$wt")
  if [ "$wtp" = "$cwdp" ] || [ "${cwdp#"$wtp"/}" != "$cwdp" ]; then say_kept "$wt" "$b" "current directory"; return; fi
  [ -n "$ref" ] || { say_kept "$wt" "" "detached HEAD"; return; }
  if [[ $b =~ ^(fix|feat|test|docs|chore)/([0-9]+)- ]]; then kind=pr; n=${BASH_REMATCH[2]}
  elif [[ $b =~ ^[^/]+/(fix|feat|test|docs|chore)-([0-9]+)- ]]; then kind=pr; n=${BASH_REMATCH[2]} # Orca: <gitUsername>/<type>-<n>-*
  elif [[ $b =~ ^proto/([0-9]+)- ]]; then kind=proto; n=${BASH_REMATCH[1]}
  elif [ -n "$pr_match" ] && [ "$b" = "$pr_match" ]; then kind=pr; n=$prn # the merged --pr PR's head, any name
  else say_kept "$wt" "$b" "branch name is not <type>/<n>-* or proto/<n>-*"; return; fi

  # 1. is the work finished?
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { say_kept "$wt" "$b" "cannot read HEAD"; return; }
  oid=""; pn=""
  if [ $kind = pr ]; then
    info=$(pr_info "$b") || { say_kept "$wt" "$b" "cannot look up the PR (gh failed)"; rc=1; return; }
    [ -n "$info" ] || { say_kept "$wt" "$b" "no PR for this branch yet"; return; }
    read -r st pn oid <<<"$info"
    [ "$st" != OPEN ] || { say_kept "$wt" "$b" "PR #$pn is open"; return; }
  else
    st=$(gh issue view "$n" --json state -q .state 2>/dev/null) || { say_kept "$wt" "$b" "cannot look up issue #$n (gh failed)"; rc=1; return; }
    [ "$st" = CLOSED ] || { say_kept "$wt" "$b" "issue #$n is ${st:-not closed}"; return; }
  fi

  # 2. keep rules
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then say_kept "$wt" "$b" "uncommitted or untracked changes"; return; fi
  unpushed=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || { say_kept "$wt" "$b" "cannot compare with remote branches"; return; }
  if [ "$st" = MERGED ]; then
    in_pr "$head" "$oid" || { say_kept "$wt" "$b" "commits not in merged PR #$pn"; return; }
  elif [ $kind = pr ]; then # closed without merge
    { [ "$unpushed" = 0 ] && in_pr "$head" "$oid"; } || { say_kept "$wt" "$b" "commits on no remote branch or after PR #$pn closed"; return; }
  elif [ "$unpushed" != 0 ]; then
    say_kept "$wt" "$b" "$unpushed commit(s) on no remote branch"; return
  fi
  if [ $have_orca = 1 ]; then
    [ -z "$busy_err" ] || { say_kept "$wt" "$b" "$busy_err"; rc=1; return; }
    ! in_list "$wt" "$busy" || { say_kept "$wt" "$b" "an Orca worker is still using it"; return; }
  fi

  # 3. remove
  if [ $kind = pr ]; then why="PR #$pn ${st}"; else why="issue #$n closed"; fi
  [ "$st" = MERGED ] && handled="$handled $b "
  if [ $dry = 1 ]; then
    echo "would remove worktree $wt ($why)"
    [ "$st" = MERGED ] && delete_remote "$b" "$pn" "$oid"
    return
  fi
  if [ $have_orca = 1 ] && in_list "$wt" "$orca_wts"; then
    if err=$(orca worktree rm --worktree "path:$wt" --delete-branch 2>&1 >/dev/null); then
      echo "removed worktree $wt ($why, via orca)"; removed=$((removed + 1))
      if git show-ref --verify -q "refs/heads/$b"; then delete_branch "$b" "$why"
      else echo "removed branch $b (via orca)"; removed=$((removed + 1)); fi
    else
      say_kept "$wt" "$b" "orca worktree rm failed: $(echo "$err" | head -1)"; rc=1; return
    fi
  elif err=$(git worktree remove "$wt" 2>&1); then
    echo "removed worktree $wt ($why)"; removed=$((removed + 1))
    delete_branch "$b" "$why"
  else
    say_kept "$wt" "$b" "git worktree remove failed: $(echo "$err" | head -1)"; rc=1; return
  fi
  [ "$st" = MERGED ] && delete_remote "$b" "$pn" "$oid"
}

list=$(mktemp); trap 'rm -f "$list"' EXIT
git worktree list --porcelain | awk '
  /^worktree /{ if (p != "") print p "\t" b "\t" f; p = substr($0, 10); b = ""; f = "" }
  /^branch /{ b = substr($0, 8) }
  /^prunable/{ f = f " prunable" }
  END { if (p != "") print p "\t" b "\t" f }' >"$list"
while IFS=$'\t' read -r p ref fl; do sweep_one "$p" "$ref" "$fl"; done <"$list"

# --pr <n>: the merged PR's branch even when no worktree is left (branch without worktree, remote head branch)
if [ -n "$prn" ]; then
  if [ $pr_viewfail = 1 ]; then echo "sweep: gh pr view $prn failed: its branches were not cleaned up"; rc=1
  else
    st=$pr_state; hb=$pr_head; ho=$pr_oid
    case "$handled" in *" $hb "*) ;; *)
      if [ "$st" != MERGED ]; then echo "sweep: PR #$prn is not merged: its branches were not cleaned up"
      else
        if git worktree list --porcelain | grep -qx "branch refs/heads/$hb"; then :  # checked out: its worktree line says why it stays
        elif git show-ref --verify -q "refs/heads/$hb"; then
          if in_pr "$(git rev-parse "refs/heads/$hb")" "$ho"; then delete_branch "$hb" "PR #$prn MERGED"
          else echo "kept branch $hb: commits not in merged PR #$prn"; kept=$((kept + 1)); fi
        fi
        delete_remote "$hb" "$prn" "$ho"
      fi ;;
    esac
  fi
fi

echo "sweep: removed $removed, kept $kept$([ $dry = 1 ] && echo ' (dry run)')"
exit $rc
