# Shared helpers for the agent-workflow scripts in bin/ and the skills (sourced, bash 3.2 compatible).
# Settings: built-in defaults, then the global file (wf_global_settings; template reference/global-settings.sh), then
# <repo>/.claude/issue-workflow.sh (template: reference/project-config.sh). settings.sh shows the result.

wf_root() { ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$PWD; }

# Every setting settings.sh reports, in its order. Any of them may go in the global file or the repo config.
WF_SETTINGS="WF_MODEL_DEFAULT WF_MODEL_STRONG WF_MODEL_FAST WF_MODEL_HEAVY WF_MAX_WORKERS WF_DIGEST_CAP WF_COMMENT_CAP WF_ISSUE_LOG_DIR WF_NO_WAIT_CI WF_PORTS WF_PROTO_PORTS WF_RISK_GLOBS WF_IGNORE_GLOBS WF_REVIEW_LINES WF_HOLD_LABELS WF_PHASE_LABELS WF_PR_ATTRIBUTION WF_REQUIRED_CHECKS WF_CHECKS_TSV WF_INSTALL_GLOBAL_RULES WF_INSTALL_DEV WF_INSTALL_PROTO_AGENT WF_INSTALLED_REV"
WF_ENV_SETTINGS="WF_COMMENT_CAP WF_ISSUE_LOG_DIR WF_PORTS WF_PROTO_PORTS" # an exported value wins over both files (WF_REPO is read where used)

wf_global_settings() { # the global settings file (template: reference/global-settings.sh)
  echo "${WF_GLOBAL_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agent-workflow-settings.sh}"
}

wf_defaults() {
  WF_MODEL_DEFAULT=sonnet
  WF_MODEL_STRONG=opus
  WF_MODEL_FAST=haiku
  WF_MODEL_HEAVY=claude-fable-5-2
  WF_MAX_WORKERS=3
  WF_DIGEST_CAP=2h
  WF_COMMENT_CAP=1500
  WF_ISSUE_LOG_DIR="$HOME/.claude/issue-logs"
  WF_NO_WAIT_CI=0
  WF_PORTS=3101-3105
  WF_PROTO_PORTS=3111-3119
  WF_RISK_GLOBS=()
  WF_IGNORE_GLOBS=(package-lock.json)
  WF_REVIEW_LINES=400
  WF_HOLD_LABELS="on-hold-after-spec do-not-merge"
  WF_PHASE_LABELS=on
  WF_PR_ATTRIBUTION=on
  WF_REQUIRED_CHECKS=""
  WF_CHECKS_TSV=""
  WF_INSTALL_GLOBAL_RULES=off
  WF_INSTALL_DEV=0
  WF_INSTALL_PROTO_AGENT=0
  WF_INSTALLED_REV=""
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

wf_seconds() { # wf_seconds <2h | 90m | 300s | 300>: seconds; fails (quietly) on anything else, 1h30m included
  local n=${1%[hms]}
  case "$n" in "" | *[!0-9]*) return 1 ;; esac
  case "$1" in
    *h) echo $((10#$n * 3600)) ;;
    *m) echo $((10#$n * 60)) ;;
    *) echo $((10#$n)) ;;
  esac
}

# Supported tool versions, the one place they are written down (docs/releasing.md says when they change).
# ORCA_MIN: below it install.sh --check and the /aw-coordinate preflight warn (they never block).
# ORCA_TESTED: the Orca version the workflow was last reviewed against, read from the snapshot /aw-orca-review
# commits (empty when the file cannot be reached, e.g. through an old compat/ script path).
# GH_MIN: the gh release that added `--attach` to `gh issue comment` (screenshots in Design rounds and Look comments).
ORCA_MIN=1.4.269
GH_MIN=2.99.0
ORCA_TESTED=""
case "${BASH_SOURCE[0]}" in */*) _wf_dir=${BASH_SOURCE[0]%/*} ;; *) _wf_dir=. ;; esac
{ read -r ORCA_TESTED <"$_wf_dir/../skills/aw-orca-review/snapshot/version"; } 2>/dev/null || :
unset _wf_dir

wf_version_lt() { # wf_version_lt <a> <b>: 0 when the dotted numeric version a is lower than b (a missing part counts as 0)
  local IFS=. i x y
  local -a a b
  # shellcheck disable=SC2206
  a=($1) b=($2)
  for i in 0 1 2 3; do
    x=${a[$i]:-0} y=${b[$i]:-0}
    if [ "$((10#$x))" -lt "$((10#$y))" ]; then return 0; fi
    if [ "$((10#$x))" -gt "$((10#$y))" ]; then return 1; fi
  done
  return 1
}

wf_tool_version() { # wf_tool_version <tool>: the first x.y[.z] of `<tool> --version`; nothing when the tool is missing or prints none
  local out re='[0-9]+(\.[0-9]+)+'
  command -v "$1" >/dev/null 2>&1 || return 0
  out=$("$1" --version 2>/dev/null) || :
  if [[ $out =~ $re ]]; then echo "${BASH_REMATCH[0]}"; fi
  return 0
}

wf_orca_note() { # one line when the installed Orca is older than ORCA_MIN; nothing otherwise (no orca, no readable version)
  local v
  v=$(wf_tool_version orca)
  [ -n "$v" ] || return 0
  wf_version_lt "$v" "$ORCA_MIN" || return 0
  echo "Orca $v is older than the supported minimum $ORCA_MIN (tested with ${ORCA_TESTED:-a newer version}): update Orca, /aw-coordinate relies on commands and messages of $ORCA_MIN."
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
