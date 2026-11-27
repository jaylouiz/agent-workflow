#!/usr/bin/env bash
# Tests for labels.sh with a stub gh. Run: bash skills/aw-setup/test-labels.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
mkdir -p "$T/bin" "$T/repo/.claude"; git -C "$T/repo" init -q
printf '#!/usr/bin/env bash\necho "$*" >>"%s/calls"\n' "$T" >"$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
cd "$T/repo" || exit 1
echo 'WF_HOLD_LABELS="on-hold-after-spec do-not-merge"' >.claude/issue-workflow.sh

bash "$DIR/labels.sh"; eq "exit 0" "$?" 0
eq "eleven labels" "$(grep -c '^label create' "$T/calls")" 11
eq "every call forces" "$(grep -c -- '--force' "$T/calls")" 11
check "phase:build colour" 'grep -q "^label create phase:build --force --color 1D76DB" "$T/calls"'
check "hold label from the config" 'grep -q "^label create do-not-merge " "$T/calls"'
rm -f "$T/calls"
out=$(bash "$DIR/labels.sh" --dry-run)
check "dry run calls nothing" '[ ! -f "$T/calls" ]'
eq "dry run prints eleven commands" "$(printf '%s\n' "$out" | grep -c '^gh label create')" 11
printf '#!/bin/sh\nexit 1\n' >"$T/bin/gh"
bash "$DIR/labels.sh" 2>"$T/err"; eq "gh failure: exit 1" "$?" 1
check "gh failure names the label" 'grep -q "could not create needs-design" "$T/err"'

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
