# Guided install, per-repo setup and settings

Status: approved 2026-11-15.

## Intent

agent-workflow is published for other builders, but setting it up today assumes the author's machine and habits: `install.sh` asks nothing and checks nothing, a project gets its profile by copying a 20-section template by hand, and several choices that differ per person (models, Orca, the author's global rules) are baked into the skills. Goal: someone who clones the repo gets a working setup for their own project in one install plus one guided conversation per repo, and can change every person- or project-specific choice in one place, without editing skill files.

Success: a new user runs `install.sh`, answers at most four questions, runs `/aw-setup` in their repo, answers only what the agent could not detect, and ends with a committed profile and config, created labels, and a short "what next".

## Goals

- `install.sh` checks requirements, asks the optional global choices (interactive terminal only), records them, and prints the next step.
- A new skill `/aw-setup` sets up one repo: detect, draft, ask only the gaps, validate, create labels, commit. Rerun = update mode.
- One settings layer: defaults → global settings file → repo config. Every choice listed under "Settings" below lives there, not in a skill.
- Skills behave well without a profile: they say so once and point to `/aw-setup` instead of guessing.

## Non-goals

- Configurable lane, phase or marker label names and colours (Tandem and the tests read them).
- Configurable internal heuristics: retro thresholds (5 min due, 15 min act, 30 days), the 10-minute CI registration window, the 15-minute root-cause trigger, the 400-character line cap.
- A per-user, per-repo untracked override file. Add later if someone needs it.
- Support for platforms other than macOS beyond what bash 3.2 and the existing scripts already give.

## Anti-goals

- A wizard that asks what the repo already answers (package scripts, CI check names, lockfiles, UI framework).
- Overwriting anything the user wrote: an existing `~/.claude/CLAUDE.md`, `settings.json` entries, a profile's prose.
- Prompts in a non-interactive run: `wf_after_merge` reruns `install.sh` unattended and must keep the recorded choices.
- Changing the author's behaviour silently: defaults equal today's hardcoded values.

## Constraints

- bash 3.2, `jq`, `python3`; every script quiet on success, one line on failure (repo convention).
- `install.sh`, `guard.sh`, `worker-done-stop.sh`, `check.sh`, `global/CLAUDE.md` are risk files (`WF_RISK_GLOBS`): the PR gets a separate reviewer.
- Skills point to profile sections by name; renames need the `rg` sweep from the profile's "Verification".
- Skill frontmatter is static and cannot read settings.

## Approaches (per-repo setup)

1. **Agent skill `/aw-setup`** (picked by the user). Reads the repo, drafts both files, interviews only the gaps, drops sections that do not apply, creates labels, commits. Can fill the prose profile, which a script cannot.
2. **Interactive shell script.** Deterministic and model-free, but cannot write the prose sections, so users still hand-edit.
3. **Both** (script for config and labels, skill for prose). More moving parts for little gain.

The global install stays a shell script (it runs before any skill exists), made interactive.

## Design

### 1. Settings layer

- New global file `${CLAUDE_CONFIG_DIR:-~/.claude}/agent-workflow-settings.sh`, same sourced-bash format as the repo config; `WF_GLOBAL_SETTINGS` overrides its path (tests).
- `wf_load` (lib.sh) order: built-in defaults → global file → repo `.claude/issue-workflow.sh`. Any `WF_*` may be set in either file; the repo wins. Globbing stays off while sourcing.
- Environment: only the three variables that are env-driven today (`WF_REPO`, `WF_COMMENT_CAP`, `WF_ISSUE_LOG_DIR`) win over both files when exported; every other `WF_*` comes from the files, as today (`wf_load` keeps assigning defaults unconditionally). `decide.sh` (already sources `lib.sh`) calls `wf_load` so the files can set the two caps; in a scratch dir it gets the global file only, which is intended.
- A missing global file is normal. One that fails to source prints one line to stderr (`agent-workflow: <path>: syntax error, using defaults`) and the script continues: hooks and guards never stop a session over it. `settings.sh show` reports it as an error line.
- New `bin/settings.sh`:
  - `settings.sh show`: every setting with value and source (`default`, `global`, `repo`, `env`), one per line, readable by people and agents.
  - `settings.sh get <NAME>`: the resolved value only.
  - `settings.sh path`: the global and repo file paths and whether they exist.
- Template `reference/global-settings.sh` documents every global setting with its default, commented out.

### 2. Settings inventory

| Setting | Default | Typical home | Today |
|---|---|---|---|
| `WF_MODEL_DEFAULT` | `sonnet` | global | lead, design, fix, delta-review workers; Design tech check; retro agent |
| `WF_MODEL_STRONG` | `opus` | global | reviewer worker, root-cause subagent |
| `WF_MODEL_FAST` | `haiku` | global | mechanical subagents |
| `WF_MAX_WORKERS` | `3` | global or repo | repo config only |
| `WF_DIGEST_CAP` | `2h` | global or repo | profile prose "digest cap" |
| `WF_COMMENT_CAP` | `1500` | global | env only, undocumented |
| `WF_ISSUE_LOG_DIR` | `~/.claude/issue-logs` | global | env only, undocumented |
| `WF_NO_WAIT_CI` | `0` | global or repo | repo config |
| `WF_PORTS`, `WF_RISK_GLOBS`, `WF_IGNORE_GLOBS`, `WF_REVIEW_LINES`, `WF_HOLD_LABELS`, `WF_REQUIRED_CHECKS`, `WF_CHECKS_TSV`, `wf_*` functions | as today | repo | unchanged |
| Global rules linked or imported | off | install choice | `--global-rules` flag |
| Orca update check hook and `/aw-orca-review` | off; `install.sh --dev` only | dev mode | always registered |

How the model tiers reach their users:

- `spec.sh`: `--model` defaults to `WF_MODEL_STRONG` for stage `review` and `WF_MODEL_DEFAULT` for every other stage; `--model` still overrides. `task-template.md` gets `{{MODEL_STRONG}}` and `{{MODEL_FAST}}` where it names `opus` and `haiku` today.
- orchestrate SKILL.md section 3: the table names tiers (default, strong, fast) with today's values as defaults and says to read them with `settings.sh show` in Preflight; `--effort high` for risk-area leads stays.
- aw-ui-design tech check and aw-retro / global CLAUDE.md retro agent: "the default tier (`settings.sh get WF_MODEL_DEFAULT`)".
- `aw-build` frontmatter `model: sonnet` is removed (user decision): in a run the worker's model comes from `worker-start --model` (the setting), and an interactive user runs on their session model.
- `usage.py` pricing stays keyed by model family; unknown families keep falling back to opus pricing.

### 3. `install.sh`

Order of output, each block a few lines:

1. **Requirements**: `git`, `bash`, `jq`, `python3`, `gh` and `gh auth status`, `claude`; optional `orca`, `shellcheck`. One line each, ok or missing with the install hint. Missing required tools: warn, continue linking, repeat in the summary.
2. **Link skills and the checkout** (as today, never overwrites a real file).
3. **Questions** (only when stdin and stdout are a terminal and `--yes` is not given; otherwise the defaults or the recorded state):
   - Models: `balanced` (sonnet/opus/haiku, default), `quality` (opus/opus/sonnet), `budget` (sonnet/sonnet/haiku), `custom` (asks the three). Written to the global settings file. With an existing file the question shows the current values and defaults to keep.
   - Global rules (show the four rule headings first; default no). No `~/.claude/CLAUDE.md`: link it. A real file: offer to append one import line `@~/.claude/agent-workflow/global/CLAUDE.md` (backup `CLAUDE.md.bak`). Already linked or imported: keep, offer to remove.
4. **Summary and next step**: what changed, what is missing, then `cd <your repo> && claude`, `/aw-setup`.

Dev mode (user decision): the Orca update check is a convenience for the maintainer, who keeps the skills current with the newest Orca; users get the updated skills through `git pull`. So `install.sh` neither links `skills/aw-orca-review` nor registers its SessionStart hook, unless `--dev` is given (no question in the interactive flow). `--dev` records `WF_INSTALL_DEV=1`; `--no-dev` removes the link and the hook. Migration: a machine whose `settings.json` already has the hook and no recorded choice counts as dev mode, so the maintainer's unattended reruns keep it.

Recorded choices: install writes `WF_INSTALL_GLOBAL_RULES=link|import|off` and `WF_INSTALL_DEV=1|0` into the global settings file, so a later run can tell "declined" from "never asked". First run without a settings file and without a terminal: models `balanced`, dev mode off (except the migration case), global rules `off` unless a link into this checkout already exists (kept, as today).

Exit codes: `install.sh` exits 0 when linking worked, even with missing tools (they are listed in the summary); `--check` exits 1 when a required tool is missing. Tools are checked for presence only, no versions.

Backups: `settings.json.bak` as today; `CLAUDE.md` gets `CLAUDE.md.bak.<timestamp>` before the import line goes in. Uninstall removes the import line only when it matches exactly.

Risk to check first in the build: that Claude Code resolves an `@~/...` import from the user-level `~/.claude/CLAUDE.md` without an approval prompt. If it does not, the import option is dropped and install offers only the symlink (or prints the line for the user to add).

Flags (scriptable, also for tests): `--yes`, `--models <preset>`, `--global-rules` / `--no-global-rules`, `--dev` / `--no-dev`, `--check` (requirements only, no changes), `--uninstall` (removes the skill links, the checkout link, the dev hook and a global-rules link or import line; keeps the settings file and logs, says so). Non-interactive rerun with no flags keeps every recorded choice (link present, import line present, hook present, settings file content).

### 4. `/aw-setup` skill

New `skills/aw-setup/SKILL.md` plus a deterministic helper `detect.sh` (prints facts as `key: value` lines; no writes) and `labels.sh` (creates the full label set with `gh label create --force`, like the skills do today). The set and its colours and descriptions are copied from the skills' current `gh label create` lines: `needs-design`, `needs-spec`, `ready`, `phase:design` 5319E7, `phase:build` 1D76DB, `ux-impact` C5DEF5, `needs-decision` D93F0B, `agent-decided` FBCA04, plus `inbox` (global CLAUDE.md text) and the repo's `WF_HOLD_LABELS`. Lane labels without a colour today get one from the builder; the skills keep their own `--force` lines (idempotent, no drift risk in practice). Templates are read through `~/.claude/agent-workflow/reference/`; drafts live in the session scratchpad until step 6.

Steps:

1. **Preflight**: git repo with a GitHub origin, `gh auth status`; `settings.sh show`. An existing `.claude/issue-workflow.md` or `.sh` switches to update mode (step 7).
2. **Detect** (`detect.sh` plus reading): package manager and lockfiles; scripts for verify/test/lint/build/dev; dev ports; E2E tool and config; CI workflows, check names as GitHub shows them, branch protection's required checks; `CLAUDE.md` / `AGENTS.md`, product and design-system docs, `.claude/rules/`; UI or not (frontend framework, components); existing labels; `orca` present.
3. **Draft** both files from the templates in the scratchpad: detected facts filled in and referenced (not copied) from `CLAUDE.md`, guesses marked, sections that do not apply left out (non-UI: Design quality, Components, Pattern check, Design feedback, Screenshots, Prototype, Canvas; no Orca: Orchestration's runner lines and ports).
4. **Ask only the gaps**, with `AskUserQuestion`, at most two rounds of up to four questions, each with a recommended option: UI project (only when detection is unsure), gate command (only when several candidates), risk areas (proposed globs to confirm or edit), one-way decisions (default list plus additions), and, with Orca, max workers. Model tiers are not asked (global); the user may override them for the repo in the review step.
5. **Review**: show the draft as a short summary (filled, guessed, left out and why); the user edits or accepts.
6. **Write and validate**: write `.claude/issue-workflow.md` and `.claude/issue-workflow.sh`; `bash -n` the config; `settings.sh show` from the repo; run the gate command once when the user agrees (it can be slow). `labels.sh`. Commit on `chore/issue-workflow-setup` and open a PR when the repo has a remote; the user may choose the current branch or no commit instead. Only its own two files are staged (`git commit -- <paths>`), so a dirty tree is left as it was. The skill never merges.
7. **Update mode**: compare the existing profile with the template: sections that now apply but are missing, commands that no longer exist, check names no longer reported. Propose each change; never rewrite user prose without showing the diff.
8. **Report**: what was detected, asked, left out; next steps (`/aw-specify <n>`, `/aw-build <n>`, `/aw-coordinate` when Orca is present).

### 5. Skills without a profile

README "Generic vs project" and each stage skill's "Read the profile" step gain one rule: no `.claude/issue-workflow.md` → say once that the repo has no profile and that `/aw-setup` creates one, then continue as if every profile section were missing (those steps do not apply). Unattended workers do not stop for it.

### 6. Profile template

`reference/project-profile.md` is reordered: core sections first (Labels, Sources, Jobs, Risk areas, Branches, Verification, Pull requests, Decisions), then a UI block (each heading tagged `<!-- ui -->`), then Orchestration (tagged `<!-- orca -->`) and Retro (untagged). Tags are per section only; section names do not change, so no skill reference breaks. "digest cap" moves to `WF_DIGEST_CAP`, read by the coordinator through `settings.sh get` (prose only, nothing enforces it). The init skill uses the tags to drop sections.

### 7. README

Install becomes a quickstart: clone, `install.sh`, `/aw-setup`, first issue. New "Settings" section with the table from section 2, `settings.sh show`, and where each file lives. Requirements stay, with the note that `install.sh --check` verifies them.

### 8. Tests

- `test-install.sh`: temp `CLAUDE_CONFIG_DIR`, non-interactive flags, idempotent reruns, never overwrites a real file, dev hook and `aw-orca-review` link only with `--dev`, migration keeps an existing hook, import line added once, `--uninstall`, a rerun without flags keeps recorded choices.
- `test-settings.sh`: layering default → global → repo → env, `show` sources, globs stay patterns.
- `test-spec.sh`: model default and template tiers come from settings.
- `detect.sh` and `labels.sh` get small suites with stubbed `gh`.
- `wf_verify` already picks up every `skills/*/test-*.sh`.

## Calls made (approved as recommended)

- Global file name and place: `~/.claude/agent-workflow-settings.sh` (next to the `agent-workflow` link, same format as the repo config).
- Three model tiers instead of one setting per role.
- Global rules: import line into an existing `CLAUDE.md` instead of only the symlink; default no.
- Orca update check only in dev mode (user decision).
- The init skill commits through a branch and PR by default.

## Left to the builder

Exact wording of prompts and messages, `detect.sh` heuristics, test layout, how the `<!-- ui -->` tags are parsed, the label colour table's location.
