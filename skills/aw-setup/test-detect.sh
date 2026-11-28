#!/usr/bin/env bash
# Tests for detect.sh on fixture repos with a stub gh. Run: bash skills/aw-setup/test-detect.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WF_GLOBAL_SETTINGS="$T/no-global-settings.sh" # never the real ~/.claude settings
unset WF_REPO
fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
has() { grep -qxF "$1" "$T/out"; }
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/calls"\nexit 1\n' "$T" >"$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

W="$T/web"; mkdir -p "$W/.github/workflows" "$W/src"; git -C "$W" init -q
git -C "$W" remote add origin https://github.com/acme/web.git
cat >"$W/package.json" <<'J'
{"scripts": {"verify": "x", "dev": "vite", "test": "vitest"}, "dependencies": {"react": "^19"}}
J
touch "$W/package-lock.json" "$W/playwright.config.ts" "$W/.github/workflows/ci.yml" "$W/CLAUDE.md" "$W/src/App.tsx"
git -C "$W" add -A
(cd "$W" && bash "$DIR/detect.sh") >"$T/out"; rc=$?
check "web: exit 0 with gh failing" '[ $rc = 0 ]'
for want in "repo: acme/web" "pm: npm" "lockfile: package-lock.json" "script.verify: npm run verify" "script.dev: npm run dev" \
  "e2e: playwright" "ci.workflow: .github/workflows/ci.yml" "doc: CLAUDE.md" "ui: yes" "profile: absent" "config: absent" "gh: unavailable" "issue_statuses: unknown"; do
  check "web: $want" 'has "$want"'
done

S="$T/sh"; mkdir -p "$S/.claude"; git -C "$S" init -q
printf "echo hi\\n" >"$S/run.sh"; mkdir -p "$S/docs"; touch "$S/.claude/issue-workflow.md" "$S/docs/diagram.html"; git -C "$S" add -A
rm -f "$T/calls"
(cd "$S" && bash "$DIR/detect.sh" --no-gh) >"$T/out"
for want in "pm: none" "ui: no" "profile: present" "e2e: none" "repo: none"; do check "shell: $want" 'has "$want"'; done
check "no-gh: gh never called" '[ ! -f "$T/calls" ]'
check "no-gh: no gh line" '! grep -q "^gh:" "$T/out"'

# issue_statuses: a stub gh that answers the planningStatuses count
for pair in "2:yes" "0:no" "x:unknown"; do
  printf '#!/usr/bin/env bash\ncase "$*" in "auth status"*) exit 0 ;; "api graphql"*) echo %s ;; *) exit 1 ;; esac\n' "${pair%%:*}" >"$T/bin/gh"
  (cd "$W" && bash "$DIR/detect.sh") >"$T/out"
  check "issue_statuses ${pair%%:*} -> ${pair#*:}" 'has "issue_statuses: ${pair#*:}"'
done
(cd "$S" && bash "$DIR/detect.sh" --no-gh) >"$T/out"; check "no-gh: issue_statuses unknown" 'has "issue_statuses: unknown"'

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
