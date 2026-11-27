# Decisions

Loaded by every stage skill (`/aw-ui-design`, `/aw-specify`, `/aw-build`) and by `/aw-coordinate`: who decides what, how an issue parks on a question for the user, and how it goes on once the answer is there. Script: `~/.claude/agent-workflow/bin/decide.sh` (usage: run it without arguments). Comment format: `~/.claude/agent-workflow/docs/decision-format.md`.

Goal: few questions, nothing waits that does not have to.

## One-way or two-way

- **One-way**: ask the user. The list is the profile's "Decisions"; the default: a Design round, reversing a recorded design decision, deleting or rewriting user data, an outward-facing or release action, a held merge, low confidence on something expensive to undo.
- **Two-way**: everything else. Take the recommendation, write it into the issue body's `## Decisions` (`D<k>: chosen · alternatives · why · cost to switch`; screenshots of the alternatives for look choices), post it with `decide.sh record <n> <file>` (the same four points, one line each; label `agent-decided`, never blocks) and continue. A scope change you agree is reasonable is two-way; say so in the record.

An interactive run asks the user directly instead (`AskUserQuestion`); an orchestrated worker never prompts locally.

## Park, don't wait

A one-way question in an unattended run becomes a decision request, and the run ends there:

1. Log where you stop, so the run that resumes finds it: `decide.sh log <n> "parked at <stage> step <k>: <what is done, what comes next>"`.
2. `decide.sh request <n> <file>`. The file: first line the question in plain words; then one line per question with its lettered options, `1 Merge: A ★ (merge now) · B (hold, today)`. The script writes the legend and the answer template, sets the label `needs-decision` and refuses another shape. The options are explained in the overview: `Overview: <link>` to a round or options comment, else `### 1. <label>: …` sections in the same file; what stays parked and the reasoning go into one `<details>`.
3. End the run and leave the branch and worktree as they are. An orchestrated worker reports `PARKED` as its task says.

The user answers with a comment on the issue, any time.

## Resume

Each stage skill starts with it, right after it loads the issue and before any other check or write: `decide.sh resume <n>`.

| Output | Exit | Meaning | Then |
|---|---|---|---|
| `held  #<n>: label on-hold` | 2 | the issue is on hold; nothing was changed, whatever its requests say | say that the issue is on hold and stop: no stage starts, no label or comment is written |
| `none` | 0 | no open request (never parked, or already resolved: a coordinator resolves before it starts a fresh worker) | go on with the skill as usual. With `log:` and log entries under it, the log's last entry is a `resumed` one: an answer was taken and nothing was logged since. If it answers a request of this stage and its result is not there yet (no new round, no spec, no further commit), the run that took it ended early: continue as for `resumed`. Otherwise go on as usual |
| `waiting  #<n> D<k> (<age>): <question>` | 2 | a request has no answer yet; nothing was changed | tell the user which decision waits and stop; change nothing on the issue |
| `resumed D<k> with: <answer>`, then `log: <path>` and the last log entries | 0 | the answer was read, the request resolved ("Resumed" comment, `needs-decision` removed, a served prototype stopped) | continue from the parked step with that answer |
| anything else | other | the issue could not be read | say so and stop; never treat it as `none` |

- The resume text spells the chosen options out (`1 Shell: B (footer bar)`), or passes the user's free text on as it is, in one line (the log keeps its first 1000 characters): read the comment on the issue when its paragraphs or lists matter, or when the text ends with `(cut: …)`. A question that reads `no answer` is still open: ask it again with a new request, or take free text in the answer into account.
- Every unmarked comment after a request counts as its answer. A text that decides nothing (a counter-question, a remark by someone else) was resolved all the same: answer it in a new request (`decide.sh request`, the reply in its first lines) and park again.
- The parked step is in the log entries `resume` printed (`parked at <stage> step <k> …`, written before the request; the script's own `parked D<k>: <question>` only repeats the question); read the whole log (`log: <path>`) only when they do not name it. The log lives on the machine that parked (`no log on this machine`): without entries, the request, its overview comment and the lane tell where the issue stands. Then check what already exists (the branch and worktree, the round or options comment, an open PR) and skip it: resume, never duplicate.
- A request belongs to the stage that parked it (the `parked at <stage>` entry names it; else the lane and the request's question do). When the running skill is another stage (Build started on an issue Specify parked), the answer is taken all the same: tell the user to run that stage's skill and give them the `resumed` line to pass on, then stop.
- Running it again is safe: after an answer was taken, the next run prints `none`.

## Hold

The label `on-hold` (set by the user, on GitHub or on their board) stops an issue: no stage starts on it (`resume` prints `held`) and its pull request is not merged (`merge-pr.sh prep` refuses). It holds in every repo, also one that sets its own `WF_HOLD_LABELS`; the other labels of that list hold the merge only. A stage that already runs is not interrupted. An orchestrated worker says so in its `worker_done` (succeeded: nothing was started); the hold ends when the user removes the label.

## Without a coordinator

The stage skills run on their own. Unattended then means: the run parks, the user answers on the issue, and the user runs `/<stage> <n>` again; its Resume step picks the answer up. The user's inbox is `decide.sh status` (answered and waiting requests, change requests on agent decisions) and `decide.sh digest` (the waiting ones as one list). A Design round has nobody to keep its local preview alive: serve it yourself before parking (`proto-serve.sh port <n>`, then `proto-serve.sh start <n> <worktree> <port>`, both in `~/.claude/agent-workflow/bin/`); `resume` stops it.

With `/aw-coordinate`, the coordinator sweeps the answers, resolves and starts the next worker (its section 5).
