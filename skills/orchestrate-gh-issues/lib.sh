# Shared helpers for the orchestrate-gh-issues scripts (sourced, bash 3.2 compatible).
# Project facts come from <repo>/.claude/issue-workflow.sh (template: reference/project-config.sh).

wf_root() { ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$PWD; }

wf_load() { # defaults, then the project's config
  wf_root
  WF_PORTS=3101-3105
  WF_MAX_WORKERS=3
  WF_REVIEW_LINES=400
  WF_RISK_GLOBS=()
  WF_IGNORE_GLOBS=(package-lock.json)
  WF_HOLD_LABELS="on-hold-after-spec do-not-merge"
  WF_CHECKS_TSV=""
  WF_REQUIRED_CHECKS=""
  # Globbing off while sourcing: an unquoted `store/**` in the config must stay a pattern, not expand to files.
  set -f
  # shellcheck disable=SC1091
  [ -f "$ROOT/.claude/issue-workflow.sh" ] && . "$ROOT/.claude/issue-workflow.sh"
  set +f
  return 0
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
