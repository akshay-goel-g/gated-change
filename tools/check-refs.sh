#!/usr/bin/env bash
#
# check-refs.sh — does what a note claims still match the repo it describes?
#
# THE GAP THIS CLOSES. A memory note, a handoff doc, a LEARNINGS.md entry — any
# of them can name a path, a commit, or a "still pending" fact that was true
# the day it was written and silently false today. Nothing that tidies such
# notes (merging duplicates, trimming an index, fixing "next week" into a real
# date) ever reads the CODE the note is about, so nothing catches drift. This
# does exactly one narrow thing instead: read claims out of a file, check them
# against git and the filesystem, print a mismatch list. It merges nothing,
# summarizes nothing, and rewrites nothing — judging whether a flagged
# mismatch actually matters is left to whoever reads the output.
#
# WHAT IT CANNOT DO. It cannot tell whether a claim is still true in a
# SEMANTIC sense — "did this decision get superseded", "does the relocated
# version still satisfy what was originally claimed". It only flags
# candidates: a path that no longer exists, a commit sha that does not
# resolve, a file whose subject has had commits land against it since the
# file was last touched. A clean report is not proof nothing drifted; a
# flagged one is a lead, not a verdict.
#
# Usage:
#   tools/check-refs.sh --dir <path>              scan every *.md under <path>
#   tools/check-refs.sh --file <path>              scan one file
#   tools/check-refs.sh --dir <path> --root <repo> check claims against <repo>
#                                                   instead of the repo this
#                                                   script's cwd resolves to
#                                                   (the memory directory a
#                                                   claim describes is often
#                                                   OUTSIDE the repo it is
#                                                   ABOUT — --root points at
#                                                   the repo, --dir/--file at
#                                                   the notes)
#
# Exit: 0 = ran, checked at least one claim, found no mismatch.
#       1 = ran, found at least one mismatch.
#       2 = usage error, target not found, or zero claims parsed anywhere —
#           a checker matching nothing must never report success by silence
#           (the templates/pre-push placeholder-regex lesson, LEARNINGS.md).
set -uo pipefail
# resolve_commit: a sha written in a note is resolved among commit objects, never through a ref name.
if [ ! -f "$(dirname "${BASH_SOURCE[0]}")/lib/commit.sh" ]; then
  echo "missing $(dirname "${BASH_SOURCE[0]}")/lib/commit.sh — cannot resolve commits" >&2
  exit 2
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib/commit.sh"

DIR=""; FILE=""; ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)  DIR="${2:-}"; shift 2 ;;
    --file) FILE="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    *) echo "check-refs.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DIR" ] && [ -z "$FILE" ]; then
  echo "usage: check-refs.sh --dir <path> | --file <path> [--root <repo>]" >&2
  exit 2
fi
if [ -n "$DIR" ] && [ ! -d "$DIR" ]; then
  echo "check-refs.sh: no such directory: $DIR" >&2
  exit 2
fi
if [ -n "$FILE" ] && [ ! -f "$FILE" ]; then
  echo "check-refs.sh: no such file: $FILE" >&2
  exit 2
fi

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
fi
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "check-refs.sh: cannot resolve a repo root to check claims against." >&2
  echo "  Run this from inside a git repo, or pass --root <repo>." >&2
  exit 2
fi

# Collect the list of files to scan.
TARGETS=""
if [ -n "$FILE" ]; then
  TARGETS="$FILE"
else
  TARGETS="$(find "$DIR" -type f -name '*.md' 2>/dev/null | sort)"
fi
if [ -z "$TARGETS" ]; then
  echo "check-refs.sh: no .md files found under $DIR" >&2
  exit 2
fi

# Portable mtime: GNU `stat -c`, BSD/macOS `stat -f`. Neither flag exists on
# the other — this kit has hit exactly this GNU/BSD divergence before (R-003),
# so try both rather than assume.
_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

CLAIMS_SEEN=0
MISMATCHES=0

# One name per line, read from fd 3 (the body may read stdin): `for f in $TARGETS` split a name on spaces and
# a note called "my notes.md" was never checked, so its stale claims passed (G7 round 27).
while IFS= read -r f <&3; do
  [ -f "$f" ] || continue
  HEADER_PRINTED=0
  _header() {
    if [ "$HEADER_PRINTED" -eq 0 ]; then
      printf '%s\n' "$f"
      HEADER_PRINTED=1
    fi
  }

  # ---- path claims -------------------------------------------------------
  # Backticked tokens containing "/" — the convention this kit's own docs and
  # memory notes already use for a path. Deliberately not bare (unquoted)
  # path-shaped words: prose is full of "/" for other reasons (a/b meaning
  # "a or b"), and backticks are the actual signal a path is being cited.
  #
  # No whitespace allowed inside the span — without that, an odd number of
  # backticks earlier on the same line (a stray one inside prose) makes the
  # regex span from there to the NEXT backtick, capturing whole sentences as
  # one "path." Measured directly against this project's own memory notes.
  #
  # A single "/" with no dot in the basename is excluded: that shape matches
  # a Claude Code slash-command ("/code-review") or a "owner/repo" GitHub
  # slug ("akshay-goel-g/gated-change") at least as often as a real path, and
  # both were false positives here in practice. A real path either has 2+
  # slashes (a directory nesting a slash-command or slug never has) or a
  # dotted basename (an extension, a dotfile) — checked in the loop below.
  PATHS="$(grep -oE '`[^` 	]*/[^` 	]*`' "$f" 2>/dev/null | sed -e 's/^`//' -e 's/`$//' | sort -u)"
  if [ -n "$PATHS" ]; then
    _nl='
'
    _filtered=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      _slashes="$(printf '%s' "$p" | tr -cd '/' | wc -c | tr -d ' \t')"
      _base="${p##*/}"
      case "$_base" in
        *.*) _has_ext=1 ;;
        *)   _has_ext=0 ;;
      esac
      if [ "${_slashes:-0}" -ge 2 ] || [ "$_has_ext" -eq 1 ]; then
        _filtered="${_filtered}${_filtered:+$_nl}$p"
      fi
    done <<EOF
$PATHS
EOF
    PATHS="$_filtered"
  fi
  if [ -n "$PATHS" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      CLAIMS_SEEN=$((CLAIMS_SEEN + 1))
      # An absolute path (Unix "/..." or a Windows drive letter "C:\...")
      # checks as given; anything else resolves against ROOT.
      case "$p" in
        /*|[A-Za-z]:\\*|[A-Za-z]:/*) _check="$p" ;;
        *) _check="$ROOT/$p" ;;
      esac
      if [ ! -e "$_check" ]; then
        _header
        printf '  MISSING PATH   %s\n' "$p"
        MISMATCHES=$((MISMATCHES + 1))
      fi
    done <<EOF
$PATHS
EOF
  fi

  # ---- commit sha claims --------------------------------------------------
  # 7-40 lowercase hex chars, word-bounded. Some false positives are expected
  # (a hex-looking word that is not actually a sha) — verify-then-report
  # means a false positive costs a wasted glance, not a wrong claim acted on.
  SHAS="$(grep -oE '\b[0-9a-f]{7,40}\b' "$f" 2>/dev/null | sort -u)"
  if [ -n "$SHAS" ]; then
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      CLAIMS_SEEN=$((CLAIMS_SEEN + 1))
      # Verify first, exactly like coverage.sh's coverage_anchor() — never
      # hand an unverified, possibly option-shaped token to a second git call.
      full="$(cd "$ROOT" 2>/dev/null && resolve_commit "$sha" 2>/dev/null)" || full=""
      if [ -z "$full" ]; then
        _header
        printf '  UNRESOLVED SHA %s   (not a commit in %s)\n' "$sha" "$ROOT"
        MISMATCHES=$((MISMATCHES + 1))
      else
        subj="$(git -C "$ROOT" log -1 --format=%s "$full" 2>/dev/null)"
        _header
        printf '  sha %s resolves to: %s\n' "$sha" "$subj"
      fi
    done <<EOF
$SHAS
EOF
  fi

  # ---- staleness watermark -------------------------------------------------
  # Not a mismatch by itself — just "how much has moved" for the paths this
  # file names, since this file was last edited. Same shape as
  # tools/lib/coverage.sh's anchor-to-HEAD idea (commits since a reference
  # point), reused rather than reinvented.
  if [ -n "$PATHS" ]; then
    _mt="$(_mtime "$f")"
    if [ -n "$_mt" ]; then
      _since_date="$(date -u -d "@$_mt" +%Y-%m-%d 2>/dev/null || date -u -r "$_mt" +%Y-%m-%d 2>/dev/null)"
      if [ -n "$_since_date" ]; then
        _existing_paths=""
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          case "$p" in
            /*|[A-Za-z]:\\*|[A-Za-z]:/*) _cp="$p" ;;
            *) _cp="$ROOT/$p" ;;
          esac
          [ -e "$_cp" ] && _existing_paths="${_existing_paths}${_existing_paths:+ }$p"
        done <<EOF
$PATHS
EOF
        if [ -n "$_existing_paths" ]; then
          # shellcheck disable=SC2086
          _n="$(git -C "$ROOT" log --oneline --since="$_since_date" -- $_existing_paths 2>/dev/null | grep -c .)"
          if [ "${_n:-0}" -gt 0 ]; then
            _header
            printf '  WATERMARK      %s commit(s) touched what this file names, since it was last edited (%s)\n' "$_n" "$_since_date"
          fi
        fi
      fi
    fi
  fi
done 3<<<"$TARGETS"

echo
if [ "$CLAIMS_SEEN" -eq 0 ]; then
  echo "check-refs.sh: parsed zero path/sha claims across the scanned file(s) — nothing checked." >&2
  exit 2
fi
printf 'checked %s claim(s), %s mismatch(es)\n' "$CLAIMS_SEEN" "$MISMATCHES"
[ "$MISMATCHES" -eq 0 ] && exit 0
exit 1
