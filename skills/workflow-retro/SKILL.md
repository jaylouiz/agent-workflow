---
name: workflow-retro
description: Use when a multi-step agent session or orchestration run ends (design, specify, build, review, longer debugging) and its friction ledgers should turn into workflow improvements, or when asked for a retro, "what slowed us down", "too many rules", or to converge, clean up or shrink skills, CLAUDE.md or the project profile.
argument-hint: "[run_id | ledger dir | ledger file]"
---

# Workflow retro

Turn what agents logged *while* working (`ledger.sh`, global CLAUDE.md) into fewer round trips, fewer errors and checks sized to the change, without growing the instructions. The session owner runs it; workers only hand over their ledger. A retro whose only output is deleting or merging rules is a good retro; zero edits is a fine outcome.

## 1. Collect

- Ledgers: the run's dir (`bash <this skill's dir>/ledger.sh dir <run_id>`), or this session's file (`ledger.sh path`), plus your own.
- Metrics: per stage wall time (orchestrated: `orca orchestration task-list --run <id> --json --full` (the concise view has no timestamps), `created_at` → `completed_at`), fix rounds, review findings by severity, every `[check]` line, and the profile's "Retro" metric sources (e.g. hook logs).
- The running log (path in the profile's "Retro") and the last context-size row.

## 2. Find causes

1. Group entries by **root cause**, not symptom. The same cause in two workers' ledgers is the strongest signal of the run.
2. Attribute each to the stage or file that could have prevented it. A Build `spec-gap` is a Specify or spec-template fix; a review finding is an `escaped` against the check that should have caught it.
3. **Scope against checks**, per PR: diff size and area against what ran (`[check]` lines, gate tier) and how long. Record both directions: `overkill` (time spent where nothing could break) and `escaped` (defects a cheaper check would have caught). Loosen a check only where its area shows no escapes.

## 3. Decide with the running log

Update each matching watch-list row (seen count, last run) or add one; find rows with `grep` by cause or id, never by reading the whole log. Then:

- **Act** on a cause seen in 2+ runs, or once when it cost ≥ 15 min or an instruction was plainly wrong.
- **Effect check**: a `fixed` row whose cause shows up again means the fix did not work; mark it `recurred` and pick a stronger action below, never a second sentence of the same rule.
- **Drop** rows not seen in the last 5 retros.

Choose the action in this order; the first that works wins:
1. Delete or correct a wrong or unused instruction.
2. Merge into an instruction that already covers the area.
3. Mechanism: script, hook, lint rule, template slot, default flag. Required when a written rule was broken twice.
4. New prose rule, naming what it replaces or why nothing could.

## 4. Converge

Measure the files in the profile's "Context files" (`wc -w`; `wc -l` too for each `CLAUDE.md`) and add a row to the running log. Run a convergence pass when the total grew since the last row, an always-loaded `CLAUDE.md` reaches the line budget (global CLAUDE.md "Budget", which also binds step 5 edits), a ledger has `rule-overload` entries, or the last pass is 5+ retros old:

- merge rules that say the same thing in two places (one home, pointers elsewhere);
- delete rules that restate the code, a tool's `--help` or another skill, and rules with no hit (no ledger entry, no `win`) whose failure would be cheap;
- move out of always-loaded files to the targets "Budget" names, and workflow facts to the profile;
- keep anything a `win` entry vouches for.

## 5. Apply and record

- Small, certain edits: apply now with the writing rules of `harvesting-session-knowledge` (read first, replace don't append). Method changes go to the agent-workflow repo (`~/.claude/agent-workflow`, a link to its checkout; commit and push); project facts go where the profile's "Retro" says.
- Larger or uncertain ones: an `inbox` issue in the repo that owns the target (global CLAUDE.md rules).
- Watch-list rows you acted on get `fixed <date> <file>` plus the expected effect, so the next retro can check it.
- Delete the processed ledgers (the log holds what matters).
- Report one line per change (what, where, which cause) plus the context-size delta. Spell ids out for the user ("watch list item 7", not "W7").

## Running log format

```markdown
## Context size (words)
| date | run | <file> | <file> | ... | total | note |
```

`CLAUDE.md` cells are `<words> / <lines>`; older rows hold words only.

```markdown

## Watch list
| id | root cause | kind | target | seen | last | status |
```

`status`: `watching` | `fixed <date> <file>: expect <effect>` | `recurred` | `dropped`.
