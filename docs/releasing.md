# Releasing

For the maintainer (or a coordinator acting for them). A release is a semver tag on `main` plus its section in
[CHANGELOG.md](../CHANGELOG.md). Users get it with `bash install.sh --update`, which prints the version jump and the
new **Breaking** entries. Creating a tag or a GitHub release is outward-facing: it is the maintainer's call, an agent
does it only when told to.

## Version numbers

`vMAJOR.MINOR.PATCH`, judged from the side of someone who installed the skills:

| Bump | When | Examples |
|---|---|---|
| major | something they rely on is gone or means something else, and they must act | a skill, script path, setting, label or comment marker renamed or removed; a profile template change that needs a migration; a higher `ORCA_MIN` or `GH_MIN` |
| minor | something new, nothing to do | a new skill, flag, setting or check |
| patch | fixes and wording | a bug fix, a clearer skill step |

Every change that makes the bump major has an entry under `### Breaking` that says what to do.

## While working

Each PR that changes what a user sees adds a line to `## [Unreleased]` in `CHANGELOG.md`, in the section it belongs
to (`Breaking`, `Added`, `Changed`, `Fixed`, `Removed`). Internal refactors and test changes do not.

## Supported tool versions

They live in `bin/lib.sh`, nowhere else:

- `ORCA_TESTED` is read from `skills/aw-orca-review/snapshot/version`; `/aw-orca-review` moves it when it reviews a
  new Orca version.
- `ORCA_MIN` is the oldest Orca the workflow works with. `/aw-orca-review` raises it when an applied change relies
  on behaviour older versions lack. Below it `install.sh --check` and the `/aw-coordinate` preflight warn.
- `GH_MIN` is the oldest `gh` that has every flag the skills use (today the release that added
  `gh issue comment --attach`).

Raising `ORCA_MIN` or `GH_MIN` is a Breaking entry. The README and the other docs name the constants, never the
numbers (`.claude/test-docs.sh` checks them), also in `CHANGELOG.md`: log a raised minimum as "`ORCA_MIN` raised".

`bash install.sh --dev` also links `/aw-orca-review` (maintainer only, run by hand after an Orca update): it reviews
the new version against this workflow and asks before it changes anything. Users get the result through
`install.sh --update`.

## Cutting a release

Run from a clean checkout of `main`. `X.Y.Z` is the new version, without the `v`.

1. Be up to date and green: `git switch main && git pull --ff-only && git status --short` prints nothing; the last
   `test` run on `main` is green (`gh run list --branch main --workflow test --limit 1`); `bash test.sh` passes.
2. Check the supported versions: `bash -c '. bin/lib.sh; echo "ORCA_MIN=$ORCA_MIN ORCA_TESTED=$ORCA_TESTED GH_MIN=$GH_MIN"'`.
   `ORCA_TESTED` should be the Orca version in use (`orca --version`); if Orca is newer, run `/aw-orca-review` first.
   A minimum that went up since the last release needs its Breaking entry.
3. Pick the version from the Unreleased section with the table above (any `Breaking` entry: major). The first
   release is `1.0.0`.
4. Edit `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (today) and put a new, empty
   `## [Unreleased]` above it. Keep `### Breaking` first in the section. Remove empty subsections.
5. Commit and push: `git commit -am "chore(release): vX.Y.Z"` and `git push origin main` (a docs-only commit goes
   straight to `main`), then wait for its `test` run to turn green.
6. Tag that commit and push the tag: `git tag -a vX.Y.Z -m "vX.Y.Z"` and `git push origin vX.Y.Z`.
7. Write the release notes from the section and create the GitHub release:

   ```sh
   awk '/^## \[/{p = ($2 == "[X.Y.Z]")} p' CHANGELOG.md | tail -n +2 >/tmp/notes.md
   gh release create vX.Y.Z --title "vX.Y.Z" --notes-file /tmp/notes.md
   ```

8. Check it the way a user gets it, in a throwaway clone and config dir (never against the real `~/.claude`):

   ```sh
   d=$(mktemp -d) && git clone -q https://github.com/jaylouiz/agent-workflow.git "$d/aw"
   git -C "$d/aw" describe --tags --match 'v[0-9]*'     # prints vX.Y.Z
   CLAUDE_CONFIG_DIR="$d/claude" bash "$d/aw/install.sh" --check
   ```

A wrong tag that was already pushed is not moved: fix forward with a patch release.
