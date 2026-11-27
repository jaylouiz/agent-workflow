#!/usr/bin/env bash
# Tests for preflight.sh: without `orca` (a PATH without it; nothing is uninstalled) /aw-coordinate goes on in subagent mode.
# Run: bash skills/aw-coordinate/test-preflight.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BASH_BIN=$(command -v bash)
mkdir -p "$T/empty" "$T/orca"
ln -s "$(command -v cat)" "$T/empty/cat"; ln -s "$(command -v cat)" "$T/orca/cat" # the only command the script runs
printf '#!/bin/sh\nexit 0\n' >"$T/orca/orca"; chmod +x "$T/orca/orca"

fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
has() { n=$((n + 1)); printf '%s\n' "$out" | grep -qF -- "$2" || { fail=$((fail + 1)); echo "FAIL [$1] no '$2' in the message"; }; }

out=$(PATH="$T/empty" "$BASH_BIN" "$DIR/preflight.sh" 2>"$T/err"); code=$?
eq "without orca on PATH: exit 69" "$code" 69
eq "without orca: nothing on stderr (the message is the output)" "$(cat "$T/err")" ""
has "says what is missing" 'No `orca` on PATH'
has "names the mode it goes on in" "subagent mode"
has "names the file the skill continues with" "subagent-mode.md"
eq "without orca: one line (it is passed on to the user)" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
n=$((n + 1)); [ -f "$DIR/subagent-mode.md" ] || { fail=$((fail + 1)); echo "FAIL [subagent-mode.md exists]"; }

# asked for by the user: the same mode with Orca installed
out=$(PATH="$T/orca" "$BASH_BIN" "$DIR/preflight.sh" --subagents 2>"$T/err"); code=$?
eq "--subagents with orca on PATH: exit 69" "$code" 69
has "--subagents: names the mode" "Asked for subagent mode"
out=$(PATH="$T/orca" "$BASH_BIN" "$DIR/preflight.sh" --bogus 2>/dev/null); code=$?
eq "unknown argument: exit 64, nothing on stdout" "$code/$out" "64/"

out=$(PATH="$T/orca" "$BASH_BIN" "$DIR/preflight.sh" 2>&1); code=$?
eq "with orca on PATH: exit 0, no output" "$code/$out" "0/"

# an Orca older than ORCA_MIN (bin/lib.sh): one warning line naming both versions, still exit 0; at the minimum: nothing
MIN=$(. "$DIR/../../bin/lib.sh"; echo "$ORCA_MIN")
printf '#!/bin/sh\necho 1.4.100\n' >"$T/orca/orca"
out=$(PATH="$T/orca" "$BASH_BIN" "$DIR/preflight.sh" 2>"$T/err"); code=$?
eq "old Orca: exit 0 (a warning never blocks)" "$code" 0
has "old Orca: warning names the installed and the minimum version" "Warning: Orca 1.4.100 is older than the supported minimum $MIN"
eq "old Orca: one line, nothing on stderr" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')/$(cat "$T/err")" "1/"
# run by bare name (cd + `bash preflight.sh`): the warning must still appear
printf '#!/bin/sh\necho 1.4.100\n' >"$T/orca/orca"
out=$(cd "$DIR" && PATH="$T/orca" "$BASH_BIN" preflight.sh 2>&1); code=$?
has "bare name: the warning still appears" "Warning: Orca 1.4.100 is older"
printf '#!/bin/sh\necho %s\n' "$MIN" >"$T/orca/orca"
out=$(PATH="$T/orca" "$BASH_BIN" "$DIR/preflight.sh" 2>&1); code=$?
eq "Orca at the minimum: exit 0, no output" "$code/$out" "0/"

# the skill runs it first, before the Orca guide it cannot load without the CLI
first=$(awk '/^## 0\. Preflight/ {p = 1; next} p && /^1\. / {print; exit}' "$DIR/SKILL.md")
n=$((n + 1)); case "$first" in *"exit 69"*subagent-mode.md*) ;; *) fail=$((fail + 1)); echo "FAIL [SKILL.md step 1 sends exit 69 to subagent-mode.md]" ;; esac
n=$((n + 1)); case "$first" in *preflight.sh*) ;; *) fail=$((fail + 1)); echo "FAIL [SKILL.md preflight step 1 runs preflight.sh] got '$(printf '%s' "$first" | cut -c1-80)'" ;; esac

echo "preflight: $((n - fail))/$n passed"
[ $fail = 0 ]
