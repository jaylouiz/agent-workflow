#!/usr/bin/env bash
# Install agent-workflow into ~/.claude: link every skill under skills/, link this checkout as ~/.claude/agent-workflow
# (the skills read reference/ through it), and register the Orca update check (skills/orca-update-review/check.sh)
# as a global SessionStart hook. Idempotent: rerun after adding, renaming or removing a skill.
#
#   --global-rules   also link global/CLAUDE.md (the author's global rules) as ~/.claude/CLAUDE.md. Opt-in; an
#                    existing link into this checkout is kept up to date without the flag.
#
# A real file or directory where a link belongs is left alone and reported: the script never overwrites.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
warn() { echo "agent-workflow: $*" >&2; }
GLOBAL_RULES=0
for arg in "$@"; do
  case $arg in
    --global-rules) GLOBAL_RULES=1 ;;
    *) warn "unknown option: $arg"; exit 2 ;;
  esac
done

link() { # link <target> <path>: create or repoint a symlink
  local target=$1 path=$2
  if [ -L "$path" ]; then
    [ "$(readlink "$path")" = "$target" ] || ln -sfn "$target" "$path"
  elif [ -e "$path" ]; then
    warn "$path exists and is not a symlink; left as is"
  else
    ln -s "$target" "$path"
  fi
}

mkdir -p "$CLAUDE_DIR/skills"
for skill in "$ROOT"/skills/*/; do
  skill=${skill%/}
  link "$skill" "$CLAUDE_DIR/skills/$(basename "$skill")"
done
# Drop links to skills that were removed or renamed here.
for path in "$CLAUDE_DIR"/skills/*; do
  [ -L "$path" ] || continue
  case "$(readlink "$path")" in "$ROOT"/skills/*) [ -e "$path" ] || rm "$path" ;; esac
done
link "$ROOT" "$CLAUDE_DIR/agent-workflow"
case "$(readlink "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null)" in "$ROOT"/*) GLOBAL_RULES=1 ;; esac
if [ "$GLOBAL_RULES" = 1 ]; then
  link "$ROOT/global/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
else
  echo "agent-workflow: global rules not linked (opt in with --global-rules, see README)"
fi

# Global SessionStart hook: notice a new Orca version the workflow was not reviewed against (orca-update-review).
# Added once, next to whatever else (e.g. Orca's own hooks) is registered; a backup is kept as settings.json.bak.
SETTINGS="$CLAUDE_DIR/settings.json"
CHECK="$CLAUDE_DIR/skills/orca-update-review/check.sh"
if ! command -v jq >/dev/null 2>&1; then
  warn "jq missing: Orca update check not registered"
elif [ -f "$SETTINGS" ] && ! grep -q 'orca-update-review/check.sh' "$SETTINGS"; then
  tmp=$(mktemp)
  if jq --arg c "bash \"$CHECK\"" \
       '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher": "startup|clear", "hooks": [{"type": "command", "command": $c, "timeout": 30}]}])' \
       "$SETTINGS" >"$tmp" && [ -s "$tmp" ]; then
    cp "$SETTINGS" "$SETTINGS.bak" && cat "$tmp" >"$SETTINGS" && echo "agent-workflow: registered the Orca update check (SessionStart)"
  else
    warn "could not update $SETTINGS; Orca update check not registered"
  fi
  rm -f "$tmp"
fi
