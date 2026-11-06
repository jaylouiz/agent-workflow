#!/usr/bin/env bash
# Tests for .claude/issue-workflow.sh (wf_verify, wf_after_merge, WF_RISK_GLOBS) in throwaway repos; install.sh is stubbed.
# Run: bash .claude/test-issue-workflow.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$DIR/../skills/orchestrate-gh-issues/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
q() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

# Load the config the way the scripts do (globbing off, defaults first), from a repo that carries a copy of it.
load() { # load <repo>
  mkdir -p "$1/.claude"; cp "$DIR/issue-workflow.sh" "$1/.claude/issue-workflow.sh"
  # shellcheck disable=SC1090
  (cd "$1" && . "$LIB" && wf_load && declare -p WF_RISK_GLOBS >/dev/null)
}

# Risk globs route the live hooks to a reviewer and a plain skill doc to the lead.
R="$T/risk"; mkdir -p "$R"; git -C "$R" init -q; load "$R" || exit 1
for f in skills/orchestrate-gh-issues/guard.sh skills/orchestrate-gh-issues/worker-done-stop.sh skills/orca-update-review/check.sh global/CLAUDE.md install.sh; do
  printf '%s\n' "$f" >"$T/files"
  eq "risk $f" "$(cd "$R" && bash "$DIR/../skills/orchestrate-gh-issues/merge-pr.sh" route --files "$T/files" | awk '{print $1}')" "reviewer:"
done
printf 'skills/build-gh-issue/SKILL.md\nREADME.md\n' >"$T/files"
eq "no risk" "$(cd "$R" && bash "$DIR/../skills/orchestrate-gh-issues/merge-pr.sh" route --files "$T/files" | awk '{print $1}')" "lead:"

# wf_verify: passes when all suites pass, names the failing one and stops there.
V="$T/verify"; mkdir -p "$V/skills/a" "$V/skills/b" "$V/skills/c"; git -C "$V" init -q; load "$V"
printf 'echo ok-a\n' >"$V/skills/a/test-a.sh"
printf 'echo ran-c >>"$0.ran"\n' >"$V/skills/c/test-c.sh"
run_verify() { (cd "$V" && . .claude/issue-workflow.sh && wf_verify 2>&1); }
out=$(run_verify); eq "verify passes quietly" "$?:$out" "0:"
rm -f "$V/skills/c/test-c.sh.ran"
printf 'echo boom; exit 3\n' >"$V/skills/b/test-b.sh"
out=$(run_verify); rc=$?
eq "verify fails" "$rc" 1
eq "verify names the suite" "$(printf '%s' "$out" | head -1)" "verify failed: skills/b/test-b.sh"
eq "verify shows its output" "$(printf '%s' "$out" | grep -c boom)" 1
eq "verify stops at the first failure" "$([ -f "$V/skills/c/test-c.sh.ran" ] && echo ran || echo not-run)" "not-run"

# wf_after_merge: bare origin, main checkout, a second clone that pushes.
O="$T/origin.git"; M="$T/main"; P="$T/pusher"
git init -q --bare "$O"; git clone -q "$O" "$M" 2>/dev/null; git clone -q "$O" "$P" 2>/dev/null
(cd "$M" && q checkout -q -b main && mkdir -p skills/one && echo 1 >skills/one/f && echo i >install.sh && q add -A && q commit -qm init && q push -q origin main 2>/dev/null)
(cd "$P" && q fetch -q && q checkout -q main 2>/dev/null)
load "$M" || exit 1; (cd "$M" && git add -A && q commit -qm cfg && q push -q origin main 2>/dev/null)
(cd "$P" && q pull -q origin main 2>/dev/null)
after() { # after: run wf_after_merge in the main checkout with install.sh stubbed; prints output and the install count
  (cd "$M" && . .claude/issue-workflow.sh && wf_install_skills() { echo INSTALL >&2; } && wf_after_merge) 2>&1
}
push() { (cd "$P" && "$@" && q add -A && q commit -qm x && q push -q origin main 2>/dev/null); }

push sh -c 'echo 2 >skills/one/f'
out=$(after); eq "ff, content change: no install" "$?:$(printf '%s' "$out" | grep -c INSTALL)" "0:0"
eq "main at origin/main" "$(git -C "$M" rev-parse HEAD)" "$(git -C "$M" rev-parse origin/main)"
out=$(after); eq "nothing new: ok, no install" "$?:$(printf '%s' "$out" | grep -c INSTALL)" "0:0"
push sh -c 'mkdir skills/two && echo 1 >skills/two/f'
out=$(after); eq "new skill dir: install" "$?:$(printf '%s' "$out" | grep -c INSTALL)" "0:1"
push git mv skills/two skills/three
out=$(after); eq "renamed skill dir: install" "$?:$(printf '%s' "$out" | grep -c INSTALL)" "0:1"
push git rm -rq skills/three
out=$(after); eq "removed skill dir: install" "$?:$(printf '%s' "$out" | grep -c INSTALL)" "0:1"
push sh -c 'echo changed >install.sh'
out=$(after); eq "install.sh changed: install" "$?:$(printf '%s' "$out" | grep -c INSTALL)" "0:1"
push sh -c 'echo 3 >skills/one/g'
out=$(after); eq "new file in a skill: no install" "$?:$(printf '%s' "$out" | grep -c INSTALL)" "0:0"
# failing install.sh and failing fetch are reported, not swallowed
push sh -c 'mkdir skills/four && echo 1 >skills/four/f'
out=$( (cd "$M" && . .claude/issue-workflow.sh && wf_install_skills() { return 1; } && wf_after_merge) 2>&1); eq "install fails: reported" "$?:$(printf '%s' "$out" | grep -c 'install.sh failed')" "1:1"
q -C "$M" remote set-url origin "$T/nowhere.git"
out=$(after); eq "fetch fails: reported" "$?:$(printf '%s' "$out" | grep -c 'fetch failed')" "1:1"
q -C "$M" remote set-url origin "$O"
# not on main: refuse, change nothing
push sh -c 'echo 4 >skills/one/f'
q -C "$M" checkout -q -b other
before=$(git -C "$M" rev-parse HEAD); out=$(after); rc=$?
eq "not on main: fails, untouched" "$rc:$(git -C "$M" rev-parse HEAD)" "1:$before"
q -C "$M" checkout -q main
# diverged local commit: ff-only fails with a message
(cd "$M" && echo l >local && q add -A && q commit -qm local)
out=$(after); eq "diverged: fails" "$?:$(printf '%s' "$out" | grep -c 'cannot fast-forward')" "1:1"

echo "$n checks, $fail failed"; [ "$fail" = 0 ]
