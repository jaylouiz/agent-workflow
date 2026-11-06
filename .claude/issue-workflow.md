# issue-workflow profile: agent-workflow

<!-- Facts the code cannot tell. Executable facts: `.claude/issue-workflow.sh`. Method and vocabulary: README.md.
     No UI here (shell scripts and Markdown), so there is no Design quality, Pattern check, Design feedback, Screenshots,
     Prototype, Canvas or Components section: those steps do not apply. -->

## Labels

- lanes: needs-design → needs-spec → ready; phase:design, phase:build; hold: on-hold-after-spec, do-not-merge
- also used: inbox (out-of-scope finds, global CLAUDE.md), agent-decided, needs-decision, ux-impact (never set here: no UI)

## Sources

- method and vocabulary: `README.md`; project templates: `reference/project-profile.md`, `reference/project-config.sh`
- no product doc, design system or design backlog

## Risk areas

- `~/.claude/skills/*` and `~/.claude/CLAUDE.md` are symlinks into the main checkout (`install.sh`): a merge changes every session of the user as soon as the main checkout is pulled (`wf_after_merge` does that). Never edit the main checkout by hand.
- Hooks and always-loaded files (a bug breaks every session; globs in `WF_RISK_GLOBS`): `guard.sh`, `worker-done-stop.sh`, `orca-update-review/check.sh`, `global/CLAUDE.md`, `install.sh`. PRs touching them get a separate Opus reviewer.
- `lib.sh` is sourced by every orchestrate script; a bash-3.2-incompatible construct breaks macOS runs: run its suite with `/bin/bash` (the gate uses the `bash` on PATH).

## Branches

- name: `<type>/<n>-<slug>`, types fix|feat|test|docs|chore
- issue numbers: `#1`-`#49` in code, docs and commits refer to the private archive `jaylouiz/agent-workflow-archive` (`gh issue view <n> -R jaylouiz/agent-workflow-archive`).
- worktree notes: Orca worktrees live in Orca's workspace directory; no dependencies to install.

## Verification

- gate command: `wf_verify` = every `skills/*/test-*.sh` and `.claude/test-*.sh`, first failure stops. Run the suites that touch your change while working, `wf_verify` before the PR.
- shellcheck on touched scripts when installed (it was not on this machine).
- extra greps: after renaming or removing a script, skill or section, `rg` the old name in `skills/`, `global/`, `README.md`, `reference/` (skills point to profile sections by name: "the profile's X").

## Pull requests

- required in body: summary, ACs as a checklist with evidence (test name or command output), what was left out. No screenshots, no E2E.

## Decisions

- one-way: the default list (orchestrate-gh-issues section 5) plus anything that edits `~/.claude` settings or runs `install.sh` outside `wf_after_merge`.
- two-way: script internals, test layout, wording of skills, what goes into the profile.
- digest cap: 2h

## Orchestration

- runner: Orca; max workers: 3
- executable facts: `.claude/issue-workflow.sh` (risk globs, verify, after-merge); no build, deploy check or PR-body check
- merge gate: no pre-merge hook, no CI. `merge-pr.sh prep` runs `wf_verify`; `merge-pr.sh after` fast-forwards the main checkout and reruns `install.sh` when `skills/*` dirs or `install.sh` changed.

## Retro

- running log: `.claude/retro-log.md`
- context files: `global/CLAUDE.md` (words / lines), this profile, all `skills/*/SKILL.md` (summed); no project `CLAUDE.md`
- metric sources: none
- edits land: committed on a `chore/` or `docs/` branch via PR, like any change
