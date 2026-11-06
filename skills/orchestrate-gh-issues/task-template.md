<!-- Read by spec.sh only (never loaded into a session). {{X}} placeholders are filled by spec.sh.
     The common block goes into every spec; one stage block follows it. -->
<!-- common -->
Issue #{{N}}: {{TITLE}}. Stage: {{STAGE}}. Tier: {{TIER}}.
Constraints: follow CLAUDE.md and .claude/issue-workflow.md. {{QUESTIONS}} A two-way choice you decide yourself, write into the issue body's `## Decisions` and `{{DECIDE}} record {{N}} <file>`. A one-way choice (orchestrate-gh-issues section 5, the profile's "Decisions") becomes `{{DECIDE}} request {{N}} <file>`; then park: worker_done --outcome succeeded, body starting `PARKED #{{N}} D<k>`, worktree left as is. Never merge. A Stop hook blocks ending your turn once without `worker_done` (after an `ask` or escalation you may end). An `ask` to the coordinator runs with the Bash tool's `run_in_background`, `--timeout-ms 1800000` at most; unanswered after one timeout: decide and `record` it. Dev server and every E2E run on PORT={{PORT}} only (the other ports in the range belong to other workers; run Playwright runs one after another: they share `test-results/`), the server started with `run_in_background` and `timeout: 7200000` (the default ends it after 30 min, mid-run) (never `nohup` or `( … & )`); stop only your own server by its port's PID. Absolute paths (a `cd` persists across calls); no `timeout` on macOS. Run only the E2E specs relevant to the change; the merge gate runs the rest. Writing tests: `/build-gh-issue` step 5. A rebase after the first push needs a force-push: `ask` the coordinator, workers cannot. Pass longer findings or context as a file path (--report-path), not pasted into messages. The guard hook checks PR bodies, issue-comment markers and trailing `&`; when it blocks, fix the command, never work around it.
Progress: coordination (stage start, milestones, PR link, review outcome, fix rounds) goes to the issue's coordination log with `{{DECIDE}} log {{N}} "<text>"`, never onto the issue; resuming, read it first (`cat "$({{DECIDE}} log --path {{N}})"`). The issue thread holds only what the user reads: decision requests and records, design rounds, the Look comment. Every comment passes `decide.sh check` (headline, options and recommendation visible; detail in `<details>`).
Ledger: as friction happens, `bash ~/.claude/skills/workflow-retro/ledger.sh -f {{LEDGER}}/{{N}}-{{STAGE}}.md add <kind> <minutes> <target> "<what | cause | fix idea>"` (kinds: `ledger.sh kinds`); run E2E and verify through `ledger.sh -f <same file> check -l <label> -- <command>`. No end-of-task feedback block.
<!-- /common -->
<!-- stage:lead -->
Target: issue #{{N}}, from spec to a PR that is ready to merge. You own the whole pipeline; the coordinator only merges.
Change, in order (skip a step whose result already exists: the issue is `ready` → no Specify; an open PR with `Closes #{{N}}` → no Build, continue at the route):
1. Issue labelled `needs-spec`, or `ready` without the issue standard (`~/.claude/agent-workflow/reference/issue-rules.md`) (Problem & job, Solution, UACs): run `/specify-gh-issue {{N}}` autonomously (its Complete track when only the standard is missing). Approach choices are two-way unless they hit a one-way item: choose, record (`## Decisions` + `decide.sh record`), continue; no `ask` to the coordinator. A route to `needs-design`: stop with worker_done body `ROUTED #{{N}} needs-design`.
2. Run `/build-gh-issue {{N}}` in this worktree: first `git branch -m {{BRANCH}}` before any commit or push. Run `/compact` first if Specify filled your context; the issue body holds the spec.
3. Right after `gh pr create`: `{{SKILLDIR}}/merge-pr.sh route <pr>`.
   - `reviewer`: add `## Review` with the single line `route: reviewer · <reason>` to the PR body (`gh pr edit <pr> --body-file`) and finish (step 5). A separate reviewer takes over.
   - `lead`: run `/code-review <pr>` (findings only: no `--fix`, never `ultra`; if it forks a background agent, wait with Monitor). Classify each finding by severity and introduced-by-PR, and check it against the issue's ACs (the review fork does not know the spec and flags spec'd behaviour). Fix every finding of medium or higher the PR introduced, plus confirmed regressions; at most 2 fix rounds, each followed by `/code-review` on the fix commits only. Other lows: list them; real defects outside the PR become `inbox` issues. Then check the `E2E-specs:` line as a reviewer would: `rg` the labels and testids of every element the diff changes in the E2E tests, and run and add each spec that asserts on them.
4. Write `## Review` into the PR body, exactly this format (merge-pr.sh parses it):
   ```
   ## Review
   route: lead · effort: <level> · by: <your model>
   - [medium|high|critical] <finding> (<file:line>) -> fixed <sha> | dismissed: <reason> | open
   lows: <n> (<one line>)
   ```
   A finding you could not fix in 2 rounds stays `-> open` (the coordinator holds the merge and reports it).
5. worker_done --outcome succeeded with a body starting `READY #{{N}} PR <url> route=<lead|reviewer>` (or `PARKED #{{N}} D<k>`, `ROUTED #{{N}} needs-design`; failure: --outcome failed, `FAILED #{{N}}: <reason>`).
Subagents: stuck on a root cause for more than 15 minutes, at most one `Agent` call with `model: opus` on that question (say so in the PR); mechanical sweeps (`rg` audits, copy or i18n sweeps, PR-body checks) may use `Agent` with `model: haiku`. A design-gate critique (profile "Design quality") always spawns its two isolated assessment sub-agents as the profile says; running it inline is a failed gate, not a budget saving.
Ownership: issue body, comments and labels; worktree {{BRANCH}} only.
Observable acceptance: PR URL with `Closes #{{N}}`, checks green per the profile, `## Review` in the format above.
<!-- /stage -->
<!-- stage:design -->
Target: issue #{{N}} (`needs-design`), one Design round.
Change: in this worktree, first `git branch -m {{BRANCH}}` before any commit or push; run `/design-gh-issue {{N}}` autonomously, one round, then park on the round's decision request.
Ownership: issue body, comments and labels; proto branch {{BRANCH}} only.
Observable acceptance: round screenshots on the issue and a decision request (`needs-decision`), or the `## UX decision` in the body and the label moved.
<!-- /stage -->
<!-- stage:review -->
Target: PR #{{PR}} for issue #{{N}}, in worktree {{WT}}. You are the independent reviewer (route `reviewer`).
Change: run `/code-review {{PR}}` (never `ultra`), findings only: no code edits, no `--fix`; if it forks a background agent, wait with Monitor. Classify each finding by severity and introduced-by-PR and check it against the issue's ACs (`gh issue view {{N}}`; the review fork does not know the spec and flags spec'd behaviour). Run E2E or a browser repro only to confirm a suspected finding of medium or higher. Compare the PR body's `E2E-specs:` line (if the profile has one) with the diff and the spec's "E2E at risk" line and add missing specs to that line in place, without running them. UI PRs: a missing design-gate result in the PR body is an open finding.
Then write only the `## Review` section of the PR body (replace the lead's `route: reviewer` line), in this format:
```
## Review
route: reviewer · effort: <level> · by: {{MODEL}}
- [medium|high|critical] <finding> (<file:line>) -> open | dismissed: <reason>
lows: <n> (<one line>)
```
Ownership: the PR body's `## Review` section and `E2E-specs:` line only; nothing else.
Observable acceptance: the `## Review` section; worker_done body starting `REVIEWED #{{N}} PR #{{PR}} open=<count>`.
<!-- /stage -->
<!-- stage:delta-review -->
Target: PR #{{PR}} for issue #{{N}}, in worktree {{WT}}: the fix commits since the last review only (`git diff <last reviewed sha>..HEAD`; `git range-diff` after a rebase), against the previous `## Review`.
Change: findings only, no edits. Confirm each `-> fixed <sha>` line, set any finding the fix did not resolve back to `-> open`, add new findings the fix introduced. Update only the `## Review` section, same format, `by: {{MODEL}}`.
Ownership: the PR body's `## Review` section only.
Observable acceptance: worker_done body starting `REVIEWED #{{N}} PR #{{PR}} open=<count>`.
<!-- /stage -->
<!-- stage:fix -->
Target: PR #{{PR}} for issue #{{N}}, in worktree {{WT}}: every `## Review` line ending in `-> open`.
Change: fix each open finding (test first where it is logic), run verify and the E2E specs the fix touches, push (no force-push), and set the line to `-> fixed <sha>` (or `-> dismissed: <reason>` when it turns out not to hold, with evidence). Keep the PR body's other rules: screenshots per the profile's "Pull requests"; edit the `E2E-specs:` line in place, never add a second. A user review in a PR comment: map each remark to its change in a `decide.sh note`.
Ownership: worktree of PR #{{PR}} only.
Observable acceptance: no `-> open` line left; worker_done body starting `FIXED #{{N}} PR #{{PR}}`.
<!-- /stage -->
