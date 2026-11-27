#!/usr/bin/env bash
# Leak lint: the skills, their templates and reference/ are read by every project, so they name no stack, no file
# layout and no issue of the project a lesson came from (such a fact belongs to that project's profile or
# .claude/rules/: workflow-retro step 5 "Routing"). Run: bash .claude/test-generic.sh
#
#   bash .claude/test-generic.sh                       self-test on fixtures, then lint this repo
#   bash .claude/test-generic.sh --scan <root> [<allowlist>]   lint <root>/skills/**/*.md and <root>/reference/*.md only
#
# A hit prints `<file>:<line>: <pattern name>: <text>`. A deliberate exception is one line in
# .claude/generic-allowlist.txt: `<file> :: <pattern name> :: <text the line contains> :: <reason>`. An entry without a
# reason, with an unknown pattern name, or that excuses nothing (stale) fails too.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# name<TAB>extended regex; one per line.
PATTERNS=$(cat <<'EOF'
issue-number	(^|[^&])#[0-9]{3,}([^[:alnum:]]|$)
pr-number	(^|[^[:alnum:]])PRs? ?[0-9]{2,}([^[:alnum:]]|$)
kan-do	kan-do
vue-file	\.vue
nuxt	[Nn]uxt
ready-in	Ready in
expect-poll	expect\.poll
repeat-each	--repeat-each
tests-e2e	tests/e2e
e2e-specs-line	E2E-specs
wayfinder	wayfinder
EOF
)

scan() { # scan <root> [<allowlist>]: print the hits and the allowlist faults; 0 clean, 1 otherwise
  local root=$1 allow=${2:-} files f name re hits line text bad=0 used="" i=0 afile aname atext areason rest ok
  files=$(cd "$root" && { find skills -type f -name '*.md' 2>/dev/null; find reference -maxdepth 1 -type f -name '*.md' 2>/dev/null; } | LC_ALL=C sort)
  [ -n "$files" ] || { echo "test-generic: no skills/**/*.md or reference/*.md under $root"; return 1; }
  while IFS=$'\t' read -r name re; do
    while IFS= read -r f; do
      hits=$(grep -nE -- "$re" "$root/$f" 2>/dev/null) || continue
      while IFS= read -r line; do
        text=${line#*:}; ok=0; i=0
        if [ -n "$allow" ] && [ -f "$allow" ]; then
          while IFS= read -r rest; do
            i=$((i + 1))
            case "$rest" in "" | "#"*) continue ;; esac
            afile=${rest%% :: *}; rest=${rest#* :: }; aname=${rest%% :: *}; rest=${rest#* :: }; atext=${rest%% :: *}
            if [ "$afile" = "$f" ] && [ "$aname" = "$name" ]; then
              case "$text" in *"$atext"*) ok=1; used="$used $i "; break ;; esac
            fi
          done <"$allow"
        fi
        [ "$ok" = 1 ] || { bad=1; echo "$f:${line%%:*}: $name: $(printf '%s' "$text" | cut -c1-160)"; }
      done <<<"$hits"
    done <<<"$files"
  done <<<"$PATTERNS"
  if [ -n "$allow" ] && [ -f "$allow" ]; then
    i=0
    while IFS= read -r rest; do
      i=$((i + 1))
      case "$rest" in "" | "#"*) continue ;; esac
      # four fields: file :: pattern :: text :: reason
      case "$rest" in *" :: "*" :: "*" :: "*) ;; *) bad=1; echo "allowlist line $i: want '<file> :: <pattern name> :: <text> :: <reason>'"; continue ;; esac
      afile=${rest%% :: *}; rest=${rest#* :: }; aname=${rest%% :: *}; rest=${rest#* :: }; atext=${rest%% :: *}; areason=${rest#* :: }
      [ -n "$(printf '%s' "$areason" | tr -d '[:space:]')" ] && [ -n "$atext" ] || { bad=1; echo "allowlist line $i: empty text or reason"; continue; }
      printf '%s\n' "$PATTERNS" | cut -f1 | grep -qxF -- "$aname" || { bad=1; echo "allowlist line $i: unknown pattern name '$aname'"; continue; }
      case "$used" in *" $i "*) ;; *) bad=1; echo "allowlist line $i: excuses nothing in $afile (stale: delete it)" ;; esac
    done <"$allow"
  fi
  return "$bad"
}

if [ "${1:-}" = --scan ]; then
  [ -n "${2:-}" ] || { echo "usage: test-generic.sh --scan <root> [<allowlist>]" >&2; exit 64; }
  scan "$2" "${3:-}"; exit $?
fi

# --- self-test: the lint finds each pattern, and the allowlist excuses exactly what it names ---
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }
fixture() { rm -rf "$T/r"; mkdir -p "$T/r/skills/a/deep" "$T/r/reference/sub" "$T/r/docs"; echo "Generic text, issue #12, colour #393e53, &#123;." >"$T/r/skills/a/SKILL.md"; }
hit() { # hit <label> <pattern name> <relative file> <line>: that line in that file is reported under that name
  fixture; printf '%s\n' "$4" >"$T/r/$3"
  out=$(scan "$T/r"); rc=$?; want="$3:1: $2: "
  check "$1: exit 1" '[ "$rc" = 1 ]'
  check "$1: reported as $2" 'printf "%s\n" "$out" | grep -qF -- "$want"'
}
clean() { # clean <label> <relative file> <line>: nothing reported
  fixture; printf '%s\n' "$3" >"$T/r/$2"
  out=$(scan "$T/r"); rc=$?
  check "$1" '[ "$rc" = 0 ] && [ -z "$out" ]'
}

fixture; out=$(scan "$T/r"); rc=$?
check "clean fixture passes (2-digit issue, hex colour, entity)" '[ "$rc" = 0 ] && [ -z "$out" ]'
hit "3-digit issue" issue-number skills/a/SKILL.md "It cost a day (#481)."
hit "issue at line start" issue-number skills/a/SKILL.md "#1234 again"
hit "PR number" pr-number skills/a/SKILL.md "that is how PR 475 escaped"
hit "PR number, plural" pr-number skills/a/SKILL.md "PRs 12 and 13"
clean "PR without a number" skills/a/x.md "open a PR 2 times"
hit "project name" kan-do skills/a/SKILL.md "As seen in kan-do."
hit "project issue reference" issue-number skills/a/SKILL.md "see kan-do#899"
hit "vue file" vue-file skills/a/SKILL.md "setup/Foo.vue renders empty"
hit "Nuxt" nuxt skills/a/SKILL.md "a Nuxt quirk"
hit "nuxt lower case" nuxt skills/a/SKILL.md "nuxt.config.ts"
hit "ready line" ready-in skills/a/SKILL.md "grep 'Ready in' in its log"
hit "expect.poll" expect-poll skills/a/SKILL.md 'retry (`expect.poll`)'
hit "repeat-each flag" repeat-each skills/a/SKILL.md 'passes `--repeat-each=10`'
hit "tests/e2e layout" tests-e2e skills/a/SKILL.md 'the `tests/e2e/*.spec.ts`'
hit "E2E-specs line" e2e-specs-line skills/a/SKILL.md 'the `E2E-specs:` line'
hit "wayfinder" wayfinder skills/a/SKILL.md "point the user to /wayfinder"
hit "a template" issue-number skills/a/task-template.md "see #614"
hit "a nested skill file" kan-do skills/a/deep/notes.md "kan-do"
hit "reference/" nuxt reference/issue-rules.md "Nuxt"
clean "expectXpoll is not expect.poll" skills/a/x.md "expectXpoll"
clean "reference/ subfolders are not linted" reference/sub/x.md "kan-do #481"
clean "docs/ is not linted" docs/x.md "kan-do #481"
clean "non-Markdown files are not linted" skills/a/x.sh "kan-do #481"

A="$T/allow"
allowed() { fixture; printf '%s\n' "$3" >"$T/r/skills/a/x.md"; printf '%s\n' "$2" >"$A"; out=$(scan "$T/r" "$A"); rc=$?; check "$1" "$4"; }
allowed "allowlist excuses the named hit" 'skills/a/x.md :: repeat-each :: `--repeat-each=<n>` :: the example of a repeat-run command' \
  'e.g. `--repeat-each=<n>`' '[ "$rc" = 0 ] && [ -z "$out" ]'
allowed "comments and blank lines in the allowlist are skipped" "$(printf '# why\n\nskills/a/x.md :: nuxt :: Nuxt :: an example')" \
  'Nuxt' '[ "$rc" = 0 ] && [ -z "$out" ]'
allowed "another pattern on the same line is still reported" 'skills/a/x.md :: repeat-each :: --repeat-each :: an example' \
  '`--repeat-each=<n>` in tests/e2e' '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "x.md:1: tests-e2e: "'
allowed "another file is not excused" 'skills/a/y.md :: nuxt :: Nuxt :: an example' \
  'Nuxt' '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "x.md:1: nuxt: " && printf "%s" "$out" | grep -q "allowlist line 1: excuses nothing"'
allowed "another text is not excused" 'skills/a/x.md :: nuxt :: Nuxt 4 :: an example' \
  'Nuxt 3' '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "x.md:1: nuxt: "'
allowed "an entry without a reason fails" 'skills/a/x.md :: nuxt :: Nuxt' \
  'Nuxt' '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "allowlist line 1: want"'
allowed "an entry with a blank reason fails" 'skills/a/x.md :: nuxt :: Nuxt ::  ' \
  'Nuxt' '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "allowlist line 1: empty text or reason"'
allowed "an unknown pattern name fails" 'skills/a/x.md :: nuxtt :: Nuxt :: an example' \
  'Nuxt' '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "unknown pattern name"'
allowed "a stale entry fails" 'skills/a/x.md :: nuxt :: Nuxt :: an example' \
  'generic' '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "allowlist line 1: excuses nothing"'
rm -rf "$T/r/skills" "$T/r/reference"; out=$(scan "$T/r"); rc=$?
check "no files to lint fails" '[ "$rc" = 1 ]'
out=$(bash "$0" --scan 2>&1); rc=$?
check "--scan without a root: usage" '[ "$rc" = 64 ]'

# --- the repo itself ---
out=$(scan "$ROOT" "$ROOT/.claude/generic-allowlist.txt"); rc=$?
n=$((n + 1))
if [ "$rc" != 0 ]; then
  fail=$((fail + 1))
  echo "FAIL [skills/**/*.md and reference/*.md carry no project fact]"
  printf '%s\n' "$out" | sed 's/^/  /'
  echo "  A stack, file layout or project issue belongs to that project's profile or .claude/rules/ (workflow-retro step 5"
  echo "  \"Routing\"); keep the generic sentence here. A deliberate exception: one line in .claude/generic-allowlist.txt."
fi

echo "generic: $((n - fail))/$n passed"
[ "$fail" = 0 ]
