#!/usr/bin/env bash
#
# reconcile.sh — R0b. Recompute the tier from the diff that actually happened.
#
# You classify a change when you know least about it, and the error is always
# biased toward under-classification: you plan a one-line fix and the
# implementation reaches into a shared module. This is the mechanical check
# that catches it before release.
#
# Usage:
#   bash reconcile.sh [predicted-tier] [--log] [--ledger <path>] [--allow-empty]
#                      [--round <n>] [--restart-lineage]   # or ROUND=<n> / RESTART_LINEAGE=1
#                      [--action NAME --evidence "<citation>"]
#                                           # e.g. reconcile.sh T1 --log
#
#   --allow-empty   treat "no changes against BASE" as exit 0 rather than exit 2.
#                   For wrappers that run reconcile on every commit including
#                   no-op ones. Off by default: an empty diff is normally a
#                   wrong base, and a wrong base produces a confident wrong tier.
#
#   --action NAME --evidence "<citation>"
#                   Declare that a no-diff event happened — pressing Publish, a
#                   permission-warning delta, ramping a staged rollout, rotating
#                   a signing key. Every path-based row in $CONF matches
#                   `git diff --name-only`; these events change no file, so no
#                   TIER::REGEX::LABEL row can ever see them (LEARNINGS.md, "The
#                   router can only tier a diff"). NAME must match an
#                   ACTION::TIER::NAME::EVIDENCE row in $CONF. Both flags are
#                   required together — an action with no citation is exactly
#                   the unmeasured claim core/04-ledger.md's evidence rule
#                   refuses everywhere else, and a citation naming no action is
#                   evidence of nothing. Composes with a normal diff-based
#                   reconcile in the SAME invocation (a release commonly has
#                   both a version-bump diff and a publish action) — ACTUAL
#                   becomes the higher of what the diff hit and what the action
#                   declares, same as any other surface hit. With no
#                   [predicted-tier], the predicted tier defaults to whatever
#                   the action resolves to: there is nothing to *guess* about a
#                   fact you are declaring, only a citation to record. See
#                   01-router.md's R0d for the full design rationale.
#
# Env:
#   BASE=<ref>    compare against this
#                 (default: origin/HEAD, then origin/main, origin/master,
#                  main, master, then HEAD~1 — which warns, because the
#                  previous commit is not the branch point)
#   CONF=<path>   surfaces file         (default: project/surfaces.conf)
#   CHANGE=<name> the change this reconciles, recorded with --log and used by
#                 the compliance hint at the end. Route and gate records
#                 correlate ONLY by sharing this name. Default: the --action
#                 name for an --action run; otherwise the current branch —
#                 and ledger.sh REFUSES a trunk branch name (master/main/…),
#                 because a route record named for a permanent branch collects
#                 reconciles from many changes and gets gates for none (P1-5).
#                 On a trunk branch, always set this.
#   ROUND=<n>     review round, recorded with --log (default: 1). A change that
#                 fails a gate and comes back reconciles again — same change,
#                 different commit, and only this tells the two apart.
#   REASON=<text> why this change exists (e.g. "Bug fix", "Feature"), recorded
#                 with --log. Optional — omitted means not recorded, not "unknown."
#
# Exit codes:
#   0  reconciled — actual <= predicted
#   1  UNDER-CLASSIFIED — run the gates you skipped
#   2  usage or environment error, INCLUDING an empty diff. "Nothing to
#      compare" is not a pass: it is almost always a base that resolved to the
#      wrong ref, and a caller that treats it as 0 ships on a reconciliation
#      that never ran. Also 2: BASE shares no history with HEAD ("Cannot compare against ...").
#
set -uo pipefail

# Resolve the surfaces file against the KIT, not the caller's cwd. The documented
# install puts the kit in .pipeline/ and invokes it from the project root
# (`bash .pipeline/tools/reconcile.sh T4`) — a cwd-relative default of
# "project/surfaces.conf" resolves to <project>/project/surfaces.conf, which does
# not exist, so R0b died with "No surfaces file" for every install that followed
# the README. It only ever worked when run from the kit's own root, which is the
# only way this repo dogfooded it. Mirrors dashboard.sh's KIT resolution.
_HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$(dirname "$_HERE")}"
. "$_HERE/lib/data-root.sh"
data_root_require reconcile.sh
CONF="${CONF:-${PIPELINE_DATA:-$KIT}/project/surfaces.conf}"

# Which gates a tier requires is the router's fact, not this script's.
. "$_HERE/lib/matrix.sh"
LOG=0
ALLOW_EMPTY=0
RESTART_LINEAGE_ARG=0
LEDGER_PATH="${LEDGER:-}"
# Whether CHANGE was given, or will fall back below. The fallback to the branch
# name is how a route record ends up named "master" (P1-5); the default is
# resolved AFTER flag parsing so an --action run can fall back to the action
# name (a meaningful identifier) rather than the branch.
[ -n "${CHANGE+x}" ] && CHANGE_SET=1 || CHANGE_SET=""
ACTION_NAME=""
EVIDENCE=""

# Pull the flags out before reading the positional tier, so `--ledger <path>`
# and `--log` work in any order and `reconcile.sh --log T3` does not read
# "--log" as the predicted tier. Silently accepting --ledger and then writing
# to the default path is the same footgun ledger.sh's own header warns about.
_rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --log)         LOG=1; shift;;
    --ledger|--action|--evidence|--round)
                   # A missing value, or the next flag standing where the value belongs
                   # (`--round --log`): either way nothing would be recorded as the user meant.
                   case "${2-}" in
                     '') echo "REFUSED: $1 needs a value (got nothing). Nothing was reconciled." >&2; exit 2;;
                     *[!a-z-]*) ;;
                     --[a-z]*) echo "REFUSED: $1 needs a value (got the option '${2-}'). Nothing was reconciled." >&2; exit 2;;
                   esac
                   case "$1" in
                     --ledger)   LEDGER_PATH="$2";;
                     --action)   ACTION_NAME="$2";;
                     --evidence) EVIDENCE="$2";;
                     --round)    ROUND="$2";;
                   esac
                   shift 2;;
    --allow-empty) ALLOW_EMPTY=1; shift;;
    --restart-lineage) RESTART_LINEAGE_ARG=1; shift;;
    -*)            echo "REFUSED: unknown option '$1'. Nothing was reconciled." >&2
                   echo "  Options: --log --ledger <path> --allow-empty --restart-lineage --action <name> --evidence <text> --round <n>" >&2
                   exit 2;;
    *)             _rest+=("$1"); shift;;
  esac
done
PREDICTED="${_rest[0]:-}"

# Resolve the change name now that --action is known. An --action run identifies
# a declared event by its action, so the action name is the right default there;
# everything else falls back to the branch (which ledger.sh refuses for a trunk
# name — P1-5 — surfaced on --log below).
if [ -z "$CHANGE_SET" ]; then
  if [ -n "$ACTION_NAME" ]; then CHANGE="$ACTION_NAME"
  else CHANGE="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"; fi
else
  CHANGE="${CHANGE:-unknown}"
fi

# A predicted tier that is not T0..T4 (or empty) is not a lower tier, it is a
# typo — but tier_num() maps anything unrecognized to 0 (same as a real,
# deliberate "T0" — nothing mandatory), so "T4 " with a trailing space, "t4",
# or a bare "4" would silently compare as T0 against a real actual tier below.
# When actual also happens to be T0 that reads as "Reconciled — routing
# matches" for a prediction that was never validated at all: a confident wrong
# answer, the exact failure class this file's own history (LEARNINGS.md) warns
# about repeatedly. Checked here, before any git or file work, same
# usage-error treatment as the --action/--evidence pairing below.
case "$PREDICTED" in
  ''|T0|T1|T2|T3|T4) ;;
  *)
    echo "REFUSED: predicted tier '$PREDICTED' is not one of T0..T4 (or empty)." >&2
    echo "  Tiers are case-sensitive and must be exactly T0..T4 — usage:" >&2
    echo "  bash reconcile.sh T2   [--log] [--ledger <path>] [--allow-empty]" >&2
    exit 2;;
esac

# Paired presence, checked before any git or file work — a usage error should
# fail before the tool spends time building a diff it will refuse to use.
# core/04-ledger.md's whole design is "a claim needs a citation": half of this
# pair is exactly the shape it exists to refuse. An action with no evidence is
# an assertion; evidence with no action names is evidence of nothing.
if [ -n "$ACTION_NAME" ] && [ -z "$EVIDENCE" ]; then
  echo "REFUSED: --action '$ACTION_NAME' with no --evidence. Nothing was reconciled." >&2
  echo "  bash reconcile.sh --action $ACTION_NAME --evidence \"<citation>\"" >&2
  exit 2
fi
if [ -z "$ACTION_NAME" ] && [ -n "$EVIDENCE" ]; then
  echo "REFUSED: --evidence given with no --action. Evidence of what?" >&2
  exit 2
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }

if [ ! -f "$CONF" ]; then
  echo "No surfaces file at $CONF" >&2
  echo "Copy project/surfaces.conf and fill in your own surfaces first." >&2
  exit 2
fi

# The shipped surfaces.conf is a browser-extension EXAMPLE with bare-keyword
# rules like "session" and "limit" — these match any path whose NAME merely
# contains the word (e.g. a docs file named "*-sessions.md"), regardless of
# what the file does. Three identical mechanical misfires against this exact
# unmodified example, on one diff, is what surfaced this (LEARNINGS.md). Warn
# loudly every run rather than waiting for the reconcile-miss-rate metric to
# accumulate enough history to notice.
if grep -q 'EXAMPLE from a browser-extension project' "$CONF" 2>/dev/null; then
  echo "WARNING: $CONF still has the shipped example surfaces, unmodified." >&2
  echo "  These are somebody else's trust boundaries. The tier below is not" >&2
  echo "  trustworthy until you replace this file with your own project's surfaces." >&2
  echo >&2
fi

# Parse "ACTION::TIER::NAME::EVIDENCE" into _a_tier/_a_name/_a_evidence
# (_a_rest2 exposed too — the shape check below needs it). One place, not
# three: this exact split used to be copied at every site that reads an
# ACTION row (the shape validator, the by-NAME lookup, the "what IS declared"
# loop in the unknown-NAME refusal), which is the rule-of-three DRY threshold
# a fresh-context review named directly. This only EXTRACTS — it does not
# validate, so it is safe to call before the shape check has run.
_action_parse() {
  local _line=$1
  _line=${_line#ACTION::}
  _a_tier=${_line%%::*}
  _a_rest2=${_line#*::}
  _a_name=${_a_rest2%%::*}
  _a_evidence=${_a_rest2#*::}
}

# Validate every ACTION row's SHAPE on every run — not only when --action is
# passed. A malformed row that silently vanished here would surface later as
# "NAME not found" (reads like a typo in the invocation, not a broken config
# file) or, worse, get misparsed as something else entirely. That is the exact
# failure class a fresh-context review of this branch's own tools/lib/matrix.sh
# found (security-reports/2026-08-13-first-push-matrix-hook-review.md, Finding
# 1: a truncated gate row silently dropped a HARD GATE from the required set,
# with exit 0, no warning anywhere in the tool chain). Refusing here is cheap —
# one pass over a short file — and it is what stops that shape of bug from
# having a second home in this file's own new row kind.
ACTION_ROWS_MALFORMED=0
_action_names_seen=""
while IFS= read -r _aline; do
  case "$_aline" in ACTION::*) ;; *) continue;; esac
  _action_parse "$_aline"
  # No third "::" at all means $_a_rest2 never changed — a 2-field ACTION row
  # (ACTION::T4::name, nothing after) is malformed, not merely undocumented.
  # EVIDENCE empty is the same shape of gap: a fresh-context review caught
  # that the ORIGINAL version of this check validated TIER and NAME but not
  # EVIDENCE, so "ACTION::T4::name::" (trailing empty field) silently printed
  # a blank evidence-description instead of refusing — the exact "silent
  # misparse instead of loud refusal" class this whole block exists to close.
  # A NAME containing a literal "::" is the other gap the same review found:
  # EVIDENCE is the deliberately GREEDY field (same convention as ledger.sh's
  # finding claim — "::" inside it must survive intact, e.g. a URL fragment
  # or a citation with punctuation), so a 5th field is not absorbed into NAME,
  # it is absorbed into EVIDENCE — `case "$_a_evidence" in *::*)` below detects
  # that case and refuses rather than silently reinterpreting which field the
  # config author meant which text to land in.
  if [ "$_a_rest2" = "$_a_evidence" ] || [ -z "$_a_tier" ] || [ -z "$_a_name" ] \
     || [ -z "$_a_evidence" ]; then
    echo "MALFORMED ACTION row in $CONF: '$_aline'" >&2
    echo "  expected ACTION::TIER::NAME::EVIDENCE — 4 non-empty fields." >&2
    ACTION_ROWS_MALFORMED=1
    continue
  fi
  case "$_a_evidence" in
    *::*)
      echo "MALFORMED ACTION row in $CONF: '$_aline'" >&2
      echo "  NAME '$_a_name' would absorb a stray '::' meant for EVIDENCE (or vice" >&2
      echo "  versa) — this row has more than the 4 fields ACTION::TIER::NAME::EVIDENCE" >&2
      echo "  expects. If EVIDENCE genuinely needs a literal '::', say so in the" >&2
      echo "  citation text some other way (a single ':' reads the same to a human)." >&2
      ACTION_ROWS_MALFORMED=1
      continue;;
  esac
  case "$_a_tier" in
    T1|T2|T3|T4) ;;
    *) echo "MALFORMED ACTION row in $CONF: '$_aline'" >&2
       echo "  TIER '$_a_tier' is not one of T1..T4." >&2
       ACTION_ROWS_MALFORMED=1; continue;;
  esac
  # Duplicate NAMEs are not two different facts — they are one NAME with two
  # conflicting answers for its tier/evidence-shape, and the lookup below has
  # to pick one. A fresh-context review found it silently picked "whichever
  # comes first in the file", so a corrected row appended later (the natural
  # way to fix a mistake in this file) would be silently ignored forever.
  # Refusing here is louder and safer than guessing "last one wins" instead.
  case " $_action_names_seen " in
    *" $_a_name "*)
      echo "MALFORMED ACTION row in $CONF: '$_aline'" >&2
      echo "  NAME '$_a_name' is declared more than once. Which one governs is not" >&2
      echo "  a guess this tool will make — rename one, or delete the stale row." >&2
      ACTION_ROWS_MALFORMED=1;;
    *) _action_names_seen="${_action_names_seen}${_a_name} ";;
  esac
done < "$CONF"
if [ "$ACTION_ROWS_MALFORMED" -eq 1 ]; then
  echo >&2
  echo "Refusing to run with a malformed ACTION row in $CONF — see above." >&2
  echo "  Silently ignoring it would be indistinguishable from a NAME that" >&2
  echo "  legitimately does not exist, which is a worse failure than refusing." >&2
  exit 2
fi

# Which ACTION row (if any) --action named. Looked up now, once, rather than
# inline where it is used — the shape validation above already proved every
# row in $CONF is well-formed, so this pass only has to find the one match.
ACTION_TIER=""
ACTION_LABEL=""
if [ -n "$ACTION_NAME" ]; then
  while IFS= read -r _aline; do
    case "$_aline" in ACTION::*) ;; *) continue;; esac
    _action_parse "$_aline"
    [ "$_a_name" = "$ACTION_NAME" ] || continue
    ACTION_TIER="$_a_tier"
    ACTION_LABEL="$_a_evidence"
    break
  done < "$CONF"
  if [ -z "$ACTION_TIER" ]; then
    echo "REFUSED: no ACTION row named '$ACTION_NAME' in $CONF." >&2
    echo "  Declared ACTION rows:" >&2
    _any_action=0
    while IFS= read -r _aline; do
      case "$_aline" in ACTION::*) ;; *) continue;; esac
      _action_parse "$_aline"
      echo "    $_a_name" >&2
      _any_action=1
    done < "$CONF"
    [ "$_any_action" -eq 1 ] || echo "    (none declared)" >&2
    exit 2
  fi
fi

# Pick a base that exists.
#
# `origin/HEAD` first, because that is the repository's own answer to "what is
# the default branch" rather than our guess at it. Then the guesses, in
# descending order of how likely they are to be the branch point.
#
# Local `master` was missing from this chain while local `main` was in it, so a
# repo with no remote and the older default name fell all the way through to
# HEAD~1 and reconciled against the previous commit instead of the branch point
# — silently, with a confident tier at the end of it. A wrong base is the one
# input that makes every number below it wrong.
BASE_GUESSED=0
BASE_EXACT=0   # 1: BASE came from the chain below and must exist as EXACTLY that ref (see BASE_DIFF)
# Full ref names, checked with `show-ref --verify`. `rev-parse --verify refs/remotes/origin/main` is NOT an
# exact check: with that ref missing git's name search finds a TAG called `refs/remotes/origin/main` (a plain
# `git fetch` delivers one), and the tag chose the base -- a T4 change tiered T0 (G7 round 28).
_ref_exists() { git show-ref --verify -q "$1" 2>/dev/null; }
if [ -n "${BASE:-}" ]; then
  :
elif _oh=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) \
     && [ -n "$_oh" ]; then BASE="$_oh"; BASE_EXACT=1
elif _ref_exists refs/remotes/origin/main   ; then BASE=refs/remotes/origin/main;   BASE_EXACT=1
elif _ref_exists refs/remotes/origin/master ; then BASE=refs/remotes/origin/master; BASE_EXACT=1
elif _ref_exists refs/heads/main            ; then BASE=refs/heads/main;            BASE_EXACT=1
elif _ref_exists refs/heads/master          ; then BASE=refs/heads/master;          BASE_EXACT=1
else
  BASE=HEAD~1
  BASE_GUESSED=1
fi

# What git is handed. A BASE the operator typed (BASE=<ref> in the environment) is their choice and goes
# through unchanged (R-009 (1)). A BASE this script chose goes as the object id the ref store holds for that
# exact ref, never as a name; a dangling origin/HEAD target leaves it empty, which the diff below refuses
# ("Cannot compare") rather than letting git's name search find something else.
BASE_DIFF="$BASE"
if [ "$BASE_EXACT" -eq 1 ]; then
  BASE_DIFF="$(git show-ref --verify --hash "$BASE" 2>/dev/null || true)"
fi

# What a person reads: the full ref names above exist so a tag cannot shadow them, not to be shown.
BASE_LABEL="${BASE#refs/remotes/}"; BASE_LABEL="${BASE_LABEL#refs/heads/}"

if [ "$BASE_GUESSED" -eq 1 ]; then
  echo "WARNING: no origin/HEAD, main, or master found. Comparing against HEAD~1," >&2
  echo "  which is the previous commit, not the branch point. Everything below is" >&2
  echo "  scoped to that assumption. Set BASE=<ref> if it is wrong." >&2
  echo >&2
fi

# Union of four sources — the committed diff against BASE, staged changes,
# unstaged changes to tracked files, and untracked new files.
#
# An earlier version appended the unstaged source only when the committed one
# was already non-empty, and never looked at untracked files at all — so a
# change with no commits yet (the common case: R0b runs after Build, before a
# commit exists) silently reconciled against nothing.
#
# `--cached` was the one still missing, and it covers the most ordinary state
# there is: work that has been `git add`ed and not yet committed. Staging moves
# a file out of all three other queries at once — it is no longer untracked, it
# no longer differs from the index, and it is not in any commit — so the file
# you most recently decided was ready was the file reconcile could not see.
# Found by tests/run.sh on its first run.
#
# Reconcile is supposed to be mechanical; a false "no changes" is a routing
# failure, not a pass.
#
# core.quotePath=false: git prints a non-ASCII path as "src/auth/na\303\257ve.go", quotes included, and an
# anchored rule never matched it, so a T4 file tiered T0 (G7 round 26). A name still quoted (it holds a
# quote, a backslash or a tab) loses its wrapping quotes below.
#
# The committed diff is the one whose failure used to be swallowed: with no merge base (an orphan branch,
# a shallow clone, a mistyped BASE, an origin/HEAD pointing at a branch that is gone) git prints an error
# and nothing else, and the empty answer read as "no committed changes" -- a routing match.
#
# A GUESSED base (HEAD~1, with the warning above) is exempt from the refusal: a repository with no commit
# has nothing to diff. A repository whose only commit is HEAD has no HEAD~1 either, but that commit IS the
# change: it is diffed against git's empty tree (asked of git: the id differs under sha256).
if [ "$BASE_GUESSED" -eq 1 ] && git rev-parse --verify -q HEAD >/dev/null 2>&1 \
   && ! git rev-parse --verify -q HEAD~1 >/dev/null 2>&1; then
  COMMITTED=$(git -c core.quotePath=false diff --no-renames --name-only "$(git hash-object -t tree /dev/null)" HEAD 2>/dev/null)
elif ! { [ -n "$BASE_DIFF" ] \
         && COMMITTED=$(git -c core.quotePath=false diff --no-renames --name-only "$BASE_DIFF"...HEAD 2>/dev/null); } \
   && [ "$BASE_GUESSED" -eq 0 ]; then
  echo "Cannot compare against $BASE_LABEL: git found no common history with HEAD (an unrelated or orphan" >&2
  echo "  branch, a shallow clone, a mistyped BASE, or a stale origin/HEAD). This is NOT a pass." >&2
  echo "  Set BASE=<ref> to a commit this branch descends from." >&2
  exit 2
fi
STAGED=$(git -c core.quotePath=false diff --no-renames --name-only --cached 2>/dev/null)
UNSTAGED=$(git -c core.quotePath=false diff --no-renames --name-only 2>/dev/null)
# ls-files lists only the current directory's untracked files, relative to it (the diffs above are repo-wide
# and root-relative): from a subdirectory that missed the rest and broke the anchored rules (G4 round 27).
UNTRACKED=$(git -c core.quotePath=false ls-files --others --exclude-standard --full-name -- ":/" 2>/dev/null)
CHANGED=$(printf '%s\n%s\n%s\n%s\n' "$COMMITTED" "$STAGED" "$UNSTAGED" "$UNTRACKED" \
          | sed '/^$/d; s/^"\(.*\)"$/\1/' | sort -u)

# The kit is not the project.
#
# The documented install drops the whole kit into .pipeline/, and the kit's own
# filenames are full of the words a surfaces file is made of: ledger.jsonl and
# 04-ledger.md hit a quota rule, session-record-arm-a.md hits a trust-boundary
# rule, 05-enforcement.md hits an enforcement rule. A fresh install therefore
# reported seventeen T4 surfaces on its first run, none of them the user's code,
# and writing the ledger — the thing you do to record a gate — raised the tier
# of the change you were recording it for.
#
# Located via git rather than string arithmetic on two paths: --show-prefix is
# already relative to the repo root and needs no normalisation, which matters
# because `git rev-parse --show-toplevel` and `pwd` disagree about drive-letter
# form on Windows.
#
# An empty prefix means the kit IS the repository — this repo dogfooding itself
# — and then nothing is excluded, because every file genuinely is the product.
# INCLUDE_KIT=1 forces that same behaviour from an installed copy.
KIT_PREFIX=""
if [ "${INCLUDE_KIT:-0}" != "1" ]; then
  _repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  _kit_root="$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$_kit_root" ] && [ "$_kit_root" = "$_repo_root" ]; then
    KIT_PREFIX="$(git -C "$KIT" rev-parse --show-prefix 2>/dev/null)"
  fi
fi

if [ -n "$KIT_PREFIX" ]; then
  _before=$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')
  # <kit>/project/ (surfaces.conf, the map, the risks) is the project's own and stays in, like coverage.sh.
  CHANGED=$(printf '%s\n' "$CHANGED" | awk -v p="$KIT_PREFIX" 'index($0, p) != 1 || index($0, p "project/") == 1')
  _after=$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')
  _dropped=$((_before - _after))
  # Say so. Silently dropping files from a routing decision is the same class of
  # invisible behaviour this script exists to catch.
  [ "$_dropped" -gt 0 ] && \
    echo "Note: $_dropped file(s) under ${KIT_PREFIX} excluded — the kit itself, not the project. INCLUDE_KIT=1 to include." >&2
fi

# The data directory (PIPELINE_DATA) is excluded the same way: its ledger, dashboard and reports are written by the
# pipeline, and a commit of them used to be tiered as project work (a `ledger` row in the shipped example made it T4).
# Its project/ directory is the project's own and stays in.
_dp=""
[ -z "${PIPELINE_DATA:-}" ] || _dp="$(git -C "$PIPELINE_DATA" rev-parse --show-prefix 2>/dev/null)"
if [ -n "$_dp" ] && [ "${INCLUDE_KIT:-0}" != "1" ]; then
  CHANGED=$(printf '%s\n' "$CHANGED" | awk -v p="$_dp" 'index($0, p) != 1 || index($0, p "project/") == 1')
fi

# Routing your project against the KIT's own surfaces fails open, which is why
# this refuses rather than warns. Nothing of yours matches rules written about
# tools/reconcile.sh and core/cards/, so every change lands at T0, no gate is
# ever mandatory, and the pipeline reports success while doing nothing at all. A
# non-empty KIT_PREFIX means this is an installed copy, so the kit's own file
# cannot be the right one.
#
# KIT_PREFIX ALONE IS NOT ENOUGH, and the gap was the dangerous half of a pair.
# A plain `cp -r gated-change/ .pipeline/` also copies the kit's .git, which
# makes .pipeline its own repository — so `_kit_root` != `_repo_root` above,
# KIT_PREFIX stays empty, and this STOP silently switched itself off in exactly
# the botched install it exists to catch. That install then routes every change
# at T0 with no gate ever mandatory: a pipeline reporting success while doing
# nothing, which this file's own message calls worse than no pipeline at all.
# `status.sh` was fixed for the same shape first; two fresh-context gates
# pointed out that the half left blind was the one that REFUSES rather than the
# one that merely reports. INCLUDE_KIT=1 still overrides, so the kit's own
# self-hosting path is unaffected.
# The test is "does the kit sit INSIDE this project's tree", not "is it a
# different git repo". A first attempt used the latter and was wrong in a way
# the suite caught immediately: running the kit's tools against some other
# checkout is legitimate and common (that is how the tests themselves drive
# reconcile), and it tripped the STOP on every such run. Both toplevels come
# from git, so they are in the same path form and a prefix test is safe here —
# which is what the D:/ vs /d/ mismatch two rounds ago was about.
_self_installed=0
[ -n "$KIT_PREFIX" ] && _self_installed=1
if [ "${INCLUDE_KIT:-0}" != "1" ] && [ -n "$_kit_root" ] && [ -n "$_repo_root" ]; then
  case "$_kit_root" in
    "$_repo_root"/*) _self_installed=1 ;;   # vendored under the project, with its own .git
  esac
fi
if [ "$_self_installed" -eq 1 ] && grep -q '^# SELF: gated-change$' "$CONF" 2>/dev/null; then
  echo "STOP — $CONF is gated-change's own surfaces file, not yours." >&2
  echo >&2
  echo "  Its rules describe the kit's source. None of them match your code, so every" >&2
  echo "  change would reconcile as T0 and no gate would ever be mandatory. That is a" >&2
  echo "  pipeline reporting success while doing nothing, which is worse than no" >&2
  echo "  pipeline at all." >&2
  echo >&2
  _dest="${KIT_PREFIX}project/surfaces.conf"; [ -z "${PIPELINE_DATA:-}" ] || _dest="$PIPELINE_DATA/project/surfaces.conf"
  echo "  cp ${KIT_PREFIX}templates/project/surfaces.conf $_dest" >&2
  echo >&2
  echo "  then answer the five questions in it." >&2
  exit 2
fi

# IGNORE rows: paths that are in the repo but are not yours to review — vendored
# code, generated output, fixtures. Dropped before tiering, so they cannot raise
# a tier and cannot appear in the hit list.
while IFS= read -r _line; do
  case "$_line" in IGNORE::*) ;; *) continue;; esac
  _rest_i=${_line#IGNORE::}
  _regex_i=${_rest_i%::*}
  [ -n "$_regex_i" ] || continue
  CHANGED=$(printf '%s\n' "$CHANGED" | grep -Ev "$_regex_i" 2>/dev/null)
done < "$CONF"

CHANGED=$(printf '%s\n' "$CHANGED" | sed '/^$/d')

# "Nothing to compare" is not "nothing wrong." R0b is the gate that a change may
# not reach Release without, and agent-instructions.md tells an agent to branch
# on this exit code — so returning 0 here hands out a pass for a reconciliation
# that never happened. The usual cause is a base that resolved to the wrong ref,
# which is exactly the failure the caller cannot see.
#
# A declared action is the one legitimate exception: it is its own evidence of
# a reconciliation event, independent of whatever the working tree looks like.
# A pure `--action store-publish` run — publishing an artifact that was built
# and committed days ago, with nothing new in the working tree today — must not
# be refused for the same reason a real empty diff is refused.
if [ -z "$CHANGED" ] && [ -z "$ACTION_NAME" ]; then
  echo "No changes against $BASE_LABEL — nothing to reconcile." >&2
  echo >&2
  echo "  This is NOT a pass. Either BASE resolved to the wrong ref, or you are on" >&2
  echo "  the base branch itself with everything already committed, or everything" >&2
  echo "  that changed was excluded (see the notes above, if any)." >&2
  echo "  Set BASE=<ref>, or pass --allow-empty if an empty diff is expected here." >&2
  [ "$ALLOW_EMPTY" -eq 1 ] && exit 0
  exit 2
fi

# 01-router.md's own stated reason for giving this its own letter (R0d, not
# folded into R0b) is that R0b assumes a diff already exists and R0d does not
# — a fresh-context review found the terminal output undercut that rationale
# by printing "R0b Reconcile" unconditionally, even for a pure --action run
# with zero file changes. Say which step actually ran, since the label is the
# only place a reader sees that distinction land.
if [ -n "$ACTION_NAME" ]; then
  _action_nfiles=$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$_action_nfiles" -gt 0 ]; then
    echo "R0b/R0d Reconcile — $_action_nfiles file(s) vs $BASE_LABEL, plus declared action '$ACTION_NAME'"
  else
    echo "R0d Reconcile · Action — '$ACTION_NAME' declared, no file changes vs $BASE_LABEL"
  fi
else
  echo "R0b Reconcile — $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') file(s) vs $BASE_LABEL"
fi
echo

tier_num() { case "$1" in T4) echo 4;; T3) echo 3;; T2) echo 2;; T1) echo 1;; *) echo 0;; esac; }

ACTUAL_N=0
HITS=""

# One grep per RULE, not per file-and-rule.
#
# This loop used to be nested the other way — for each file, for each rule, spawn
# a grep — which is files × rules processes. A 201-file diff against the 22 rules
# below took 134 seconds on Git Bash, in a step both the README and 00-start.md
# describe as taking "seconds", and process spawn is the whole cost: on Linux the
# same loop is merely wasteful rather than unusable.
#
# Rules are few and fixed; the file list is one string. Inverting gives one grep
# per rule regardless of diff size. The output is unchanged — HITS is sorted and
# de-duplicated before it is printed either way, and tests/run.sh pins that
# against a golden file captured before the change.
while IFS= read -r line; do
  # ACTION:: rows are excluded here explicitly, not by accident of shape.
  # ACTION::T4::store-publish::<evidence-desc> has three "::" (four fields),
  # same as it would need to fall into the `*::*::*` path-rule check just
  # below — its third field is a NAME, not a regex, and grep'ing a NAME like
  # "store-publish" against the file list matches nothing, silently, forever.
  # That is precisely the failure class this file's own history warns about
  # (a confident wrong answer, not a loud refusal) and the shape matrix.sh's
  # Finding 1 already produced once for gate rows — see the ACTION shape
  # validation earlier in this file, which is the loud version of this same
  # guard. ACTION rows are parsed once, above, and looked up by NAME there;
  # they never reach this loop.
  case "$line" in ''|\#*|TARGET::*|IGNORE::*|ACTION::*) continue;; esac
  case "$line" in *::*::*) ;; *) continue;; esac
  # Split on the first and last "::" — regexes contain "|" and ":" freely,
  # so field-splitting on a single character corrupts them.
  tier=${line%%::*}
  rest=${line#*::}
  regex=${rest%::*}
  label=${rest##*::}
  [ -n "$regex" ] || continue

  matched=$(printf '%s\n' "$CHANGED" | grep -E "$regex" 2>/dev/null)
  [ -n "$matched" ] || continue

  n=$(tier_num "$tier")
  [ "$n" -gt "$ACTUAL_N" ] && ACTUAL_N=$n
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    HITS="${HITS}${tier}	${file}	${label}
"
  done <<EOF
$matched
EOF
done < "$CONF"

# Fold the declared action into the same max-of-hits computation path hits
# already use — an action is just another surface, one with no path. This is
# what makes composing an action with a diff-based reconcile in one invocation
# work without a second code path: ACTUAL ends up as the higher of whatever
# the diff hit and whatever the action declared, exactly like two path rules
# hitting the same file already do today.
if [ -n "$ACTION_NAME" ]; then
  _action_n=$(tier_num "$ACTION_TIER")
  [ "$_action_n" -gt "$ACTUAL_N" ] && ACTUAL_N=$_action_n
fi

case "$ACTUAL_N" in 4) ACTUAL=T4;; 3) ACTUAL=T3;; 2) ACTUAL=T2;; 1) ACTUAL=T1;; *) ACTUAL=T0;; esac

if [ -n "$HITS" ]; then
  echo "Surfaces hit"
  echo "------------"
  printf '%s' "$HITS" | sort -u | sort -r | awk -F'\t' '{ printf "  %-3s %-50s %s\n", $1, $2, $3 }'
  echo
fi

if [ -n "$ACTION_NAME" ]; then
  echo "Action declared"
  echo "---------------"
  printf "  %-3s %-20s %s\n" "$ACTION_TIER" "$ACTION_NAME" "$ACTION_LABEL"
  printf "  Evidence: %s\n" "$EVIDENCE"
  echo
fi

echo "Targets to verify (every one needs evidence in the test gate)"
echo "-------------------------------------------------------------"
grep '^TARGET::' "$CONF" | sed 's/^TARGET:://' | awk -F'::' '{ printf "  [ ] %-30s %s\n", $1, $2 }'
echo

# matrix_required/matrix_conditional return empty both when this tier
# genuinely mandates nothing and when the router could not be read at all
# (see lib/matrix.sh's _matrix_load) — the "for _g in $(...)" loops below
# cannot see that distinction, since a for-loop over a command substitution
# discards its exit status. Check it directly first, so a broken router
# cannot read back as "Gates: none mandatory" and "Reconciled — routing
# matches."
if ! _matrix_load; then
  echo "REFUSED: the gate matrix could not be read — see the error above." >&2
  echo "  Reconcile cannot tell 'this tier mandates no gates' from 'the router that" >&2
  echo "  says what is mandated is missing or broken', and reporting the routing as" >&2
  echo "  reconciled on that basis would be the exact confident-wrong-answer this" >&2
  echo "  script exists to prevent. Fix the router, or point MATRIX_ROUTER at a good" >&2
  echo "  copy." >&2
  exit 2
fi

# Derived from core/01-router.md, not restated here. This list used to be a
# hardcoded case statement, and it disagreed with both the router and ledger.sh
# — three copies of one table, which is two more than can be kept true.
GATES=""
for _g in $(matrix_required "$ACTUAL"); do
  _cell="$(matrix_cell "$_g" "$ACTUAL")"
  case "$_cell" in
    *"(hard)"*) GATES="${GATES}${GATES:+, }$(matrix_name "$_g")(HARD GATE)";;
    *) GATES="${GATES}${GATES:+, }$(matrix_name "$_g")$(matrix_marker "$_g" "$ACTUAL")";;
  esac
done
[ -n "$GATES" ] || GATES="none mandatory"

# Recommended-with-a-footnote: not mandatory, but the footnote may make them so.
_COND=""
for _g in $(matrix_conditional "$ACTUAL"); do
  _COND="${_COND}${_COND:+, }$(matrix_name "$_g")$(matrix_marker "$_g" "$ACTUAL")"
done

echo "Actual tier : $ACTUAL"
[ -n "$PREDICTED" ] && echo "Predicted   : $PREDICTED"
echo "Gates       : $GATES"
[ -n "$_COND" ] && echo "Also check  : $_COND  (recommended; the footnote may make it mandatory)"
echo

if [ -z "$PREDICTED" ]; then
  if [ -n "$ACTION_NAME" ]; then
    # There is nothing to GUESS about a declared action — its tier is a fact
    # read out of $CONF, not a prediction someone made before knowing what
    # happened. Setting predicted = actual makes the verdict "match" by
    # construction and lets this fall through to the same --log / exit path
    # every other reconcile takes, instead of a separate code path that could
    # drift from it. What still needs recording is the citation, not a guess.
    PREDICTED="$ACTUAL"
    echo "No predicted tier given for a declared action — using $ACTUAL, the action's own tier."
    echo "There is nothing to guess here: $CONF said $ACTION_TIER before this ran."
    echo
  else
    echo "No predicted tier given — nothing to reconcile against."
    echo "Run:  bash reconcile.sh T2"
    exit 0
  fi
fi

PRED_N=$(tier_num "$PREDICTED")

# Feed the leading indicator. Miss rate is the one metric available on day one,
# and it is free only if reconciliations are actually recorded.
if [ "$LOG" -eq 1 ]; then
  _LEDGER_SH="$(dirname "$0")/ledger.sh"
  [ -x "$_LEDGER_SH" ] || _LEDGER_SH="bash $(dirname "$0")/ledger.sh"
  # Capture combined output rather than discarding it: ledger.sh refuses a
  # --change that is a branch name (P1-5), a bad --round, and more — and
  # "(is tools/ledger.sh present?)" mis-diagnosed every one of those as a
  # missing file. On success this is cmd_route's own "logged: ... -> $LEDGER"
  # line (G6 Peer, this change's own review: reconcile.sh used to discard that
  # stdout entirely, so the destination path this change added never reached
  # anyone driving route through reconcile — the documented normal path,
  # ledger.sh:13-14 — even after ledger.sh started naming it).
  # Where this change started: the commit BASE and HEAD share. Recorded on the route
  # entry so ledger.sh compliance can bind gate records to the change's own commits
  # (E3) without re-deriving it from trunk later -- after a merge that collapses.
  _BASE_SHA=""
  [ -z "$BASE_DIFF" ] || _BASE_SHA="$(git merge-base "$BASE_DIFF" HEAD 2>/dev/null || true)"
  # Only the exact value 1 (flag or RESTART_LINEAGE=1): "0", "false" or a stale exported variable
  # must not restart a lineage.
  _RESTART=""; { [ "${RESTART_LINEAGE_ARG:-0}" = 1 ] || [ "${RESTART_LINEAGE:-}" = 1 ]; } && _RESTART=1
  _route_out=$($_LEDGER_SH route --change "$CHANGE" --predicted "$PREDICTED" --actual "$ACTUAL" \
      --round "${ROUND:-1}" ${_RESTART:+--restart-lineage} ${_BASE_SHA:+--base "$_BASE_SHA"} ${REASON:+--reason "$REASON"} ${LEDGER_PATH:+--ledger "$LEDGER_PATH"} \
      ${ACTION_NAME:+--action "$ACTION_NAME"} ${ACTION_NAME:+--evidence "$EVIDENCE"} 2>&1)
  _route_rc=$?
  if [ "$_route_rc" -eq 0 ]; then
    echo "(logged to ledger)"
    echo "  $_route_out"
    echo
  else
    echo "RECONCILE NOT RECORDED — the ledger write was refused:" >&2
    printf '%s\n' "${_route_out:-  (tools/ledger.sh not found or not runnable)}" | sed 's/^/  /' >&2
    echo >&2
    echo "  The tier was recomputed (predicted $PREDICTED, actual $ACTUAL) but NOT the" >&2
    echo "  verdict, and nothing was recorded. R0b requires a recorded reconciliation" >&2
    echo "  before Release — fix the above and re-run to get the full result." >&2
    if [ -z "${CHANGE_SET:-}" ] && [ -z "$ACTION_NAME" ]; then
      echo "  ('--change' defaulted to the branch name '$CHANGE'; set CHANGE=<name>.)" >&2
    fi
    exit 2
  fi
fi

if [ "$ACTUAL_N" -gt "$PRED_N" ]; then
  echo "UNDER-CLASSIFIED: predicted $PREDICTED, actual $ACTUAL."
  echo "Run the gates $ACTUAL requires before release, and log the miss in the ledger."
  exit 1
elif [ "$ACTUAL_N" -lt "$PRED_N" ]; then
  echo "Over-classified: predicted $PREDICTED, actual $ACTUAL. Safe to proceed."
  echo "Note it — consistent over-classification wastes real time."
  exit 0
else
  # Reconciled is a verdict about ROUTING, not about readiness. An earlier
  # version ended with a flat "Proceed to release." while printing the gate list
  # directly above it — including a HARD GATE — without ever checking whether any
  # of them ran. Read at 2am that is an all-clear, and it is the reason a T4
  # change reached a push with three mandated gates unrun.
  # An action's route is recorded as round 1 on a repeat firing whatever ROUND= said, so naming a
  # round here could point at one that does not exist: compliance defaults to the latest round.
  if [ -n "$ACTION_NAME" ]; then _ROUND_HINT=""; else _ROUND_HINT=" --round ${ROUND:-1}"; fi
  echo "Reconciled — routing matches. This says nothing about whether the"
  echo "gates above ran."
  echo
  echo "  bash $(dirname "$0")/ledger.sh compliance --change \"$CHANGE\" --tier $ACTUAL${_ROUND_HINT}"
  echo
  echo "  is the check that answers that, and it is the one that decides release."
  exit 0
fi
