<!-- Brief for a wave coordinator (SKILL.md "1c. Waves"). The main coordinator fills the <...> parts,
     writes the result to a file and starts it with `worker-start --spec-file`. Keep it short: the wave
     coordinator screens its issues itself. -->
You are the WAVE COORDINATOR for wave <k> of a larger hand-off in <repo> (main checkout, default branch). Your Task is to coordinate, not to build: invoke the skill `/orchestrate-gh-issues` and act as its coordinator for the issues below, in autonomous mode, from screening to merged PRs. The Task and Dispatch preamble you carry does not make you a build worker: coordinating this wave is your Task. Create your own Run for your workers, start them, end your turn, and let Orca wake you. Send `worker_done` only when every issue of this wave has settled (merged, parked on a decision request, held or failed).

Why waves: the main coordinator (the user's session) keeps its context small. It only starts wave coordinators and reads their final report.

## Issues of this wave
<What earlier waves merged, one line (PR numbers).>
- <Inbox issues to triage first: "run `/gh-inbox-dispatcher` yourself for #a #b (you count as the user caller). What it routes joins this wave, unless it needs the user's input before any work can start: then park it with a decision request and report it.">
- <#n: one line each: what it is, suggested lane, suggested batch, risk area, an answer the user already gave.>
- <Default-branch CI: "check the latest completed full run; red is fixed forward in this wave", when the project runs one.>

Lanes and batches above are the main coordinator's screening, given as hints: verify them in your own screening (section 1b) and relabel where needed.

Not in this wave, do not start them: <issues of later waves, with the reason>. Out of scope entirely, do not touch: <excluded and held issues>.

## Differences from the skill (the user follows only the main coordinator's session)
- Never use `AskUserQuestion` or `PushNotification`. A one-way decision becomes `decide.sh request` on the issue as usual; the issue parks and goes into your final report. An issue parked on a decision counts as settled for this wave; an answer that arrives on the issue while you still run is picked up by your sweep as usual.
- Design rounds: run the round, park on its decision request, report the proto worktree path, branch and preview URL. Leave no dev server running when you finish.
- Worker questions you cannot answer safely from the spec, the profile, the docs or `CLAUDE.md`: `ask` the main coordinator, then end your turn.
- Merge green PRs by default (prep, `gh pr merge`, after), one at a time.
- New `inbox` issues that you or your workers file: do not start them; list their numbers in the final report. The main coordinator queues them into the next wave.
- Ledger and retro as the skill says; record the profile's open trial arms in your `coordinator.md`.

## Done means
The final report in `worker_done`, at most about 40 lines: one line per issue (merged with the PR link / parked with the question in one sentence / held / failed with the reason; fix rounds; models as accepted), `agent-decided` records worth the user's eye, new inbox issue numbers with a few words each, proto worktrees left for parked design rounds, the state of default-branch CI, one line on the retro and your run ledger dir. A parked or failed issue is a valid outcome, not a Task failure: report `failed` only if you could not coordinate the wave at all.
