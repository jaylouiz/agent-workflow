#!/usr/bin/env bash
# Put a stage's branch into the worktree a subagent runs in (aw-coordinate subagent mode, subagent-mode.md).
# The harness gives every stage subagent a fresh, isolated worktree (`isolation: worktree`) on a branch of its own
# naming; this is the subagent's first command.
#
#   wt.sh init <branch>
#
# Run inside the subagent's worktree. Where the branch comes from, in this order:
#   - it is checked out here already: nothing to do
#   - another worktree holds it (an earlier stage of the issue): that worktree is removed and the branch taken over,
#     only when it is clean and everything on the branch is on origin; else exit 3 and nothing is changed
#   - a local branch, or only origin/<branch>: switched to (fast-forwarded to origin/<branch> when behind)
#   - nowhere: created from the fetched default branch (origin/HEAD, else origin/main)
# The branch the harness made is deleted when it has no commits of its own.
# Refuses (exit 1, nothing changed): the main checkout, a worktree with uncommitted or untracked changes, a failed fetch.
# Prints `worktree: <path>` and `branch: <branch> (<where it came from>)`.
# Exit: 0 ok, 1 refused, 3 the branch's other worktree has uncommitted or unpushed work, 64 usage.
set -uo pipefail
die() { echo "wt.sh: $*" >&2; exit "${2:-1}"; }
[ "${1:-}" = init ] && [ -n "${2:-}" ] && [ $# = 2 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
b=$2
git check-ref-format --branch "$b" >/dev/null 2>&1 || die "not a branch name: $b" 64

top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git repository"
rp() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }
gd=$(rp "$(git rev-parse --git-dir)"); cd_=$(rp "$(git rev-parse --git-common-dir)")
[ "$gd" != "$cd_" ] || die "refusing: $top is the main checkout, not a worktree of its own (start the subagent with isolation: worktree)"
cd "$top" || die "cd $top failed"
old=$(git branch --show-current)
if [ "$old" = "$b" ]; then echo "worktree: $top"; echo "branch: $b (already here)"; exit 0; fi
[ -z "$(git status --porcelain)" ] || die "refusing: $top has uncommitted or untracked changes"
git fetch -q --prune origin 2>/dev/null || die "git fetch origin failed: nothing changed"

def=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); def=${def#origin/}
[ -n "$def" ] || def=main
has() { git show-ref --verify --quiet "$1"; }

# the worktree that holds <branch>, if any
other=$(git worktree list --porcelain | awk -v want="branch refs/heads/$b" '/^worktree /{w = substr($0, 10)} $0 == want {print w; exit}')
if [ -n "$other" ]; then
  main=$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
  [ "$(rp "$other")" != "$(rp "$main")" ] || die "refusing: $b is checked out in the main checkout ($main)"
  [ -z "$(git -C "$other" status --porcelain 2>/dev/null)" ] || die "busy: $other ($b) has uncommitted or untracked changes: nothing changed" 3
  has "refs/remotes/origin/$b" || die "busy: $b in $other was never pushed: nothing changed" 3
  [ "$(git rev-list --count "origin/$b..$b")" = 0 ] || die "busy: $b in $other has commits that are not on origin: nothing changed" 3
  git worktree remove "$other" >/dev/null 2>&1 || die "busy: git worktree remove $other failed: nothing changed" 3
  from="taken over from $other"
fi

if has "refs/heads/$b"; then
  git switch -q "$b" || die "git switch $b failed"
  from=${from:-local branch}
elif has "refs/remotes/origin/$b"; then
  git switch -q -c "$b" --track "origin/$b" || die "git switch -c $b origin/$b failed"
  from="from origin/$b"
else
  has "refs/remotes/origin/$def" || die "no origin/$def to start $b from"
  git switch -q -c "$b" --no-track "origin/$def" || die "git switch -c $b origin/$def failed"
  from="new from origin/$def"
fi
if has "refs/remotes/origin/$b" && [ "$(git rev-list --count "origin/$b..HEAD")" = 0 ]; then
  git merge -q --ff-only "origin/$b" 2>/dev/null || true # behind origin: catch up; ahead or diverged: left as it is
fi
# the harness's own branch: gone when it carries nothing (its tip is on the default branch)
if [ -n "$old" ] && [ "$old" != "$def" ] && git merge-base --is-ancestor "$old" "origin/$def" 2>/dev/null; then
  git branch -q -D "$old" 2>/dev/null || true
fi
echo "worktree: $top"
echo "branch: $b ($from)"
