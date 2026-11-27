#!/usr/bin/env bash
# Tests for the settings layer: lib.sh wf_load (defaults → global file → repo config, env for the caps) and settings.sh.
# Run: bash bin/test-settings.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/global.sh"
unset WF_COMMENT_CAP WF_ISSUE_LOG_DIR WF_REPO
R="$T/repo"; mkdir -p "$R/.claude"; git -C "$R" init -q
cd "$R" || exit 1
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
S="$DIR/settings.sh"
reset() { rm -f "$WF_GLOBAL_SETTINGS" "$R/.claude/issue-workflow.sh"; }

eq "path before the global file exists" "$(bash "$S" path | head -1)" "global: $T/global.sh (absent)"

reset
eq "default strong tier" "$(bash "$S" get WF_MODEL_STRONG)" opus
eq "default heavy tier" "$(bash "$S" get WF_MODEL_HEAVY)" claude-fable-5-2
check "show lists the heavy tier" 'bash "$S" show | grep -q "^WF_MODEL_HEAVY=claude-fable-5-2 *(default)$"'
eq "default digest cap" "$(bash "$S" get WF_DIGEST_CAP)" 2h
check "show marks defaults" 'bash "$S" show | grep -q "^WF_MAX_WORKERS=3 *(default)$"'

printf 'WF_MODEL_DEFAULT=opus\nWF_MODEL_HEAVY=fable\n' >"$WF_GLOBAL_SETTINGS"
eq "global heavy tier" "$(bash "$S" get WF_MODEL_HEAVY)" fable
eq "global over default" "$(bash "$S" get WF_MODEL_DEFAULT)" opus
check "show marks global" 'bash "$S" show | grep -q "^WF_MODEL_DEFAULT=opus *(global)$"'

echo 'WF_MAX_WORKERS=5' >"$WF_GLOBAL_SETTINGS"; echo 'WF_MAX_WORKERS=1' >"$R/.claude/issue-workflow.sh"
eq "repo over global" "$(bash "$S" get WF_MAX_WORKERS)" 1
check "show marks repo" 'bash "$S" show | grep -q "^WF_MAX_WORKERS=1 *(repo)$"'

reset; echo 'WF_COMMENT_CAP=900' >"$WF_GLOBAL_SETTINGS"
eq "global comment cap" "$(bash "$S" get WF_COMMENT_CAP)" 900
eq "env wins for the comment cap" "$(WF_COMMENT_CAP=1200 bash "$S" get WF_COMMENT_CAP)" 1200
check "show marks env" 'WF_COMMENT_CAP=1200 bash "$S" show | grep -q "^WF_COMMENT_CAP=1200 *(env)$"'
reset
eq "env does not win for other settings" "$(WF_MAX_WORKERS=9 bash "$S" get WF_MAX_WORKERS)" 3

mkdir -p "$R/src/a"; touch "$R/src/a/b"
echo 'WF_RISK_GLOBS=(src/**)' >"$WF_GLOBAL_SETTINGS"
check "global globs stay patterns" 'bash "$S" show | grep -qF "WF_RISK_GLOBS=(src/**)"'

echo 'WF_X=(' >"$WF_GLOBAL_SETTINGS"
out=$(bash "$S" get WF_MAX_WORKERS 2>"$T/err"); rc=$?
eq "broken global: exit 0" "$rc" 0
eq "broken global: defaults" "$out" 3
check "broken global: one stderr line naming the file" '[ "$(wc -l <"$T/err" | tr -d " ")" = 1 ] && grep -qF "$WF_GLOBAL_SETTINGS" "$T/err"'

reset
bash "$S" get WF_NOPE >/dev/null 2>&1; eq "unknown name exits 1" "$?" 1
bash "$S" frob >/dev/null 2>&1; eq "usage exits 64" "$?" 64

# wf_seconds: the digest cap as seconds
. "$DIR/lib.sh"
eq "2h" "$(wf_seconds 2h)" 7200
eq "90m" "$(wf_seconds 90m)" 5400
eq "plain seconds" "$(wf_seconds 300)" 300
wf_seconds soon >/dev/null 2>&1; eq "junk fails" "$?" 1

# decide.sh takes the comment cap from the global file
echo 'WF_COMMENT_CAP=10' >"$WF_GLOBAL_SETTINGS"
printf 'eleven char' >"$T/c.md"
bash "$DIR/decide.sh" check "$T/c.md" >/dev/null 2>&1; eq "decide.sh cap from global" "$?" 65

# decide.sh runs with set -e: a settings file whose command returns non-zero, or that does not parse, must not kill it
printf 'command -v no-such-tool-xyz >/dev/null && WF_PM=pnpm\n' >"$WF_GLOBAL_SETTINGS"
printf 'short' >"$T/ok.md"
bash "$DIR/decide.sh" check "$T/ok.md" >/dev/null 2>&1; eq "decide.sh survives a false last line" "$?" 0
printf 'WF_X=(\n' >"$WF_GLOBAL_SETTINGS"
bash "$DIR/decide.sh" check "$T/ok.md" >/dev/null 2>"$T/err2"; eq "decide.sh survives an unparsable global file" "$?" 0
check "unparsable global file: stderr names it" 'grep -qF "$WF_GLOBAL_SETTINGS" "$T/err2"'
rm -f "$WF_GLOBAL_SETTINGS"


# settings.sh profile: template version and size budget
. "$DIR/lib.sh"
TPL="$DIR/../reference/project-profile.md"
want=$(sed -n 's/.*<!-- profile-template: \([0-9][0-9]*\) -->.*/\1/p' "$TPL" | head -1)
check "template carries a version line" '[ -n "$want" ]'
P="$T/profile.md"
printf '# p\n\n<!-- profile-template: %s -->\n\n## Labels\n\n- a\n' "$want" >"$P"
eq "current profile is silent" "$(bash "$S" profile "$P")" ""
printf '# p\n\n## Labels\n\n- a\n' >"$P"
eq "no version: one line" "$(bash "$S" profile "$P")" "profile older than the template (none < $want): run /aw-setup update"
printf '# p\n\n<!-- profile-template: 0 -->\n\n## Labels\n' >"$P"
check "older version: one line" '[ "$(bash "$S" profile "$P" | wc -l | tr -d " ")" = 1 ] && bash "$S" profile "$P" | grep -q "^profile older than the template (0 < "'
printf '# p\n\n<!-- profile-template: %s -->\n\n## Big\n\n' "$want" >"$P"
head -c 16000 /dev/zero | tr '\0' x >>"$P"; printf '\n\n## Small\n\n- a\n' >>"$P"
out=$(bash "$S" profile "$P")
check "over 15 KB: warns with budget" 'echo "$out" | grep -q "over the 15 KB budget"'
check "over 15 KB: section sizes" 'echo "$out" | grep -q "Big 16"'
check "over 15 KB: convention named" 'echo "$out" | grep -qF "Full text: .claude/issue-workflow/<slug>.md"'
head -c 5000 /dev/zero | tr '\0' x >>"$P"
check "over 20 KB: split now" 'bash "$S" profile "$P" | grep -q "over the 20 KB limit"'
eq "missing profile is silent" "$(bash "$S" profile "$T/none.md")" ""
# show ends with the check for the repo's own profile
printf '# p\n\n## Labels\n' >"$R/.claude/issue-workflow.md"
check "show prints the version line" 'bash "$S" show | grep -q "^profile older than the template"'
rm -f "$R/.claude/issue-workflow.md"
echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
