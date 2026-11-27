<!-- Read by spec.sh only (never loaded into a session). {{X}} placeholders are filled by spec.sh.
     The common block goes into every spec; one stage block follows it. The rules are the same for both runners;
     the sentences that differ (how a worker reports, parks and asks) are the phrases below, one `KEY=text` line
     each, picked by `spec.sh --runner <orca|subagent>` (default orca). An empty value is allowed. -->
<!-- phrases:orca -->
START=
PARK=worker_done --outcome succeeded, body starting `PARKED #{{N}} D<k>`, worktree left as is
TURN=Never end your turn while a `run_in_background` job of your own (E2E, server) is still running: wait for it with Monitor, else the coordinator sees "stopped without reporting". A Stop hook blocks ending your turn once without `worker_done` (after an `ask` or escalation you may end). An `ask` to the coordinator runs with the Bash tool's `run_in_background`, `--timeout-ms 1800000` at most; unanswered after one timeout: decide and `record` it.
REBASE=A rebase after the first push needs a force-push: `ask` the coordinator, workers cannot.
FINDINGS=Pass longer findings or context as a file path (--report-path), not pasted into messages.
BRANCH_STEP=first `git branch -m {{BRANCH}}` before any commit or push
NO_ASK=; no `ask` to the coordinator
REPORT=worker_done body
REPORT_IN=`worker_done`
LEAD_DONE=worker_done --outcome succeeded with a body starting `READY #{{N}} PR <url> route=<lead|reviewer>` (or `PARKED #{{N}} D<k>`, `ROUTED #{{N}} needs-design`; could not finish (no PR, no access): --outcome failed, `FAILED #{{N}}: <reason>`). Every other stage: red checks or open findings are a `succeeded` report, never `failed`.
<!-- /phrases -->
<!-- phrases:subagent -->
START=You are a Claude Code subagent of the coordinator session, in a git worktree of your own. Your first command: `{{SKILLDIR}}/wt.sh init {{BRANCH}}` (it puts the stage's branch into this worktree; on a non-zero exit change nothing and end with `FAILED #{{N}}: <its message>`). Your final message is your only report: its first line is the result line this brief names, then three sentences (what you did, what you found, what is left). Before it, commit and push the branch: the next stage takes the branch over from `origin`, and the harness may remove this worktree. A skill named here (`/aw-build {{N}}`) is called with the Skill tool; without that tool, read its `SKILL.md` under `~/.claude/skills/` and follow it. Then:{{SP}}
PARK=commit and push your branch and end with a final message starting `PARKED #{{N}} D<k>`
TURN=Never end while a `run_in_background` job of your own (E2E, server) is still running: wait for it with Monitor. You cannot reach the coordinator mid-run: a question you would have asked is a two-way choice you decide and `record`, or a one-way one that parks.
REBASE=Never rebase after the first push (no force-push): merge the default branch in instead.
FINDINGS=Put longer findings or context into a file in the ledger's directory and name its path in your final message.
BRANCH_STEP=on the branch `{{BRANCH}}` that `wt.sh init` set
NO_ASK=
REPORT=final message
REPORT_IN=your final message
LEAD_DONE=End with a final message starting `READY #{{N}} PR <url> route=<lead|reviewer>` (or `PARKED #{{N}} D<k>`, `ROUTED #{{N}} needs-design`; could not finish (no PR, no access): `FAILED #{{N}}: <reason>`). Red checks or open findings are still `READY`, never `FAILED`.
<!-- /phrases -->
<!-- common -->
Issue #{{N}}: {{TITLE}}. Stage: {{STAGE}}. Tier: {{TIER}}.
Constraints: {{START}}follow CLAUDE.md and .claude/issue-workflow.md. {{QUESTIONS}} A two-way choice you decide yourself, write into the issue body's `## Decisions` and `{{DECIDE}} record {{N}} <file>`. A one-way choice (`~/.claude/agent-workflow/reference/decisions.md`, the profile's "Decisions") becomes `{{DECIDE}} request {{N}} <file>`; then park: {{PARK}}. Never merge. {{TURN}} Dev server and every E2E run on PORT={{PORT}} only (the other ports in the range belong to other workers; run Playwright runs one after another: they share `test-results/`), the server started with `run_in_background` and `timeout: 7200000` (the default ends it after 30 min, mid-run) (never `nohup` or `( … & )`); stop only your own server by its port's PID. Reproduce a bug that writes to git or user data only in a throwaway clone or temp HOME, never against the shared repository (every worktree shares its `.git`) or real data. Absolute paths (a `cd` persists across calls); no `timeout` on macOS. Run only the E2E specs relevant to the change; the merge gate runs the rest. Writing tests: `/aw-build` step 5. {{REBASE}} {{FINDINGS}} The guard hook checks PR bodies, issue-comment markers and trailing `&`; when it blocks, fix the command, never work around it.
Progress: coordination (stage start, milestones, PR link, review outcome, fix rounds) goes to the issue's coordination log with `{{DECIDE}} log {{N}} "<text>"`, never onto the issue; resuming, read it first (`cat "$({{DECIDE}} log --path {{N}})"`). The issue thread holds only what the user reads: decision requests and records, design rounds, the Look comment. Every comment passes `decide.sh check` (short visible text, options in the overview shape, detail in one `<details>`).
Ledger: as friction happens, `bash ~/.claude/skills/aw-retro/ledger.sh -f {{LEDGER}}/{{N}}-{{STAGE}}.md add <kind> <minutes> <target> "<what | cause | fix idea>"` (kinds: `ledger.sh kinds`); run E2E and verify through `ledger.sh -f <same file> check -l <label> -- <command>`. No end-of-task feedback block.
<!-- /common -->
<!-- stage:lead -->
Target: issue #{{N}}, from spec to a PR that is ready to merge. You own the whole pipeline; the coordinator only merges.
Change, in order (skip a step whose result already exists: the issue is `ready` → no Specify; an open PR with `Closes #{{N}}` → no Build, continue at the route):
1. Issue labelled `needs-spec`, or `ready` without the issue standard (`~/.claude/agent-workflow/reference/issue-rules.md`) (Problem & job, Solution, UACs): run `/aw-specify {{N}}` autonomously (its Complete track when only the standard is missing). Approach choices are two-way unless they hit a one-way item: choose, record (`## Decisions` + `decide.sh record`), continue{{NO_ASK}}. A route to `needs-design`: stop with {{REPORT}} `ROUTED #{{N}} needs-design`.
2. Run `/aw-build {{N}}` in this worktree: {{BRANCH_STEP}}.
3. Right after `gh pr create`: `{{BINDIR}}/merge-pr.sh route <pr>`.
   - `reviewer`: add `## Review` with the single line `route: reviewer · <reason>` to the PR body (`gh pr edit <pr> --body-file`) and finish (step 5). A separate reviewer takes over.
   - `lead`: run `/code-review <pr>` (findings only: no `--fix`, never `ultra`; if it forks a background agent, wait with Monitor). Classify each finding by severity and introduced-by-PR, and check it against the issue's ACs (the review fork does not know the spec and flags spec'd behaviour). Fix every finding of medium or higher the PR introduced, plus confirmed regressions; at most 2 fix rounds, each followed by `/code-review` on the fix commits only. Other lows: list them; real defects outside the PR become `inbox` issues (when `gh issue create` is denied, put each under "Inbox to file" in the PR body and name them in {{REPORT_IN}}; the coordinator files them). Then check the PR-body lines the project's `wf_pr_body_check` requires as a reviewer would: when one names the E2E specs for the merge gate, `rg` the labels and test ids of every element the diff changes in the project's E2E specs, and run and add each spec that asserts on them.
4. Write `## Review` into the PR body, exactly this format (merge-pr.sh parses it):
   ```
   ## Review
   route: lead · by: <your model>
   - [medium|high|critical] <finding> (<file:line>) -> fixed <sha> | dismissed: <reason> | open
   lows: <n> (<one line>)
   ```
   A finding you could not fix in 2 rounds stays `-> open` (the coordinator holds the merge and reports it).
5. {{LEAD_DONE}}
Subagents: stuck on a root cause for more than 15 minutes, at most one `Agent` call with `model: {{MODEL_STRONG}}` on that question (say so in the PR); mechanical sweeps (`rg` audits, copy or i18n sweeps, PR-body checks) may use `Agent` with `model: {{MODEL_FAST}}`. Design gate (profile "Design quality"): a UI PR gets its `/impeccable critique` result (if installed; otherwise the result of the gate that profile section names) in the body BEFORE `gh pr create`; if you cannot spawn the isolated sub-agent, run it inline and say so in the body (the profile allows it; skipping it costs a review finding and a fix round). A flake or red-main fix states the result of the profile's repeat-run command (10 runs, 30 for a flake proof) in the body (profile "Orchestration").
Ownership: issue body, comments and labels; worktree {{BRANCH}} only.
Observable acceptance: PR URL with `Closes #{{N}}`, checks green per the profile, `## Review` in the format above.
<!-- /stage -->
<!-- stage:design -->
Target: issue #{{N}} (`needs-design`), one Design round.
Change: in this worktree, {{BRANCH_STEP}}; run `/aw-ui-design {{N}}` autonomously, one round, then park on the round's decision request.
Preview: your dev server dies with you, so the coordinator serves this worktree on preview port {{PROTO_PORT}} while the decision waits. After the push, `proto-serve.sh hosted <branch>` gives the hosted preview: its URL is the `Preview:` link and `Local: http://localhost:{{PROTO_PORT}}/…` (same route and variant) the fallback line under it; exit 2 = none, then `Preview:` is the local link. Your own dev server keeps PORT. `none` = no preview port was free: link your own port and say so in your `PARKED` body.
Ownership: issue body, comments and labels; proto branch {{BRANCH}} only.
Observable acceptance: round screenshots on the issue and a decision request (`needs-decision`), or the `## UX decision` in the body and the label moved.
<!-- /stage -->
<!-- stage:review -->
Target: PR #{{PR}} for issue #{{N}}, in worktree {{WT}}. You are the independent reviewer (route `reviewer`).
Change: run `/code-review {{PR}}` (never `ultra`), findings only: no code edits, no `--fix`; if it forks a background agent, wait with Monitor. Classify each finding by severity and introduced-by-PR and check it against the issue's ACs (`gh issue view {{N}}`; the review fork does not know the spec and flags spec'd behaviour). Run E2E or a browser repro only to confirm a suspected finding of medium or higher. GitHub CI: read `gh pr checks {{PR}}` once and report what it shows; never wait or end the turn for CI (nothing wakes you, the coordinator checks CI at merge). Compare the PR-body lines the project's `wf_pr_body_check` requires (e.g. one naming the E2E specs for the merge gate) with the diff and the spec's "E2E at risk" line and add what is missing to that line in place, without running it. UI PRs: a missing design-gate result in the PR body is an open finding.
Then write only the `## Review` section of the PR body (replace the lead's `route: reviewer` line), in this format:
```
## Review
route: reviewer · by: {{MODEL}}
- [medium|high|critical] <finding> (<file:line>) -> open | dismissed: <reason>
lows: <n> (<one line>)
```
Ownership: the PR body's `## Review` section and the PR-body lines the project's `wf_pr_body_check` requires only; nothing else.
Observable acceptance: the `## Review` section; {{REPORT}} starting `REVIEWED #{{N}} PR #{{PR}} open=<count>`.
<!-- /stage -->
<!-- stage:delta-review -->
Target: PR #{{PR}} for issue #{{N}}, in worktree {{WT}}: the fix commits since the last review only (`git diff <last reviewed sha>..HEAD`; `git range-diff` after a rebase), against the previous `## Review`.
Change: findings only, no edits. Confirm each `-> fixed <sha>` line, set any finding the fix did not resolve back to `-> open`, add new findings the fix introduced. Update only the `## Review` section, same format, `by: {{MODEL}}`; replace the earlier `route:` line with yours. Check that each fix also covers the finding's sibling cases (other breakpoints, tiles, variants).
Ownership: the PR body's `## Review` section only.
Observable acceptance: {{REPORT}} starting `REVIEWED #{{N}} PR #{{PR}} open=<count>`.
<!-- /stage -->
<!-- stage:fix -->
Target: PR #{{PR}} for issue #{{N}}, in worktree {{WT}}: every `## Review` line ending in `-> open`, plus every task in the `Notes:` block at the end (a gate failure, a merge conflict, a decided follow-up). Notes tasks are work even when no `-> open` line exists: do them, never answer "no open lines, nothing changed".
Change: fix each open finding (test first where it is logic); for each, find its sibling cases (other breakpoints, tiles, sources, variants of the same code path) and fix or test them in the same round; run verify and the E2E specs the fix touches, push (no force-push), and set the line to `-> fixed <sha>` (or `-> dismissed: <reason>` when it turns out not to hold, with evidence). A finding resolved by a decision (code differs from the spec on purpose) also updates the issue body in the same round: the acceptance criteria it contradicts and `## Decisions`. A risk you would only document (a known trap that can lose or strand user data) is a new `-> open` line, never a note in the report. Keep the PR body's other rules: screenshots per the profile's "Pull requests"; edit a line the project's `wf_pr_body_check` requires in place, never add a second. A user review in a PR comment: map each remark to its change in a `decide.sh note`.
Ownership: worktree of PR #{{PR}} only.
Observable acceptance: no `-> open` line left and every Notes task done; {{REPORT}} starting `FIXED #{{N}} PR #{{PR}}`.
<!-- /stage -->
