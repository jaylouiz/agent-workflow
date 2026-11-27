# Board client contract v1

What a board client may rely on: the comments agents write on an issue, the labels and statuses they set, the
coordination log, and the two ways a client reaches a coordinator. [Tandem](https://github.com/jaylouiz/tandem) is the
reference client; "a client" below means any program that reads issues the way it does.

- **Version**: the number in this title and in `docs/contract-fixtures/manifest.json` (`"contract": 1`). Comments carry
  no version: old comments stay readable, and a client pins the document, not a comment.
- **Change rule**: every string in a table below is byte-stable. Changing one bumps the version here and in the
  manifest, regenerates the fixtures, and needs a pull request in the reference client before it merges here. Adding a
  comment kind, a label or a field a client can ignore is no bump.
- The human-facing side (how a decision is written and answered) is [decision-format.md](decision-format.md). The
  scripts: `bin/decide.sh`, `bin/decision_format.py`, `bin/issue-status.sh`.

## Golden fixtures

`docs/contract-fixtures/` holds one comment per shape, byte for byte as the writer posts it, and what a client must
read from it:

| File | What |
|---|---|
| `<name>.md` | the comment body (or the coordination log) |
| `<name>.json` | the expectation: what `bin/contract_reader.py`, a reader that follows only the rules below, gets from the body |
| `answers.json` | the replies a client writes: `text` is the comment, `picks` and `notes` are what the user chose in the client (`null`: typed by hand), `reads_as` is how `decide.sh` spells it out against the fixture named in `request` (`null`: passed on as free text) |
| `manifest.json` | the contract version, the fixtures and the writer of each |

`bash bin/test-decide.sh --write-fixtures` writes the directory from the real writers (`decide.sh` with a stubbed
`gh`); the default run fails when a file differs. The round is the example of decision-format.md "Overview" and the
look follows the Build skill's template: agents write these two by hand, so the fixtures are exemplars the checks accept.

**Pinning**: a client copies the directory into its own repository (noting the commit it took it from), parses each
`<name>.md` with its own reader, compares with `<name>.json`, builds each entry of `answers.json` with its own writer,
and asserts that `manifest.contract` is the version it supports.

<a id="comment-markers"></a>

## Comment markers

Every agent comment starts with `<!-- decision-<kind> … -->`, so it never reads as the user's.

| Marker | Written by | Meaning |
|---|---|---|
| `<!-- decision-request D<k> -->` | `decide.sh request` | a one-way question; the issue is parked (label `needs-decision`) |
| `<!-- decision-record D<k> -->` | `decide.sh record` | a two-way decision an agent made (label `agent-decided`) |
| `<!-- decision-answer D<k> -->` | `decide.sh answer` | an answer the user gave elsewhere; line 2 starts `Answer from the user (via the coordinator): ` |
| `<!-- decision-resolved D<k> -->` | `decide.sh resolve` | the answer was taken: `Resumed (D<k>)…` |
| `<!-- decision-followup D<k> -->` | `decide.sh followup` | a change request on a record became its own issue |
| `<!-- decision-note round R<k> -->` | the Design skill | a design round, the overview of its questions |
| `<!-- decision-note options -->` | the Specify skill | technical approaches, in the overview shape |
| `<!-- decision-note look -->` | the Build skill | the Look comment of a `ux-impact` issue |
| `<!-- decision-note -->` | `decide.sh note` | any other agent comment (the closing summary) |

A comment without a marker is the user's. It belongs to the decision it names: a first line `Decision D<k>:` (what a
client writes) or `D<k>:`, with a request or record `D<k>` earlier in the thread. Otherwise it belongs to the nearest
earlier marked comment, a note included: a reply to a note belongs to no decision and is ignored, by a client and by
`decide.sh` alike. Request and record footers tell the user to start a reply with `Decision D<k>:` to reach an older
decision. A client writes for the user, so it writes unmarked comments only.

## Request

| A client reads | Kept by |
|---|---|
| the first visible line that is no `###` heading is the question (visible: outside HTML comments and `<details>`) | the question stays a plain line; the heading `### Decision needed (D<k>)` carries only the id |
| a `Preview: <url>` line | unchanged |
| every `-`, `*` or `1.` list line before the first `---` is an option tile; the text before `:` is what an answer names (`Decision D1: B`) | one question: one `- A: …` line per option. Several: the legend uses `+` bullets (no tiles) and the one tile is `- ok: take every ★ option`. `decide.sh request` refuses list lines in the file's body |
| the first line containing "recommend" is the recommendation; its first word marks the recommended tile | one `Recommendation:` line (`B (footer bar)`, or `ok (1B 2A)`) |
| nothing below the first `---` | the answer template sits there |
| `<!-- choices <n> <Label>: A ★ (kw, today) · B (kw) -->`, one line per question: options split on ` · `, a letter `A`-`Z`, `★` on the recommended one, 1 to 3 keywords in brackets, `today` as a tag | `decide.sh request` writes one per question line; a request without them is one question from its list lines, and its answer is free text |
| `Options with screenshots: <link>` names the overview comment | written when the request links a round or options comment (`above in this comment` when it carries its own sections) |

## Round and options note

| A client reads | Kept by |
|---|---|
| `## <title>`, `Preview: <url>` | unchanged |
| `Variants: 1A, 1B, 2A` lists the things to pick, written back as `R<k>:` / `- pick: 1B, 2A` / `- reject: 1C` | `Variants:` lists the short forms; the answer reader takes picks and ignores rejects |
| `### <n>. <label>: <what it decides>` is a question; the line under a `###` heading is its summary | a blank line under every question heading |
| per question a table, one row per option: `\| A \| <name> (today) \| <in short> \|`, the recommended row `\| **B ★** \| … \|`, and a line `★ Why <letter>: …` | `decide.sh check` enforces the shape on every round and options note |
| image alt `R<k> · <n>. <label> · <what it shows>` puts a screenshot under its question | enforced by `decide.sh check`; images sit in their section, never in `<details>` |
| rounds written before the question format: `### <key>: <name>` variant headings, `Axis <name>: a, b (about)`, a closing `**Question:**` line, alt `R<k> · <variant> · <desktop\|mobile>` | read only; no skill writes them any more and `decide.sh check` refuses them |

## Look comment

`### Look: <headline>`, `Preview: <url>`, `Path: <route>`, a line `Check:` followed by a `- ` list, and screenshots with
alt `look · <desktop|mobile> · <state>`.

## Replies a client writes

All unmarked. Every reply to a decision starts `Decision D<k>: `; `decide.sh` strips the prefix and reads the rest.

| Reply | Read as |
|---|---|
| `Decision D1: ok` | every recommended option |
| `Decision D1: ok. 1A 3B` | the recommendations, except these |
| `Decision D1: 1B 2A` | those letters; a question left out reads `no answer` |
| `Decision D1: 1 Shell: C (top stepper) but calmer`, one line per further question | the letter counts, the brackets may be stale, text after them is a note |
| `Decision D1: B`, `Decision D1: B. wait for the review` | a request with one question |
| `Decision D<k>: <text>` on a record | a change request on that agent decision |
| `Approve: merge`, `Hold`, `Send back`, each optionally followed by `. <note>`, with the prefix when the pull request has a request | a pull-request verdict: passed on word for word, the coordinator acts on it |
| `R<k>:` then `- pick: 1B, 2A`, `- reject: 1C` (older rounds: `- pick <axis>: a`), a blank line, free text | a reaction to round `R<k>`: picks count, rejects do not |

A person may also type `ok`, `1B 2A`, a bare letter or the copied answer block without the prefix. Anything else is
free text and reaches the agent word for word.

## Issue body

A client matches the heading `^## UX decision` (the Design stage's result). The other `##` sections of the issue
standard ([reference/issue-rules.md](../reference/issue-rules.md)) are for readers.

## Labels

| Label | Meaning |
|---|---|
| `needs-design`, `needs-spec`, `ready` | lanes: the next step is Design, Specify, Build |
| `phase:design`, `phase:build` | the phase, next to the status (below) |
| `inbox` | an unsorted finding, not triaged yet |
| `needs-decision` | parked on a decision request |
| `agent-decided` | has agent decisions the user has not reviewed; never blocks |
| `ux-impact` | the result changes what the user sees: a Look comment follows |
| `on-hold` | set by the user or a client: no stage starts on the issue and its pull request is not merged, in every repository (`decide.sh resume` prints `held`, `merge-pr.sh prep` refuses) |
| `on-hold-after-spec`, `do-not-merge` | the default merge holds of `WF_HOLD_LABELS`; a repository may set its own list, `on-hold` always stays in it |
| `needs-direction` | fog: the direction is open and the user sets it. Set by `issue-status.sh fog`, removed when a stage starts; the lane label stays, and a client shows no next step |

<a id="phases"></a>

## Phases and statuses

A lane names the next step; the phase says whether work on it has started. Clients group issues by phase, read in this
order (first match wins):

| Phase | Rule | Set by |
|---|---|---|
| Done | issue closed | the merge (`Closes #n`) |
| Inbox | `inbox`, or open with no lane label (fog included) | filing, `/gh-inbox-dispatcher` |
| UX Design | status In progress with the lane `needs-design`, else `phase:design` | `/aw-ui-design` at its start (it also sets the lane `needs-design`); at the handover the status goes back to Backlog and the label is removed |
| Build | status In progress (any other lane) or In review, else `phase:build`, or an open PR with `Closes #n` | `/aw-specify` or `/aw-build` at its start (In progress), Build after `gh pr create` (In review); kept until close |
| Backlog | a lane label, no started status and no `phase:*` | triage, the Design handover |

The **status** is GitHub's native issue status. `bin/issue-status.sh` writes `In progress`, `In review` and `Backlog`
by name, next to the phase label, best effort: a repo without statuses, or a call that fails, leaves the label as the
only signal, and a status of Backlog, Todo or none says nothing about the phase. `Todo` means "handed to an agent, not
started yet" and is written by the client that hands over, never here. `WF_PHASE_LABELS=off` stops the `phase:*` label
writes once every client reads the status (the cut-over); the labels already on issues stay until then.

## Coordination log

Agent-to-agent progress, outside the work tree, written by `decide.sh log` and deleted by `merge-pr.sh after`:

- path: `${WF_ISSUE_LOG_DIR:-~/.claude/issue-logs}/<owner>/<repo>/<n>.md`. A client reads `WF_ISSUE_LOG_DIR` from its
  environment only, so set it there (not only in a settings file) when it differs from the default.
- first line `# Coordination log #<n> (<owner>/<repo>)`, a blank line, then one line per entry:
  `- <YYYY-MM-DDTHH:MMZ> <text>` (UTC, the text on one line).

## Push and launch

| What | String |
|---|---|
| a client tells a running coordinator that feedback arrived or an issue should start | `orca orchestration send --to run:<id> --type status --subject "tandem push: <owner/repo>#<n> <feedback\|start>"`, to the newest Run whose coordinator is live in that repo |
| no Run: the client launches a coordinator | the prompt `/aw-coordinate #<n> …` (one `#<n>` per issue) |
| skills a client may show or launch | `/aw-coordinate`, `/aw-ui-design`, `/aw-specify`, `/aw-build` (all skills carry the prefix `aw-`) |
