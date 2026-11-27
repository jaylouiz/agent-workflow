---
name: aw-setup
description: Set up or update agent-workflow for the current repo. Detects scripts, CI checks, UI and docs, drafts `.claude/issue-workflow.md` and `.claude/issue-workflow.sh`, asks only what it could not detect, creates the labels and commits the setup as a PR. Use when a repo has no issue-workflow profile yet, when a skill says the profile is missing, or when asked to set up, initialise, onboard or update the workflow for a project.
argument-hint: "[update]"
allowed-tools: Bash(gh auth status*) Bash(gh repo view *) Bash(gh label *) Bash(gh pr create *) Bash(gh pr list *) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git switch *) Bash(git add *) Bash(git commit *) Bash(git push *) Bash(git remote *)
---

# Set up agent-workflow in this repo

Outcome: the repo has a committed profile (`.claude/issue-workflow.md`, the facts the skills leave open) and config (`.claude/issue-workflow.sh`, the executable facts), the workflow labels exist, and the user knows the next command. The user answers only what the repo cannot tell. Method and vocabulary: `~/.claude/agent-workflow/README.md`; templates: `~/.claude/agent-workflow/reference/project-profile.md` and `project-config.sh`.

## 1. Preflight

1. In a git checkout with a GitHub `origin` and `gh auth status` passing; otherwise say what is missing (labels and the PR need both) and continue with files only.
2. `bash ~/.claude/agent-workflow/bin/settings.sh show`: the global settings (models, max workers) apply to every repo; this repo overrides them only where the user wants.
3. A profile or config exists, or the argument is `update`: update mode (section 6).

## 2. Detect

`bash <this skill's dir>/detect.sh` prints the facts (`key: value`; see its header). Then read what it points to: `CLAUDE.md` / `AGENTS.md` (facts already there are referenced from the profile, never copied), product and design-system docs, `.claude/rules/`, the CI workflows (which job is the gate), `package.json` scripts or the `Makefile`. Find the risk areas: paths where a change is expensive or fragile (persistence, auth, payments, migrations, shared hooks, generated code), from the code, `CLAUDE.md` and recent `git log` churn.

## 3. Draft

Fill both templates in the session scratchpad, not in the repo yet:

- Every detected fact goes in; a guess is marked `(guess)`.
- Sections that do not apply are left out, not left empty: with `ui: no`, every section tagged `<!-- ui -->`; without Orca (`orca: no`), the section tagged `<!-- orca -->`. A missing section means "does not apply" to every skill.
- Config: `WF_PORTS` from the dev script (only with Orca), `WF_RISK_GLOBS` from the risk areas, `WF_IGNORE_GLOBS` from the lockfile, `WF_REQUIRED_CHECKS` from `required_check` (else the check names the gate job reports), `wf_verify` from the gate script, `wf_install` from the package manager. Model tiers and `WF_MAX_WORKERS` stay global unless the user asks.

## 4. Ask only the gaps

At most two `AskUserQuestion` calls of up to four questions each, the recommended option first with the reason. Ask only what detection left open, typically:

- UI project? (only when `ui: unsure`)
- Gate command (only when several candidates exist or none does)
- Risk areas: the proposed globs to confirm or edit
- One-way decisions: the default list (aw-orchestrate section 5) plus any the user adds
- Max workers (only with Orca, and only if the user wants a repo value)

Then show a short summary of the draft: filled, guessed, left out and why. The user accepts or edits.

## 5. Write, check, commit

1. Write `.claude/issue-workflow.md` and `.claude/issue-workflow.sh`; `bash -n .claude/issue-workflow.sh`; `bash ~/.claude/agent-workflow/bin/settings.sh show` from the repo (the repo values show as `(repo)`).
2. Offer one run of the gate (`wf_verify`); it can take minutes, so ask first. A failure is reported, not fixed here.
3. `bash <this skill's dir>/labels.sh` (creates or updates the lane, phase, marker, inbox and hold labels).
4. Commit only these two files: on a clean or dirty tree, `git switch -c chore/issue-workflow-setup`, `git commit -- .claude/issue-workflow.md .claude/issue-workflow.sh`, push, `gh pr create` (summary: what was detected, asked, left out). The user may instead pick the current branch or no commit. Never merge.

## 6. Update mode

Compare the existing files with the templates and the fresh `detect.sh` output; propose each change, one line why:

- sections that now apply but are missing (e.g. a UI was added), and sections that no longer apply
- commands, scripts or check names that no longer exist
- config variables the template has gained

Never rewrite the user's prose unseen: show the diff and apply only what the user accepts, then section 5 (labels again, commit as `chore: update issue-workflow profile`).

## 7. Report

Detected, asked, left out (and how to add it later: rerun `/aw-setup update`), the PR link, and the next commands: `/aw-specify <n>` or `/aw-build <n>` for one issue, `/aw-ui-design <n>` when the UX is open, `/aw-orchestrate <issues>` with Orca.
