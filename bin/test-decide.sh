#!/usr/bin/env bash
# Tests for decide.sh check, log, digest, reply attribution (status/digest) and the decision format (request, overview check, answers) (offline, gh stubbed). Run: bash bin/test-decide.sh
# The golden fixtures of the board client contract (docs/contract-fixtures/, docs/contract.md) come from this suite:
#   bash bin/test-decide.sh --write-fixtures    write them from the real writers (the default run fails when one differs)
set -u
WRITE=0; [ "${1:-}" != --write-fixtures ] || WRITE=1
unset WF_REPO GH_REPO # a caller's repo pin must not reach the stubbed gh
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
export WF_PROTO_DIR="$T/proto-serve" # never the real prototype-server registry
mkdir -p "$T/repo" "$T/bin"; git -C "$T/repo" init -q; git -C "$T/repo" remote add origin https://github.com/acme/widgets.git
cd "$T/repo" || exit 1
export WF_ISSUE_LOG_DIR="$T/logs" PATH="$T/bin:$PATH"

# gh stub: `issue list` without a label returns $T/needs.json, `issue view <n> --json state` reads $T/state-<n>.
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")")
case "$1 $2" in
  "issue list") case "$*" in *agent-decided*comments*) cat "$T/agent.json" ;; *--label*needs-decision*) [ -e "$T/nolabel" ] && echo '[]' || cat "$T/needs.json" ;; *comments*) cat "$T/needs.json" ;; *--jq*) echo 0 ;; *) echo '[]' ;; esac ;;
  "issue view") case "$*" in *"--json comments"*) jq '.[0].comments' "$T/needs.json" ;; *"--json number,url,comments"*) [ ! -e "$T/viewfail" ] || { echo "gh: could not read the issue" >&2; exit 1; }; jq '.[0]' "$T/needs.json" ;; *) cat "$T/state-$3" 2>/dev/null || echo OPEN ;; esac ;;
  "issue comment") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cat "$2" >>"$T/posted"; shift; done ;;
  "issue edit") echo "$*" >>"$T/edits" ;;
  "label create") ;;
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
change   #7 D2: D2: change it (a request on #7 is still waiting: this may be its answer under the wrong D<k>)"
eq "the same with the prefix Tandem writes (Decision D2:)" \
  "$(status 'rec D2' 'req D3' 'Decision D2: change it')" "waiting  #7 D3 (0m): Pick D3?
change   #7 D2: Decision D2: change it (a request on #7 is still waiting: this may be its answer under the wrong D<k>)"
eq "'Decision D3:' after a later record answers D3" "$(status 'req D3' 'rec D2' 'Decision D3: B')" "answered #7 D3: Decision D3: B"
eq "'Decision' without an id, or with an unknown one, attaches to the nearest marker" "$(status 'rec D1' 'rec D2' 'Decision: wait'; status 'rec D1' 'rec D2' 'Decision D9: x')" "change   #7 D2: Decision: wait
change   #7 D2: Decision D9: x"
eq "answer to D3 written after rec D2: D3 answered, D2 untouched" \
  "$(status 'req D3' 'rec D2' 'D3: B')" "answered #7 D3: D3: B"
eq "unprefixed reply keeps the nearest earlier marker (D2)" "$(status 'req D3' 'rec D2' 'B')" "waiting  #7 D3 (0m): Pick D3?
change   #7 D2: B (a request on #7 is still waiting: this may be its answer under the wrong D<k>)"
eq "unprefixed 'change D1' attaches to D1" "$(status 'rec D1' 'change D1')" "change   #7 D1: change D1"
eq "prefix naming an unknown id attaches to the nearest marker" "$(status 'rec D1' 'D9: x')" "change   #7 D1: D9: x"
eq "prefix before its request exists does not count" "$(status 'rec D1' 'D2: early' 'req D2')" "waiting  #7 D2 (0m): Pick D2?
change   #7 D1: D2: early (a request on #7 is still waiting: this may be its answer under the wrong D<k>)"
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
touch "$T/nolabel" # the needs-decision label can be gone (dropped by hand, lag): status and digest scan by comments, not by label
eq "answered request is listed although the label is gone" "$(status 'req D1' 'D1: B')" "answered #7 D1: D1: B"
eq "waiting request is listed although the label is gone" "$(status 'req D1')" "waiting  #7 D1 (0m): Pick D1?"
eq "digest lists a request although the label is gone" "$(thread "$T/needs.json" 'req D1'; bash "$D" digest | sed -n 1p)" "1 decision(s) need you:"
eq "a multi-line answer starting 'D1:' is answered" "$(thread "$T/needs.json" 'req D1' 'D1:' ; jq '.[0].comments[1].body = "D1:\n\nStep: agree\n\nEmpty: agree"' "$T/needs.json" >"$T/n2" && mv "$T/n2" "$T/needs.json"; cp "$T/needs.json" "$T/agent.json"; bash "$D" status)" "answered #7 D1: D1: Step: agree Empty: agree"
rm -f "$T/nolabel"
eq "labeled and recent scans list a request once" "$(status 'req D1')" "waiting  #7 D1 (0m): Pick D1?"

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
# resolve stops the issue's prototype server (nothing registered: no-op)
PS=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); mkdir -p "$T/ps-wt"
DUMMY_SERVER="$DIR/dummy-server.py" WF_PROTO_CMD='python3 "$DUMMY_SERVER" "$PORT"' bash "$DIR/proto-serve.sh" start 7 "$T/ps-wt" "$PS" >/dev/null 2>&1
eq "prototype server is up before resolve" "$([ -n "$(lsof -nP -tiTCP:"$PS" -sTCP:LISTEN 2>/dev/null)" ] && echo up)" up
: >"$T/posted"; bash "$D" resolve 7 "go" D3 >/dev/null 2>&1
eq "resolve stops the issue's prototype server" "$(lsof -nP -tiTCP:"$PS" -sTCP:LISTEN 2>/dev/null)" ""
eq "resolve unregisters it" "$(grep -c . "$WF_PROTO_DIR/servers.tsv")" 0

eq "a bad decision id is refused" "$(rc bash "$D" resolve 7 go x2)" 64
eq "an unknown decision id is refused" "$(rc bash "$D" resolve 7 go D99)" 64
eq "an id with trailing junk is refused" "$(rc bash "$D" resolve 7 go D3x)" 64
eq "a lowercase id is refused" "$(rc bash "$D" resolve 7 go d3)" 64
eq "nothing is posted for a refused id" "$(: >"$T/posted"; bash "$D" resolve 7 go D99 >/dev/null 2>&1; wc -c <"$T/posted" | tr -d ' ')" 0
thread "$T/needs.json" 'plain comment'
eq "no decision on the issue: default id is refused" "$(rc bash "$D" resolve 7 go)" 64

# footers name the D<k>: prefix (the only way for a GitHub user to reach an older decision)
thread "$T/needs.json" 'rec D1'
printf 'Pick?\n1 Layout: A (list, today) · B ★ (grid)\n' >"$T/q.md"
: >"$T/posted"; bash "$D" request 7 "$T/q.md" >/dev/null 2>&1
eq "request footer names the prefix of its own id" "$(grep -c 'Short form: `Decision D2: 1B`' "$T/posted")" 1
printf 'Pick?\n- A: x\n- B: y\n' >"$T/q.md"
: >"$T/posted"; bash "$D" record 7 "$T/q.md" >/dev/null 2>&1
eq "record footer names the prefix of its own id" "$(grep -c 'starting with `Decision D2:`' "$T/posted")" 1

# ---- decision format (docs/decision-format.md) ----
# request: built from the question lines. tandem() prints what a board client reads from a request, through the reference
# reader (contract_reader.py, the rules of docs/contract.md): visible lines without `###` headings, cut at the first `---`;
# question = first line, Preview: line, options = `-`/`*`/`1.` list lines, recommendation = first line with "recommend".
tandem() {
  python3 -I "$DIR/contract_reader.py" "$1" | jq -r '
    ([.options[] | split(":")[0] | gsub("^\\s+|\\s+$"; "")]) as $keys
    | ((.recommendation // "") | (split(" ")[0] // "") | (split("(")[0] // "") | ascii_downcase) as $rec
    | "question=\(.question)", "preview=\(.preview // "")", "keys=\($keys | join(","))", "options=\(.options | join(" | "))",
      "recommended=\([$keys[] | select($rec != "" and ascii_downcase == $rec)] | join(","))"'
}
thread "$T/needs.json" 'plain comment'
cat >"$T/multi.md" <<'REQ'
Setup shell: 2 choices
Preview: https://p/x?variant=1A
Overview: https://github.com/acme/widgets/issues/7#issuecomment-1
1 Shell: A (back on top, today) · B ★ (footer bar) · C (top stepper)
2 Heading: A ★ (hidden) · B (small, visible)
REQ
: >"$T/posted"; eq "request prints its id" "$(bash "$D" request 7 "$T/multi.md" 2>&1)" "D1"
cp "$T/posted" "$T/req-multi.md"
eq "request keeps the marker on line 1" "$(head -1 "$T/posted")" "<!-- decision-request D1 -->"
eq "request links the overview instead of describing the options" "$(grep -c '^Options with screenshots: https://github.com/acme/widgets/issues/7#issuecomment-1$' "$T/posted")" 1
eq "legend: one line per question, keywords in brackets, ★ bold" "$(grep -F '**1 Shell:**' "$T/posted")" "+ **1 Shell:** A (back on top, today) · **B ★ (footer bar)** · C (top stepper)"
eq "answer block is prefilled with the recommendations" "$(sed -n '/^```$/,/^```$/p' "$T/posted" | tr '\n' '|')" '```|Decision D1:|1 Shell: B (footer bar)|2 Heading: A (hidden)|```|'
eq "each option is named once outside the block (legend only)" "$(grep -c 'top stepper' "$T/posted")" 2 # its choices comment + the legend
eq "Tandem reads a multi-question request: question, preview, one tile 'ok', recommended" "$(tandem "$T/posted" | tr '\n' ';')" \
  "question=Setup shell: 2 choices;preview=https://p/x?variant=1A;keys=ok;options=ok: take every ★ option;recommended=ok;"
eq "digest shows the question and the preview of a new request" "$(jq -n --arg t "$now" --rawfile b "$T/posted" '[{number: 7, url: "u", comments: [{body: $b, createdAt: $t}]}]' >"$T/needs.json"; bash "$D" digest | sed -n '2,3p' | tr '\n' ';')" \
  "- #7 D1 (0m): Setup shell: 2 choices  u;  preview: https://p/x?variant=1A;"
printf 'Hold the merge of #641?\n1 Merge: A ★ (merge now) · B (hold, today)\n' >"$T/single.md"
thread "$T/needs.json" 'plain comment'; : >"$T/posted"; bash "$D" request 7 "$T/single.md" >/dev/null 2>&1; cp "$T/posted" "$T/req-single.md"
eq "Tandem reads a single-question request: one tile per option, the recommended one flagged" "$(tandem "$T/posted" | tr '\n' ';')" \
  "question=Hold the merge of #641?;preview=;keys=A,B;options=A: merge now ★ | B: hold (today);recommended=A;"
printf 'What should the export file be called?\nOpen question: a file name\n' >"$T/open.md"
: >"$T/posted"; bash "$D" request 7 "$T/open.md" >/dev/null 2>&1
eq "an open question posts without choices and asks for free text" "$(grep -c 'in your own words' "$T/posted")/$(tandem "$T/posted" | sed -n '1p;3p' | tr '\n' ';')" "1/question=What should the export file be called?;keys=;"
bad() { printf '%s\n' "$@" >"$T/bad.md"; : >"$T/posted"; bash "$D" request 7 "$T/bad.md" >/dev/null 2>&1; echo "$?/$(wc -c <"$T/posted" | tr -d ' ')"; }
eq "old shape (options as a list, no question lines) is refused, nothing posted" "$(bad 'Pick?' '- A: x' '- B: y' 'Recommendation: A')" "65/0"
eq "today's state as a special id is refused" "$(bad 'Pick?' '1 Shell: o (today) · A ★ (footer bar)')" "65/0"
eq "no ★ is refused" "$(bad 'Pick?' '1 Shell: A (rail) · B (footer bar)')" "65/0"
eq "two ★ are refused" "$(bad 'Pick?' '1 Shell: A ★ (rail) · B ★ (footer bar)')" "65/0"
eq "more than 3 keywords are refused" "$(bad 'Pick?' '1 Shell: A ★ (rail with back on top) · B (footer bar)')" "65/0"
eq "letters out of order are refused" "$(bad 'Pick?' '1 Shell: A ★ (rail) · C (footer bar)')" "65/0"
eq "questions out of order are refused" "$(bad 'Pick?' '2 Shell: A ★ (rail) · B (footer bar)')" "65/0"
eq "a body list line (a Tandem option tile) is refused" "$(bad 'Pick?' '1 Shell: A ★ (rail) · B (footer bar)' '- stays parked: build')" "65/0"
eq "a body line Tandem would read as the recommendation is refused" "$(bad 'Pick?' '1 Shell: A ★ (rail) · B (footer bar)' 'I recommend A.')" "65/0"
eq "a body --- (Tandem stops reading there) is refused" "$(bad 'Pick?' '1 Shell: A ★ (rail) · B (footer bar)' '---')" "65/0"
# a request without a round carries its overview itself
inline() { bad 'Hold the merge?' '1 Merge: A ★ (merge now) · B (hold, today)' '' "$1" '' '| | Option | In short |' '|---|---|---|' '| **A ★** | Merge now | CI is green |' '| B | Hold (today) | wait for the review |' '' "$2"; }
eq "inline overview passes" "$(inline '### 1. Merge: now or after the review' '★ Why A: nothing is open.' | cut -d/ -f1)" 0
eq "inline overview: 'above in this comment'" "$(grep -c '^Options with screenshots: above in this comment$' "$T/posted")" 1
eq "inline overview does not change what Tandem reads" "$(tandem "$T/posted" | sed -n '1p;3p;5p' | tr '\n' ';')" "question=Hold the merge?;keys=A,B;recommended=A;"
eq "inline overview that disagrees with the question lines is refused" "$(inline '### 1. Ship: now or after the review' '★ Why A: nothing is open.')" "65/0"
eq "inline overview without the why line is refused" "$(inline '### 1. Merge: now or after the review' 'Because.')" "65/0"

# check: the overview shape of a round or options note
round() { printf '%s\n' '<!-- decision-note round R1 -->' '## Design round 1: Setup shell' 'Preview: https://p/x' "$@" >"$T/round.md"; rc bash "$D" check "$T/round.md"; }
SEC1=('### 1. Shell: where back and next sit' '' '| | Option | In short |' '|---|---|---|' '| A | Rail, back on top (today) | back above |' '| **B ★** | Rail, footer bar | Zurück left |' '' '★ Why B: back and main action sit together.' '' '![R1 · 1. Shell · desktop](https://x/1.png)')
SEC2=('### 2. Heading: the step heading' '' '| | Option | In short |' '|---|---|---|' '| **A ★** | Hidden | rail names the step |' '| B | Small, visible | heading in the pane |' '' '★ Why A: say it once.')
DET=('' '<details><summary>Stories, checks, build cost, dropped</summary>' '' 'Dropped: three shells' '</details>')
eq "round in the new shape passes" "$(round 'Variants: 1A, 1B, 2A, 2B' "${SEC1[@]}" '' "${SEC2[@]}" "${DET[@]}")" 0
eq "round: Variants line must list the short keys (Tandem's picks)" "$(round 'Variants: a, b' "${SEC1[@]}")" 65
eq "round: old variant heading is refused" "$(round 'Variants: o, a' '### o: A Rail, back on top' 'Back on top')" 65
eq "round: old axis heading beside a question is refused" "$(round 'Variants: 1A, 1B' "${SEC1[@]}" '' '### heading o: hidden')" 65
eq "round: a closing Question line is refused" "$(round 'Variants: 1A, 1B' "${SEC1[@]}" '' '**Question:** Which shell (A or B)?')" 65
eq "round: an image outside its question is refused" "$(round 'Variants: 1A, 1B' '![R1 · 1. Shell · desktop](https://x/0.png)' "${SEC1[@]}")" 65
eq "round: an image inside <details> is refused" "$(round 'Variants: 1A, 1B' "${SEC1[@]}" '' '<details><summary>More</summary>' '' '![R1 · 1. Shell · mobile](https://x/2.png)' '</details>')" 65
eq "round: image alt must name its question the way the heading does" "$(round 'Variants: 1A, 1B' "${SEC1[@]:0:9}" '![1 Shell: A, B](https://x/1.png)')" 65
eq "round: two <details> are refused" "$(round 'Variants: 1A, 1B' "${SEC1[@]}" "${DET[@]}" "${DET[@]}")" 65
eq "round: sections after <details> are refused" "$(round 'Variants: 1A, 1B, 2A, 2B' "${SEC1[@]}" "${DET[@]}" '' "${SEC2[@]}")" 65
eq "round: a table right under the heading is refused (Tandem shows that line as the summary)" "$(round 'Variants: 1A, 1B' "${SEC1[0]}" "${SEC1[@]:2}")" 65
eq "round: no ★ row is refused" "$(round 'Variants: 1A, 1B' '### 1. Shell: where' '' '| A | Rail | x |' '| B | Bar | y |')" 65
printf '%s\n' '<!-- decision-note options -->' 'Storage for the export' '' '### 1. Storage: where the export lives' '' '| | Option | In short |' '|---|---|---|' '| **A ★** | File | simplest |' '| B | Database | queryable |' '' '★ Why A: no migration.' >"$T/opts.md"
eq "options note in the new shape passes" "$(rc bash "$D" check "$T/opts.md")" 0
printf '%s\n' '<!-- decision-note options -->' 'Storage' '- A: file' '- B: database' 'Recommendation: A' >"$T/opts.md"
eq "options note in the old shape is refused" "$(rc bash "$D" check "$T/opts.md")" 65
printf '%s\n' '<!-- decision-note look -->' '### Look: x' 'Check:' '- one' >"$T/look.md"
eq "other notes are not shape-checked" "$(rc bash "$D" check "$T/look.md")" 0

# answers: ok, the block, the short form, what Tandem writes; anything else stays free text
answered() { jq -n --arg t "$now" --rawfile b "$1" --arg a "$2" '[{number: 7, url: "u", comments: [{body: $b, createdAt: $t}, {body: $a, createdAt: $t}]}]' >"$T/needs.json"; cp "$T/needs.json" "$T/agent.json"; bash "$D" status | sed -n 2p; }
M="$T/req-multi.md"; S="$T/req-single.md"
eq "ok takes every recommendation" "$(answered "$M" 'ok')" "  reads as: 1 Shell: B (footer bar) · 2 Heading: A (hidden)"
eq "'all recommended' does too" "$(answered "$M" 'D1: all recommended')" "  reads as: 1 Shell: B (footer bar) · 2 Heading: A (hidden)"
eq "the block form, stale brackets ignored, text after the letter is a note" "$(answered "$M" 'D1
1 Shell: C (footer bar) but calmer
2 Heading: A (hidden)')" "  reads as: 1 Shell: C (top stepper), note: but calmer · 2 Heading: A (hidden)"
eq "the short form" "$(answered "$M" '1A 2b')" "  reads as: 1 Shell: A (back on top, today) · 2 Heading: B (small, visible)"
eq "a mixed answer (one question, two options) stays free text" "$(answered "$M" '1B with the header from 1A')" ""
eq "a partial answer names what is missing" "$(answered "$M" 'D1: 1C')" "  reads as: 1 Shell: C (top stepper) · 2 Heading: no answer (★ is A)"
eq "Tandem's tile answer with a note (D1: ok. 1A)" "$(answered "$M" 'D1: ok. 1A')" "  reads as: 1 Shell: A (back on top, today) · 2 Heading: A (hidden)"
eq "Tandem's answers start with 'Decision D1:': ok with changes" "$(answered "$M" 'Decision D1: ok. 1A')" "  reads as: 1 Shell: A (back on top, today) · 2 Heading: A (hidden)"
eq "Decision D1: ok" "$(answered "$M" 'Decision D1: ok')" "  reads as: 1 Shell: B (footer bar) · 2 Heading: A (hidden)"
eq "Decision D1: the short form" "$(answered "$M" 'Decision D1: 1C 2B')" "  reads as: 1 Shell: C (top stepper) · 2 Heading: B (small, visible)"
eq "Decision D1: one line per question, the first on the prefix line, a note after its letter" "$(answered "$M" 'Decision D1: 1 Shell: C (Top stepper) but calmer
2 Heading: A (Hidden)')" "  reads as: 1 Shell: C (top stepper), note: but calmer · 2 Heading: A (hidden)"
eq "the copied template (Decision D1: on its own line)" "$(answered "$M" 'Decision D1:
1 Shell: B (footer bar)
2 Heading: B (small, visible)')" "  reads as: 1 Shell: B (footer bar) · 2 Heading: B (small, visible)"
eq "Decision D1: a single question with a note" "$(answered "$S" 'Decision D1: B. wait for the review')" "  reads as: 1 Merge: B (hold, today)"
eq "Tandem's round reaction: picks count, rejects do not" "$(answered "$M" 'R1:
- pick: 1C, 2B
- reject: 1A

calmer please')" "  reads as: 1 Shell: C (top stepper) · 2 Heading: B (small, visible)"
eq "Tandem's tile answer on a single question (D1: B. note)" "$(answered "$S" 'D1: B. wait for the review')" "  reads as: 1 Merge: B (hold, today)"
eq "a bare letter on a single question" "$(answered "$S" 'a')" "  reads as: 1 Merge: A (merge now)"
eq "free text stays free text" "$(answered "$M" 'B but with the heading of the old one'; bash "$D" status | wc -l | tr -d ' ')" "1"
eq "an unknown letter is not a choice" "$(answered "$M" '1D')" ""
eq "the raw answer still leads the status row" "$(answered "$M" 'ok' >/dev/null; bash "$D" status | sed -n 1p)" "answered #7 D1: ok"
eq "an old-format request still reads as before" "$(status 'req D1' 'D1: B')" "answered #7 D1: D1: B"
answered "$M" 'ok' >/dev/null
: >"$T/posted"; eq "resolve prints the choices spelled out" "$(bash "$D" resolve 7 '1A 2B' D1 2>/dev/null)" "resumed D1 with: 1 Shell: A (back on top, today) · 2 Heading: B (small, visible) (answer: 1A 2B)"
eq "resolve keeps its marker and says how the answer was read" "$(tr '\n' '|' <"$T/posted")" "<!-- decision-resolved D1 -->|Resumed (D1) with: 1 Shell: A (back on top, today) · 2 Heading: B (small, visible).|"
eq "the resume text reaches the coordination log" "$(grep -c 'resumed D1 with: 1 Shell: A' "$(bash "$D" log --path 7)")" 1
: >"$T/posted"; eq "resolve passes free text on as it is" "$(bash "$D" resolve 7 'B but calmer' D1 2>/dev/null)/$(sed -n 2p "$T/posted")" "resumed D1 with: B but calmer/Resumed (D1)."
bash "$D" log --rm 7

# resume: a stage's Resume step for one issue (none / waiting / answered), reference/decisions.md
resume() { : >"$T/posted"; : >"$T/edits"; out=$(bash "$D" resume 7 2>/dev/null); code=$?; }
wrote() { echo "$(wc -c <"$T/posted" | tr -d ' ')/$(wc -c <"$T/edits" | tr -d ' ')"; }
rm -rf "$T/logs"
thread "$T/needs.json" 'plain comment'; resume
eq "resume, no request: none" "$code/$out" "0/none"
eq "resume none writes nothing" "$(wrote)/$(ls "$T/logs" 2>/dev/null | wc -l | tr -d ' ')" "0/0/0"
thread "$T/needs.json" 'req D1'; resume
eq "resume, unanswered request: exit 2 and the waiting line" "$code/$(printf '%s\n' "$out" | sed -n 1p)" "2/waiting  #7 D1 (0m): Pick D1?"
eq "resume waiting says how to go on" "$(printf '%s\n' "$out" | sed -n 2p)" "Answer on the issue (u), then run the stage again. Nothing was changed."
eq "resume waiting writes nothing" "$(wrote)" "0/0"
thread "$T/needs.json" 'req D1' 'ans D1' 'res D1' 'req D2' 'D1: late'; resume
eq "resume names the waiting decision, not a resolved one" "$code/$(printf '%s\n' "$out" | sed -n 1p)" "2/waiting  #7 D2 (0m): Pick D2?"
thread "$T/needs.json" 'req D1' 'req D2' 'Decision D1: B'; resume
eq "resume with one request answered and one waiting: waiting, nothing written" "$code/$(printf '%s\n' "$out" | sed -n 1p)/$(wrote)" "2/waiting  #7 D2 (0m): Pick D2?/0/0"
bash "$D" log 7 "parked D1 at build step 4, next: migration"
thread "$T/needs.json" 'req D1' 'Decision D1: B'; resume
eq "resume, answered: resolves with the answer" "$code/$(printf '%s\n' "$out" | sed -n 1p)" "0/resumed D1 with: Decision D1: B"
eq "resume answered posts the Resumed comment and drops the label" "$(head -1 "$T/posted")/$(cat "$T/edits")" "<!-- decision-resolved D1 -->/issue edit 7 --remove-label needs-decision"
eq "resume answered prints the log path" "$(printf '%s\n' "$out" | sed -n 2p)" "log: $T/logs/acme/widgets/7.md"
eq "resume answered prints the log entries, the parked step and the resume line" "$(printf '%s\n' "$out" | sed -n '3,$p' | sed 's/^- [^ ]* //' | tr '\n' '|')" "parked D1 at build step 4, next: migration|resumed D1 with: Decision D1: B|"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do bash "$D" log 7 "entry $i"; done
resume
eq "resume prints only the last 20 log entries" "$(printf '%s\n' "$out" | grep -c '^- ')/$(printf '%s\n' "$out" | tail -1 | sed 's/^- [^ ]* //')" "20/resumed D1 with: Decision D1: B"
thread "$T/needs.json" 'req D1' 'Decision D1: B' 'res D1'; resume
eq "resume after a resolve: none, nothing written (idempotent; under Orca the coordinator resolved first)" "$code/$(printf '%s\n' "$out" | sed -n 1p)/$(wrote)" "0/none/0/0"
eq "none after an answer was taken still shows the log, so a run that died after the resolve is not lost" "$(printf '%s\n' "$out" | sed -n 2p)/$(printf '%s\n' "$out" | grep -c '^- .* resumed D1 with: Decision D1: B')" "log: $T/logs/acme/widgets/7.md/1"
bash "$D" log 7 "build goes on at step 4"; resume
eq "none shows no log once a later entry follows the resumed one (a later stage is not sent back)" "$code/$out" "0/none"
long=$(python3 -c 'print("B, and then: " + "word " * 500 + "the end")')
jq -n --arg t "$now" --arg a "$long" '[{number: 7, url: "u", comments: [{body: "<!-- decision-request D1 -->\nPick D1?", createdAt: $t}, {body: $a, createdAt: $t}]}]' >"$T/needs.json"; resume
eq "resume passes a long answer on in full (status shows 1000 chars of it)" "$(printf '%s\n' "$out" | sed -n 1p | grep -c 'the end$')/$(bash "$D" status | sed -n 1p | grep -c 'the end$')" "1/0"
eq "the log keeps one screen of a long answer and marks the cut" "$(tail -1 "$T/logs/acme/widgets/7.md" | grep -c ' … (cut: the full answer is the comment on the issue)$')/$(tail -1 "$T/logs/acme/widgets/7.md" | wc -c | awk '{print ($1 < 1200) ? "short" : "long"}')" "1/short"
jq -n --arg t "$now" --arg a "$(python3 -c 'print("x" * 20500)')" '[{number: 7, url: "u", comments: [{body: "<!-- decision-request D1 -->\nPick D1?", createdAt: $t}, {body: $a, createdAt: $t}]}]' >"$T/needs.json"; resume
eq "an answer over 20000 chars is marked as cut" "$(printf '%s\n' "$out" | sed -n 1p | grep -c 'x … (cut: the full answer is the comment on the issue)$')" 1
rm -rf "$T/logs"; mkdir -p "$T/logs/acme"; : >"$T/logs/acme/widgets" # the log cannot be written: a file sits where its directory goes
thread "$T/needs.json" 'req D1' 'Decision D1: B'; : >"$T/posted"; : >"$T/edits"; out=$(bash "$D" resume 7 2>"$T/err"); code=$?
eq "resume without a writable log still resolves and says there is no log" "$code/$(printf '%s\n' "$out" | tr '\n' '|')/$(grep -c 'No such file\|Not a directory' "$T/err" | tr -d ' ')" "0/resumed D1 with: Decision D1: B|log: $T/logs/acme/widgets/7.md (no log on this machine)|/0"
rm -rf "$T/logs"
thread "$T/needs.json" 'req D1' 'ans D1'; resume
eq "resume takes an answer the coordinator posted" "$code/$(printf '%s\n' "$out" | sed -n 1p)" "0/resumed D1 with: B"
thread "$T/needs.json" 'rec D1' 'Decision D1: change it'; resume
eq "resume leaves a change request on a record alone" "$code/$(printf '%s\n' "$out" | sed -n 1p)/$(wrote)" "0/none/0/0"
jq -n --arg t "$now" --rawfile b "$T/req-multi.md" '[{number: 7, url: "u", comments: [{body: $b, createdAt: $t}, {body: "ok", createdAt: $t}]}]' >"$T/needs.json"; resume
eq "resume spells an ok out against the request's choices" "$(printf '%s\n' "$out" | sed -n 1p)" "resumed D1 with: 1 Shell: B (footer bar) · 2 Heading: A (hidden) (answer: ok)"
touch "$T/viewfail"; thread "$T/needs.json" 'req D1' 'Decision D1: B'; resume; rm -f "$T/viewfail"
n=$((n + 1)); { [ "$code" != 0 ] && [ "$code" != 2 ] && [ -z "$out" ] && [ "$(wrote)" = "0/0" ]; } || { fail=$((fail + 1)); echo "FAIL [resume when the issue cannot be read: an error, never none or waiting, nothing written] got '$code/$out/$(wrote)'"; }
eq "resume without an issue number is a usage error" "$(rc bash "$D" resume)/$(rc bash "$D" resume x7)" "64/64"
rm -rf "$T/logs"; thread "$T/needs.json" 'plain comment'; bash "$D" request 7 "$T/single.md" >/dev/null 2>&1
eq "request logs where the issue parked" "$(sed 's/^- [^ ]* //' "$T/logs/acme/widgets/7.md" | tail -1)" "parked D1: $(sed -n 1p "$T/single.md")"
eq "the usage lists resume" "$(bash "$D" | grep -c 'decide.sh resume  <n>')" 1
eq "the usage ends with the header's last line" "$(bash "$D" | tail -1 | cut -c1-28)" "GitHub's label filter lags a"

# hold (docs/contract.md, reference/decisions.md "Hold"): an issue labelled on-hold starts no stage, whatever its requests say
hold() { jq '.[0].labels = [{name: "needs-spec"}, {name: "on-hold"}]' "$T/needs.json" >"$T/n2" && mv "$T/n2" "$T/needs.json"; }
rm -rf "$T/logs"; thread "$T/needs.json" 'plain comment'; hold; resume
eq "resume on an on-hold issue: held, exit 2" "$code/$(printf '%s\n' "$out" | sed -n 1p)" "2/held  #7: label on-hold"
eq "held says how to go on" "$(printf '%s\n' "$out" | sed -n 2p)" "Remove the label to go on, then run the stage again. Nothing was changed."
thread "$T/needs.json" 'req D1' 'Decision D1: B'; hold; resume
eq "held wins over an answered request: nothing resolved, nothing written" "$code/$(printf '%s\n' "$out" | sed -n 1p)/$(wrote)/$(ls "$T/logs" 2>/dev/null | wc -l | tr -d ' ')" "2/held  #7: label on-hold/0/0/0"
thread "$T/needs.json" 'req D1'; hold; resume
eq "held wins over a waiting request" "$code/$(printf '%s\n' "$out" | sed -n 1p)" "2/held  #7: label on-hold"
thread "$T/needs.json" 'req D1' 'Decision D1: B'; jq '.[0].labels = [{name: "on-hold-after-spec"}, {name: "do-not-merge"}]' "$T/needs.json" >"$T/n2" && mv "$T/n2" "$T/needs.json"; resume
eq "the merge-only hold labels do not stop a stage" "$code/$(printf '%s\n' "$out" | sed -n 1p)" "0/resumed D1 with: Decision D1: B"
eq "the usage lists held" "$(bash "$D" | grep -c 'held  #<n>: label on-hold')" 1

# ---- golden fixtures of the board client contract (docs/contract.md, docs/contract-fixtures/) ----
# Each <name>.md is a comment exactly as its writer posts it (decide.sh with the stubbed gh), or an exemplar in the documented
# shape (round: the Overview example of docs/decision-format.md; look: the Build skill's template); <name>.json is what a
# client reads from it (contract_reader.py). Regenerate with --write-fixtures; a client vendors the directory.
ROOT=$(cd "$DIR/.." && pwd); FIX="$ROOT/docs/contract-fixtures"; G="$T/golden"; mkdir -p "$G"; rm -rf "$T/logs"
posts() { name=$1; shift; : >"$T/posted"; "$@" >/dev/null 2>&1; cp "$T/posted" "$G/$name.md"; } # posts <name> <command...>
writers=""; fixture() { writers="$writers$1"$'\t'"$2"$'\n'; } # fixture <name> <writer>
cat >"$T/f-multi.md" <<'REQ'
Setup shell: 2 choices
Preview: https://preview.example/setup?variant=1A
Overview: https://github.com/acme/widgets/issues/7#issuecomment-1
1 Shell: A (back on top, today) · B ★ (footer bar) · C (top stepper)
2 Heading: A ★ (hidden) · B (small, visible)
REQ
printf 'Hold the merge of the setup shell?\n1 Merge: A ★ (merge now) · B (hold, today)\n' >"$T/f-single.md"
printf 'What should the export file be called?\nOpen question: a file name\n' >"$T/f-open.md"
printf 'Storage for the export\nChosen: a file in the data folder\nAlternatives: a database table\nWhy: no migration\nCost to switch: low\n' >"$T/f-record.md"
thread "$T/needs.json" 'plain comment'
posts request-multi bash "$D" request 7 "$T/f-multi.md"; fixture request-multi "decide.sh request (several questions)"
posts request-single bash "$D" request 7 "$T/f-single.md"; fixture request-single "decide.sh request (one question)"
posts request-open bash "$D" request 7 "$T/f-open.md"; fixture request-open "decide.sh request (Open question)"
posts record bash "$D" record 7 "$T/f-record.md"; fixture record "decide.sh record"
jq -n --arg t "$now" --rawfile b "$G/request-multi.md" '[{number: 7, url: "u", comments: [{body: $b, createdAt: $t}]}]' >"$T/needs.json"
posts answer bash "$D" answer 7 "1A 2B" D1; fixture answer "decide.sh answer"
posts resolved bash "$D" resolve 7 "1A 2B" D1; fixture resolved "decide.sh resolve"
thread "$T/needs.json" 'rec D1' 'Decision D1: change it'
posts followup bash "$D" followup 7 9 D1; fixture followup "decide.sh followup"
# the coordination log: two lines written by `decide.sh log`, with a fixed clock (a date stub for these two calls only)
mkdir -p "$T/clock"; printf '#!/bin/sh\ncat "%s/clock/now"\n' "$T" >"$T/clock/date"; chmod +x "$T/clock/date"; rm -rf "$T/logs"
echo 2026-01-05T09:30Z >"$T/clock/now"; PATH="$T/clock:$PATH" bash "$D" log 7 "Build started on feat/7-setup-shell"
echo 2026-01-05T10:12Z >"$T/clock/now"; PATH="$T/clock:$PATH" bash "$D" log 7 "PR: https://github.com/acme/widgets/pull/8"
cp "$T/logs/acme/widgets/7.md" "$G/coordination-log.md"; fixture coordination-log "decide.sh log"; rm -rf "$T/logs"
# exemplars: the documented shapes an agent fills in
awk '/^```markdown$/ {on = 1; next} on && /^```$/ {exit} on' "$ROOT/docs/decision-format.md" >"$G/round.md"; fixture round "the Overview example of docs/decision-format.md"
eq "the round exemplar passes the overview check" "$(rc bash "$D" check "$G/round.md")" 0
cp "$FIX/look.md" "$G/look.md" 2>/dev/null || : >"$G/look.md"; fixture look "the Look template of skills/aw-build/SKILL.md (kept by hand)"
eq "the look exemplar passes the comment check" "$(rc bash "$D" check "$G/look.md")" 0
# its lines start the way the template's lines do, in the template's order (the text before each <placeholder>)
tpl=$(awk '/^   <!-- decision-note look -->$/ {on = 1} on && /^   ```$/ {exit} on' "$ROOT/skills/aw-build/SKILL.md" | sed 's/^   //; s/<[^!].*$//')
follows() { # follows <file>; stdin: the template's line starts. Prints each line of <file> that starts otherwise
  local i=0 want got
  while IFS= read -r want; do
    i=$((i + 1)); got=$(sed -n "${i}p" "$1")
    case "$got" in "$want"*) ;; *) echo "line $i: want '$want…' got '$got'" ;; esac
  done
}
eq "the look exemplar follows the Build skill's template" "$(printf '%s\n' "$tpl" | follows "$G/look.md")/$(printf '%s\n' "$tpl" | wc -l | tr -d ' ')" "/6"
for f in "$G"/*.md; do python3 -I "$DIR/contract_reader.py" "$f" >"${f%.md}.json"; done
# answers.json: the replies a client writes (picks and notes are what the user chose in the client; null = typed by hand),
# and how decide.sh reads each one against its request (`reads_as` null = passed on as free text)
: >"$T/answers.jsonl"
ans() { # ans <form> <request fixture> <text> <picks json> <notes json> [<more fields json>]
  local more=${6:-}; [ -n "$more" ] || more='{}'
  jq -nc --arg f "$1" --arg r "$2" --arg t "$3" --argjson p "$4" --argjson n "$5" --argjson x "$more" \
    --arg ra "$(python3 -I "$DIR/decision_format.py" read "$(cat "$G/$2.md")" "$3" 2>/dev/null)" \
    '{form: $f, request: $r, text: $t, picks: $p, notes: $n, reads_as: (if $ra == "" then null else $ra end)} + $x' >>"$T/answers.jsonl"
}
ans ok request-multi 'Decision D1: ok' '{}' '{}'
ans ok-with-changes request-multi 'Decision D1: ok. 1A' '{"1": "A"}' '{}'
ans ok-with-changes request-multi 'Decision D1: ok. 1C 2B' '{"1": "C", "2": "B"}' '{}'
ans lines request-multi $'Decision D1: 1 Shell: C (top stepper) but calmer\n2 Heading: A (hidden)' '{"1": "C"}' '{"1": "but calmer"}'
ans letter request-single 'Decision D1: A' '{}' '{}'
ans letter request-single 'Decision D1: B. wait for the review' '{"1": "B"}' '{"1": "wait for the review"}'
ans typed request-multi 'ok' null null
ans typed request-multi '1B 2A' null null
ans typed request-multi $'Decision D1:\n1 Shell: B (footer bar)\n2 Heading: B (small, visible)' null null
ans typed request-single 'B' null null
ans free-text request-open 'Decision D1: export-2026.csv' null null
ans verdict request-single 'Decision D1: Approve: merge' null null '{"verdict": "approve", "note": ""}'
ans verdict request-single 'Decision D1: Hold' null null '{"verdict": "hold", "note": ""}'
ans verdict request-single 'Decision D1: Send back. the header is cut off on a phone' null null '{"verdict": "send-back", "note": "the header is cut off on a phone"}'
ans round-reaction request-multi $'R1:\n- pick: 1C, 2B\n- reject: 1A\n\ncalmer please' null null '{"round": 1, "round_picks": ["1C", "2B"], "round_rejects": ["1A"], "comment": "calmer please"}'
jq -s '{contract: 1, answers: .}' "$T/answers.jsonl" >"$G/answers.json"
eq "answers.json: every form a client builds from picks reads as choices" "$(jq -r '[.answers[] | select(.picks != null and .reads_as == null)] | length' "$G/answers.json")" 0
eq "answers.json: a PR verdict is passed on as free text, never read as a letter" "$(jq -r '[.answers[] | select(.form == "verdict") | .reads_as] | unique | tojson' "$G/answers.json")" "[null]"
eq "answers.json: a note and a changed pick are read" "$(jq -r '.answers[3].reads_as' "$G/answers.json")" "1 Shell: C (top stepper), note: but calmer · 2 Heading: A (hidden)"
printf '%s' "$writers" | jq -Rn '{contract: 1, doc: "docs/contract.md", fixtures: [inputs | split("\t") | {name: .[0], body: "\(.[0]).md", expect: "\(.[0]).json", writer: .[1]}], answers: "answers.json"}' >"$G/manifest.json"
eq "the manifest's contract version is the one in the title of docs/contract.md" "$(sed -n 1p "$ROOT/docs/contract.md")" "# Board client contract v$(jq -r .contract "$G/manifest.json")"
# what the reference reader gets from the exemplars and the log (the request cases are pinned by tandem() above)
eq "reader: the round's variants, questions and the shot under each" "$(jq -c '[.marker.round, .variants, [.questions[] | [.n, .label, ([.options[] | select(.recommended) | .letter] | join("")), .shots]]]' "$G/round.json")" '[1,["1A","1B","1C","2A","2B"],[[1,"Shell","B",[0]],[2,"Heading","A",[1]]]]'
eq "reader: the look's fields" "$(jq -c '[.headline, .path, (.checks | length), [.screenshots[] | .viewport + "/" + .state]]' "$G/look.json")" '["the setup sheet keeps back and next in one footer bar","/setup?seed=demo",3,["desktop/step 2","mobile/step 2"]]'
eq "reader: the log's lines" "$(jq -c '[.lines[] | .at]' "$G/coordination-log.json")" '["2026-01-05T09:30Z","2026-01-05T10:12Z"]'
eq "reader: the answer without its prefix, a record's title" "$(jq -r .answer "$G/answer.json")/$(jq -r .title "$G/record.json")" "1A 2B/Storage for the export"
if [ "$WRITE" = 1 ]; then
  mkdir -p "$FIX"; cp "$G"/* "$FIX"/; echo "wrote $(ls "$G" | wc -l | tr -d ' ') files to docs/contract-fixtures/"
fi
drift=""; for f in "$G"/*; do cmp -s "$f" "$FIX/$(basename "$f")" || drift="$drift $(basename "$f")"; done
for f in "$FIX"/*; do [ -e "$G/$(basename "$f")" ] || drift="$drift $(basename "$f")(not generated: delete it)"; done
eq "docs/contract-fixtures/ is what the writers and the reader produce (bash bin/test-decide.sh --write-fixtures)" "$drift" ""

# repo resolution: WF_REPO first, else the checkout's origin, else loud failure before anything is written
rm -rf "$T/logs"; mkdir -p "$T/scratch"; : >"$T/posted"; : >"$T/gh-env"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
T=$(dirname "$(dirname "$0")")
echo "GH_REPO=${GH_REPO:-}" >>"$T/gh-env"
case "$1 $2" in
  "issue comment") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cat "$2" >>"$T/posted"; shift; done ;;
  "issue edit") echo "$*" >>"$T/edits" ;;
  "label create") ;;
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
