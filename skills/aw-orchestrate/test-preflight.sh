#!/usr/bin/env bash
# Tests for preflight.sh: /aw-orchestrate stops cleanly without `orca` (a PATH without it; nothing is uninstalled).
# Run: bash skills/aw-orchestrate/test-preflight.sh
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
has "says what is missing" 'no `orca` on PATH'
has "names the design skill" "/aw-ui-design <n>"
has "names the specify skill" "/aw-specify <n>"
has "names the build skill" "/aw-build <n>"
has "names the inbox: status" "bin/decide.sh status"
has "names the inbox: digest" "bin/decide.sh digest"
has "says how a parked issue goes on" "run the same stage skill again"

out=$(PATH="$T/orca" "$BASH_BIN" "$DIR/preflight.sh" 2>&1); code=$?
eq "with orca on PATH: exit 0, no output" "$code/$out" "0/"

# the skill runs it first, before the Orca guide it cannot load without the CLI
first=$(awk '/^## 0\. Preflight/ {p = 1; next} p && /^1\. / {print; exit}' "$DIR/SKILL.md")
n=$((n + 1)); case "$first" in *preflight.sh*) ;; *) fail=$((fail + 1)); echo "FAIL [SKILL.md preflight step 1 runs preflight.sh] got '$(printf '%s' "$first" | cut -c1-80)'" ;; esac

echo "preflight: $((n - fail))/$n passed"
[ $fail = 0 ]
