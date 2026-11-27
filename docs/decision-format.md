# Decision format

How an agent asks the user to decide on a GitHub issue, and how the answer is read. Built and enforced by
`bin/decide.sh` (logic in `decision_format.py`, tests in `test-decide.sh`).

- A decision has **questions** numbered `1`, `2`, … Each has **options** lettered `A`, `B`, `C` …
- The same letters are used in the text, on the images and in the prototype's switcher.
- Today's state is an ordinary option tagged `(today)`. The recommended option carries `★`.
- Each option is described once, in the **overview**. The **request** links to it and only asks for the reply.

## Overview

The design round comment (`<!-- decision-note round R<k> -->`), Specify's options comment
(`<!-- decision-note options -->`), or, for a request without either, the request file itself.
One `###` section per question; a decision with one question has one section.

```markdown
<!-- decision-note round R1 -->
## Design round 1: Setup shell
Preview: https://preview.example/setup?variant=1A
Variants: 1A, 1B, 1C, 2A, 2B
One sheet for Notion and Reminders. Open: where back sits, and the step heading.

### 1. Shell: where back and next sit

| | Option | In short |
|---|---|---|
| A | Rail, back on top (today) | back above, one button below |
| **B ★** | Rail, footer bar | Zurück left, Weiter right |
| C | Top stepper | no rail, same form at every width |

★ Why B: back and main action sit together, like in dialogs.

![R1 · 1. Shell · A, B, C at 1280 and 390](shell.png)

### 2. Heading: the step heading in the pane

| | Option | In short |
|---|---|---|
| **A ★** | Hidden | the rail names the step |
| B | Small, visible | heading with the step's action |

★ Why A: say it once.

![R1 · 2. Heading · A, B at 1280 and 390](heading.png)

<details><summary>Stories, checks, build cost, dropped</summary>

Job: … · Stories: …
Checks: …
Per option: 1A: … · M
Dropped: three shells (contradicts #562)
</details>
```

`decide.sh check` (run by the guard hook on every issue comment) refuses a round or options note unless:

- every `###` heading is `### <n>. <label>: <what it decides>`, numbered in order, with a blank line under it
- each section has a table with one row per option, lettered in order, exactly one `★` row, and a `★ Why <letter>:` line
- every image sits in a question section, open, never in `<details>` and never before the first section
- there is at most one `<details>` block and nothing follows it
- there is no `Question:` line
- a round has `Variants: 1A, 1B, …` (all options in short form) and image alts `R<k> · <n>. <label> · <what it shows>`

## Request

`decide.sh request <n> <file>` writes the comment from a short file:

```
Setup shell: 2 choices
Preview: https://preview.example/setup?variant=1A
Overview: https://github.com/owner/repo/issues/607#issuecomment-1
1 Shell: A (back on top, today) · B ★ (footer bar) · C (top stepper)
2 Heading: A ★ (hidden) · B (small, visible)
```

Line 1 is the question. Each question line names its options with 1 to 3 keywords in brackets (`today` is a tag and
does not count). Without `Overview:` the overview sections go into the same file, below these lines. A question with
nothing to pick from uses `Open question: <what kind of answer>` instead of question lines. The posted comment:

````markdown
<!-- decision-request D1 -->
<!-- choices 1 Shell: A (back on top, today) · B ★ (footer bar) · C (top stepper) -->
<!-- choices 2 Heading: A ★ (hidden) · B (small, visible) -->
### Decision needed (D1)
Setup shell: 2 choices
Preview: https://preview.example/setup?variant=1A
Options with screenshots: https://github.com/owner/repo/issues/607#issuecomment-1

+ **1 Shell:** A (back on top, today) · **B ★ (footer bar)** · C (top stepper)
+ **2 Heading:** **A ★ (hidden)** · B (small, visible)

- ok: take every ★ option

Recommendation: ok (1B 2A)

---
Copy, change only the letters you disagree with, post as a comment:
```
Decision D1:
1 Shell: B (footer bar)
2 Heading: A (hidden)
```
Or reply `ok` to take every recommendation. Text after a letter is read as a note. Short form: `Decision D1: 1B 2A`. The run picks it up at its next checkpoint.
````

A request with one question lists its options one per line instead (`- A: merge now ★`, `- B: hold (today)`,
then `Recommendation: A (merge now)`).

## Answers

Read by `decide.sh status` (a second line `reads as: …` under the answered row) and `decide.sh resolve` (prints the
resume text and writes it into the "Resumed" comment and the coordination log):

| Form | Example | Read as |
|---|---|---|
| ok | `ok`, `Decision D1: ok`, `D1: all recommended` | every recommended option |
| block | the copied block; `1 Shell: C (footer bar) but calmer` | question 1 = C, note "but calmer". The brackets may be stale, the letter counts |
| short | `1B 2A`, `Decision D1: ok. 1A` | those letters; with `ok`, the rest is the recommendation, without it the rest is `no answer` |
| letter | `B`, `B. wait for the review` | one-question requests only |
| free text | anything else | passed on word for word, as before |

A reply may start with the decision it answers: `Decision D1:` (what Tandem writes and what the request's template shows) or
`D1:`. With a request or record of that id earlier in the thread the reply belongs to that decision, also when a later one is
open; the prefix is not part of the answer. A design round's `R1:` reaction is read as before.

The resume text spells the choices out: `1 Shell: C (top stepper), note: but calmer · 2 Heading: A (hidden)`.
A request without `<!-- choices -->` lines (posted before this format) is never parsed: its answer is free text.

## Board clients

A board client (Tandem is the reference client) reads these comments with its own parser and writes the user's replies.
What it depends on, string by string, is the [board client contract](contract.md): markers, the request rules, round and
look shapes, the replies it writes, labels, statuses, the coordination log, push and launch. `test-decide.sh` pins it with
the golden fixtures in `docs/contract-fixtures/` and a reference reader (`bin/contract_reader.py`). The example under
"Overview" above is the round fixture: changing it changes `round.md` there.

## Where it lives

| File | What |
|---|---|
| `bin/decision_format.py` | builds the request, checks the overview, reads answers |
| `docs/contract.md`, `docs/contract-fixtures/`, `bin/contract_reader.py` | what a board client reads and writes, the golden fixtures and the reference reader |
| `bin/decide.sh` | `request` (builds from question lines), `check` (cap plus overview shape), `status` (`reads as`), `resolve` (resume text), `resume` (a stage's Resume step: `none`, `waiting` or the resume text), `digest` (answer hint) |
| `reference/decisions.md` | one-way or two-way, how to write a request and a record, parking and the Resume step |
| `reference/coordination.md` ("Decisions and the user"), `skills/aw-coordinate/task-template.md` | the coordinator's sweep and digest, what to quote to the resumed worker |
| `skills/aw-ui-design/SKILL.md` sections 1, 3, 7 | round comment template: questions instead of variants and axes |
| `skills/aw-specify/SKILL.md` section 5 | options comment uses the overview shape |
