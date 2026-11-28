#!/usr/bin/env bash
# Tests for spec.sh. Run: bash skills/aw-coordinate/test-spec.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
export WF_PROTO_DIR="$T/proto-serve" # never the real prototype-server registry
mkdir -p "$T/bin" "$T/repo/.claude" "$T/ledger"; git -C "$T/repo" init -q
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "issue view"*) if [ -f "$TITLE_FILE" ]; then cat "$TITLE_FILE"; else echo "Fix the thing"; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"; export TITLE_FILE="$T/title"
cd "$T/repo" || exit 1
echo 'WF_PORTS=39101-39103' >.claude/issue-workflow.sh
git remote add origin https://github.com/acme/widgets.git

fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }

out=$(bash "$DIR/spec.sh" lead 7 --tier Standard --ledger "$T/ledger" 2>&1); rc=$?
check "lead exits 0" '[ $rc = 0 ]'
check "lead first line" 'printf "%s" "$out" | head -1 | grep -q "^Issue #7: Fix the thing. Stage: lead. Tier: Standard"'
for want in "/aw-specify 7" "/aw-build 7" "merge-pr.sh route" "## Review" "READY #7" "PARKED #7" "model: opus" "decide.sh log 7"; do
  check "lead contains $want" 'printf "%s" "$out" | grep -qF -- "$want"'
done
check "decide.sh calls carry WF_REPO (workers run them outside a checkout)" 'printf "%s" "$out" | grep -qF "\`WF_REPO=acme/widgets ~/.claude/agent-workflow/bin/decide.sh record 7 <file>\`" && printf "%s" "$out" | grep -qF "\$(WF_REPO=acme/widgets ~/.claude/agent-workflow/bin/decide.sh log --path 7)"'
check "no unfilled placeholder" '! printf "%s" "$out" | grep -Eq "\{\{[A-Z_]+\}\}"'
p1=$(printf '%s' "$out" | sed -n 's/^PORT=//p')
check "port assigned" '[ -n "$p1" ]'
out2=$(bash "$DIR/spec.sh" design 8 --ledger "$T/ledger" 2>&1)
p2=$(printf '%s' "$out2" | sed -n 's/^PORT=//p')
check "design spec names the preview port" 'printf "%s" "$out2" | grep -Eq "preview port 31(1[1-9])"'
check "second port differs" '[ -n "$p2" ] && [ "$p1" != "$p2" ]'
check "reservation recorded" 'grep -q "^$p1 #7 lead" "$T/ledger/ports"'
bash "$DIR/spec.sh" release-port "$p1" --ledger "$T/ledger"
check "release drops reservation" '! grep -q "^$p1 " "$T/ledger/ports"'

out3=$(bash "$DIR/spec.sh" review 9 --pr 42 --wt /x/wt --model opus --no-port --ledger "$T/ledger" 2>&1)
check "review writes only ## Review" 'printf "%s" "$out3" | grep -qF "write only the \`## Review\` section"'
check "review has by line" 'printf "%s" "$out3" | grep -qF "by: opus"'
check "review names PR and worktree" 'printf "%s" "$out3" | grep -qF "PR #42" && printf "%s" "$out3" | grep -qF "/x/wt"'
check "no-port gives no PORT line" '! printf "%s" "$out3" | grep -q "^PORT="'

# Model tiers come from the settings (defaults sonnet / opus / haiku; review and delta-review default to the strong tier).
out7=$(bash "$DIR/spec.sh" review 9 --pr 42 --wt /x --no-port --ledger "$T/ledger" 2>&1)
check "review defaults to strong" 'printf "%s" "$out7" | grep -qF "by: opus"'
out7d=$(bash "$DIR/spec.sh" delta-review 9 --pr 42 --wt /x --no-port --ledger "$T/ledger" 2>&1)
check "delta-review defaults to strong" 'printf "%s" "$out7d" | grep -qF "by: opus"'
out7f=$(bash "$DIR/spec.sh" delta-review 9 --pr 42 --wt /x --no-port --model claude-fable-5-2 --ledger "$T/ledger" 2>&1)
check "--model takes a full model ID (heavy tier)" 'printf "%s" "$out7f" | grep -qF "by: claude-fable-5-2"'
printf 'WF_MODEL_STRONG=fable\nWF_MODEL_FAST=sonnet\n' >"$WF_GLOBAL_SETTINGS"
out8=$(bash "$DIR/spec.sh" lead 15 --no-port --ledger "$T/ledger" 2>&1)
check "lead names the strong tier" 'printf "%s" "$out8" | grep -qF "model: fable" && ! printf "%s" "$out8" | grep -qF "model: opus"'
check "lead names the fast tier" 'printf "%s" "$out8" | grep -qF "model: sonnet" && ! printf "%s" "$out8" | grep -qF "haiku"'
out9=$(bash "$DIR/spec.sh" review 9 --pr 42 --wt /x --no-port --ledger "$T/ledger" 2>&1)
check "review respects the global strong tier" 'printf "%s" "$out9" | grep -qF "by: fable"'
out10=$(bash "$DIR/spec.sh" review 9 --pr 42 --wt /x --no-port --model sonnet --ledger "$T/ledger" 2>&1)
check "--model still wins" 'printf "%s" "$out10" | grep -qF "by: sonnet"'
rm -f "$WF_GLOBAL_SETTINGS"

echo "extra note for #10" >"$T/extra.md"
out4=$(bash "$DIR/spec.sh" fix 10 --pr 43 --wt /y --ledger "$T/ledger" --extra "$T/extra.md" 2>&1)
check "extra appended" 'printf "%s" "$out4" | grep -qF "extra note for #10"'

bash "$DIR/spec.sh" lead 10 --ledger "$T/ledger" --extra "$T/missing.md" >"$T/o" 2>"$T/err"; rc=$?
check "missing --extra file: exit 64, names it, no spec" '[ $rc = 64 ] && grep -q "missing.md" "$T/err" && [ ! -s "$T/o" ]'

bash "$DIR/spec.sh" lead 10 --ledger "$T/ledger" --extra >/dev/null 2>&1; rc=$?
check "a trailing --extra is a usage error (64), not an unbound variable" '[ $rc = 64 ]'

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

# --runner subagent: the same stage rules as a brief for a Claude Code subagent (subagent-mode.md); no Orca mechanics
for st in lead design review delta-review fix; do
  o=$(bash "$DIR/spec.sh" "$st" 21 --runner subagent --branch feat/21-x --pr 42 --no-port --ledger "$T/ledger" 2>&1); rc=$?
  check "subagent $st: exit 0" '[ $rc = 0 ]'
  check "subagent $st: no unfilled placeholder" '! printf "%s" "$o" | grep -Eq "\{\{[A-Z_]+\}\}"'
  check "subagent $st: names neither the orca CLI, worker_done nor ask" '! printf "%s" "$o" | grep -Eq "(^|[^A-Za-z])orca([^A-Za-z]|$)|worker_done|\`ask\`|--outcome|Stop hook|--report-path"'
  check "subagent $st: starts with wt.sh init on its branch" 'printf "%s" "$o" | grep -qF "Your first command: \`~/.claude/skills/aw-coordinate/wt.sh init feat/21-x\`"'
  check "subagent $st: pushes before its final message" 'printf "%s" "$o" | grep -qF "commit and push the branch"'
  check "subagent $st: parks with a final message" 'printf "%s" "$o" | grep -qF "end with a final message starting \`PARKED #21 D<k>\`"'
  # the stage rules are the same text for both runners: every line that holds no runner phrase is identical
  oo=$(bash "$DIR/spec.sh" "$st" 21 --branch feat/21-x --pr 42 --no-port --ledger "$T/ledger" 2>&1)
  same=$(printf '%s\n' "$oo" | grep -Ev "worker_done|\`ask\`|git branch -m" | grep -Fxvc -f <(printf '%s\n' "$o"))
  check "subagent $st: shares every rule line without a runner phrase with the Orca spec (differing: $same)" '[ "$same" = 0 ]'
done
os=$(bash "$DIR/spec.sh" lead 21 --runner subagent --branch feat/21-x --no-port --ledger "$T/ledger" 2>&1)
for want in "final message starting \`READY #21 PR <url> route=<lead|reviewer>\`" "\`FAILED #21: <reason>\`" "stop with final message \`ROUTED #21 needs-design\`" "on the branch \`feat/21-x\` that \`wt.sh init\` set" "/aw-specify 21" "merge-pr.sh route" "route: lead · by: <your model>"; do
  check "subagent lead contains $want" 'printf "%s" "$os" | grep -qF -- "$want"'
done
check "subagent review reports REVIEWED" 'bash "$DIR/spec.sh" review 21 --runner subagent --branch feat/21-x --pr 42 --no-port --ledger "$T/ledger" | grep -qF "final message starting \`REVIEWED #21 PR #42 open=<count>\`"'
check "subagent fix reports FIXED" 'bash "$DIR/spec.sh" fix 21 --runner subagent --branch feat/21-x --pr 42 --no-port --ledger "$T/ledger" | grep -qF "final message starting \`FIXED #21 PR #42\`"'
oi=$(bash "$DIR/spec.sh" lead 21 --runner subagent --branch feat/21-x --interactive --no-port --ledger "$T/ledger" 2>&1)
check "subagent interactive: every choice parks" 'printf "%s" "$oi" | grep -qF "becomes a decision request, one-way or not" && ! printf "%s" "$oi" | grep -qF "preamble"'
ob=$(bash "$DIR/spec.sh" lead 21 --runner subagent --branch feat/21-x --batch 22,23 --ledger "$T/ledger3" 2>&1)
check "subagent batch and port lines are kept" 'printf "%s" "$ob" | grep -qF "also #22, #23" && printf "%s" "$ob" | grep -q "^PORT=39101$"'
bash "$DIR/spec.sh" lead 21 --runner subagent --no-port --ledger "$T/ledger" >"$T/o" 2>"$T/err"; rc=$?
check "subagent without --branch: exit 64, names the flag, no brief" '[ $rc = 64 ] && grep -q -- "--branch" "$T/err" && [ ! -s "$T/o" ]'
bash "$DIR/spec.sh" lead 21 --runner cloud --branch b --no-port --ledger "$T/ledger" >/dev/null 2>&1; rc=$?
check "unknown runner: exit 64" '[ $rc = 64 ]'
# the default runner is Orca, and its spec keeps every Orca phrase (the template only moved them into phrase lines)
od=$(bash "$DIR/spec.sh" lead 21 --no-port --ledger "$T/ledger" 2>&1)
check "--runner orca is the default" '[ "$od" = "$(bash "$DIR/spec.sh" lead 21 --runner orca --no-port --ledger "$T/ledger" 2>&1)" ]'
for want in "then park: worker_done --outcome succeeded, body starting \`PARKED #21 D<k>\`, worktree left as is. Never merge. Never end your turn while" "A Stop hook blocks ending your turn once without \`worker_done\`" "continue; no \`ask\` to the coordinator. A route to \`needs-design\`: stop with worker_done body \`ROUTED #21 needs-design\`." "in this worktree: first \`git branch -m the profile" "A rebase after the first push needs a force-push: \`ask\` the coordinator, workers cannot. Pass longer findings or context as a file path (--report-path), not pasted into messages. The guard hook" "5. worker_done --outcome succeeded with a body starting \`READY #21 PR <url> route=<lead|reviewer>\`" "name them in \`worker_done\`; the coordinator files them" "Constraints: follow CLAUDE.md"; do
  check "orca lead keeps: $(printf '%s' "$want" | cut -c1-50)" 'printf "%s" "$od" | grep -qF -- "$want"'
done
check "the phrase lines themselves never reach a spec" '! printf "%s\n%s" "$od" "$os" | grep -Eq "^(START|PARK|TURN|REBASE|FINDINGS|BRANCH_STEP|NO_ASK|REPORT|REPORT_IN|LEAD_DONE)=|phrases:"'

# an issue title is data: a placeholder written in it stays as written in the brief
echo 'Fix {{BRANCH}} and {{N}} in {{DECIDE}}' >"$TITLE_FILE"
out=$(bash "$DIR/spec.sh" lead 9 --ledger "$T/ledger" --no-port 2>&1)
check "a title with placeholders is not expanded" 'printf "%s" "$out" | head -1 | grep -qF "Issue #9: Fix {{BRANCH}} and {{N}} in {{DECIDE}}."'
rm -f "$TITLE_FILE"
echo "spec: $((n - fail))/$n passed"
[ $fail = 0 ]
