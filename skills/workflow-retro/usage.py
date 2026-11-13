#!/usr/bin/env python3
"""Measured context and cost of Claude Code sessions, read from the local transcripts.

  usage.py start-context [--project NAME] [--n 5]
      What a session carries before it does any work: the context of the first model call of the latest
      interactive top-level sessions (tokens; headless -p runs are left out), with the parts that can be seen in a transcript (tool definitions, skill
      listing, instruction files). The retro records the median in its context-size row.
  usage.py summary [--project NAME] [--since YYYY-MM-DD]
      Per role (lead, review, fix, ..., coordinator, ad hoc, subagents): sessions, estimated cost, calls,
      start and peak context; the share of all processed context that is the start context replayed on every
      call; how often each skill was invoked (an instruction that names a skill nobody invokes is dead).

NAME defaults to the directory name of the repository's main checkout; every transcript directory under
~/.claude/projects whose name contains it is read (the main checkout and its worktrees).
Costs are API list prices per million tokens (input, output) and only relative weights: cache reads count 0.1x
input, cache writes 1.25x. A model family not listed is priced like opus.
"""
import argparse, collections, datetime, glob, json, os, re, statistics, subprocess, sys

PRICE = {'opus': (5, 25), 'sonnet': (3, 15), 'haiku': (1, 5)}
BASE = os.path.expanduser('~/.claude/projects')


def default_project():
    try:
        common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                capture_output=True, text=True, check=True).stdout.strip()
        return os.path.basename(os.path.dirname(common))
    except Exception:
        return os.path.basename(os.getcwd())


def family(model):
    for k in PRICE:
        if k in (model or ''):
            return k
    return 'opus'


def text_of(content):
    if isinstance(content, str):
        return content
    return '\n'.join(c.get('text', '') for c in content or [] if isinstance(c, dict) and c.get('type') == 'text')


def scan(path, is_sub):
    """One transcript -> a row, or None when it holds no model call."""
    calls, order, skills = {}, [], []
    first_ts = first_user = stage = None
    tools_chars = skill_listing = instructions = None
    biggest_tool = None
    interactive = False
    try:
        f = open(path, errors='replace')
    except OSError:
        return None
    for line in f:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        first_ts = first_ts or o.get('timestamp')
        t = o.get('type')
        m = o.get('message') or {}
        if t == 'api-request-shape' and tools_chars is None:
            sizes = {d.get('name'): len(json.dumps(d)) for d in (o.get('shape') or {}).get('tools') or []}
            tools_chars = sum(sizes.values())
            interactive = 'AskUserQuestion' in sizes  # headless (-p) runs carry a smaller tool list
            if sizes:
                name = max(sizes, key=sizes.get)
                biggest_tool = (name, sizes[name])
        elif t == 'attachment':
            a = o.get('attachment') or {}
            if a.get('type') == 'skill_listing' and skill_listing is None:
                skill_listing = len(a.get('content') or '')
            elif a.get('type') == 'instructions' and instructions is None:
                instructions = len(json.dumps(a.get('files') or ''))
        elif t == 'user' and first_user is None:
            txt = text_of(m.get('content'))
            if txt.strip() and not txt.startswith('<local-command'):
                first_user = txt[:400]
                mm = re.search(r'=== TASK ===\s*Issue #\d+:.*?Stage: ([\w-]+)\.', txt, re.S)
                stage = mm.group(1) if mm else None
        elif t == 'assistant':
            u, mid = m.get('usage'), m.get('id')
            if u and mid:
                if mid not in calls:
                    order.append(mid)
                calls[mid] = (u, m.get('model'))
            for part in m.get('content') or []:
                if isinstance(part, dict) and part.get('type') == 'tool_use' and part.get('name') == 'Skill':
                    skills.append((part.get('input') or {}).get('skill'))
    if not order:
        return None
    ctx, cost, models = [], 0.0, collections.Counter()
    for mid in order:
        u, model = calls[mid]
        i, cc, cr, out = (u.get(k) or 0 for k in ('input_tokens', 'cache_creation_input_tokens',
                                                    'cache_read_input_tokens', 'output_tokens'))
        pin, pout = PRICE[family(model)]
        cost += (i * pin + cc * pin * 1.25 + cr * pin * 0.1 + out * pout) / 1e6
        ctx.append(i + cc + cr)
        models[model] += 1
    if is_sub:
        role = 'subagent'
    elif stage:
        role = 'worker:' + stage
    elif first_user and 'dispatched worker' in first_user:
        role = 'worker:other'
    elif first_user and '/orchestrate-gh-issues' in first_user[:200]:
        role = 'coordinator'
    else:
        role = 'ad hoc'
    return dict(path=path, first=first_ts or '', role=role, calls=len(order), cost=cost, ctx_first=ctx[0],
                ctx_max=max(ctx), ctx_sum=sum(ctx), model=models.most_common(1)[0][0], skills=skills,
                tools_chars=tools_chars, biggest_tool=biggest_tool, skill_listing=skill_listing,
                instructions=instructions, interactive=interactive, mtime=os.path.getmtime(path))


def transcripts(project, since=None, newest=None, scan_cap=80):
    files = []
    for d in os.listdir(BASE) if os.path.isdir(BASE) else []:
        if project not in d:
            continue
        files += [(p, False) for p in glob.glob(os.path.join(BASE, d, '*.jsonl'))]
        files += [(p, True) for p in glob.glob(os.path.join(BASE, d, '*', 'subagents', '*.jsonl'))]
    if since:
        cut = datetime.datetime.fromisoformat(since).timestamp()
        files = [f for f in files if os.path.getmtime(f[0]) >= cut]
    files.sort(key=lambda f: os.path.getmtime(f[0]), reverse=True)
    rows = []
    for n, (path, sub) in enumerate(files):
        if newest and (sub or n >= scan_cap):
            continue
        r = scan(path, sub)
        if r and (not newest or r['interactive']):
            rows.append(r)
            if newest and len(rows) >= newest:
                break
    return rows


def k(n):
    return '-' if n is None else f'{n / 1000:.1f}k'


def start_context(args):
    rows = transcripts(args.project, newest=args.n)
    if not rows:
        sys.exit(f'usage.py: no transcript with a model call for project "{args.project}"')
    print(f'start context of the latest {len(rows)} interactive top-level sessions of "{args.project}" (tokens of the first model call):')
    for r in rows:
        when = datetime.datetime.fromtimestamp(r['mtime']).strftime('%m-%d %H:%M')
        big = f"{r['biggest_tool'][0]} {k(r['biggest_tool'][1])} chars" if r['biggest_tool'] else '-'
        print(f"  {when}  {r['ctx_first']:>7}  {r['role']:<20} tools {k(r['tools_chars'])} chars (largest: {big}), "
              f"skill listing {k(r['skill_listing'])} chars, instruction files {k(r['instructions'])} chars")
    print(f"median start context: {int(statistics.median(r['ctx_first'] for r in rows))} tokens")


def summary(args):
    rows = transcripts(args.project, since=args.since)
    if not rows:
        sys.exit(f'usage.py: no transcript with a model call for project "{args.project}"')
    total = sum(r['cost'] for r in rows)
    print(f'{len(rows)} sessions of "{args.project}"' + (f' since {args.since}' if args.since else '')
          + f', estimated ${total:,.0f} (list-price equivalent, relative weights only)')
    print(f"{'role':<22}{'n':>5}{'cost $':>8}{'share':>7}{'median $':>10}{'calls':>7}{'start ctx':>11}{'peak ctx':>10}")
    groups = collections.defaultdict(list)
    for r in rows:
        groups[r['role']].append(r)
    for role, v in sorted(groups.items(), key=lambda kv: -sum(r['cost'] for r in kv[1])):
        c = sum(r['cost'] for r in v)
        print(f"{role:<22}{len(v):>5}{c:>8.0f}{100 * c / total:>6.0f}%{statistics.median(r['cost'] for r in v):>10.2f}"
              f"{int(statistics.median(r['calls'] for r in v)):>7}{int(statistics.median(r['ctx_first'] for r in v)):>11}"
              f"{int(statistics.median(r['ctx_max'] for r in v)):>10}")
    replay = sum(r['calls'] * r['ctx_first'] for r in rows) / max(1, sum(r['ctx_sum'] for r in rows))
    print(f'start context replayed on every call: {100 * replay:.0f}% of all context processed')
    top = [r for r in rows if r['role'] != 'subagent']
    if top:
        print(f"median start context of top-level sessions: {int(statistics.median(r['ctx_first'] for r in top))} tokens")
    used = collections.Counter(s for r in rows for s in r['skills'] if s)
    print('skills invoked: ' + (', '.join(f'{s} {n}' for s, n in used.most_common()) or 'none'))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('start-context')
    a.add_argument('--project', default=default_project())
    a.add_argument('--n', type=int, default=5)
    a.set_defaults(fn=start_context)
    b = sub.add_parser('summary')
    b.add_argument('--project', default=default_project())
    b.add_argument('--since')
    b.set_defaults(fn=summary)
    args = ap.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
