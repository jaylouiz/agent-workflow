# Issue rules

Loaded by every stage skill (`/design-gh-issue`, `/specify-gh-issue`, `/build-gh-issue`, `/orchestrate-gh-issues`, `/gh-inbox-dispatcher`). The human overview with vocabulary and the lane diagram is the [README](../README.md).

## Issue standard

An issue body has two main parts: **`## Problem`** (why: stays solution-free) and **`## Solution`** (what: rough at first, sharpened by every stage). The detail sections each stage adds (`## UX decision`, `## User stories`, `## Acceptance criteria`, …) follow `## Solution` and belong to it; they stay `##` headings because clients match them (Tandem: `^## UX decision`). An issue filed with only a title is normal: the first stage that runs completes what is missing.

| Layer | Content | Due before | Completed by |
|---|---|---|---|
| Problem & job | `## Problem`: who, in what situation, what is wrong or missing (or which delight is missing), and why it matters; `Job: <id> <job>` from the profile's "Jobs" (or `new job: …` as a proposal for the user). No solution: anything solution-like from the request (an idea, a mechanism, a rule, a trigger) goes to Solution. The request's motive goes to Problem when it states a need ("I want to move faster"), to Solution when it states a mechanism ("rewards keep me productive") | any stage starts | the first stage that runs (Design or Specify), in its guard |
| Solution | `## Solution`: 2-5 lines on the current shape of the answer. Starts as the request's own idea (or `open`), rewritten at each stage's end to match its detail sections | any stage starts | each stage, at its end |
| User stories | one or more, under `## User stories` (Design: the `**Stories:**` line of the UX decision) | Design ends | Design; Specify when Design is skipped |
| UACs | `## Acceptance criteria` › User: observable behaviour, one line per state | Design ends | Design's handover; Specify when Design is skipped |
| Technical | approach, technical ACs, implementation notes, verification | Build | Specify |

- **Infer, then record.** A missing layer is inferred from the codebase, the profile's "Sources" and "Jobs", related and closed issues and the design backlog. Each inferred item is marked `(inferred)`; one bundled `agent-decided` record per stage lists them all (two-way, never blocks). If even the problem cannot be named from context, it is fog.
- **Tech-only** (refactor, infra, tooling, no user-visible change): Problem = what hurts technically and why it matters; `Job:` the job it protects, or `none (tech-only)`; no stories; UACs = "user-visible behaviour unchanged" plus measurable checks.
- **Bugs**: the job the bug breaks; the story may be the broken expectation; UACs = the correct behaviour plus a regression check.
- **Who writes**: only stage workers (Design, Specify, a lead). Triage, the coordinator and `/gh-inbox-dispatcher` never write layers; they route an incomplete issue to `needs-spec` (or `needs-design`) and may tell its worker to complete it.
- Existing issues are not retrofitted; the standard applies when a stage next touches an issue.

## Triage rule

Applied by `/gh-inbox-dispatcher`, orchestrator screening, each skill's guard, or the user.

- **Fog** (the problem or outcome is unclear even with full context, many directions, more than one session): no lane. Comment and tell the user to run `/wayfinder <n>`. Agents never start it.
- **`needs-design`** (open direction): the how for the user is unclear and getting it wrong is expensive: a new surface, a new interaction, a changed flow, several plausible layouts. Pure visual polish is not Design; it is a look choice inside Build.
- **`needs-spec`** (open build or incomplete issue): UX is clear (or the issue is not UI), but the build has open tech choices, touches the profile's risk areas, or the issue standard is not complete yet (Specify's Complete track fills it).
- **`ready`**: the outcome is clear, the build is a standard pattern, and the body already meets the issue standard. Triage never writes it into shape. Build stops and asks when something important turns out unclear.
