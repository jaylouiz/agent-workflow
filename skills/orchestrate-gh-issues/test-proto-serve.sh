#!/usr/bin/env bash
# Tests for proto-serve.sh (start, adopt, ensure after a kill, stop, prune, registry cleanup) with a dummy
# http.server instead of npm and a stubbed `gh`. Run: bash skills/orchestrate-gh-issues/test-proto-serve.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(cd "$(mktemp -d)" && pwd -P)
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
export WF_PROTO_DIR="$T/state" WF_PROTO_CMD='python3 -m http.server "$PORT" --bind 127.0.0.1' WF_PROTO_WAIT=10
export PATH="$T/bin:$PATH" STUB="$T/stub"
mkdir -p "$T/bin" "$STUB" "$T/wt-a" "$T/wt-b"
cd "$T" || exit 1
P=$DIR/proto-serve.sh
REG=$WF_PROTO_DIR/servers.tsv
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
up() { lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }
count() { local c; c=$(grep -c . "$REG" 2>/dev/null); echo "${c:-0}"; }
cleanup() { for p in ${PORTS:-}; do pids=$(lsof -nP -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null); [ -z "$pids" ] || kill $pids 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
A=$(free_port); B=$(free_port); C=$(free_port); PORTS="$A $B $C"

# gh stub: `issue view <n> ... --json state,labels --jq` answers from $STUB/issue-<n> ("OPEN needs-decision", "CLOSED", "fail")
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "issue view" ] || exit 1
f=$STUB/issue-$3; [ -f "$f" ] && [ "$(cat "$f")" != fail ] || exit 1
cat "$f"
STUB
chmod +x "$T/bin/gh"

# start: detached, listening, registered
bash "$P" start 101 "$T/wt-a" "$A" >"$T/out" 2>&1; eq "start exits 0" $? 0
[ -n "$(up "$A")" ]; eq "start: the port listens" $? 0
eq "start: one registry line" "$(count)" 1
eq "start: registry has issue, port and worktree" "$(cut -f1,3,4 "$REG")" "$(printf '101\t%s\t%s' "$A" "$T/wt-a")"
pid=$(cut -f5 "$REG")
eq "start: own session (pgid = pid)" "$(ps -o pgid= -p "$pid" | tr -d ' ')" "$pid"
eq "start: list says up" "$(bash "$P" list | grep -c "port $A.*up")" 1
eq "start: serves the worktree" "$(lsof -a -p "$(up "$A")" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" "$T/wt-a"

# start again: nothing restarted, still one line
bash "$P" start 101 "$T/wt-a" "$A" >"$T/out" 2>&1; eq "restart start exits 0" $? 0
eq "start twice: same pid" "$(cut -f5 "$REG")" "$pid"
eq "start twice: one registry line" "$(count)" 1

# ensure: up = nothing to do; killed = restarted; idempotent
bash "$P" ensure >"$T/out" 2>&1; eq "ensure with a live server" "$(grep -c '^up' "$T/out")" 1
eq "ensure with a live server keeps the pid" "$(cut -f5 "$REG")" "$pid"
kill -KILL -- "-$pid" 2>/dev/null; sleep 0.5
eq "kill: port is down" "$(up "$A")" ""
eq "kill: list says down" "$(bash "$P" list | grep -c "port $A.*down")" 1
bash "$P" ensure >"$T/out" 2>&1; eq "ensure after a kill exits 0" $? 0
[ -n "$(up "$A")" ]; eq "ensure after a kill: listening again" $? 0
eq "ensure after a kill: reports a restart" "$(grep -c '^restarted' "$T/out")" 1
pid2=$(cut -f5 "$REG"); [ "$pid2" != "$pid" ]; eq "ensure after a kill: new pid registered" $? 0
bash "$P" ensure >"$T/out" 2>&1
eq "ensure twice: second run restarts nothing" "$(grep -c '^restarted' "$T/out")" 0
eq "ensure twice: pid unchanged" "$(cut -f5 "$REG")" "$pid2"

# a port in the workers' range is refused; a bad issue or worktree too
bash "$P" start 5 "$T/wt-a" 3102 >/dev/null 2>&1; eq "worker-range port refused" $? 64
bash "$P" start x "$T/wt-a" "$B" >/dev/null 2>&1; eq "bad issue refused" $? 64
bash "$P" start 5 "$T/nope" "$B" >/dev/null 2>&1; eq "missing worktree refused" $? 64
eq "refusals register nothing" "$(count)" 1
bash "$P" start 5 "$T/wt-b" "$A" >/dev/null 2>&1; eq "port in use by another worktree refused" $? 64

# adopt: a server already running on the port is registered, not restarted
(cd "$T/wt-b" && exec python3 -m http.server "$B" --bind 127.0.0.1 >/dev/null 2>&1) &
disown $!
for _ in $(seq 1 50); do [ -n "$(up "$B")" ] && break; sleep 0.1; done
bash "$P" start 202 "$T/wt-b" "$B" >"$T/out" 2>&1; eq "adopt exits 0" $? 0
eq "adopt: says so" "$(grep -c 'already running' "$T/out")" 1
eq "adopt: registered with the listener's pid" "$(awk -F'\t' -v p="$B" '$3 == p {print $5}' "$REG")" "$(up "$B")"
eq "adopt: two registry lines" "$(count)" 2

# stop: server killed, line gone; unknown issue is a no-op
bash "$P" stop 202 >"$T/out" 2>&1; eq "stop exits 0" $? 0
eq "stop: port closed" "$(up "$B")" ""
eq "stop: registry line removed" "$(grep -c "	$B	" "$REG")" 0
bash "$P" stop 101 >/dev/null 2>&1
eq "stop: first server closed" "$(up "$A")" ""
eq "stop: registry empty" "$(count)" 0
bash "$P" stop 999 >/dev/null 2>&1; eq "stop of an unregistered issue exits 0" $? 0
bash "$P" ensure >"$T/out" 2>&1; eq "ensure with an empty registry" $? 0

# several issues on one server: the last one to stop ends it
bash "$P" start 301,302 "$T/wt-a" "$C" >/dev/null 2>&1
bash "$P" stop 301 >"$T/out" 2>&1
[ -n "$(up "$C")" ]; eq "shared server survives the first stop" $? 0
eq "shared server keeps the other issue" "$(cut -f1 "$REG")" 302
bash "$P" stop 302 >/dev/null 2>&1
eq "shared server ends with its last issue" "$(up "$C")" ""
eq "shared server: registry empty" "$(count)" 0

# ensure drops a server whose worktree is gone
mkdir "$T/wt-gone"; bash "$P" start 401 "$T/wt-gone" "$A" >/dev/null 2>&1
bash "$P" stop 401 >/dev/null 2>&1; bash "$P" start 401 "$T/wt-gone" "$A" >/dev/null 2>&1
kill -KILL -- "-$(cut -f5 "$REG")" 2>/dev/null; sleep 0.5; rmdir "$T/wt-gone" 2>/dev/null || rm -rf "$T/wt-gone"
bash "$P" ensure >"$T/out" 2>&1
eq "ensure: missing worktree unregistered" "$(count)" 0
eq "ensure: says so" "$(grep -c '^gone' "$T/out")" 1

# a server that dies at once: exit 1, nothing registered
WF_PROTO_CMD=false bash "$P" start 501 "$T/wt-a" "$A" >"$T/out" 2>&1; eq "dead on start exits 1" $? 1
eq "dead on start: nothing registered" "$(count)" 0

# a stranger on the port is neither adopted nor killed; a stale pid that is not ours is left alone
F=$(free_port); PORTS="$PORTS $F"; mkdir -p "$T/elsewhere"
(cd "$T/elsewhere" && exec python3 -m http.server "$F" --bind 127.0.0.1 >/dev/null 2>&1) &
disown $!; for _ in $(seq 1 50); do [ -n "$(up "$F")" ] && break; sleep 0.1; done
bash "$P" start 801 "$T/wt-a" "$F" >"$T/out" 2>&1; eq "start refuses a port used by another program" $? 1
eq "refused start registers nothing" "$(count)" 0
printf '801\t-\t%s\t%s\t%s\n' "$F" "$T/wt-a" "$(up "$F")" >"$REG"
bash "$P" stop 801 >/dev/null 2>&1
[ -n "$(up "$F")" ]; eq "stop leaves a server that does not run in the worktree" $? 0
kill "$(up "$F")"; : >"$REG"
(cd / && exec python3 -I -c 'import os; os.setsid(); os.execvp("sleep", ["sleep", "30"])') &
SL=$!; disown "$SL"; sleep 0.5
printf '802\t-\t%s\t%s\t%s\n' "$F" "$T/wt-a" "$SL" >"$REG"
bash "$P" stop 802 >/dev/null 2>&1
kill -0 "$SL" 2>/dev/null; eq "stop leaves a stale pid that now belongs to another process" $? 0
kill "$SL" 2>/dev/null; : >"$REG"

# port: reserves a preview port per issue (stable, distinct, skipped when taken), start fills it in, prune frees stale ones
X=$(free_port); export WF_PROTO_PORTS="$X-$((X + 2))"
eq "port: first free port of the range" "$(bash "$P" port 901)" "$X"
eq "port: the same issue gets the same port" "$(bash "$P" port 901)" "$X"
eq "port: another issue gets the next one" "$(bash "$P" port 902)" "$((X + 1))"
eq "port: reservations are registered" "$(count)" 2
eq "port: list says reserved" "$(bash "$P" list | grep -c reserved)" 2
bash "$P" ensure >"$T/out" 2>&1; eq "ensure skips a reservation" "$?:$(grep -c . "$T/out")" "0:0"
bash "$P" start 901 "$T/wt-a" "$X" >/dev/null 2>&1; eq "start fills in a reserved port" "$?" 0
[ -n "$(up "$X")" ]; eq "start on a reserved port serves it" $? 0
eq "start on a reserved port keeps one line for it" "$(grep -c "	$X	" "$REG")" 1
bash "$P" stop 902 >/dev/null 2>&1; eq "stop releases a reservation" "$(grep -c "	$((X + 1))	" "$REG")" 0
(cd "$T/wt-b" && exec python3 -m http.server "$((X + 1))" --bind 127.0.0.1 >/dev/null 2>&1) &
disown $!; for _ in $(seq 1 50); do [ -n "$(up "$((X + 1))")" ] && break; sleep 0.1; done
eq "port: a port someone listens on is skipped" "$(bash "$P" port 903)" "$((X + 2))"
kill "$(up "$((X + 1))")"; PORTS="$PORTS $X"
echo "OPEN waiting" >"$STUB/issue-901"; echo "OPEN design" >"$STUB/issue-903"
bash "$P" prune >"$T/out" 2>&1
eq "prune keeps a reservation of an open issue" "$(grep -c "	$((X + 2))	" "$REG")" 1
echo OPEN >"$STUB/issue-903"; bash "$P" prune >"$T/out" 2>&1
eq "prune frees a reservation once the issue left design" "$(grep -c "	$((X + 2))	" "$REG")" 0
bash "$P" port 903 >/dev/null; echo CLOSED >"$STUB/issue-903"; bash "$P" prune >"$T/out" 2>&1
eq "prune frees the reservation of a closed issue" "$(grep -c "	$((X + 2))	" "$REG")" 0
bash "$P" stop 901 >/dev/null 2>&1; eq "port test cleaned up" "$(count)$(up "$X")" 0
unset WF_PROTO_PORTS

# prune: stops what no longer waits; a gh failure keeps the server
bash "$P" start 601 "$T/wt-a" "$A" >/dev/null 2>&1; bash "$P" start 602,603 "$T/wt-b" "$B" >/dev/null 2>&1
echo "OPEN waiting design" >"$STUB/issue-601"; echo "CLOSED waiting" >"$STUB/issue-602"; echo "OPEN waiting" >"$STUB/issue-603"
bash "$P" prune --dry-run >"$T/out" 2>&1; eq "prune --dry-run changes nothing" "$(count)" 2
bash "$P" prune >"$T/out" 2>&1
[ -n "$(up "$A")" ]; eq "prune: a waiting issue keeps its server" $? 0
[ -n "$(up "$B")" ]; eq "prune: a shared server keeps running while one issue waits" $? 0
eq "prune: the closed issue is dropped from the shared server" "$(awk -F'\t' -v p="$B" '$3 == p {print $1}' "$REG")" 603
echo "OPEN design" >"$STUB/issue-601"; echo fail >"$STUB/issue-603"
bash "$P" prune >"$T/out" 2>&1
[ -n "$(up "$B")" ]; eq "prune: gh failing keeps the server" $? 0
eq "prune: an answered issue (no needs-decision) is stopped" "$(up "$A")" ""
echo "CLOSED" >"$STUB/issue-603"; bash "$P" prune >"$T/out" 2>&1
eq "prune: closed issue stops the last server" "$(up "$B")" ""
eq "prune: registry cleaned" "$(count)" 0

# hosted / unhost: the project's wf_proto_preview_url / wf_proto_preview_delete, run at the checkout's root
H=$T/hosted-repo; mkdir -p "$H/.claude/sub"; git init -q "$H"
(cd "$H/.claude/sub" && bash "$P" hosted proto/7-x >"$T/out" 2>&1); eq "hosted: a project without previews exits 2" $? 2
grep -q "no hosted previews" "$T/out"; eq "hosted: says why" $? 0
(cd "$H" && bash "$P" unhost proto/7-x >"$T/out" 2>&1); eq "unhost: nothing to remove without the hook" $? 0
cat >"$H/.claude/issue-workflow.sh" <<'CFG'
wf_proto_preview_url() { [ "$1" != proto/8-failed ] || return 1; echo "https://${1//\//-}.preview.test (from $(basename "$PWD"))"; }
wf_proto_preview_delete() { echo "deleted $1"; }
CFG
eq "hosted: the project's URL, run at its root" "$(cd "$H/.claude/sub" && bash "$P" hosted proto/7-x 2>&1)" "https://proto-7-x.preview.test (from hosted-repo)"
(cd "$H" && bash "$P" hosted proto/8-failed >/dev/null 2>&1); eq "hosted: no built preview exits 2" $? 2
eq "unhost: runs the project's delete" "$(cd "$H" && bash "$P" unhost proto/7-x 2>&1)" "deleted proto/7-x"

[ "$fail" = 0 ] && echo "test-proto-serve: all $n checks passed" || { echo "test-proto-serve: $fail of $n failed"; exit 1; }
