# Retro running log

Never loaded into a session. Format and rules: `skills/workflow-retro/SKILL.md`.

## Context size (words)
| date | run | global/CLAUDE.md | issue-workflow.md | skills/*/SKILL.md | total | note |
|---|---|---|---|---|---|---|
| 2026-11-06 | run_869230114ca7 | 524 / 29 | 424 | 7629 | 8577 | baseline, profile added in #30 |
| 2026-11-06 | run_869230114ca7 (retro) | 524 / 29 | 434 | 7647 | 8605 | no context file changed after #32's merge; +28 is a measuring difference (baseline taken before the PR's last edits), no convergence pass |
| 2026-11-06 | run_2f339c0163f0 | 524 / 29 | 434 | 8026 | 8984 | +379 in SKILL.md: ~330 from 73acf37 (Issue standard, user commit), ~50 from #41/#33-34; no convergence pass on a fresh user change, next retro decides |

## Watch list
| id | root cause | kind | target | seen | last | status |
|---|---|---|---|---|---|---|
| W1 | no project config: merge-pr after left the live skills stale (main checkout 9 commits behind), prep ran no verify; 3 min | missing-instruction | .claude/issue-workflow.sh | 1 | run_c2462e5895bd | fixed 2026-11-06 .claude/issue-workflow.sh (#30): confirmed at PR #35, prep ran wf_verify and `after` left main at origin/main |
| W2 | inbox finding (#18) gave a repro that passed (spaced cwd instead of spaced skill dir); 2 min | spec-gap | inbox issue template (global CLAUDE.md) | 1 | run_c2462e5895bd | watching |
| W3 | guard.sh python block in shell single quotes broke on apostrophes; 6 min | escaped | guard.sh | 1 | run_869230114ca7 (4 guard.sh fix commits, no recurrence) | fixed 2026-11-06 guard.sh:73: expect no quote-breakage in the python block (chr(39) note, PR #26) |
| W4 | lead self-review of a risk-area PR misses mediums the opus reviewer then finds (#29: 2; #36: 1 ANSI-C false positive; #41: 3 in the busy-worker check); each cost one fix + delta round (~10 min) | escaped | build-gh-issue / WF_RISK_GLOBS | 3 | run_2f339c0163f0 | fixed 2026-11-06 .claude/issue-workflow.sh WF_RISK_GLOBS (#30 D2): working, all caught before merge; if it keeps costing a round, have the lead run /code-review high on risk-area PRs |
| W5 | checks grow with the suite: wf_verify 24 s -> 1m32 s once test-sweep.sh landed (#41), run 3-4x per PR; sweep.sh reads every Run and worker (49 Runs, 913 rows, ~19 s wall) on each `after` | overkill | wf_verify / sweep.sh | 1 | run_2f339c0163f0 | watching |
