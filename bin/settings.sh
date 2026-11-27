#!/usr/bin/env bash
# Show the agent-workflow settings as the scripts resolve them in this checkout: built-in defaults, then the global
# file (~/.claude/agent-workflow-settings.sh), then .claude/issue-workflow.sh; WF_COMMENT_CAP and WF_ISSUE_LOG_DIR
# from the environment win over both.
#
#   settings.sh show         every setting as NAME=value (source), source = default | global | repo | env
#   settings.sh get <NAME>   the resolved value only (arrays space-joined); exit 1 for an unknown name
#   settings.sh path         the global and repo file and whether each exists
#   settings.sh profile [<file>]  check the project profile (default .claude/issue-workflow.md): one line when it is older
#                            than the template (`<!-- profile-template: N -->` in reference/project-profile.md), and over
#                            15 KB a warning with the section sizes (over 20 KB: split now). Silent when fine; exit 0.
# `show` ends with the same check. Exit 64: usage.
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

profile_check() { # profile_check [<file>]: see the header
  wf_root
  local f=${1:-$ROOT/.claude/issue-workflow.md} tpl="$DIR/../reference/project-profile.md" have want size
  [ -f "$f" ] || return 0
  want=$(sed -n 's/.*<!-- profile-template: \([0-9][0-9]*\) -->.*/\1/p' "$tpl" 2>/dev/null | head -1)
  have=$(sed -n 's/.*<!-- profile-template: \([0-9][0-9]*\) -->.*/\1/p' "$f" | head -1)
  if [ -n "$want" ] && [ "${have:-0}" -lt "$want" ]; then
    echo "profile older than the template (${have:-none} < $want): run /aw-setup update"
  fi
  size=$(wc -c <"$f" | tr -d ' ')
  if [ "$size" -gt 15360 ]; then
    if [ "$size" -gt 20480 ]; then echo "profile over the 20 KB limit ($size bytes): split it now (/aw-setup update, retro)"
    else echo "profile over the 15 KB budget ($size bytes): consider a split"; fi
    echo "  sections (bytes): $(LC_ALL=C awk '/^## /{if(h!="")printf "%s %d, ",h,n; h=substr($0,4); n=0} {n+=length($0)+1} END{if(h!="")printf "%s %d",h,n}' "$f")"
    echo "  convention: a long section keeps its heading and becomes one line, \`Full text: .claude/issue-workflow/<slug>.md (read when: <stage/step>)\` (reference/project-profile.md)"
  fi
  return 0
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
    profile_check
    ;;
  profile) profile_check "${2:-}" ;;
  path)
    wf_root
    for f in "global:$(wf_global_settings)" "repo:$ROOT/.claude/issue-workflow.sh"; do
      p=${f#*:}; [ -f "$p" ] && e=present || e=absent
      echo "${f%%:*}: $p ($e)"
    done
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
esac
