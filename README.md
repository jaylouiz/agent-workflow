# agent-workflow

Claude Code skills that take a GitHub issue from rough idea to merged PR, with UX design and tech specification as separate, optional stages. The skills hold the method; each project fills in its facts in a tracked **profile** file.

This is the author's working setup, published as is: opinionated, built around Claude Code, GitHub issues and [Orca](https://github.com/stablyai/orca) workers, and used daily on a few personal projects. Take what fits.

## Quickstart

```sh
git clone https://github.com/jaylouiz/agent-workflow.git
bash agent-workflow/install.sh       # checks the requirements, asks two questions, links the skills
cd <your repo> && claude             # then: /aw-setup
```

`/aw-setup` reads the repo (scripts, CI checks, UI or not, docs), drafts the project's profile and config, asks only what it could not tell, creates the labels and opens a PR with the setup. Then take an issue through it: `/aw-specify <n>` or `/aw-build <n>` for a clear one, `/aw-ui-design <n>` when the UX is open, `/aw-orchestrate <issues>` for several at once with Orca. Rerun `/aw-setup update` when the project changes.

## Requirements

- [Claude Code](https://claude.com/claude-code), [`gh`](https://cli.github.com) logged in, `git`, `bash` (3.2 is enough), `jq`, `python3`. macOS is the tested platform. `install.sh --check` checks them and changes nothing.
- [Orca](https://github.com/stablyai/orca) and its `orca` CLI for `/aw-orchestrate` (workers, messages). The single-issue skills (`/aw-ui-design`, `/aw-specify`, `/aw-build`) run without it.
- Skills and plugins the skills call but this repo does not ship: `/code-review` (Claude Code), and optionally `/gh-inbox-dispatcher`, `/ui-canvas`, `harvesting-session-knowledge` and the Impeccable plugin. A step whose tool is missing is skipped or reported, not guessed.

## Install

`install.sh` links every `skills/*` into `~/.claude/skills/` and this checkout to `~/.claude/agent-workflow` (the skills read `reference/` and run the shared scripts in `bin/` through it). Every skill starts with `aw-`: type `/aw-` to list them. `CLAUDE_CONFIG_DIR` is not supported: hooks and paths assume `~/.claude`, and `install.sh` (also `--check`) warns when it points elsewhere. The script paths from before the rename keep working for one release through [compat/](compat/README.md). In a terminal it asks two things and records the answers in `~/.claude/agent-workflow-settings.sh`:

- **Models**: one per tier, default / strong / fast / heavy (what each runs: [Settings](#settings)), each a Claude Code alias or a full model ID; Enter keeps the value shown (the one you set before, else the shipped `sonnet` / `opus` / `haiku` / `claude-fable-5-2`). No Fable access: answer `opus` for heavy. Without prompts: `--models balanced` (the shipped values), `quality` (opus / opus / sonnet / claude-fable-5-2) or `budget` (sonnet / sonnet / haiku / opus), and `--model-default|strong|fast|heavy <id>` per tier over the preset.
- **Global rules**: the author's [global/CLAUDE.md](global/CLAUDE.md) (inbox issues for side findings, the user's direction first for vague goals, the friction ledger and retro, screening several issues first, committing without asking). Off by default. On: linked as `~/.claude/CLAUDE.md`, or, when you have your own, one import line `@~/.claude/agent-workflow/global/CLAUDE.md` appended to it (a timestamped backup is kept).

Rerun it after `git pull` or after adding, renaming or removing a skill: without a terminal (or with `--yes`) it keeps every recorded choice. It never overwrites a real file where a link belongs. A rerun never changes a tier you set unless you answer or flag a new value. Flags: `--yes`, `--models <preset>`, `--model-<tier> <id>`, `--global-rules` / `--no-global-rules`, `--check`, `--uninstall` (removes the links and the global rules, keeps the settings file). Edit skills in this repo only.

Maintainer only: `--dev` also links `/aw-orca-review`, which the maintainer runs by hand after an Orca update: it reviews the new version against this workflow (`skills/aw-orca-review/snapshot/version`) and asks before it changes anything. Users get the result through `git pull`.

Per project without the skill: copy [reference/project-profile.md](reference/project-profile.md) to `<project>/.claude/issue-workflow.md` and [reference/project-config.sh](reference/project-config.sh) to `<project>/.claude/issue-workflow.sh`, fill them in and commit them.

Cloud sessions (Claude Code on the web) do not get these skills (only the attached repo, no `gh issue`/`gh pr`, no plugins); what works there lives in each project's `CLAUDE.md`.

## Settings

Choices that differ per person or project live in two sourced bash files, read in this order (later wins): built-in defaults, the global `~/.claude/agent-workflow-settings.sh` (template [reference/global-settings.sh](reference/global-settings.sh)), the repo's `.claude/issue-workflow.sh` (template [reference/project-config.sh](reference/project-config.sh)). Any setting may go in either file. `bash ~/.claude/agent-workflow/bin/settings.sh show` prints every value with its source; `settings.sh get <NAME>` one value.

| Setting | Default | Usually set | What it does |
|---|---|---|---|
| `WF_MODEL_DEFAULT` | `sonnet` | global | normal lead, design and fix workers; Design's tech check; the retro agent |
| `WF_MODEL_STRONG` | `opus` | global | coordinators, reviewer and delta-review workers, the one root-cause subagent of a stuck lead |
| `WF_MODEL_FAST` | `haiku` | global | mechanical subagents (`rg` audits, copy sweeps) |
| `WF_MODEL_HEAVY` | `claude-fable-5-2` | global | lead and design workers for a new feature, a bigger UI change or complex technical work |
| `WF_MAX_WORKERS` | `3` | global or repo | concurrent Orca workers in a Run |
| `WF_DIGEST_CAP` | `2h` | global or repo | how long the oldest unannounced decision request waits for the digest |
| `WF_COMMENT_CAP` | `1500` | global | visible characters per agent issue comment |
| `WF_ISSUE_LOG_DIR` | `~/.claude/issue-logs` | global | per-issue coordination logs |
| `WF_NO_WAIT_CI` | `0` | global or repo | `1`: merge prep does not wait for pending checks |
| `WF_PHASE_LABELS` | `on` | global or repo | `off`: the skills stop writing `phase:design` / `phase:build`; GitHub's issue status carries the phase alone |
| `WF_PR_ATTRIBUTION` | `on` | global or repo | `off`: the guard hook no longer requires the "Generated with [Claude Code]" line in a PR body |
| `WF_PORTS`, `WF_PROTO_PORTS`, `WF_RISK_GLOBS`, `WF_IGNORE_GLOBS`, `WF_REVIEW_LINES`, `WF_HOLD_LABELS`, `WF_REQUIRED_CHECKS`, `WF_CHECKS_TSV`, `wf_*` functions | see the template | repo | ports, review routing, holds, CI gate, verify / build / after-merge steps |

The model tiers are written by `install.sh`; a repo may override one in its `.claude/issue-workflow.sh` (e.g. `WF_MODEL_HEAVY=opus`). `WF_COMMENT_CAP` and `WF_ISSUE_LOG_DIR` may also come from the environment, which wins. Fixed on purpose: label names and colours (clients such as Tandem read them), the retro thresholds and the CI wait windows.

## Vocabulary

**Two tracks.** **Discovery** decides *what* to build and *how it should work for the user*: cheap, throwaway artefacts, user in the loop. **Delivery** builds it right: production code, tests, review, merge.

**Stages.** Each is optional except Build; an issue enters at the first stage it needs.

| Stage | Track | Question | Skill | Output |
|---|---|---|---|---|
| Chart | Discovery | Which problem, which outcome? Too big for one session. | the user, by any method (no skill here) | a direction the stages can take |
| Design | Discovery | How should it look and behave for the user? | `/aw-ui-design` | UX decision, user stories, UACs |
| Specify | Delivery | How do we build it, how do we know it is done? | `/aw-specify` | Spec (approach, technical ACs, verification) |
| Build | Delivery | | `/aw-build` | PR |
| Review, Merge | Delivery | Is it correct, can it ship? | `/code-review`, `/aw-orchestrate` | merged PR |

"Design" always means UX design here. Tech design is part of Specify.

**Lanes** are labels that say where an issue waits: `needs-design` → `needs-spec` → `ready`. Hold labels (e.g. `on-hold-after-spec`) stop the pipeline after a stage. A lane names the **next step**; the **phase** says whether work on it has started. Clients such as [Tandem](https://github.com/jaylouiz/tandem) group issues by phase, read in this order (first match wins):

| Phase | Rule | Set by |
|---|---|---|
| Done | issue closed | the merge (`Closes #n`) |
| Inbox | `inbox`, or open with no lane label (fog included) | filing, `/gh-inbox-dispatcher` |
| UX Design | status In progress with the lane `needs-design`, else `phase:design` | `/aw-ui-design` at its start (it also sets the lane `needs-design`); at the handover the status goes back to Backlog and the label is removed |
| Build | status In progress (any other lane) or In review, else `phase:build`, or an open PR with `Closes #n` | `/aw-specify` or `/aw-build` at its start (In progress), Build after `gh pr create` (In review); kept until close |
| Backlog | a lane label, no started status and no `phase:*` | triage, the Design handover |

The **status** is GitHub's native issue status (Backlog, Todo, In progress, In review, Done, …), written by `bin/issue-status.sh` next to the phase label, best effort: a repo without statuses, or a call that fails, leaves the label as the only signal, and a status of Backlog, Todo or none says nothing about the phase. Todo means "handed to an agent, not started yet" and is written by the client that hands over (Tandem), never here. `WF_PHASE_LABELS=off` stops the `phase:*` label writes once every client reads the status (the cut-over); the labels already on issues stay until then.

`ux-impact` marks an issue whose result the user should look at after Done (set in Design's handover and by Build for UI changes); its **Look comment** says where.

| Term | Meaning |
|---|---|
| Triage | Giving an issue its entry lane by the triage rule ([reference/issue-rules.md](reference/issue-rules.md)). |
| Brief | The UX problem statement at the start of Design: job, users, states, constraints, what to keep. |
| Variant | One structurally different answer to the design question (layout, hierarchy, primary affordance). Colour or copy tweaks are not variants. |
| Tech check | Read-only cost and risk rating of the variants during Design. Not a spec. |
| Prototype | Throwaway coded variants inside the real app, switched by `?variant=` and a switcher bar. Lives on a proto branch `proto/<n>-<slug>`, never merged. |
| Sketch | Canvas frames via `/ui-canvas`, when code is too costly or too risky. |
| Round | One cycle of show (screenshots, preview URL) → feedback → revise. Its comment is the overview of the decision: one section per question with an option table and the screenshot under it. |
| UX decision | The `## UX decision` section of the issue body. Ends Design. |
| Job | What the user needs to get done, verb + object, solution-neutral ("Plan the day"); a short list in the profile's "Jobs". Adding one is the user's call. |
| User story | `As <who>, when <situation>, I want <what>, so that <outcome>`: the level under a job where concrete behaviour lives. |
| UAC | User acceptance criterion: behaviour the user can observe. Layers and owners: [reference/issue-rules.md](reference/issue-rules.md). |
| Spec | The issue body after Specify: the issue standard's layers plus approach, technical ACs, implementation notes, verification. The only input Build needs. |
| Profile | The project's tracked file with the facts these skills leave open (`.claude/issue-workflow.md`), written by `/aw-setup`. |
| Ledger | One line per friction, written the moment it happens (`aw-retro/ledger.sh`, global CLAUDE.md); outside the work tree, archived by the retro (`ledger.sh close`). |
| Retro | `/aw-retro` at the end of a run or session: ledgers → causes → the cheapest fix, plus a convergence pass when the instructions grow. |
| One-way / two-way decision | One-way: costly to undo or the user's call by definition (Design round, held merge, the profile's "Decisions" list); only these reach the user. Two-way: everything else; the agent decides, records it and continues. |
| Coordination log | Per-issue Markdown file for agent-to-agent progress (stage starts, milestones, PR link, fix rounds, resume text): `decide.sh log`, at `~/.claude/issue-logs/<owner>/<repo>/<n>.md`, outside the work tree; deleted by `merge-pr.sh after`. The issue thread keeps only what the user reads. |
| Look comment | Build's marked comment (`<!-- decision-note look -->`) on a `ux-impact` issue: preview URL seeded to show the change, `Path:` for production, final screenshots, what to check. |
| Comment markers | Every agent comment starts with `<!-- decision-<kind> … -->` so it never reads as the user's. A comment without a marker is the user's and belongs to the decision it names (a first line `Decision D<k>:`, which is what Tandem writes, or `D<k>:`, with a request or record `D<k>` earlier in the thread), else to the nearest earlier marked comment (a note included: a reply to a note belongs to no decision and is ignored, in Tandem and in `decide.sh` alike). Request and record footers tell the user to start a reply with `D<k>:` to reach an older decision. Decision kinds carry an id (`request D<k>`, `record`, `answer`, `resolved`, `followup`); note kinds are typed for clients: `note round R<k>` (design round; screenshot alt `R<k> · <variant> · <desktop\|mobile>`), `note options` (Specify approaches), `note look`, plain `note` (summary). |
| Comment cap | Every agent comment stays scannable: at most 1500 visible characters, no line over 400; detail goes into `<details>` (`decide.sh check`, enforced by the guard hook). |
| Decision request | A one-way question as a marked issue comment (`decide.sh request`) plus label `needs-decision`: numbered questions, lettered options (`★` = recommended), a link to the overview that explains them and a prefilled answer to copy. The user answers in a comment, any time: `ok`, the copied block, `1B 2A` or free text. Format: [docs/decision-format.md](docs/decision-format.md). |
| Parked | An issue waiting on a decision request. Its worker has ended; a fresh one resumes after the answer. |
| Agent decision | A two-way decision recorded in the body's `## Decisions` and a marked comment, label `agent-decided`. Never blocks; removing the label accepts it, a comment asks for a change. |
| Push | [Tandem](https://github.com/jaylouiz/tandem) telling the coordinator that Feedback arrived or a Card should start: `orca orchestration send --to run:<id> --type status --subject "tandem push: <owner/repo>#<n> <feedback\|start>"` to the newest Run whose coordinator terminal is live in that repo; with no Run it launches `/aw-orchestrate #<n>`. The coordinator handles it in its message read (orchestrate section 6). |
| Digest | The coordinator's one bundled ping of all open decision requests: when the run goes idle, or when the oldest unannounced one passes `WF_DIGEST_CAP`. |
| Running log | The project's committed watch list of recurring causes and the context-size history (path in the profile's "Retro"). Never loaded into a session. |

## Issue standard and triage rule

What an issue holds at each stage (`## Problem` solution-free, `## Solution` sharpened per stage, job, user stories, UACs) and how it gets its lane (fog, `needs-design`, `needs-spec`, `ready`): [reference/issue-rules.md](reference/issue-rules.md), the file the skills load.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/lanes-dark.png">
  <img src="docs/diagrams/lanes.png" width="960" alt="Issue lanes: triage routes an issue to needs-design (open UX), needs-spec (open build) or ready (issue standard met). /aw-ui-design leads to needs-spec, or to ready when the standard is met; /aw-specify leads to ready; /aw-build opens a PR, which is reviewed and merged. Fog at any point gets no lane: the user sets the direction.">
</picture>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/issue-standard-dark.png">
  <img src="docs/diagrams/issue-standard.png" width="960" alt="Issue standard, layer by layer: a title-only issue gets Problem &amp; job and a rough Solution from the first stage that runs; /aw-ui-design adds user stories and UACs; /aw-specify adds the technical layer (approach, technical ACs, verification). Specify without Design adds user stories, UACs and technical ACs in one step.">
</picture>

Diagram sources: `docs/diagrams/render.py` (writes the HTML; rasterize with the diagram-design skill's `export_png.py`).

## Generic vs project

- **Skill**: a method, a step order, a tool-agnostic rule.
- **Profile** (or the project's `CLAUDE.md`): anything that names the project's files, commands, labels, URLs, tools, invariants or quirks. Facts already in `CLAUDE.md` are referenced from the profile, not copied.

When a skill says "the profile's X", read that section of `.claude/issue-workflow.md`. A missing section means the step does not apply to this project; say so in the report instead of guessing. A repo without a profile works the same way (every section missing); the skills point to `/aw-setup` once.

## Background

Separating discovery from delivery follows Marty Cagan's dual-track product work; bounded, rough shaping before building follows Basecamp's *Shape Up*; disposable prototypes follow Brooks ("plan to throw one away"). Scaling ceremony to risk (a small issue goes straight to `ready`) follows Birgitta Böckeler's critique of heavy spec-driven tooling on martinfowler.com, and Anthropic's *Building effective agents* advice to prefer simple, explicit workflows.

## History and license

This repository starts with a single public commit; issue and PR numbers up to #49 in skills, docs and comments refer to the author's private archive of the earlier history.

MIT, see [LICENSE](LICENSE). Third-party material: [NOTICE](NOTICE).
