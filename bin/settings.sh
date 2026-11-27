#!/usr/bin/env bash
# Show the agent-workflow settings as the scripts resolve them in this checkout: built-in defaults, then the global
# file (~/.claude/agent-workflow-settings.sh), then .claude/issue-workflow.sh; WF_COMMENT_CAP and WF_ISSUE_LOG_DIR
# from the environment win over both.
#
#   settings.sh show         every setting as NAME=value (source), source = default | global | repo | env
#   settings.sh get <NAME>   the resolved value only (arrays space-joined); exit 1 for an unknown name
#   settings.sh path         the global and repo file and whether each exists
# Exit 64: usage.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"

value() { # value <NAME>: arrays as (a b), scalars as is
  if declare -p "$1" 2>/dev/null | grep -q '^declare -a'; then
    local -a a; eval "a=(\"\${$1[@]+\"\${$1[@]}\"}\")"
    echo "(${a[*]+${a[*]}})"
  else
    echo "${!1-}"
  fi
}

layer() { # layer <0|1|2>: print NAME<TAB>value after defaults (0), + global (1), + repo (2), no env
  (
    for v in $WF_ENV_SETTINGS; do unset "$v"; done
    wf_root; wf_defaults
    [ "$1" -ge 1 ] && wf_source "$(wf_global_settings)" 2>/dev/null
    [ "$1" -ge 2 ] && wf_source "$ROOT/.claude/issue-workflow.sh" 2>/dev/null
    for v in $WF_SETTINGS; do printf '%s\t%s\n' "$v" "$(value "$v")"; done
  )
}

case "${1:-}" in
  get)
    [ -n "${2:-}" ] || { echo "usage: settings.sh get <NAME>" >&2; exit 64; }
    case " $WF_SETTINGS " in *" $2 "*) ;; *) echo "settings.sh: unknown setting $2" >&2; exit 1 ;; esac
    wf_load
    v=$(value "$2"); case "$v" in "("*")") v=${v#(}; v=${v%)} ;; esac
    echo "$v"
    ;;
  show)
    wf_load
    d=$(layer 0); g=$(layer 1); r=$(layer 2)
    for v in $WF_SETTINGS; do
      now=$(value "$v")
      src=default
      [ "$(printf '%s\n' "$g" | grep "^$v	")" = "$(printf '%s\n' "$d" | grep "^$v	")" ] || src=global
      [ "$(printf '%s\n' "$r" | grep "^$v	")" = "$(printf '%s\n' "$g" | grep "^$v	")" ] || src=repo
      case " $WF_ENV_SETTINGS " in *" $v "*) [ "$(printf '%s\n' "$r" | grep "^$v	" | cut -f2-)" = "$now" ] || src=env ;; esac
      printf '%s=%s  (%s)\n' "$v" "$now" "$src"
    done
    ;;
  path)
    wf_root
    for f in "global:$(wf_global_settings)" "repo:$ROOT/.claude/issue-workflow.sh"; do
      p=${f#*:}; [ -f "$p" ] && e=present || e=absent
      echo "${f%%:*}: $p ($e)"
    done
    ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
esac
