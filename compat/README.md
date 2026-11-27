# compat

Old paths that still resolve for one release, so sessions, project files and tools that name them keep working after
the v1.0.0 rename. Nothing here is a skill: no folder holds a `SKILL.md`, so no old name shows up in the skill list.

- `orchestrate-gh-issues/`: one symlink per script and template that used to live in `skills/orchestrate-gh-issues/`.
  The shared scripts now live in [`bin/`](../bin) (`~/.claude/agent-workflow/bin/`), the coordinator's own in
  `skills/aw-orchestrate/`. `install.sh` links each folder here into `~/.claude/skills/` under its name.
- `workflow-retro/ledger.sh`: the friction ledger, which the global rules and every worker spec name by its old path;
  it lives in `skills/aw-retro/`.
- `renames`: the old and new skill names, read by `install.sh`.

`bin/test-compat.sh` checks that every entry resolves. Removal: jaylouiz/agent-workflow#41.
