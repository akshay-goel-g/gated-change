#!/usr/bin/env bash
#
# matrix.sh — the gate matrix, read from the one place it is written down.
#
# `core/01-router.md` holds the matrix. It used to also be hardcoded in
# `ledger.sh` (which gates a tier mandates) and in `reconcile.sh` (which gates to
# print), and the copies disagreed: the router says G8 is `M⁵` — mandatory unless
# the change is invisible — while ledger.sh's copy said flatly mandatory, so an
# invisible refactor could not pass compliance without logging a G8 pass it never
# earned. A check strict enough that nobody can satisfy it honestly gets
# satisfied dishonestly, which is worse than not having it.
#
# Sourced, not executed:
#   . "$(dirname "$0")/lib/matrix.sh"
#
# Env:
#   MATRIX_ROUTER=<path>   override the router file (tests)
#   MATRIX_LOCK=<path>     override the known-good reference (tests)
#
# The table is parsed once per process and cached.
#
# Regenerate the reference after a deliberate, reviewed change to the table:
#   bash tools/lib/matrix.sh --freeze

_MATRIX_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX_ROUTER="${MATRIX_ROUTER:-$(cd "$_MATRIX_HERE/../.." && pwd)/core/01-router.md}"
MATRIX_LOCK="${MATRIX_LOCK:-$_MATRIX_HERE/matrix.lock}"

_MATRIX_TABLE=""
_MATRIX_FOOTNOTES=""
_MATRIX_LOAD_FAILED=""
# Internal only — set solely by --freeze's own code below, never from the
# environment. Unlike MATRIX_ROUTER/MATRIX_LOCK, an env-settable bypass here
# would let anyone who controls the calling process's environment (not just
# the router or lock file) silently disable the lock check outright.
_MATRIX_SKIP_LOCK=""

# macOS ships shasum, not sha256sum; openssl is the last-resort fallback. Same
# chain the rest of the kit uses for its checksums —
# one portability answer, not two. Reads stdin, prints the hex digest.
_matrix_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    return 1
  fi
}

# A missing router is not a reason to guess. Every consumer of this file is
# deciding what must happen before a change ships; a default would be a fabricated
# answer to that question.
#
# The failure is cached alongside the success: a repeat call now short-circuits
# to a fast `return 0` (success) or `return 2` (failure) instead of re-running
# the body. Without that, callers that ask the matrix several questions per
# invocation — cmd_gates alone calls
# matrix_gates() twice and matrix_name() once per gate row — each independently
# retried the load and reprinted the three-line warning, so one missing-router
# invocation could scroll the same message 4+ times with nothing distinguishing
# one occurrence from the next.
_matrix_load() {
  [ -n "$_MATRIX_TABLE" ] && return 0
  [ -n "$_MATRIX_LOAD_FAILED" ] && return 2
  if [ ! -f "$MATRIX_ROUTER" ]; then
    echo "matrix: no router at $MATRIX_ROUTER" >&2
    echo "  The gate matrix lives there and nowhere else. Without it there is no" >&2
    echo "  way to know which gates a tier mandates, and guessing is not one." >&2
    _MATRIX_LOAD_FAILED=1
    return 2
  fi

  # | **G1 · Intent** | Product manager | 15 min | — | — | R | M | M |
  # Cells keep their markers: "R¹" and "M (hard)" stay as written, because
  # resolving a footnote here would mean inventing a fact the router states in
  # prose and the ledger has no field for.
  # A row must split into exactly 10 fields (9 pipes: the leading/trailing
  # empty ones plus id, persona, budget, and five tier cells) — not merely
  # "at least 9". `NF < 9` alone let a row missing ONE pipe (two adjacent
  # cells fused by a dropped `|`, the shape a real merge conflict produces)
  # land at NF=9 and pass: the row still "parsed", still carried the right
  # gate id, but one tier cell silently absorbed its neighbor's text while
  # the LAST cell (always T4) came out empty — a HARD GATE's own mandate
  # cell reads as "" instead of "M (hard)", indistinguishable from "not
  # mandated", with no error anywhere. Found live by a fresh-context G8
  # Dogfood run against this file's own round-1/round-2 fixes
  # (security-reports/2026-09-16-matrix-router-unreadable-fails-open-round2.md).
  #
  # Neither field COUNT nor blankness is sufficient: a fresh-context G7 run
  # then found a row corrupted in TWO places whose pipe-count changes cancel
  # out (one pipe dropped, one added elsewhere in the same row) — NF stays
  # exactly 10, no cell is empty, but content shifts into the wrong columns
  # (security-reports/2026-09-16-matrix-router-unreadable-fails-open-round3.md).
  # Shape checks can only ever chase the last shape found broken. The
  # terminating fix is an allow-list on CONTENT: every real tier cell in
  # `core/01-router.md` is one of exactly nine values — an em dash, or `M`/`R`
  # optionally suffixed with ` (hard)` (M only) or one footnote superscript
  # (¹²³⁴⁵, the only markers this file currently defines). Anything else is
  # rejected outright, closing the whole class at once rather than the one
  # shape most recently caught. Alternation (`a|b|c`), not a bracket class
  # (`[abc]`): a bracket character class over multibyte glyphs is the exact
  # portability trap `_MATRIX_FOOTNOTES`'s own comment below already avoids;
  # matching each multibyte superscript as a whole literal alternative has
  # no such problem. A future footnote using a 6th marker needs this pattern
  # extended too — that failure is loud (every tier refuses, immediately,
  # the next time anyone runs compliance/reconcile) and self-explaining, the
  # opposite of the silent wrong answer this whole file exists to prevent.
  _MATRIX_TABLE="$(awk -F'|' '
    /^\| \*\*G[0-9]/ {
      if (NF != 10) next
      if (match($2, /G[0-9]+/) == 0) next
      id = substr($2, RSTART, RLENGTH)
      nm = $2
      gsub(/\*/, "", nm)
      sub(/^[^\xc2]*·[ \t]*/, "", nm)     # "G1 · Intent" -> "Intent"
      gsub(/^[ \t]+|[ \t]+$/, "", nm)
      if (nm == "" || nm ~ /^G[0-9]+$/) nm = id
      bud = $4; gsub(/[^0-9]/, "", bud)
      line = id "\t" nm "\t" (bud == "" ? "0" : bud)
      valid = 1
      for (t = 5; t <= 9; t++) {
        cell = $t
        gsub(/^[ \t]+|[ \t]+$/, "", cell)
        gsub(/\*/, "", cell)
        if (cell !~ /^—$|^(M( \(hard\))?|R)(¹|²|³|⁴|⁵)?$/) valid = 0
        line = line "\t" cell
      }
      if (!valid) next
      print line
    }
  ' "$MATRIX_ROUTER")"

  if [ -z "$_MATRIX_TABLE" ]; then
    echo "matrix: $MATRIX_ROUTER has no gate rows — is the table intact?" >&2
    _MATRIX_LOAD_FAILED=1
    return 2
  fi

  # "Non-empty" is not "intact". The awk block above silently drops any row
  # that doesn't have all 9 pipe-delimited fields (NF < 9) or whose id column
  # doesn't match G[0-9]+ — so a single truncated or reflowed row (a dropped
  # column, a broken table during a merge) leaves _MATRIX_TABLE non-empty and
  # this whole function returns success, with the missing gate silently absent
  # from every matrix_* answer. Found and reproduced against G7's own row
  # (security-reports/2026-08-13-first-push-matrix-hook-review.md, Finding 1,
  # "not fixed in this pass... flagging for a deliberate follow-up"), and
  # reproduced again live a month later by a fresh-context G7 run against
  # THIS change's own round-1 fix for the sibling bug (a whole-file-missing
  # router) — the identical failure class the sibling fix's own name promises
  # to close, just one row deep instead of the whole file.
  local _missing="" _g
  for _g in G1 G2 G3 G4 G5 G6 G7 G8; do
    printf '%s\n' "$_MATRIX_TABLE" | cut -f1 | grep -qx "$_g" || \
      _missing="${_missing}${_missing:+ }$_g"
  done
  if [ -n "$_missing" ]; then
    echo "matrix: $MATRIX_ROUTER is missing a row for: $_missing" >&2
    echo "  Every one of the eight built-in gates (G1..G8) must have a parseable row." >&2
    echo "  A table with one gate silently dropped is exactly as untrustworthy as one" >&2
    echo "  with none — guessing what the missing row would have mandated is not an" >&2
    echo "  option, least of all for a row that might be a HARD GATE." >&2
    _MATRIX_TABLE=""
    _MATRIX_LOAD_FAILED=1
    return 2
  fi

  # The two checks above close "malformed shape" and "wrong vocabulary" — they
  # do not close "well-formed, in-vocabulary, but wrong in aggregate". Every
  # one of G1..G8 can have a row, every cell can be one of the nine valid
  # values the allow-list above accepts, and a whole tier's column can still
  # legitimately parse to all "—" if every row's cell for that tier was
  # replaced with it — a find/replace or truncated edit landing on one COLUMN
  # rather than one row. "—" is valid content everywhere (it's T0's normal
  # value on every real row), so neither check above objects to it filling
  # T2, T3, or T4 too. `matrix_required`/`matrix_conditional` then legitimately
  # return empty for that tier, exit 0 — the original fail-open bug this file
  # exists to prevent, one column deep instead of one row or one file.
  # Reproduced live against a router with every T4 cell replaced by "—" (8/8
  # rows present, every cell individually valid) after both checks above.
  #
  # This checks a per-tier invariant, not a per-gate one: no tier above T1 in
  # a real matrix mandates zero gates. It does NOT catch a targeted swap of
  # two individually-valid cells that leaves each tier's own M-count unchanged
  # (e.g. G7's T1 and T4 cells swapped, so T4 still has some M elsewhere), nor
  # a single cell downgraded (M -> R) while its column still has other M's left
  # over — both are position bugs, not vocabulary or aggregate-count bugs. The
  # lock check below closes both (`task_f2ac7ba7`).
  local _t _col _bad=""
  for _t in T2 T3 T4; do
    case "$_t" in T2) _col=6;; T3) _col=7;; T4) _col=8;; esac
    printf '%s\n' "$_MATRIX_TABLE" | awk -F'\t' -v c="$_col" '$c ~ /M/ { f=1 } END { exit !f }' \
      || _bad="${_bad}${_bad:+, }$_t"
  done
  if [ -n "$_bad" ]; then
    echo "matrix: $MATRIX_ROUTER parsed, every gate has a row, every cell is valid" >&2
    echo "  vocabulary — but no gate is mandatory (M) anywhere at $_bad. A real matrix" >&2
    echo "  always mandates something above T1, at every tier. Treating this as" >&2
    echo "  corrupted rather than as a legitimate 'nothing required' answer: guessing" >&2
    echo "  release needs no gates is not a risk this file takes silently." >&2
    _MATRIX_TABLE=""
    _MATRIX_LOAD_FAILED=1
    return 2
  fi

  # Footnote lines sit directly under the table and begin with a superscript.
  # They are found positionally, exactly as dashboard.sh does it: matching a
  # multibyte character class portably is a fight with no prize at the end.
  _MATRIX_FOOTNOTES="$(awk '
    /^\| \*\*G[0-9]/ { intable = 1; next }
    intable && /^\|/  { next }
    intable {
      if ($0 ~ /^[ \t]*$/) next
      if ($0 ~ /^(#|\*\*|---)/) { exit }
      print
    }
  ' "$MATRIX_ROUTER")"

  # `--freeze` (bottom of this file) parses the table through this same
  # function to compute what the reference SHOULD be — it cannot ask this
  # check to pass before the reference it is about to write even exists.
  if [ -z "$_MATRIX_SKIP_LOCK" ]; then
    _matrix_verify_lock || return 2
  fi
  return 0
}

# Position/permutation integrity: the checks above validate shape, vocabulary,
# and per-tier aggregate counts, but none of them validate WHICH gate a
# mandate belongs to. Two already-legal cells swapped (one gate's T1 and T4
# cells traded, so T4's own M-count is unchanged but the mandate is now
# attached to the wrong gate), or a single cell quietly downgraded from `M` to
# `R` while its column still has other M's left over (no swap needed — every
# real T2/T3/T4 column has more than one M, so the per-tier aggregate check
# above never notices one going missing) — both parse clean, use valid
# vocabulary, and pass the per-tier aggregate check. Live-reproduced against
# the real repo: G7's T4 cell alone changed from `**M (hard)**` to `R`
# silently drops G7 from `matrix_required T4` entirely, and
# `ledger.sh compliance --tier T4` never even names G7 as mandated — a stale
# logged G7 pass would satisfy compliance with zero re-verification.
#
# Neither shape is closable by more shape/vocabulary/aggregate checks on the
# table alone: the only way to catch "well-formed and individually plausible,
# but wrong" is comparing the whole table's exact content against a
# known-good reference — the same reason a dependency lockfile pins an exact
# version rather than trusting that a file which still parses as valid
# JSON/TOML names the right one.
#
# The reference ($MATRIX_LOCK) is a single sha256 hex digest of the PARSED
# table (id/name/budget/five cells, one row per gate, gate order) — not of
# the raw markdown file, so a prose-only edit elsewhere in the router (R0a/
# R0b text, footnote wording, this file's own comments) does not spuriously
# invalidate it; only a change that could alter what `matrix_required`
# answers does. It is regenerated by a deliberate act, never automatically:
# `bash tools/lib/matrix.sh --freeze`, run only after a REVIEWED, intentional
# change to the table — never as a side effect of loading it, or this
# wouldn't be a check, it would be a rubber stamp. A missing reference fails
# exactly like a missing router: there is no default here either.
#
# This closes accidental/silent corruption — a bad merge, a scripted
# find/replace, a fat-fingered edit — the same class every check above
# closes. It does NOT defend against a single commit that edits
# core/01-router.md and tools/lib/matrix.lock together with intent: that
# always requires a human actually reading the diff (G6/G7), same as it
# always has for every other file in this repo. A mismatch is loud and
# immediate — refused, not silently accepted — which is the whole point.
_matrix_verify_lock() {
  local _actual _expected
  if ! _actual="$(printf '%s' "$_MATRIX_TABLE" | _matrix_hash)"; then
    echo "matrix: no sha256sum, shasum, or openssl found on this machine — cannot" >&2
    echo "  verify $MATRIX_ROUTER against its known-good reference. Refusing rather" >&2
    echo "  than trusting a table this process cannot check." >&2
    _MATRIX_TABLE=""
    _MATRIX_LOAD_FAILED=1
    return 1
  fi
  if [ ! -f "$MATRIX_LOCK" ]; then
    echo "matrix: no known-good reference at $MATRIX_LOCK" >&2
    echo "  Shape and vocabulary checks passed, but this file also compares the" >&2
    echo "  table's exact content against a known-good reference, to catch a" >&2
    echo "  mandate silently reattached to the wrong gate (a swap, or a single" >&2
    echo "  cell downgraded) — neither is visible to shape or vocabulary checks." >&2
    echo "  Without the reference there is nothing to compare against. If" >&2
    echo "  core/01-router.md's table is correct as it stands, create the" >&2
    echo "  reference deliberately: bash tools/lib/matrix.sh --freeze" >&2
    _MATRIX_TABLE=""
    _MATRIX_LOAD_FAILED=1
    return 1
  fi
  _expected="$(awk '{print $1; exit}' "$MATRIX_LOCK")"
  if [ "$_actual" != "$_expected" ]; then
    echo "matrix: $MATRIX_ROUTER's table does not match its known-good reference" >&2
    echo "  at $MATRIX_LOCK. Every cell still parses and uses valid vocabulary, but" >&2
    echo "  the table's exact content changed — which can mean a mandate silently" >&2
    echo "  moved to the wrong gate, not just a legitimate edit. If this change was" >&2
    echo "  deliberate and reviewed, regenerate the reference:" >&2
    echo "    bash tools/lib/matrix.sh --freeze" >&2
    echo "  If it was not, core/01-router.md itself needs fixing, not the reference." >&2
    _MATRIX_TABLE=""
    _MATRIX_LOAD_FAILED=1
    return 1
  fi
  return 0
}

matrix_gates() { _matrix_load || return 2; printf '%s\n' "$_MATRIX_TABLE" | cut -f1; }

matrix_name() {
  _matrix_load || return 2
  printf '%s\n' "$_MATRIX_TABLE" | awk -F'\t' -v g="$1" '$1 == g { print $2; found = 1 }
    END { if (!found) print g }' g="$1"
}

matrix_budget() {
  _matrix_load || return 2
  printf '%s\n' "$_MATRIX_TABLE" | awk -F'\t' -v g="$1" '$1 == g { print $3; found = 1 }
    END { if (!found) print 0 }'
}

# The cell as written: M · R · — · M (hard) · M⁵ · R³
matrix_cell() {
  _matrix_load || return 2
  local col
  case "$2" in T0) col=4;; T1) col=5;; T2) col=6;; T3) col=7;; T4) col=8;; *) printf ''; return 0;; esac
  printf '%s\n' "$_MATRIX_TABLE" | awk -F'\t' -v g="$1" -v c="$col" '$1 == g { print $c }'
}

# Cells that are recommended-with-a-footnote: the footnote can promote them to
# mandatory in a circumstance the matrix cannot see (a bug fix, a UI surface, a
# network call). Reported, never blocking — M means mandatory and R does not.
matrix_conditional() {
  _matrix_load || return 2
  local g cell
  for g in $(matrix_gates); do
    cell="$(matrix_cell "$g" "$1")"
    case "$cell" in
      *M*) ;;
      *) [ -n "$(matrix_marker "$g" "$1")" ] && printf '%s\n' "$g";;
    esac
  done
}

# Gates whose cell at this tier mandates them. Recommended (R) gates are
# deliberately absent: this answers "was the required work done", not "was every
# optional gate considered".
matrix_required() {
  _matrix_load || return 2
  local g cell
  for g in $(matrix_gates); do
    cell="$(matrix_cell "$g" "$1")"
    case "$cell" in *M*) printf '%s\n' "$g";; esac
  done
}

# What is left of a cell once M, R, (hard) and punctuation are removed — i.e. the
# footnote marker, or nothing. Byte-wise on purpose: the marker is multibyte and
# only ever needs to be compared against the start of a footnote line, never
# interpreted.
matrix_marker() {
  local cell; cell="$(matrix_cell "$1" "$2")"
  cell="${cell//M/}"; cell="${cell//R/}"; cell="${cell//(hard)/}"
  cell="${cell//—/}"; cell="${cell// /}"
  printf '%s' "$cell"
}

# Does this cell depend on a fact the matrix does not carry?
matrix_is_conditional() { [ -n "$(matrix_marker "$1" "$2")" ]; }

# The footnote text for a marker, so a tool can print the question rather than
# telling the user to go and look it up.
# The footnotes wrap: the marker starts a line and the rest is indented under it.
# Continuations are joined, so a caller gets the whole sentence rather than the
# first line of it and a question it cannot answer.
matrix_footnote() {
  _matrix_load || return 2
  local marker="$1" line out="" collecting=0
  [ -n "$marker" ] || return 0
  while IFS= read -r line; do
    if [ "$collecting" -eq 1 ]; then
      case "$line" in
        [[:space:]]*) out="$out $(printf '%s' "$line" | sed 's/^[[:space:]]*//')";;
        *) break;;
      esac
      continue
    fi
    case "$line" in
      "$marker"*) out="${line#"$marker"}"; collecting=1;;
    esac
  done <<EOF
$_MATRIX_FOOTNOTES
EOF
  printf '%s' "$out"
}

# Regenerate $MATRIX_LOCK from the CURRENT table — a deliberate act, run by a
# human right after a reviewed, intentional change to core/01-router.md,
# never automatically and never as a side effect of sourcing this file. Only
# reachable by executing this file directly (`bash tools/lib/matrix.sh
# --freeze`); every normal caller sources it, where `$0` is the caller's own
# path, not this file's, and the guard below stays false.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    --freeze)
      _MATRIX_SKIP_LOCK=1
      if ! _matrix_load; then
        echo "matrix: $MATRIX_ROUTER failed shape/vocabulary/aggregate checks — fix" >&2
        echo "  the router before freezing a reference for it; freezing a broken" >&2
        echo "  table would just make the reference agree with the breakage." >&2
        exit 2
      fi
      _hash="$(printf '%s' "$_MATRIX_TABLE" | _matrix_hash)" || {
        echo "matrix: no sha256sum, shasum, or openssl found — cannot compute a hash." >&2
        exit 1
      }
      printf '%s  sha256 of the parsed table in %s — regenerate with: bash %s --freeze\n' \
        "$_hash" "$MATRIX_ROUTER" "$0" > "$MATRIX_LOCK"
      echo "matrix: wrote $_hash" >&2
      echo "  to $MATRIX_LOCK" >&2
      ;;
    "")
      echo "usage: bash $0 --freeze" >&2
      echo "  Regenerates $MATRIX_LOCK from the current table. Run this only after" >&2
      echo "  reviewing an intentional change to core/01-router.md's gate matrix." >&2
      exit 1
      ;;
    *)
      echo "matrix: unknown option '$1' — the only direct-execution mode is --freeze" >&2
      exit 1
      ;;
  esac
fi
