#!/usr/bin/env bash
# Tests for issue-status.sh: the native issue status next to the phase labels (offline, gh stubbed).
# Run: bash bin/test-issue-status.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/global.sh" # never the real ~/.claude settings
unset WF_REPO GH_REPO WF_PHASE_LABELS
mkdir -p "$T/repo/.claude" "$T/bin"; git -C "$T/repo" init -q; git -C "$T/repo" remote add origin https://github.com/acme/widgets.git
cd "$T/repo" || exit 1
export PATH="$T/bin:$PATH"

# gh stub: logs every call to $T/calls (one line each, GH_REPO first when set). `api graphql` answers a lookup from
# $T/lookup (the TSV the real --jq prints) and a mutation with nothing; a file $T/fail-<word> makes that call fail.
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")")
printf '%s%s\n' "${GH_REPO:+GH_REPO=$GH_REPO }" "$*" >>"$T/calls"
case "$1 $2" in
  "api graphql")
    case "$*" in
      *setIssueStatus*) [ ! -e "$T/fail-mutation" ] || exit 1 ;;
      *) [ ! -e "$T/fail-lookup" ] || { echo "gh: Field 'planningStatuses' doesn't exist" >&2; exit 1; }
         cat "$T/lookup" ;;
    esac ;;
  "label create") ;;
  "issue edit") [ ! -e "$T/fail-edit" ] || exit 1 ;;
  "issue view") cat "$T/labels" 2>/dev/null ;;
  *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"

fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
S="$DIR/issue-status.sh"
# lookup answer: issue id, current status, id of the status asked for
answer() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >"$T/lookup"; }
run() { rm -f "$T/calls" "$T/err"; : >"$T/calls"; bash "$S" "$@" >"$T/out" 2>"$T/err"; echo $?; }
calls() { grep -c "$1" "$T/calls"; }
reset() { rm -f "$T"/fail-* "$T/labels" "$WF_GLOBAL_SETTINGS" "$T/repo/.claude/issue-workflow.sh"; answer I_7 Backlog IS_x; }

check "the script is executable (the skills call it by path)" '[ -x "$S" ]'

# --- phase build: label, then status, ids looked up by name ---
reset
eq "phase build exits 0" "$(run phase 7 build)" 0
check "creates the phase label with its colour" 'grep -q "^label create phase:build --force --color 1D76DB --description Phase Build" "$T/calls"'
check "adds the phase label" 'grep -qx "issue edit 7 --add-label phase:build" "$T/calls"'
check "looks the status up by name in this repo" 'grep -q "^api graphql .*planningStatuses.* -f owner=acme -f name=widgets -F number=7 .*select(.name == \\\\\"In progress\\\\\")" "$T/calls" || grep -q "planningStatuses.*owner=acme.*name=widgets.*number=7.*In progress" "$T/calls"'
check "writes the status with the ids the lookup gave" 'grep -q "setIssueStatus(input: { issueId: \$issueId, statusId: \$statusId }).* -f issueId=I_7 -f statusId=IS_x" "$T/calls"'
eq "no note when all went through" "$(cat "$T/err")" ""

# --- phase design / review / backlog ---
reset
eq "phase design exits 0" "$(run phase 7 design)" 0
check "design adds phase:design" 'grep -qx "issue edit 7 --add-label phase:design" "$T/calls"'
check "design label colour" 'grep -q "^label create phase:design --force --color 5319E7" "$T/calls"'
check "design sets In progress" 'grep -q "In progress" "$T/calls" && [ "$(calls setIssueStatus)" = 1 ]'
check "design puts the issue in the lane needs-design (a redesign of a ready issue reads as UX Design, not Build)" 'grep -qx "issue edit 7 --add-label needs-design" "$T/calls"'

reset; printf 'needs-spec\nneeds-direction\n' >"$T/labels"
run phase 7 build >/dev/null
check "a stage start removes the fog label (the issue has a lane now)" 'grep -qx "issue edit 7 --remove-label needs-direction" "$T/calls"'
run phase 7 design >/dev/null
check "design removes the fog label too" 'grep -qx "issue edit 7 --remove-label needs-direction" "$T/calls"'
reset; printf 'needs-spec\n' >"$T/labels"
run phase 7 build >/dev/null
eq "no fog label: nothing removed" "$(calls "remove-label")" 0
reset; printf 'needs-direction\n' >"$T/labels"; echo 'WF_PHASE_LABELS=off' >"$T/repo/.claude/issue-workflow.sh"
run phase 7 build >/dev/null
check "the fog label goes also with the phase labels off" 'grep -qx "issue edit 7 --remove-label needs-direction" "$T/calls"'

# --- fog: the label the triage rule sets (docs/contract.md) ---
reset
eq "fog exits 0" "$(run fog 7)" 0
check "fog creates the label with its description" 'grep -q "^label create needs-direction --force --color D4C5F9 --description Direction open: the user sets it" "$T/calls"'
check "fog adds the label" 'grep -qx "issue edit 7 --add-label needs-direction" "$T/calls"'
eq "fog writes no status and removes no lane" "$(calls "setIssueStatus\|remove-label")" 0
reset; touch "$T/fail-edit"
eq "fog with a failing write still exits 0" "$(run fog 7)" 0
check "and says so" 'grep -q "label needs-direction not added" "$T/err"'
eq "fog without a number is a usage error" "$(run fog)" 64

reset
eq "phase review exits 0" "$(run phase 7 review)" 0
check "review sets In review" 'grep -q "In review" "$T/calls" && [ "$(calls setIssueStatus)" = 1 ]'
eq "review writes no label" "$(calls "label create\|issue edit")" 0

reset; printf 'needs-design\nphase:design\n' >"$T/labels"; answer I_7 "In progress" IS_b
eq "phase backlog exits 0" "$(run phase 7 backlog)" 0
check "backlog removes phase:design when the issue carries it" 'grep -qx "issue edit 7 --remove-label phase:design" "$T/calls"'
check "backlog sets Backlog" 'grep -q "select(.name == .*Backlog" "$T/calls" && [ "$(calls setIssueStatus)" = 1 ]'
reset; printf 'needs-design\n' >"$T/labels"; answer I_7 "In progress" IS_b
run phase 7 backlog >/dev/null
eq "backlog leaves the labels alone when phase:design is not there (a repo after the cut-over has no such label)" "$(calls "issue edit")" 0
eq "and still sets the status" "$(calls setIssueStatus)" 1

# --- already there: no write ---
reset; answer I_7 "In progress" IS_x
eq "already In progress exits 0" "$(run phase 7 build)" 0
eq "an issue already at the status is not written again" "$(calls setIssueStatus)" 0

# --- WF_PHASE_LABELS=off: the status alone ---
reset; echo 'WF_PHASE_LABELS=off' >"$T/repo/.claude/issue-workflow.sh"
eq "off (repo config) exits 0" "$(run phase 7 build)" 0
eq "off: no label call" "$(calls "label create\|issue edit")" 0
eq "off: the status is still set" "$(calls setIssueStatus)" 1
reset; echo 'WF_PHASE_LABELS=off' >"$WF_GLOBAL_SETTINGS"
run phase 7 design >/dev/null
eq "off (global file): no label create, no phase label" "$(calls "label create\|phase:design")" 0
check "off: the lane label needs-design is no phase label and is still added" 'grep -qx "issue edit 7 --add-label needs-design" "$T/calls"'
reset; echo 'WF_PHASE_LABELS=off' >"$T/repo/.claude/issue-workflow.sh"; printf 'phase:design\n' >"$T/labels"
run phase 7 backlog >/dev/null
check "off: the handover still removes a phase:design from before the cut-over" 'grep -qx "issue edit 7 --remove-label phase:design" "$T/calls"'
reset
eq "the setting defaults to on" "$(bash "$DIR/settings.sh" get WF_PHASE_LABELS)" on
check "settings.sh show lists it" 'bash "$DIR/settings.sh" show | grep -q "^WF_PHASE_LABELS=on *(default)$"'

# --- best effort: nothing stops a skill ---
reset; touch "$T/fail-lookup"
eq "no statuses in the repo (lookup fails): exit 0" "$(run phase 7 build)" 0
check "the label is still written" 'grep -qx "issue edit 7 --add-label phase:build" "$T/calls"'
eq "no mutation after a failed lookup" "$(calls setIssueStatus)" 0
check "one note says the status was not set" '[ "$(wc -l <"$T/err" | tr -d " ")" = 1 ] && grep -q "#7: status not set to In progress" "$T/err"'

reset; answer I_7 Backlog ""
eq "a status name the repo does not have: exit 0" "$(run set 7 "In progress")" 0
eq "and no write" "$(calls setIssueStatus)" 0
check "note names the status" 'grep -q "acme/widgets has no status named In progress" "$T/err"'

reset; answer "" "" IS_x
eq "no such issue: exit 0" "$(run set 99 Backlog)" 0
check "note names the issue" 'grep -q "#99: no such issue in acme/widgets" "$T/err"'
eq "and no write for it" "$(calls setIssueStatus)" 0

reset; touch "$T/fail-mutation"
eq "a refused write: exit 0" "$(run set 7 "In review")" 0
check "note says the write failed" 'grep -q "#7: status not set to In review (the write failed)" "$T/err"'

reset; touch "$T/fail-edit"
eq "a failed label write: exit 0" "$(run phase 7 build)" 0
check "note names the label" 'grep -q "#7: label phase:build not added" "$T/err"'
eq "and the status is still set" "$(calls setIssueStatus)" 1

reset
eq "a name with quotes is never sent (it would end up inside the jq filter)" "$(run set 7 'x") | halt')" 0
eq "nothing called for it" "$(wc -l <"$T/calls" | tr -d " ")" 0

# --- set / get ---
reset; answer I_7 "" IS_t
eq "set exits 0" "$(run set 7 Todo)" 0
check "set on an issue without a status writes it" 'grep -q "issueId=I_7 -f statusId=IS_t" "$T/calls"'
eq "set writes no label" "$(calls "label create\|issue edit")" 0
reset; answer I_7 "In review" ""
run get 7 >/dev/null
eq "get prints the status name" "$(cat "$T/out")" "In review"
eq "get writes nothing" "$(calls "setIssueStatus\|issue edit")" 0
reset; touch "$T/fail-lookup"
eq "get in a repo without statuses: exit 0, empty" "$(run get 7)$(cat "$T/out")" 0

# --- which repo ---
reset
WF_REPO=other/thing run phase 7 build >/dev/null
check "WF_REPO names the repo of the lookup" 'grep -q "owner=other -f name=thing" "$T/calls"'
check "and pins the label calls" 'grep -qx "GH_REPO=other/thing issue edit 7 --add-label phase:build" "$T/calls"'
run phase 7 build >/dev/null
check "without WF_REPO gh keeps its own resolution" '! grep -q "^GH_REPO=" "$T/calls"'
mkdir -p "$T/norepo"; cd "$T/norepo" || exit 1
rm -f "$T/bin/gh.real"; printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/gh"
eq "no repo to act on: exit 64, before any write" "$(bash "$S" phase 7 build >/dev/null 2>&1; echo $?)" 64
cd "$T/repo" || exit 1

# --- usage ---
for args in "" "phase" "phase 7" "phase 7 done" "phase x build" "phase 7x build" "set 7" "set x Todo" "get" "get -1" "nope 7"; do
  # shellcheck disable=SC2086
  eq "usage: '$args'" "$(bash "$S" $args >/dev/null 2>&1; echo $?)" 64
done

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
