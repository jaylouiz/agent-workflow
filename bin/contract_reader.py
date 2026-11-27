#!/usr/bin/env python3
"""Reference reader for the board client contract (docs/contract.md): what a client reads from one agent comment or
from a coordination log, as JSON. It follows the contract's reading rules, the way the reference client reads them
(Tandem: src/core/contract.ts, questions.ts, activity.ts), and nothing else: no knowledge of how decide.sh builds a comment.

  contract_reader.py <file>     print the expectation for the comment body (or coordination log) in <file>

test-decide.sh uses it to write and check docs/contract-fixtures/<name>.json next to each <name>.md, and to pin what a
client reads from a request. Change a rule here only together with docs/contract.md (and its version).
"""
import json
import re
import sys

MARKER = re.compile(r"<!--\s*decision-([a-z]+)(?:\s+([^>]*?))?\s*-->")
KINDS = ("request", "record", "answer", "resolved", "followup", "note")
CHOICES = re.compile(r"<!--\s*choices\s+(\d+)\s+([^:]+):\s*(.*?)\s*-->")
ITEM = re.compile(r"^\s*(?:[-*]|\d+\.)\s+")
IMG = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)")
LOG_LINE = re.compile(r"^- (\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?(?:\.\d+)?Z)\s+(.*\S)\s*$")
ANSWER_PREFIX = re.compile(r"^Answer from the user \(via the coordinator\):\s*")


def marker(body):
    m = MARKER.search(body)
    if not m or m.group(1) not in KINDS:
        return None
    kind, rest = m.group(1), (m.group(2) or "").strip()
    out = {"kind": kind, "id": None, "note": None, "round": None}
    if kind == "note":
        r = re.match(r"round\s+R(\d+)", rest)
        if r:
            out.update(note="round", round=int(r.group(1)))
        elif rest.startswith("options"):
            out["note"] = "options"
        elif rest.startswith("look"):
            out["note"] = "look"
    else:
        d = re.match(r"(D\d+)", rest)
        out["id"] = d.group(1) if d else None
    return out


def visible(body):
    """What a reader sees: no HTML comments, no <details> blocks."""
    body = re.sub(r"(?is)<details>.*?</details>", "", body)
    body = re.sub(r"(?s)<!--.*?-->", "", body)
    return [l.rstrip() for l in body.split("\n")]


def field(lines, name):
    for l in lines:
        if l.startswith(name + ":"):
            return l[len(name) + 1:].strip() or None
    return None


def own_lines(body):
    """A request's or record's own text: visible, no `###` headings, cut at the first `---`, no blank lines."""
    lines = [l for l in visible(body) if not re.match(r"###\s", l)]
    stripped = [l.strip() for l in lines]
    if "---" in stripped:
        lines = lines[:stripped.index("---")]
    return [l for l in lines if l.strip()]


def choices(body):
    out = []
    for n, label, rest in CHOICES.findall(body):
        options = []
        for part in rest.split(" · "):
            p = re.match(r"^([A-Z])\s*(★)?\s*(?:\((.*)\))?$", part.strip())
            if not p:
                continue
            words = [w.strip() for w in (p.group(3) or "").split(",") if w.strip()]
            options.append({"letter": p.group(1), "recommended": bool(p.group(2)), "today": "today" in words,
                            "name": ", ".join(w for w in words if w != "today")})
        out.append({"n": int(n), "label": label.strip(), "options": options})
    return out


def request(body):
    own = own_lines(body)
    content = [l for l in own if not l.startswith("Preview:")]
    rec = next((l for l in content if re.search(r"(?i)recommend", l)), None)
    overview = re.search(r"Options with screenshots:\s*(.*\S)", body)
    return {
        "question": content[0].strip() if content else "",
        "preview": field(own, "Preview"),
        "overview": overview.group(1) if overview else None,
        "options": [ITEM.sub("", l).strip() for l in content[1:] if ITEM.match(l)],
        "recommendation": re.sub(r"(?i)^\**recommend(?:ation|ed)?:?\**:?\s*", "", rec).strip() if rec else None,
        "questions": choices(body),
    }


def screenshots(body):
    out = []
    for alt, src in IMG.findall(body):
        parts = [p.strip() for p in alt.split("·")]
        view = lambda p: p if p in ("desktop", "mobile") else None  # noqa: E731
        shot = {"alt": alt, "src": src, "variant": None, "viewport": None, "state": None}
        if parts and re.match(r"^R\d+$", parts[0]):
            shot.update(variant=parts[1] if len(parts) > 1 else None, viewport=view(parts[2]) if len(parts) > 2 else None)
        elif parts and parts[0] == "look":
            shot.update(viewport=view(parts[1]) if len(parts) > 1 else None, state=parts[2] if len(parts) > 2 else None)
        out.append(shot)
    return out


def round_note(body):
    lines = visible(body)
    shots = screenshots(body)
    title = next((l[3:].strip() for l in lines if l.startswith("## ")), None)
    variants = [k.strip() for k in re.sub(r"\([^)]*\)", "", field(lines, "Variants") or "").split(",") if re.match(r"^[\w-]+$", k.strip())]
    questions = []
    text = re.sub(r"(?is)<details>.*?</details>", "", body)
    for section in re.split(r"(?m)^(?=###\s+\d+\.\s)", text):
        h = re.search(r"(?m)^###\s+(\d+)\.\s+([^:\n]+):\s*(.*)$", section)
        if not h:
            continue
        n = int(h.group(1))
        options = []
        for letter, star, name, short in re.findall(r"(?m)^\|\s*(?:\*\*)?([A-Z])\s*(★)?\s*(?:\*\*)?\s*\|\s*([^|]*)\|\s*([^|]*)\|", section):
            name = name.strip()
            options.append({"letter": letter, "recommended": bool(star), "today": "(today)" in name,
                            "name": re.sub(r"\s*\(today\)", "", name), "short": short.strip()})
        if not options:
            continue
        why = re.search(r"(?m)^★\s*Why\s+[A-Z]:\s*(.*)$", section)
        questions.append({"n": n, "label": h.group(2).strip(), "about": h.group(3).strip(), "options": options,
                          "why": why.group(1).strip() if why else "",
                          "shots": [i for i, s in enumerate(shots) if re.match(r"^\s*R\d+\s*·\s*%d\.\s" % n, s["alt"])]})
    return {"title": title, "preview": field(lines, "Preview"), "variants": variants, "questions": questions, "screenshots": shots}


def look(body):
    lines = visible(body)
    head = next((l for l in lines if l.startswith("### ")), None)
    checks = []
    if "Check:" in [l.strip() for l in lines]:
        for l in lines[[l.strip() for l in lines].index("Check:") + 1:]:
            m = re.match(r"^\s*[-*]\s+(.*)$", l)
            if m:
                checks.append(m.group(1).strip())
            elif l.strip():
                break
    return {"headline": re.sub(r"^###\s+(Look:\s*)?", "", head).strip() if head else "Look", "preview": field(lines, "Preview"),
            "path": field(lines, "Path"), "checks": checks, "screenshots": screenshots(body)}


def log(text):
    return {"lines": [{"at": m.group(1), "text": m.group(2)} for m in map(LOG_LINE.match, text.split("\n")) if m]}


def read(text):
    m = marker(text)
    if m is None:
        return {"marker": None, **log(text)}
    out = {"marker": m}
    if m["kind"] == "request":
        out.update(request(text))
    elif m["kind"] == "record":
        own = own_lines(text)
        out["title"] = own[0].strip() if own else m["id"]
    elif m["kind"] == "answer":
        out["answer"] = ANSWER_PREFIX.sub("", " ".join(text.split("\n")[1:])).strip()
    elif m["note"] == "round":
        out.update(round_note(text))
    elif m["note"] == "look":
        out.update(look(text))
    return out


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as f:
        print(json.dumps(read(f.read()), ensure_ascii=False, indent=2))
