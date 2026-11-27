#!/usr/bin/env bash
# Docs lint: the README stays a newcomer's page (size, sections, no version number that bin/lib.sh owns), its
# relative links and those of docs/vocabulary.md resolve, the anchors board clients cite survive, and every skill line
# that uses an optional skill says what to do without it. Run: bash .claude/test-docs.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1
fail=0; n=0
check() { n=$((n + 1)); if eval "$2"; then :; else fail=$((fail + 1)); echo "FAIL [$1]"; fi; }

check "README is under 12 KB ($(wc -c <README.md | tr -d ' ') bytes)" '[ "$(wc -c <README.md)" -lt 12000 ]'
for h in Quickstart Requirements "Without and with Orca" "With Orca" Install Settings Updating Troubleshooting Vocabulary; do
  check "README has the section '$h'" 'grep -qxF "## $h" README.md'
done
check "README: a 10-step walkthrough" '[ "$(grep -cE "^(10|[1-9])\. " README.md)" -ge 10 ] && grep -q "^10\. " README.md'
check "README: requirements for macOS and Linux" 'grep -q "^- macOS: " README.md && grep -q "^- Linux: " README.md'
check "README: the audience line replaced 'published as is'" 'grep -q "^For any developer" README.md && ! grep -qi "published as is" README.md'
check "README: no longer calls macOS the tested platform" '! grep -qi "tested platform" README.md'
for s in WF_MAX_WORKERS WF_PORTS WF_PROTO_PORTS ORCA_MIN ORCA_TESTED "install.sh --check" "install.sh --update"; do
  check "README names $s" 'grep -qF -- "$s" README.md'
done
for t in "No profile" CLAUDE_CONFIG_DIR "Orca below the minimum" "not logged in or too old" "Hooks not firing"; do
  check "Troubleshooting covers: $t" 'sed -n "/^## Troubleshooting/,/^## Vocabulary/p" README.md | grep -qF -- "$t"'
done
check "README: Orca-only settings are marked" '[ "$(grep -c "^| \`WF_.*| Orca |" README.md)" -ge 6 ] && grep -q "^| \`WF_MAX_WORKERS\` | \`3\` | Orca |" README.md && grep -q "^| \`WF_PROTO_PORTS\` | \`3111-3119\` | |" README.md'
check "README: the glossary has five terms and links to docs/vocabulary.md" '[ "$(sed -n "/^## Vocabulary/,/^Every term/p" README.md | grep -c "^- \*\*")" = 5 ] && grep -qF "](docs/vocabulary.md)" README.md'
# the supported versions live in bin/lib.sh alone: the docs name the constants, not their values
. bin/lib.sh
for v in "$GH_MIN" "$ORCA_MIN" "$ORCA_TESTED"; do
  [ -n "$v" ] || { n=$((n + 1)); fail=$((fail + 1)); echo "FAIL [bin/lib.sh sets no GH_MIN/ORCA_MIN/ORCA_TESTED value]"; continue; }
  check "no doc repeats the version $v of bin/lib.sh" '! grep -nF -- "$v" README.md CHANGELOG.md docs/releasing.md docs/vocabulary.md'
done
# every setting settings.sh reports is in the README table, and the defaults shown there are lib.sh's
wf_defaults
for s in $WF_SETTINGS; do
  case $s in WF_INSTALL_* | WF_INSTALLED_REV) continue ;; esac
  check "README settings table names $s" 'sed -n "/^## Settings/,/^## Updating/p" README.md | grep -qF -- "\`$s\`"'
done
for s in WF_MODEL_DEFAULT WF_MODEL_FAST WF_MODEL_STRONG WF_MODEL_HEAVY WF_MAX_WORKERS WF_PORTS WF_DIGEST_CAP WF_NO_WAIT_CI WF_PROTO_PORTS WF_COMMENT_CAP WF_PHASE_LABELS WF_PR_ATTRIBUTION; do
  eval "v=\$$s"
  check "README shows the default of $s ($v)" 'grep -qF -- "| \`$s\` | \`$v\` |" README.md'
done

# anchors a board client may cite: they stay in the README (pointing at the contract) and exist in the contract
for a in phases comment-markers; do
  check "README keeps the anchor #$a" 'grep -qF "<a id=\"$a\"></a>" README.md'
  check "docs/contract.md has the anchor #$a" 'grep -qF "<a id=\"$a\"></a>" docs/contract.md'
  check "README points #$a at the contract" 'grep -qF "](docs/contract.md#$a)" README.md'
done
check "README still has #settings and #vocabulary" 'grep -qx "## Settings" README.md && grep -qx "## Vocabulary" README.md'

# relative links and images resolve
links() { grep -oE '\]\([^)#: ]+(#[^)]*)?\)|(src|srcset)="[^":]+"' "$1" | sed -E 's/^\]\(//; s/^(src|srcset)="//; s/[)"]$//; s/#.*//'; }
for f in README.md docs/vocabulary.md; do
  d=$(dirname "$f")
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    check "$f: link target exists: $l" '[ -e "$d/$l" ]'
  done < <(links "$f" | sort -u)
done
check "docs/vocabulary.md holds the term table" 'grep -q "^| Term | Meaning |" docs/vocabulary.md && grep -q "^| Coordination log |" docs/vocabulary.md'

# optional skills: every skill line that names one carries the fallback; /wayfinder is named nowhere
OPT='/gh-inbox-dispatcher|/ui-canvas|[Ii]mpeccable|harvesting-session-knowledge'
miss=$(grep -rnE --include='*.md' -- "$OPT" skills | grep -v '(if installed; otherwise ' || :)
check "every optional-skill mention in skills/ has '(if installed; otherwise …)'${miss:+: $miss}" '[ -z "$miss" ]'
check "the lint finds the mentions it guards" '[ "$(grep -rnE --include="*.md" -- "$OPT" skills | wc -l)" -ge 6 ]'
check "no /wayfinder anywhere" '! grep -rnqi --exclude-dir=.git --exclude=test-generic.sh --exclude=test-docs.sh wayfinder .'

echo "docs: $((n - fail))/$n passed"
[ "$fail" = 0 ]
