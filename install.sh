#!/usr/bin/env bash
# Install agent-workflow into ~/.claude: check the requirements, link every skill under skills/ and this checkout as
# ~/.claude/agent-workflow (the skills read reference/ and run bin/ through it), record the global choices in
# ~/.claude/agent-workflow-settings.sh and print the next step. Idempotent: rerun after adding, renaming or removing a
# skill. In a terminal it asks; without one (or with --yes) it keeps every recorded choice and uses defaults otherwise.
#
#   --yes                    no questions: recorded choices, else defaults
#   --models <preset>        balanced (sonnet/opus/haiku/claude-fable-5-2, the shipped defaults) | quality
#                            (opus/opus/sonnet/claude-fable-5-2) | budget (sonnet/sonnet/haiku/opus). Order: default / strong / fast / heavy.
#   --model-default|--model-strong|--model-fast|--model-heavy <alias or model ID>
#                            one tier, over the preset. In a terminal it asks every tier no flag set (Enter keeps the
#                            value shown); a tier set before is never changed unless asked or flagged.
#   --global-rules           use the author's global rules (global/CLAUDE.md): a link when there is no ~/.claude/CLAUDE.md,
#                            else one import line appended to it. --no-global-rules removes either.
#   --proto-agent            macOS: a login LaunchAgent runs `proto-serve.sh ensure`, so the prototype previews that wait on a
#                            decision come back after a reboot. --no-proto-agent removes it. Off unless asked for or recorded.
#   --dev / --no-dev         maintainer only: link /aw-orca-review (run by hand after an Orca update)
#   --check                  only check the requirements; exit 1 when a required tool is missing
#   --uninstall              remove the links and the global rules; keeps the settings file
#
# A real file or directory where a link belongs is left alone and reported: the script never overwrites.
# CLAUDE_CONFIG_DIR is not supported: the links follow it, but the hooks, permission patterns and skill paths name
# ~/.claude, so the script warns (also with --check) when it points elsewhere.
# compat/ holds the old script paths (linked next to the skills, no skill) and the skill rename map.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# shellcheck source=bin/lib.sh
. "$ROOT/bin/lib.sh"
SETTINGS_FILE=$(wf_global_settings)
JSON="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
case "$CLAUDE_DIR/" in "$HOME"/*) IMPORT="@~${CLAUDE_DIR#"$HOME"}/agent-workflow/global/CLAUDE.md" ;; *) IMPORT="@$CLAUDE_DIR/agent-workflow/global/CLAUDE.md" ;; esac

warn() { echo "agent-workflow: $*" >&2; }
# The hooks in the skills' frontmatter, the allowed-tools patterns and the paths in the skill text name ~/.claude: with
# another config dir the hook commands do not exist (a non-blocking hook error), so guard.sh is silently off.
config_dir_note() { # prints the warning when CLAUDE_CONFIG_DIR points somewhere other than ~/.claude; else nothing
  local d=${CLAUDE_CONFIG_DIR:-}
  while [ "${d%/}" != "$d" ]; do d=${d%/}; done
  [ -n "$d" ] && [ "$d" != "$HOME/.claude" ] || return 0
  echo "CLAUDE_CONFIG_DIR=$d is not supported: hooks and paths assume ~/.claude, so with this config dir the guard and Stop hooks do not run and the skills' script paths do not resolve. Supported setup: links in ~/.claude (run install.sh without CLAUDE_CONFIG_DIR)."
}
say() { echo "$*"; }
CHANGES=""
changed() { CHANGES="$CHANGES
  - $*"; }

MODEL_RE='^[][A-Za-z0-9._:@/-]+$' # a model alias or ID, e.g. opus, opus[1m], claude-fable-5-2
YES=0 MODELS="" RULES="" DEV="" PROTO_AGENT="" MODE=install M_DEFAULT="" M_STRONG="" M_FAST="" M_HEAVY=""
while [ $# -gt 0 ]; do
  case $1 in
    --yes) YES=1 ;;
    --models) MODELS=${2:-}; shift
      case $MODELS in balanced | quality | budget) ;; *) warn "--models: balanced, quality or budget (got '$MODELS')"; exit 2 ;; esac ;;
    --model-default | --model-strong | --model-fast | --model-heavy)
      t=$(echo "${1#--model-}" | tr a-z A-Z); v=${2:-}; shift
      [[ $v =~ $MODEL_RE ]] || { warn "$1 needs a model alias or ID (got '$v')"; exit 2; }
      eval "M_$t=\$v" ;;
    --global-rules) RULES=on ;;
    --no-global-rules) RULES=off ;;
    --proto-agent) PROTO_AGENT=1 ;;
    --no-proto-agent) PROTO_AGENT=0 ;;
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
  need orca optional "only for /aw-coordinate: https://github.com/stablyai/orca"
  need lsof optional "prototype preview servers: brew install lsof or sudo apt install lsof"
  if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then say "  warn     gh is not logged in: gh auth login"; fi
  local note; note=$(config_dir_note); [ -z "$note" ] || say "  warn     $note"
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
recorded() { # the active value of KEY, without quotes or a trailing comment; empty when unset
  [ -f "$SETTINGS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$SETTINGS_FILE" | tail -1 | sed 's/[[:space:]]*#.*$//' | tr -d "\"'"
}
rec_or() { local r; r=$(recorded "$1"); echo "${r:-$2}"; } # rec_or KEY DEFAULT
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

# --- skill renames (compat/renames: "<old> <new>" per line) ---
renames() { grep -v -e '^#' -e '^[[:space:]]*$' "$ROOT/compat/renames" 2>/dev/null; }
old_name() { renames | awk -v n="$1" '$2 == n { print $1 }'; } # old_name <new name>
is_old_name() { renames | awk -v n="$1" '$1 == n { f = 1 } END { exit !f }'; }
RENAMED=0 # 1 once this run removed or repointed a link under an old skill name: the rename map is printed

# --- the retired Orca update check hook: older installs registered it in settings.json (under the skill's old name);
# every run takes it out ---
OLD_REVIEW=$(old_name aw-orca-review); OLD_HOOK="$OLD_REVIEW/check.sh"
has_hook() { [ -n "$OLD_REVIEW" ] && [ -f "$JSON" ] && grep -qF "$OLD_HOOK" "$JSON"; } # no old name known: never match a bare check.sh
json_edit() { # json_edit <jq filter> [args]: rewrite settings.json, backup first
  local tmp; tmp=$(mktemp)
  if jq "$@" "$JSON" >"$tmp" && [ -s "$tmp" ]; then
    cp "$JSON" "$JSON.bak" && cat "$tmp" >"$JSON"; rm -f "$tmp"
  else
    rm -f "$tmp"; warn "could not update $JSON"; return 1
  fi
}
remove_hook() {
  has_hook || return 0
  command -v jq >/dev/null 2>&1 || { warn "jq missing: Orca update check left in $JSON"; return 0; }
  json_edit --arg hook "$OLD_HOOK" '.hooks.SessionStart |= map(select(all(.hooks[]?; (.command // "") | contains($hook) | not)))
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

# Login LaunchAgent for `proto-serve.sh ensure` (macOS). launchctl is skipped when AW_LAUNCHAGENTS_DIR redirects the plist.
AGENT_LABEL=com.agent-workflow.proto-serve
AGENT_DIR=${AW_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}
AGENT_PLIST=$AGENT_DIR/$AGENT_LABEL.plist
agent_launchctl() { [ -n "${AW_LAUNCHAGENTS_DIR:-}" ] || launchctl "$@" 2>/dev/null || :; }
agent_on() {
  local want
  want="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
<key>Label</key><string>$AGENT_LABEL</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>-lc</string><string>bash \"$CLAUDE_DIR/agent-workflow/bin/proto-serve.sh\" ensure</string></array>
<key>RunAtLoad</key><true/>
<key>AbandonProcessGroup</key><true/>
<key>StandardOutPath</key><string>$CLAUDE_DIR/proto-serve-agent.log</string>
<key>StandardErrorPath</key><string>$CLAUDE_DIR/proto-serve-agent.log</string>
</dict></plist>"
  [ "$(cat "$AGENT_PLIST" 2>/dev/null)" = "$want" ] && return 0
  mkdir -p "$AGENT_DIR"; printf '%s\n' "$want" >"$AGENT_PLIST"
  agent_launchctl bootout "gui/$(id -u)/$AGENT_LABEL"; agent_launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  changed "login LaunchAgent $AGENT_PLIST (proto-serve.sh ensure)"
}
agent_off() {
  [ -e "$AGENT_PLIST" ] || return 0
  agent_launchctl bootout "gui/$(id -u)/$AGENT_LABEL"; rm -f "$AGENT_PLIST"; changed "removed the login LaunchAgent $AGENT_PLIST"
}

# --- run ---
if [ "$MODE" = check ]; then requirements; [ "$REQ_OK" = 1 ]; exit; fi

if [ "$MODE" = uninstall ]; then
  rules_off; remove_hook; agent_off
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
[ -n "$DEV" ] || { has_hook && DEV=1 || DEV=0; } # a leftover hook marks the maintainer
if [ -z "$RULES" ]; then
  r=$(recorded WF_INSTALL_GLOBAL_RULES); [ -n "$r" ] || r=$(rules_state)
  [ "$r" = off ] && RULES=off || RULES=on
fi

[ -n "$PROTO_AGENT" ] || PROTO_AGENT=$(recorded WF_INSTALL_PROTO_AGENT)
[ -n "$PROTO_AGENT" ] || { [ -e "$AGENT_PLIST" ] && PROTO_AGENT=1 || PROTO_AGENT=0; }

# Model tiers in the order of the presets and the questions; shipped defaults come from lib.sh.
TIERS="DEFAULT STRONG FAST HEAVY"
tier_default() { (wf_defaults; eval "echo \$WF_MODEL_$1"); }
tier_use() {
  case $1 in
    DEFAULT) echo "normal lead, design and fix workers" ;;
    STRONG) echo "coordinators, reviewers" ;;
    FAST) echo "mechanical subagents" ;;
    HEAVY) echo "new features, bigger UI changes, complex technical work; no Fable access: opus" ;;
  esac
}
tier_get() { eval "echo \$M_$1"; }
case $MODELS in
  balanced) p="sonnet opus haiku claude-fable-5-2" ;;
  quality) p="opus opus sonnet claude-fable-5-2" ;;
  budget) p="sonnet sonnet haiku opus" ;;
  *) p="" ;;
esac
if [ -n "$p" ]; then
  # shellcheck disable=SC2086
  set -- $p
  for t in $TIERS; do [ -n "$(tier_get "$t")" ] || eval "M_$t=\$1"; shift; done
fi

if [ "$INTERACTIVE" = 1 ]; then
  say "Models per tier (a Claude Code alias or a full model ID; Enter keeps the value in brackets):"
  for t in $TIERS; do
    [ -z "$(tier_get "$t")" ] || continue
    a=$(ask "  $(echo "$t" | tr A-Z a-z) ($(tier_use "$t"))" "$(rec_or "WF_MODEL_$t" "$(tier_default "$t")")")
    [[ $a =~ $MODEL_RE ]] || { warn "not a model alias or ID: '$a' (nothing changed; run install.sh again)"; exit 2; }
    eval "M_$t=\$a"
  done
  say ""
  say "Global rules (global/CLAUDE.md, the author's habits for every project):"
  grep '^## ' "$ROOT/global/CLAUDE.md" | sed 's/^## /  - /'
  d=n; [ "$RULES" = on ] && d=y
  case "$(ask "Use them? (y/n)" "$d")" in y* | Y*) RULES=on ;; *) RULES=off ;; esac
  say ""
  if [ "$(uname)" = Darwin ]; then
    say "Prototype previews: design rounds keep their preview server running while a decision waits (proto-serve.sh)."
    d=n; [ "$PROTO_AGENT" = 1 ] && d=y
    case "$(ask "Restart them at login with a LaunchAgent? (y/n)" "$d")" in y* | Y*) PROTO_AGENT=1 ;; *) PROTO_AGENT=0 ;; esac
    say ""
  fi
fi

for t in $TIERS; do # a flag, preset or answer; else the recorded value stays; else the shipped default
  v=$(tier_get "$t"); [ -n "$v" ] || [ -n "$(recorded "WF_MODEL_$t")" ] || v=$(tier_default "$t")
  [ -z "$v" ] || set_setting "WF_MODEL_$t" "$v"
done

mkdir -p "$CLAUDE_DIR/skills"
for skill in "$ROOT"/skills/*/; do
  skill=${skill%/}; name=$(basename "$skill")
  if [ "$name" = aw-orca-review ] && [ "$DEV" != 1 ]; then unlink_ours "$CLAUDE_DIR/skills/$name"; continue; fi
  link "$skill" "$CLAUDE_DIR/skills/$name"
done
# The old script paths (compat/<old skill name>/, no SKILL.md: no skill is registered) stay reachable next to the skills.
for dir in "$ROOT"/compat/*/; do
  [ -d "$dir" ] || continue
  dir=${dir%/}; path="$CLAUDE_DIR/skills/$(basename "$dir")"
  case "$(readlink "$path" 2>/dev/null)" in "$ROOT"/skills/*) RENAMED=1 ;; esac # the old skill's link becomes the compat link
  link "$dir" "$path"
done
# Drop links to skills that were removed or renamed here.
for path in "$CLAUDE_DIR"/skills/*; do
  [ -L "$path" ] || continue
  case "$(readlink "$path")" in "$ROOT"/skills/*)
    [ -e "$path" ] || { rm "$path"; changed "removed stale $path"; ! is_old_name "$(basename "$path")" || RENAMED=1; } ;;
  esac
done
link "$ROOT" "$CLAUDE_DIR/agent-workflow"

remove_hook
if [ "$RULES" = on ]; then rules_on; else rules_off; fi
if [ "$PROTO_AGENT" = 1 ] && [ "$(uname)" != Darwin ]; then warn "--proto-agent is macOS only"; PROTO_AGENT=0; fi
if [ "$PROTO_AGENT" = 1 ]; then agent_on; else agent_off; fi
set_setting WF_INSTALL_PROTO_AGENT "$PROTO_AGENT"
set_setting WF_INSTALL_DEV "$DEV"
set_setting WF_INSTALL_GLOBAL_RULES "$(rules_state)"

say "agent-workflow installed.${CHANGES:- Nothing changed.}"
[ -z "$MISSING" ] || say "Missing tools:$MISSING (see Requirements above)"
say "Settings: $SETTINGS_FILE (bash $CLAUDE_DIR/agent-workflow/bin/settings.sh show)"
if [ "$RENAMED" = 1 ]; then
  say ""
  say "The skills were renamed (type /aw- to list them); the old names are gone:"
  renames | while read -r old new; do say "  /$old -> /$new"; done
  say "The shared scripts moved to $CLAUDE_DIR/agent-workflow/bin/; the old script paths keep working for one release."
fi
note=$(config_dir_note); [ -z "$note" ] || { say ""; warn "WARNING: $note"; }
say ""
say "Next: cd <your repo> && claude, then run /aw-setup to set the repo up."
