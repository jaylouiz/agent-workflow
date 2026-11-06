# shellcheck shell=bash
# issue-workflow config for agent-workflow (sourced by the orchestrate-gh-issues scripts; template: reference/project-config.sh).
# Shell scripts only: no dev server (default WF_PORTS stay unused), no build, no deploy, no PR-body check.

# Hooks and always-loaded files every session runs: a bug there breaks all sessions, so these PRs get a separate reviewer.
WF_RISK_GLOBS=(
  'skills/orchestrate-gh-issues/guard.sh'
  'skills/orchestrate-gh-issues/worker-done-stop.sh'
  'skills/orca-update-review/check.sh'
  'global/CLAUDE.md'
  'install.sh'
)

# cwd: the PR's worktree. Runs every skill test suite plus this config's own test; stops at the first failure.
wf_verify() {
  local f out
  for f in skills/*/test-*.sh .claude/test-*.sh; do
    [ -f "$f" ] || continue
    if ! out=$(bash "$f" 2>&1); then
      echo "verify failed: $f"; printf '%s\n' "$out" | tail -n 20
      return 1
    fi
  done
}

# Reruns install.sh (relinks ~/.claude/skills, the global CLAUDE.md and the SessionStart hook). Tests override it.
wf_install_skills() { bash "$PWD/install.sh"; }

# cwd: the main checkout, which ~/.claude/skills/* point into: bring it to origin/main so merged skills go live.
wf_after_merge() {
  local old new
  [ "$(git branch --show-current)" = main ] || { echo "after-merge: main checkout is not on main, not updated"; return 1; }
  git fetch -q origin main || { echo "after-merge: fetch failed"; return 1; }
  old=$(git rev-parse HEAD)
  git merge -q --ff-only origin/main || { echo "after-merge: cannot fast-forward main (local changes or commits?)"; return 1; }
  new=$(git rev-parse HEAD)
  [ "$old" != "$new" ] || return 0
  # install.sh links one directory per skill: a changed skills/ listing (added, removed, renamed) or install.sh itself needs a rerun
  if [ "$(git ls-tree --name-only "$old" skills/)" != "$(git ls-tree --name-only "$new" skills/)" ] ||
     ! git diff --quiet "$old" "$new" -- install.sh; then
    wf_install_skills >/dev/null || { echo "after-merge: install.sh failed"; return 1; }
    echo "after-merge: reran install.sh"
  fi
}
