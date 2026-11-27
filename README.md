# agent-workflow

Claude Code skills that take a GitHub issue from rough idea to merged PR, with UX design and tech specification as separate, optional stages. The skills hold the method; each project fills in its facts in a tracked **profile** file.

For any developer who works with [Claude Code](https://claude.com/claude-code) and GitHub issues. `/aw-coordinate` takes several issues through all stages at once; [Orca](https://github.com/stablyai/orca) is optional and runs them as supervised workers.

## Quickstart

```sh
git clone https://github.com/jaylouiz/agent-workflow.git
bash agent-workflow/install.sh       # checks the requirements, asks a few questions, links the skills
cd <your repo> && claude             # then: /aw-setup
```

`/aw-setup` reads the repo (scripts, CI checks, UI or not, docs), drafts the profile and config, asks only what it could not tell, creates the labels and opens a PR with the setup. Rerun `/aw-setup update` when the project changes. A first issue then goes like this:

1. You open an issue with only a title, say "Export the list as CSV" (#12).
2. In `claude`, you type `/aw-specify 12`.
3. The skill reads the issue and the code, and writes the missing layers into the issue body: Problem, Solution, acceptance criteria.
4. Where the build is open it posts two or three approaches as a comment and waits for your choice.
5. You answer on the issue (`ok` takes the recommended one); the issue gets the label `ready`.
6. You type `/aw-build 12`.
7. It works on a branch and worktree of its own, implements the spec and runs the project's tests.
8. It checks every acceptance criterion against evidence and opens a PR with `Closes #12`.
9. You run `/code-review`, then merge the PR yourself: only `/aw-coordinate` merges.
10. Is the UX open (a new screen or flow)? Start with `/aw-ui-design 12`: variants, your pick, then steps 2-9.

A question only you can answer **parks** the issue as a comment. Answer there and run the same skill again: it continues where it stopped.

## Requirements

- Both platforms: [Claude Code](https://claude.com/claude-code), `git`, `bash` (3.2 is enough), `jq`, `python3` and [`gh`](https://cli.github.com), logged in (`gh auth login`) and at least `GH_MIN` of [bin/lib.sh](bin/lib.sh), the one place the minimum versions live.
- macOS: `brew install gh jq python`; the system `bash` and `git` do.
- Linux: `sudo apt install jq python3 lsof`, and `gh` from [GitHub's apt/rpm repository](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) (distribution packages are older than `GH_MIN`); `lsof` is only for prototype previews.
- `bash install.sh --check` (run in your clone of this repo) checks all of it and changes nothing. CI runs the test suite on macOS and Ubuntu.
- Optional, not shipped here: `/gh-inbox-dispatcher`, `/ui-canvas`, `harvesting-session-knowledge` and the Impeccable plugin. `/code-review` is built into Claude Code. A step whose tool is missing is skipped or reported, or takes the fallback its skill names.

## Without and with Orca

| | Without Orca | With Orca |
|---|---|---|
| Skills | `/aw-setup`, `/aw-ui-design`, `/aw-specify`, `/aw-build`, `/aw-retro`, `/code-review`, and `/aw-coordinate <issues>` in subagent mode | the same; `/aw-coordinate` runs the stages as Orca workers |
| Workers of `/aw-coordinate` | background subagents, each in its own git worktree; they report once, at the end | Orca workers in their own terminals: you can watch and message them |
| When the session ends | the run stops; run `/aw-coordinate <issues>` again to go on | Orca wakes the coordinator; many issues run as waves |
| Decisions | the issue parks; `~/.claude/agent-workflow/bin/decide.sh status` lists what waits; rerun the skill after answering | the coordinator sends one digest and restarts the worker after your answer |
| Settings | all in [Settings](#settings) | all |
| Profile sections | all but "Orchestration" | all |

Without `orca` on PATH, `/aw-coordinate 12 15 #18` runs in subagent mode: it screens and batches the issues, runs each stage as a subagent (up to `WF_MAX_WORKERS` at once, `1` for one after the other), parks on decision requests, routes the review through `/code-review` and merges. The word `subagents` in the input picks that mode with Orca too. Both modes follow [reference/coordination.md](reference/coordination.md).

## With Orca

1. Install [Orca](https://github.com/stablyai/orca) with its `orca` CLI.
2. Check: `bash install.sh --check` warns when your Orca is older than the minimum; `/aw-coordinate` warns too, neither blocks. Minimum and tested version are `ORCA_MIN` and `ORCA_TESTED`: `bash -c '. ~/.claude/agent-workflow/bin/lib.sh; echo "$ORCA_MIN $ORCA_TESTED"'`.
3. In your repo: `/aw-coordinate 12 15 #18`, or an idea in plain words.

`WF_MAX_WORKERS` (default `3`) is how many workers run at once. `WF_PORTS` (`3101-3105`; prototype previews check it without Orca too) gives each worker a dev-server and E2E port, so the range needs at least that many ports. `WF_PROTO_PORTS` (`3111-3119`) holds the prototype previews that stay up while a design decision waits; keep it outside `WF_PORTS`.

## Install

`install.sh` links every `skills/*` into `~/.claude/skills/` and this checkout to `~/.claude/agent-workflow` (the skills read `reference/` and run `bin/` through it). Every skill starts with `aw-`: type `/aw-` to list them. In a terminal it asks, and records the answers in `~/.claude/agent-workflow-settings.sh`:

- **Models**, one per tier (default / strong / fast / heavy, see [Settings](#settings)): a Claude Code alias; Enter keeps the value shown. No Fable access: answer `opus` for heavy. Without prompts: `--models balanced|quality|budget`, or `--model-<tier> <id>`.
- **Global rules**: the author's [global/CLAUDE.md](global/CLAUDE.md), off by default. The prompt prints one line per rule, with `needs:` where a rule names an optional skill. On: linked as `~/.claude/CLAUDE.md`, or one import line appended to your own (a backup is kept).
- **Prototype previews**: restart them at login (a LaunchAgent on macOS, a `systemd --user` unit on Linux).

A rerun without a terminal (or with `--yes`) keeps every recorded choice and never overwrites a real file where a link belongs. All flags, `--uninstall` among them: the header of [install.sh](install.sh). Edit skills in this repo only. Old script paths keep working for one release through [compat/](compat/README.md).

Without `/aw-setup`: copy [reference/project-profile.md](reference/project-profile.md) to `<project>/.claude/issue-workflow.md` and [reference/project-config.sh](reference/project-config.sh) to `<project>/.claude/issue-workflow.sh`, fill them in and commit them.

## Settings

Two sourced bash files, read in this order (later wins): built-in defaults, the global `~/.claude/agent-workflow-settings.sh` (template [reference/global-settings.sh](reference/global-settings.sh)), the repo's `.claude/issue-workflow.sh` (template [reference/project-config.sh](reference/project-config.sh)). `bash ~/.claude/agent-workflow/bin/settings.sh show` prints every value with its source. **Coord.** marks a setting only `/aw-coordinate` and its workers read.

| Setting | Default | Coord. | What it does |
|---|---|---|---|
| `WF_MODEL_DEFAULT` | `sonnet` | | normal workers, Design's tech check, the retro agent |
| `WF_MODEL_FAST` | `haiku` | | mechanical subagents (`rg` audits, copy sweeps) |
| `WF_MODEL_STRONG` | `opus` | Coord. | coordinators, reviewers, the root-cause subagent of a stuck lead |
| `WF_MODEL_HEAVY` | `claude-fable-5-2` | Coord. | workers for a new feature, a bigger UI change, complex technical work |
| `WF_MAX_WORKERS` | `3` | Coord. | concurrent workers of one hand-off |
| `WF_PORTS` | `3101-3105` | Coord. | one dev-server and E2E port per worker |
| `WF_DIGEST_CAP` | `2h` | Coord. | how long the oldest unannounced decision request waits for the digest |
| `WF_NO_WAIT_CI` | `0` | Coord. | `1`: merge prep does not wait for pending checks |
| `WF_RISK_GLOBS`, `WF_IGNORE_GLOBS`, `WF_REVIEW_LINES`, `WF_HOLD_LABELS`, `WF_REQUIRED_CHECKS`, `WF_CHECKS_TSV`, `wf_*` functions | see the template | Coord. | review routing, merge holds, CI gate, verify / build / after-merge steps |
| `WF_PROTO_PORTS` | `3111-3119` | | prototype previews of `/aw-ui-design` |
| `WF_COMMENT_CAP` | `1500` | | visible characters per agent issue comment |
| `WF_ISSUE_LOG_DIR` | `~/.claude/issue-logs` | | per-issue coordination logs |
| `WF_PHASE_LABELS` | `on` | | `off`: no `phase:design` / `phase:build` labels; GitHub's issue status carries the phase alone |
| `WF_PR_ATTRIBUTION` | `on` | | `off`: the guard hook stops requiring the "Generated with [Claude Code]" line in a PR body |

Fixed on purpose: label names and colours (board clients read them), the retro thresholds and the CI wait windows.

## Updating

`bash install.sh --update` refuses local changes to tracked files, runs `git pull --ff-only`, reruns the install when a skill was added, renamed or removed or `install.sh` changed, and prints the version jump and the new **Breaking** entries of the [CHANGELOG](CHANGELOG.md). Restart open Claude sessions and coordinators afterwards: a running session keeps the skill text it loaded. Releases are semver tags; the maintainer's procedure is [docs/releasing.md](docs/releasing.md).

## Troubleshooting

- **"No profile in this repo"**: the skills run, but skip every project-specific step. Run `/aw-setup` once and merge its PR.
- **`CLAUDE_CONFIG_DIR` is set**: not supported. Hooks and script paths assume `~/.claude`; `install.sh` warns. Unset it and rerun `install.sh`.
- **Orca below the minimum**: `/aw-coordinate` relies on commands of `ORCA_MIN`. Update Orca; the warning goes.
- **`gh` not logged in or too old**: `gh auth login`, or update `gh`. Screenshots in issue comments need `GH_MIN`. `install.sh --check` reports both.
- **Hooks not firing** (a PR without `Closes #<n>` gets through): the hooks sit in each skill's frontmatter and run `~/.claude/agent-workflow/bin/guard.sh`, so they are live only while an `/aw-` skill runs. Check that this path exists, that `jq` and `python3` are installed, and restart sessions opened before the install.
- **Claude Code on the web**: cloud sessions do not get these skills; what works there lives in the project's `CLAUDE.md`.

## Vocabulary

- **Stage**: Design (`/aw-ui-design`), Specify (`/aw-specify`), Build (`/aw-build`), then Review and Merge. Only Build is required.
- **Lane**: the label that names an issue's next stage: `needs-design` → `needs-spec` → `ready`.
- **Profile**: the project's facts the skills leave open, `.claude/issue-workflow.md`, written by `/aw-setup`.
- **Spec**: the issue body after Specify: problem, solution, acceptance criteria. The only input Build needs.
- **Decision request**: a question only you can answer, as an issue comment; until you answer, the issue is **parked**.

Every term, the issue standard and the method's background: [docs/vocabulary.md](docs/vocabulary.md). What a board client such as [Tandem](https://github.com/jaylouiz/tandem) may rely on: [docs/contract.md](docs/contract.md), with <a id="phases"></a>[phases and statuses](docs/contract.md#phases) and <a id="comment-markers"></a>[comment markers](docs/contract.md#comment-markers).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/lanes-dark.png">
  <img src="docs/diagrams/lanes.png" width="960" alt="Issue lanes: triage routes an issue to needs-design (open UX), needs-spec (open build) or ready. /aw-ui-design leads to needs-spec or ready, /aw-specify to ready, /aw-build opens a PR, which is reviewed and merged. Fog gets no lane: the user sets the direction.">
</picture>

## History and license

This repository starts with a single public commit; issue and PR numbers up to #49 in skills, docs and comments refer to the author's private archive of the earlier history.

MIT, see [LICENSE](LICENSE). Third-party material: [NOTICE](NOTICE).
