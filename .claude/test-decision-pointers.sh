#!/usr/bin/env bash
# Text contract of the decision rules (issue 34): they live in reference/decisions.md, every stage skill starts with
# the Resume step and none points into the coordinator skill for them, and the coordinator's recovery reads the issue
# status before the phase label. Run: bash .claude/test-decision-pointers.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
fail=0; n=0
ok() { n=$((n + 1)); if ! eval "$2"; then fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; } # line <file> <text>: first line holding it, empty when none

ref=reference/decisions.md
ok "reference/decisions.md exists" '[ -s "$ref" ]'
for h in "## One-way or two-way" "## Park, don't wait" "## Resume" "## Without a coordinator"; do
  ok "decisions.md has '$h'" 'grep -qxF -- "$h" "$ref"'
done
ok "decisions.md holds the default one-way list" 'grep -q "reversing a recorded design decision" "$ref"'
ok "decisions.md names the three resume results" 'grep -q "^| \`none\` | 0 " "$ref" && grep -q "^| \`waiting .* | 2 " "$ref" && grep -q "^| \`resumed D<k> with: " "$ref"'
ok "decisions.md names the inbox for a run without a coordinator" 'grep -q "decide.sh status" "$ref" && grep -q "decide.sh digest" "$ref"'

for s in aw-ui-design aw-specify aw-build; do
  f=skills/$s/SKILL.md
  r=$(line "$f" 'bin/decide.sh resume $issue'); v=$(line "$f" 'gh issue view $issue'); p=$(line "$f" 'issue-status.sh phase $issue')
  ok "$s has the Resume step" '[ -n "$r" ]'
  ok "$s: Resume comes right after the issue is loaded" '[ -n "$r" ] && [ -n "$v" ] && [ "$r" -eq $((v + 1)) ]'
  ok "$s: Resume comes before the phase write" '[ -n "$r" ] && [ -n "$p" ] && [ "$r" -lt "$p" ]'
  ok "$s: the Resume step names all three results" 'sed -n "${r:-1}p" "$f" | grep -q "\`none\`.*\`waiting\` (exit 2).*\`resumed\`"'
  ok "$s points to reference/decisions.md" 'grep -qF "agent-workflow/reference/decisions.md" "$f"'
  ok "$s does not point into the coordinator skill" '! grep -nE "aw-orchestrate\`? section|orchestrate section" "$f"'
done

ok "nothing names 'orchestrate section 5' as the home of the rules any more" \
  '! grep -rnE "aw-orchestrate\`? section 5|orchestrate section 5" bin skills global reference README.md docs .claude/issue-workflow.md --include="*.md" --include="*.sh"'

o=skills/aw-orchestrate/SKILL.md
ok "the coordinator skill points to reference/decisions.md" 'grep -qF "agent-workflow/reference/decisions.md" "$o"'
rec=$(grep -F "**Lost coordinator session**" "$o")
ok "recovery reads the issue status first, the phase label second" \
  'case "$rec" in *"issue-status.sh get"*"phase:"*) case "${rec%%issue-status.sh get*}" in *"phase:"*) false ;; *) true ;; esac ;; *) false ;; esac'

echo "decision-pointers: $((n - fail))/$n passed"
[ $fail = 0 ]
