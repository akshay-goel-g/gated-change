#!/usr/bin/env bash
#
# status.sh — "is the pipeline actually on, for the work in front of me?"
#
# THE GAP THIS CLOSES. Every other read command in this kit requires you to
# already know the answer: `ledger.sh compliance --change <name> --tier T4`
# needs the change name and its tier before it will tell you anything. If the
# pipeline never ran, there IS no change name, so the question cannot even be
# formed. And nothing in the kit ever compared the ledger against git history
# — the ledger only knows what was written INTO it, so its silence is
# indistinguishable between "no work happened" and "work happened and every
# gate was asleep." Measured on this kit's own repo when this file was
# written: 63 commits, 18 of them ever named in the ledger, and two gates
# (G2 Scout, G3 Craft) that had never run once in the project's entire
# history. None of that was visible from any command that existed.
#
# This is `05-enforcement.md`'s own charge against a silent hook — "a hook
# that prints only on failure has no way to tell you it is asleep" — applied
# to the pipeline itself rather than to one hook.
#
# WHAT IT DOES NOT DO. It does not attribute a gate to each commit. Gate runs
# record the commit they REVIEWED; the fix then lands as a later commit, so
# per-commit attribution would report every legitimate fix as a violation.
# What it reports instead is honest and computable: work that has landed
# SINCE the last recorded gate run, tiered by the same `surfaces.conf` rules
# `reconcile.sh` already uses. That set is exactly R0c's concern — the edits
# made after routing already ran.
#
# Usage:
#   bash .pipeline/tools/status.sh            # human summary
#   bash .pipeline/tools/status.sh --quiet    # exit code only, no output
#
# Exit: 0 = nothing unrouted above T2.  1 = unrouted T3/T4 work exists.
#       2 = cannot answer (not a repo, no surfaces file).
# A non-zero "there is unrouted T3/T4 work" is deliberately distinct from a
# 2 "I could not tell" — a caller that cannot tell those apart would treat a
# broken install as a clean bill of health, which is the failure this file
# exists to make impossible.
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$(dirname "$_HERE")}"
# DATA = where this project's own files live (project/, ledger.jsonl, dashboard.html, security-reports/). The kit's
# directory unless PIPELINE_DATA says otherwise (D5): a plugin's code directory is shared and read-only.
. "$KIT/tools/lib/data-root.sh"
data_root_require status.sh
DATA="${PIPELINE_DATA:-$KIT}"
CONF="${SURFACES:-$DATA/project/surfaces.conf}"
LEDGER="${LEDGER:-$DATA/ledger.jsonl}"
DASHBOARD="$DATA/dashboard.html"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "not a git repository — status cannot be computed here" >&2; exit 2; }

if [ ! -f "$CONF" ]; then
  echo "No surfaces file at $CONF." >&2
  echo "  Tiering is what makes 'unrouted' mean anything; without it this" >&2
  echo "  command would have to report every commit or none. Refusing to" >&2
  echo "  guess — start from templates/project/surfaces.conf." >&2
  exit 2
fi

# The coverage computation itself lives in tools/lib/coverage.sh, shared with
# tools/dashboard.sh. Two implementations of "what is unrouted" is how the gate
# matrix once came to disagree with itself (see tools/lib/matrix.sh's own reason
# for existing); a coverage number that differs between the terminal and the
# dashboard is worse than either answer alone, because whichever a reader
# happens to see, the other is wrong.
if [ ! -f "$KIT/tools/lib/coverage.sh" ]; then
  echo "missing $KIT/tools/lib/coverage.sh — cannot compute coverage" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "$KIT/tools/lib/coverage.sh"

say ""
say "Pipeline status — $(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo .)")"
say "======================================================================"
say ""

# ---------------------------------------------------------------- the ledger
#
# The last gate LOGGED, and the commit that entry names — an audit-trail
# statement ("what does the tail of the file say right now"), not a claim
# about which commit is newest in the repo's history. Read from the LAST
# matching line rather than the highest date: the ledger is append-only by
# design (04-ledger.md), so file order IS chronological LOGGING order, and a
# date field that may be a bare day or a full instant (both permanently
# valid) does not sort reliably against itself for same-day entries.
#
# That is a narrower claim than it looks. `ledger.sh add --commit <sha>`
# lets an entry name a commit other than the one being logged against right
# now — a retro/backfilled review, most often — so the LAST-LOGGED entry and
# the LAST-REVIEWED commit (`coverage_anchor()`, below) can legitimately name
# two different commits. A fresh G4/G8 round on `coverage_anchor()`'s own fix
# hit this: before that fix, both readings shared the same (buggy) append-
# order logic and always agreed; after it, they can visibly disagree on this
# same screen with nothing here explaining why. The disagreement note below
# (after SINCE_REF is computed) is that explanation.
LAST_GATE_LINE=""
LAST_COMMIT=""
LAST_DATE=""
LAST_CHANGE=""
if [ -f "$LEDGER" ]; then
  LAST_GATE_LINE="$(grep '"type":"gate"' "$LEDGER" 2>/dev/null | grep -E '"outcome":"(pass|fail)"' | tail -1)"
  if [ -n "$LAST_GATE_LINE" ]; then
    LAST_COMMIT="$(printf '%s' "$LAST_GATE_LINE" | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p')"
    LAST_DATE="$(printf '%s' "$LAST_GATE_LINE" | sed -n 's/.*"date":"\([^"]*\)".*/\1/p')"
    LAST_CHANGE="$(printf '%s' "$LAST_GATE_LINE" | sed -n 's/.*"change":"\([^"]*\)".*/\1/p')"
  fi
fi

if [ ! -f "$LEDGER" ]; then
  say "  LEDGER      none at $LEDGER"
  say "              No gate has ever been recorded in this project."
elif [ -z "$LAST_GATE_LINE" ]; then
  say "  LEDGER      exists, but holds no gate verdicts (pass or fail)"
  say "              Routes, escapes, or only skipped / n/a gate rows — no gate has produced a verdict here."
else
  say "  LAST GATE   $LAST_DATE — $LAST_CHANGE (commit ${LAST_COMMIT:-unrecorded})"
fi

# ---------------------------------------------------------------- gates never run
#
# A gate that has never run once is a different fact from a gate that ran and
# found nothing, and only one of them is a problem.
NEVER="$(coverage_never_run "$LEDGER" "$KIT")"
[ -n "$NEVER" ] && say "  NEVER RUN   $NEVER — no ledger entry has ever named these"

# ---------------------------------------------------------------- unrouted work
#
# "Since the last gate run" needs a commit that actually exists in THIS
# repository's history. A ledger may legitimately name commits this clone has
# never seen — a fleet/project ledger, a squashed or rewritten history, a
# short sha from a different repo. Verifying with rev-parse rather than
# assuming is the difference between "0 commits since" (a confident lie, and
# the best-looking possible output) and an honest "cannot anchor."
SINCE_REF="$(coverage_anchor "$LEDGER")"   # one sha, or several separated by spaces (merged lines, each gated)

RANGE_LABEL=""
if [ -n "$SINCE_REF" ]; then
  RANGE="$(coverage_range "$SINCE_REF")"
  if [ "$(printf '%s\n' $SINCE_REF | grep -c .)" -gt 1 ]; then
    RANGE_LABEL="since the last gated commits ($(printf '%s' "$SINCE_REF" | sed 's/ /, /g')) — two lines of history, each gated"
  else
    RANGE_LABEL="since the last gated commit ($SINCE_REF)"
  fi
else
  # No anchor. Report history rather than nothing: a project that has never
  # gated anything is exactly the case that most needs an answer, and it is
  # the one an anchored-only implementation would silently skip.
  RANGE="HEAD"
  # The newest gate row names a commit that IS here but no single gated commit is the newest: they sit
  # on separate lines of history (two merged branches, each gated on its own). That is a different
  # fact from "not found in this repo" (G8 round 11), and the fix is different: gate the merged tip.
  LAST_IN_REPO=0
  [ -n "$LAST_COMMIT" ] && resolve_commit "$LAST_COMMIT" >/dev/null 2>&1 && LAST_IN_REPO=1
  AMBIG_NOTE="the ledger names gated commits, but none is reachable from HEAD (a squash or rebase merge, or a branch the gates were not logged on) -- log a gate on the commit you are on to anchor"
  if [ -n "$LAST_COMMIT" ] && [ "$LAST_IN_REPO" -eq 1 ]; then
    RANGE_LABEL="in the whole history — $AMBIG_NOTE"
  elif [ -n "$LAST_COMMIT" ]; then
    RANGE_LABEL="in the whole history — ledger names commit '$LAST_COMMIT', not found in this repo"
  else
    RANGE_LABEL="in the whole history — no gated commit to anchor to"
  fi
  # Nothing gated yet: count from the install, not from the beginning of time (E10).
  BASELINE_REF="$(coverage_baseline "$KIT")"
  # A BASELINE that does not name a commit here used to be dropped without a word, so a typo looked applied.
  BASELINE_WARN=""
  if [ -n "${BASELINE:-}" ] && [ "$BASELINE" != none ] && [ -z "$BASELINE_REF" ]; then
    BASELINE_WARN="BASELINE='$BASELINE' is not a commit in this repository and was ignored -- the whole history is counted"
  fi
  # A pin file that is there but gives no cutoff (empty, garbage, a sha this clone lacks) is never
  # rewritten, so every later run counts the whole history. Say why and how to get out (G4 round 22).
  PIN_WARN=""
  # Same conditions as coverage_baseline's pin branch: the kit lives in THIS repo (not another one's
  # subdirectory), is not committed and not ignored. With those, an empty answer means the pin gave no
  # cutoff -- present but unusable, a dangling link, or absent and not writable (G4 round 23).
  if [ -z "$BASELINE_REF" ] && [ -z "${BASELINE:-}" ] \
     && [ -z "$(git -C "$KIT" ls-files -- tools/status.sh 2>/dev/null)" ] \
     && ! git -C "$KIT" check-ignore -q tools/status.sh 2>/dev/null \
     && [ -n "$(git -C "$KIT" rev-parse --show-prefix 2>/dev/null)" ] \
     && [ "$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null)" = "$(git rev-parse --show-toplevel 2>/dev/null)" ] \
     && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    PIN_WARN="the install pin $KIT/.install-base gives no cutoff (empty, not a commit here, a link, or it could not be written), so the whole history is counted -- delete that file to pin again at the CURRENT HEAD (work committed since the install then stops counting), or set BASELINE=<the install commit>"
  fi
  if [ -n "$BASELINE_REF" ]; then
    RANGE="${BASELINE_REF}..HEAD"
    if [ -n "$LAST_COMMIT" ]; then
      # Not "since ...": that reads as an anchored count from the last REVIEWED commit, and the
      # ledger's commit is not in this repo, so there is no such anchor.
      _bl_from="the kit's install"; [ -n "${BASELINE:-}" ] && _bl_from="your BASELINE cutoff"
      if [ "$LAST_IN_REPO" -eq 1 ]; then
        RANGE_LABEL="counted from $_bl_from (${BASELINE_REF:0:7}), not from a reviewed commit — $AMBIG_NOTE"
      else
        RANGE_LABEL="counted from $_bl_from (${BASELINE_REF:0:7}), not from a reviewed commit — ledger names commit '$LAST_COMMIT', not found in this repo"
      fi
    else
      if [ -n "${BASELINE:-}" ]; then
        # An explicit BASELINE is the user's own cutoff, not the install commit: never call it that.
        RANGE_LABEL="since BASELINE ${BASELINE_REF:0:7} (your cutoff) — no gated commit to anchor to"
      elif [ -z "$(git -C "$KIT" ls-files -- tools/status.sh 2>/dev/null)" ] \
           || { [ -f "$KIT/.install-base" ] && [ "$(tr -d ' \t\r\n' < "$KIT/.install-base" 2>/dev/null | cut -c1-7)" = "${BASELINE_REF:0:7}" ]; }; then
        # (second test: the kit has since been committed, but work done between the first check and
        # that commit still counts, from the pin -- see coverage_baseline)
        if [ -z "$(git -C "$KIT" ls-files -- tools/status.sh 2>/dev/null)" ]; then
          RANGE_LABEL="since the kit was first checked (${BASELINE_REF:0:7}, pinned; the kit is not committed yet) — no gated commit to anchor to"
        else
          RANGE_LABEL="since the kit was first checked (${BASELINE_REF:0:7}, pinned; work committed before the kit itself is counted) — no gated commit to anchor to"
        fi
      elif [ -z "${BASELINE:-}" ] && [ "$(git -C "$KIT" log --diff-filter=A --format=%H -- tools/status.sh 2>/dev/null | tail -1)" != "$(git rev-parse "$BASELINE_REF" 2>/dev/null)" ]; then
        RANGE_LABEL="since just before the kit was installed (${BASELINE_REF:0:7}; the install commit also carries project work, so it is counted) — no gated commit to anchor to"
      else
        RANGE_LABEL="since the kit was installed (${BASELINE_REF:0:7}) — no gated commit to anchor to"
      fi
    fi
    # Commits BEFORE the install; the install commit itself is not "earlier". When the kit is not
    # committed yet the pin is the last commit that existed BEFORE it (a user's own), which is
    # earlier history and has to be counted there, or it appears in neither number.
    if [ -z "$(git -C "$KIT" ls-files -- tools/status.sh 2>/dev/null)" ] \
       || [ "$(git -C "$KIT" log --diff-filter=A --format=%H -- tools/status.sh 2>/dev/null | tail -1)" != "$(git rev-parse "$BASELINE_REF" 2>/dev/null)" ]; then
      N_BEFORE="$(git rev-list --count "${BASELINE_REF}" 2>/dev/null || echo 0)"
    else
      N_BEFORE="$(git rev-list --count "${BASELINE_REF}^" 2>/dev/null || echo 0)"
    fi
  fi
fi

N_COMMITS="$(git rev-list --count $RANGE -- 2>/dev/null || echo 0)"   # `--`: a root file named HEAD is not a revision

# A window, not the whole history, when unanchored. Installing this kit into an
# existing repo with thousands of commits is the normal adoption path, and this
# is the one command meant to be run casually — a first invocation that takes
# an hour is one nobody runs twice. Overridable, and the truncation is always
# stated out loud rather than quietly changing what "unrouted" counts.
MAX_SCAN="${MAX_SCAN:-500}"
SCANNED="$N_COMMITS"
[ "$SCANNED" -gt "$MAX_SCAN" ] && SCANNED="$MAX_SCAN"

say ""
say "  UNROUTED WORK"
say "  -------------"
say "  $N_COMMITS commit(s) $RANGE_LABEL"
[ -n "${BASELINE_WARN:-}" ] && say "  ($BASELINE_WARN)"
[ -n "${PIN_WARN:-}" ] && say "  ($PIN_WARN)"
[ -n "${N_BEFORE:-}" ] && [ "${N_BEFORE:-0}" -gt 0 ] &&   say "  ($N_BEFORE earlier commit(s) predate $([ -n "${BASELINE:-}" ] && echo 'your BASELINE cutoff' || echo 'the install') and are not counted — BASELINE=none to include them)"
[ "$N_COMMITS" -gt "$MAX_SCAN" ] && \
  say "  (tiering the most recent $MAX_SCAN — set MAX_SCAN= to widen)"

# The LAST GATE line above and this range both say "last" but answer
# different questions (see the comment at LAST_GATE_LINE) — a retro-logged
# `--commit` entry is the one case where they can legitimately disagree.
# Silent disagreement is exactly the "confident wrong answer" this file
# exists to avoid, so state it out loud instead of leaving two numbers on
# screen with no stated relationship.
if [ -n "$LAST_COMMIT" ] && [ -n "$SINCE_REF" ]; then
  # Compare RESOLVED commits, not the raw strings: `--commit` can be logged as
  # a short or full sha interchangeably, so the same commit can reach
  # LAST_COMMIT and SINCE_REF in two different-length forms that would
  # string-compare unequal despite naming one commit — a false "these
  # disagree" note is exactly the kind of confident-wrong-answer this whole
  # file exists to avoid. A fresh G6 round on this exact note found it.
  LAST_COMMIT_FULL="$(resolve_commit "$LAST_COMMIT" 2>/dev/null)"
  SINCE_REF_FULL=""; ANCHOR_MATCHES_LAST=0
  for _sr in $SINCE_REF; do
    _srf="$(resolve_commit "$_sr" 2>/dev/null)" || continue
    SINCE_REF_FULL="$_srf"
    [ "$_srf" = "$LAST_COMMIT_FULL" ] && ANCHOR_MATCHES_LAST=1
  done
  if [ -n "$LAST_COMMIT_FULL" ] && [ -n "$SINCE_REF_FULL" ] && [ "$ANCHOR_MATCHES_LAST" -eq 0 ]; then
    say "  (LAST GATE, above, names a different commit than this — the last LOGGED"
    say "   entry named a commit other than the newest REVIEWED one, most often a"
    say "   retro-logged review. Both are correct; they answer different questions.)"
  fi
fi

SCAN_OUT="$(coverage_scan "$CONF" "$RANGE" "$SCANNED" "$(coverage_kit_prefix "$KIT")" "$(coverage_data_prefix)")"

HIGHEST=0
T4_LIST=""
T3_LIST=""
if [ -n "$SCAN_OUT" ]; then
  while IFS="$(printf '\t')" read -r top rest; do
    [ -n "$top" ] || continue
    [ "$top" -gt "$HIGHEST" ] && HIGHEST=$top
    case "$top" in
      4) T4_LIST="${T4_LIST}    $rest
";;
      3) T3_LIST="${T3_LIST}    $rest
";;
    esac
  done <<EOF
$SCAN_OUT
EOF
fi

if [ -n "$T4_LIST" ]; then
  say ""
  say "  T4 — trust boundary, never re-gated:"
  [ "$QUIET" -eq 1 ] || printf '%s' "$T4_LIST"
fi
if [ -n "$T3_LIST" ]; then
  say ""
  say "  T3 — shared surface, never re-gated:"
  [ "$QUIET" -eq 1 ] || printf '%s' "$T3_LIST"
fi
if [ "$HIGHEST" -lt 3 ] && [ "$N_COMMITS" -gt 0 ]; then
  say "  Nothing above T2 — no gate is mandated for this work."
fi

# ---------------------------------------------------------------- is it wired up?
#
# Every enforcement point 05-enforcement.md names, checked rather than assumed.
# A pipeline that "fails to run" is most often one that was never actually
# installed, and nothing before this reported that at all.
# ---------------------------------------------------------------- starved gates
#
# A gate whose declared input does not exist does not refuse to run — it infers
# the input and reviews against the inference, and every downstream gate then
# verifies against that same invention. Nothing else in the kit can see this:
# the ledger records that a gate ran and passed, which is true, and says
# nothing about what it was comparing against.
#
# Each card names what it must never invent in its own `must_ask:` field. This
# check is the mechanical half — a BOUNDED set of project inputs whose absence
# is detectable from files alone. It is deliberately not derived from the cards'
# `input:` lines, which are prose ("the diff · registry entries whose triggers
# matched · project/map.md") and would need guessing to turn into paths; a check
# that silently mis-parses its own criteria is the failure mode this whole
# command exists to remove. Bounded and honest beats broad and unreliable — and
# what it does not cover, `must_ask` and `ledger.sh assume` do.
STARVED=""
_starve() { STARVED="${STARVED}    $1
"; }

if grep -q 'EXAMPLE from a browser-extension project' "$CONF" 2>/dev/null; then
  _starve "G7 Threat   — surfaces.conf is still the shipped example, so the trust"
  _starve "              boundaries it would review are somebody else's."
fi
if ! grep -q '^TARGET::' "$CONF" 2>/dev/null; then
  _starve "G5 Proof    — no TARGET rows in surfaces.conf, so \"every target has"
  _starve "              evidence\" is satisfied by evidence for no targets."
fi
# Counting ENTRIES, not prose that mentions entries.
#
# The first version tested for the phrase "If you touch", which is how an entry
# reads — and is also, verbatim, the header of the table the shipped template
# ships with ("| If you touch… | You must also check… | Because |"). Against a
# real project that had copied the template and filled in nothing, the header
# matched, the registry looked populated, and G4 was never reported as starved.
# A check that cannot fire is worse than none, and this one could not fire on
# the only file it was ever going to be pointed at. The tests missed it because
# their fixtures were hand-written prose rather than the real template; the test
# beside this one now uses the shipped file itself.
#
# So: count table rows that have actual content in the first cell, ignoring the
# header, the `|---|` separator, and the empty `| | | |` placeholder. Prose
# outside a table is not an entry either — the template's own instructions are
# full of the phrase.
_reg="$DATA/project/registry.md"
_reg_entries=0
if [ -f "$_reg" ]; then
  _reg_entries="$(awk '
    { line[NR] = $0 }
    function is_sep(s) { return s ~ /^[[:space:]]*\|[[:space:]]*:?-+/ }
    END {
      for (i = 1; i <= NR; i++) {
        s = line[i]
        if (s !~ /^[[:space:]]*\|/) {
          # An entry written as prose rather than a table row. The template
          # states the shape in a blockquote ("> **If you touch X...**"), so a
          # blockquote is instructions, not content.
          if (s ~ /If you touch/ && s !~ /^[[:space:]]*>/) n++
          continue
        }
        if (is_sep(s)) continue                        # |---|---| rule
        if (i < NR && is_sep(line[i+1])) continue      # a HEADER: the row above a rule.
                                                       # Detected structurally rather than by
                                                       # matching its wording, because the
                                                       # template ships two tables with
                                                       # different headers and the first
                                                       # version only knew about one of them.
        t = s; gsub(/[|[:space:]]/, "", t)
        if (t == "") continue                          # the empty "| | | |" placeholder
        n++
      }
      print n + 0
    }' "$_reg" 2>/dev/null)"
  _reg_entries="${_reg_entries:-0}"
fi
if [ "$_reg_entries" -eq 0 ]; then
  _starve "G4 Ripple   — project/registry.md holds no couplings, so \"every triggered"
  _starve "              entry checked\" is true with nothing triggered."
fi

if [ -n "$STARVED" ]; then
  say ""
  say "  GATES THAT WOULD INVENT THEIR INPUT"
  say "  ----------------------------------"
  [ "$QUIET" -eq 1 ] || printf '%s' "$STARVED"
  say "  These pass without lying — they just have nothing to check against."
  say "  Fill the input, or log what you assumed instead:"
  say "    bash $KIT/tools/ledger.sh assume --change <name> --assumed '<what>' --resolution defaulted"
  say "  (a 'defaulted' assumption is accepted at T0-T2 only; compliance refuses it at T3/T4 --"
  say "   there, ask or verify, with --basis, instead.)"
fi

# ---------------------------------------------------------------- stale curated input
#
# G4 Ripple reads project/registry.md and project/map.md. A file full of true couplings from two hundred commits ago
# still passes every check above, and is quietly wrong about the code as it is now. The mined draft is worse off: it
# is a snapshot. Age is measured in COMMITS since the file last changed (or, for the draft, since the commit it was
# mined at), not in days: a quiet repository does not make a registry stale, and a busy one does in a week. Read-only
# and advisory, like the blocks around it: it never changes the exit code.
#   REGISTRY_STALE_COMMITS=<n>   how many commits behind before it says so (default 100; 0 turns the check off)
_stale_n="${REGISTRY_STALE_COMMITS:-100}"
case "$_stale_n" in ''|*[!0-9]*) _stale_n=100;; esac
STALE_INPUT=""
_commits_since() { # <rev>  -> number of commits in <rev>..HEAD, or nothing
  [ -n "$1" ] && git -C "$KIT" rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1 || return 0
  git -C "$KIT" rev-list --count "$1..HEAD" 2>/dev/null
}
_stale_file() { # <file> <label>: tracked files only (an untracked file has no history to age)
  local f="$1" label="$2" last n
  [ -f "$f" ] || return 0
  git -C "$KIT" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || return 0
  last="$(git -C "$KIT" log -1 --format=%H -- "$f" 2>/dev/null)"
  n="$(_commits_since "$last")"
  [ -n "$n" ] && [ "$n" -ge "$_stale_n" ] \
    && STALE_INPUT="${STALE_INPUT}    $label: last changed $n commit(s) ago ($(printf '%.8s' "$last"))
"
  return 0
}
if [ "$_stale_n" -gt 0 ]; then
  [ "$_reg_entries" -gt 0 ] && _stale_file "$DATA/project/registry.md" "project/registry.md"
  _stale_file "$DATA/project/map.md" "project/map.md"
  # The mined draft carries the commit it was mined at ("... at commit <sha> ..."), and is rarely committed.
  _draft="$DATA/project/registry-draft.md"
  if [ -f "$_draft" ]; then
    _dsha="$(sed -n 's/^> Generated .* at commit \([0-9a-f]\{7,40\}\) from .*/\1/p' "$_draft" | head -n 1)"
    _dn="$(_commits_since "$_dsha")"
    [ -n "$_dn" ] && [ "$_dn" -ge "$_stale_n" ] \
      && STALE_INPUT="${STALE_INPUT}    project/registry-draft.md: mined $_dn commit(s) ago ($_dsha)
"
  fi
fi
if [ -n "$STALE_INPUT" ]; then
  say ""
  say "  STALE INPUT (advisory)"
  say "  ----------------------"
  [ "$QUIET" -eq 1 ] || printf '%s' "$STALE_INPUT"
  say "  G4 Ripple reads these. Re-read them against what changed since, then COMMIT them (or re-mine:"
  say "    bash $KIT/tools/mine-registry.sh). Threshold: REGISTRY_STALE_COMMITS=$_stale_n commits (0 = off)."
fi

# ---------------------------------------------------------------- governance staleness
#
# project/govern.md already schedules a cadence for exactly this kind of
# review (risk review, registry curation, etc.) — but nothing before this
# checked whether the dates in project/risks.md were actually being honored,
# or whether a cadence row even has an owner. Read-only, same as the STARVED
# block above: this reports, it never changes the exit code, which stays
# status.sh's existing "unrouted T3/T4 work" contract (see the file header).
GOVERN_STALE=""
_gstale() { GOVERN_STALE="${GOVERN_STALE}    $1
"; }

_risks="$DATA/project/risks.md"
if [ -f "$_risks" ]; then
  # String-compared against today's date, not `date -d` — GNU-only, and would
  # break the declared BSD/macOS TARGET the same way it would everywhere else
  # in this kit (R-003). YYYY-MM-DD sorts correctly as a plain string.
  _today="$(date -u +%Y-%m-%d 2>/dev/null)"
  if [ -n "$_today" ]; then
    # Anchored from each END of the row, not split into numbered fields: an
    # ID never contains "|", and "Review by" is the table's LAST column, so
    # neither match depends on how many "|"-separated cells sit between them
    # — safe even if a risk's own prose someday contains a literal pipe.
    while IFS= read -r _row; do
      [ -n "$_row" ] || continue
      _id="$(printf '%s' "$_row" | sed -n 's/^| *\(R-[0-9]\{3\}\) *|.*/\1/p')"
      _due="$(printf '%s' "$_row" | sed -n 's/.*| *\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\) *|[[:space:]]*$/\1/p')"
      if [ -n "$_id" ] && [ -n "$_due" ] && [ "$_due" \< "$_today" ]; then
        _gstale "project/risks.md: $_id review was due $_due"
      fi
    done <<EOF
$(grep -E '^\| *R-[0-9]+ *\|' "$_risks" 2>/dev/null)
EOF
  fi
fi

_govern="$DATA/project/govern.md"
if [ -f "$_govern" ]; then
  # Same header/separator detection as the registry.md count above: a row is
  # a header only if the NEXT line is a "|---|" separator rule.
  _blank_owners="$(awk '
    /^## Cadence/ { in_sec = 1; next }
    /^## / && in_sec { in_sec = 0 }
    in_sec { line[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        s = line[i]
        if (s !~ /^[ \t]*\|/) continue
        if (s ~ /^[ \t]*\|[ \t]*:?-+/) continue                      # |---|---| rule
        if (i < n && line[i+1] ~ /^[ \t]*\|[ \t]*:?-+/) continue    # header row
        nf = split(s, f, "|")
        if (nf < 4) continue
        what = f[2]; owner = f[4]
        gsub(/^[ \t]+|[ \t]+$/, "", what)
        gsub(/^[ \t]+|[ \t]+$/, "", owner)
        if (what != "" && owner == "") print what
      }
    }' "$_govern" 2>/dev/null)"
  if [ -n "$_blank_owners" ]; then
    while IFS= read -r _item; do
      [ -n "$_item" ] || continue
      _gstale "project/govern.md: \"$_item\" cadence row has no Owner"
    done <<EOF
$_blank_owners
EOF
  fi
fi

if [ -n "$GOVERN_STALE" ]; then
  say ""
  say "  GOVERNANCE STALE"
  say "  ----------------"
  [ "$QUIET" -eq 1 ] || printf '%s' "$GOVERN_STALE"
  say "  project/govern.md schedules these; nothing else checks the dates got kept."
fi

# Which build of the kit is this?
#
# A vendored kit is a copy, and until `tools/update-kit.sh` existed nothing said
# how to refresh one — so an install could sit years behind, carrying bugs fixed
# upstream, with no way to tell from inside. This cannot know what the newest
# release is (no network, by design), but it can state exactly what you are
# running so the answer is comparable against a CHANGELOG. Same fingerprint the
# ledger stamps on every gate record: version, plus a checksum of the shell that
# does the work, so a locally-edited tool shows a different hash at the same
# version.
_kit_v=""
[ -f "$KIT/VERSION" ] && _kit_v="$(tr -d ' \t\r\n' < "$KIT/VERSION" 2>/dev/null)"
[ -n "$_kit_v" ] || _kit_v="unknown"
_kit_h="$(cat "$KIT"/tools/*.sh "$KIT"/tools/lib/*.sh 2>/dev/null | cksum 2>/dev/null | awk '{printf "%08x", $1}')"
say ""
say "  KIT         $_kit_v+${_kit_h:-nohash}"
say "              Refresh a vendored copy: bash $KIT/tools/update-kit.sh <newer-kit>"

say ""
say "  ENFORCEMENT"
say "  -----------"

HOOKS_DIR="$(git rev-parse --git-path hooks 2>/dev/null)"
if [ -f "$HOOKS_DIR/pre-push" ]; then
  # Installed, but is it the CURRENT hook?
  #
  # The installed hook is a copy taken at install time, so every later fix to
  # templates/pre-push reaches nobody who already ran the installer. On this
  # kit's own repo that had already happened: the installed copy was 102 lines
  # against a 204-line template, missing an entire feature — while this line
  # printed a green tick, and install-hook.sh refused to replace it ("someone
  # put it there on purpose"). Presence was being reported as currency, which
  # is the same class of wrong answer as a hook whose regex matches nothing:
  # it looks installed. Found by a fresh-context review, not from inside.
  #
  # Compared with the PIPELINE_DIR line blanked on both sides, because
  # install-hook.sh rewrites exactly that line per install (tools/install-hook.sh)
  # — so a byte comparison would call every correctly-installed vendored copy
  # stale, and a check that cries wolf gets ignored as fast as one that never
  # fires.
  # A byte difference from the template has two very different causes this
  # check cannot distinguish: a stale copy left behind by an earlier kit
  # version, or a hook someone deliberately hand-edited (install-hook.sh
  # itself refuses to overwrite one of those, in those words: "someone put
  # it there on purpose"). Calling it "OUT OF DATE" asserted the first cause
  # as fact and led straight into `--force`, which is exactly the command
  # that destroys the second case. Named as a finding, not fixed silently:
  # the parenthetical below already hedged this while the headline still
  # didn't, which is its own kind of wrong answer.
  _hook_norm='s|^PIPELINE_DIR=.*|PIPELINE_DIR=|;s|^PIPELINE_DATA=.*|PIPELINE_DATA=|'
  if [ -f "$KIT/templates/pre-push" ] \
     && ! diff -q <(sed "$_hook_norm" "$HOOKS_DIR/pre-push") \
                  <(sed "$_hook_norm" "$KIT/templates/pre-push") >/dev/null 2>&1; then
    say "  [!] pre-push hook installed but DIFFERS from templates/pre-push"
    say "      Could be a stale copy from an older kit version, or a hook you"
    say "      deliberately customized -- this check cannot tell which. Diff it first:"
    say "        diff $HOOKS_DIR/pre-push $KIT/templates/pre-push"
    say "      Only if it should match the template:"
    say "        bash $KIT/tools/install-hook.sh --force"
  else
    say "  [x] pre-push hook installed"
  fi
else
  say "  [ ] pre-push hook NOT installed   → bash $KIT/tools/install-hook.sh"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if grep -qs "r0c-post-edit" "$REPO_ROOT/.claude/settings.json" 2>/dev/null; then
  say "  [x] R0c re-entry hook installed (Claude Code)"
else
  say "  [ ] R0c re-entry hook NOT installed → bash $KIT/tools/install-claude-hook.sh"
fi
if grep -qs "stop-compliance" "$REPO_ROOT/.claude/settings.json" 2>/dev/null; then
  say "  [x] Stop hook installed (Claude Code): a T3/T4 change that fails compliance blocks the session end"
else
  say "  [ ] Stop hook NOT installed → bash $KIT/tools/install-claude-hook.sh"
fi

if [ -f "$DASHBOARD" ]; then
  if [ -f "$LEDGER" ] && [ "$LEDGER" -nt "$DASHBOARD" ]; then
    say "  [~] dashboard.html is older than the ledger → bash $KIT/tools/dashboard.sh"
  else
    say "  [x] dashboard.html present"
  fi
else
  say "  [ ] dashboard.html NOT generated  → bash $KIT/tools/dashboard.sh"
fi

if grep -q 'EXAMPLE from a browser-extension project' "$CONF" 2>/dev/null; then
  say "  [!] surfaces.conf is still the shipped EXAMPLE — every tier above is"
  say "      somebody else's trust boundaries, not yours."
fi

# An install that carried the KIT's own records in with it.
#
# The README's step 1 is `cp -r gated-change/ your-project/.pipeline/`, which
# copies everything — including this kit's own ledger.jsonl, its
# security-reports/, and its SELF-marked project/ config. A fresh adopter's very
# first `status.sh` then reported the KIT's newest gate run as their own project's
# LAST GATE, and their "Start the ledger" step was a no-op on a file with a
# hundred entries already in it. Found by a fresh-context Dogfood run that simply
# followed the README top to bottom, which is the only way it could have been
# found — everyone who already knew the kit had a working install.
#
# The SELF marker is the one reliable signal: reconcile.sh already refuses to run
# against it (STOP, "not yours"). status.sh is a report rather than a gate, so it
# says so loudly instead of exiting — but it says it about the WHOLE install,
# because if that file came along then so did everything beside it.
# "Is this an installed copy?" cannot rely on --show-prefix alone. A plain
# `cp -r gated-change/ .pipeline/` also copies the kit's .git, which makes
# .pipeline its OWN repository — so show-prefix comes back empty, the kit looks
# like the repo root, and this guard (and reconcile.sh's identical one) silently
# switches itself off in exactly the botched install it exists to catch.
# Comparing toplevels catches both shapes: a vendored copy inside your repo, and
# a copy that brought its own .git along.
_kit_prefix="$(git -C "$KIT" rev-parse --show-prefix 2>/dev/null)"
_kit_top="$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null)"
_repo_top="$(git rev-parse --show-toplevel 2>/dev/null)"
# "Inside this project's tree", not "a different git repo" — running the kit's
# tools against some other checkout is legitimate, and treating that as a broken
# install fires the warning on every such run. Both toplevels come from git, so
# they share a path form and the prefix test is safe.
_is_installed=0
[ -n "$_kit_prefix" ] && _is_installed=1
if [ -n "$_kit_top" ] && [ -n "$_repo_top" ]; then
  case "$_kit_top" in
    "$_repo_top"/*) _is_installed=1 ;;      # vendored under the project, with its own .git
  esac
fi
if [ "$_is_installed" -eq 1 ] && grep -q '^# SELF: gated-change$' "$CONF" 2>/dev/null; then
  say ""
  say "  [!] THIS INSTALL IS CARRYING THE KIT'S OWN RECORDS, NOT YOURS."
  say "      project/surfaces.conf is marked 'SELF: gated-change', which means the copy"
  say "      brought the kit's config — and with it, its ledger and security reports."
  say "      Every number above may be describing the kit's history, not your project's."
  say ""
  say "      Start clean:"
  say "        cp $KIT/templates/project/surfaces.conf $DATA/project/surfaces.conf"
  say "        rm -f $DATA/ledger.jsonl $DATA/dashboard.html"
  say "        rm -rf $DATA/security-reports"
  say "      then answer the five questions in surfaces.conf."
fi

say ""
if [ "$HIGHEST" -ge 3 ]; then
  say "  → Work above T2 has landed with no gate run since. Route it:"
  say "      bash $KIT/tools/reconcile.sh <predicted-tier> --log"
  say ""
  exit 1
fi
exit 0
