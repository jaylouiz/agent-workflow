# Global workflow rules

## Out-of-scope opportunities -> GitHub `inbox`

Worthwhile things noticed outside the current task (bugs, design debt, refactors, missing tests, ideas) are neither fixed in the current change nor lost:

- File one GitHub issue per opportunity with label `inbox` (`gh label create inbox --force --description "Unsorted out-of-scope finding, needs triage"`, then `gh issue create --label inbox`).
- Body: what was noticed, where (file:line), why it matters, how it was found (skill/task/PR). No spec, no solution design; triage happens later (`inbox` -> a lane).
- Dedupe first: `gh issue list --search "<keywords>" --state all`; comment on an existing issue instead of opening a duplicate.
- Only in repos the user owns/works in and whose tracker is GitHub. Never in public or third-party repos without asking. Skip if there is no `gh` auth.
- Only real, concrete findings. No speculative or stylistic nitpicks. At most ~5 per run; if more, bundle the rest into one issue.
- Inbox issues are never picked up by `/orchestrate-gh-issues`, `/design-gh-issue`, `/specify-gh-issue` or `/build-gh-issue` until relabelled by the user or by `/gh-inbox-dispatcher` (which the user invokes or allows). Mention the filed issues in one line in the final report.
- Formal audit deliverables that a project already stores in docs (e.g. `docs/design/backlog.md`) stay there; `inbox` is for side-findings outside the task.

## Unspecific, large goals -> `/wayfinder` (only when needed)

If an issue or idea has a vague destination, many possible directions, and is too big for one session, recommend `/wayfinder` to chart it as decision tickets first. Otherwise (the normal case) use the project's lanes (Design, Specify, Build; `~/.claude/agent-workflow/README.md`). `/wayfinder` is user-invoked and human-in-the-loop: agents and unattended workers never start it; they stop and hand the issue back to the user.

## Self-improvement: friction ledger and retro (standing practice)

Goal: fewer round trips, fewer errors, checks sized to the change, and instructions that stay small.

- **While working** (every multi-step session: orchestration run, design, specify or build of an issue, review, longer debugging; workers and sub-agents too): the moment something costs ~2+ minutes, a retry or a round trip, log one line with `bash ~/.claude/skills/workflow-retro/ledger.sh add <kind> <minutes> <target> "<what | cause | fix idea>"` (`ledger.sh kinds`; orchestrated workers pass the `-f` file their spec names). Also log a `win` that must survive a cleanup. Never log "all fine".
- **At the end** the session owner runs `/workflow-retro` over all ledgers (it picks the cheapest fix: delete, merge, mechanism, then a new rule); workers only hand theirs over. One line in the final report says what changed where.
- **Budget**: every always-loaded `CLAUDE.md` stays under 200 lines (Anthropic's guidance) and holds only what the code cannot tell. An addition that would cross the budget first deletes code-derivable text or moves something out: a subsystem rule to path-scoped `.claude/rules/` (`paths:`), a procedure to a skill, a zero-exception rule to a hook or deny rule. If none of that works, the addition is cut.

## Multiple issues -> screen all first

When handed several issues at once, read and screen all of them first (size, area overlap, dependencies, lane) and derive the order and parallelisation before dispatching anything.
