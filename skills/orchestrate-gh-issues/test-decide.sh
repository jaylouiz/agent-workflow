#!/usr/bin/env bash
# Tests for decide.sh check, log, digest and reply attribution (status/digest) (offline, gh stubbed). Run: bash skills/orchestrate-gh-issues/test-decide.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo" "$T/bin"; git -C "$T/repo" init -q; git -C "$T/repo" remote add origin https://github.com/acme/widgets.git
cd "$T/repo" || exit 1
export WF_ISSUE_LOG_DIR="$T/logs" PATH="$T/bin:$PATH"

# gh stub: `issue list --label needs-decision` returns $T/needs.json, `issue view <n> --json state` reads $T/state-<n>.
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")")
case "$1 $2" in
  "issue list") case "$*" in *needs-decision*) cat "$T/needs.json" ;; *agent-decided*comments*) cat "$T/agent.json" ;; *--jq*) echo 0 ;; *) echo '[]' ;; esac ;;
  "issue view") case "$*" in *"--json comments"*) jq '.[0].comments' "$T/needs.json" ;; *) cat "$T/state-$3" 2>/dev/null || echo OPEN ;; esac ;;
  "issue comment") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cat "$2" >>"$T/posted"; shift; done ;;
  "issue edit"|"label create") ;;
  "repo view") echo https://github.com/acme/widgets ;;
  *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"

fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL [$1] want '$3' got '$2'"; }; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
D="$DIR/decide.sh"

# check
printf '<!-- decision-note -->\nShort question?\n- A: one\n- B: two\n' >"$T/ok.md"
eq "short comment passes" "$(rc bash "$D" check "$T/ok.md")" 0
python3 -c 'print("x " * 1000)' >"$T/long.md"
eq "long visible text blocked" "$(rc bash "$D" check "$T/long.md")" 65
{ echo "Headline"; echo "<details><summary>Details</summary>"; python3 -c 'print("\n".join(["y " * 150] * 20))'; echo "</details>"; } >"$T/folded.md"
eq "detail folded into <details> passes" "$(rc bash "$D" check "$T/folded.md")" 0
python3 -c 'print("z" * 450)' >"$T/wall.md"
eq "one wall-of-text line blocked" "$(rc bash "$D" check "$T/wall.md")" 65
printf 'See ![R1 · a · desktop](https://github.com/user-attachments/assets/%s)\n' "$(python3 -c 'print("0" * 600)')" >"$T/img.md"
eq "images and URLs do not count" "$(rc bash "$D" check "$T/img.md")" 0
eq "cap is configurable" "$(WF_COMMENT_CAP=5 rc bash "$D" check "$T/ok.md")" 65
printf '### a: one\nline\n<details><summary>Details</summary> p </details>\n### b: two\n' >"$T/glued.md"
eq "heading glued to </details> blocked" "$(rc bash "$D" check "$T/glued.md")" 65
printf '### a: one\nline\n<details><summary>Details</summary> p </details>\n\n### b: two\n<details><summary>Details</summary> q </details>\n' >"$T/spaced.md"
eq "blank line after </details> passes" "$(rc bash "$D" check "$T/spaced.md")" 0

# log
bash "$D" log 12 "Build started on feat/12-x"
bash "$D" log 12 "verify green
(2879 tests)"
f="$T/logs/acme/widgets/12.md"
eq "log path" "$(bash "$D" log --path 12)" "$f"
eq "log header" "$(head -1 "$f")" "# Coordination log #12 (acme/widgets)"
eq "log entries, one line each" "$(grep -c '^- 20' "$f")" 2
eq "multi-line text flattened" "$(tail -1 "$f" | sed 's/^- [^ ]* //')" "verify green (2879 tests)"
bash "$D" log 13 "x"; echo CLOSED >"$T/state-13"
bash "$D" log --prune >/dev/null
eq "prune drops closed issue logs" "$(ls "$T/logs/acme/widgets")" "12.md"
bash "$D" log --rm 12
eq "rm drops the log" "$(ls "$T/logs/acme/widgets" | wc -l | tr -d ' ')" 0

# digest: a waiting request is listed (rows are \x1f-separated)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg t "$now" '[{number: 7, url: "https://github.com/acme/widgets/issues/7", comments: [
  {body: "<!-- decision-request D1 -->\n### Decision needed (D1): parked\n\nPick a layout?\nPreview: https://p/x", createdAt: $t}]}]' >"$T/needs.json"
out=$(bash "$D" digest)
eq "digest lists the waiting request" "$(printf '%s\n' "$out" | head -1)" "1 decision(s) need you:"
eq "digest shows the preview" "$(printf '%s\n' "$out" | grep -c 'preview: https://p/x')" 1
jq -n --arg t "$now" '[{number: 7, url: "u", comments: [
  {body: "<!-- decision-request D1 -->\nPick?", createdAt: $t}, {body: "B", createdAt: $t}]}]' >"$T/needs.json"
eq "answered request is not in the digest" "$(bash "$D" digest)" "no open decision requests"

# reply attribution (shapes shared with tandem#26): `req Dk` / `rec Dk` / `ans Dk` / `res Dk` / `note` are marked comments,
# anything else is an unmarked user comment. thread <file> <comments...> writes one issue (#7) with those comments.
thread() {
  local f=$1; shift
  printf '%s\n' "$@" | jq -R --arg t "$now" '
    (if test("^req D") then "<!-- decision-request \(.[4:]) -->\nPick \(.[4:])?"
     elif test("^rec D") then "<!-- decision-record \(.[4:]) -->\nChose \(.[4:])"
     elif test("^ans D") then "<!-- decision-answer \(.[4:]) -->\nAnswer from the user (via the coordinator): B"
     elif test("^res D") then "<!-- decision-resolved \(.[4:]) -->\nResumed (\(.[4:]))."
     elif test("^fol D") then "<!-- decision-followup \(.[4:]) -->\nChange request moved to #9."
     elif . == "note" then "<!-- decision-note look -->\nLook"
     else . end) | {body: ., createdAt: $t}' | jq -s '[{number: 7, url: "u", comments: .}]' >"$f"
}
status() { thread "$T/needs.json" "$@"; cp "$T/needs.json" "$T/agent.json"; bash "$D" status; }
eq "challenge to D2 while D3 is open: D3 stays waiting, D2 is a change" \
  "$(status 'rec D2' 'req D3' 'D2: change it')" "waiting  #7 D3 (0m): Pick D3?
change   #7 D2: D2: change it"
eq "answer to D3 written after rec D2: D3 answered, D2 untouched" \
  "$(status 'req D3' 'rec D2' 'D3: B')" "answered #7 D3: D3: B"
eq "unprefixed reply keeps the nearest earlier marker (D2)" "$(status 'req D3' 'rec D2' 'B')" "waiting  #7 D3 (0m): Pick D3?
change   #7 D2: B"
eq "unprefixed 'change D1' attaches to D1" "$(status 'rec D1' 'change D1')" "change   #7 D1: change D1"
eq "prefix naming an unknown id attaches to the nearest marker" "$(status 'rec D1' 'D9: x')" "change   #7 D1: D9: x"
eq "prefix before its request exists does not count" "$(status 'rec D1' 'D2: early' 'req D2')" "waiting  #7 D2 (0m): Pick D2?
change   #7 D1: D2: early"
eq "replies of one decision are joined in thread order" "$(status 'rec D1' 'req D2' 'D1: a' 'D2: b' 'D1: c')" "answered #7 D2: D2: b
change   #7 D1: D1: a / D1: c"
eq "prefixed comment after a note still names its decision" "$(status 'rec D1' 'note' 'D1: x')" "change   #7 D1: D1: x"
eq "unprefixed comment after a note belongs to the note: no change row (as on the Board)" "$(status 'rec D1' 'note' 'y')" ""
eq "a round reaction after a note is no change row" "$(status 'rec D1' 'note' 'R1: - pick: B')" ""
eq "an unprefixed reply after the note's own later marker goes to that marker" "$(status 'rec D1' 'note' 'rec D2' 'z')" "change   #7 D2: z"
eq "a note between a request and a prefixed answer does not hide the answer" "$(status 'req D1' 'note' 'D1: B')" "answered #7 D1: D1: B"
eq "a parked request stays waiting when a later record follows" "$(status 'req D3' 'rec D4')" "waiting  #7 D3 (0m): Pick D3?"
eq "digest lists a parked request despite a later record" "$(bash "$D" digest | sed -n 2p | cut -c1-30)" "- #7 D3 (0m): Pick D3?  u"
eq "answered request is not waiting in the digest, even with a later record" "$(thread "$T/needs.json" 'req D3' 'rec D4' 'D3: B'; bash "$D" digest)" "no open decision requests"
eq "answer marker overrides: answered" "$(status 'req D1' 'ans D1')" "answered #7 D1: B"
eq "resolved request stays resolved (no row, later chatter is not a change)" "$(status 'req D1' 'ans D1' 'res D1' 'thanks')" ""
eq "record then followup is not a change" "$(status 'rec D1' 'D1: x' 'fol D1')" ""

eq "a later comment after followup is a change again" "$(status 'rec D1' 'D1: x' 'fol D1' 'D1: also y')" "change   #7 D1: D1: also y"

# write commands: default to the newest decision, or the D<k> given (the one status printed)
thread "$T/needs.json" 'req D3' 'rec D4' 'D3: B'
: >"$T/posted"; bash "$D" resolve 7 "go" >/dev/null 2>&1
eq "resolve defaults to the newest decision" "$(head -1 "$T/posted")" "<!-- decision-resolved D4 -->"
: >"$T/posted"; bash "$D" resolve 7 "go" D3 >/dev/null 2>&1
eq "resolve D3 targets the answered request" "$(head -1 "$T/posted")" "<!-- decision-resolved D3 -->"
thread "$T/needs.json" 'rec D2' 'req D3' 'D2: change it'
: >"$T/posted"; bash "$D" followup 7 9 D2
eq "followup D2 targets the challenged record" "$(head -1 "$T/posted")" "<!-- decision-followup D2 -->"
: >"$T/posted"; bash "$D" answer 7 "B" D3
eq "answer D3 targets the named request" "$(head -1 "$T/posted")" "<!-- decision-answer D3 -->"
eq "a bad decision id is refused" "$(rc bash "$D" resolve 7 go x2)" 64
eq "an unknown decision id is refused" "$(rc bash "$D" resolve 7 go D99)" 64
eq "an id with trailing junk is refused" "$(rc bash "$D" resolve 7 go D3x)" 64
eq "a lowercase id is refused" "$(rc bash "$D" resolve 7 go d3)" 64
eq "nothing is posted for a refused id" "$(: >"$T/posted"; bash "$D" resolve 7 go D99 >/dev/null 2>&1; wc -c <"$T/posted" | tr -d ' ')" 0
thread "$T/needs.json" 'plain comment'
eq "no decision on the issue: default id is refused" "$(rc bash "$D" resolve 7 go)" 64

# footers name the D<k>: prefix (the only way for a GitHub user to reach an older decision)
thread "$T/needs.json" 'rec D1'
printf 'Pick?\n- A: x\n- B: y\n' >"$T/q.md"
: >"$T/posted"; bash "$D" request 7 "$T/q.md" >/dev/null 2>&1
eq "request footer names the prefix of its own id" "$(grep -c 'start it with `D2:`' "$T/posted")" 1
: >"$T/posted"; bash "$D" record 7 "$T/q.md" >/dev/null 2>&1
eq "record footer names the prefix of its own id" "$(grep -c 'starting with `D2:`' "$T/posted")" 1

# repo resolution: WF_REPO first, else the checkout's origin, else loud failure before anything is written
rm -rf "$T/logs"; mkdir -p "$T/scratch"; : >"$T/posted"; : >"$T/gh-env"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")")
echo "GH_REPO=${GH_REPO:-}" >>"$T/gh-env"
case "$1 $2" in
  "issue comment") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cat "$2" >>"$T/posted"; shift; done ;;
  "issue edit"|"label create") ;;
  "issue view") echo '[]' ;;
  "repo view") exit 1 ;;
  *) echo "gh stub: unexpected $*" >&2; exit 1 ;;
esac
STUB
printf 'Pick?\n- A: x\n' >"$T/q.md"
NOREPO() { (cd "$T/scratch" && env -u WF_REPO GIT_CEILING_DIRECTORIES="$T" "$@"); }
eq "outside a checkout, WF_REPO unset: note fails loudly" "$(NOREPO bash "$D" note 7 hi >/dev/null 2>&1; echo $?)" 64
eq "outside a checkout, WF_REPO unset: message names WF_REPO" "$(NOREPO bash "$D" note 7 hi 2>&1 >/dev/null | grep -c 'WF_REPO')" 1
for c in "record 7 $T/q.md" "request 7 $T/q.md" "answer 7 B" "resolve 7 go" "followup 7 9" "log 7 x" "log --path 7" "log --rm 7" "log --prune" "status" "digest"; do
  # shellcheck disable=SC2086
  eq "outside a checkout, WF_REPO unset: '$c' fails" "$(NOREPO bash "$D" $c >/dev/null 2>&1; echo $?)" 64
done
eq "nothing posted or logged when refused" "$(wc -c <"$T/posted" | tr -d ' ')/$(find "$T/logs" -type f 2>/dev/null | wc -l | tr -d ' ')" "0/0"
eq "check needs no repo" "$(NOREPO bash "$D" check "$T/ok.md" >/dev/null 2>&1; echo $?)" 0
eq "WF_REPO outside a checkout: note posts" "$(NOREPO env WF_REPO=acme/widgets bash "$D" note 7 hi >/dev/null 2>&1; echo $?)" 0
eq "WF_REPO outside a checkout: comment was posted" "$(grep -c 'decision-note' "$T/posted")" 1
eq "WF_REPO is handed to gh as GH_REPO" "$(tail -1 "$T/gh-env")" "GH_REPO=acme/widgets"
NOREPO env WF_REPO=acme/widgets bash "$D" log 7 "from scratch"
eq "WF_REPO outside a checkout: log lands under the repo" "$(ls "$T/logs/acme/widgets")" "7.md"
eq "WF_REPO ../.. (path traversal) is refused" "$(NOREPO env WF_REPO=../.. bash "$D" log 7 x >/dev/null 2>&1; echo $?)" 64
eq "WF_REPO with a newline is refused" "$(NOREPO env "WF_REPO=a/b
evil" bash "$D" note 7 hi >/dev/null 2>&1; echo $?)" 64
git -C "$T/repo" remote set-url origin https://github.com/acme/widgets/
eq "origin URL with a trailing slash still resolves" "$(cd "$T/repo" && env -u WF_REPO bash "$D" log --path 7)" "$T/logs/acme/widgets/7.md"
git -C "$T/repo" remote set-url origin https://github.com/acme/widgets.git
eq "malformed WF_REPO a/b/c is refused" "$(NOREPO env WF_REPO=a/b/c bash "$D" note 7 hi >/dev/null 2>&1; echo $?)" 64
eq "malformed WF_REPO https url is refused" "$(NOREPO env WF_REPO=https://github.com/a/b bash "$D" note 7 hi >/dev/null 2>&1; echo $?)" 64
: >"$T/gh-env"; (cd "$T/repo" && env -u WF_REPO -u GH_REPO bash "$D" note 7 hi >/dev/null 2>&1) # origin is still github here
eq "WF_REPO unset: GH_REPO stays unset (gh resolves as before)" "$(tail -1 "$T/gh-env")" "GH_REPO="
eq "malformed WF_REPO is refused" "$(NOREPO env WF_REPO=widgets bash "$D" note 7 hi >/dev/null 2>&1; echo $?)" 64
eq "WF_REPO wins over the checkout's origin" "$(cd "$T/repo" && env WF_REPO=other/thing bash "$D" log --path 7)" "$T/logs/other/thing/7.md"
eq "checkout origin used when WF_REPO is unset" "$(cd "$T/repo" && env -u WF_REPO bash "$D" log --path 7)" "$T/logs/acme/widgets/7.md"
git -C "$T/repo" remote set-url origin git@gitlab.com:acme/widgets.git
eq "a non-GitHub origin is not taken for a GitHub slug" "$(cd "$T/repo" && env -u WF_REPO bash "$D" note 7 hi >/dev/null 2>&1; echo $?)" 64

echo "decide: $((n - fail))/$n passed"
[ $fail = 0 ]
