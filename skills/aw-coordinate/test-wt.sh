#!/usr/bin/env bash
# Tests for wt.sh against a local bare origin (no network). Run: bash skills/aw-coordinate/test-wt.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
has() { n=$((n + 1)); printf '%s\n' "$out" | grep -qF -- "$2" || { fail=$((fail + 1)); echo "FAIL [$1] no '$2' in: $out"; }; }
q() { git -c user.email=t@t -c user.name=t "$@"; }
wt() { (cd "$1" && shift && bash "$DIR/wt.sh" "$@" 2>&1); }

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/main" 2>/dev/null
cd "$T/main" || exit 1
q checkout -q -b main; echo a >a; q add a; q commit -q -m init; q push -q -u origin main
git remote set-head origin main >/dev/null
git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main # a later clone checks out main whatever init.defaultBranch is
# what the harness does: a worktree on a branch of its own naming, cut from the default branch
agent() { q -C "$T/main" worktree add -q -b "worktree-$1" "$T/wts/$1" main; }

out=$(wt "$T/main" init feat/7-x); rc=$?
eq "main checkout: refused" "$rc" 1
has "main checkout: says why" "is the main checkout"
eq "main checkout: still on main" "$(git -C "$T/main" branch --show-current)" main

out=$(wt "$T/main" nope); eq "usage: exit 64" "$?" 64
out=$(wt "$T/main" init "bad name"); eq "bad branch name: exit 64" "$?" 64

# a new branch: cut from the fetched default branch, not from the stale local one
git clone -q -b main "$T/origin.git" "$T/other" 2>/dev/null
(cd "$T/other" && echo b >b && q add b && q commit -q -m "main moved" && q push -q origin main)
tip=$(git -C "$T/other" rev-parse HEAD)
agent a1
out=$(wt "$T/wts/a1" init feat/7-x); rc=$?
eq "new branch: exit 0" "$rc" 0
has "new branch: names the source" "branch: feat/7-x (new from origin/main)"
has "new branch: names the worktree" "worktree: $T/wts/a1"
eq "new branch: checked out" "$(git -C "$T/wts/a1" branch --show-current)" feat/7-x
eq "new branch: starts at the fetched default branch" "$(git -C "$T/wts/a1" rev-parse HEAD)" "$tip"
eq "new branch: the harness branch is gone" "$(git -C "$T/main" branch --list worktree-a1)" ""
eq "new branch: no upstream yet (a push sets it)" "$(git -C "$T/wts/a1" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" ""
out=$(wt "$T/wts/a1" init feat/7-x); has "again: nothing to do" "branch: feat/7-x (already here)"

# a dirty worktree is refused
agent a2; echo x >"$T/wts/a2/untracked"
out=$(wt "$T/wts/a2" init feat/8-y); rc=$?
eq "dirty worktree: refused" "$rc" 1
eq "dirty worktree: branch unchanged" "$(git -C "$T/wts/a2" branch --show-current)" worktree-a2
rm "$T/wts/a2/untracked"

# an earlier stage holds the branch: unpushed or uncommitted work keeps it (exit 3, nothing changed)
(cd "$T/wts/a1" && echo c >c && q add c && q commit -q -m work)
out=$(wt "$T/wts/a2" init feat/7-x); rc=$?
eq "other worktree never pushed: exit 3" "$rc" 3
has "never pushed: says so" "was never pushed"
(cd "$T/wts/a1" && q push -q -u origin feat/7-x && echo d >d && q add d && q commit -q -m more)
out=$(wt "$T/wts/a2" init feat/7-x); rc=$?
eq "other worktree with unpushed commits: exit 3" "$rc" 3
has "unpushed commits: says so" "not on origin"
(cd "$T/wts/a1" && q push -q && echo e >dirty)
out=$(wt "$T/wts/a2" init feat/7-x); rc=$?
eq "other worktree dirty: exit 3" "$rc" 3
eq "busy: the other worktree is still there" "$([ -d "$T/wts/a1" ] && echo yes)" yes
eq "busy: this worktree is unchanged" "$(git -C "$T/wts/a2" branch --show-current)" worktree-a2
rm "$T/wts/a1/dirty"

# clean and pushed: taken over, the old worktree removed
head=$(git -C "$T/wts/a1" rev-parse HEAD)
out=$(wt "$T/wts/a2" init feat/7-x); rc=$?
eq "take over: exit 0" "$rc" 0
has "take over: names the old worktree" "taken over from $T/wts/a1"
eq "take over: the old worktree is gone" "$([ -d "$T/wts/a1" ] && echo yes)" ""
eq "take over: same commit" "$(git -C "$T/wts/a2" rev-parse HEAD)" "$head"
eq "take over: on the branch" "$(git -C "$T/wts/a2" branch --show-current)" feat/7-x

# the branch only on origin (another machine, or the harness removed the worktree and the local branch went with a sweep)
(cd "$T/other" && q checkout -q -b fix/9-z && echo z >z && q add z && q commit -q -m z && q push -q origin fix/9-z)
agent a3
out=$(wt "$T/wts/a3" init fix/9-z)
has "origin only: from origin" "branch: fix/9-z (from origin/fix/9-z)"
eq "origin only: tracks it" "$(git -C "$T/wts/a3" rev-parse --abbrev-ref '@{u}')" origin/fix/9-z

# a local branch without a worktree, behind origin: switched to and fast-forwarded
q -C "$T/main" worktree remove "$T/wts/a3"
(cd "$T/other" && echo z2 >z2 && q add z2 && q commit -q -m z2 && q push -q origin fix/9-z)
agent a4
out=$(wt "$T/wts/a4" init fix/9-z)
has "local branch: says so" "branch: fix/9-z (local branch)"
eq "local branch: fast-forwarded to origin" "$(git -C "$T/wts/a4" rev-parse HEAD)" "$(git -C "$T/other" rev-parse fix/9-z)"

# the main checkout holding the branch is never removed
q -C "$T/main" checkout -q -b docs/5-m
agent a5
out=$(wt "$T/wts/a5" init docs/5-m); rc=$?
eq "branch in the main checkout: refused" "$rc" 1
eq "branch in the main checkout: it is still there" "$(git -C "$T/main" branch --show-current)" docs/5-m

echo "wt: $((n - fail))/$n passed"
[ $fail = 0 ]
