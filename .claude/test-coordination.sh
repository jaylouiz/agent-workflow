#!/usr/bin/env bash
# The coordination policy has one home: reference/coordination.md. Both modes of /aw-coordinate (SKILL.md for Orca
# workers, subagent-mode.md for Claude Code subagents) point to it and hold only their own mechanics.
# Run: bash .claude/test-coordination.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ref=reference/coordination.md; orca=skills/aw-coordinate/SKILL.md; sub=skills/aw-coordinate/subagent-mode.md
fail=0; n=0
ok() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }

for h in "## Role and outcome" "## Input" "## Screening (2+ issues)" "## Stages" "## Models per role" "## Decisions and the user" "## Progress and reporting"; do
  ok "coordination.md has '$h'" 'grep -qxF -- "$h" "$ref"'
done
for f in "$orca" "$sub"; do
  ok "$f points to the coordination rules" 'grep -qF "agent-workflow/reference/coordination.md" "$f"'
done

# the policy is written once: batch limits, round limits, the review route, the merge sequence, the model table, the digest
while IFS= read -r p; do
  [ -n "$p" ] || continue
  ok "coordination.md holds: $p" 'grep -qF -- "$p" "$ref"'
  for f in "$orca" "$sub"; do ok "$f does not repeat: $p" '! grep -qF -- "$p" "$f"'; done
done <<'EOP'
Limits: 2-4 issues
ships alone, so it can be reverted alone
Max 3 rounds
max 2 rounds
up to 2 fix rounds
merge-pr.sh prep <pr>
`gh pr merge` as its own call
**Do not merge**
You never read diffs to review them yourself
| Role | Tier
takes its biggest issue's row
decide.sh digest --due
**never edit code**
EOP

# the mechanics of one runner stay in its mode file
ok "coordination.md names no Orca mechanics" '! grep -nE "worker-start|worker_done|next\.sh|msgs\.sh|run-create|orca orchestration|--worktree path:" "$ref"'
ok "coordination.md names no subagent mechanics" '! grep -nE "run_in_background|isolation|wt\.sh|plan\.sh" "$ref"'
ok "subagent-mode.md names neither the orca CLI nor worker_done" '! grep -nE "(^|[^A-Za-z])orca([^A-Za-z]|$)|worker_done|next\.sh|msgs\.sh" "$sub"'
ok "the Orca mode starts no subagent workers" '! grep -nE "isolation: |wt\.sh|plan\.sh|--runner" "$orca"'

# the subagent mode names every step plan.sh prints, and the scripts it tells the coordinator to run exist
for s in design lead review fix hold delta-review merge screen skip; do
  ok "plan.sh documents the step $s" 'grep -qE "^#   $s " skills/aw-coordinate/plan.sh'
  ok "subagent-mode.md names the step $s" 'grep -qF "\`$s\`" "$sub"'
done
# the round state has one owner: bin/rounds.sh writes and reads the markers; the doc names its commands, never a marker to
# word by hand; plan.sh and merge-pr.sh prep read the state from it
for c in 'rounds.sh` `start <n> <pr>`' 'rounds.sh fixed <n> <pr>' 'rounds.sh delta <n> <pr> open=' 'rounds.sh delta <n> <pr> skipped'; do
  ok "subagent-mode.md names the round command '$c'" 'grep -qF -- "$c" "$sub"'
done
ok "subagent-mode.md words no round marker itself" '! grep -nE "round: (fix|delta) " "$sub"'
ok "subagent-mode.md opens the round before the fix worker's Agent call" 'grep -qE "Before a .fix. worker, and before its .Agent. call" "$sub"'
ok "subagent-mode.md says what no marker means (Orca rounds, a lost log)" 'grep -qF "ran under the Orca coordinator" "$sub"'
for m in 'round: fix <k> started <sha> pr=<pr>' 'round: fix <k> settled <sha> pr=<pr>' 'round: delta <k> settled open=<m> pr=<pr>' 'round: delta <k> skipped pr=<pr>'; do
  ok "rounds.sh defines the round marker '$m'" 'grep -qF -- "$m" bin/rounds.sh'
done
ok "the round delta is settled only after a delta-review stage" 'grep -qF "never after a first \`review\`" "$sub"'
ok "plan.sh and merge-pr.sh prep read the round state from rounds.sh, with no marker regex of their own" 'grep -qF "rounds.sh\" state \"\$1\"" skills/aw-coordinate/plan.sh && grep -qF "rounds.sh\" state \"\$pr\"" bin/merge-pr.sh && ! grep -nE "round: (fix|delta) \[" skills/aw-coordinate/plan.sh bin/merge-pr.sh'
for s in plan.sh wt.sh spec.sh preflight.sh; do ok "$s is executable" '[ -x "skills/aw-coordinate/$s" ]'; done
for r in READY REVIEWED FIXED PARKED ROUTED FAILED; do
  ok "the result line $r is in the template and settled in subagent-mode.md" 'grep -qF "$r #" skills/aw-coordinate/task-template.md && grep -qF "\`$r #" "$sub"'
done

# sections other files point to by number still exist in the Orca mode
for h in "## 0. Preflight" "## 1c. Waves (many issues)" "## 4. Task specs" "## 5. Decisions and the user" "## 6. Safety and recovery" "## 7. Progress and reporting"; do
  ok "SKILL.md keeps '$h'" 'grep -qxF -- "$h" "$orca"'
done

echo "coordination: $((n - fail))/$n passed"
[ $fail = 0 ]
