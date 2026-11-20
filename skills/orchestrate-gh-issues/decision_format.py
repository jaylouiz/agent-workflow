#!/usr/bin/env python3
"""The decision format (docs/decision-format.md), used by decide.sh. One place builds a request, checks an overview
and reads an answer, so the three cannot drift.

  decision_format.py request <file> <D-id>     print the request comment built from <file>, or exit 65 with the reason
  decision_format.py check <file>              shape of an overview comment (round or options note); exit 65 with the reason
  decision_format.py read <choices> <answer>   print the answer spelled out (`1 Shell: B (footer bar) · …`), or nothing
                                               when it cannot be read (the caller then passes the text on as it is)

A decision has questions `1`, `2`, … with options `A`, `B`, …; one option per question carries `★` (recommended),
today's state is an ordinary option tagged `today`. Tandem (the user's board) reads these comments too: see
"Tandem" in docs/decision-format.md before changing a line this file writes.
"""
import re
import sys

DOC = "~/.claude/agent-workflow/docs/decision-format.md"
QUESTION = re.compile(r"^(\d+) ([^:|]+): (.+)$")
OPTION = re.compile(r"^([A-Z])( ★)? \(([^()]+)\)$")
SECTION = re.compile(r"^### (\d+)\. ([^:]+): (\S.*)$")
ROW = re.compile(r"^\|\s*\**([A-Z])( ★)?\**\s*\|(.*)\|(.*)\|\s*$")
IMAGE = re.compile(r"!\[([^\]]*)\]\([^)]*\)|<img\b[^>]*>")
LIST = re.compile(r"^\s*(?:[-*]|\d+\.)\s+")


class Bad(Exception):
    pass


def letters(n):
    return [chr(ord("A") + i) for i in range(n)]


# ---- choices: `1 Shell: A (back on top, today) · B ★ (footer bar) · C (top stepper)` ----

def parse_question(line):
    """One question line, or None when the line is not one. Raises Bad when it tries to be one and is malformed."""
    m = QUESTION.match(line.strip())
    if not m or not re.match(r"A( ★)? \(", m.group(3)):
        return None
    n, label, rest = int(m.group(1)), m.group(2).strip(), m.group(3)
    opts = []
    for part in rest.split(" · "):
        o = OPTION.match(part.strip())
        if not o:
            raise Bad(f"question {n}: cannot read the option '{part.strip()}'. Shape: `{n} {label}: A (1 to 3 keywords) · B ★ (keywords) · C (keywords, today)`.")
        words = [p.strip() for p in o.group(3).split(",") if p.strip()]
        keywords = " ".join(w for w in words if w != "today").split()
        if not 1 <= len(keywords) <= 3:
            raise Bad(f"question {n} option {o.group(1)}: '{o.group(3)}' has {len(keywords)} keywords, 1 to 3 are allowed (`today` is a tag and does not count).")
        opts.append({"key": o.group(1), "rec": bool(o.group(2)), "text": o.group(3).strip(), "today": "today" in words,
                     "name": ", ".join(w for w in words if w != "today")})
    if [o["key"] for o in opts] != letters(len(opts)) or len(opts) < 2:
        raise Bad(f"question {n}: options are lettered A, B, C … in order, at least two (today's state is an ordinary option tagged `today`).")
    if sum(o["rec"] for o in opts) != 1:
        raise Bad(f"question {n}: exactly one option carries ★ (the recommendation).")
    if sum(o["today"] for o in opts) > 1:
        raise Bad(f"question {n}: only one option can be `today`.")
    return {"n": n, "label": label, "opts": opts}


def numbered(qs):
    if [q["n"] for q in qs] != list(range(1, len(qs) + 1)):
        raise Bad("questions are numbered 1, 2, 3 … in order.")
    return qs


def rec(q):
    return next(o for o in q["opts"] if o["rec"])


def choice_line(q):
    return f"{q['n']} {q['label']}: " + " · ".join(f"{o['key']}{' ★' if o['rec'] else ''} ({o['text']})" for o in q["opts"])


def spell(q, key):
    o = next(o for o in q["opts"] if o["key"] == key)
    return f"{q['n']} {q['label']}: {key} ({o['text']})"


# ---- overview: one `### <n>. <label>: <what it decides>` section per question, with an option table ----

def strip_comments(text):
    return re.sub(r"(?s)<!--.*?-->", "", text)


def overview(text):
    """The questions an overview shows: [{n, label, keys, rec}]. Raises Bad on a shape error."""
    lines = strip_comments(text).splitlines()
    secs, cur, in_details, details, after_details = [], None, False, 0, False
    for i, raw in enumerate(lines):
        line = raw.rstrip()
        if re.search(r"(?i)<details", line):
            in_details, details, cur = True, details + 1, None
            if details > 1:
                raise Bad("more than one <details> block. Secondary detail (stories, checks, build cost, dropped variants, per-option detail) goes into ONE collapsed <details> at the end.")
        if in_details:
            if IMAGE.search(line):
                raise Bad("an image sits inside <details>. Put each image open, directly under the question it belongs to.")
            if re.search(r"(?i)</details>", line):
                in_details, after_details = False, True
            continue
        if after_details and line.strip():
            raise Bad("text follows the <details> block. The one <details> block comes last.")
        if line.startswith("### "):
            m = SECTION.match(line)
            if not m:
                raise Bad(f"heading '{line}': an overview has one section per question, `### <n>. <label>: <what it decides>`, and names each option once, as a row of that section's table (| A | name (today) | in short |, the recommended row `| **B ★** |`). See {DOC}.")
            if i + 1 < len(lines) and lines[i + 1].strip():
                raise Bad(f"heading '{line}': leave the next line blank (Tandem shows that line as the section's summary).")
            cur = {"n": int(m.group(1)), "label": m.group(2).strip(), "keys": [], "recs": [], "today": 0, "why": None, "alts": []}
            secs.append(cur)
            continue
        if re.match(r"^\**Question:", line):
            raise Bad("drop the closing 'Question:' line: the section headings are the questions, and each option is named once.")
        for im in IMAGE.finditer(line):
            if cur is None:
                raise Bad("an image sits outside a question section. Put each image directly under the question it belongs to (one image per question, its options side by side, where possible).")
            cur["alts"].append(im.group(1) if im.group(1) is not None else (re.search(r'alt="([^"]*)"', im.group(0)) or [None, ""])[1])
        if cur is None:
            continue
        r = ROW.match(line)
        if r:
            cur["keys"].append(r.group(1))
            if r.group(2):
                cur["recs"].append(r.group(1))
            cur["today"] += "(today)" in r.group(3)
        w = re.match(r"^★ Why ([A-Z]):", line)
        if w:
            cur["why"] = w.group(1)
    if not secs:
        raise Bad(f"no question section. An overview has one `### <n>. <label>: <what it decides>` section per question with an option table. See {DOC}.")
    numbered(secs)
    for s in secs:
        q = f"question {s['n']} ({s['label']})"
        if s["keys"] != letters(len(s["keys"])) or len(s["keys"]) < 2:
            raise Bad(f"{q}: its table needs one row per option, lettered A, B, C … in order, at least two: `| A | name (today) | in short |`.")
        if len(s["recs"]) != 1:
            raise Bad(f"{q}: exactly one row carries ★: `| **B ★** | name | in short |`.")
        if s["why"] != s["recs"][0]:
            raise Bad(f"{q}: add the line `★ Why {s['recs'][0]}: <one short reason>` under the table.")
        if s["today"] > 1:
            raise Bad(f"{q}: only one option can be (today).")
    return secs


def short_keys(qs, keys=lambda q: q["keys"]):
    return [f"{q['n']}{k}" for q in qs for k in keys(q)]


def check(text):
    m = re.search(r"<!--\s*decision-note\s+(round\s+R(\d+)|options)\b", text)
    if not m:
        return
    secs = overview(text)
    if m.group(2) is None:
        return
    want = ", ".join(short_keys(secs))
    got = next((l.split(":", 1)[1].strip() for l in strip_comments(text).splitlines() if l.startswith("Variants:")), None)
    if got != want:
        raise Bad(f"a round names its options in one line Tandem reads as the things to pick: `Variants: {want}` (found: {got or 'no Variants line'}).")
    for s in secs:
        head = f"R{m.group(2)} · {s['n']}. {s['label']}"
        for alt in s["alts"]:
            parts = [p.strip() for p in alt.split("·")]
            if " · ".join(parts[:2]) != head or len(parts) != 3 or not parts[2]:
                raise Bad(f"image alt '{alt}' under question {s['n']}: use `{head} · <desktop|mobile, or what it shows>` (Tandem groups the gallery by it).")


# ---- request ----

def request(text, did):
    lines = text.splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    if not lines or lines[0].lstrip().startswith(("#", "<", "-", "|")) or parse_question(lines[0]):
        raise Bad("the first line is the question in plain words (Tandem and the digest show it).")
    question, preview, link, open_q, qs, body = lines[0].strip(), None, None, None, [], []
    for line in lines[1:]:
        q = parse_question(line)
        if q:
            qs.append(q)
        elif line.startswith("Preview:") and preview is None:
            preview = line.strip()
        elif line.startswith("Overview:") and link is None:
            link = line.split(":", 1)[1].strip()
        elif line.startswith("Open question:") and open_q is None:
            open_q = line.strip()
        else:
            body.append(line.rstrip())
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    if not qs and not open_q:
        raise Bad(f"no choices. After the question line, give one line per question: `1 Shell: A (back on top, today) · B ★ (footer bar) · C (top stepper)` (1 to 3 keywords in brackets, ★ on the recommended option), plus `Overview: <link to the round or options comment>` or the overview sections in this file. A question without options to pick from: add a line `Open question: <what kind of answer you need>` instead. See {DOC}.")
    numbered(qs)
    visible = strip_comments(re.sub(r"(?is)<details>.*?</details>", "", "\n".join(body))).splitlines()
    for l in visible:
        if LIST.match(l):
            raise Bad(f"body line '{l.strip()[:60]}': Tandem reads every `-`, `*` or numbered list line of a request as an answer option. Use `+` bullets, a table or <details>.")
        if re.search(r"(?i)recommend", l):
            raise Bad(f"body line '{l.strip()[:60]}': Tandem reads the first line with 'recommend' as the recommendation, and the request writes that line itself. Give the reason as `★ Why <letter>: …`.")
        if l.strip() == "---":
            raise Bad("a `---` line in the body: Tandem stops reading a request there. Remove it.")
    secs = overview("\n".join(body)) if any(SECTION.match(l) for l in body) else []
    if secs:
        if link:
            raise Bad("give `Overview: <link>` or the overview sections in this file, not both.")
        if [(s["n"], s["label"], s["keys"], s["recs"][0]) for s in secs] != [(q["n"], q["label"], [o["key"] for o in q["opts"]], rec(q)["key"]) for q in qs]:
            raise Bad("the question lines and the `### <n>. <label>:` sections do not match (same numbers, labels, letters and ★).")
    out = [f"<!-- decision-request {did} -->"] + [f"<!-- choices {choice_line(q)} -->" for q in qs]
    out += [f"### Decision needed ({did})", question] + ([preview] if preview else [])
    if body:
        out += [""] + body + [""]
    if open_q:
        out += ["", open_q, "", "---", f"Answer in a comment here, in your own words; with other decisions on this issue start it with `{did}:`. The run picks it up at its next checkpoint."]
        return "\n".join(out) + "\n"
    if link or secs:
        out += [f"Options with screenshots: {link or 'above in this comment'}"]
    out += [""]
    one = len(qs) == 1
    if one:  # Tandem shows each `- KEY: text` line as a tile; a click answers `D<k>: KEY`
        out += [f"- {o['key']}: {o['name']}{' (today)' if o['today'] else ''}{' ★' if o['rec'] else ''}" for o in qs[0]["opts"]]
        out += ["", f"Recommendation: {rec(qs[0])['key']} ({rec(qs[0])['text']})"]
    else:  # `+` bullets: a list on GitHub, not an option tile in Tandem; its one tile is `ok`
        for q in qs:
            out.append(f"+ **{q['n']} {q['label']}:** " + " · ".join(
                f"**{o['key']} ★ ({o['text']})**" if o["rec"] else f"{o['key']} ({o['text']})" for o in q["opts"]))
        out += ["", "- ok: take every ★ option", "", "Recommendation: ok (" + " ".join(f"{q['n']}{rec(q)['key']}" for q in qs) + ")"]
    out += ["", "---", "Copy, change only the letters you disagree with, post as a comment:" if not one else "Copy, change the letter if you disagree, post as a comment:", "```", did]
    out += [spell(q, rec(q)["key"]) for q in qs]
    short = " ".join(f"{q['n']}{rec(q)['key']}" for q in qs)
    out += ["```", f"Or reply `ok` to take {'the recommendation' if one else 'every recommendation'}. Text after a letter is read as a note. Short form: `{did}: {short}`. The run picks it up at its next checkpoint."]
    return "\n".join(out) + "\n"


# ---- answer ----

def read(choices, answer):
    qs = []
    for line in re.split(r"[\x1e\n]", choices):
        line = re.sub(r"^<!-- choices | -->$", "", line.strip())
        try:
            q = parse_question(line) if line else None
        except Bad:
            q = None
        if q:
            qs.append(q)
    if not qs:
        return ""
    by_n = {q["n"]: q for q in qs}
    picked, notes, took_all = {}, {}, False

    def valid(n, key):
        return n in by_n and any(o["key"] == key for o in by_n[n]["opts"])

    for seg in re.split(r"\s+/\s+", " ".join(answer.split())):
        seg = re.sub(r"-\s*reject:\s*\w+(?:\s*,\s*\w+)*", " ", seg)  # Tandem's round reaction: rejects are not picks
        seg = re.sub(r"^\s*(?:[DR]\d+\b:?\s*)+", "", seg)
        seg = re.sub(r"^-\s*pick:\s*", "", seg)
        if re.match(r"(?i)(ok(ay)?|all recommended|recommended|take (all|every) recommend\w*)(?![\w-])", seg):
            took_all = True
        m = re.match(r"([A-Z]|[a-z](?=\s*(?:$|[.,:;(])))\s*(?:$|[.,:;(★])", seg)
        if m and len(qs) == 1 and valid(1, m.group(1).upper()):
            picked[1] = m.group(1).upper()
        hits = []
        # block form: `1 Shell: B (footer bar) free note`; the brackets may be stale, the letter counts
        for m in re.finditer(r"(?<![\w.])(\d+)[.)]?\s+[^:/]{0,40}?:\s*(?:\*\*)?([A-Z](?![A-Za-z])|[a-z](?=\s*(?:$|[.,;(]|\d+[.)]?\s)))", seg):
            if valid(int(m.group(1)), m.group(2).upper()):
                hits.append((m.start(), m.end(), int(m.group(1)), m.group(2).upper(), True))
        for m in re.finditer(r"(?<![\w.])(\d+)[:=]?([A-Za-z])(?!\w)", seg):  # short form: 1B 2A
            if valid(int(m.group(1)), m.group(2).upper()) and not any(s <= m.start() < e for s, e, *_ in hits):
                hits.append((m.start(), m.end(), int(m.group(1)), m.group(2).upper(), False))
        hits.sort()
        for n in {h[2] for h in hits}:  # `1B with parts from 1A`: two options of one question is a mix, not a pick
            if len({h[3] for h in hits if h[2] == n}) > 1:
                return ""
        for i, (_, end, n, key, block) in enumerate(hits):
            picked[n] = key
            notes.pop(n, None)
            if block:
                note = seg[end:hits[i + 1][0] if i + 1 < len(hits) else len(seg)]
                note = re.sub(r"^\s*(?:\*\*)?\s*★?\s*(?:\([^()]*\))?(?:\*\*)?[\s.,:;-]*", "", note).strip()
                if note:
                    notes[n] = note
    if not picked and not took_all:
        return ""
    out = []
    for q in qs:
        key = picked.get(q["n"]) or (rec(q)["key"] if took_all else None)
        if key is None:
            out.append(f"{q['n']} {q['label']}: no answer (★ is {rec(q)['key']})")
        else:
            out.append(spell(q, key) + (f", note: {notes[q['n']]}" if q["n"] in notes else ""))
    return " · ".join(out)


def main(argv):
    try:
        if len(argv) == 4 and argv[1] == "request":
            sys.stdout.write(request(open(argv[2], encoding="utf-8").read(), argv[3]))
        elif len(argv) == 3 and argv[1] == "check":
            check(open(argv[2], encoding="utf-8").read())
        elif len(argv) == 4 and argv[1] == "read":
            out = read(argv[2], argv[3])
            if out:
                print(out)
        else:
            sys.stderr.write(__doc__)
            return 64
    except Bad as e:
        sys.stderr.write(f"decision format: {e}\n")
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
