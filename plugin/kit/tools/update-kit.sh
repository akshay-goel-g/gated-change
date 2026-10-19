#!/usr/bin/env bash
#
# update-kit.sh — refresh a vendored .pipeline/ from a newer kit, without
# destroying the records that make it yours.
#
# WHY THIS EXISTS. A vendored kit is a COPY. Every fix made upstream — including
# the ones that stop `compliance` passing a change it should refuse — reaches an
# existing install only if somebody copies the files again, and until now
# nothing in this kit said how. Two fresh-context Ripple reviews raised it in
# consecutive rounds: the security fixes in a release "can never reach an
# existing install, and nothing tells anyone."
#
# It was left to a README paragraph, and that is precisely the arrangement that
# produced the dirty-install bug this kit already had — `cp -r` copied the kit's
# own ledger, config and .git into adopters' projects, and their first status
# report described the kit's history instead of theirs. An upgrade run by hand
# gets that wrong in the other direction: it is far easier to clobber
# project/surfaces.conf, ledger.jsonl and security-reports/ than to preserve
# them, and those three ARE the project's pipeline. So the refresh is mechanical
# here rather than described somewhere.
#
# WHAT MOVES, AND WHAT NEVER DOES.
#   Replaced (the portable kit — "Portable. Do not edit." is on every one):
#     core/  tools/  templates/  README.md  CHANGELOG.md  VERSION
#   Never touched (yours, and unrecoverable if lost):
#     project/  ledger.jsonl  security-reports/  dashboard.html  specs/  .git
#
# Usage:
#   bash .pipeline/tools/update-kit.sh <path-to-newer-kit> [--dry-run]
#
# Exit codes:
#   0  updated, or already current
#   1  refused — the source does not look like a kit, or the target is not one
#   2  usage error
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(dirname "$HERE")"

SRC=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '3,32p' "$0"; exit 0;;
    -*) echo "unknown option: $1" >&2; exit 2;;
    *)  [ -n "$SRC" ] && { echo "unexpected extra argument: $1" >&2; exit 2; }
        SRC="$1"; shift;;
  esac
done

[ -n "$SRC" ] || { sed -n '3,32p' "$0" >&2; exit 2; }
[ -d "$SRC" ] || { echo "no such directory: $SRC" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd)"

# Refuse to read from something that is not a kit, and refuse to write into
# something that is not one either. Copying an arbitrary directory over a
# project's .pipeline/ is unrecoverable, and "it looked like a path" is not a
# check.
for _d in core tools templates; do
  [ -d "$SRC/$_d" ] || { echo "REFUSED: $SRC has no $_d/ — that is not a kit." >&2; exit 1; }
done
[ -f "$SRC/core/01-router.md" ] || { echo "REFUSED: $SRC/core/01-router.md missing — that is not a kit." >&2; exit 1; }
[ -d "$KIT/core" ] && [ -d "$KIT/tools" ] || {
  echo "REFUSED: $KIT does not look like an installed kit." >&2; exit 1; }

if [ "$SRC" = "$KIT" ]; then
  echo "REFUSED: source and destination are the same directory." >&2
  exit 1
fi

# The same fingerprint the ledger records on every gate run (detect_kit() in
# tools/ledger.sh): version plus a checksum of the shell that does the work.
# Comparing the two answers "is this actually newer, or am I about to copy the
# same thing over itself" without any network call.
_fingerprint() {
  local root="$1" v="" h
  [ -f "$root/VERSION" ] && v="$(tr -d ' \t\r\n' < "$root/VERSION" 2>/dev/null)"
  [ -n "$v" ] || v="unknown"
  h="$(cat "$root"/tools/*.sh "$root"/tools/lib/*.sh 2>/dev/null \
       | cksum 2>/dev/null | awk '{printf "%08x", $1}')"
  printf '%s+%s' "$v" "${h:-nohash}"
}

# The fingerprint above is what the ledger stamps on each record (it must stay
# comparable across history), but it covers only tools/*.sh. As the "is this
# newer?" test it called an install current while core/ -- the gate matrix, the
# cards -- or templates/ had changed upstream, so those changes were never applied
# (E6). Whether anything portable differs is its own question: hash every file
# this script would replace, in a fixed order.
_content_sum() {
  local root="$1"
  ( cd "$root" 2>/dev/null || exit 0
    { find core tools templates -type f 2>/dev/null
      for f in README.md CHANGELOG.md VERSION; do [ -f "$f" ] && echo "$f"; done
    } | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"; tr -d '\r' < "$f"
    done | cksum | awk '{print $1 "-" $2}' )
}

OLD="$(_fingerprint "$KIT")"
NEW="$(_fingerprint "$SRC")"

echo "  installed: $OLD"
echo "  source   : $NEW"
if [ "$OLD" = "$NEW" ] && [ "$(_content_sum "$KIT")" = "$(_content_sum "$SRC")" ]; then
  echo "Already current — nothing to do."
  exit 0
fi
[ "$OLD" = "$NEW" ] && echo "  (same version and tools, but core/ or templates/ differ -- updating those)"

# Portable parts only. Everything absent from this list is either the project's
# own (and must survive) or not the kit's business.
PORTABLE_DIRS="core tools templates"
PORTABLE_FILES="README.md CHANGELOG.md VERSION"

if [ "$DRY" -eq 1 ]; then
  echo
  echo "DRY RUN — nothing written. Would replace:"
  for d in $PORTABLE_DIRS; do [ -d "$SRC/$d" ] && echo "    $d/"; done
  for f in $PORTABLE_FILES; do [ -f "$SRC/$f" ] && echo "    $f"; done
  echo "  and would leave untouched:"
  for p in project ledger.jsonl security-reports dashboard.html specs .git .install-base; do
    [ -e "$KIT/$p" ] && echo "    $p"
  done
  exit 0
fi

for d in $PORTABLE_DIRS; do
  [ -d "$SRC/$d" ] || continue
  # Remove then copy, so a file DELETED upstream actually disappears here. A
  # merge-in-place would leave a retired tool behind, still executable, still
  # looking installed — which is the failure mode this kit spends most of its
  # words on.
  #
  # Both checked explicitly rather than relying on `set -e`: this script uses
  # `cmd1 && cmd2` as a bare statement in several places above (the version-file
  # and directory-existence checks), and under `-e` a guard whose condition is
  # merely false — not an error — would abort the whole run right there. A
  # blanket `-e` trades one silent-failure shape for another. What actually
  # needs to be loud is specifically rm/cp failing mid-loop: without this check,
  # a permission error, a full disk, or a lock held on Windows (this kit's own
  # dev platform) let the loop continue to the next directory and still print
  # the unconditional "Updated" success line below, over a project directory
  # that `rm -rf` had already emptied and `cp -r` never finished refilling.
  rm -rf "$KIT/$d" || {
    echo "FAILED removing $KIT/$d -- it may now be partially deleted." >&2
    echo "Stopping here rather than continuing to the next directory. Check $KIT/$d by hand before retrying." >&2
    exit 1; }
  cp -r "$SRC/$d" "$KIT/$d" || {
    echo "FAILED copying $SRC/$d to $KIT/$d -- the destination may now be partially written." >&2
    echo "Stopping here rather than continuing to the next directory. Check $KIT/$d by hand before retrying." >&2
    exit 1; }
done
for f in $PORTABLE_FILES; do
  [ -f "$SRC/$f" ] || continue
  cp "$SRC/$f" "$KIT/$f" || {
    echo "FAILED copying $SRC/$f to $KIT/$f." >&2
    echo "Stopping here rather than continuing. Check $KIT/$f by hand before retrying." >&2
    exit 1; }
done

# `.kit-version`, when present, stamps an install's own provenance -- version
# AT INSTALL TIME, install date, and where it came from
# (written once when the kit was installed). ledger.sh's
# detect_kit() prefers this file's `version=` line over plain VERSION
# whenever it exists, which every real install does. Left alone, a vendored
# kit's `.kit-version` goes stale the moment this script updates VERSION: every
# future ledger record keeps stamping the OLD version forever, while this
# script's own fingerprint output and status.sh's banner (both read plain
# VERSION) correctly report the new one -- a silent three-way disagreement.
# Found by a fresh-context G6 Peer review.
#
# Updated IN PLACE rather than overwritten wholesale or copied from $SRC:
# `installed=`/`source=` record THIS install's own original provenance, not
# the kit's, and a source kit tree being distributed for an update carries no
# `.kit-version` of its own to copy anyway -- only a real install writes one.
if [ -f "$KIT/.kit-version" ] && [ -f "$SRC/VERSION" ]; then
  NEW_V="$(tr -d ' \t\r\n' < "$SRC/VERSION" 2>/dev/null)"
  if [ -n "$NEW_V" ]; then
    sed "s/^version=.*/version=$NEW_V/" "$KIT/.kit-version" > "$KIT/.kit-version.new" \
      && mv "$KIT/.kit-version.new" "$KIT/.kit-version"
  fi
fi

# templates/project is the skeleton new installs copy from; the LIVE project/
# is never touched above, so this is only restating what did not happen.
echo
echo "Updated $OLD → $(_fingerprint "$KIT")"
echo "  (the fingerprint above covers version + tools/*.sh only; content checksum of every portable file: $(_content_sum "$KIT"))"
echo "  Left untouched: project/  ledger.jsonl  security-reports/  dashboard.html  .install-base"
echo
echo "  Things this cannot do for you:"
echo "    1. The pre-push hook is a SEPARATE copy in .git/hooks/, taken at install"
echo "       time. It is still the old one:"
echo "         bash $KIT/tools/install-hook.sh --force"
echo "    2. Your project/ files are yours and were not merged. If this release"
echo "       added a config the cards read, CHANGELOG.md's 'Action required'"
echo "       section is where it says so."
echo "       (A new commands.conf EVIDENCE:: line or surfaces.conf row is the kind of thing it lists.)"
echo "    3. On Claude Code, a new hook in .claude/settings.json is registered by re-running"
echo "         bash $KIT/tools/install-claude-hook.sh"
echo "       (the Stop hook that blocks ending a session over a failing T3/T4 change arrived that way)."
echo
echo "  Then check what changed:  bash $KIT/tools/status.sh"
