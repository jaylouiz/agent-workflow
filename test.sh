#!/usr/bin/env bash
# Run every test suite of this repo: bin/test-*.sh, skills/*/test-*.sh and .claude/test-*.sh. The one list of suites: CI
# (.github/workflows/test.yml) and the merge gate (wf_verify in .claude/issue-workflow.sh) both call this.
#
#   bash test.sh               run all suites, then one summary naming the failed ones
#   bash test.sh --fail-fast   stop at the first failing suite
#
# Each suite runs with the `bash` on PATH from the repo root; a failed suite shows the last 20 lines of its output
# (TEST_TAIL=<n> for more: CI sets it).
# Exit: 0 all passed, 1 a suite failed (or none found), 64 usage.
set -u
fail_fast=0
for a in "$@"; do
  case "$a" in
    --fail-fast) fail_fast=1 ;;
    -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test.sh: unknown argument: $a" >&2; exit 64 ;;
  esac
done
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

n=0; failed=""
for f in bin/test-*.sh skills/*/test-*.sh .claude/test-*.sh; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  if out=$(bash "$f" 2>&1); then
    echo "ok    $f"
  else
    echo "FAIL  $f"; printf '%s\n' "$out" | tail -n "${TEST_TAIL:-20}" | sed 's/^/      /'
    failed="$failed $f"
    [ "$fail_fast" = 0 ] || break
  fi
done

[ "$n" -gt 0 ] || { echo "test.sh: no suites found"; exit 1; }
if [ -z "$failed" ]; then echo "test.sh: $n/$n suites passed"; exit 0; fi
set -- $failed
echo "test.sh: $# of $n suites failed:$failed"
exit 1
