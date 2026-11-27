#!/usr/bin/env bash
# Print what /aw-setup can tell about the current repo, one `key: value` fact per line. Never writes.
#
#   detect.sh [--no-gh]    --no-gh skips the GitHub lookups (check names, required checks, labels)
#
# Keys: repo, default_branch, profile, config, pm, lockfile, script.<name>, e2e, ci.workflow, ci.check,
# required_check, doc, rules, ui, ui.reason, orca, label, gh. A key may repeat (one line per value). Exit 0 always.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../bin/lib.sh
. "$DIR/../../bin/lib.sh"
GH=1
case "${1:-}" in --no-gh) GH=0 ;; "") ;; *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;; esac
wf_root; cd "$ROOT" || exit 0
kv() { printf '%s: %s\n' "$1" "$2"; }

if [ "$GH" = 1 ]; then repo=$(WF_REPO="" wf_repo_slug 2>/dev/null) || repo=""; else
  u=$(git remote get-url origin 2>/dev/null) || u=""; repo=""
  case "$u" in *github.com[:/]*/*) u=${u%/}; u=${u%.git}; repo=${u#*github.com[:/]} ;; esac
fi
kv repo "${repo:-none}"
b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) && kv default_branch "${b#origin/}" || kv default_branch "$(git branch --show-current 2>/dev/null || echo unknown)"
[ -f .claude/issue-workflow.md ] && kv profile present || kv profile absent
[ -f .claude/issue-workflow.sh ] && kv config present || kv config absent

pm=none lock=""
for pair in package-lock.json:npm pnpm-lock.yaml:pnpm yarn.lock:yarn bun.lockb:bun bun.lock:bun Cargo.lock:cargo go.sum:go poetry.lock:python uv.lock:python; do
  f=${pair%%:*}; [ -f "$f" ] && { pm=${pair#*:}; lock=$f; break; }
done
[ "$pm" = none ] && [ -f package.json ] && pm=npm
[ "$pm" = none ] && [ -f Cargo.toml ] && pm=cargo
[ "$pm" = none ] && [ -f go.mod ] && pm=go
[ "$pm" = none ] && { [ -f pyproject.toml ] || [ -f requirements.txt ]; } && pm=python
kv pm "$pm"; [ -n "$lock" ] && kv lockfile "$lock"

run="npm run"; case $pm in pnpm) run="pnpm run" ;; yarn) run="yarn" ;; bun) run="bun run" ;; esac
if [ -f package.json ]; then
  python3 -I - package.json "$run" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
scripts = d.get("scripts") or {}
for name in ("verify", "test", "lint", "typecheck", "build", "dev", "e2e"):
    if name in scripts:
        print("script.%s: %s %s" % (name, sys.argv[2], name))
PY
fi
if [ -f Makefile ]; then
  for t in verify test lint build; do grep -q "^$t:" Makefile && kv "script.$t" "make $t"; done
fi

e2e=none
ls playwright.config.* >/dev/null 2>&1 && e2e=playwright
[ "$e2e" = none ] && ls cypress.config.* >/dev/null 2>&1 && e2e=cypress
kv e2e "$e2e"
for f in .github/workflows/*.yml .github/workflows/*.yaml; do [ -f "$f" ] && kv ci.workflow "$f"; done

for f in CLAUDE.md AGENTS.md PRODUCT.md DESIGN.md README.md; do [ -f "$f" ] && kv doc "$f"; done
for f in .claude/rules/*.md; do [ -f "$f" ] && kv rules "$f"; done

ui=unsure reason="no frontend framework or UI files found"
if [ -f package.json ] && grep -Eq '"(react|vue|svelte|@angular/core|solid-js|preact|next|nuxt|astro|@remix-run/react|react-native|expo)"' package.json; then
  ui=yes; reason="frontend framework in package.json"
elif [ -n "$(git ls-files -- '*.tsx' '*.jsx' '*.vue' '*.svelte' '*.swift' '*.kt' '*.html' ':(exclude)docs/**' ':(exclude)**/docs/**' 2>/dev/null | head -1)" ]; then
  ui=unsure; reason="UI-like files but no known framework"
elif [ -n "$(git ls-files 2>/dev/null | head -1)" ]; then
  ui=no; reason="no frontend framework or UI files"
fi
kv ui "$ui"; kv ui.reason "$reason"
command -v orca >/dev/null 2>&1 && kv orca yes || kv orca no

if [ "$GH" = 1 ] && [ -n "$repo" ]; then
  if gh auth status >/dev/null 2>&1; then
    br=$(gh repo view "$repo" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null) || br=""
    if [ -n "$br" ]; then
      gh api "repos/$repo/commits/$br/check-runs" --jq '.check_runs[].name' 2>/dev/null | sort -u | while IFS= read -r c; do kv ci.check "$c"; done
      gh api "repos/$repo/branches/$br/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null | while IFS= read -r c; do kv required_check "$c"; done
    fi
    gh label list -R "$repo" --limit 200 --json name --jq '.[].name' 2>/dev/null | while IFS= read -r l; do kv label "$l"; done
  else
    kv gh unavailable
  fi
fi
exit 0
