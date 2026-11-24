#!/usr/bin/env bash
# Keep prototype dev servers running for as long as a design decision waits on the user. A worker's dev server dies
# with the worker, the coordinator's background server with its session or the 2 h limit on background commands; the
# preview link the user opens later must still work. Servers started here are fully detached (their own session) and
# registered, so `ensure` can bring back what died (a reboot, a crash).
#
#   proto-serve.sh start <n[,m…]> <worktree> <port>   serve <worktree> (`npm run dev`, PORT=<port>) for issue(s) <n>
#        (one prototype can serve several issues). The port must be outside the workers' range (WF_PORTS). Already
#        listening on <port>: the running server is registered as is (adopted), not restarted. Waits up to
#        $WF_PROTO_WAIT s (20) for the port; exit 1 when the server died at once (the log tail is printed).
#   proto-serve.sh port <n>                     the preview port for issue <n>: the one it already has, else the first
#                                               free one of WF_PROTO_PORTS (3111-3119), reserved at once (exit 3: none free)
#   proto-serve.sh stop <n>                     drop issue <n> from its server; the last issue stops and unregisters it
#   proto-serve.sh ensure                       restart every registered server that no longer listens; idempotent
#   proto-serve.sh list                         issue(s), port, state, pid, worktree
#   proto-serve.sh prune [--dry-run]            stop the servers of issues that are closed or no longer carry
#                                               `needs-decision` (merge-pr.sh sweep runs it); a gh failure keeps them
#   proto-serve.sh hosted <branch>              the hosted preview URL of a pushed proto branch, from the project's
#                                               `wf_proto_preview_url` (waits while it builds); exit 2: none, use the local link
#   proto-serve.sh unhost <branch>              remove that hosted preview (`wf_proto_preview_delete`; sweep.sh runs it
#                                               with the branch); a project without one has nothing to remove
#
# A port from `port` is only reserved (worktree `-`): `start` fills it in, `ensure` skips it, `prune` frees it once the issue is closed or leaves design.
# State: $WF_PROTO_DIR (default ~/.claude/proto-serve): servers.tsv (issues, repo, port, worktree, pid) and a log per
# server (<first issue>.log). $WF_PROTO_CMD replaces `npm run dev` (tests use a dummy server). After a reboot run
# `proto-serve.sh ensure` (install.sh can add a login LaunchAgent for it).
# Exit: 0 ok, 1 a server did not start or could not be stopped, 64 usage.
set -uo pipefail
PATH=$PATH:/usr/sbin:/usr/bin:/bin # lsof lives in /usr/sbin; a minimal PATH (launchd, tests) lacks it
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$DIR/lib.sh"
die() { echo "proto-serve.sh: $*" >&2; exit 64; }

STATE=${WF_PROTO_DIR:-$HOME/.claude/proto-serve}
REG=$STATE/servers.tsv
CMD=${WF_PROTO_CMD:-npm run dev}
WAIT=${WF_PROTO_WAIT:-20}
TAB=$(printf '\t')

listener() { lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }
alive() { kill -0 "$1" 2>/dev/null; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

repo_of() { # repo_of <dir>: owner/repo of a checkout, else `-` (a tab-separated field must never be empty: read would shift)
  local u; u=$(git -C "$1" remote get-url origin 2>/dev/null) || u=""
  case "$u" in *github.com[:/]*/*) u=${u%/}; u=${u%.git}; echo "${u#*github.com[:/]}" ;; *) echo - ;; esac
}

reg_put() { # reg_put <issues> <repo> <port> <worktree> <pid>: replace the entry of that port (atomic)
  mkdir -p "$STATE"; touch "$REG"
  { awk -F'\t' -v p="$3" '$3 != p' "$REG"; printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; } >"$REG.$$" && mv "$REG.$$" "$REG"
}
reg_drop() { [ -f "$REG" ] || return 0; awk -F'\t' -v p="$1" '$3 != p' "$REG" >"$REG.$$" && mv "$REG.$$" "$REG"; } # <port>

launch() { # launch <issues> <worktree> <port>: print the pid of a server detached from this session (macOS has no setsid)
  mkdir -p "$STATE"
  python3 -I -c '
import os, subprocess, sys
wt, port, log, cmd = sys.argv[1:5]
with open(log, "ab") as out:
    p = subprocess.Popen(["sh", "-c", "exec " + cmd], cwd=wt, env=dict(os.environ, PORT=port),
                         stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
print(p.pid)' "$2" "$3" "$STATE/${1%%,*}.log" "$CMD"
}

await_up() { # await_up <pid> <port>: 0 listening, 1 the process died, 2 still starting after $WAIT s
  local i=0
  while [ "$i" -lt $((WAIT * 5)) ]; do
    [ -z "$(listener "$2")" ] || return 0
    alive "$1" || return 1
    sleep 0.2; i=$((i + 1))
  done
  return 2
}

in_wt() { # in_wt <pid> <worktree>: the process runs inside the worktree (its cwd), or its cwd cannot be read
  local c; c=$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  [ -z "$c" ] || [ "$c" = "$2" ] || [ "${c#"$2"/}" != "$c" ]
}
ours() { # ours <port> <worktree>: the listener pids on the port that run in the worktree (never someone else's server)
  local p; for p in $(lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null); do in_wt "$p" "$2" && echo "$p"; done
}

kill_server() { # kill_server <port> <pid> <worktree>: our server and its children (own session: the group), by listener or pid
  local pids p g i=0
  pids=$(ours "$1" "$3")
  for p in $pids; do
    g=$(pgid_of "$p")
    if [ "$g" = "$2" ]; then kill -TERM -- "-$g" 2>/dev/null; else kill -TERM "$p" 2>/dev/null; fi
  done
  # still starting (nothing listens yet): the registered pid, only while it still runs in the worktree (pids get reused)
  if [ -z "$(listener "$1")" ] && alive "$2" && [ "$(pgid_of "$2")" = "$2" ] && in_wt "$2" "$3"; then kill -TERM -- "-$2" 2>/dev/null; fi
  while [ "$i" -lt 25 ] && { [ -n "$(ours "$1" "$3")" ] || { alive "$2" && in_wt "$2" "$3"; }; }; do sleep 0.2; i=$((i + 1)); done
  for p in $(ours "$1" "$3"); do kill -KILL "$p" 2>/dev/null; done
  if alive "$2" && [ "$(pgid_of "$2")" = "$2" ] && in_wt "$2" "$3"; then kill -KILL -- "-$2" 2>/dev/null; fi
  [ -z "$(ours "$1" "$3")" ]
}

cmd_start() {
  [ $# -eq 3 ] || die "usage: start <n[,m…]> <worktree> <port>"
  local issues=$1 wt port=$3 repo pid lo hi cur
  [[ $issues =~ ^[0-9]+(,[0-9]+)*$ ]] || die "not an issue number (or comma list): $issues"
  [ -d "$2" ] || die "no such worktree: $2"; wt=$(cd "$2" && pwd -P)
  [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die "not a port (1024-65535): $port"
  wf_load; lo=${WF_PORTS%-*}; hi=${WF_PORTS#*-}
  if [ "$port" -ge "$lo" ] && [ "$port" -le "$hi" ]; then die "port $port is in the workers' range $WF_PORTS: pick one outside it"; fi
  repo=$(repo_of "$wt")
  cur=$(awk -F'\t' -v p="$port" '$3 == p' "$REG" 2>/dev/null)
  if [ -n "$cur" ] && [ "$(echo "$cur" | cut -f4)" != "$wt" ] && [ "$(echo "$cur" | cut -f4)" != - ]; then
    if [ -n "$(listener "$port")" ]; then die "port $port is registered for $(echo "$cur" | cut -f4) and still in use: stop it first"; fi
  fi
  if [ -n "$(listener "$port")" ]; then # a server already runs there: register it as is (a fresh start would fight for the port)
    pid=$(listener "$port")
    in_wt "$pid" "$wt" || { echo "proto-serve: port $port is used by another program (pid $pid, not running in $wt): pick another port" >&2; return 1; }
    if [ -n "$cur" ] && [ "$(echo "$cur" | cut -f4)" = "$wt" ]; then pid=$(echo "$cur" | cut -f5); alive "$pid" || pid=$(listener "$port"); fi
    reg_put "$issues" "$repo" "$port" "$wt" "$pid"
    echo "serving #$issues on port $port (already running, pid $pid, registered)"; return 0
  fi
  pid=$(launch "$issues" "$wt" "$port") || { echo "proto-serve: could not launch" >&2; return 1; }
  reg_put "$issues" "$repo" "$port" "$wt" "$pid"
  await_up "$pid" "$port"
  case $? in
    0) echo "serving #$issues on port $port (pid $pid, log $STATE/${issues%%,*}.log)" ;;
    1) reg_drop "$port"; echo "proto-serve: server for #$issues died at once; log tail:" >&2; tail -n 15 "$STATE/${issues%%,*}.log" >&2; return 1 ;;
    *) echo "serving #$issues on port $port (pid $pid, still starting after ${WAIT}s: check the log $STATE/${issues%%,*}.log)" ;;
  esac
}

cmd_port() {
  [ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]] || die "usage: port <n>"
  local here p lo hi issues repo port wt pid
  here=$(wf_repo_slug 2>/dev/null) || here=""
  if [ -s "$REG" ]; then
    while IFS="$TAB" read -r issues repo port wt pid; do
      case ",$issues," in *",$1,"*) [ -z "$here" ] || [ "$repo" = - ] || [ "$here" = "$repo" ] || continue; echo "$port"; return 0 ;; esac
    done <"$REG"
  fi
  wf_load; lo=${WF_PROTO_PORTS%-*}; hi=${WF_PROTO_PORTS#*-}
  for ((p = lo; p <= hi; p++)); do
    awk -F'\t' -v p="$p" '$3 == p {f = 1} END {exit !f}' "$REG" 2>/dev/null && continue
    [ -z "$(listener "$p")" ] || continue
    reg_put "$1" "${here:--}" "$p" - 0; echo "$p"; return 0
  done
  echo "proto-serve: no free port in $WF_PROTO_PORTS" >&2; return 3
}

cmd_stop() {
  [ $# -eq 1 ] || die "usage: stop <n>"
  [[ $1 =~ ^[0-9]+$ ]] || die "not an issue number: $1"
  [ -s "$REG" ] || return 0
  local here rc=0 issues repo port wt pid rest
  here=$(wf_repo_slug 2>/dev/null) || here=""
  while IFS="$TAB" read -r issues repo port wt pid; do
    [ -n "$port" ] || continue
    case ",$issues," in *",$1,"*) ;; *) continue ;; esac
    [ -z "$here" ] || [ "$repo" = - ] || [ "$here" = "$repo" ] || continue
    rest=$(echo ",$issues," | sed "s/,$1,/,/; s/^,//; s/,$//")
    if [ -n "$rest" ]; then reg_put "$rest" "$repo" "$port" "$wt" "$pid"; echo "#$1 dropped from the server on port $port (still serves #$rest)"
    elif [ "$wt" = - ]; then reg_drop "$port"; echo "released port $port of #$1"
    elif kill_server "$port" "$pid" "$wt"; then reg_drop "$port"; echo "stopped the server for #$1 (port $port)"
    else echo "proto-serve: could not stop the server on port $port (pid $pid)" >&2; rc=1; fi
  done <"$REG"
  return $rc
}

cmd_ensure() {
  [ -s "$REG" ] || { echo "ensure: nothing registered"; return 0; }
  local rc=0 issues repo port wt pid
  while IFS="$TAB" read -r issues repo port wt pid; do
    [ -n "$port" ] || continue
    [ "$wt" != - ] || continue # a reserved port, nothing served yet
    if [ -n "$(listener "$port")" ]; then echo "up   #$issues port $port"; continue; fi
    if [ ! -d "$wt" ]; then reg_drop "$port"; echo "gone #$issues port $port: worktree $wt is missing, unregistered"; continue; fi
    pid=$(launch "$issues" "$wt" "$port") || { echo "FAIL #$issues port $port: could not launch" >&2; rc=1; continue; }
    reg_put "$issues" "$repo" "$port" "$wt" "$pid"
    await_up "$pid" "$port"
    case $? in
      0) echo "restarted #$issues port $port (pid $pid)" ;;
      1) echo "FAIL #$issues port $port: died at once, see $STATE/${issues%%,*}.log" >&2; rc=1 ;;
      *) echo "restarted #$issues port $port (pid $pid, still starting)" ;;
    esac
  done <"$REG"
  return $rc
}

cmd_list() {
  [ -s "$REG" ] || { echo "no prototype servers registered"; return 0; }
  local issues repo port wt pid st
  while IFS="$TAB" read -r issues repo port wt pid; do
    [ -n "$port" ] || continue
    if [ "$wt" = - ]; then st=reserved; elif [ -n "$(listener "$port")" ]; then st=up; else st=down; fi
    printf '#%s\tport %s\t%s\tpid %s\t%s\n' "$issues" "$port" "$st" "$pid" "$wt"
  done <"$REG"
}

cmd_prune() {
  local dry=0 issues repo port wt pid n live st a
  for a in "$@"; do [ "$a" = --dry-run ] && dry=1 || die "usage: prune [--dry-run]"; done
  [ -s "$REG" ] || return 0
  while IFS="$TAB" read -r issues repo port wt pid; do
    [ -n "$port" ] || continue
    live=""
    for n in ${issues//,/ }; do
      # waiting = open with `needs-decision` (a reserved port also while `needs-design`); an issue gh cannot read counts as waiting
      if st=$(gh issue view "$n" $([ "$repo" = - ] || echo "-R $repo") --json state,labels --jq '.state + (if any(.labels[]; .name == "needs-decision") then " waiting" else "" end) + (if any(.labels[]; .name == "needs-design") then " design" else "" end)' 2>/dev/null); then
        case " $st " in
          *" OPEN "*) case " $st " in
            *" waiting "*) live="${live:+$live,}$n" ;;
            *" design "*) [ "$wt" != - ] || live="${live:+$live,}$n" ;;
          esac ;;
        esac
      else live="${live:+$live,}$n"; fi
    done
    [ "$live" != "$issues" ] || continue
    if [ -z "$live" ]; then
      if [ $dry = 1 ]; then echo "would stop the server for #$issues (port $port): no longer waiting"; continue; fi
      if [ "$wt" = - ]; then reg_drop "$port"; echo "released port $port of #$issues: no longer waiting"
      elif kill_server "$port" "$pid" "$wt"; then reg_drop "$port"; echo "stopped the server for #$issues (port $port): no longer waiting"
      else echo "proto-serve: could not stop the server on port $port" >&2; fi
    elif [ $dry = 0 ]; then
      reg_put "$live" "$repo" "$port" "$wt" "$pid"; echo "server on port $port keeps #$live"
    fi
  done <"$REG"
  return 0
}

cmd_hosted() { # the project's functions run at its root (cwd = the checkout, wf_load sets ROOT)
  [ $# -eq 1 ] || die "usage: hosted <branch>"
  wf_load
  wf_has wf_proto_preview_url || { echo "proto-serve: no hosted previews in this project (no wf_proto_preview_url)" >&2; return 2; }
  (cd "$ROOT" && wf_proto_preview_url "$1") || return 2
}

cmd_unhost() {
  [ $# -eq 1 ] || die "usage: unhost <branch>"
  wf_load
  wf_has wf_proto_preview_delete || return 0
  (cd "$ROOT" && wf_proto_preview_delete "$1")
}

c=${1:-}; [ $# -eq 0 ] || shift
case "$c" in
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  ensure) cmd_ensure ;;
  list) cmd_list ;;
  prune) cmd_prune "$@" ;;
  port) cmd_port "$@" ;;
  hosted) cmd_hosted "$@" ;;
  unhost) cmd_unhost "$@" ;;
  *) die "usage: proto-serve.sh start <n[,m…]> <worktree> <port> | port <n> | stop <n> | ensure | list | prune [--dry-run] | hosted <branch> | unhost <branch>" ;;
esac
