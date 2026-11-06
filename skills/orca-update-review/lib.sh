# Shared helpers for the orca-update-review scripts (sourced; DIR must be set).
ORCA_REPO=stablyai/orca
ORCA_PLIST=${ORCA_PLIST:-/Applications/Orca.app/Contents/Info.plist}
SNAP=${ORCA_SNAPSHOT_DIR:-$DIR/snapshot}
UPDATES_DIR=${ORCA_UPDATES_DIR:-$HOME/.claude/orca-updates}

installed_version() {
  [ -f "$ORCA_PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ORCA_PLIST" 2>/dev/null
}
reviewed_version() { cat "$SNAP/version" 2>/dev/null || echo none; }
# version_gt a b: a > b (numeric dotted versions)
version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]; }
help_name() { printf '%s' "$1" | sed 's/^orca //; s/ /-/g'; }
# has_content <file>: the fetched file holds something other than whitespace (an exit-0 fetch that printed nothing is a failed fetch).
has_content() { grep -q '[^[:space:]]' "$1" 2>/dev/null; }
# has_usage <file> <cmd>: a `Usage: <cmd>` line in the first 3 lines of the saved `--help` (the exit code of --help is not part of it).
has_usage() { head -3 "$1" 2>/dev/null | grep -q "^Usage: $2"; }
