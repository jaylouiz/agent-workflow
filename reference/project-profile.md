# issue-workflow profile: <project>

<!-- profile-template: 1 -->

<!-- Read by the agent-workflow skills; /aw-setup writes and updates it. Project facts only (README
     "Generic vs project"): reference CLAUDE.md instead of copying it; delete a section that does not apply (a missing
     section means the step does not apply). A "ui" tag comment under a heading marks a section only a project with a
     UI needs, "orca" one only Orca orchestration needs. Settings (models, max workers, digest cap): settings.sh show.

     Template version: the `profile-template` line above; /aw-setup update bumps it. `settings.sh show` and
     `settings.sh profile` print one line when a profile has an older version or none.
     Budget: warn above 15 KB, limit 20 KB (`settings.sh profile` prints the section sizes). Over the budget, split.
     Partials: every `##` heading stays; a section over about 3 KB shrinks to one line,
     `Full text: .claude/issue-workflow/<slug>.md (read when: <stage/step>)`. The skills say "the profile's X" and follow
     the pointer only when the step needs it. Which stage reads which section: reference/stage-sections.md.
     Routing a project lesson: about files -> path-scoped `.claude/rules/` (`paths:`); about a workflow step -> this profile. -->

## Labels

- lanes: needs-design → needs-spec → ready
- hold: <e.g. on-hold-after-spec = stop after Specify>
- context labels triage may add: <e.g. new-feature, polish, a11y>

## Sources

- product: <PRODUCT.md, vision doc>
- design system: <DESIGN.md, token files>
- design backlog / audits: <paths, and how an issue names an entry>

## Jobs

<!-- The user's main jobs that every issue names (README "Issue standard"). -->
- list: <path and section, e.g. PRODUCT.md "Jobs to be done", with the IDs>

## Risk areas

<paths and concepts where changes are expensive or fragile; drives the tech check and model tiers>

## Branches

- name: <type>/<n>-<slug>, types fix|feat|test|docs|chore
- worktree notes: <dependency symlinks, setup quirks>

## Verification

- gate command: <e.g. npm run verify>
- tests: <unit, E2E rules, visual baselines, ports>
- repeat-run command: <how to run one timing or flake test `<n>` times without retries, e.g. `npx playwright test <spec> --repeat-each=<n> --retries=0 --workers=4`; the skills ask for 10 runs for a new timing test, 30 for a flake proof>
- extra greps: <checks that caught real misses before>

## Pull requests

- screenshots: <how to embed without committing images>
- required in body: <ACs with evidence, review scores, …>

## Decisions

- one-way (ask the user; everything else the agent decides and records): <list; default: the list in `~/.claude/agent-workflow/reference/decisions.md`>
- explicitly two-way: <calls the user trusts agents with, e.g. internal structure, data shape changes with migration>

## Design quality
<!-- ui -->

<!-- Which tool fills each slot. Commands as the agent types them. -->
- brief: <command that produces a confirmed UX brief>
- current-state review: <critique / audit commands for an existing surface>
- variant lenses: <commands or checklists that push variants apart>
- element look: <tool that hot-swaps element variants in the running app, if any>
- build: <how UI is built, refinement verbs>
- gate: <before/after review that must pass before a PR>
- polish / detector: <final pass and static detector command>
- design records: <how pattern extraction and design-doc updates happen>

## Components
<!-- ui -->

<how to look up component APIs; never guess props>

## Pattern check
<!-- ui -->

<!-- Optional. Before a UI element is created or changed, the agent finds the existing recurring solution to the same user job and decides reuse / align / diverge alone. -->
- rule: <always-on, path-scoped rule file that holds the procedure, so ad-hoc edits are covered too>
- record: <one line per decision and its grammar; where it goes (PR body for lane work, final report for ad-hoc work)>
- gate: <PR-body check in `wf_pr_body_check`, if any>

## Design feedback
<!-- ui -->

<!-- Optional. A design reason from the user ("because...") builds the design framework only through a proposal the user adopts. -->
- channels: <chat, PR/issue comments, prototype comments, canvas threads, diverge reasons>
- flow: <challenge the reason against convention, product principles and the design system; one verdict; propose; unattended runs file a candidate issue>
- writes: <nothing is written before the user's explicit yes>

## Copy
<!-- ui -->

<!-- Optional. UI copy as its own step: Design decides what text goes where and why (a copy inventory), a copy pass in a fresh context writes the final wording once structure and look are decided. -->
- draft rules: <the few rules prototype copy follows; real draft wording, never lorem ipsum>
- copy inventory: <what Design records per text element: where, purpose, or `convention`>
- copy pass: <skill or procedure that turns the inventory into the `### UI copy` table; rules and vocabulary files>
- Build: <implement the table verbatim; without a table, run the copy pass before the PR>

## Screenshots
<!-- ui -->

- tool: <browser automation skill or command>
- widths: <e.g. 1280 and 390>; themes: <light only | light and dark>
- entry URL: <dev URL with seeded data>

## Prototype
<!-- ui -->

- host: <dev command, URL with seed data, how variants mount>
- switcher: <component path, created on the first proto branch>
- branch: proto/<n>-<slug>, own worktree, never merged
- relaxed: <which hooks or lint rules skip proto branches>
- share: <preview deploys for proto branches, if any>
- data: <local or stub data only>

## Canvas
<!-- ui -->

<canvas skill and its profile path, or "none">

## Orchestration
<!-- orca -->

- runner: <Orca or other>; max workers come from `WF_MAX_WORKERS` (settings): note here only why this repo differs
- executable facts (ports, risk globs, verify, after-merge, deploy check, PR-body check): `.claude/issue-workflow.sh` (template `reference/project-config.sh`)
- merge gate: <what the pre-merge hook runs, overrides, CI status note>

## Retro

- running log: <committed path, e.g. .claude/retro-log.md>
- context files: <instruction files a run loads, measured each retro: global and project CLAUDE.md, this profile, the skills>
- metric sources: <hook or CI logs with check tier, duration and result>
- edits land: <where and how project-fact edits are committed>
