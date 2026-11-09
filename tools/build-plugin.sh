#!/usr/bin/env bash
#
# build-plugin.sh — prepare the plugin folder for the Claude Code plugin directory.
#
# WHY IT NO LONGER COPIES THE KIT. The directory accepts only Markdown, text, JSON, YAML and
# a few image types from an unverified publisher, and the kit is mostly bash scripts. So the
# plugin ships no kit at all: plugin/.claude-plugin/ and plugin/skills/ are written by hand,
# and the install and update skills fetch the kit from a tagged release of the public repository.
# The only thing this script still does is copy LICENSE and NOTICE to the plugin root, where the
# directory expects them, and remove a plugin/kit/ left by an older build.
#
# Usage:
#   bash tools/build-plugin.sh                # prepare plugin/ in place
#   bash tools/build-plugin.sh <plugin-dir>   # prepare <plugin-dir> elsewhere (the test uses this)
#
# Exit: 0 done; 1 a source is missing or the target could not be written.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PLUGIN="${1:-$ROOT/plugin}"

for f in LICENSE NOTICE; do
  [ -f "$ROOT/$f" ] || { echo "build-plugin: missing file $ROOT/$f" >&2; exit 1; }
done
mkdir -p "$PLUGIN"

# An older build left a generated kit here. Remove it only if it is marked as ours.
if [ -f "$PLUGIN/kit/.built-by-build-plugin" ]; then
  rm -rf "$PLUGIN/kit"
elif [ -e "$PLUGIN/kit" ]; then
  echo "build-plugin: $PLUGIN/kit exists and is not a previous build; refusing to touch it, and the plugin must not ship it" >&2
  exit 1
fi

cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$PLUGIN/"
echo "prepared $PLUGIN (no kit is shipped: the install skill fetches it from a tagged release)"
