#!/usr/bin/env bash
# Offline tests for check.sh (stubbed Orca plist, orca CLI and prepare.sh). Run: bash skills/orca-update-review/test-check.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/snap" "$T/updates" "$T/skill"
cp "$DIR/check.sh" "$DIR/lib.sh" "$T/skill/"
printf '#!/usr/bin/env bash\necho "$@" >"%s/prepared"\n' "$T" >"$T/skill/prepare.sh"
cat >"$T/bin/orca" <<'EOF2'
#!/usr/bin/env bash
[ -f "$STUB/worker" ] && echo '{"ok":true,"result":{"workers":[{"agentTerminalHandle":"term_1","dispatchStatus":"dispatched"}]}}' || echo '{"ok":true,"result":{"workers":[]}}'
EOF2
chmod +x "$T/bin/orca"
plist() { /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $1" "$T/Info.plist" >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$T/Info.plist"; }
export PATH="$T/bin:$PATH" STUB="$T" ORCA_PLIST="$T/Info.plist" ORCA_SNAPSHOT_DIR="$T/snap" ORCA_UPDATES_DIR="$T/updates"
unset ORCA_TERMINAL_HANDLE
export CLAUDE_CODE_ENTRYPOINT=cli
fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
run() { echo "{\"source\":\"${1:-startup}\"}" | bash "$T/skill/check.sh"; }
reset() { rm -rf "$T/updates"/* "$T/prepared" "$T/worker"; echo 1.4.246 >"$T/snap/version"; plist 1.4.247; }

reset
out=$(run)
check "new version: starts the review as first user turn, naming both versions" 'printf "%s" "$out" | jq -r .hookSpecificOutput.initialUserMessage | grep -q "^Run /orca-update-review: .*1.4.246 -> 1.4.247"'
check "new version: no model-only note" 'printf "%s" "$out" | jq -e ".hookSpecificOutput.additionalContext == null" >/dev/null'
check "new version: prepare.sh started with versions" 'grep -q "1.4.246 1.4.247 --out $T/updates/1.4.247.md" "$T/prepared"'
check "new version: user sees the start" 'printf "%s" "$out" | jq -r .systemMessage | grep -q "1.4.247 is new.*starting /orca-update-review"'
out=$(run)
check "same day again: status line only, no second start" 'printf "%s" "$out" | jq -e ".hookSpecificOutput == null" >/dev/null && printf "%s" "$out" | jq -r .systemMessage | grep -q "review pending"'

reset; echo "# r" >"$T/updates/1.4.247.md"
out=$(run)
check "report exists: says ready, no new prepare" 'printf "%s" "$out" | grep -q "is ready at" && [ ! -f "$T/prepared" ]'

reset; printf '#!/usr/bin/env bash\nexit 1\n' >"$T/skill/prepare.sh.fail"
cp "$T/skill/prepare.sh" "$T/skill/prepare.sh.ok"; cp "$T/skill/prepare.sh.fail" "$T/skill/prepare.sh"
out=$(run); cp "$T/skill/prepare.sh.ok" "$T/skill/prepare.sh"
check "prepare fails: still notifies, names the fallback" 'printf "%s" "$out" | grep -q "not prepared" && printf "%s" "$out" | grep -q "runs prepare.sh first"'

reset; echo 1.4.247 >"$T/snap/version"
out=$(run)
check "reviewed version: status line only" 'printf "%s" "$out" | jq -e ".hookSpecificOutput == null" >/dev/null && printf "%s" "$out" | jq -r .systemMessage | grep -q "1.4.247 is reviewed, workflow setup up to date"'

reset
check "resume: quiet" '[ -z "$(run resume)" ]'
check "compact: quiet" '[ -z "$(run compact)" ]'

reset; touch "$T/worker"
check "dispatched worker: quiet and not stamped" '[ -z "$(ORCA_TERMINAL_HANDLE=term_1 run)" ] && [ ! -f "$T/updates/1.4.247.announced" ]'
check "other Orca terminal: notified" '[ -n "$(ORCA_TERMINAL_HANDLE=term_2 run)" ]'

reset
out=$(CLAUDE_CODE_ENTRYPOINT=sdk-cli run)
check "non-interactive (claude -p): status line only, day not used up" 'printf "%s" "$out" | jq -e ".hookSpecificOutput == null" >/dev/null && printf "%s" "$out" | jq -r .systemMessage | grep -q "review pending" && [ ! -f "$T/updates/1.4.247.announced" ]'

reset; rm -f "$T/Info.plist"
check "no Orca installed: quiet" '[ -z "$(run)" ]'

echo "check: $((n - fail))/$n passed"
[ $fail = 0 ]
