# Spec template

Use these headings in this order. Delete sections that do not apply (for example the UX decision on non-UI issues), but never leave a section empty. The first layers follow the issue standard (`reference/issue-rules.md`); mark what you inferred `(inferred)`.

```markdown
## Problem
One to three sentences, solution-free: who, in what situation, what is wrong or missing (or which delight is missing), and why it matters. Tech-only: what hurts technically and why it matters.

**Job:** <id and job from the profile's "Jobs" | new job: <proposal for the user> | none (tech-only)>
**Source:** backlog ID / audit finding / link, if any.

## Solution
2-5 lines: the current shape of the answer (from the request at first, then what Design and this spec decided), with the user's own requirements (e.g. a trigger, an adopted rule) marked `(user, <date>)`. The sections below are its detail.

## User stories
- As <who>, when <situation>, I want <what>, so that <outcome>.
Only when Design did not run (Design's stories live in the UX decision). Delete for tech-only issues.

## UX decision
Copied unchanged from Design (`/design-gh-issue`), when it ran. UI issues only.

## Chosen approach
The technical approach and why, in a few lines. Name the rejected approaches in one line (details are in the options comment).

## Layout
Light UI without a UX decision only: ASCII for desktop and mobile width. A structural sketch, not a visual spec; styling follows the design system.

## Acceptance criteria
**User (UAC)**: copied unchanged when Design wrote them, else written here.
- [ ] <behaviour the user can observe, one per line; each story and each state the UX decision or notes name (e.g. with/without topic) gets its own line, since implementers test only the ACs. Tech-only: "user-visible behaviour unchanged" plus measurable checks>
- [ ] <the profile's default ACs for UI, adapted>

**Technical**
- [ ] <what the build must also guarantee that the user cannot see: persistence, migration, sync, performance, tests; delete the list when empty>

## Out of scope
Things someone might expect that this issue deliberately does not do.

## Accepted trade-offs
Deliberate decisions that design reviews must respect, each with a reason. Delete when unused.

## Hazards
Only for an action that cannot be undone (a posted comment, a deletion, a send, a payment): the ways it fires wrongly or fails unseen (a held key's auto-repeat, state swapped under the input, a silent failure, a double submit), each with the AC or test that covers it. Delete otherwise.

## Implementation notes
Files and components involved, store or service changes, design-system rules that apply, known pitfalls (risk areas and invariants from the profile, CLAUDE.md and the matching `.claude/rules/` files).

## Verification
Which tests (unit, E2E, visual baselines) and which design-quality commands prove the criteria. Name only test files that exist (list the test folder), and `grep` for existing assertions and baselines the change moves.

E2E at risk: <basenames of the `tests/e2e/*.spec.ts` that exercise the touched areas (the profile's risk areas and `.claude/hooks/e2e-gate.json` show what the gate maps by itself; name what it cannot know: `rg` every touched component name, `data-testid` and removed or moved title across `tests/e2e` and list the specs that hit, e.g. a flow reached through a shared component; run 4 of 13 PRs missed specs the gate map did not hold); omit the line when nothing is at risk (the builder copies these names into the PR's `E2E-specs:` line)>

## Original notes
The author's original text, unchanged. Omit if the original body was empty.
```
