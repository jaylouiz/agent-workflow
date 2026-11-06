#!/usr/bin/env bash
# Lists where the workflow depends on the Orca CLI.
#   touchpoints.sh commands    one real `orca <group> <command>` per line (each verified with --help)
#   touchpoints.sh locations   file:line of every `orca …` mention (snapshot and this skill excluded)
# Scanned: this repo's skills/ and reference/, plus the .claude dir of every checkout next to this one (hooks, rules, skills,
# issue-workflow.*). Extra dirs: ORCA_TOUCHPOINT_DIRS (colon-separated).
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$DIR/../.." && pwd)

dirs=("$ROOT/skills" "$ROOT/reference")
for d in "$(dirname "$ROOT")"/*/.claude; do [ -d "$d" ] && dirs+=("$d"); done
IFS=: read -r -a extra <<<"${ORCA_TOUCHPOINT_DIRS:-}"
for d in ${extra[@]+"${extra[@]}"}; do [ -n "$d" ] && [ -d "$d" ] && dirs+=("$d"); done

scan() { # every line naming `orca <word>` (grep -I skips binaries)
  grep -rInE '(^|[^a-z_/-])orca [a-z][a-z-]+' "${dirs[@]}" 2>/dev/null \
    | grep -v -e "$DIR/" -e '/settings.local.json:' -e '/worktrees/' -e '/.DS_Store'
}

case "${1:-}" in
  locations) scan | cut -c1-220 ;;
  commands)
    # Each candidate `orca g [c]` is classified by what `orca … --help` prints: its Usage line (real), "Unknown command"
    # (prose that merely looks like a command: dropped) or anything else (Orca not ready, help failed): an error, never a
    # silent drop. The list is printed only when complete, so a caller never works on a partial one.
    helpclass() { # helpclass <expected usage> <orca args…>: prints ok | unknown | broken
      local want=$1 out; shift
      out=$(orca "$@" --help 2>&1)
      if printf '%s\n' "$out" | head -3 | grep -q "^Usage: $want"; then echo ok
      elif printf '%s\n' "$out" | grep -q '^Unknown command'; then echo unknown
      else echo broken; fi
    }
    list="" broken=""
    while read -r _ g c; do
      [ -n "${g:-}" ] || continue
      if [ -n "${c:-}" ]; then
        case $(helpclass "orca $g $c" "$g" "$c") in
          ok) list+="orca $g $c"$'\n'; continue ;;
          broken) broken+="orca $g $c "; continue ;;
        esac
      fi
      case $(helpclass "orca $g" "$g") in # not a command of its own: is the group one?
        ok) list+="orca $g"$'\n' ;;
        broken) broken+="orca $g " ;;
      esac
    done < <(scan | grep -oE '(^|[^a-z_/-])orca [a-z][a-z-]+( [a-z][a-z-]+)?' | sed -E 's/^[^o]*orca/orca/' | sort -u)
    if [ -n "$broken" ]; then
      echo "touchpoints.sh: \`orca <cmd> --help\` failed or printed no Usage line (Orca not ready?) for: ${broken% }; command list incomplete, not used" >&2
      exit 1
    fi
    printf '%s' "$list" | sort -u ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
