# Changelog

What changed for someone who uses the skills, release by release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org)
as [docs/releasing.md](docs/releasing.md) applies it to this repo. A change that needs an action from the user goes
under **Breaking**, first in its release: `install.sh --update` prints those entries after an update.

## [Unreleased]

### Breaking

- Every skill has a new name that starts with `aw-` (type `/aw-` to list them). The old names are gone; the map is
  in [compat/renames](compat/renames), and `install.sh` prints it once when it relinks an older install.
- The shared scripts moved to `bin/` and are reached as `~/.claude/agent-workflow/bin/<script>`. The old script
  paths keep working for one release through [compat/](compat/README.md); project files and hooks that name them
  should move to the new paths.
- `CLAUDE_CONFIG_DIR` other than `~/.claude` is not supported: `install.sh` (also `--check`) warns, because the
  hooks and script paths assume `~/.claude`.

### Added

- `install.sh --update`: refuses local changes, runs `git pull --ff-only`, reruns the install only when a skill
  was added, renamed or removed or `install.sh` changed, prints the version jump or the new commits and the new
  Breaking entries, and reminds you to restart open sessions.
- Supported Orca version: `ORCA_MIN` and `ORCA_TESTED` in `bin/lib.sh`. `install.sh --check` and the
  `/aw-coordinate` preflight warn when the installed Orca is older than `ORCA_MIN`; they never block.
- `install.sh --check` also reports a `gh` older than 2.99.0 (the first release with `gh issue comment --attach`),
  `bash`, optional `shellcheck`, and whether `/code-review`, `ui-canvas` and Impeccable are installed.
- Linux: `install.sh --proto-agent` installs a `systemd --user` unit that restarts the prototype preview servers
  at login, as the LaunchAgent does on macOS.
- The installed revision is recorded as `WF_INSTALLED_REV` in the settings file.
- The stage skills resume a parked issue without Orca (`decide.sh resume`), and `/aw-coordinate` stops cleanly
  with the manual path when there is no `orca`.
- Project profile: long sections can move to their own file, with a size budget and a template version check
  (`settings.sh profile`).
- `test.sh` runs every suite; CI runs it on macOS (bash 3.2) and ubuntu.
- `WF_PR_ATTRIBUTION=off` drops the attribution line the guard hook requires in a PR body.

### Changed

- `install.sh` warns when the default, strong or fast model tier is set to a full model ID: subagents of these
  tiers need a Claude Code alias. The heavy tier takes either.

### Fixed

- `install.sh`: the retired Orca update check is removed without touching a hook of yours in the same group, and
  its path elsewhere in `settings.json` no longer causes a jq error or switches the maintainer mode on.
- A digest cap with two units (`WF_DIGEST_CAP=1h30m`) no longer prints a bash error; the 2h default applies.
