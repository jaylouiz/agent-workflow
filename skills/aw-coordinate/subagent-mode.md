# Subagent mode: coordinate without Orca

Read when `preflight.sh` exits 69. You are the coordinator of the coordination rules (`~/.claude/agent-workflow/reference/coordination.md`): read them first, everything in them holds here. Of `SKILL.md` only the intro and section 0 apply (step 2 does not); its other sections describe the other runner. This file adds only how the stages run as Claude Code subagents.

A **worker** is a background subagent you start with the `Agent` tool, in a git worktree of its own. It returns one final message and cannot reach you while it runs. The run lives in this session: nothing wakes it after the session ends, so a decision the user answers later is picked up by running `/aw-coordinate <issues>` again (section 4).

No `Agent` tool in this session: say so and stop; the README's manual path (one stage skill per issue) is what is left.

## 1. Start

1. `SKILL.md` section 0, steps 3 and 4 (profile, settings, sweep). Work from the main checkout.
2. The run ledger dir, for every brief, the port reservations and your own `coordinator.md`: `bash ~/.claude/skills/aw-retro/ledger.sh dir sub-<YYYYMMDD-HHMM>`.
3. Input and screening as the coordination rules say. The facts come from `<this skill's directory>/plan.sh <n>…`: one line per issue with its next step (`design`, `lead`, `review`, `fix`, `merge`, `screen` for an issue without a lane, `skip` with the reason) and, for work that exists, `pr=` and `branch=`. The judgement stays yours: the lane of a `screen` issue, batches, dependencies, order. There are no waves here: a hand-off too big for one round runs in the screened order through the same slots.

## 2. Run a stage

One stage is one `Agent` call.

1. **Brief**: `<this skill's directory>/spec.sh <stage> <n> --runner subagent --branch <branch> --ledger <dir> [--tier …] [--model <alias>] [--pr <pr>] [--batch <n,m>] [--extra <file>] [--interactive] [--no-port] > <dir>/<n>-<stage>.spec`. The branch of new work is yours to name by the profile's "Branches" (Design: `proto/<n>-<slug>`); for work that exists it is the `branch=` that `plan.sh` printed. Exit 3 = no free port: the stage waits for a slot. Never hand-build or shorten a brief.
2. **Start**: `Agent` with `subagent_type: "general-purpose"`, `isolation: "worktree"`, `run_in_background: true`, `description: "#<n> <stage>"`, `model` the row's alias (the coordination rules' "Models per role"), and the prompt `Your task is the brief in <absolute path of the .spec file>: read it completely, then do exactly that.` Always with `isolation: "worktree"`: the brief's first command (`wt.sh init <branch>`) refuses to run in the main checkout. When the tool refuses the `model` value, start without it (the worker then runs on this session's model) and say so in the final report.
3. **Slots**: at most `WF_MAX_WORKERS` workers at once (`~/.claude/agent-workflow/bin/settings.sh get WF_MAX_WORKERS`; `1` is a strict sequence). Never two stages of one issue or batch at once (the later stage's `wt.sh init` takes the branch over from the earlier one's worktree), and never two that screening put on a dependency edge.
4. **Wait**: never poll. The harness tells you when a worker ends; until then do what does not depend on it (merge a PR that is ready, sweep the decisions), else end your turn. A background worker's permission prompt shows up in this session and is the user's to answer.
5. **Settle** each worker when it ends:
   - Free its port: `spec.sh release-port <port> --ledger <dir>` (the port is the brief's last line, `PORT=<p>`).
   - Read the first line of its final message, write its round marker if the table has one (below), then check the result against GitHub with `plan.sh <n>` instead of trusting it:

     | Result line | `plan.sh` must show | Next |
     | --- | --- | --- |
     | `READY #<n> PR <url> route=lead` | `merge` | the merge queue (step 6); `hold` (a finding still `-> open`: the lead used its 2 rounds) is the rules' held merge: root-cause issue, decision request, never another fix worker |
     | `READY #<n> PR <url> route=reviewer` | `review` | stage `review` (`--pr <pr>`, the PR's branch) |
     | `REVIEWED #<n> PR #<pr> open=0` | `merge` | after a delta-review: marker `round: delta <r> settled open=0` first (`<r>` = the settled fix round it reviews); the merge queue |
     | `REVIEWED #<n> PR #<pr> open=<k>` | `fix` | after a delta-review: marker `round: delta <r> settled open=<k>` first. Stage `fix`, then `delta-review`, within the rounds the rules allow; `hold` after 2 settled fix rounds: the held merge as above |
     | `FIXED #<n> PR #<pr>` | `delta-review` (a settled fix round has no delta marker) or, when the rules skip it (docs or comments only: marker `round: delta <r> skipped`), `merge` | marker `round: fix <r> settled <sha>` first (`<r>` = settled fix rounds + 1, `<sha>` = the PR's head, `gh pr view <pr> --json headRefOid`); then stage `delta-review`, else the merge queue |
     | `PARKED #<n> D<k>` | `skip` (waiting) | section 3; a Design round also gets its preview served as the rules say (the worktree: `git worktree list`, the line with the proto branch) |
     | `ROUTED #<n> needs-design` | `design` | stage `design` |
     | `FAILED #<n>: …`, no result line, or `plan.sh` shows another step | | one retry: a fresh worker for the step `plan.sh` shows, the failure text in `--extra`; a second failure ends that issue's pipeline and goes into the report |

   - **Round markers**: only you write them, with `decide.sh log <n> "<marker>"`, as the exact line shown and never worded otherwise; `plan.sh` counts only these lines and ignores worker free text such as "fix round 1 done". Write each when the worker's final line is read, before `plan.sh`: a fix marker before its delta-review starts (a lost session then resumes at `delta-review`, never at `merge`), a delta marker when the delta-review worker has ended (a lost session during it repeats the delta-review). A fix round counts as reviewed only when a delta marker with the same `<r>` exists.
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

Durable state is on GitHub and in git, none of it in this session. After a lost session, or when the user comes back with answers: `plan.sh <issues>` gives each issue's next step and branch (it reads the settled fix rounds and a pending delta-review from the round markers on the coordination log, section 2 step 5: write them as they happen, else a lost session resumes at `merge` with a fix nobody reviewed), `decide.sh status` the decisions; go on from there and never start a second pipeline for an issue. A worker of a lost session is gone: what it pushed is taken over by the next stage's `wt.sh init`; what it did not push stays in its worktree and makes `wt.sh` exit 3 (step 5).

## 5. Reporting

The coordination rules' "Progress and reporting". The model per stage is the `model` you passed and the tool accepted. The `measures` line counts workers per issue as `Agent` calls.
