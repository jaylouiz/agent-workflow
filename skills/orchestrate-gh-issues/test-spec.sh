#!/usr/bin/env bash
# Tests for spec.sh. Run: bash skills/orchestrate-gh-issues/test-spec.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/.claude" "$T/ledger"; git -C "$T/repo" init -q
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "issue view"*) echo "Fix the thing" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
cd "$T/repo" || exit 1
echo 'WF_PORTS=39101-39103' >.claude/issue-workflow.sh
git remote add origin https://github.com/acme/widgets.git

fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }

out=$(bash "$DIR/spec.sh" lead 7 --tier Standard --ledger "$T/ledger" 2>&1); rc=$?
check "lead exits 0" '[ $rc = 0 ]'
check "lead first line" 'printf "%s" "$out" | head -1 | grep -q "^Issue #7: Fix the thing. Stage: lead. Tier: Standard"'
for want in "/specify-gh-issue 7" "/build-gh-issue 7" "merge-pr.sh route" "## Review" "READY #7" "PARKED #7" "model: opus" "decide.sh log 7"; do
  check "lead contains $want" 'printf "%s" "$out" | grep -qF -- "$want"'
done
check "decide.sh calls carry WF_REPO (workers run them outside a checkout)" 'printf "%s" "$out" | grep -qF "\`WF_REPO=acme/widgets ~/.claude/skills/orchestrate-gh-issues/decide.sh record 7 <file>\`" && printf "%s" "$out" | grep -qF "\$(WF_REPO=acme/widgets ~/.claude/skills/orchestrate-gh-issues/decide.sh log --path 7)"'
check "no unfilled placeholder" '! printf "%s" "$out" | grep -Eq "\{\{[A-Z]+\}\}"'
p1=$(printf '%s' "$out" | sed -n 's/^PORT=//p')
check "port assigned" '[ -n "$p1" ]'
out2=$(bash "$DIR/spec.sh" design 8 --ledger "$T/ledger" 2>&1)
p2=$(printf '%s' "$out2" | sed -n 's/^PORT=//p')
check "second port differs" '[ -n "$p2" ] && [ "$p1" != "$p2" ]'
check "reservation recorded" 'grep -q "^$p1 #7 lead" "$T/ledger/ports"'
bash "$DIR/spec.sh" release-port "$p1" --ledger "$T/ledger"
check "release drops reservation" '! grep -q "^$p1 " "$T/ledger/ports"'

out3=$(bash "$DIR/spec.sh" review 9 --pr 42 --wt /x/wt --model opus --no-port --ledger "$T/ledger" 2>&1)
check "review writes only ## Review" 'printf "%s" "$out3" | grep -qF "write only the \`## Review\` section"'
check "review has by line" 'printf "%s" "$out3" | grep -qF "by: opus"'
check "review names PR and worktree" 'printf "%s" "$out3" | grep -qF "PR #42" && printf "%s" "$out3" | grep -qF "/x/wt"'
check "no-port gives no PORT line" '! printf "%s" "$out3" | grep -q "^PORT="'

echo "extra note for #10" >"$T/extra.md"
out4=$(bash "$DIR/spec.sh" fix 10 --pr 43 --wt /y --ledger "$T/ledger" --extra "$T/extra.md" 2>&1)
check "extra appended" 'printf "%s" "$out4" | grep -qF "extra note for #10"'

bash "$DIR/spec.sh" lead 10 --ledger "$T/ledger" --extra "$T/missing.md" >"$T/o" 2>"$T/err"; rc=$?
check "missing --extra file: exit 64, names it, no spec" '[ $rc = 64 ] && grep -q "missing.md" "$T/err" && [ ! -s "$T/o" ]'

out5=$(bash "$DIR/spec.sh" lead 13 --interactive --ledger "$T/ledger" 2>&1)
check "interactive routes questions through ask" 'printf "%s" "$out5" | grep -qF "Interactive issue"'
check "interactive drops no-questions line" '! printf "%s" "$out5" | grep -qF "No questions to the user."'
out6=$(bash "$DIR/spec.sh" design 14 --no-port --ledger "$T/ledger" 2>&1)
check "design default branch is proto" 'printf "%s" "$out6" | grep -qF "proto/14-"'

echo 'WF_PORTS=39101-39101' >.claude/issue-workflow.sh
bash "$DIR/spec.sh" lead 11 --ledger "$T/ledger2" >/dev/null 2>&1
bash "$DIR/spec.sh" lead 12 --ledger "$T/ledger2" >/dev/null 2>"$T/err"; rc=$?
check "no free port exits 3" '[ $rc = 3 ] && grep -q "no free port" "$T/err"'

bash "$DIR/spec.sh" bogus 1 --ledger "$T/ledger" >/dev/null 2>&1; rc=$?
check "unknown stage exits 64" '[ $rc = 64 ]'

out7=$(cd "$T" && WF_REPO=zed/other bash "$DIR/spec.sh" lead 15 --no-port --ledger "$T/ledger" 2>&1)
check "WF_REPO env wins in the spec" 'printf "%s" "$out7" | grep -qF "WF_REPO=zed/other ~/.claude"'

echo "spec: $((n - fail))/$n passed"
[ $fail = 0 ]
