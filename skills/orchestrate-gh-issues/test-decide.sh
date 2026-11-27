#!/usr/bin/env bash
# Tests for decide.sh check, log, digest, reply attribution (status/digest) and the decision format (request, overview check, answers) (offline, gh stubbed). Run: bash skills/orchestrate-gh-issues/test-decide.sh
set -u
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
# request: built from the question lines. tandem() mirrors what Tandem reads from a request (tandem src/core/contract.ts
# parseRequestBody, src/core/answer.ts optionKey, Feedback.tsx recommended): visible lines without `###` headings, cut at the
# first `---`; question = first line, Preview: line, options = `-`/`*`/`1.` list lines, recommendation = first line with "recommend".
tandem() {
  python3 -I -c '
import re, sys
b = open(sys.argv[1], encoding="utf-8").read()
b = re.sub(r"(?is)<details>[\s\S]*?</details>", "", b); b = re.sub(r"<!--[\s\S]*?-->", "", b)
lines = [l.rstrip() for l in b.split("\n") if not re.match(r"###\s", l)]
if "---" in [l.strip() for l in lines]: lines = lines[:[l.strip() for l in lines].index("---")]
own = [l for l in lines if l.strip()]
preview = next((l[8:].strip() for l in own if l.startswith("Preview:")), "")
content = [l for l in own if not l.startswith("Preview:")]
item = r"^\s*(?:[-*]|\d+\.)\s+"
options = [re.sub(item, "", l).strip() for l in content[1:] if re.match(item, l)]
rec = next((re.sub(r"(?i)^\**recommend(?:ation|ed)?:?\**:?\s*", "", l).strip() for l in content if re.search(r"(?i)recommend", l)), "")
keys = [o.split(":")[0].strip() for o in options]
print("question=" + content[0]); print("preview=" + preview); print("keys=" + ",".join(keys)); print("options=" + " | ".join(options))
print("recommended=" + ",".join(k for k in keys if rec and k.lower() == re.split(r"[\s(]", rec)[0].lower()))' "$1"
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
