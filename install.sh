#!/usr/bin/env bash
# Install agent-workflow into ~/.claude (or $CLAUDE_CONFIG_DIR): check the requirements, link every skill under skills/
# and this checkout as ~/.claude/agent-workflow (the skills read reference/ through it), record the global choices in
# ~/.claude/agent-workflow-settings.sh and print the next step. Idempotent: rerun after adding, renaming or removing a
# skill. In a terminal it asks; without one (or with --yes) it keeps every recorded choice and uses defaults otherwise.
#
#   --yes                    no questions: recorded choices, else defaults
#   --models <preset>        balanced (sonnet/opus/haiku, default) | quality (opus/opus/sonnet) | budget (sonnet/sonnet/haiku)
#                            | custom (asks; terminal only). Order: default / strong / fast tier.
#   --global-rules           use the author's global rules (global/CLAUDE.md): a link when there is no ~/.claude/CLAUDE.md,
#                            else one import line appended to it. --no-global-rules removes either.
#   --dev / --no-dev         maintainer only: link /orca-update-review and register its SessionStart hook (Orca update check)
#   --check                  only check the requirements; exit 1 when a required tool is missing
#   --uninstall              remove the links, the dev hook and the global rules; keeps the settings file
#
# A real file or directory where a link belongs is left alone and reported: the script never overwrites.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# shellcheck source=skills/orchestrate-gh-issues/lib.sh
. "$ROOT/skills/orchestrate-gh-issues/lib.sh"
SETTINGS_FILE=$(wf_global_settings)
JSON="$CLAUDE_DIR/settings.json"
CHECK="$CLAUDE_DIR/skills/orca-update-review/check.sh"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
case "$CLAUDE_DIR/" in "$HOME"/*) IMPORT="@~${CLAUDE_DIR#"$HOME"}/agent-workflow/global/CLAUDE.md" ;; *) IMPORT="@$CLAUDE_DIR/agent-workflow/global/CLAUDE.md" ;; esac

warn() { echo "agent-workflow: $*" >&2; }
say() { echo "$*"; }
CHANGES=""
changed() { CHANGES="$CHANGES
  - $*"; }

YES=0 MODELS="" RULES="" DEV="" MODE=install
while [ $# -gt 0 ]; do
  case $1 in
    --yes) YES=1 ;;
    --models) MODELS=${2:-}; shift
      case $MODELS in balanced | quality | budget | custom) ;; *) warn "--models: balanced, quality, budget or custom (got '$MODELS')"; exit 2 ;; esac ;;
    --global-rules) RULES=on ;;
    --no-global-rules) RULES=off ;;
    --dev) DEV=1 ;;
    --no-dev) DEV=0 ;;
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    *) warn "unknown option: $1 (see the header of install.sh)"; exit 2 ;;
  esac
  shift
done
INTERACTIVE=0
if [ "$YES" = 0 ] && { [ "${AW_INSTALL_INTERACTIVE:-0}" = 1 ] || { [ -t 0 ] && [ -t 1 ]; }; }; then INTERACTIVE=1; fi
[ "$MODELS" != custom ] || [ "$INTERACTIVE" = 1 ] || { warn "--models custom asks for the three models: run it in a terminal without --yes"; exit 2; }

ask() { # ask <question> <default>: the answer (empty = default); the prompt goes to stderr
  local a
  printf '%s [%s] ' "$1" "$2" >&2
  IFS= read -r a || a=""
  echo "${a:-$2}"
}

# --- requirements ---
MISSING="" REQ_OK=1
need() { # need <tool> <required|optional> <hint>
  if command -v "$1" >/dev/null 2>&1; then
    say "  ok       $1"
  else
    say "  missing  $1 ($2): $3"; MISSING="$MISSING $1"
    [ "$2" = optional ] || REQ_OK=0
  fi
}
requirements() {
  say "Requirements"
  need git required "https://git-scm.com"
  need jq required "brew install jq"
  need python3 required "brew install python"
  need gh required "brew install gh, then gh auth login"
  need claude required "https://claude.com/claude-code"
  need orca optional "only for /orchestrate-gh-issues: https://github.com/stablyai/orca"
  if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then say "  warn     gh is not logged in: gh auth login"; fi
}

# --- links ---
link() { # link <target> <path>: create or repoint a symlink
  local target=$1 path=$2
  if [ -L "$path" ]; then
    [ "$(readlink "$path")" = "$target" ] || { ln -sfn "$target" "$path"; changed "relinked $path"; }
  elif [ -e "$path" ]; then
    warn "$path exists and is not a symlink; left as is"
  else
    ln -s "$target" "$path"; changed "linked $path"
  fi
}
unlink_ours() { # unlink_ours <path>: remove a symlink into this checkout
  case "$(readlink "$1" 2>/dev/null)" in "$ROOT" | "$ROOT"/*) rm "$1"; changed "removed $1" ;; esac
}

# --- recorded choices in the global settings file ---
recorded() { [ -f "$SETTINGS_FILE" ] && sed -n "s/^$1=//p" "$SETTINGS_FILE" | tail -1 | tr -d "\"'"; }
set_setting() { # set_setting KEY VALUE: replace the active line, else the commented default, else append
  [ -f "$SETTINGS_FILE" ] || { mkdir -p "$(dirname "$SETTINGS_FILE")"; cp "$ROOT/reference/global-settings.sh" "$SETTINGS_FILE"; changed "created $SETTINGS_FILE"; }
  [ "$(recorded "$1")" = "$2" ] && return 0
  python3 -I - "$SETTINGS_FILE" "$1" "$2" <<'PY'
import re, sys
path, key, val = sys.argv[1:]
lines = open(path, encoding="utf-8").read().split("\n")
active = [i for i, l in enumerate(lines) if l.startswith(key + "=")]
comment = [i for i, l in enumerate(lines) if re.match(r"#\s*" + re.escape(key) + "=", l)]
new = key + "=" + val
if active:
    lines[active[-1]] = new
elif comment:
    lines[comment[0]] = new
else:
    if lines and lines[-1] == "":
        lines.insert(len(lines) - 1, new)
    else:
        lines.append(new)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

# --- the dev hook (Orca update check) ---
has_hook() { [ -f "$JSON" ] && grep -q 'orca-update-review/check.sh' "$JSON"; }
json_edit() { # json_edit <jq filter> [args]: rewrite settings.json, backup first
  local tmp; tmp=$(mktemp)
  if jq "$@" "$JSON" >"$tmp" && [ -s "$tmp" ]; then
    cp "$JSON" "$JSON.bak" && cat "$tmp" >"$JSON"; rm -f "$tmp"
  else
    rm -f "$tmp"; warn "could not update $JSON"; return 1
  fi
}
add_hook() {
  [ -f "$JSON" ] || echo '{}' >"$JSON"
  has_hook && return 0
  command -v jq >/dev/null 2>&1 || { warn "jq missing: Orca update check not registered"; return 0; }
  json_edit --arg c "bash \"$CHECK\"" \
    '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher": "startup|clear", "hooks": [{"type": "command", "command": $c, "timeout": 30}]}])' \
    && changed "registered the Orca update check (SessionStart)"
}
remove_hook() {
  has_hook || return 0
  command -v jq >/dev/null 2>&1 || { warn "jq missing: Orca update check left in $JSON"; return 0; }
  json_edit '.hooks.SessionStart |= map(select(all(.hooks[]?; (.command // "") | contains("orca-update-review/check.sh") | not)))
             | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end' \
    && changed "removed the Orca update check"
}

# --- global rules ---
rules_state() { # link | import | off, from what is on disk
  case "$(readlink "$CLAUDE_MD" 2>/dev/null)" in "$ROOT"/*) echo link; return ;; esac
  if [ -f "$CLAUDE_MD" ] && grep -qxF "$IMPORT" "$CLAUDE_MD"; then echo import; else echo off; fi
}
backup_md() { cp "$CLAUDE_MD" "$CLAUDE_MD.bak.$(date +%Y%m%d-%H%M%S)"; }
rules_on() {
  case "$(rules_state)" in link | import) return 0 ;; esac
  if [ ! -e "$CLAUDE_MD" ] && [ ! -L "$CLAUDE_MD" ]; then
    ln -s "$ROOT/global/CLAUDE.md" "$CLAUDE_MD"; changed "linked $CLAUDE_MD to the global rules"
  elif [ -L "$CLAUDE_MD" ]; then
    warn "$CLAUDE_MD is a link elsewhere; add this line to the file it points to: $IMPORT"
  else
    backup_md; printf '\n%s\n' "$IMPORT" >>"$CLAUDE_MD"; changed "added the global rules import to $CLAUDE_MD"
  fi
}
rules_off() {
  case "$(rules_state)" in
    link) rm "$CLAUDE_MD"; changed "removed the $CLAUDE_MD link" ;;
    import) backup_md; grep -vxF "$IMPORT" "$CLAUDE_MD" >"$CLAUDE_MD.tmp"; mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"; changed "removed the global rules import from $CLAUDE_MD" ;;
  esac
}

# --- run ---
if [ "$MODE" = check ]; then requirements; [ "$REQ_OK" = 1 ]; exit; fi

if [ "$MODE" = uninstall ]; then
  rules_off; remove_hook
  for path in "$CLAUDE_DIR"/skills/*; do [ -L "$path" ] && unlink_ours "$path"; done
  unlink_ours "$CLAUDE_DIR/agent-workflow"
  say "agent-workflow uninstalled:${CHANGES:- nothing to remove}"
  [ -f "$SETTINGS_FILE" ] && say "kept $SETTINGS_FILE (your settings; delete it by hand if you want)"
  exit 0
fi

say "agent-workflow setup ($ROOT -> $CLAUDE_DIR)"; say ""
requirements; say ""

# Choices: flag, else the recorded one, else what is on disk (machines installed before choices were recorded), else default.
[ -n "$DEV" ] || DEV=$(recorded WF_INSTALL_DEV)
[ -n "$DEV" ] || { has_hook && DEV=1 || DEV=0; }
if [ -z "$RULES" ]; then
  r=$(recorded WF_INSTALL_GLOBAL_RULES); [ -n "$r" ] || r=$(rules_state)
  [ "$r" = off ] && RULES=off || RULES=on
fi

if [ "$INTERACTIVE" = 1 ]; then
  cur=""; [ -n "$(recorded WF_MODEL_DEFAULT)" ] && cur=", now $(recorded WF_MODEL_DEFAULT)/$(recorded WF_MODEL_STRONG)/$(recorded WF_MODEL_FAST)"
  say "Models per tier (default / strong / fast$cur):"
  say "  balanced = sonnet/opus/haiku, quality = opus/opus/sonnet, budget = sonnet/sonnet/haiku, custom = you name them"
  if [ -z "$MODELS" ]; then
    if [ -n "$(recorded WF_MODEL_DEFAULT)" ]; then def=keep; else def=balanced; fi
    MODELS=$(ask "Models ($([ "$def" = keep ] && printf 'keep, ')balanced, quality, budget, custom)" "$def")
    [ "$MODELS" = keep ] && MODELS=""
  fi
  say ""
  say "Global rules (global/CLAUDE.md, the author's habits for every project):"
  grep '^## ' "$ROOT/global/CLAUDE.md" | sed 's/^## /  - /'
  d=n; [ "$RULES" = on ] && d=y
  case "$(ask "Use them? (y/n)" "$d")" in y* | Y*) RULES=on ;; *) RULES=off ;; esac
  say ""
fi

case $MODELS in
  balanced) m="sonnet opus haiku" ;;
  quality) m="opus opus sonnet" ;;
  budget) m="sonnet sonnet haiku" ;;
  custom) m="$(ask "Default tier" "$(recorded WF_MODEL_DEFAULT || echo sonnet)") $(ask "Strong tier" "$(recorded WF_MODEL_STRONG || echo opus)") $(ask "Fast tier" "$(recorded WF_MODEL_FAST || echo haiku)")" ;;
  *) m="" ;;
esac
[ -n "$m" ] || [ -n "$(recorded WF_MODEL_DEFAULT)" ] || m="sonnet opus haiku"
if [ -n "$m" ]; then
  set -- $m
  set_setting WF_MODEL_DEFAULT "$1"; set_setting WF_MODEL_STRONG "$2"; set_setting WF_MODEL_FAST "$3"
fi

mkdir -p "$CLAUDE_DIR/skills"
for skill in "$ROOT"/skills/*/; do
  skill=${skill%/}; name=$(basename "$skill")
  if [ "$name" = orca-update-review ] && [ "$DEV" != 1 ]; then unlink_ours "$CLAUDE_DIR/skills/$name"; continue; fi
  link "$skill" "$CLAUDE_DIR/skills/$name"
done
# Drop links to skills that were removed or renamed here.
for path in "$CLAUDE_DIR"/skills/*; do
  [ -L "$path" ] || continue
  case "$(readlink "$path")" in "$ROOT"/skills/*) [ -e "$path" ] || { rm "$path"; changed "removed stale $path"; } ;; esac
done
link "$ROOT" "$CLAUDE_DIR/agent-workflow"

if [ "$DEV" = 1 ]; then add_hook; else remove_hook; fi
if [ "$RULES" = on ]; then rules_on; else rules_off; fi
set_setting WF_INSTALL_DEV "$DEV"
set_setting WF_INSTALL_GLOBAL_RULES "$(rules_state)"

say "agent-workflow installed.${CHANGES:- Nothing changed.}"
[ -z "$MISSING" ] || say "Missing tools:$MISSING (see Requirements above)"
say "Settings: $SETTINGS_FILE (bash $CLAUDE_DIR/skills/orchestrate-gh-issues/settings.sh show)"
say ""
say "Next: cd <your repo> && claude, then run /init-issue-workflow to set the repo up."
