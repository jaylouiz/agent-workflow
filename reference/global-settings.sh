# shellcheck shell=bash
# agent-workflow global settings: ~/.claude/agent-workflow-settings.sh (install.sh creates it from this template).
# Sourced by the orchestrate-gh-issues scripts after the built-in defaults and before the repo's
# .claude/issue-workflow.sh, so a repo overrides anything here. Any WF_* from reference/project-config.sh may also go
# here (e.g. WF_MAX_WORKERS for every repo). Check the result with:
#   bash ~/.claude/skills/orchestrate-gh-issues/settings.sh show
# Uncomment a line to change it; the value shown is the default.

# --- Models (Claude Code aliases or full model IDs) ---
# WF_MODEL_DEFAULT=sonnet     # lead, design, fix and delta-review workers; Design's tech check; the retro agent
# WF_MODEL_STRONG=opus        # reviewer workers (route reviewer) and the one root-cause subagent of a stuck lead
# WF_MODEL_FAST=haiku         # mechanical subagents: rg audits, copy sweeps, PR-body checks

# --- Orchestration ---
# WF_MAX_WORKERS=3            # concurrent workers in a Run
# WF_DIGEST_CAP=2h            # the oldest unannounced decision request waits at most this long for the digest
# WF_NO_WAIT_CI=0             # 1 = merge prep does not wait for pending checks (a failed check still blocks)

# --- Comments and logs ---
# WF_COMMENT_CAP=1500         # visible characters per agent issue comment (decide.sh check, guard.sh)
# WF_ISSUE_LOG_DIR="$HOME/.claude/issue-logs"   # per-issue coordination logs, outside every work tree

# --- Recorded by install.sh: rerun install.sh to change them ---
