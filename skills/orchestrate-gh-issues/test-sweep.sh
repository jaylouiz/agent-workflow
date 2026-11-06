#!/usr/bin/env bash
# Tests for sweep.sh (worktree and branch cleanup of finished work) against a hermetic fixture: temp git repos,
# a bare origin, stubbed `orca` and `gh` on PATH. Nothing here touches a real repo or the real Orca.
# Run: bash skills/orchestrate-gh-issues/test-sweep.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
q() { git -c user.email=t@t -c user.name=t "$@"; }
has() { n=$((n + 1)); printf '%s\n' "$OUT" | grep -Eq -- "$2" || { fail=$((fail + 1)); echo "FAIL [$1] no line matching '$2' in:"; printf '%s\n' "$OUT" | sed 's/^/    /'; }; }
hasnt() { n=$((n + 1)); ! printf '%s\n' "$OUT" | grep -Eq -- "$2" || { fail=$((fail + 1)); echo "FAIL [$1] unexpected line matching '$2'"; }; }
slug() { echo "${1//\//_}"; }
JQ=$(dirname "$(command -v jq)"); GIT=$(dirname "$(command -v git)")

# stubs: state lives in $STUB/{gh,orca}/ files; every orca call is logged
export STUB=$T/stub; mkdir -p "$STUB/gh" "$STUB/orca" "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
G=$STUB/gh; [ ! -f "$G/fail" ] || { echo "gh down" >&2; exit 1; }
s() { echo "${1//\//_}"; }
case "$*" in
  "pr list --state all --head "*) b=$6; [ -f "$G/pr-$(s "$b")" ] && cat "$G/pr-$(s "$b")" || echo '[]' ;;
  "pr list --state open --base "*) b=$6; [ -f "$G/base-$(s "$b")" ] && cat "$G/base-$(s "$b")" || true ;;
  "issue view "*) cat "$G/issue-$3" ;;
  "pr view "*) cat "$G/view-$3" ;;
  *) echo "gh stub: $*" >&2; exit 1 ;;
esac
EOF
cat >"$T/bin/orca" <<'EOF'
#!/usr/bin/env bash
O=$STUB/orca; echo "$*" >>"$O/calls"
case "$1 $2" in
  "worktree list") jq -Rn '[inputs | {path: .}] | {ok: true, result: {worktrees: .}}' <"$O/managed" ;;
  "worktree rm")
    [ "${4#path:}" != "$(cat "$O/rmfail" 2>/dev/null)" ] || { echo "orca: boom" >&2; exit 1; }
    wt=${4#path:}; b=$(git -C "$wt" branch --show-current)
    git -C "$wt" worktree remove "$wt" 2>&1 >/dev/null || exit 1 # orca never forces; a dirty tree fails
    git -C "$MAIN" branch -D "$b" >/dev/null 2>&1; echo '{"ok":true}' ;;
  "orchestration run-list"|"orchestration worker-list")
    # like the real CLI: without --run the list is scoped to the Run bound to the caller (here: a Run with no workers)
    kind=$2; run=""; cur=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --run) run=$2; shift ;; --cursor) cur=$2; shift ;; esac; shift; done
    [ ! -f "$O/wlfail" ] || { echo "orca: down" >&2; exit 1; }
    if [ "$kind" = run-list ]; then f=$O/runs${cur:+-$cur}; d='{"ok":true,"result":{"runs":[{"id":"r1"}],"nextCursor":null}}'
    else [ -n "$run" ] || { echo '{"ok":true,"result":{"workers":[],"scope":{"source":"bound"},"nextCursor":null}}'; exit 0; }
      f=$O/workers-$run${cur:+-$cur}; d='{"ok":true,"result":{"workers":[],"nextCursor":null}}'; fi
    if [ -f "$f" ]; then cat "$f"; elif [ -z "$cur" ]; then echo "$d"; else echo "orca: bad cursor" >&2; exit 1; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/bin/orca"
export PATH="$T/bin:$GIT:$JQ:/usr/bin:/bin" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# fresh fixture: bare origin + main checkout with one commit
fixture() {
  rm -rf "$T/fx" "$STUB/gh/"* "$STUB/orca/"*; mkdir -p "$T/fx/wts"; : >"$STUB/orca/managed"
  git init -q --bare "$T/fx/origin.git"; git clone -q "$T/fx/origin.git" "$T/fx/main" 2>/dev/null
  export MAIN=$T/fx/main
  (cd "$MAIN" && q checkout -q -b main && echo a >a && q add a && q commit -qm init && q push -q -u origin main 2>/dev/null)
}
# wt <branch> [local|pushed]: worktree on a new branch with one commit, pushed unless "local"
wt() {
  local b=$1 d; d=$T/fx/wts/$(slug "$b")
  git -C "$MAIN" worktree add -q -b "$b" "$d" main 2>/dev/null
  (cd "$d" && echo "$b" >f && q add f && q commit -qm "$b") || return 1
  [ "${2:-pushed}" = local ] || git -C "$d" push -q -u origin "$b" 2>/dev/null
}
tip() { git -C "$MAIN" rev-parse "refs/heads/$1"; }
dirof() { echo "$T/fx/wts/$(slug "$1")"; }
# prs <branch> <state> <number> [oid]: PR list entry for a branch (oid defaults to the local tip)
prs() { printf '[{"number":%s,"state":"%s","headRefOid":"%s"}]\n' "$3" "$2" "${4:-$(tip "$1")}" >"$STUB/gh/pr-$(slug "$1")"; }
managed() { dirof "$1" >>"$STUB/orca/managed"; }
exists() { [ -d "$(dirof "$1")" ] && echo yes || echo no; }
branch() { git -C "$MAIN" show-ref --verify -q "refs/heads/$1" && echo yes || echo no; }
remote() { git -C "$MAIN" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1 && echo yes || echo no; }
sweep() { OUT=$(cd "$MAIN" && bash "$DIR/sweep.sh" "$@" 2>&1); RC=$?; }

fixture
# --- finished work: removed
wt feat/1-merged-orca; prs feat/1-merged-orca MERGED 101; managed feat/1-merged-orca
wt fix/2-merged-git;   prs fix/2-merged-git MERGED 102
wt chore/3-closed;     prs chore/3-closed CLOSED 103
wt proto/4-design;     echo CLOSED >"$STUB/gh/issue-4"
wt fix/16-remote-moved; prs fix/16-remote-moved MERGED 116
(cd "$T/fx" && git clone -q origin.git other 2>/dev/null && cd other && q checkout -q fix/16-remote-moved && echo more >g && q add g && q commit -qm later && q push -q 2>/dev/null)
wt feat/17-stacked;    prs feat/17-stacked MERGED 117; echo 118 >"$STUB/gh/base-feat_17-stacked"
wt test/12-stale-worker; prs test/12-stale-worker MERGED 112
# --- kept
wt proto/5-open;       echo OPEN >"$STUB/gh/issue-5"
wt feat/6-open-pr;     prs feat/6-open-pr OPEN 106
wt fix/7-dirty;        prs fix/7-dirty MERGED 107; echo change >>"$(dirof fix/7-dirty)/f"
wt fix/8-untracked;    prs fix/8-untracked MERGED 108; echo x >"$(dirof fix/8-untracked)/new"
wt feat/9-ahead;       prs feat/9-ahead MERGED 109; (cd "$(dirof feat/9-ahead)" && echo e >e && q add e && q commit -qm extra)
wt docs/10-closed-local; prs docs/10-closed-local CLOSED 110; (cd "$(dirof docs/10-closed-local)" && echo e >e && q add e && q commit -qm extra)
wt test/11-worker;     prs test/11-worker MERGED 111
printf '%s\n' '{"ok":true,"result":{"workers":[{"state":"succeeded","terminalState":"retained","workspace":"id::'"$(dirof test/12-stale-worker)"'"},{"state":"ready","terminalState":"retained","workspace":"id::'"$(dirof test/11-worker)"'"}],"nextCursor":null}}' >"$STUB/orca/workers-r1"
wt feat/13-cwd;        prs feat/13-cwd MERGED 113
wt someone/fix-14-orca-name; prs someone/fix-14-orca-name MERGED 114
wt scratch/14-other-name; prs scratch/14-other-name MERGED 124
wt someone/fix-24-orca-dirty; prs someone/fix-24-orca-dirty MERGED 125; echo change >>"$(dirof someone/fix-24-orca-dirty)/f"
wt someone/chore-26-orca-open; prs someone/chore-26-orca-open OPEN 126
wt feat/15-no-pr
wt proto/20-local-only local; echo CLOSED >"$STUB/gh/issue-20"
wt fix/21-locked;      prs fix/21-locked MERGED 121; git -C "$MAIN" worktree lock "$(dirof fix/21-locked)"
wt feat/22-detached;   prs feat/22-detached MERGED 122; git -C "$(dirof feat/22-detached)" checkout -q --detach
wt fix/23-orca-rmfail; prs fix/23-orca-rmfail MERGED 123; managed fix/23-orca-rmfail

snap() { git -C "$MAIN" worktree list | wc -l | tr -d ' '; }
before=$(snap); heads=$(git -C "$MAIN" branch --list | wc -l | tr -d ' ')

# dry run: reports, changes nothing
sweep --dry-run
eq "dry run rc" "$RC" 0
has "dry run says would remove" 'would remove worktree .*merged-orca'
has "dry run says would delete remote" 'would delete remote branch origin/fix/2-merged-git'
eq "dry run changes no worktree" "$(snap)" "$before"
eq "dry run changes no branch" "$(git -C "$MAIN" branch --list | wc -l | tr -d ' ')" "$heads"
eq "dry run keeps remote" "$(remote fix/2-merged-git)" yes
eq "dry run never called orca rm" "$(grep -c 'worktree rm' "$STUB/orca/calls" 2>/dev/null || true)" 0
has "dry run summary" 'sweep: removed 0, kept .*\(dry run\)'

# real run (orca fails to remove one managed worktree)
dirof fix/23-orca-rmfail >"$STUB/orca/rmfail"
sweep --cwd "$(dirof feat/13-cwd)/"
eq "rc 1 when a removal failed" "$RC" 1

has "merged via orca: worktree" "removed worktree .*merged-orca \(PR #101 MERGED, via orca\)"
eq "merged via orca: dir gone" "$(exists feat/1-merged-orca)" no
eq "merged via orca: branch gone" "$(branch feat/1-merged-orca)" no
has "merged via orca: remote" "deleted remote branch origin/feat/1-merged-orca"
eq "merged via orca: remote gone" "$(remote feat/1-merged-orca)" no
eq "orca called as specified" "$(grep -c "^worktree rm --worktree path:$(dirof feat/1-merged-orca) --delete-branch$" "$STUB/orca/calls")" 1

has "merged, git fallback: worktree" "removed worktree .*fix_2-merged-git \(PR #102 MERGED\)"
has "merged, git fallback: branch" "removed branch fix/2-merged-git \(PR #102 MERGED\)"
eq "git fallback: dir gone" "$(exists fix/2-merged-git)" no
eq "git fallback: branch gone (squash: not an ancestor of main)" "$(branch fix/2-merged-git)" no
eq "git fallback: remote gone" "$(remote fix/2-merged-git)" no
eq "no orca rm for unmanaged" "$(grep -c "path:.*fix_2-merged-git" "$STUB/orca/calls" || true)" 0

has "closed PR removed" "removed worktree .*chore_3-closed \(PR #103 CLOSED\)"
eq "closed PR: branch gone" "$(branch chore/3-closed)" no
eq "closed PR: remote branch stays" "$(remote chore/3-closed)" yes
has "proto with closed issue" "removed worktree .*proto_4-design \(issue #4 closed\)"
eq "proto: branch gone" "$(branch proto/4-design)" no
eq "proto: remote stays" "$(remote proto/4-design)" yes
has "remote moved after merge" "kept remote branch origin/fix/16-remote-moved: moved after PR #116"
eq "remote moved: still there" "$(remote fix/16-remote-moved)" yes
eq "remote moved: worktree removed" "$(exists fix/16-remote-moved)" no
has "stacked PR keeps remote" "kept remote branch origin/feat/17-stacked: open PR based on it \(118\)"
eq "stacked: remote there" "$(remote feat/17-stacked)" yes
eq "finished dispatch of a retained terminal does not block" "$(exists test/12-stale-worker)" no

has "open issue proto kept" "kept .*proto_5-open \(proto/5-open\): issue #5 is OPEN"
has "open PR kept" "kept .*feat_6-open-pr .*: PR #106 is open"
has "dirty kept" "kept .*fix_7-dirty .*: uncommitted or untracked changes"
has "untracked kept" "kept .*fix_8-untracked .*: uncommitted or untracked changes"
has "ahead of merged PR kept" "kept .*feat_9-ahead .*: commits not in merged PR #109"
has "closed PR with local commit kept" "kept .*docs_10-closed-local .*: commits on no remote branch or after PR #110 closed"
has "active worker kept" "kept .*test_11-worker .*: an Orca worker is still using it"
has "cwd kept" "kept .*feat_13-cwd .*: current directory"
has "orca-prefixed branch removed" "removed worktree .*someone_fix-14-orca-name \(PR #114 MERGED\)"
eq "orca-prefixed: dir gone" "$(exists someone/fix-14-orca-name)" no
eq "orca-prefixed: branch gone" "$(branch someone/fix-14-orca-name)" no
eq "orca-prefixed: remote gone" "$(remote someone/fix-14-orca-name)" no
has "orca-prefixed dirty kept" "kept .*fix-24-orca-dirty .*: uncommitted or untracked changes"
has "orca-prefixed open PR kept" "kept .*chore-26-orca-open .*: PR #126 is open"
has "other naming kept" "kept .*scratch_14-other-name .*: branch name is not"
eq "other naming: intact" "$(exists scratch/14-other-name):$(branch scratch/14-other-name)" "yes:yes"
has "no PR kept" "kept .*feat_15-no-pr .*: no PR for this branch yet"
has "proto with unpushed commits kept" "kept .*proto_20-local-only .*: 1 commit\(s\) on no remote branch"
has "locked worktree kept" "kept .*fix_21-locked .*: git worktree remove failed"
has "detached kept" "kept .*feat_22-detached \(detached\): detached HEAD"
has "orca rm failure kept" "kept .*fix_23-orca-rmfail .*: orca worktree rm failed: orca: boom"
has "main checkout kept" "kept $MAIN \(main\): main checkout"
for k in someone/fix-24-orca-dirty someone/chore-26-orca-open feat/9-ahead docs/10-closed-local test/11-worker feat/13-cwd feat/15-no-pr proto/20-local-only fix/7-dirty fix/8-untracked feat/6-open-pr proto/5-open; do
  eq "kept intact: $k" "$(exists "$k"):$(branch "$k")" "yes:yes"
done
eq "dirty file content survives" "$(tail -1 "$(dirof fix/7-dirty)/f")" change
eq "untracked file survives" "$(cat "$(dirof fix/8-untracked)/new")" x
eq "current dir (inside the worktree) is also kept" "$( (cd "$MAIN" && OUT=$(bash "$DIR/sweep.sh" --cwd "$(dirof feat/13-cwd)/sub/dir" 2>&1); echo "$OUT" | grep -c 'feat_13-cwd.*current directory'))" 1

# rerun is a no-op for what is already gone
sweep --cwd "$(dirof feat/13-cwd)"
has "rerun: nothing left to remove" "sweep: removed 0, kept"

# --- no Orca at all: git fallback
fixture; wt feat/1-m; prs feat/1-m MERGED 1
mkdir "$T/noorca"; ln -s "$T/bin/gh" "$T/noorca/gh"
OUT=$(cd "$MAIN" && PATH="$T/noorca:$GIT:$JQ:/usr/bin:/bin" bash "$DIR/sweep.sh" 2>&1); RC=$?
eq "no orca: rc" "$RC" 0
has "no orca: removed" "removed worktree .*feat_1-m \(PR #1 MERGED\)"

# --- gh down: nothing removed, rc 1
fixture; wt feat/1-m; prs feat/1-m MERGED 1; touch "$STUB/gh/fail"
sweep; eq "gh down rc" "$RC" 1
has "gh down keeps" "kept .*feat_1-m .*: cannot look up the PR \(gh failed\)"
eq "gh down keeps worktree" "$(exists feat/1-m)" yes

# --- orca worker list unavailable: fail closed
fixture; wt feat/1-m; prs feat/1-m MERGED 1; touch "$STUB/orca/wlfail"
sweep; eq "worker-list down rc" "$RC" 1
has "worker-list down keeps" "kept .*feat_1-m .*: orca run-list failed"
eq "worker-list down keeps worktree" "$(exists feat/1-m)" yes

# --- fetch fails: nothing removed
fixture; wt feat/1-m; prs feat/1-m MERGED 1; git -C "$MAIN" remote set-url origin "$T/nonexistent.git"
sweep; eq "fetch down rc" "$RC" 1
has "fetch down message" "git fetch failed: nothing removed"
eq "fetch down keeps worktree" "$(exists feat/1-m)" yes

# --- the busy check reads every Run (a bound coordinator's default list covers one Run only), all pages, every row
# worker row of another Run, a row without workspace first, a second page: the busy worktree is still kept
busyrow() { printf '{"state":"ready","terminalState":"active","workspace":"id::%s"}' "$(dirof "$1")"; }
fixture; wt feat/1-m; prs feat/1-m MERGED 1
echo '{"ok":true,"result":{"runs":[{"id":"r1"},{"id":"r2"}],"nextCursor":null}}' >"$STUB/orca/runs"
printf '{"ok":true,"result":{"workers":[%s],"nextCursor":null}}\n' "$(busyrow feat/1-m)" >"$STUB/orca/workers-r2"
sweep; has "worker of another Run keeps" "kept .*feat_1-m .*: an Orca worker is still using it"
eq "worker of another Run: worktree stays" "$(exists feat/1-m)" yes
eq "worker of another Run: sweep ok" "$RC" 0
grep -q -- "--run r2" "$STUB/orca/calls"; eq "worker-list called with --run per Run" "$?" 0

fixture; wt feat/1-m; prs feat/1-m MERGED 1
printf '{"ok":true,"result":{"workers":[{"state":"ready","terminalState":"retained","workspace":null,"dispatchId":"ctx_x"},{"state":"ready","terminalState":"active"},%s],"nextCursor":null}}\n' "$(busyrow feat/1-m)" >"$STUB/orca/workers-r1"
sweep; has "null workspace row does not drop the rest" "kept .*feat_1-m .*: an Orca worker is still using it"
eq "null workspace row: worktree stays" "$(exists feat/1-m)" yes
eq "null workspace row: rc" "$RC" 0

fixture; wt feat/1-m; prs feat/1-m MERGED 1; wt feat/2-m; prs feat/2-m MERGED 2
printf '{"ok":true,"result":{"workers":[%s],"nextCursor":"p2"}}\n' "$(busyrow feat/1-m)" >"$STUB/orca/workers-r1"
printf '{"ok":true,"result":{"workers":[%s],"nextCursor":null}}\n' "$(busyrow feat/2-m)" >"$STUB/orca/workers-r1-p2"
echo '{"ok":true,"result":{"runs":[{"id":"r1"}],"nextCursor":"q2"}}' >"$STUB/orca/runs"
echo '{"ok":true,"result":{"runs":[{"id":"r3"}],"nextCursor":null}}' >"$STUB/orca/runs-q2"
printf '{"ok":true,"result":{"workers":[%s],"nextCursor":null}}\n' "$(busyrow feat/3-m)" >"$STUB/orca/workers-r3"
wt feat/3-m; prs feat/3-m MERGED 3
sweep
has "page 2 of workers keeps" "kept .*feat_2-m .*: an Orca worker is still using it"
has "page 1 of workers keeps" "kept .*feat_1-m .*: an Orca worker is still using it"
has "page 2 of Runs keeps" "kept .*feat_3-m .*: an Orca worker is still using it"

# fail safe: whatever of the busy list cannot be read keeps everything, with the reason
fixture; wt feat/1-m; prs feat/1-m MERGED 1
echo 'not json' >"$STUB/orca/runs"
sweep; eq "bad run-list rc" "$RC" 1; has "bad run-list keeps" "kept .*feat_1-m .*: orca run-list failed"
eq "bad run-list keeps worktree" "$(exists feat/1-m)" yes
fixture; wt feat/1-m; prs feat/1-m MERGED 1
echo '{"ok":true,"result":{"workers":[],"nextCursor":"gone"}}' >"$STUB/orca/workers-r1"
sweep; eq "paging failure rc" "$RC" 1; has "paging failure keeps" "kept .*feat_1-m .*: orca worker-list failed"
eq "paging failure keeps worktree" "$(exists feat/1-m)" yes
fixture; wt feat/1-m; prs feat/1-m MERGED 1
echo '{"ok":true,"result":{"workers":"x"}}' >"$STUB/orca/workers-r1"
sweep; has "bad worker JSON keeps" "kept .*feat_1-m .*: orca worker-list failed"
fixture; wt feat/1-m; prs feat/1-m MERGED 1
echo '{"ok":true,"result":{"runs":[{"id":"r1"}],"nextCursor":"loop"}}' >"$STUB/orca/runs"
cp "$STUB/orca/runs" "$STUB/orca/runs-loop"
sweep; has "endless paging is cut off, nothing removed" "kept .*feat_1-m .*: orca run-list failed"

# --- --pr: merged PR without a worktree; unmerged PR
fixture; wt feat/30-gone; prs feat/30-gone MERGED 30
git -C "$MAIN" worktree remove "$(dirof feat/30-gone)"
printf '{"state":"MERGED","headRefName":"feat/30-gone","headRefOid":"%s"}' "$(tip feat/30-gone)" >"$STUB/gh/view-30"
sweep --pr 30
has "--pr: branch without worktree" "removed branch feat/30-gone \(PR #30 MERGED\)"
has "--pr: remote head" "deleted remote branch origin/feat/30-gone"
eq "--pr: local gone" "$(branch feat/30-gone)" no
eq "--pr: remote gone" "$(remote feat/30-gone)" no
fixture; wt feat/31-open; printf '{"state":"OPEN","headRefName":"feat/31-open","headRefOid":"x"}' >"$STUB/gh/view-31"; prs feat/31-open OPEN 31
sweep --pr 31
has "--pr unmerged is left alone" "PR #31 is not merged"
eq "--pr unmerged: remote stays" "$(remote feat/31-open)" yes
fixture; wt feat/32-ahead; prs feat/32-ahead MERGED 32
printf '{"state":"MERGED","headRefName":"feat/32-ahead","headRefOid":"%s"}' "$(tip feat/32-ahead)" >"$STUB/gh/view-32"
git -C "$MAIN" worktree remove "$(dirof feat/32-ahead)"; git -C "$MAIN" branch -f feat/32-ahead main
(cd "$MAIN" && git worktree add -q "$T/fx/tmpwt" feat/32-ahead && cd "$T/fx/tmpwt" && echo z >z && q add z && q commit -qm later) && git -C "$MAIN" worktree remove "$T/fx/tmpwt"
sweep --pr 32
has "--pr: local branch with commits outside the PR kept" "kept branch feat/32-ahead: commits not in merged PR #32"
eq "--pr: that branch survives" "$(branch feat/32-ahead)" yes

# --- --pr <n>: the merged PR's own worktree whatever its branch is named (No-issue PR, retro record)
viewpr() { # viewpr <n> <branch> <state> [cross-repo: true|false]: gh pr view stub for PR <n>
  printf '{"state":"%s","headRefName":"%s","headRefOid":"%s","isCrossRepository":%s}' "$3" "$2" "$(tip "$2")" "${4:-false}" >"$STUB/gh/view-$1"; }
fixture; wt chore/retro-run_abc; prs chore/retro-run_abc MERGED 40; viewpr 40 chore/retro-run_abc MERGED
sweep
has "unnumbered branch kept without --pr" "kept .*chore_retro-run_abc .*: branch name is not"
eq "unnumbered, no --pr: intact" "$(exists chore/retro-run_abc):$(branch chore/retro-run_abc)" "yes:yes"
sweep --dry-run --pr 40
has "--pr dry run: would remove the unnumbered worktree" "would remove worktree .*chore_retro-run_abc \(PR #40 MERGED\)"
eq "--pr dry run: intact" "$(exists chore/retro-run_abc)" yes
sweep --pr 40
eq "--pr unnumbered: rc" "$RC" 0
has "--pr removes the unnumbered worktree" "removed worktree .*chore_retro-run_abc \(PR #40 MERGED\)"
has "--pr unnumbered: branch" "removed branch chore/retro-run_abc \(PR #40 MERGED\)"
has "--pr unnumbered: remote" "deleted remote branch origin/chore/retro-run_abc"
eq "--pr unnumbered: dir gone" "$(exists chore/retro-run_abc)" no
eq "--pr unnumbered: branch gone" "$(branch chore/retro-run_abc)" no
eq "--pr unnumbered: remote gone" "$(remote chore/retro-run_abc)" no
has "--pr unnumbered: summary" "sweep: removed 3, kept 1"

# a --pr worktree is removed through Orca when Orca manages it, and other unnumbered branches stay untouched
fixture; wt chore/retro-o; prs chore/retro-o MERGED 41; viewpr 41 chore/retro-o MERGED; managed chore/retro-o
wt wip/other; prs wip/other MERGED 42
sweep --pr 41
has "--pr via orca" "removed worktree .*chore_retro-o \(PR #41 MERGED, via orca\)"
has "--pr: another unnumbered branch kept" "kept .*wip_other .*: branch name is not"
eq "--pr: another unnumbered branch intact" "$(exists wip/other):$(branch wip/other)" "yes:yes"

# keep rules still apply to the --pr worktree
fixture; wt chore/dirty-pr; prs chore/dirty-pr MERGED 43; viewpr 43 chore/dirty-pr MERGED; echo change >>"$(dirof chore/dirty-pr)/f"
sweep --pr 43
has "--pr dirty kept" "kept .*chore_dirty-pr .*: uncommitted or untracked changes"
fixture; wt chore/untracked-pr; prs chore/untracked-pr MERGED 44; viewpr 44 chore/untracked-pr MERGED; echo x >"$(dirof chore/untracked-pr)/new"
sweep --pr 44
has "--pr untracked kept" "kept .*chore_untracked-pr .*: uncommitted or untracked changes"
fixture; wt chore/ahead-pr; prs chore/ahead-pr MERGED 45; viewpr 45 chore/ahead-pr MERGED
(cd "$(dirof chore/ahead-pr)" && echo e >e && q add e && q commit -qm extra)
sweep --pr 45
has "--pr with commits outside the PR kept" "kept .*chore_ahead-pr .*: commits not in merged PR #45"
fixture; wt chore/busy-pr; prs chore/busy-pr MERGED 46; viewpr 46 chore/busy-pr MERGED
printf '{"ok":true,"result":{"workers":[%s],"nextCursor":null}}\n' "$(busyrow chore/busy-pr)" >"$STUB/orca/workers-r1"
sweep --pr 46
has "--pr worktree in use by a worker kept" "kept .*chore_busy-pr .*: an Orca worker is still using it"
fixture; wt chore/cwd-pr; prs chore/cwd-pr MERGED 47; viewpr 47 chore/cwd-pr MERGED
sweep --pr 47 --cwd "$(dirof chore/cwd-pr)/sub"
has "--pr worktree that is the cwd kept" "kept .*chore_cwd-pr .*: current directory"
fixture; wt chore/open-pr; prs chore/open-pr OPEN 48; viewpr 48 chore/open-pr MERGED
sweep --pr 48
has "--pr: an open PR on the same head keeps it" "kept .*chore_open-pr .*: PR #48 is open"
fixture; wt chore/unmerged-pr; prs chore/unmerged-pr OPEN 49; viewpr 49 chore/unmerged-pr OPEN
sweep --pr 49
has "--pr not merged: kept" "kept .*chore_unmerged-pr .*: branch name is not"
has "--pr not merged: said so" "PR #49 is not merged"
eq "--pr not merged: intact" "$(exists chore/unmerged-pr):$(branch chore/unmerged-pr)" "yes:yes"
fixture; wt chore/fork-pr; prs chore/fork-pr MERGED 50; viewpr 50 chore/fork-pr MERGED true
sweep --pr 50
has "--pr from a fork never matches a local branch" "kept .*chore_fork-pr .*: branch name is not"
eq "--pr fork: intact" "$(exists chore/fork-pr):$(branch chore/fork-pr)" "yes:yes"
fixture; wt chore/gh-down-pr; prs chore/gh-down-pr MERGED 51; viewpr 51 chore/gh-down-pr MERGED; touch "$STUB/gh/fail"
sweep --pr 51
eq "--pr with gh down: rc" "$RC" 1
eq "--pr with gh down: intact" "$(exists chore/gh-down-pr):$(branch chore/gh-down-pr)" "yes:yes"
fixture; wt chore/other-pr; prs chore/other-pr MERGED 52; wt chore/named-pr; prs chore/named-pr MERGED 53; viewpr 53 chore/named-pr MERGED
sweep --pr 53
has "--pr removes only PR <n>'s branch" "removed worktree .*chore_named-pr"
eq "--pr other unnumbered worktree intact" "$(exists chore/other-pr):$(branch chore/other-pr)" "yes:yes"

# --- usage
OUT=$(bash "$DIR/sweep.sh" --bogus 2>&1); eq "usage rc" "$?" 64

echo "sweep: $((n - fail))/$n passed"
[ $fail = 0 ]
