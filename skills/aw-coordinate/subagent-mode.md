# Subagent mode: coordinate without Orca

Read when `preflight.sh` exits 69. You are the coordinator of the coordination rules (`~/.claude/agent-workflow/reference/coordination.md`): read them first, everything in them holds here. Of `SKILL.md` only the intro and section 0 apply (step 2 does not); its other sections describe the other runner. This file adds only how the stages run as Claude Code subagents.

A **worker** is a background subagent you start with the `Agent` tool, in a git worktree of its own. It returns one final message and cannot reach you while it runs. The run lives in this session: nothing wakes it after the session ends, so a decision the user answers later is picked up by running `/aw-coordinate <issues>` again (section 4).

No `Agent` tool in this session: say so and stop; the README's manual path (one stage skill per issue) is what is left.

## 1. Start

1. `SKILL.md` section 0, steps 3 and 4 (profile, settings, sweep). Work from the main checkout.
2. The run ledger dir, for every brief, the port reservations and your own `coordinator.md`: `bash ~/.claude/skills/aw-retro/ledger.sh dir sub-<YYYYMMDD-HHMM>`.
3. Input and screening as the coordination rules say. The facts come from `<this skill's directory>/plan.sh <n>…`: one line per issue with its next step (`design`, `lead`, `review`, `fix`, `merge`, `screen` for an issue without a lane, `skip` with the reason) and, for work that exists, `pr=` and `branch=` (`fix` and `delta-review` also `round=`, the fix round the stage belongs to). The judgement stays yours: the lane of a `screen` issue, batches, dependencies, order. There are no waves here: a hand-off too big for one round runs in the screened order through the same slots.

## 2. Run a stage

One stage is one `Agent` call.

1. **Brief**: `<this skill's directory>/spec.sh <stage> <n> --runner subagent --branch <branch> --ledger <dir> [--tier …] [--model <alias>] [--pr <pr>] [--batch <n,m>] [--extra <file>] [--interactive] [--no-port] > <dir>/<n>-<stage>.spec`. The branch of new work is yours to name by the profile's "Branches" (Design: `proto/<n>-<slug>`); for work that exists it is the `branch=` that `plan.sh` printed. Exit 3 = no free port: the stage waits for a slot. Never hand-build or shorten a brief.
2. **Start**: `Agent` with `subagent_type: "general-purpose"`, `isolation: "worktree"`, `run_in_background: true`, `description: "#<n> <stage>"`, `model` the row's alias (the coordination rules' "Models per role"), and the prompt `Your task is the brief in <absolute path of the .spec file>: read it completely, then do exactly that.` Always with `isolation: "worktree"`: the brief's first command (`wt.sh init <branch>`) refuses to run in the main checkout. When the tool refuses the `model` value, start without it (the worker then runs on this session's model) and say so in the final report. Before a `fix` worker, and before its `Agent` call: `~/.claude/agent-workflow/bin/rounds.sh` `start <n> <pr>` opens the round on the coordination log (exit 1, e.g. both rounds are used or a delta-review is due: start nothing, run `plan.sh <n>` and do what it shows).
3. **Slots**: at most `WF_MAX_WORKERS` workers at once (`~/.claude/agent-workflow/bin/settings.sh get WF_MAX_WORKERS`; `1` is a strict sequence). Never two stages of one issue or batch at once (the later stage's `wt.sh init` takes the branch over from the earlier one's worktree), and never two that screening put on a dependency edge.
4. **Wait**: never poll. The harness tells you when a worker ends; until then do what does not depend on it (merge a PR that is ready, sweep the decisions), else end your turn. A background worker's permission prompt shows up in this session and is the user's to answer.
5. **Settle** each worker when it ends:
   - Free its port: `spec.sh release-port <port> --ledger <dir>` (the port is the brief's last line, `PORT=<p>`).
   - Read the first line of its final message, run the `rounds.sh` command its row names ("Rounds" below), then check the result against GitHub with `plan.sh <n>` instead of trusting it:

     | Result line | `plan.sh` must show | Next |
     | --- | --- | --- |
     | `READY #<n> PR <url> route=lead` | `merge` | the merge queue (step 6); `hold` (a finding still `-> open`: the lead used its 2 rounds) is the rules' held merge: root-cause issue, decision request, never another fix worker |
     | `READY #<n> PR <url> route=reviewer` | `review` | stage `review` (`--pr <pr>`, the PR's branch) |
     | `REVIEWED #<n> PR #<pr> open=0` | `merge` | after a `delta-review` stage: `rounds.sh delta <n> <pr> open=0` first; the merge queue |
     | `REVIEWED #<n> PR #<pr> open=<k>` | `fix` | after a `delta-review` stage: `rounds.sh delta <n> <pr> open=<k>` first. Stage `fix` (`rounds.sh start` before it), then `delta-review`, within the rounds the rules allow; `hold` after 2 fix rounds: the held merge as above |
     | `FIXED #<n> PR #<pr>` | `delta-review`, also when the worker left a new `-> open` line; when the rules skip the delta-review (docs or comments only), after `rounds.sh delta <n> <pr> skipped`: `merge` (`fix` or `hold` with a line open) | `rounds.sh fixed <n> <pr>` first; then stage `delta-review`, else the merge queue |
     | `PARKED #<n> D<k>` | `skip` (waiting) | section 3; a Design round also gets its preview served as the rules say (the worktree: `git worktree list`, the line with the proto branch) |
     | `ROUTED #<n> needs-design` | `design` | stage `design` |
     | `FAILED #<n>: …`, no result line, or `plan.sh` shows another step | | one retry: a fresh worker for the step `plan.sh` shows, the failure text in `--extra`; a second failure ends that issue's pipeline and goes into the report |

   - **Rounds**: the fix and delta-review rounds of a PR are markers on the coordination log that only `~/.claude/agent-workflow/bin/rounds.sh` writes and reads (`start` before a fix worker, `fixed` after its `FIXED`, `delta` after the `REVIEWED` of a `delta-review` stage, never after a first `review`; its header has the rules). Never write a marker with `decide.sh log` and never count a round yourself: `plan.sh` prints `round=<k>`. A round that was started stays in flight until its delta marker, wherever the session got lost: `plan.sh` then shows `fix` (the same round goes on; `start` writes nothing new) while a line is still `-> open` and no `FIXED` was read, else `delta-review`, and never `merge`; `merge-pr.sh prep` refuses it too. The rounds belong to the PR: a batch PR's rounds are counted over the logs of all the issues it closes, and an issue's earlier PR leaves none behind. A round state that cannot be read shows as `unknown` and refuses the merge.
   - A `FAILED` that quotes `wt.sh` with `busy:` is not retried: an earlier worktree of the issue holds work that is not on `origin`. Report it with that path; pushing or discarding it is the user's call.
   - Then sweep the decisions (section 3) and start the next stages while slots are free.
6. **Merge**: the coordination rules' merge sequence, by yourself, from the main checkout, one PR at a time. `merge-pr.sh after` removes the PR's worktree and branches; the harness removes a worker's worktree that has no changes.

## 3. Decisions

The coordination rules' "Decisions and the user". Here:

- **Sweep** (`decide.sh status`) after every worker's end and before the final report. An `answered` request: `decide.sh resolve`, then a fresh worker on the same stage and branch, the line `resolve` printed quoted in its `--extra`.
- **Digest**, idle (no worker runs and nothing is runnable): ask with `AskUserQuestion` at once.
- **Interactive** issues: `spec.sh --interactive` makes the worker park on every choice. Ask the user as soon as it parks (`AskUserQuestion`), put the answer onto the issue (`decide.sh answer`), resolve and start the fresh worker.
- A worker cannot put a question to you mid-run: its brief tells it to decide a two-way choice and to park on a one-way one.

## 4. Resume and recovery

Durable state is on GitHub and in git, none of it in this session. After a lost session, or when the user comes back with answers: `plan.sh <issues>` gives each issue's next step and branch (it reads the fix rounds used and a round in flight from the round markers, section 2 step 5 "Rounds"; a `fix` or `delta-review` it shows for a round in flight is that round going on, not a new one), `decide.sh status` the decisions; go on from there and never start a second pipeline for an issue. A worker of a lost session is gone: what it pushed is taken over by the next stage's `wt.sh init`; what it did not push stays in its worktree and makes `wt.sh` exit 3 (step 5). The markers are on this machine only: a PR whose earlier fix rounds ran under the Orca coordinator (it writes none), or whose log is gone, counts as having used no round, so when you know of such rounds hold the merge yourself after the rounds the rules allow, and send a PR whose fix nobody reviewed to `delta-review` before the merge queue.

## 5. Reporting

The coordination rules' "Progress and reporting". The model per stage is the `model` you passed and the tool accepted. The `measures` line counts workers per issue as `Agent` calls.
