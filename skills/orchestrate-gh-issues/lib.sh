# Shared helpers for the orchestrate-gh-issues scripts (sourced, bash 3.2 compatible).
# Settings: built-in defaults, then the global file (wf_global_settings; template reference/global-settings.sh), then
# <repo>/.claude/issue-workflow.sh (template: reference/project-config.sh). settings.sh shows the result.

wf_root() { ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$PWD; }

# Every setting settings.sh reports, in its order. Any of them may go in the global file or the repo config.
WF_SETTINGS="WF_MODEL_DEFAULT WF_MODEL_STRONG WF_MODEL_FAST WF_MAX_WORKERS WF_DIGEST_CAP WF_COMMENT_CAP WF_ISSUE_LOG_DIR WF_NO_WAIT_CI WF_PORTS WF_RISK_GLOBS WF_IGNORE_GLOBS WF_REVIEW_LINES WF_HOLD_LABELS WF_REQUIRED_CHECKS WF_CHECKS_TSV WF_INSTALL_GLOBAL_RULES WF_INSTALL_DEV"
WF_ENV_SETTINGS="WF_COMMENT_CAP WF_ISSUE_LOG_DIR" # an exported value wins over both files (WF_REPO is read where used)

wf_global_settings() { # the global settings file (template: reference/global-settings.sh)
  echo "${WF_GLOBAL_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-workflow-settings.sh}"
}

wf_defaults() {
  WF_MODEL_DEFAULT=sonnet
  WF_MODEL_STRONG=opus
  WF_MODEL_FAST=haiku
  WF_MAX_WORKERS=3
  WF_DIGEST_CAP=2h
  WF_COMMENT_CAP=1500
  WF_ISSUE_LOG_DIR="$HOME/.claude/issue-logs"
  WF_NO_WAIT_CI=0
  WF_PORTS=3101-3105
  WF_RISK_GLOBS=()
  WF_IGNORE_GLOBS=(package-lock.json)
  WF_REVIEW_LINES=400
  WF_HOLD_LABELS="on-hold-after-spec do-not-merge"
  WF_REQUIRED_CHECKS=""
  WF_CHECKS_TSV=""
  WF_INSTALL_GLOBAL_RULES=off
  WF_INSTALL_DEV=0
}

wf_source() { # wf_source <file>: source a settings file with globbing off; a missing file is fine, a broken one warns once
  [ -f "$1" ] || return 0
  # bash 3.2's -n reports some parse errors (an unclosed `(`) and still exits 0: any output counts as a syntax error.
  if ! bash -n "$1" >/dev/null 2>&1 || [ -n "$(bash -n "$1" 2>&1)" ]; then
    echo "agent-workflow: $1: syntax error, not loaded (using the other settings)" >&2
    return 0
  fi
  # Globbing off while sourcing: an unquoted `store/**` must stay a pattern, not expand to files.
  # `|| :` also keeps a failing command in the file (a false last line, a parse error bash -n missed) from ending a
  # caller that runs with set -e (decide.sh, guard.sh through it).
  set -f
  # shellcheck disable=SC1090
  . "$1" || :
  set +f
  return 0
}

wf_load() { # defaults, then the global settings file, then the project's config; exported caps win
  local v saved=""
  wf_root
  for v in $WF_ENV_SETTINGS; do
    [ -n "${!v+x}" ] && saved="$saved $v=$(printf %q "${!v}")"
  done
  wf_defaults
  wf_source "$(wf_global_settings)"
  wf_source "$ROOT/.claude/issue-workflow.sh"
  [ -z "$saved" ] || eval "$saved"
  return 0
}

wf_seconds() { # wf_seconds <2h | 90m | 300s | 300>: seconds; fails on anything else
  case "$1" in
    *[!0-9hms]* | "" | [hms]*) return 1 ;;
    *h) echo $((${1%h} * 3600)) ;;
    *m) echo $((${1%m} * 60)) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}

wf_main_root() { # the main checkout (first worktree), wherever the script runs from
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}'
}

wf_repo_slug() { # owner/repo: $WF_REPO, else the checkout's GitHub origin, else gh; prints nothing and fails when none
  local u
  if [ -n "${WF_REPO:-}" ]; then echo "$WF_REPO"; return 0; fi
  u=$(git remote get-url origin 2>/dev/null) || u=""
  case "$u" in *github.com[:/]*/*) u=${u%/}; u=${u%.git}; echo "${u#*github.com[:/]}"; return 0 ;; esac
  gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null
}

wf_has() { declare -F "$1" >/dev/null; }

wf_run() { # wf_run <fn> [args]: run a project step, or say it does not apply
  local fn=$1; shift
  if wf_has "$fn"; then "$fn" "$@"; else echo "skip: $fn not defined"; fi
}

wf_match() { # wf_match <path> <glob>...: 0 if any glob matches (** = *, so a/** matches a/b/c)
  local path=$1 g; shift
  for g in "$@"; do
    g=${g//\*\*/*}
    # shellcheck disable=SC2053
    [[ $path == $g ]] && return 0
  done
  return 1
}
