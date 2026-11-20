# Decision format

How an agent asks the user to decide on a GitHub issue, and how the answer is read. Built and enforced by
`skills/orchestrate-gh-issues/decide.sh` (logic in `decision_format.py`, tests in `test-decide.sh`).

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
D1
1 Shell: B (footer bar)
2 Heading: A (hidden)
```
Or reply `ok` to take every recommendation. Text after a letter is read as a note. Short form: `D1: 1B 2A`. The run picks it up at its next checkpoint.
````

A request with one question lists its options one per line instead (`- A: merge now ★`, `- B: hold (today)`,
then `Recommendation: A (merge now)`).

## Answers

Read by `decide.sh status` (a second line `reads as: …` under the answered row) and `decide.sh resolve` (prints the
resume text and writes it into the "Resumed" comment and the coordination log):

| Form | Example | Read as |
|---|---|---|
| ok | `ok`, `D1: all recommended` | every recommended option |
| block | the copied block; `1 Shell: C (footer bar) but calmer` | question 1 = C, note "but calmer". The brackets may be stale, the letter counts |
| short | `1B 2A`, `D1: ok. 1A` | those letters; with `ok`, the rest is the recommendation, without it the rest is `no answer` |
| letter | `B`, `B. wait for the review` | one-question requests only |
| free text | anything else | passed on word for word, as before |

The resume text spells the choices out: `1 Shell: C (top stepper), note: but calmer · 2 Heading: A (hidden)`.
A request without `<!-- choices -->` lines (posted before this format) is never parsed: its answer is free text.

## Tandem

Tandem (the user's board) reads these comments with its own parser (`src/core/contract.ts`). What it depends on,
and how the format keeps it:

| Tandem reads | Kept by |
|---|---|
| markers `decision-request D<k>`, `-answer`, `-resolved`, `-record`, `-followup`, `-note round R<k>` / `options` / `look` | unchanged; the `choices` comments use another prefix |
| request: the first visible line that is no `###` heading is the question | the question stays a plain line; the heading carries only the id |
| request: `Preview:` line | unchanged |
| request: every `-`, `*` or `1.` list line before the first `---` is an option tile; the text before `:` is what a click sends (`D1: B`) | one question: one `- A: …` line per option. Several: the legend uses `+` bullets (no tiles) and the one tile is `- ok: …`. `decide.sh request` refuses list lines in the file's body |
| request: the first line containing "recommend" is the recommendation; its first word marks the recommended tile | one `Recommendation:` line (`B (footer bar)`, or `ok (1B 2A)`); the answer template sits below the `---`, where Tandem stops reading |
| round: `Variants:` keys are the things to pick, written back as `R1:` / `- pick: 1B, 2A` / `- reject: 1C` | `Variants:` lists the short forms; the answer reader takes picks and ignores rejects |
| round: `### <key>: <name>` headings are also listed, the next line is the summary; images group by alt `R<k> · <key> · <desktop\|mobile>` | question headings `### 1. Shell: …` with a blank line under them; alt `R1 · 1. Shell · …` puts the image under its question |
| answers it writes: `D1: <key>. <note>` | read as letter, `ok` or short form, see above |
| issue body: `^## UX decision` | unchanged |

`test-decide.sh` pins these lines with a copy of Tandem's request rules (`tandem()`).

## Where it lives

| File | What |
|---|---|
| `skills/orchestrate-gh-issues/decision_format.py` | builds the request, checks the overview, reads answers |
| `skills/orchestrate-gh-issues/decide.sh` | `request` (builds from question lines), `check` (cap plus overview shape), `status` (`reads as`), `resolve` (resume text), `digest` (answer hint) |
| `skills/orchestrate-gh-issues/SKILL.md` section 5, `task-template.md` | how to write a request, what to quote to the resumed worker |
| `skills/design-gh-issue/SKILL.md` sections 1, 3, 7 | round comment template: questions instead of variants and axes |
| `skills/specify-gh-issue/SKILL.md` section 5 | options comment uses the overview shape |
