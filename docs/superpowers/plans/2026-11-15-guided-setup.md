# Guided Setup and Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new user gets from `git clone` to a working, committed per-repo setup through an interactive `install.sh` and a `/aw-setup` skill, and every person- or project-specific choice lives in one settings layer instead of skill text.

**Architecture:** `lib.sh` gains a global settings file between the built-in defaults and the repo config; `settings.sh` prints the resolved values with their source. `install.sh` checks requirements, asks the global questions, records the answers in the global file and keeps the maintainer's Orca update check behind `--dev`. A new skill `aw-setup` (with `detect.sh` and `labels.sh`) drafts and commits the repo's profile and config.

**Tech Stack:** bash 3.2, `jq`, `python3 -I`, `gh`, Claude Code skills (Markdown with frontmatter).

**Spec:** `docs/superpowers/specs/2026-11-15-guided-setup-design.md`

## Global Constraints

- bash 3.2 compatible (no associative arrays, no `${x,,}`, no `mapfile`); run touched suites with `/bin/bash` too.
- Scripts are quiet on success and print one line on failure; `set -uo pipefail` like their neighbours.
- Defaults equal today's values: `WF_MODEL_DEFAULT=sonnet`, `WF_MODEL_STRONG=opus`, `WF_MODEL_FAST=haiku`, `WF_MAX_WORKERS=3`, `WF_DIGEST_CAP=2h`, `WF_COMMENT_CAP=1500`, `WF_ISSUE_LOG_DIR=$HOME/.claude/issue-logs`, `WF_NO_WAIT_CI=0`, the rest as in `lib.sh` today.
- Global file: `${WF_GLOBAL_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-workflow-settings.sh}`.
- Only `WF_REPO`, `WF_COMMENT_CAP` and `WF_ISSUE_LOG_DIR` win from the environment over both files.
- Model presets: `balanced` = sonnet/opus/haiku, `quality` = opus/opus/sonnet, `budget` = sonnet/sonnet/haiku (default/strong/fast).
- Recorded install choices: `WF_INSTALL_GLOBAL_RULES=link|import|off`, `WF_INSTALL_DEV=1|0`.
- Never overwrite a real file the user owns; `settings.json.bak` before a `settings.json` edit, `CLAUDE.md.bak.<YYYYmmdd-HHMMSS>` before a `CLAUDE.md` edit.
- Label names and colours do not change. Section names of the profile do not change.
- Work on branch `feat/guided-setup`; one PR; never run the live `install.sh` on the maintainer's machine without asking (profile "Decisions": edits to `~/.claude` are one-way).

## Review Focus

- **The maintainer's real global settings leak into test suites.** A `~/.claude/agent-workflow-settings.sh` with `WF_MAX_WORKERS=5` must not change any suite's result: every suite exports `WF_GLOBAL_SETTINGS` to a temp path (Task 1, step 6).
- **Unattended rerun on the maintainer's machine** (`wf_after_merge` → `install.sh >/dev/null`, no TTY, no settings file yet, hook present): keeps the hook, the `aw-orca-review` link and the global-rules symlink (Task 3 test `migration keeps dev`).
- **A broken global settings file** (syntax error) must not stop `guard.sh` or any hook: one stderr line, defaults used (Task 1 test `broken global`).
- **Unquoted globs in the global file** (`WF_RISK_GLOBS=(src/**)`) stay patterns, as for the repo file (Task 1 test `global globs stay patterns`).
- **Rerunning `/aw-setup` or `install.sh` twice** adds nothing twice: one import line, one hook entry, one `KEY=` line per setting (Task 3 tests `idempotent`).

---

### Task 1: Settings layer

**Files:**
- Modify: `bin/lib.sh` (`wf_load`, new helpers)
- Modify: `bin/decide.sh:84,106` (read caps after `wf_load`)
- Create: `bin/settings.sh`
- Create: `reference/global-settings.sh`
- Test: `bin/test-settings.sh`
- Modify: every `skills/*/test-*.sh` and `.claude/test-*.sh` that runs a script sourcing `lib.sh` (one `export WF_GLOBAL_SETTINGS=...` line)

**Interfaces:**
- Produces (lib.sh):
  - `wf_global_settings` → prints the global file path (Global Constraints).
  - `WF_SETTINGS` → space-separated list of every setting name `settings.sh` reports, in this order: `WF_MODEL_DEFAULT WF_MODEL_STRONG WF_MODEL_FAST WF_MAX_WORKERS WF_DIGEST_CAP WF_COMMENT_CAP WF_ISSUE_LOG_DIR WF_NO_WAIT_CI WF_PORTS WF_RISK_GLOBS WF_IGNORE_GLOBS WF_REVIEW_LINES WF_HOLD_LABELS WF_REQUIRED_CHECKS WF_CHECKS_TSV WF_INSTALL_GLOBAL_RULES WF_INSTALL_DEV`.
  - `wf_load` → defaults, then the global file, then `$ROOT/.claude/issue-workflow.sh`, globbing off for both; env values of `WF_COMMENT_CAP`/`WF_ISSUE_LOG_DIR` captured before and restored after. Source failure of either file: `agent-workflow: <path>: could not be loaded, using what loaded so far` on stderr, return 0.
- Produces (settings.sh): `settings.sh show` → lines `NAME=value  (default|global|repo|env)`, arrays printed space-joined in parentheses; `settings.sh get NAME` → value only, exit 1 for an unknown name; `settings.sh path` → two lines `global: <path> (present|absent)`, `repo: <path> (present|absent)`. Exit 64 on usage.
- Default `WF_INSTALL_GLOBAL_RULES=off`, `WF_INSTALL_DEV=0`.

- [ ] **Step 1: Write the failing tests** in `test-settings.sh` (same `check`/`eq` style as `test-spec.sh`; temp repo, `export WF_GLOBAL_SETTINGS=$T/global.sh`):
  - `defaults`: no files → `settings.sh get WF_MODEL_STRONG` = `opus`, `get WF_DIGEST_CAP` = `2h`, `show` line for `WF_MAX_WORKERS` ends `(default)`.
  - `global over default`: global file `WF_MODEL_DEFAULT=opus` → `get` = `opus`, `show` says `(global)`.
  - `repo over global`: repo config `WF_MAX_WORKERS=1`, global `WF_MAX_WORKERS=5` → `1`, `(repo)`.
  - `env wins for caps`: global `WF_COMMENT_CAP=900`, `WF_COMMENT_CAP=1200 settings.sh get WF_COMMENT_CAP` = `1200`, `(env)`; but `WF_MAX_WORKERS=9 settings.sh get WF_MAX_WORKERS` with no files = `3`.
  - `global globs stay patterns`: global `WF_RISK_GLOBS=(src/**)` with a real `src/a/b` file present → `show` prints `(src/**)`.
  - `broken global`: global file `WF_X=(` → `get WF_MAX_WORKERS` exits 0 with `3`, stderr has one line naming the file.
  - `path`: prints `global: $T/global.sh (absent)` before the file exists.
  - `unknown name`: `get WF_NOPE` exits 1.
  - `decide.sh cap from global`: global `WF_COMMENT_CAP=10`, `decide.sh check` on an 11-char file exits 65.

- [ ] **Step 2: Run** `bash bin/test-settings.sh` → FAIL (`settings.sh` missing).

- [ ] **Step 3: Implement** the lib.sh helpers and `wf_load` order; `settings.sh` derives each source by loading in subshells layer by layer (defaults only; + global; + repo) and comparing `declare -p` output, `env` when the name is one of the two caps and was set before load. `decide.sh`: call `wf_load` once after sourcing `lib.sh` (keep `${WF_COMMENT_CAP:-1500}` as fallback). `reference/global-settings.sh`: header comment (what the file is, load order, that any `WF_*` from `reference/project-config.sh` may go here and the repo wins), then every global setting commented out with its default and one-line meaning, grouped "Models", "Orchestration", "Comments and logs", "Recorded by install.sh (do not edit by hand)".

- [ ] **Step 4: Run** `bash bin/test-settings.sh` and `/bin/bash bin/test-settings.sh` → no `FAIL` lines, exit 0.

- [ ] **Step 5: Isolate the other suites**: add `export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh"` right after each suite's `T=$(mktemp -d)` (suites without `$T`: use `/nonexistent/agent-workflow-settings.sh`).

- [ ] **Step 6: Run the gate** `bash -c '. .claude/issue-workflow.sh; wf_verify'` → no output, exit 0. Then create `~/.claude`-independent proof: `WF_GLOBAL_SETTINGS=$(mktemp) && echo WF_MAX_WORKERS=9 >"$WF_GLOBAL_SETTINGS"` is ignored by the suites (rerun `wf_verify` with `HOME=$(mktemp -d)` containing such a file → still exit 0).

- [ ] **Step 7: Commit** `feat(settings): global settings layer and settings.sh`.

### Task 2: Model tiers and digest cap read from settings

**Files:**
- Modify: `skills/aw-orchestrate/spec.sh:21` (model default per stage), `:76-80` (export `MODEL_STRONG`, `MODEL_FAST`)
- Modify: `skills/aw-orchestrate/task-template.md:26` (`opus` → `{{MODEL_STRONG}}`, `haiku` → `{{MODEL_FAST}}`)
- Modify: `skills/aw-orchestrate/SKILL.md` section 0 (Preflight: new step "`settings.sh show`; models, max workers and digest cap come from it"), section 3 table (roles → tiers), every `--model opus`/`sonnet` example and the retro line (`fresh agent on the default tier`), and the digest cap mention (`WF_DIGEST_CAP`)
- Modify: `skills/aw-orchestrate/next.sh:16` (usage example only)
- Modify: `skills/aw-ui-design/SKILL.md:52` (`model: sonnet` → the default tier, `settings.sh get WF_MODEL_DEFAULT`)
- Modify: `skills/aw-retro/SKILL.md` and `global/CLAUDE.md:24` (retro agent: `model:` = default tier, `bash ~/.claude/agent-workflow/bin/settings.sh get WF_MODEL_DEFAULT`)
- Modify: `skills/aw-build/SKILL.md:4` (delete `model: sonnet`)
- Test: `skills/aw-orchestrate/test-spec.sh`

**Interfaces:**
- Consumes: `wf_load` and `WF_MODEL_*` from Task 1; `settings.sh get`.
- Produces: `spec.sh` without `--model`: stage `review` → `$WF_MODEL_STRONG`, others → `$WF_MODEL_DEFAULT`; template placeholders `{{MODEL_STRONG}}`, `{{MODEL_FAST}}`.

- [ ] **Step 1: Write the failing tests** in `test-spec.sh`:
  - `review defaults to strong`: `spec.sh review 9 --pr 42 --wt /x --no-port` (no `--model`) contains `by: opus`.
  - `lead names default tier`: global file `WF_MODEL_STRONG=fable` → lead spec contains `model: fable` and not `model: opus`.
  - `fast tier`: global `WF_MODEL_FAST=sonnet` → lead spec contains `model: sonnet` in the subagents line and not `haiku`.
  - `review respects global strong`: global `WF_MODEL_STRONG=fable`, review without `--model` → `by: fable`.
  - `--model still wins`: review with `--model sonnet` → `by: sonnet`.
- [ ] **Step 2: Run** `bash skills/aw-orchestrate/test-spec.sh` → the new checks FAIL.
- [ ] **Step 3: Implement** spec.sh (resolve `model` after `wf_load` when `--model` was not given) and the template placeholders.
- [ ] **Step 4: Run** `test-spec.sh` → no `FAIL`.
- [ ] **Step 5: Edit the prose** listed under Files. Section 3 table becomes: Coordinator = the user's session; Lead = default tier (`--effort high` for risk area or cross-cutting); Reviewer worker = strong; Root-cause subagent = strong, at most one per issue; Mechanical subagents = fast; Design, fix and delta-review workers = default. Keep the sentence "No other worker runs the strong tier unless the user says so for the run." Drop the dated "User decision 2026-11-02" pointer only if it no longer matches (it records the tier split, keep it).
- [ ] **Step 6: Sweep** `rg -n '\b(sonnet|opus|haiku)\b' skills global reference README.md -g '!**/snapshot/**' -g '!**/test-*'` → only `usage.py` pricing and preset/default documentation remain.
- [ ] **Step 7: Run** `wf_verify` → exit 0. **Commit** `feat(settings): model tiers and digest cap from settings`.

### Task 3: Interactive `install.sh`

**Files:**
- Modify: `install.sh` (rewrite, same link semantics)
- Test: `.claude/test-install.sh` (picked up by `wf_verify`)
- Modify: `.claude/issue-workflow.sh` (`WF_RISK_GLOBS` unchanged; `wf_install_skills` keeps `bash "$PWD/install.sh"`)

**Interfaces:**
- Consumes: `reference/global-settings.sh` (copied to the global path on first write), `wf_global_settings` (source `lib.sh` for it).
- Produces: flags `--yes`, `--models balanced|quality|budget|custom`, `--global-rules`, `--no-global-rules`, `--dev`, `--no-dev`, `--check`, `--uninstall`; exit 0 after linking, 2 on an unknown flag, `--check` exit 1 when a required tool is missing. Interactive only when `[ -t 0 ] && [ -t 1 ]` and no `--yes`, or when `AW_INSTALL_INTERACTIVE=1` (tests feed answers on stdin). Internal `set_setting KEY VALUE` replaces the `^KEY=` line or appends it, never duplicates.

- [ ] **Step 0: Verify the import mechanism.** Ask the `claude-code-guide` agent: does Claude Code load `@~/.claude/agent-workflow/global/CLAUDE.md` from the user-level `~/.claude/CLAUDE.md`, and is there an approval prompt for it? Then try it: a throwaway `CLAUDE_CONFIG_DIR` with such a line and `claude -p "quote the first heading of your global rules"`. If it does not load silently, drop the `import` mode: a real `CLAUDE.md` then gets the line printed for the user to add, and the tests below for `import` become tests for that message.
- [ ] **Step 1: Write the failing tests** (`CLAUDE_CONFIG_DIR=$T/c`, `WF_GLOBAL_SETTINGS` unset so the path derives from it, `PATH` with stub `gh`, `orca`, `claude`):
  - `fresh --yes`: all skills except `aw-orca-review` linked in `$T/c/skills`, `$T/c/agent-workflow` → repo, settings file has `WF_MODEL_DEFAULT=sonnet`, `WF_INSTALL_DEV=0`, `WF_INSTALL_GLOBAL_RULES=off`, no `CLAUDE.md`, `settings.json` has no `aw-orca-review`.
  - `dev`: `--yes --dev` with a `settings.json` `{}` → `aw-orca-review` linked, one SessionStart entry with `check.sh`, `WF_INSTALL_DEV=1`; second run → still one entry.
  - `no-dev`: then `--no-dev` → link and hook gone, `settings.json.bak` exists.
  - `migration keeps dev`: no settings file, `settings.json` with the hook, global `CLAUDE.md` linked into the repo, run with no flags and no TTY → hook kept, `aw-orca-review` linked, `CLAUDE.md` link kept, recorded `WF_INSTALL_DEV=1`, `WF_INSTALL_GLOBAL_RULES=link`.
  - `models preset`: `--yes --models quality` → `WF_MODEL_DEFAULT=opus`, `WF_MODEL_STRONG=opus`, `WF_MODEL_FAST=sonnet`; rerun `--yes` keeps them.
  - `global rules link`: `--yes --global-rules`, no `CLAUDE.md` → symlink to `global/CLAUDE.md`.
  - `global rules import`: real `CLAUDE.md` with `# mine`, `--yes --global-rules` → file still starts with `# mine`, contains the import line exactly once after two runs, a `CLAUDE.md.bak.*` exists.
  - `never overwrites`: real directory at `$T/c/skills/aw-build` → left, warning names it, exit 0.
  - `interactive`: `AW_INSTALL_INTERACTIVE=1` with stdin `budget\nn\n` → budget models recorded, no rules.
  - `check`: `PATH` without `jq` → `--check` exit 1, output line names `jq`, nothing linked.
  - `uninstall`: after `dev` + `import` → no links into the repo, no hook, no import line, settings file kept, output says it was kept.
  - `unknown flag`: exit 2.
  - `stale link removed`: a link in `$T/c/skills/old` pointing into `$ROOT/skills/old` (missing) → removed (today's behaviour).
- [ ] **Step 2: Run** `bash .claude/test-install.sh` → FAIL.
- [ ] **Step 3: Implement** in this output order: requirements (`git bash jq python3 gh claude` required, `gh auth status` warned, `orca shellcheck` optional; each line `ok <tool>` or `missing <tool>: <install hint>`), links, questions (models; global rules showing the four `##` headings of `global/CLAUDE.md`; no dev question), summary (what changed, missing tools, then `Next: cd <your repo> && claude, then /aw-setup`). Prompts read with `read -r`, default in brackets, empty answer = default. Migration rule: no recorded `WF_INSTALL_DEV` and `settings.json` contains `aw-orca-review/check.sh` → dev; no recorded `WF_INSTALL_GLOBAL_RULES` and `CLAUDE.md` links into the repo → `link`. The hook jq expression stays as today; removal deletes SessionStart entries whose command contains `aw-orca-review/check.sh` and drops an emptied `SessionStart`.
- [ ] **Step 4: Run** `bash .claude/test-install.sh` and `/bin/bash .claude/test-install.sh` → no `FAIL`. `shellcheck install.sh` if installed.
- [ ] **Step 5: Run** `wf_verify` → exit 0. **Commit** `feat(install): guided install with requirements check, settings and dev mode`.

### Task 4: `/aw-setup` skill

**Files:**
- Create: `skills/aw-setup/SKILL.md`
- Create: `skills/aw-setup/detect.sh`, `skills/aw-setup/labels.sh`
- Test: `skills/aw-setup/test-detect.sh`, `skills/aw-setup/test-labels.sh`

**Interfaces:**
- Consumes: `settings.sh show|path` (Task 1), templates via `~/.claude/agent-workflow/reference/` (Task 5 tags), `wf_repo_slug` from `lib.sh`.
- Produces:
  - `detect.sh [--no-gh]` (cwd = repo) prints `key: value` lines, one fact per line, keys: `repo`, `default_branch`, `profile` and `config` (`present|absent`), `pm` (npm|pnpm|yarn|bun|cargo|go|python|none), `lockfile`, `script.<name>` for `verify test lint typecheck build dev e2e` when present in `package.json` or a `Makefile`, `e2e` (playwright|cypress|none), `ci.workflow` (each `.github/workflows/*` file), `ci.check` (check-run names on the default branch head, gh only), `required_check` (branch protection, gh only, silent when not allowed), `doc` (each of `CLAUDE.md AGENTS.md PRODUCT.md DESIGN.md README.md` present), `rules` (each `.claude/rules/*.md`), `ui` (`yes|no|unsure`) and `ui.reason`, `orca` (`yes|no`), `label` (each existing label name, gh only). Never writes; exit 0 even when gh fails (`gh: unavailable` line).
  - `labels.sh [--dry-run]` creates with `gh label create --force`: `needs-design` (0E8A16, "UX direction open: prototype or sketch before spec"), `needs-spec` (C2E0C6, "Rough idea, spec not written yet"), `ready` (0052CC, "Spec confirmed, ready to build"), `phase:design` 5319E7, `phase:build` 1D76DB, `ux-impact` C5DEF5, `needs-decision` D93F0B, `agent-decided` FBCA04 (descriptions copied from the skills' current lines), `inbox` (EDEDED, "Unsorted out-of-scope finding, needs triage"), and each of `$WF_HOLD_LABELS` (B60205, "Hold: stops the pipeline (issue-workflow config)"). `--dry-run` prints the `gh` commands.

- [ ] **Step 1: Write the failing tests**:
  - `test-detect.sh`: fixture repo with `package.json` (`scripts.verify`, `scripts.dev`, `react` dependency), `package-lock.json`, `playwright.config.ts`, `.github/workflows/ci.yml`, `CLAUDE.md` → lines `pm: npm`, `lockfile: package-lock.json`, `script.verify: npm run verify`, `e2e: playwright`, `ci.workflow: .github/workflows/ci.yml`, `doc: CLAUDE.md`, `ui: yes`, `profile: absent`; a shell-only fixture → `ui: no`, `pm: none`; stub `gh` failing → exit 0 and `gh: unavailable`; `--no-gh` → no `gh` call (stub records calls).
  - `test-labels.sh`: stub `gh` logs args; `WF_HOLD_LABELS="on-hold-after-spec do-not-merge"` in a repo config → 11 `label create` calls, each with `--force`, `phase:build` with `--color 1D76DB`; `--dry-run` → no calls, 11 printed lines.
- [ ] **Step 2: Run** both suites → FAIL.
- [ ] **Step 3: Implement** `detect.sh` and `labels.sh` (`labels.sh` sources `lib.sh` and calls `wf_load` for `WF_HOLD_LABELS`; `detect.sh` uses `python3 -I` for `package.json`).
- [ ] **Step 4: Run** both suites (also with `/bin/bash`) → no `FAIL`.
- [ ] **Step 5: Write `SKILL.md`** following the spec's section 4 steps 1-8, in the house style of the other stage skills (Outcome line, numbered sections, commands as typed). Frontmatter: `name: aw-setup`; `description:` "Set up or update agent-workflow for the current repo: detects scripts, CI checks, UI and docs, drafts `.claude/issue-workflow.md` and `.claude/issue-workflow.sh`, asks only what it could not detect, creates the labels and commits the setup as a PR. Use when a repo has no issue-workflow profile yet, when a skill says the profile is missing, or when asked to set up, initialise, onboard or update the workflow for a project."; `argument-hint: "[update]"`; `allowed-tools: Bash(gh *) Bash(git *) Bash(bash *)`. Content decisions it must carry: questions via `AskUserQuestion`, at most two calls of up to four questions, recommended option first; drafts in the session scratchpad; drop sections by the template's `<!-- ui -->` / `<!-- orca -->` tags; reference `CLAUDE.md` facts instead of copying; `git commit -- .claude/issue-workflow.md .claude/issue-workflow.sh` on `chore/issue-workflow-setup`, PR via `gh pr create`, never merge; update mode proposes diffs and never rewrites prose unseen; final report lists detected / asked / left out and the next commands. Keep it under 6 KB (`wc -c`).
- [ ] **Step 6: Dry run** the skill's deterministic part on this repo: `bash skills/aw-setup/detect.sh --no-gh` → `profile: present`, `ui: no`.
- [ ] **Step 7: Run** `wf_verify` → exit 0. **Commit** `feat(init): /aw-setup skill with detect.sh and labels.sh`.

### Task 5: Template, missing-profile rule and README

**Files:**
- Modify: `reference/project-profile.md` (reorder; `<!-- ui -->` after each UI heading: Design quality, Components, Pattern check, Design feedback, Screenshots, Prototype, Canvas; `<!-- orca -->` after Orchestration; drop "digest cap" line, point to `WF_DIGEST_CAP`)
- Modify: `reference/project-config.sh` header (mentions the global file and `settings.sh show`)
- Modify: `skills/aw-ui-design/SKILL.md`, `skills/aw-specify/SKILL.md`, `skills/aw-build/SKILL.md`, `skills/aw-orchestrate/SKILL.md` (the "Read the profile" step), `README.md`
- Modify: `.claude/issue-workflow.md` (this repo: drop "digest cap: 2h", default)

**Interfaces:**
- Consumes: everything above (names only).

- [ ] **Step 1: Template**: reorder to Labels, Sources, Jobs, Risk areas, Branches, Verification, Pull requests, Decisions, then the UI block, then Orchestration, Retro. Section headings unchanged (verify: `diff <(git show HEAD:reference/project-profile.md | grep '^## ' | sort) <(grep '^## ' reference/project-profile.md | sort)` → empty).
- [ ] **Step 2: Missing-profile rule**, one sentence in each listed skill's profile step and in README "Generic vs project": "No `.claude/issue-workflow.md`: say once that this repo has no profile and that `/aw-setup` creates one, then continue as if every profile section were missing; an unattended worker does not stop for it."
- [ ] **Step 3: README**: Install becomes "Quickstart" (clone; `bash agent-workflow/install.sh`; in your repo `/aw-setup`; first issue `/aw-specify <n>` or `/aw-build <n>`), flags list, `install.sh --check`, "Maintainer: `--dev` adds the Orca update check" (the current hook paragraph moves here). New "Settings" section: the spec's section 2 table, load order, `settings.sh show`, file locations. Update "Per project" to point at the skill, keeping the manual-copy path as a one-liner.
- [ ] **Step 4: Sweep** `rg -n 'digest cap|--global-rules|aw-orca-review/check.sh' skills global reference README.md .claude -g '!**/snapshot/**'` → every hit matches the new behaviour; `wc -c skills/*/SKILL.md global/CLAUDE.md` → `global/CLAUDE.md` under 15000.
- [ ] **Step 5: Run** `wf_verify` → exit 0. **Commit** `docs: quickstart, settings and missing-profile rule`.

### Task 6: Branch gate and handover

- [ ] **Step 1:** `wf_verify` on the branch → exit 0; every touched suite also with `/bin/bash`.
- [ ] **Step 2:** Push `feat/guided-setup`, open the PR (summary, ACs as a checklist with evidence, what was left out; the PR touches `install.sh` and `global/CLAUDE.md`, so `merge-pr.sh route` → reviewer).
- [ ] **Step 3:** Ask the user before running the new `install.sh` on their machine (one-way per the profile); after a yes, run it without flags and confirm: hook kept, `aw-orca-review` linked, `CLAUDE.md` link kept, `settings.sh show` shows defaults.
