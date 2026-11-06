#!/usr/bin/env bash
# Tests for merge-pr.sh route and review-check (offline). Run: bash skills/orchestrate-gh-issues/test-merge-pr.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/.claude"; git -C "$T/repo" init -q; cd "$T/repo" || exit 1
cat >.claude/issue-workflow.sh <<'EOF'
WF_RISK_GLOBS=(store/** composables/useTaskSync.ts)
WF_IGNORE_GLOBS=(package-lock.json tests/e2e/snapshots/**)
EOF

fail=0; n=0
first() { awk '{print $1; exit}'; }
route() { printf '%s\n' "$@" >"$T/files"; bash "$DIR/merge-pr.sh" route --files "$T/files" ${LINES_ARG:-} | first; }
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }

eq "docs only" "$(route README.md)" "lead:"
eq "risk file" "$(route README.md store/tasks.ts)" "reviewer:"
eq "exact risk path" "$(route composables/useTaskSync.ts)" "reviewer:"
eq "ignored only" "$(route package-lock.json tests/e2e/snapshots/a.png)" "lead:"
eq "empty list" "$(: >"$T/files"; bash "$DIR/merge-pr.sh" route --files "$T/files" | first)" "lead:"
eq "big diff" "$(LINES_ARG='--lines 500' route components/A.vue)" "reviewer:"
eq "risk file also matching an ignore glob" "$(printf 'WF_RISK_GLOBS=(DESIGN.md)\nWF_IGNORE_GLOBS=(*.md)\n' >.claude/issue-workflow.sh; route DESIGN.md)" "reviewer:"
cat >.claude/issue-workflow.sh <<'EOC'
WF_RISK_GLOBS=(store/** composables/useTaskSync.ts)
WF_IGNORE_GLOBS=(package-lock.json tests/e2e/snapshots/**)
EOC
eq "small diff" "$(LINES_ARG='--lines 120' route components/A.vue)" "lead:"
# no project config: defaults
mkdir -p "$T/bare"; git -C "$T/bare" init -q
eq "no config" "$(cd "$T/bare" && printf 'store/tasks.ts\n' >f && bash "$DIR/merge-pr.sh" route --files f | first)" "lead:"

rc() { bash "$DIR/merge-pr.sh" review-check "$@" >"$T/out" 2>&1; echo $?; }
printf 'Closes #1\n' >"$T/b1"
eq "missing section" "$(rc "$T/b1")" 1
n=$((n+1)); grep -q "missing" "$T/out" || { fail=$((fail + 1)); echo "FAIL [missing msg] $(cat "$T/out")"; }
printf '## Review\nroute: lead · effort: medium · by: sonnet\n- [medium] x (a.ts:1) -> open\nlows: 0\n' >"$T/b2"
eq "open finding" "$(rc "$T/b2")" 1
n=$((n+1)); grep -q "open finding" "$T/out" || { fail=$((fail + 1)); echo "FAIL [open msg] $(cat "$T/out")"; }
printf '## Review\nroute: lead · effort: medium · by: sonnet\n- [high] x (a.ts:1) -> fixed abc123\n- [medium] y (b.ts:2) -> dismissed: spec AC3\nlows: 1 (naming)\n\n## Other\n- [medium] z -> open\n' >"$T/b3"
eq "all resolved, later section ignored" "$(rc "$T/b3")" 0
eq "route stricter" "$(rc "$T/b3" --route reviewer)" 1
n=$((n+1)); grep -q "route" "$T/out" || { fail=$((fail + 1)); echo "FAIL [route msg] $(cat "$T/out")"; }
printf '## Review\nroute: reviewer · store/tasks.ts\n' >"$T/b4"
eq "reviewer route not yet reviewed" "$(rc "$T/b4" --route reviewer)" 1
printf '## Review\nroute: reviewer · effort: high · by: opus\nlows: 0\n' >"$T/b5"
eq "reviewer reviewed clean" "$(rc "$T/b5" --route reviewer)" 0

echo "merge-pr: $((n - fail))/$n passed"
[ $fail = 0 ]
