#!/usr/bin/env python3
"""Write the README diagrams (light + dark HTML) from one source.

    python3 docs/diagrams/render.py
    # then rasterize each HTML with the diagram-design skill:
    uv run --with playwright python3 ~/.claude/skills/diagram-design/scripts/export_png.py docs/diagrams/<name>.html

Skin: diagram-design default tokens (references/style-guide.md).
"""

from __future__ import annotations

import pathlib

HERE = pathlib.Path(__file__).resolve().parent

SKINS = {
    "light": dict(
        paper="#f5f5f5", paper2="#ececec", node="#ffffff", ink="#2d3142",
        muted="#4f5d75", soft="#5a6580", accent="#bf4520",
        accent_tint="rgba(191,69,32,0.08)", accent_tag="rgba(191,69,32,0.50)",
        ink40="rgba(45,49,66,0.40)", ink10="rgba(45,49,66,0.10)",
        ink05="rgba(45,49,66,0.05)",
    ),
    "dark": dict(
        paper="#2d3142", paper2="#393e53", node="#393e53", ink="#f5f5f5",
        muted="#bfc0c0", soft="#949eb2", accent="#f08a59",
        accent_tint="rgba(240,138,89,0.10)", accent_tag="rgba(240,138,89,0.50)",
        ink40="rgba(245,245,245,0.40)", ink10="rgba(245,245,245,0.10)",
        ink05="rgba(245,245,245,0.05)",
    ),
}

SANS = "'Geist', system-ui, sans-serif"
MONO = "'Geist Mono', ui-monospace, monospace"
SERIF = "'Instrument Serif', 'Noto Serif', serif"
FONTS = ("https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1"
         "&family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500;600&display=swap")


def page(c: dict, slug: str, eyebrow: str, h1: str, w: int, h: int,
         desc: str, body: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{h1}</title>
  <link href="{FONTS}" rel="stylesheet">
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ font-family: {SANS}; background: {c['paper']}; color: {c['ink']};
           min-height: 100vh; display: flex; align-items: center; justify-content: center;
           padding: 3rem 2rem; }}
    .frame {{ max-width: 1200px; width: 100%; }}
    .diagram-container {{ width: 100%; overflow-x: auto; }}
    .eyebrow {{ font-family: {MONO}; font-size: 0.66rem; font-weight: 500; letter-spacing: 0.18em;
               text-transform: uppercase; color: {c['muted']}; margin-bottom: 0.5rem; }}
    h1 {{ font-family: {SERIF}; font-size: clamp(1.5rem, 2.4vw + 0.75rem, 2rem); font-weight: 400;
         letter-spacing: -0.02em; line-height: 1.15; margin-bottom: 1.5rem; }}
    svg {{ width: 100%; min-width: {w}px; display: block; }}
    @media print {{ .diagram-container {{ overflow-x: visible; }} svg {{ min-width: 0; }} }}
  </style>
</head>
<body>
  <div class="frame">
    <p class="eyebrow">{eyebrow} · agent-workflow</p>
    <h1>{h1}</h1>
    <div class="diagram-container">
      <svg viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg" role="img" aria-labelledby="{slug}-title {slug}-desc">
        <title id="{slug}-title">{h1}</title>
        <desc id="{slug}-desc">{desc}</desc>
        <defs>
          <marker id="arrow" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="{c['muted']}"/></marker>
          <marker id="arrow-accent" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="{c['accent']}"/></marker>
        </defs>
        <rect width="100%" height="100%" fill="{c['paper']}"/>
{body}
      </svg>
    </div>
  </div>
</body>
</html>
"""


# ---------- primitives ----------

def arrow(c, d, accent=False):
    col, mk = (c["accent"], "arrow-accent") if accent else (c["muted"], "arrow")
    return (f'        <path d="{d}" fill="none" stroke="{col}" stroke-width="1.2" '
            f'marker-end="url(#{mk})"/>')


def label(c, cx, y_mask, text, anchor="middle", accent=False):
    """Arrow label: 8px mono caps on an opaque paper mask (mask top = y_mask, h=12)."""
    w = round(len(text) * 5.5 + 8)
    w += w % 2
    x = cx - w / 2 if anchor == "middle" else cx
    tx = cx if anchor == "middle" else cx + w / 2
    col = c["accent"] if accent else c["soft"]
    return (f'        <rect x="{x:g}" y="{y_mask}" width="{w}" height="12" rx="2" fill="{c["paper"]}"/>\n'
            f'        <text x="{tx:g}" y="{y_mask + 9}" fill="{col}" font-size="8" font-family="{MONO}" '
            f'text-anchor="middle" letter-spacing="0.06em">{text}</text>')


def box(c, x, y, w, h, tag, name, sub, focal=False):
    fill, stroke, tagc = ((c["accent_tint"], c["accent"], c["accent_tag"]) if focal
                          else (c["node"], c["ink"], c["ink40"]))
    tagtxt = c["accent"] if focal else c["ink"]
    tw = len(tag) * 6 + 12
    cx = x + w / 2
    return f"""        <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{c['paper']}"/>
        <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1"/>
        <rect x="{x + 8}" y="{y + 8}" width="{tw}" height="12" rx="2" fill="none" stroke="{tagc}" stroke-width="0.8"/>
        <text x="{x + 8 + tw / 2:g}" y="{y + 17}" fill="{tagtxt}" font-size="7" font-family="{MONO}" text-anchor="middle" letter-spacing="0.08em">{tag}</text>
        <text x="{cx:g}" y="{y + 40}" fill="{c['ink']}" font-size="14" font-weight="600" font-family="{SANS}" text-anchor="middle">{name}</text>
        <text x="{cx:g}" y="{y + 56}" fill="{c['muted']}" font-size="9" font-family="{MONO}" text-anchor="middle">{sub}</text>"""


def oval(c, x, y, w, h, name, sub=None, end=False):
    cx, cy = x + w / 2, y + h / 2
    out = [f'        <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h // 2}" fill="{c["paper"]}"/>',
           f'        <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h // 2}" fill="{c["ink05"] if end else c["node"]}" '
           f'stroke="{c["ink"]}" stroke-width="{1.6 if end else 1}"/>']
    if sub:
        out.append(f'        <text x="{cx:g}" y="{cy}" fill="{c["ink"]}" font-size="13" font-weight="600" font-family="{SANS}" text-anchor="middle">{name}</text>')
        out.append(f'        <text x="{cx:g}" y="{cy + 14}" fill="{c["muted"]}" font-size="9" font-family="{MONO}" text-anchor="middle">{sub}</text>')
    else:
        out.append(f'        <text x="{cx:g}" y="{cy + 5}" fill="{c["ink"]}" font-size="13" font-weight="600" font-family="{SANS}" text-anchor="middle">{name}</text>')
    return "\n".join(out)


def legend(c, y, w, items):
    out = [f'        <line x1="32" y1="{y}" x2="{w - 32}" y2="{y}" stroke="{c["ink10"]}" stroke-width="0.8"/>',
           f'        <text x="32" y="{y + 24}" fill="{c["muted"]}" font-size="8" font-family="{MONO}" letter-spacing="0.14em">LEGEND</text>']
    x = 112
    for swatch, text, width in items:
        out.append(swatch(x, y + 14))
        out.append(f'        <text x="{x + 30}" y="{y + 24}" fill="{c["muted"]}" font-size="9" font-family="{MONO}">{text}</text>')
        x += width
    return "\n".join(out)


# ---------- figure 1: lanes ----------

def lanes(c):
    W, H = 960, 456
    a = []
    # arrows first
    a.append(arrow(c, "M 152 212 L 186 212"))                                   # issue -> triage
    a.append(arrow(c, "M 232 176 L 232 100 Q 232 92 240 92 L 358 92"))          # triage -> design
    a.append(arrow(c, "M 276 212 L 358 212"))                                   # triage -> spec
    a.append(arrow(c, "M 232 248 L 232 324 Q 232 332 240 332 L 358 332"))       # triage -> ready
    a.append(arrow(c, "M 440 124 L 440 178"))                                   # design -> spec
    a.append(arrow(c, "M 440 244 L 440 298"))                                   # spec -> ready
    a.append(arrow(c, "M 560 92 L 592 92 Q 600 92 600 100 L 600 298"))          # design -> ready (standard met)
    a.append(arrow(c, "M 640 332 L 698 332"))                                   # ready -> PR
    a.append(arrow(c, "M 812 332 L 850 332"))                                   # PR -> merge
    # labels (before nodes)
    a.append(label(c, 296, 72, "OPEN UX"))
    a.append(label(c, 316, 192, "OPEN BUILD"))
    a.append(label(c, 304, 312, "STANDARD MET"))
    a.append(label(c, 608, 192, "STANDARD MET", anchor="start"))
    # nodes
    a.append(oval(c, 32, 188, 120, 48, "Issue", "any shape"))
    a.append(f'        <polygon points="188,212 232,176 276,212 232,248" fill="{c["paper"]}"/>')
    a.append(f'        <polygon points="188,212 232,176 276,212 232,248" fill="{c["node"]}" stroke="{c["ink"]}" stroke-width="1"/>')
    a.append(f'        <text x="232" y="216" fill="{c["ink"]}" font-size="12" font-weight="600" font-family="{SANS}" text-anchor="middle">Triage</text>')
    a.append(box(c, 360, 60, 200, 64, "LABEL", "needs-design", "/design-gh-issue"))
    a.append(box(c, 360, 180, 200, 64, "LABEL", "needs-spec", "/specify-gh-issue"))
    a.append(box(c, 360, 300, 280, 64, "LABEL", "ready", "/build-gh-issue", focal=True))
    a.append(box(c, 700, 300, 112, 64, "PR", "Pull request", "review"))
    a.append(oval(c, 852, 308, 84, 48, "Merge", end=True))
    # fog callout (top-right margin)
    a.append(f'        <text x="936" y="84" fill="{c["ink"]}" font-size="15" font-style="italic" font-family="{SERIF}" text-anchor="end">Fog at any point: no lane.</text>')
    a.append(f'        <text x="936" y="104" fill="{c["ink"]}" font-size="15" font-style="italic" font-family="{SERIF}" text-anchor="end">The user charts it with /wayfinder.</text>')
    # legend
    sw_oval = lambda x, y: f'        <rect x="{x}" y="{y}" width="22" height="12" rx="6" fill="{c["node"]}" stroke="{c["ink"]}" stroke-width="0.8"/>'
    sw_dia = lambda x, y: f'        <polygon points="{x + 3},{y + 6} {x + 11},{y} {x + 19},{y + 6} {x + 11},{y + 12}" fill="{c["node"]}" stroke="{c["ink"]}" stroke-width="0.8"/>'
    sw_box = lambda x, y: f'        <rect x="{x}" y="{y}" width="22" height="12" rx="2" fill="{c["node"]}" stroke="{c["ink"]}" stroke-width="0.8"/>'
    sw_foc = lambda x, y: f'        <rect x="{x}" y="{y}" width="22" height="12" rx="2" fill="{c["accent_tint"]}" stroke="{c["accent"]}" stroke-width="0.8"/>'
    a.append(legend(c, 400, W, [
        (sw_oval, "start · end", 140),
        (sw_dia, "triage rule", 140),
        (sw_box, "label · skill that works it", 240),
        (sw_foc, "build gate", 140),
    ]))
    desc = ("Flow of a GitHub issue through the lanes: triage routes it to needs-design, needs-spec, "
            "or ready when the issue standard is met; design leads to needs-spec or to ready, specify leads "
            "to ready, and build opens a pull request that is reviewed and merged. Fog goes to the user's /wayfinder.")
    return W, H, desc, "\n".join(a)


# ---------- figure 2: issue standard ----------

BANDS = [  # (key, name, sub, height)
    ("title", "Title", None, 28),
    ("problem", "Problem &amp; job", None, 32),
    ("solution", "Solution", "rough", 32),
    ("stories", "User stories", None, 32),
    ("uacs", "UACs", None, 32),
    ("tech", "Technical", "ACs · verification", 44),
]
COLS = [  # (header, bands present, bands new in this column)
    ("FILED", ["title"], ["title"]),
    ("STAGE STARTS", ["title", "problem", "solution"], ["problem", "solution"]),
    ("AFTER DESIGN", ["title", "problem", "solution", "stories", "uacs"], ["stories", "uacs"]),
    ("READY TO BUILD", [b[0] for b in BANDS], ["tech"]),
]


def standard(c):
    W, H = 960, 432
    CW, X0, GAP, TOP = 164, 32, 80, 72
    a = []
    xs = [X0 + i * (CW + GAP) for i in range(4)]
    bottoms = []
    for i, (_, present, _) in enumerate(COLS):
        y = TOP + 8
        for key, _, _, h in BANDS:
            if key in present:
                y += h + 4
        bottoms.append(y - 4 + 8)
    # arrows first
    for i in range(3):
        a.append(arrow(c, f"M {xs[i] + CW} 94 L {xs[i + 1] - 2} 94", accent=False))
    bx, ex = xs[1] + CW // 2, xs[3] + CW // 2
    a.append(arrow(c, f"M {bx} {bottoms[1]} L {bx} 352 Q {bx} 360 {bx + 8} 360 "
                      f"L {ex - 8} 360 Q {ex} 360 {ex} 352 L {ex} {bottoms[3] + 2}"))
    # labels
    a.append(label(c, (xs[0] + CW + xs[1]) / 2, 74, "FIRST STAGE"))
    a.append(label(c, (xs[1] + CW + xs[2]) / 2, 74, "DESIGN"))
    a.append(label(c, (xs[2] + CW + xs[3]) / 2, 74, "SPECIFY"))
    a.append(label(c, (xs[2] + xs[2] + CW) / 2, 340, "SPECIFY ONLY"))
    # columns
    for i, (head, present, new) in enumerate(COLS):
        x = xs[i]
        focal = i == 3
        a.append(f'        <text x="{x}" y="56" fill="{c["accent"] if focal else c["muted"]}" font-size="8" font-weight="500" '
                 f'font-family="{MONO}" letter-spacing="0.18em">{head}</text>')
        a.append(f'        <rect x="{x}" y="{TOP}" width="{CW}" height="{bottoms[i] - TOP}" rx="8" fill="{c["paper"]}"/>')
        a.append(f'        <rect x="{x}" y="{TOP}" width="{CW}" height="{bottoms[i] - TOP}" rx="8" '
                 f'fill="{c["accent_tint"] if focal else c["ink05"]}" stroke="{c["accent"] if focal else c["ink40"]}" stroke-width="1"/>')
        y = TOP + 8
        for key, name, sub, h in BANDS:
            if key not in present:
                continue
            is_new = key in new
            if key == "solution" and i > 1:
                sub = "sharpened"
            fill = c["node"] if is_new else c["paper2"]
            stroke = f' stroke="{c["ink"]}" stroke-width="1"' if is_new else ""
            txt = c["ink"] if is_new else c["soft"]
            a.append(f'        <rect x="{x + 8}" y="{y}" width="{CW - 16}" height="{h}" rx="4" fill="{fill}"{stroke}/>')
            if key == "tech":
                a.append(f'        <text x="{x + 18}" y="{y + 18}" fill="{txt}" font-size="12" font-weight="600" font-family="{SANS}">{name}</text>')
                a.append(f'        <text x="{x + 18}" y="{y + 34}" fill="{c["muted"]}" font-size="9" font-family="{MONO}">{sub}</text>')
            else:
                a.append(f'        <text x="{x + 18}" y="{y + h / 2 + 4:g}" fill="{txt}" font-size="12" font-weight="{600 if is_new else 500}" font-family="{SANS}">{name}</text>')
                if sub:
                    a.append(f'        <text x="{x + CW - 18}" y="{y + h / 2 + 3:g}" fill="{c["muted"] if is_new else c["soft"]}" font-size="9" font-family="{MONO}" text-anchor="end">{sub}</text>')
            y += h + 4
    # callout under the first column
    for k, line in enumerate(["A title-only issue is normal:",
                              "the first stage that runs",
                              "fills in what is missing."]):
        a.append(f'        <text x="{X0}" y="{152 + k * 19}" fill="{c["ink"]}" font-size="15" font-style="italic" font-family="{SERIF}">{line}</text>')
    # legend
    sw_new = lambda x, y: f'        <rect x="{x}" y="{y}" width="22" height="12" rx="2" fill="{c["node"]}" stroke="{c["ink"]}" stroke-width="0.8"/>'
    sw_old = lambda x, y: f'        <rect x="{x}" y="{y}" width="22" height="12" rx="2" fill="{c["paper2"]}"/>'
    sw_foc = lambda x, y: f'        <rect x="{x}" y="{y}" width="22" height="12" rx="2" fill="{c["accent_tint"]}" stroke="{c["accent"]}" stroke-width="0.8"/>'
    a.append(legend(c, 384, W, [
        (sw_new, "added at this step", 190),
        (sw_old, "carried over", 150),
        (sw_foc, "complete spec, Build's only input", 260),
    ]))
    desc = ("How an issue body fills up layer by layer: a title-only issue gains Problem and job plus a rough "
            "Solution from the first stage, user stories and UACs from Design, and the technical layer from "
            "Specify; Specify without Design adds stories, UACs and the technical layer in one step.")
    return W, H, desc, "\n".join(a)


FIGS = [
    ("lanes", "Flowchart", "Issue lanes", lanes),
    ("issue-standard", "Layer build-up", "Issue standard, layer by layer", standard),
]

if __name__ == "__main__":
    for slug, eyebrow, h1, fn in FIGS:
        for skin, c in SKINS.items():
            s = slug if skin == "light" else f"{slug}-dark"
            w, h, desc, body = fn(c)
            (HERE / f"{s}.html").write_text(page(c, s, eyebrow, h1, w, h, desc, body))
            print("wrote", HERE / f"{s}.html")
