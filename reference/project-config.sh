# shellcheck shell=bash
# issue-workflow config: <project>/.claude/issue-workflow.sh, sourced by the orchestrate-gh-issues scripts
# (spec.sh, merge-pr.sh, guard.sh). Executable project facts only; prose facts stay in .claude/issue-workflow.md.
# Every variable has a default (lib.sh); a function left undefined means that step does not apply.
# Functions run with the cwd noted; keep them quiet on success and print one line on failure.

WF_PORTS=3101-3105                    # dev-server/E2E ports, one per concurrent worker (spec.sh)
WF_MAX_WORKERS=3                      # concurrent workers in the Run (next.sh starts queued tasks up to this)
WF_RISK_GLOBS=()                      # quoted globs, e.g. ('store/**' 'server/**'): PRs touching them get a separate reviewer; ** = any depth
WF_IGNORE_GLOBS=(package-lock.json)   # not counted for the diff-size route
WF_REVIEW_LINES=400                   # changed lines above which the route is reviewer
WF_HOLD_LABELS="on-hold-after-spec do-not-merge"   # PR or issue labels that hold a merge
WF_REQUIRED_CHECKS=""                 # GitHub checks prep waits for, comma-separated names as GitHub shows them (e.g. "CI / quality, build"); empty = every reported check must not fail
WF_CHECKS_TSV=""                      # gate log with the PR head SHA per row, printed by merge-pr.sh after

# cwd: the PR's worktree, after the base branch was merged in.
# wf_verify() { npm run verify; }
# wf_build_needed() { git diff --name-only "$1"...HEAD | grep -Eq '^(package\.json|build\.config)'; }   # $1 = origin/<base>
# wf_build() { npm run build; }
# wf_install() { npm ci; }   # prep runs it in the PR worktree when merging the base brought a package.json change

# cwd: the main checkout, after the merge.
# wf_after_merge() { [ "$(git branch --show-current)" = main ] && git fetch -q origin main && git merge -q --ff-only origin/main; }
# wf_deploy_check() { echo "deploy: <state>"; }

# $1 = the PR body file; print the reason and return 1 to block gh pr create (guard.sh).
# wf_pr_body_check() { grep -q '^Test plan:' "$1" || { echo "missing 'Test plan:' line"; return 1; }; }
