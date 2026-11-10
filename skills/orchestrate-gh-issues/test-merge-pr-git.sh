#!/usr/bin/env bash
# Integration tests for merge-pr.sh prep/after and config loading, against a local bare origin (gh stubbed).
# Run: bash skills/orchestrate-gh-issues/test-merge-pr-git.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
first() { awk '{print $1; exit}'; }
q() { git -c user.email=t@t -c user.name=t "$@"; }

# C1: unquoted ** globs in the config must stay patterns, even where matching files exist.
mkdir -p "$T/g/.claude" "$T/g/store" "$T/g/server/api"; git -C "$T/g" init -q
touch "$T/g/store/tasks.ts" "$T/g/server/api/a.ts"
echo 'WF_RISK_GLOBS=(store/** server/**)' >"$T/g/.claude/issue-workflow.sh"
eq "unquoted glob, new file" "$(cd "$T/g" && printf 'store/new.ts\n' >f && bash "$DIR/merge-pr.sh" route --files f | first)" "reviewer:"
eq "unquoted glob, nested path" "$(cd "$T/g" && printf 'server/api/x/y.ts\n' >f && bash "$DIR/merge-pr.sh" route --files f | first)" "reviewer:"

# I5/M3: every closing reference, line-anchored.
printf 'This fixes #488 regression.\nCloses #10\nCloses #11\nFixes acme/widgets#12\n' >"$T/bi"
eq "issues-of all closing refs" "$(bash "$DIR/merge-pr.sh" issues-of "$T/bi" | tr '\n' ' ')" "10 11 12 "

# Repo: bare origin, main checkout, PR worktree feat/7-x; main moves on after the branch.
R="$T/int"; mkdir -p "$R"; git init -q --bare "$R/origin.git"
git clone -q "$R/origin.git" "$R/main" 2>/dev/null
cd "$R/main" || exit 1
q checkout -q -b main
mkdir .claude
cat >.claude/issue-workflow.sh <<'EOF'
wf_verify() { [ ! -f FAILVERIFY ] || { echo verify-failed; return 1; }; echo verify-ok; }
wf_after_merge() { echo "after-merge in $(basename "$PWD") on $(git branch --show-current)"; }
EOF
echo a >a; q add -A; q commit -qm init; q push -q origin main 2>/dev/null
q worktree add -q -b feat/7-x "$R/wt" 2>/dev/null
(cd "$R/wt" && echo b >b && q add b && q commit -qm b && q push -q -u origin feat/7-x 2>/dev/null)
echo c >c; q add c; q commit -qm c; q push -q origin main 2>/dev/null

mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "pr view 7 --json state,headRefName,baseRefName,labels,body")
    printf '{"state":"OPEN","headRefName":"feat/7-x","baseRefName":"main","labels":[],"body":"Closes #70\\n## Review\\nroute: lead · effort: low · by: sonnet\\nlows: 0\\n"}' ;;
  "pr checks 7 --json name,bucket") [ -f "$T/checks" ] || { echo "no checks reported on the 'x' branch" >&2; exit 1; }; cat "$T/checks" ;;
  "pr view 7 --json files"*) printf 'b\t1\t0\n' ;;
  "pr view 7 --json state,headRefOid") printf '{"state":"MERGED","headRefOid":"abc"}' ;;
  "pr view 7 --json state,headRefName,headRefOid,isCrossRepository") printf '{"state":"MERGED","headRefName":"feat/7-x","headRefOid":"%s"}' "$(cat "$OIDFILE")" ;;
  "pr list --state all --head feat/7-x"*) [ ! -f "$T/ghfail" ] || exit 1; printf '[{"number":7,"state":"MERGED","headRefOid":"%s"}]' "$(cat "$OIDFILE")" ;;
  "pr list --state open --base"*) : ;;
  "pr view 7 --json body"*) printf 'Closes #70\n' ;;
  "issue view 70 --json labels"*) : ;;
  *) echo "gh stub: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export OIDFILE="$T/oid" T
git -C "$R/wt" rev-parse HEAD >"$OIDFILE"
export PATH="$T/bin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# I3: verify fails after the local merge; a rerun must still verify and push.
touch "$R/wt/FAILVERIFY"
bash "$DIR/merge-pr.sh" prep 7 >/dev/null 2>&1; eq "prep stops on failed verify" "$?" 64
rm "$R/wt/FAILVERIFY"
out=$(bash "$DIR/merge-pr.sh" prep 7 2>&1); rc=$?
eq "rerun verifies and pushes" "$rc:$(printf '%s' "$out" | grep -c verify-ok)" "0:1"
git -C "$R/main" fetch -q origin
eq "remote head contains main" "$(git -C "$R/main" merge-base --is-ancestor origin/main origin/feat/7-x && echo yes)" "yes"

# CI checks: prep refuses on failed, waits on pending, honours WF_REQUIRED_CHECKS.
ck() { printf '%s' "$1" >"$T/checks"; out=$(bash "$DIR/merge-pr.sh" prep 7 2>&1); rc=$?; }
ck '[{"name":"CI / quality","bucket":"fail"},{"name":"lint","bucket":"pass"}]'
eq "ci failed refuses" "$rc:$(printf '%s' "$out" | grep -c 'CI: failed check(s): CI / quality')" "1:1"
eq "ci failed: no ready line" "$(printf '%s' "$out" | grep -c '^ready:')" 0
ck '[{"name":"CI / quality","bucket":"cancel"}]'
eq "ci cancelled refuses" "$rc" 1
rm "$T/checks"
echo 'WF_REQUIRED_CHECKS="CI / quality"' >>"$R/main/.claude/issue-workflow.sh"
ck '[{"name":"other","bucket":"pass"}]'
eq "required check not reported waits" "$rc:$(printf '%s' "$out" | grep -c 'WAIT #7: CI pending: CI / quality(not reported)')" "2:1"
ck '[{"name":"CI / quality","bucket":"pending"}]'
eq "pending waits, no ready line" "$rc:$(printf '%s' "$out" | grep -c '^ready:')" "2:0"
ck '[{"name":"CI / quality","bucket":"pass"},{"name":"flaky","bucket":"fail"}]'
eq "required subset ignores other failure" "$rc:$(printf '%s' "$out" | grep -c '^ready:')" "0:1"
ck 'not json'
eq "unreadable output fails closed" "$rc" 64
sed -i.bak '$d' "$R/main/.claude/issue-workflow.sh"; rm -f "$R/main/.claude/issue-workflow.sh.bak"
ck '[{"name":"CI / quality","bucket":"pass"},{"name":"s","bucket":"skipping"}]'
eq "all pass/skipping is ready" "$rc:$(printf '%s' "$out" | grep -c '^ready:')" "0:1"
rm "$T/checks"
out=$(bash "$DIR/merge-pr.sh" prep 7 2>&1); eq "no checks reported is ready" "$?:$(printf '%s' "$out" | grep -c '^ready:')" "0:1"

# M1: a conflict aborts the merge and leaves the worktree clean.
echo d >d; q add d; q commit -qm d; q push -q origin main 2>/dev/null
(cd "$R/wt" && echo conflict >d && q add d && q commit -qm d2 && q push -q 2>/dev/null)
bash "$DIR/merge-pr.sh" prep 7 >/dev/null 2>&1; rc=$?
eq "conflict aborts the merge" "$rc:$(git -C "$R/wt" rev-parse -q --verify MERGE_HEAD >/dev/null && echo mid || echo clean)" "64:clean"

# I4: after, invoked from the PR worktree, acts on the main checkout.
git -C "$R/wt" rev-parse HEAD >"$OIDFILE" # the PR head GitHub merged
out=$(cd "$R/wt" && bash "$DIR/merge-pr.sh" after 7 "done" 2>&1)
eq "after runs in the main checkout" "$(printf '%s' "$out" | grep -o 'after-merge in main on main')" "after-merge in main on main"

# #41: after sweeps finished work. From inside the PR worktree it is the current directory: kept; the main checkout's
# own run removes it and its branches. A sweep that cannot run (gh down) never fails after.
eq "after kept the worktree it ran in" "$(printf '%s' "$out" | grep -c "kept .*/wt (feat/7-x): current directory")" 1
eq "after: keeping the cwd worktree is not a sweep failure" "$(printf '%s' "$out" | grep -c WARN)" 0
eq "after: remote head branch deleted although the worktree stays" "$(printf '%s' "$out" | grep -c '^deleted remote branch origin/feat/7-x')" 1
eq "after keeps the cwd worktree on disk" "$([ -d "$R/wt" ] && echo yes)" yes
touch "$T/ghfail"
out=$(cd "$R/main" && bash "$DIR/merge-pr.sh" after 7 "done" 2>&1); rc=$?
eq "failing sweep does not fail after" "$rc" 0
eq "failing sweep is reported" "$(printf '%s' "$out" | grep -c 'cannot look up the PR')" 1
eq "failing sweep kept the worktree" "$([ -d "$R/wt" ] && echo yes)" yes
rm "$T/ghfail"
out=$(cd "$R/main" && bash "$DIR/merge-pr.sh" after 7 "done" 2>&1); rc=$?
eq "after from the main checkout removes the PR worktree" "$rc:$([ -d "$R/wt" ] && echo yes || echo no)" "0:no"
eq "after removed the local branch" "$(git -C "$R/main" show-ref --verify -q refs/heads/feat/7-x && echo yes || echo no)" no
eq "remote head branch is gone" "$(git -C "$R/main" ls-remote --exit-code --heads origin feat/7-x >/dev/null 2>&1 && echo yes || echo no)" no
eq "after prints one line per removal" "$(printf '%s' "$out" | grep -c '^removed worktree\|^removed branch')" 2
# the sweep subcommand: dry run changes nothing
eq "sweep rejects other flags" "$(bash "$DIR/merge-pr.sh" sweep --nope >/dev/null 2>&1; echo $?)" 64
eq "sweep --dry-run via merge-pr.sh" "$(cd "$R/main" && bash "$DIR/merge-pr.sh" sweep --dry-run 2>&1 | grep -c 'dry run')" 1

echo "merge-pr-git: $((n - fail))/$n passed"
[ $fail = 0 ]
