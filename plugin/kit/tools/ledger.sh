#!/usr/bin/env bash
#
# ledger.sh — record what the pipeline did, and report what it adds up to.
#
# Three record types:
#   gate    a gate ran
#   route   a reconciliation happened (predicted vs actual tier)
#   escape  a defect was found AFTER release, linked to the change that caused it
#
# Usage:
#   ledger.sh add    --change <name> --gate G7 --tier T4 [options]
#   ledger.sh route  --change <name> --predicted T1 --actual T4 [--base <sha>] [--restart-lineage]
#            [--action NAME --evidence '<citation>']   # a declared event, not a diff —
#            reconcile.sh --action passes both through. Paired: one without the
#            other is REFUSED, same shape as a finding's severity/location pair.
#   ledger.sh escape --change <name> --found-by user|self|monitoring [--severity high]
#   ledger.sh assume --change <name> --assumed '<what the requester never said>' \
#            --resolution asked|verified|defaulted [--basis '<why>'] [--round N]
#            The INPUT record. 10-probe.md checkpoint 1 asks "what did they not
#            say that I assumed?" — this is where the answer goes. `defaulted`
#            is legal and logged, and is what `compliance` refuses at T3/T4.
#   ledger.sh report
#   ledger.sh gates
#   ledger.sh compliance --change <name> --tier T4 [--round N]
#            Did the gates this tier MANDATES actually pass? Exits 1 if not.
#            The one check that is not self-graded — "skipped" is not "passed".
#
# Any subcommand also accepts --ledger <path> anywhere in its arguments,
# taking precedence over the LEDGER env var. `LEDGER=path && ledger.sh ...`
# is a common footgun — that assignment does not export, so the script
# silently falls back to the default path and the entry lands somewhere
# other than where you meant it to. `ledger.sh add --ledger path ...` (or
# `LEDGER=path ledger.sh ...`, prefix form, no &&) both actually work.
#
# add options:
#   --outcome pass|fail|skipped|n/a
#   --confidence fresh|low   REQUIRED for pass/fail (an out-of-vocab or missing
#                    value on a verdict is silently uncounted by the dashboard and
#                    every ledger stat). skipped/n-a default it to `low`.
#   --challenged true|false | --minutes N | --lane normal|hotfix | --note "text"
#   --model <name>   which model graded this gate. Models change; results shift.
#                    Recording it is how you tell a process change from a model change.
#                    Defaults to $PIPELINE_MODEL. Left unset it WARNS: core/08-models.md
#                    already says "pick from the table and say which you picked", and a
#                    provenance field that accepts a placeholder in silence enforces
#                    nothing — every line of the first real run said "unset". Each gate
#                    card now carries its expected tier on a `model:` line, so the
#                    answer travels with the card that is handed to the subagent.
#   --tokens N       what the run COST. core/04-ledger.md keeps escape rate as the only
#                    outcome metric — cost is not the goal — but an unmeasured constraint
#                    is how a methodology gets abandoned, and `minutes` is a fiction for
#                    a subagent. This is the budget metric that is actually consumed.
#   --tokens-in N --tokens-out N   the same cost, split by direction. PAIRED — one
#                    without the other is REFUSED (checked on the flag being passed,
#                    not the value being non-empty, so --tokens-in '' is refused as an
#                    invalid value rather than read as omitted). Optional: when --tokens
#                    is not also given, `tokens` is computed as their sum, so every
#                    reader that only ever knew the aggregate field keeps working
#                    unchanged. Input and output are priced differently and a gate's
#                    ratio shifts with what it is asked to do (a large diff handed in
#                    vs. a long report handed back) — an aggregate number hides which
#                    one grew. An explicit --tokens LESS than tokens-in + tokens-out is
#                    REFUSED (the parts can't outweigh the whole); one that is GREATER
#                    is accepted and kept as given — a true billed total may legitimately
#                    exceed the split when it includes cost the split doesn't categorize
#                    (e.g. cache-read/cache-creation tokens, which this kit's own
#                    subagent gates incur every run by re-reading core/). All three of
#                    --tokens/--tokens-in/--tokens-out are capped at 15 digits (~10^15) —
#                    far beyond any real token count, but enough to keep bash's 64-bit
#                    arithmetic on the sum from ever wrapping (G6 Peer / G7 Threat round 2:
#                    an uncapped 20-digit operand wraps mod 2^64 into an arbitrary
#                    in-range-looking value).
#   --withhold-breached true|false   OPTIONAL, TRIAL (core/11-evolution.md Step 7 — review
#                    after 10 firings or 30 days): did the withheld input (the card's own
#                    `withhold:` line) actually reach this gate anyway? core/02-gates.md's
#                    blind review rule is only as real as whoever ran the gate remembering to
#                    honour it — this is a self-reported, honest-signal field for the case
#                    where it slipped, not a control. Omitting it records nothing and warns
#                    nothing, exactly like every other optional field here.
#   --round N        which review round. The failure rule sends a failed gate back to
#                    Build and re-runs it; round is what tells those apart afterwards.
#   --commit <sha>   what was reviewed. Auto-detected from git HEAD when omitted.
#   --finding "severity::location::claim"    repeatable. Structures one finding.
#                    severity : blocking | minor | info | out-of-scope — REFUSED otherwise
#                    location : file:line or the command that proves it (evidence rule).
#                               Required for blocking and minor: core/02-gates.md says a
#                               finding without a citation is DELETED, not softened.
#                    claim    : free text, may itself contain "::".
#                               For `out-of-scope` it must contain `filed:<ref>` — the
#                               rule in core/02-gates.md routes these to a separate
#                               follow-up item, and a rule with no destination loses the
#                               finding. G8 Dogfood produces most of them.
#                    Each finding gets a stable id, <change>-r<round>-<gate>-<n>, computed
#                    here so a later conversation can name one instead of describing it.
#                    It is an identifier, not a state: nothing in this file tracks whether
#                    a finding was fixed, because that record would be written by the
#                    author about their own fix and handed to the next reviewer, which is
#                    the anchoring core/02-gates.md's blind review rule exists to prevent.
#
#                    The number of --finding rows IS the finding count. There is no bare
#                    --findings flag: core/04-ledger.md says a count "cannot be read back,
#                    argued with, or shown to anyone", and a flag the docs argue against
#                    is a flag that should not exist.
#
# Every line also carries `kit`: the version plus a hash of tools/, auto-detected exactly
# the way `commit` is. An installed copy gone stale against the kit source once reported
# gates as SKIPPED that had actually FAILED, and it was caught only because the output
# disagreed with someone's memory. `compliance` now says so out loud instead. It SHOWS
# staleness; it never skips a run on that basis — see the note above cmd_compliance.
#
# `date` is a full UTC instant now (`2026-08-14T17:53:03Z`, `date -u +%Y-%m-%dT%H:%M:%SZ`),
# not just a calendar day. A real user asked for a time, not only a day — "today" covers a
# 24-hour window and that stopped being precise enough. Widened in place rather than added
# as a second field: every consumer here (compliance, report, gates, the dashboard) already
# treats `date` as an opaque, sortable string, never parses its length or splits on `-`, so
# there was nothing to migrate. Every line written before this change stays exactly
# `"YYYY-MM-DD"` forever — core/04-ledger.md's "never backfill" rule means an old entry does
# not get a fabricated time bolted on, it just stays coarser than a new one, honestly. A
# mixed ledger (some lines a bare day, some a full instant) is the permanent, ordinary shape
# of every project's history from here on, not a transitional state. String comparison and
# sort order both still hold across the mix: a full-instant value is a bare-day value with
# more characters appended in the same left-to-right field order, so `>` and `localeCompare`
# keep working unmodified, and same-day entries with a time correctly sort after the bare-day
# ones they extend. tools/dashboard/app.js's friendlyDate() is what renders either shape.
#
set -uo pipefail

# Where this script itself lives, one level above tools/ — used both here (to
# pick the right default ledger) and by detect_kit() below.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

# The installed-copy convention is `.pipeline/ledger.jsonl`, relative to the
# CONSUMING project's root — correct when a project's own git repo is bigger
# than the kit directory it contains. But when the kit IS the repo (self-hosting,
# this repo), that convention resolves to a stray `.pipeline/ledger.jsonl`
# instead of the `ledger.jsonl` the README calls "the evidence" — reconcile.sh
# already tells these two cases apart (`KIT_PREFIX`, `SELF: gated-change`);
# ledger.sh never did, so an add here silently wrote to the wrong file and
# reported success while doing it — the exact failure class this whole file
# exists to prevent, just never pointed at its own default.
#
# `--show-prefix` rather than comparing two `--show-toplevel` paths: empty means
# KIT_ROOT already IS the repo root (self-hosting), non-empty means it is nested
# under something bigger (installed). This never compares a `pwd`-built path
# against a git-built one — reconcile.sh's own comment two files over warns that
# `git rev-parse --show-toplevel` and `pwd` disagree about drive-letter form on
# Windows (`D:/...` vs `/d/...`), and an earlier version of this exact fix did
# precisely that comparison and silently always resolved to "installed".
if [ -z "$(git -C "$KIT_ROOT" rev-parse --show-prefix 2>/dev/null)" ] \
   && git -C "$KIT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  LEDGER="${LEDGER:-$KIT_ROOT/ledger.jsonl}"
else
  LEDGER="${LEDGER:-.pipeline/ledger.jsonl}"
fi

# An option that takes a value must GET one: `add --change --log ...` used to store "--log" as the
# change name (append-only, so permanently) and `route --change --restart-lineage` swallowed a real
# flag. Usage: _val "$1" "$#" "${2-}" -- refuses a missing value or one that IS the next long option
# (exactly "--word": lowercase letters and dashes, nothing else). Text that merely starts with "--"
# ("--no-verify was used for the push") is a legitimate value, e.g. in a --note.
_val() {
  [ "$2" -ge 2 ] || { echo "REFUSED: $1 needs a value. Nothing was written." >&2; exit 2; }
  case "$3" in
    *[!a-z-]*) ;;   # has a space, '=', a digit...: ordinary text (a note may start with "--")
    --[a-z]*) echo "REFUSED: $1 needs a value, but the next argument is the option '$3'. Nothing was written." >&2; exit 2;;
  esac
}

# Pull --ledger <path> out of the argument list before subcommand dispatch,
# wherever it appears, so it works identically across add/route/escape/report/gates.
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) _val "$1" "$#" "${2-}"; LEDGER="$2"; shift 2;;
    *) _args+=("$1"); shift;;
  esac
done
if [ "${#_args[@]}" -gt 0 ]; then
  set -- "${_args[@]}"
else
  set --
fi

# Gate names, budgets and which gates a tier mandates all come from
# core/01-router.md. They used to be hardcoded here, and the copies drifted: this
# file insisted on six gates at T3 while the router marks G8 as `M⁵` — mandatory
# *unless the change is invisible* — and insisted on G5 at T1 where the router
# says nothing is mandatory at all. Compliance is the one check in the kit that
# is not self-graded, so a copy of the rules that is stricter than the rules
# pushes people into logging passes they did not earn.
. "$(dirname "${BASH_SOURCE[0]}")/lib/matrix.sh"
# resolve_commit: the one way a stored commit string becomes a commit (never through a ref name).
if [ ! -f "$(dirname "${BASH_SOURCE[0]}")/lib/commit.sh" ]; then
  echo "missing $(dirname "${BASH_SOURCE[0]}")/lib/commit.sh — cannot resolve commits; refusing to run (a gate would pass unchecked)" >&2
  exit 2
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib/commit.sh"

budget_for() { matrix_budget "$1"; }
gate_name()  { matrix_name "$1"; }

tier_num() { case "$1" in T4) echo 4;; T3) echo 3;; T2) echo 2;; T1) echo 1;; *) echo 0;; esac; }

# Structural checks for values that land in a BARE (unquoted) JSON position --
# "round":%s, "minutes":%s, "tokens":%s, "challenged_premise":%s in the emit()
# templates below. json_escape() cannot make an arbitrary string safe there:
# escaping only protects a value sitting inside quotes, and these positions
# have none. A value that is not actually an integer or an actual `true`/
# `false` literal makes the JSON syntactically invalid at that position no
# matter what it contains — so it is refused, the same as finding_json refuses
# an invalid severity, not merely escaped-and-accepted.
# A round-2 fresh-context review found this accepted "007" -- all digits, so it
# passed the check below, but a leading zero followed by another digit is not a
# valid JSON number (RFC 8259; confirmed against both Python's json and Node's
# JSON.parse, which both refuse it). Not a forgery vector, since it cannot
# break out of its bare position -- but it is exactly the "a ledger that
# cannot be read back is the same as no ledger" failure this file's header
# already warns about, just via a value nobody thought to try instead of one
# an attacker chose.
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; 0*) [ "$1" = 0 ];; *) return 0;; esac; }
# is_uint plus a magnitude cap, for any value that will be fed to bash
# arithmetic ($(( ))) or a numeric `-lt`/`-eq` test. is_uint alone checks
# SHAPE (digits, no sign) but not SIZE — bash arithmetic is SIGNED 64-bit and
# overflows past 2^63. G6 Peer / G7 Threat round 2, independently, against
# --tokens-in/--tokens-out: a 20-digit operand (or two operands summing past
# 2^63) wraps to an arbitrary IN-RANGE value that then passes is_uint on the
# result — round 1's overflow fix only rejected a NEGATIVE wrapped sum, which
# is just one residue out of many. And the wrap doesn't wait for `$(( ))`: a
# huge literal used directly in `[ "$a" -lt "$b" ]` crashes with a raw
# "integer expected" shell error that bypasses the REFUSED framing entirely.
# Bounding the digit COUNT is a pure string comparison — it never touches
# arithmetic, so it cannot itself wrap or crash — and 15 digits (up to ~10^15)
# is already far beyond any real token count while keeping the SUM of two
# such values (≤ 2*10^15) nowhere near 2^63, so nothing downstream can wrap.
is_uint_bounded() { is_uint "$1" && [ "${#1}" -le 15 ]; }
is_bool() { case "$1" in true|false) return 0;; *) return 1;; esac; }
# Gate ids get only a loose structural shape check ("G", then digits), not the
# fixed G1-G8 enum -- 06-extending.md lets a project author new gates past G8,
# so the point here is not "is this a real gate", it is "can this value break
# out of the position it is spliced into".
#
# Tiers are different: T0-T4 is a closed set (core/06-extending.md's own card
# example keys a tier map with exactly those five; nothing in this kit lets a
# project add a T5) and `cmd_compliance` below already refuses any tier
# outside it, in those words, because a typo there silently reads as "nothing
# to check" rather than a refusal. `add` used to share gate's loose shape
# check instead of that same enum, so `add --tier T44` wrote a record
# `compliance --tier T44` would then refuse to even look at -- a gate logged
# at a tier compliance can never check is worse than one rejected outright,
# because the ledger *looks* complete. Empty stays allowed: --tier is
# optional on `add`.
looks_like_tier() { [ -z "$1" ] && return 0; case "$1" in T0|T1|T2|T3|T4) return 0;; *) return 1;; esac; }
looks_like_gate()  { case "$1" in G*) is_uint "${1#G}";; *) return 1;; esac; }

# The repository's ACTUAL default branch (R-005), resolved once here rather than
# per call. resolve_default_branch() lives in tools/lib/default-branch.sh --
# sourced by both this file (the write side) and tools/dashboard.sh (the read
# side) so the two cannot resolve it differently, the same reason lib/matrix.sh
# and lib/coverage.sh exist. Empty when git cannot answer, and then
# change_is_branchy() below falls back to its hand-enumerated list -- the
# behaviour this check had before R-005. Adds no dependency: this file already
# shells out to git at load (the KIT_ROOT/LEDGER block above) and per write
# (detect_commit).
. "$(dirname "${BASH_SOURCE[0]}")/lib/default-branch.sh"
DEFAULT_BRANCH="$(resolve_default_branch)"

# A --change value that is a long-lived branch name (or a fallback placeholder),
# not a real change. Route and gate records correlate ONLY by sharing a change
# name; one named for a permanent branch collects records from many unrelated
# changes and correlates with none -- the dashboard then renders it as a change
# that skipped every mandated gate (P1-5). reconcile.sh defaults --change to
# `git rev-parse --abbrev-ref HEAD`, so this is exactly the value it writes when
# run on a trunk branch with no CHANGE= set; "unknown" is its git-absent fallback.
# A branch-per-change workflow names its branch for the change, so those pass.
#
# The repo's real default branch is refused FIRST, computed above -- so a trunk
# named `prod` or a team convention is caught even though it is not on the list.
# The hand-enumerated `case` is the fallback for when git resolves nothing: it
# lists only unambiguous trunk names and placeholders (`release`, `stable` etc.
# are plausible change names and are deliberately NOT listed). It is duplicated
# in tools/dashboard/app.js's changeIsBranchy -- keep the two lists in sync.
change_is_branchy() {
  if [ -n "$DEFAULT_BRANCH" ] && [ "$1" = "$DEFAULT_BRANCH" ]; then return 0; fi
  case "$1" in
    master|main|develop|development|dev|trunk|HEAD|unknown) return 0;;
    *) return 1;;
  esac
}
refuse_branchy_change() {
  # Say WHY. When the name matched the git-resolved default branch, the reason
  # is not on any list the reader can look up -- and a teammate whose checkout
  # of the same repo has no origin/HEAD never hits it -- so a bare "branch name
  # or placeholder" reads as arbitrary (G8 Dogfood). Name the actual cause.
  if [ -n "$DEFAULT_BRANCH" ] && [ "$1" = "$DEFAULT_BRANCH" ]; then
    echo "REFUSED: --change '$1' is this repository's default branch, resolved from git" >&2
    echo "  (origin/HEAD, or init.defaultBranch) -- not a change." >&2
  else
    echo "REFUSED: --change '$1' is a branch name or placeholder, not a change." >&2
  fi
  echo "  Records correlate only by sharing a change name, and one named for a" >&2
  echo "  long-lived branch joins up with nothing. Name the change:" >&2
  echo "    --change <what-this-does>" >&2
  echo "  (On a trunk branch, set CHANGE=<name> -- reconcile.sh passes it through.)" >&2
  echo "  Nothing was written to $LEDGER." >&2
  exit 2
}

# A line is appended only if it still looks like one JSON object. This is the last
# gate before the record, and it is deliberately structural rather than clever: the
# observed failure was a run whose findings collapsed to empty strings and wrote
# `,,,,` into the ledger, which no consumer can parse and nothing later detects.
# Refusing here is the file's own stated rule (see json_escape) finally enforced:
# a ledger that cannot be read back is the same as no ledger.
emit() {
  local line="$1" summary="${2:-}"
  case "$line" in
    '{'*'}') ;;
    *) echo "REFUSED: refusing to append a line that is not a JSON object." >&2
       echo "  Nothing was written to $LEDGER." >&2
       echo "  line: $line" >&2
       exit 3;;
  esac
  # Deliberately NOT scanning for `,,` or `[,`. That was the shape of the observed
  # corruption, but a note or a claim may legitimately contain either, and a check
  # that refuses valid input is the strictness LEARNINGS.md warns about: nobody can
  # satisfy it, so it gets bypassed, so it measures nothing. The empty element is
  # prevented at its source instead — finding_json refuses rather than returning ""
  # and cmd_add aborts on an empty render. This is the structural backstop only.
  [ "$(printf '%s' "$line" | wc -l)" -eq 0 ] || {
    echo "REFUSED: the line contains a newline; one record is one line." >&2; exit 3; }
  # Checked, not fire-and-forget: every success message below this point names
  # $LEDGER as where the record landed (G7 Threat, this change's own review —
  # an unchecked append let a full disk or a denied permission print that exact
  # confident "logged: ... -> $LEDGER" claim while writing nothing).
  mkdir -p "$(dirname "$LEDGER")" || {
    echo "REFUSED: could not create the directory for $LEDGER." >&2
    echo "  Nothing was written." >&2
    exit 3; }
  # G7 Threat round 2, this change's own review: an append succeeds against
  # /dev/null, a device, a FIFO, or a symlink to any of those — exit 0, clean
  # success line, and the record silently never exists anywhere. Refusing
  # anything that exists and is not a REGULAR file closes that (and subsumes
  # the plain-directory case the append below would also catch on its own).
  [ -e "$LEDGER" ] && [ ! -f "$LEDGER" ] && {
    echo "REFUSED: $LEDGER exists and is not a regular file (a directory, a device," >&2
    echo "  a FIFO, or a symlink to one). A mistyped --ledger pointing at a directory" >&2
    echo "  is the common case; a device or FIFO is the dangerous one, because it" >&2
    echo "  accepts the append and silently discards every record written to it." >&2
    echo "  Nothing was written." >&2
    exit 3; }
  # A ledger that does not end in a newline (a truncated last write, a merge resolved by hand and saved
  # without one) would have this record glued onto that last line: one physical line, two records. Every
  # consumer ranks by line, so a FAIL glued behind a PASS never counted as "after" it and compliance exited 0
  # over a logged failure (G4 round 28). Start a new line instead, and say so.
  if [ -s "$LEDGER" ] && [ -n "$(tail -c 1 "$LEDGER" 2>/dev/null)" ]; then
    printf '\n' >> "$LEDGER" || {
      echo "REFUSED: could not repair the missing final newline in $LEDGER. Nothing was written." >&2
      exit 3; }
    echo "  note: $LEDGER did not end in a newline (a truncated or hand-edited last line); this record starts a new line." >&2
  fi
  printf '%s\n' "$line" >> "$LEDGER" || {
    echo "REFUSED: the write to $LEDGER failed (disk full, permission denied, or the" >&2
    echo "  path is not writable). This append is not atomic — if bytes reached the" >&2
    echo "  file before the failure, a truncated line is now sitting in $LEDGER;" >&2
    echo "  check it by hand before trusting anything appended after this point." >&2
    exit 3; }
  # The destination is named HERE, at the one place that actually writes —
  # not re-typed at every caller (G4 Ripple, this change's own review: five
  # call sites each hand-appending "-> $LEDGER" is an enumerated list a sixth
  # writer can silently miss, and no test catches an omission at the wrong
  # layer). A caller with nothing to say passes no summary and gets no line.
  # `if`, not `[ -n "$summary" ] && echo ...` — that form returns the TEST's
  # exit status (1) when summary is empty, so emit() itself would report a
  # successful write as a failure to any caller that checks its own return
  # code (G7 Threat round 2, this change's own review — live-confirmed
  # `emit_rc=1` with the record correctly written; cmd_route's own exit code
  # is this function's, since emit is its last statement).
  if [ -n "$summary" ]; then echo "$summary → $LEDGER"; fi
}

# What produced this line. Version plus a hash of the tools, because a version
# alone does not move when a tool is edited in place — which is the whole failure
# this exists to expose. Auto-detected for the same reason `commit` is
# (core/04-ledger.md): a provenance field you have to remember is one you will
# eventually not. KIT_ROOT is computed above, near LEDGER's default — same value,
# needed before this point too.
detect_kit() {
  local v="" h
  [ -f "$KIT_ROOT/VERSION" ] && v="$(tr -d ' \t\r\n' < "$KIT_ROOT/VERSION" 2>/dev/null)"
  if [ -f "$KIT_ROOT/.kit-version" ]; then
    local iv; iv="$(sed -n 's/^version=//p' "$KIT_ROOT/.kit-version" 2>/dev/null | head -1)"
    [ -n "$iv" ] && v="$iv"
  fi
  [ -n "$v" ] || v="unknown"
  h="$(cat "$KIT_ROOT"/tools/*.sh "$KIT_ROOT"/tools/lib/*.sh 2>/dev/null \
       | cksum 2>/dev/null | awk '{printf "%08x", $1}')"
  printf '%s+%s' "$v" "${h:-nohash}"
}

# Escape a string for a JSON string context. Notes are long agent-written prose
# and findings quote real code, so an unescaped " or \ is not hypothetical — it
# produces a line that no consumer can parse, silently, forever. A ledger that
# cannot be read back is the same as no ledger.
#
# EVERY byte below 0x20 must be escaped, not only tab, CR and LF: JSON forbids a raw control byte inside a
# string, so a pasted ESC (coloured test output in a --finding, --note, REASON or --evidence) wrote a line that
# the grep-based consumers read and JSON.parse rejected -- compliance said FAIL where the dashboard said pass
# (G4 round 28). Tab, CR and LF keep their short forms; the rest become \u00XX. LC_ALL=C makes awk walk bytes,
# so multi-byte text passes through unchanged.
json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' \
    | LC_ALL=C awk '
        BEGIN {
          for (i = 1; i < 32; i++) if (i != 9 && i != 10 && i != 13) esc[sprintf("%c", i)] = sprintf("\\u%04x", i)
          re = "[" sprintf("%c", 1) "-" sprintf("%c", 8) sprintf("%c", 11) sprintf("%c", 12) sprintf("%c", 14) "-" sprintf("%c", 31) "]"
        }
        NR > 1 { printf "\\n" }
        $0 ~ re { out = ""; n = length($0)
                  for (j = 1; j <= n; j++) { ch = substr($0, j, 1); out = out ((ch in esc) ? esc[ch] : ch) }
                  printf "%s", out; next }
        { printf "%s", $0 }'
}

# Parse  severity::location::claim  into one JSON object.
# Claim is greedy — it takes everything after the second separator, so a claim
# containing "::" (a C++ scope, a URL) survives intact. Only the first two
# separators are structural.
#
# Three things are REFUSED here rather than warned about, and the discriminator is
# not strictness for its own sake — LEARNINGS.md records that a check stricter than
# the rule it enforces produces false entries, not rigour. The line is: reject what
# makes the record FALSE or UNREADABLE, warn on what is merely INCOMPLETE.
#
#   invalid severity   the four values are the axis every report groups by, and the
#                      right one is always knowable, so nothing legitimate is blocked.
#                      This used to warn and then store the bad value verbatim — the
#                      worst of both, and core/02-gates.md described it as "silently
#                      coerced", which was never what the code did.
#   missing location   core/02-gates.md:74 already says a finding without a citation
#                      is DELETED, not softened. The doc mandated rejection; only the
#                      tool was lenient.
#   unfiled out-of-scope   core/02-gates.md:95 routes these to a separate follow-up
#                      item. Nothing implemented the routing, so they accumulated in
#                      the ledger and nowhere else.
#
finding_json() {
  local raw="$1" id="$2" sev loc claim rest filed=""
  case "$raw" in
    *::*::*) sev="${raw%%::*}"; rest="${raw#*::}"; loc="${rest%%::*}"; claim="${rest#*::}";;
    *::*)    sev="${raw%%::*}"; loc=""; claim="${raw#*::}";;
    *)       sev="";            loc=""; claim="$raw";;
  esac

  case "$sev" in
    blocking|minor|info|out-of-scope) ;;
    *)
      echo "REFUSED: severity '$sev' is not one of blocking | minor | info | out-of-scope." >&2
      echo "  in: $raw" >&2
      echo "  The vocabulary is on every gate card (the \`severities:\` line) and in" >&2
      echo "  core/04-ledger.md. Nothing was written." >&2
      return 1;;
  esac

  # The evidence rule (core/02-gates.md): every claim about behavior cites
  # file:line or command output, including agreement. Mechanical here rather
  # than remembered, the same way `withhold` made the blind review rule real.
  if [ -z "$loc" ] && { [ "$sev" = "blocking" ] || [ "$sev" = "minor" ]; }; then
    echo "REFUSED: a '$sev' finding with no location." >&2
    echo "  in: $raw" >&2
    echo "  The evidence rule wants file:line or command output. core/02-gates.md:" >&2
    echo "  a finding without a citation is deleted, not softened. Nothing was written." >&2
    return 1
  fi

  # An out-of-scope finding is real, confirmed outside this diff, and therefore
  # about to leave this change's story entirely. Naming where it went is the
  # difference between the failure rule being followed and being quoted.
  if [ "$sev" = "out-of-scope" ]; then
    filed="$(printf '%s' "$claim" \
             | sed -n 's/.*filed:\([^ ]*\).*/\1/p' | sed -e 's/[.,;)]*$//')"
    if [ -z "$filed" ]; then
      echo "REFUSED: an 'out-of-scope' finding must say where it was filed." >&2
      echo "  in: $raw" >&2
      echo "  Add \`filed:<ref>\` to the claim — an issue id, a TODO path, a risks.md row." >&2
      echo "  core/02-gates.md routes these to a separate follow-up item; a finding with" >&2
      echo "  no destination is one the next round has no way to find. Nothing was written." >&2
      return 1
    fi
  fi

  printf '{"id":"%s","severity":"%s","location":"%s","claim":"%s"%s}' \
    "$(json_escape "$id")" "$(json_escape "$sev")" "$(json_escape "$loc")" \
    "$(json_escape "$claim")" \
    "$([ -n "$filed" ] && printf ',"filed":"%s"' "$(json_escape "$filed")")"
}

# commit_arg <value> <1 when --commit was given, else 0>  --  the ONE place a --commit becomes a stored value
# (add, route, assume). Prints what to store, or REFUSES (stderr, exit status 1; the caller exits 2).
# --commit lands in the record and is later fed to git by compliance, so: lower-case hex or nothing
# (`HEAD~1`, a branch name, free text, upper case are refused rather than stored as a binding that
# compliance can only wave through); and in a repository exactly one commit, stored as the FULL sha
# (a blob or tree id, a 3- or 41-character string, an unknown or ambiguous prefix, an abbreviated
# annotated-tag id are refused: each would later read as "cannot be checked", a PASS with a note).
# An EXPLICIT empty value is refused in a repository that has a commit: it is the same door.
commit_arg() {
  local c="$1" given="$2" full
  [ "$given" -eq 1 ] || c="$(detect_commit)"
  case "$c" in
    *[!0-9a-f]*) echo "REFUSED: --commit '$c' is not a hex commit sha (lower case only; try --commit \"\$(git rev-parse HEAD~1)\")." >&2
                 echo "  Nothing was written to $LEDGER." >&2; return 1;;
  esac
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if [ -z "$c" ]; then
      if [ "$given" -eq 1 ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
        echo "REFUSED: --commit '' names no commit, and this repository has one. Omit --commit to record HEAD." >&2
        echo "  Nothing was written to $LEDGER." >&2; return 1
      fi
    else
      full="$(resolve_commit "$c")" || {
        echo "REFUSED: --commit '$c' does not name exactly one commit in this repository (a blob, a tree, an" >&2
        echo "  unknown or ambiguous prefix, an ABBREVIATED annotated-tag id, or a wrong length)." >&2
        echo "  Nothing was written to $LEDGER." >&2; return 1; }
      c="$full"
    fi
  fi
  printf '%s\n' "$c"
}

# The full sha of what is being reviewed, when we are in a repo and not told.
# --verify -q: with no commit yet (G1 is logged before the first one) a bare `rev-parse HEAD` prints the
# word HEAD and fails, which the hex check then refuses as a --commit nobody typed. Nothing is the answer.
detect_commit() { git rev-parse --verify -q HEAD 2>/dev/null || printf ''; }

# ---------------------------------------------------------------- add (gate run)
cmd_add() {
  local change="" gate="" tier="" outcome="pass" confidence="" confidence_set=0
  local challenged="false" minutes=0 tokens=0 tokens_set=0 lane="normal" note="" model="${PIPELINE_MODEL:-unset}"
  local round=1 round_set=0 commit="" commit_set=0
  local withhold_breached=""   # unset by default — TRIAL, optional (see --withhold-breached above)
  local tokens_in="" tokens_out="" tokens_in_set=0 tokens_out_set=0   # OPTIONAL, PAIRED (see --tokens-in above)
  # Findings are collected raw and rendered after the loop: the id needs --change,
  # --round and --gate, and requiring them to precede --finding on the command line
  # would be a rule nobody can see they broke.
  local raw_findings=() n_details=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --change) _val "$1" "$#" "${2-}"; change="$2"; shift 2;;      --gate) _val "$1" "$#" "${2-}"; gate="$2"; shift 2;;
      --tier) _val "$1" "$#" "${2-}"; tier="$2"; shift 2;;
      --outcome) _val "$1" "$#" "${2-}"; outcome="$2"; shift 2;;
      --confidence) _val "$1" "$#" "${2-}"; confidence="$2"; confidence_set=1; shift 2;;
      --challenged) _val "$1" "$#" "${2-}"; challenged="$2"; shift 2;; --minutes) _val "$1" "$#" "${2-}"; minutes="$2"; shift 2;;
      --tokens) _val "$1" "$#" "${2-}"; tokens="$2"; tokens_set=1; shift 2;;
      --tokens-in) _val "$1" "$#" "${2-}"; tokens_in="$2"; tokens_in_set=1; shift 2;;
      --tokens-out) _val "$1" "$#" "${2-}"; tokens_out="$2"; tokens_out_set=1; shift 2;;
      --lane) _val "$1" "$#" "${2-}"; lane="$2"; shift 2;;          --note) _val "$1" "$#" "${2-}"; note="$2"; shift 2;;
      --model) _val "$1" "$#" "${2-}"; model="$2"; shift 2;;        --round) _val "$1" "$#" "${2-}"; round="$2"; round_set=1; shift 2;;
      --commit) _val "$1" "$#" "${2-}"; commit="$2"; commit_set=1; shift 2;;
      --withhold-breached) _val "$1" "$#" "${2-}"; withhold_breached="$2"; shift 2;;
      --finding)
        _val "$1" "$#" "${2-}"; raw_findings[$n_details]="$2"; n_details=$((n_details + 1)); shift 2;;
      --findings)
        echo "REFUSED: --findings was removed. Pass one --finding per finding instead:" >&2
        echo "  --finding \"blocking|minor|info|out-of-scope::file:line::claim\"" >&2
        echo "  core/04-ledger.md: a count \"cannot be read back, argued with, or shown" >&2
        echo "  to anyone\". The number of --finding rows is the count." >&2
        exit 2;;
      *) echo "unknown option: $1" >&2; exit 2;;
    esac
  done
  [ -n "$change" ] && [ -n "$gate" ] || {
    echo "usage: ledger.sh add --change <name> --gate <G1..G8> [--tier T3] ..." >&2; exit 2; }
  change_is_branchy "$change" && refuse_branchy_change "$change"

  # These land in a BARE (unquoted) JSON position in the emit() template below
  # ("round":%s, "minutes":%s, "tokens":%s, "challenged_premise":%s) or, for
  # tier/gate, get compared and displayed as trusted routing data by compliance
  # and the dashboard. No amount of escaping fixes a bad value in a bare
  # position — the fix is refusing before it reaches emit(), the same as
  # finding_json already refuses an invalid severity rather than writing it.
  looks_like_gate "$gate" || {
    echo "REFUSED: --gate '$gate' does not look like a gate id (G, then digits)." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }
  # Well-formed is not the same as real. G9+ is a legal authored gate (core/06-extending.md),
  # so a gate the router does not list is warned about, not refused: `G9` typed for `G8`
  # would otherwise be logged, mandated by nothing, and look like evidence.
  if _matrix_load 2>/dev/null && ! matrix_gates 2>/dev/null | grep -qx "$gate"; then
    echo "WARNING: $gate is not a gate in the router table (core/01-router.md). It is recorded," >&2
    echo "  but no tier mandates it, so compliance will never ask for it. Typo for G1..G8?" >&2
  fi
  looks_like_tier "$tier" || {
    echo "REFUSED: --tier '$tier' is not one of T0..T4 (or empty)." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }
  is_uint_bounded "$round" || {
    echo "REFUSED: --round '$round' is not a non-negative integer." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }
  [ "$round" -ge 1 ] || {
    echo "REFUSED: --round 0 is not a round; rounds start at 1." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }
  if [ "$round_set" -eq 0 ] && [ -n "$change" ]; then
    local _lr; _lr="$(change_latest_route_round "$change")"
    if [ -n "$_lr" ] && [ "$_lr" -gt 1 ]; then
      echo "  note: no --round given, so this is recorded as round 1, but '$change' has a route at round $_lr." >&2
      echo "        Pass --round $_lr if it belongs to the latest round." >&2
    fi
  fi
  is_uint "$minutes" || {
    echo "REFUSED: --minutes '$minutes' is not a non-negative integer." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }
  # Bounded, not plain is_uint: $tokens is compared against a computed value
  # below (`-lt`), and an oversized literal there crashes that comparison
  # with a raw shell error instead of a clean REFUSED (G7 Threat round 2).
  is_uint_bounded "$tokens" || {
    echo "REFUSED: --tokens '$tokens' is not a non-negative integer of a plausible size." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }

  # --tokens-in/--tokens-out are optional but PAIRED. Checked on whether the
  # FLAG was given (tokens_in_set/tokens_out_set), not on the value being
  # non-empty — G8 Dogfood round 1 found that `--tokens-in ""` was silently
  # read as "flag omitted" instead of "invalid value", so `--tokens-in ""
  # --tokens-out 200` produced the wrong error message. Checking the flag
  # means an explicitly-empty value now falls through to the is_uint check
  # below and is refused for what it actually is.
  #
  # The real reason one without the other is refused: `tokens_in`/`tokens_out`
  # are used below to compute the total, so a one-sided value would corrupt
  # that computation, not merely "understate a direction" (G6 Peer round 1 —
  # the file's own --action/--evidence analogy doesn't hold, since a lone
  # --evidence is meaningless while a lone --tokens-in is a true, usable
  # number; the pairing here is forced by what the code does with it, not by
  # the value being semantically empty on its own).
  if [ "$tokens_in_set" -eq 1 ] && [ "$tokens_out_set" -eq 0 ]; then
    echo "REFUSED: --tokens-in '$tokens_in' with no --tokens-out. Nothing was written to $LEDGER." >&2
    exit 2
  fi
  if [ "$tokens_in_set" -eq 0 ] && [ "$tokens_out_set" -eq 1 ]; then
    echo "REFUSED: --tokens-out '$tokens_out' with no --tokens-in. Nothing was written to $LEDGER." >&2
    exit 2
  fi
  if [ "$tokens_in_set" -eq 1 ]; then
    # Same bare-JSON-position exposure as --tokens above (see the emit()
    # comment near the printf template) — validated here, not escaped there.
    # Bounded (see is_uint_bounded above `is_uint`'s definition): these two
    # are about to be summed in bash arithmetic, which overflows silently past
    # 2^63 — an operand this check doesn't catch can make an out-of-range
    # SUM land back in range and read as plausible (G6 Peer / G7 Threat
    # round 2, independently).
    is_uint_bounded "$tokens_in" || {
      echo "REFUSED: --tokens-in '$tokens_in' is not a non-negative integer of a plausible size." >&2
      echo "  Nothing was written to $LEDGER." >&2; exit 2; }
    is_uint_bounded "$tokens_out" || {
      echo "REFUSED: --tokens-out '$tokens_out' is not a non-negative integer of a plausible size." >&2
      echo "  Nothing was written to $LEDGER." >&2; exit 2; }
    # G4 Ripple round 1 (challenged_premise): a caller's true billed total can
    # legitimately EXCEED tokens_in + tokens_out — this kit's own subagent
    # gates re-read core/ on every run, and cache-read/cache-creation tokens
    # are billed but belong to neither "in" nor "out" as this field defines
    # them. Requiring exact equality made it impossible to record a true
    # total alongside an honest partial split, so the rule is: the total may
    # not be LESS than the split (that would be internally inconsistent —
    # the parts can't outweigh the whole), but may exceed it. When --tokens is
    # omitted, the split is the only information available and supplies the
    # total directly.
    #
    # bash arithmetic is signed 64-bit and overflows silently past 2^63. Round 1 only
    # rejected a NEGATIVE wrapped sum (--tokens-in 9223372036854775807
    # --tokens-out 1); round 2 (G6 Peer / G7 Threat, independently) showed a
    # 20-digit operand can wrap to an arbitrary POSITIVE value that then
    # passes a sign check. is_uint_bounded on both operands above is what
    # actually closes this now — with each operand capped at 15 digits, the
    # sum below cannot reach 2^63, let alone wrap. This is_uint check on the
    # sum itself is defense in depth (the same reasoning `04-ledger.md`
    # gives for keeping json_escape on already-enum-checked fields), not the
    # thing doing the work.
    local computed_total=$((tokens_in + tokens_out))
    is_uint "$computed_total" || {
      echo "REFUSED: --tokens-in + --tokens-out overflowed to '$computed_total'." >&2
      echo "  Nothing was written to $LEDGER." >&2; exit 2; }
    if [ "$tokens_set" -eq 1 ] && [ "$tokens" -lt "$computed_total" ]; then
      echo "REFUSED: --tokens $tokens is less than --tokens-in $tokens_in + --tokens-out $tokens_out (=$computed_total)." >&2
      echo "  The total cannot be smaller than the split that makes it up." >&2
      echo "  Nothing was written to $LEDGER." >&2; exit 2
    fi
    [ "$tokens_set" -eq 1 ] || tokens=$computed_total
  fi
  is_bool "$challenged" || {
    echo "REFUSED: --challenged '$challenged' is not true or false." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }

  # Render findings now that the id components are known. A refusal from
  # finding_json aborts the whole entry — a partially-recorded run is a run the
  # ledger describes wrongly, which is worse than one it does not describe.
  local details="" i=0 obj fid
  while [ "$i" -lt "$n_details" ]; do
    fid="$(printf '%s-r%s-%s-%s' "$change" "$round" "$gate" "$((i + 1))")"
    obj="$(finding_json "${raw_findings[$i]}" "$fid")" || {
      echo "  (finding $((i + 1)) of $n_details — nothing was written to $LEDGER)" >&2
      exit 2; }
    [ -n "$obj" ] || {
      echo "REFUSED: finding $((i + 1)) rendered to nothing. Nothing was written." >&2; exit 3; }
    details="${details}${details:+,}${obj}"
    i=$((i + 1))
  done
  local findings=$n_details

  # The outcome vocabulary used to only warn on a typo ("passed", "OK") rather
  # than refuse, unlike --tier and --resolution's identical closed-set checks
  # elsewhere in this file. A warning still wrote the line: compliance reads it
  # as neither a pass nor a skip, so the record exists, looks fine in the file,
  # and counts as nothing -- silently, in the one file 04-ledger.md calls "not
  # self-graded". Found by a fresh-context G8 Dogfood run that typed --outcome
  # passs by hand and only noticed because it went looking for the entry
  # afterward. Refusing before it reaches emit() matches --tier (line ~375)
  # and --resolution (cmd_assume) exactly, and the same reasoning applies:
  # append-only means a bad value here is never backfilled.
  case "$outcome" in
    pass|fail|skipped|n/a) ;;
    *) echo "REFUSED: --outcome '$outcome' is not one of pass|fail|skipped|n/a." >&2
       echo "  compliance would read anything else as no verdict at all -- an entry that" >&2
       echo "  exists, looks fine in the file, and counts as nothing. Nothing was written" >&2
       echo "  to $LEDGER." >&2
       exit 2;;
  esac

  # `confidence` says whether this gate got an independent fresh-context review
  # (core/02-gates.md's context rule) — `fresh` — or not — `low` (same session,
  # or no clean one was available). core/04-ledger.md gives exactly those two,
  # every gate card's `logs_with:` line reads `--confidence fresh|low`, and
  # tools/dashboard/app.js's isIndependent() is a strict allow-list: `conf ===
  # "fresh"` and nothing else. The field is load-bearing in two directions:
  #
  #   - An OUT-OF-VOCAB value fails closed — isSelfCheck() marks the record an
  #     author self-check, and `ledger.sh report` (below) counts `"fresh"` and
  #     `"low"` literally, so the line drops out of the fresh/low/challenge
  #     tallies entirely. A gate that genuinely ran fresh and challenged the
  #     author, logged `--confidence tru`, silently vanishes from the
  #     disagreement quota. It happened: `ci-to-codebuild` G7 round 2 was
  #     `--confidence true` (`pass`, `challenged_premise:true`), superseded by a
  #     corrected append (commit b471896).
  #   - A MISSING value on a verdict is the same failure by omission. So for
  #     `pass`/`fail` it is REQUIRED, not defaulted — the docs always implied it
  #     (every card passes it explicitly) and G8 Dogfood made the omission path a
  #     repeat finding. `skipped`/`n/a` are exempt: they reviewed nothing, and
  #     get `low` stamped below.
  #
  # Refused, not stored or defaulted — same as --tier, --outcome and
  # --resolution, same reason: the ledger is append-only and never backfilled.
  if [ "$confidence_set" -eq 1 ]; then
    case "$confidence" in
      fresh|low) ;;
      *) echo "REFUSED: --confidence '$confidence' is not one of fresh|low." >&2
         echo "  fresh = an independent fresh-context review; low = anything else" >&2
         echo "  (same session, or no clean one was available). The dashboard trusts" >&2
         echo "  only \"fresh\" as independent and ledger.sh report counts the two" >&2
         echo "  literally, so any other value silently stops counting. Nothing was" >&2
         echo "  written to $LEDGER." >&2
         exit 2;;
    esac
  elif [ "$outcome" = "pass" ] || [ "$outcome" = "fail" ]; then
    echo "REFUSED: --outcome $outcome needs --confidence fresh|low." >&2
    echo "  fresh = this gate ran in a session that did not write the code" >&2
    echo "  (core/02-gates.md's context rule); low = anything else. A verdict with" >&2
    echo "  no confidence is an independence claim nobody made — the dashboard and" >&2
    echo "  every ledger stat would silently not count it. Nothing was written to" >&2
    echo "  $LEDGER." >&2
    exit 2
  fi

  # `n/a` says this gate's card does not fire here. It is only honoured by
  # compliance where the router's own cell carries a footnote, and it needs a
  # reason: a bare n/a is an assertion, and the point of allowing one is that
  # the reason travels with it.
  if [ "$outcome" = "n/a" ] && [ -z "$note" ]; then
    echo "  warning: --outcome n/a with no --note. Compliance will show 'no reason" >&2
    echo "           recorded', which is what a skipped gate looks like to a reviewer." >&2
  fi

  # `skipped`/`n/a` reviewed nothing, so they have no confidence to report and
  # --confidence is not required for them (the check above only demands it for a
  # verdict). Stamp `low` so the record carries a value the dashboard and
  # `report` can read. Explicit --confidence still wins if someone really means
  # it (e.g. insisting a skipped gate's placeholder came from a fresh session).
  if { [ "$outcome" = "skipped" ] || [ "$outcome" = "n/a" ]; } && [ "$confidence_set" -eq 0 ]; then
    confidence="low"
  fi

  commit="$(commit_arg "$commit" "$commit_set")" || exit 2

  local details_json=""
  [ "$n_details" -gt 0 ] && details_json="$(printf ',"finding_details":[%s]' "$details")"

  # TRIAL, optional (see --withhold-breached above): omitted entirely from the
  # record when not passed — not written as false, which would claim a
  # negative answer nobody actually gave. An invalid value is warned about and
  # dropped rather than written, since anything other than a JSON `true`/
  # `false` literal here would emit malformed JSON into an append-only file.
  local withhold_json=""
  if [ -n "$withhold_breached" ]; then
    case "$withhold_breached" in
      true|false) withhold_json="$(printf ',"withhold_breached":%s' "$withhold_breached")";;
      *) echo "  warning: --withhold-breached expected true|false, got '$withhold_breached' — not recorded." >&2;;
    esac
  fi

  # Present only when --tokens-in/--tokens-out were given, same "absent means
  # not this shape" convention as details_json and withhold_json above. `tokens`
  # itself (below) always carries the total either way, so a line written by an
  # older ledger.sh and a line written by this one are both readable by every
  # existing sum/average — the split is additional precision, not a new
  # required field, the same widening core/04-ledger.md already documents for
  # `date` going from a bare day to a full instant.
  local tokens_split_json=""
  [ "$tokens_in_set" -eq 1 ] && tokens_split_json="$(printf ',"tokens_in":%s,"tokens_out":%s' "$tokens_in" "$tokens_out")"

  # tier/gate/outcome/confidence reach here only after a closed-set check above,
  # so json_escape is a no-op for them today — kept anyway as defense in depth
  # against one of those checks ever being loosened, the same way finding_json
  # escapes severity even though it is also enum-checked. `lane` and `model`
  # have NO closed-set check, so json_escape is the only thing standing between
  # them and the JSON they are spliced into. `lane` is documented as exactly
  # `normal|hotfix` (core/04-ledger.md) and `cmd_report` buckets it with a
  # literal `grep -c '"lane":"hotfix"'`, so a `--lane hotfixx` typo silently
  # miscounts yield the same way a bad `--confidence` miscounts independence —
  # a latent instance of the gap this change closes for `confidence`, left as a
  # follow-up to keep this change to one field. `model` only warns on the
  # literal `unset`. round/minutes/tokens/challenged/tokens_in/tokens_out land
  # in a BARE, unquoted position in this template (tokens_in/tokens_out inside
  # tokens_split_json) and are validated above rather than escaped here,
  # because escaping only protects a value inside quotes.
  emit "$(printf '{"type":"gate","date":"%s","change":"%s","tier":"%s","gate":"%s","round":%s,"commit":"%s","kit":"%s","findings":%s%s,"outcome":"%s","confidence":"%s","challenged_premise":%s,"minutes":%s,"tokens":%s,"lane":"%s","model":"%s","note":"%s"%s%s}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$change")" "$(json_escape "$tier")" "$(json_escape "$gate")" "$round" \
    "$(json_escape "$commit")" "$(json_escape "$(detect_kit)")" "$findings" "$details_json" \
    "$(json_escape "$outcome")" "$(json_escape "$confidence")" "$challenged" "$minutes" "$tokens" "$(json_escape "$lane")" \
    "$(json_escape "$model")" "$(json_escape "$note")" "$withhold_json" "$tokens_split_json")" \
    "logged: $gate ($(gate_name "$gate")) on $change — round $round, $findings finding(s), $outcome"

  # core/08-models.md picks a tier per gate and then says "say which you picked".
  # Nobody did, on any line of the first real run, because nothing asked. The
  # card carries the expected tier now; this is what notices when it is ignored.
  if [ "$model" = "unset" ]; then
    echo "  warning: no --model recorded (and \$PIPELINE_MODEL is unset)." >&2
    echo "           core/08-models.md assigns each gate a tier and asks you to say which" >&2
    echo "           you picked — the \`model:\` line on $gate's card is the expected one." >&2
    echo "           Without it you cannot tell a process change from a model change." >&2
  fi
  # No token budget exists to overrun, so this is a note, not a warning: the field
  # is new and nothing yet mandates it. It replaces the budget check that used to
  # hang off --minutes, which no subagent run ever populated — a check that cannot
  # fire is worse than no check.
  #
  # Gated on tokens_set/tokens_in_set, not on "$tokens" -eq 0 — G8 Dogfood round 1
  # logged a genuine, explicit `--tokens 0` (a real zero-cost run) and got told
  # "no --tokens recorded" anyway, indistinguishable from actually omitting the
  # flag. Checking whether a flag was PASSED, not what value it resolved to, is
  # the same fix `--tokens-in ""` needed above.
  if [ "$tokens_set" -eq 0 ] && [ "$tokens_in_set" -eq 0 ] && [ "$outcome" != skipped ] && [ "$outcome" != "n/a" ]; then
    echo "  note: no --tokens recorded. Cost is not the goal (core/04-ledger.md keeps"
    echo "        escape rate as the headline) but it is the constraint, and an"
    echo "        unmeasured constraint is how a pipeline gets abandoned instead of tuned."
  fi
}

# ---------------------------------------------------------------- route (reconcile)
cmd_route() {
  local change="" predicted="" actual="" round=1 commit="" commit_set=0 reason=""
  local action="" evidence="" base="" restart=0 is_restart=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --restart-lineage) restart=1; shift;;
      --base) _val "$1" "$#" "${2-}"; base="$2"; shift 2;;
      --change) _val "$1" "$#" "${2-}"; change="$2"; shift 2;; --predicted) _val "$1" "$#" "${2-}"; predicted="$2"; shift 2;;
      --actual) _val "$1" "$#" "${2-}"; actual="$2"; shift 2;; --round) _val "$1" "$#" "${2-}"; round="$2"; shift 2;;
      --commit) _val "$1" "$#" "${2-}"; commit="$2"; commit_set=1; shift 2;;
      --reason) _val "$1" "$#" "${2-}"; reason="$2"; shift 2;;
      --action) _val "$1" "$#" "${2-}"; action="$2"; shift 2;;
      --evidence) _val "$1" "$#" "${2-}"; evidence="$2"; shift 2;;
      *) echo "unknown option: $1" >&2; exit 2;;
    esac
  done
  [ -n "$change" ] && [ -n "$predicted" ] && [ -n "$actual" ] || {
    echo "usage: ledger.sh route --change <name> --predicted T1 --actual T4 [--reason 'Bug fix'] [--base <sha>]" >&2
    echo "                       [--action NAME --evidence '<citation>']" >&2
    exit 2; }
  change_is_branchy "$change" && refuse_branchy_change "$change"

  # --round lands in a BARE JSON position below ("round":%s) -- see cmd_add's
  # identical check for why escaping cannot fix a bad value there.
  is_uint_bounded "$round" || {
    echo "REFUSED: --round '$round' is not a non-negative integer." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }
  # Rounds start at 1. Round 0 was accepted, but lineages, floors and the dashboard all key on
  # round 1, so a round-0 route silently belonged to no lineage on one side of the kit and to
  # lineage 1 on the other.
  [ "$round" -ge 1 ] || {
    echo "REFUSED: --round 0 is not a round; rounds start at 1." >&2
    echo "  Nothing was written to $LEDGER." >&2; exit 2; }
  # --base is a commit sha: it is where this change STARTS, recorded once so compliance
  # never has to re-derive it from trunk -- which moves, and which stops meaning "where the
  # change started" the moment the branch is merged. Hex only, and it must name a commit
  # that exists here (a one-character `--base a` used to be accepted).
  case "$base" in
    *[!0-9a-f]*) echo "REFUSED: --base '$base' is not a hex commit sha." >&2
                 echo "  Nothing was written to $LEDGER." >&2; exit 2;;
  esac
  # Store and compare the FULL sha: the same commit given abbreviated read as "a different base"
  # (refused as a new lineage, and after a restart a plain re-run was refused too -- G8 round 19).
  # Resolved among commit OBJECTS, never through ref names (a tag named like the short sha, G7 round 23).
  if [ -n "$base" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    local _full_base
    if _full_base="$(resolve_commit "$base")" && [ -n "$_full_base" ]; then
      base="$_full_base"
    else
      echo "REFUSED: --base '$base' is not a commit in this repository (or names more than one)." >&2
      echo "  Nothing was written to $LEDGER." >&2; exit 2
    fi
  fi
  # A round-1 route with a different base than the change's current one starts a NEW lineage (new
  # base, new tier floor). That is how a reused name restarts, but it is also what happens when
  # someone simply forgets ROUND=2 after a push (the base moved) -- so it is refused unless asked
  # for. The SAME base again is a re-run of the same reconcile and needs nothing.
  # A declared ACTION (--action: store-publish, prod-deploy ...) recurs once per EVENT, not once per
  # piece of work, and reconcile.sh sends --base (whenever git finds a merge-base) and defaults the round to 1, so the second
  # firing after the base moved was refused and the declaration never recorded. Each firing is its
  # own event, so it starts its own lineage (a restart, marked as one): the gate results logged for
  # the previous event read NOT RUN for this one. Merely letting it through kept the first event's
  # passes counting for the second (G1 round 11: an unreviewed second prod-deploy read all PASS).
  # Whatever the base: reconcile.sh computes merge-base(BASE, HEAD), which does not move across new
  # local commits, so a redeploy of the same HEAD, or a deploy after committing a fix and before
  # pushing, arrives with the SAME base and used to stay in the first firing's lineage (G7/G4/G1
  # round 12). One lineage per event is the invariant, not "the base moved".
  # A firing is an EVENT, not a round of some work, so it is always recorded as round 1: logged at
  # --round 2 (the knob the refusal text offers for follow-ups) it used to skip the restart and the
  # first event's passes carried forward as PASS* (G7 round 13).
  # Only a firing on a change that has ALREADY fired some declared action is a new event. The first
  # firing on a change that so far has only diff routes is a follow-up of that work (reconcile.sh
  # composes a version-bump diff with a publish action under one CHANGE=): it keeps the round it was
  # given and goes through the ordinary rules below, whose --round 2 advice therefore works.
  local _repeat_action=0
  # A change with no route at all has nothing to follow up: its first action firing is round 1, so
  # a repeat firing finds a round-1 route to restart from (logged at ROUND=2 the first firing used
  # to be kept at round 2 and the second one skipped the restart -- G5 round 15).
  if [ -n "$action" ] && [ "$round" -ne 1 ] && ! change_has_route "$change"; then
    echo "  NOTE: the first route of '$change' is a declared action: recorded as round 1; --round $round ignored." >&2
    round=1
  fi
  if [ -n "$action" ] && change_has_any_action_route "$change"; then
    _repeat_action=1; restart=1
    if [ "$round" -ne 1 ]; then
      echo "  NOTE: a repeat firing of a declared action is recorded as round 1 (each firing is its own event); --round $round ignored." >&2
      round=1
    fi
  fi
  # An explicit --restart-lineage is a restart, and a restart is round 1 (lineage starts read only
  # round-1 rows). Given with a stale --round 2 (ROUND=2 is still exported when RESTART_LINEAGE=1 is
  # added) it used to be dropped without a word and the old lineage's passes kept counting (G6/G7
  # round 19). Same treatment as a repeat action firing: recorded as round 1, and it says so.
  # (Also with --action: the first firing of an action on a change with only diff routes keeps its
  # round as a follow-up, but a restart is never a follow-up -- G1 round 20.)
  # (On a change with no route the first route starts its lineage anyway, and a row left at round 3
  # would let a later plain round-1 route with another base through unrefused -- G4/G1 rounds 20-21.)
  if [ "$restart" -eq 1 ] && [ "$round" -ne 1 ]; then
    if change_has_route "$change"; then
      echo "  NOTE: --restart-lineage restarts the work, which is round 1; --round $round ignored." >&2
    else
      echo "  NOTE: --round $round ignored: the first route of '$change' is round 1." >&2
    fi
    round=1
  fi
  if [ "$round" -eq 1 ] && [ -n "$base" ] && change_has_round1 "$change" \
     && { [ "$_repeat_action" -eq 1 ] || [ "$restart" -eq 1 ] || [ "$base" != "$(change_base_commit "$change")" ]; }; then
    # A round-1 route with a DIFFERENT base starts a NEW lineage: new base, tier floor re-recorded, and every gate
    # result logged so far stops counting (it reads NOT RUN). Which of "forgot ROUND=2 after a push"
    # and "the work really restarted" it is cannot be told from the data -- two rounds of reviewers
    # kept finding a case (an open FAIL, mandated gates never run, only passes) where guessing let
    # the accident lower the floor or wipe the evidence. So it is never guessed: a restart needs
    # --restart-lineage (RESTART_LINEAGE=1 with reconcile.sh), always.
    if [ "$restart" -ne 1 ]; then
      local _g _open=""
      for _g in $(grep '"type":"gate"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$(json_escape "$change")\"" \
                  | sed -n 's/.*"gate":"\([^"]*\)".*/\1/p' | sort -u); do
        gate_fail_after_pass "$change" "$_g" && _open="${_open}${_open:+ }$_g"
      done
      echo "REFUSED: '$change' already has a round-1 route. A second one starts a NEW lineage." >&2
      echo "  That re-records the base and the tier floor and makes every gate result logged so far" >&2
      echo "  count for nothing (they read NOT RUN)${_open:+ -- including the unresolved FAIL on: $_open}." >&2
      echo "  For a follow-up on the same work use --round 2 (ROUND=2 with reconcile.sh)." >&2
      echo "  If the work really restarted, say so: --restart-lineage (RESTART_LINEAGE=1 with reconcile.sh)." >&2
      echo "  Nothing was written to $LEDGER." >&2
      exit 2
    fi
    is_restart=1
    if [ "$_repeat_action" -eq 1 ]; then
      echo "  NOTE: a declared action already fired on '$change'. This firing is a new event and starts a NEW lineage: gate results" >&2
      echo "  logged for the previous firing no longer count -- run and log the mandated gates again." >&2
    else
      echo "  NOTE: '$change' already has a round-1 route. This one starts a NEW lineage: its base and tier" >&2
      echo "  floor are re-recorded, and gate results logged so far no longer count (a G1 logged before" >&2
      echo "  this route belongs to the old lineage too -- log it again). For a follow-up use --round 2." >&2
    fi
  fi
  # A repeat firing is a new event whatever the change's earlier routes look like: the guard above only
  # fires when a round-1 route with a base exists, and a first firing kept at round 2 (follow-up of a
  # diff change, a stale ROUND=2, a baseless advisory route) leaves none -- the restart marker would
  # then never be written and the first event's passes carried over (G4 round 16). change_lineage_start
  # honours a marker on any round-1 route.
  # An explicit --restart-lineage is the same: with no round-1 route carrying a base to restart from
  # (the change's first route was logged at a stale ROUND=2) the guard above never ran and the flag
  # was dropped without a word (G4 round 18). It needs a route to restart from, and round 1.
  # A route with no base is advisory (compliance never uses it to bind gate records or set the tier
  # floor), so it cannot start a lineage either: a baseless "restart" used to take the advisory
  # route's own tier as the floor (G4 round 17). It is not marked, and the note says so.
  if [ "$restart" -eq 1 ] && [ "$is_restart" -ne 1 ] && [ "$round" -eq 1 ] \
     && { [ "$_repeat_action" -eq 1 ] || change_has_route "$change"; }; then
    if [ -n "$base" ]; then
      is_restart=1
      if [ "$_repeat_action" -eq 1 ]; then
        echo "  NOTE: a declared action already fired on '$change'. This firing is a new event and starts a NEW lineage: gate results" >&2
        echo "  logged for the previous firing no longer count -- run and log the mandated gates again." >&2
      else
        echo "  NOTE: '$change' has no round-1 route with a base. --restart-lineage starts a NEW lineage here: gate results" >&2
        echo "  logged so far no longer count -- run and log the mandated gates again." >&2
      fi
    else
      echo "  NOTE: this route has no --base, so it cannot start a new lineage (a route with no base is advisory):" >&2
      echo "  gate results logged so far STILL count. reconcile.sh --log sends a base whenever git can find a merge-base." >&2
    fi
  elif [ "$restart" -eq 1 ] && [ "$is_restart" -ne 1 ] && [ "$_repeat_action" -ne 1 ] \
       && ! change_has_route "$change"; then
    # Nothing to restart from: the first route of a change starts its lineage anyway (G6 round 19).
    echo "  NOTE: '$change' has no earlier route, so --restart-lineage has nothing to restart: this route starts the lineage." >&2
  fi
  # Write-once: rounds 2+ keep the base round 1 recorded, whatever this call computed.
  # (reconcile.sh recomputes merge-base(BASE,HEAD) every time; after a push or a merge of
  # trunk that moves, and the change's own earlier passes would fall before it.)
  if [ "$round" -gt 1 ] && [ -n "$base" ]; then
    local _prev_base; _prev_base="$(change_base_commit "$change")"
    if [ -n "$_prev_base" ] && [ "$_prev_base" != "$base" ]; then
      echo "  (base kept from round 1: ${_prev_base:0:7}; this call's ${base:0:7} ignored -- a round-1 route starts a new lineage)" >&2
      base="$_prev_base"
    fi
  fi
  if [ -z "$base" ]; then
    echo "  NOTE: no --base: this route entry is advisory. compliance will not use it to bind gate" >&2
    echo "  records or to set the tier floor -- only reconcile.sh --log writes the base that does." >&2
  fi

  # An action-based route with no evidence is exactly the unmeasured claim
  # core/04-ledger.md's evidence rule refuses everywhere else in this file
  # (finding_json's identical pairing check, above, for blocking/minor findings
  # and their location). Evidence naming no action is evidence of nothing --
  # both directions are refused, not just the one that looks dangerous.
  # reconcile.sh already enforces this pairing before it ever calls here, but
  # this file is the one thing in the kit core/04-ledger.md calls "not
  # self-graded" -- it has to hold the line on its own, not trust its caller.
  if [ -n "$action" ] && [ -z "$evidence" ]; then
    echo "REFUSED: --action '$action' with no --evidence. Nothing was written to $LEDGER." >&2
    exit 2
  fi
  if [ -z "$action" ] && [ -n "$evidence" ]; then
    echo "REFUSED: --evidence given with no --action. Evidence of what? Nothing was written." >&2
    exit 2
  fi

  local p a verdict
  p=$(tier_num "$predicted"); a=$(tier_num "$actual")
  if   [ "$a" -gt "$p" ]; then verdict="under"
  elif [ "$a" -lt "$p" ]; then verdict="over"
  else verdict="match"; fi

  # Reconcile re-runs on every commit of a multi-round change, so without these
  # two fields a change that reconciled three times leaves three identical lines
  # and no way to tell which commit each was about.
  commit="$(commit_arg "$commit" "$commit_set")" || exit 2

  # Present only when declared, rather than written as empty strings on every
  # ordinary diff-based route -- an absent field reads as "not an action route"
  # unambiguously; an empty-string field would need a second convention to mean
  # the same thing. Same conditional-block shape cmd_add already uses for
  # finding_details and withhold_breached.
  local action_json=""
  [ -n "$action" ] && action_json="$(printf ',"action":"%s","evidence":"%s"' \
    "$(json_escape "$action")" "$(json_escape "$evidence")")"

  # Free text, not an enum — "why" varies more than severity does. A suggested
  # vocabulary (Bug fix · Feature · Refactor · Hardening · Cleanup · Docs) keeps
  # it scannable without forcing a bad fit. Same fact for every round of one
  # change, so it's fine (and expected) to pass the same value each time.
  local route_summary="logged: route $change — round $round, predicted $predicted, actual $actual ($verdict)"
  [ -n "$action" ] && route_summary="$route_summary, action '$action'"
  [ -n "$base" ] && action_json="$(printf ',"base":"%s"' "$base")$action_json"
  # The marker is what makes this row a restart. Only a route that went through the refusal above
  # carries it, so a row nobody wrote with `route` (a hand-resolved merge conflict, a hand edit)
  # is not one -- unless it was copied whole from a branch where somebody did; see R-008.
  [ "$is_restart" -eq 1 ] && action_json=",\"restart\":true$action_json"
  emit "$(printf '{"type":"route","date":"%s","change":"%s","round":%s,"commit":"%s","kit":"%s","predicted":"%s","actual":"%s","verdict":"%s","reason":"%s"%s}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$change")" "$round" "$(json_escape "$commit")" \
    "$(json_escape "$(detect_kit)")" \
    "$(json_escape "$predicted")" "$(json_escape "$actual")" "$verdict" "$(json_escape "$reason")" "$action_json")" \
    "$route_summary"
}

# ---------------------------------------------------------------- escape
cmd_escape() {
  local change="" found_by="" severity="unset" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --change) _val "$1" "$#" "${2-}"; change="$2"; shift 2;;   --found-by) _val "$1" "$#" "${2-}"; found_by="$2"; shift 2;;
      --severity) _val "$1" "$#" "${2-}"; severity="$2"; shift 2;; --note) _val "$1" "$#" "${2-}"; note="$2"; shift 2;;
      *) echo "unknown option: $1" >&2; exit 2;;
    esac
  done
  [ -n "$change" ] && [ -n "$found_by" ] || {
    echo "usage: ledger.sh escape --change <original-change> --found-by user|self|monitoring" >&2
    echo "  --change is the change that INTRODUCED the defect, not the fix." >&2
    exit 2; }
  case "$found_by" in
    user|self|monitoring) ;;
    *) echo "REFUSED: --found-by '$found_by' is not one of user|self|monitoring." >&2
       echo "  The escape stats count each of those separately; any other value is counted as none." >&2
       echo "  Nothing was written to $LEDGER." >&2; exit 2;;
  esac
  change_is_branchy "$change" && refuse_branchy_change "$change"

  emit "$(printf '{"type":"escape","date":"%s","change":"%s","found_by":"%s","severity":"%s","note":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$change")" "$(json_escape "$found_by")" "$(json_escape "$severity")" "$(json_escape "$note")")" \
    "logged: escape on $change — found by $found_by"

  if ! grep -q "\"type\":\"gate\".*\"change\":\"$change\"" "$LEDGER" 2>/dev/null; then
    echo "  note: no gate runs recorded for '$change'. If it never went through the"
    echo "        pipeline this is baseline, not an escape — escape rate only means"
    echo "        something for changes that actually ran the gates."
  fi
}

# ---------------------------------------------------------------- assumptions
#
# The fourth record type, and the only one about the INPUT rather than the
# output. `core/10-probe.md`'s Checkpoint 1 already asks the right question —
# "What did they not say that I assumed? List the assumptions explicitly. This
# is where most divergence enters, and it enters silently" — and it was, until
# this command existed, the single least enforced sentence in the kit: only
# checkpoint 3 appears in the PR checklist, no gate card mentioned asking
# anything, and there was no record type that could hold the answer. An
# assumption you cannot write down is one nobody can review, count, or
# challenge later, which is this file's whole argument applied to itself.
#
# `resolution` is the field that matters, and it is why this is not just a note:
#   asked      — put to the requester, and their answer is what got built
#   verified   — not asked, but established from the code/docs (cite it in --basis)
#   defaulted  — neither. A plausible value was chosen and work continued.
#
# `defaulted` is legal on purpose. Refusing it would only teach people to log
# `verified` instead, which is the same failure with better paperwork — the
# same reasoning `05-enforcement.md` gives for keeping `--no-verify` and
# insisting it be logged. What `defaulted` does is become visible: it is what
# `compliance` refuses at T3/T4 (see cmd_compliance), and what the dashboard can
# show. An assumption logged as `defaulted` and then confirmed is logged again
# as `asked`; the pair is the audit trail, so nothing is ever edited in place.
cmd_assume() {
  local change="" round=1 assumed="" basis="" resolution="" commit="" commit_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --change) _val "$1" "$#" "${2-}"; change="$2"; shift 2;;
      --round) _val "$1" "$#" "${2-}"; round="$2"; shift 2;;
      --assumed) _val "$1" "$#" "${2-}"; assumed="$2"; shift 2;;
      --basis) _val "$1" "$#" "${2-}"; basis="$2"; shift 2;;
      --resolution) _val "$1" "$#" "${2-}"; resolution="$2"; shift 2;;
      --commit) _val "$1" "$#" "${2-}"; commit="$2"; commit_set=1; shift 2;;
      *) echo "unknown option: $1" >&2; exit 2;;
    esac
  done

  [ -n "$change" ] && [ -n "$assumed" ] && [ -n "$resolution" ] || {
    echo "usage: ledger.sh assume --change <name> --assumed '<what was filled in>' \\" >&2
    echo "                        --resolution asked|verified|defaulted [--basis '<why>'] [--round N]" >&2
    echo "" >&2
    echo "  --assumed is what the REQUESTER never said and you supplied anyway." >&2
    echo "  10-probe.md checkpoint 1: 'What did they not say that I assumed?'" >&2
    exit 2; }
  change_is_branchy "$change" && refuse_branchy_change "$change"

  case "$resolution" in
    asked|verified|defaulted) ;;
    *) echo "REFUSED: --resolution must be asked, verified, or defaulted (got '$resolution')." >&2
       echo "  These three are the whole vocabulary, the same way the four severities are." >&2
       echo "  A resolution outside them cannot be counted, so it is refused rather than stored." >&2
       exit 2;;
  esac

  # `verified` is a claim about evidence, so it carries the same bar every other
  # claim in this kit does: cite it. 12-grounding.md refuses an unsupported
  # agreement for exactly this reason — "Looks correct" without a citation is
  # indistinguishable from not having checked — and `verified` with no basis is
  # that sentence wearing a different hat.
  if [ "$resolution" = "verified" ] && [ -z "$basis" ]; then
    echo "REFUSED: --resolution verified requires --basis naming where it was verified." >&2
    echo "  An unsupported 'verified' is indistinguishable from 'defaulted' (12-grounding.md)." >&2
    exit 2
  fi

  is_uint_bounded "$round" || { echo "REFUSED: --round must be a non-negative integer (got '$round')." >&2; exit 2; }
  commit="$(commit_arg "$commit" "$commit_set")" || exit 2

  emit "$(printf '{"type":"assumption","date":"%s","change":"%s","round":%s,"commit":"%s","kit":"%s","assumed":"%s","basis":"%s","resolution":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$change")" "$round" "$(json_escape "$commit")" \
    "$(json_escape "$(detect_kit)")" "$(json_escape "$assumed")" "$(json_escape "$basis")" \
    "$(json_escape "$resolution")")" \
    "logged: assumption on $change (round $round) — $resolution"
  if [ "$resolution" = "defaulted" ]; then
    echo "  A plausible value was chosen and nobody confirmed it. This is allowed and"
    echo "  logged, not hidden — but 'compliance' REFUSES a T3/T4 change that still"
    echo "  carries it. Resolve it by asking, then log again with --resolution asked."
  fi
}

# The assumptions for a change that are still `defaulted` — i.e. nobody ever
# confirmed them. Keyed on the LAST record per distinct `assumed` text, so
# logging the same assumption again as `asked` genuinely clears it (the same
# governing-entry rule gate_latest_outcome uses for gate outcomes, rather than
# a second, differently-shaped one).
# Both extractions below were wrong in the first version, and a fresh-context
# Peer review found each producing a FALSE PASS — the one outcome this function
# exists to prevent. Fixed together because they share a cause: a JSON string
# was being read with patterns that do not understand JSON escaping.
#
#   1. `sub(/".*/, "", a)` truncated `assumed` at the first ESCAPED quote, so
#      `the \"widget\" size` and `the \"widget\" color` both keyed to `the \`.
#      Resolving one silently cleared the other. Now the value is taken up to
#      the first quote NOT preceded by a backslash, so an escaped quote stays
#      part of the text and two quoted assumptions remain distinct.
#   2. `resolution` was read with an unanchored `sub()` that simply does not
#      match on a TRUNCATED line (no `resolution` field at all — exactly what a
#      killed process or a full disk leaves behind on an append-only file). The
#      unmatched sub left `r` as the WHOLE LINE, which then overwrote the real
#      `defaulted` verdict for that same key and made the refusal vanish. Now a
#      line whose resolution cannot be read is treated as `unreadable`, which is
#      not `asked` and therefore cannot clear anything — and, because a record
#      we cannot parse is not evidence that a question was answered, it holds
#      the assumption open rather than closing it.
#
# The governing rule is unchanged and still mirrors gate_latest_outcome: the
# LAST record per distinct `assumed` text wins, because append order is time
# order.
unresolved_assumptions() {
  local change="$1"
  [ -f "$LEDGER" ] || return 0
  # The stored name is JSON-escaped, so the search key must be too (a `\` or `"` in a change name made the
  # defaulted-assumption refusal miss its own rows).
  grep '"type":"assumption"' "$LEDGER" 2>/dev/null \
    | grep -F "\"change\":\"$(json_escape "$change")\"" \
    | awk '
      # Value of a JSON string field, honouring backslash escapes: scan forward
      # from the key and stop at the first quote that is not itself escaped.
      # Returns "" when the field is absent, which the caller must distinguish
      # from a real empty value.
      # Sets JV_OK=1 only when the value was properly CLOSED by an unescaped
      # quote. Returning the text alone is not enough: round 1 of this fix
      # treated "field absent" as the only unreadable case, so a line truncated
      # INSIDE the value (…"resolution":"defaulte) returned a plausible-looking
      # string, compared unequal to "defaulted", and cleared the very record it
      # was a corrupted copy of — the identical false PASS at a different
      # truncation offset. Two independent fresh-context gates found it, and the
      # test written for round 1 passed straight over it because it only ever
      # truncated BEFORE the field.
      function jval(line, key,   i, c, out, esc) {
        JV_OK = 0
        i = index(line, "\"" key "\":\"")
        if (i == 0) return ""
        i += length(key) + 4
        out = ""; esc = 0
        for (; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (esc)          { out = out c; esc = 0; continue }
          if (c == "\\")    { out = out c; esc = 1; continue }
          if (c == "\"")    { JV_OK = 1; return out }
          out = out c
        }
        return out          # ran off the end: unterminated, JV_OK stays 0
      }
      # Undo JSON escaping for DISPLAY. Keying above happens on the escaped form
      # throughout, so this changes no comparison — but the caller prints these
      # lines and tells the user to pass the same text back to `--assume`, and
      # `--assumed '"'"'the \"widget\" size'"'"'` would be escaped a second time and match
      # nothing. What is shown has to be what you can actually retype.
      #
      # \n stays the literal two characters "backslash, n" rather than becoming
      # a real newline. Every caller of this function treats its output as ONE
      # RECORD PER LINE — `wc -l` counts unresolved assumptions, and a `sed`
      # pass turns each line into one "· " bullet. Unescaping \n into an actual
      # newline let the text of one multi-line assumption split across two
      # printed lines, so it was counted as two unresolved assumptions and
      # bulleted twice, for text that was ever written as a single --assume
      # record. \t is unaffected: a literal tab does not collide with that
      # per-line contract the way a literal newline does.
      #
      # NOTE: keep this comment block free of the single-quote character --
      # it lives inside a bash single-quoted awk script, and one quote
      # character here ends that string early, so everything after gets
      # parsed as bash instead of awk. Found the hard way.
      function junesc(s,   i, c, out, esc) {
        out = ""; esc = 0
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (esc) {
            if (c == "n") out = out "\\n"
            else if (c == "t") out = out "\t"
            else out = out c
            esc = 0; continue
          }
          if (c == "\\") { esc = 1; continue }
          out = out c
        }
        return out
      }
      {
        a = jval($0, "assumed"); a_ok = JV_OK
        # A subject we could not read in full cannot be matched against a later
        # resolving record, so it gets its own key and is reported as unreadable
        # rather than dropped. Dropping it is what "fail open" looks like here.
        if (a == "" && !a_ok) next              # field genuinely absent
        if (!a_ok) { latest["(unreadable record: " substr(a, 1, 40) "…)"] = "unreadable"; next }
        r = jval($0, "resolution"); r_ok = JV_OK
        if (!r_ok) r = "unreadable"             # absent OR never closed
        latest[a] = r
      }
      # "unreadable" is deliberately grouped with "defaulted": a record we cannot
      # parse is not evidence that anyone answered the question, and this
      # function decides whether work ships.
      END { for (a in latest) if (latest[a] == "defaulted" || latest[a] == "unreadable") print junesc(a) }
    '
}

require_ledger() {
  [ -f "$LEDGER" ] || { echo "No ledger at $LEDGER — nothing recorded yet." >&2; exit 1; }
  [ -s "$LEDGER" ] || { echo "Ledger at $LEDGER is empty. A gate with no entries did not run." >&2; exit 1; }
}

# ---------------------------------------------------------------- compliance
# The gates a tier MANDATES, read from the router. Recommended (R) ones are
# deliberately absent: this answers "was the required work done", not "was every
# optional gate considered".
required_gates_for() { matrix_required "$1" | tr '\n' ' '; }

# The LATEST round at which gate $2 recorded a PASS for change $1, or "" if never.
#
# A "skipped" entry is honest bookkeeping, not a pass — that distinction is the
# entire point of this check. Without it the pipeline is self-graded, and a
# skipped hard gate reads exactly like a cleared one at release time.
#
# Deliberately NOT restricted to the current round. Requiring every gate to
# re-pass at every round would mean a one-line fix in round 3 re-runs all six —
# which nobody does twice, so the check gets bypassed and stops meaning
# anything. The failure rule (core/02-gates.md) says return to the phase that
# produced the defect, not to the start. So an older pass counts, and the
# report says how old it is; judging whether the change since then invalidates
# it is the reviewer's call, and it is a call they can only make if they can see
# the age.
gate_passed_round() {
  gate_entries "$1" "$2" \
    | grep "\"outcome\":\"pass\"" \
    | sed -n 's/.*"round":\([0-9]*\).*/\1/p' \
    | sort -n | tail -1
}

# Where the CURRENT lineage of change $1 starts, as a 1-based line number in the ledger, or 0 when
# the change has only one lineage (so a G1 logged before the first route still counts).
#
# A lineage begins at the change's FIRST round-1 route that carries a base, and again at every route
# the tool wrote with `"restart":true` -- which `route --restart-lineage` does (and a REPEAT firing of a declared action, when the route has a base), after the
# refusal in cmd_route. A round-1 route with a different base and NO marker is not a restart: it is
# what a union merge of two branches' ledgers produces (nobody ran cmd_route for it), or a hand
# edit, and treating it as one let the merge silently drop an open FAIL (G7 round 8). It is
# ignored for lineage purposes and compliance says so. The same base again is just a re-run.
# Position, not date: the ledger is append-only. Ledgers whose routes carry no base (older ones,
# or hand-typed routes) cannot tell lineages apart: they are one lineage.
change_lineage_start() {
  local cj rows brows
  cj="$(json_escape "$1")"
  rows="$(grep -n '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$cj\"")"
  [ -n "$rows" ] || { printf '0'; return; }
  brows="$(printf '%s\n' "$rows" | grep '"base":"[0-9a-f]')"
  if [ -n "$brows" ]; then
    # Starts: the first round-1 route with a base, and every round-1 route with a base that is marked
    # restart. A marked route counts even with no earlier round-1 base route (a repeat firing of a
    # declared action on a change whose first firing was kept at round 2). A route with no base never
    # starts a lineage, marked or not: it is advisory.
    printf '%s\n' "$rows" | awk -F: '
      /"round":1,/ {
        isb = ($0 ~ /"base":"[0-9a-f]/); isr = ($0 ~ /"restart":true/)
        if (isb && (isr || !seen)) { start = $1 + 0; n++; if (isr) marked = 1 }
        if (isb) seen = 1
      }
      END { print (marked ? start : 0) }'
  else
    printf '0'
  fi
}

# Whether the change has any route at all.
change_has_route() {
  grep '"type":"route"' "$LEDGER" 2>/dev/null | grep -qF "\"change\":\"$(json_escape "$1")\""
}

# Whether the change already has a route recorded for ANY declared action (so a firing now is a
# repeat, and a new event).
change_has_any_action_route() {
  grep '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$(json_escape "$1")\"" \
    | grep -q '"action":"'
}

# The highest round of any route recorded for the change IN ITS CURRENT LINEAGE (empty when it has
# none): a restart closes the earlier lineage's rounds.
change_latest_route_round() {
  local _s; _s="$(change_lineage_start "$1")"
  grep -n '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$(json_escape "$1")\"" \
    | awk -F: -v s="$_s" '$1 + 0 >= s + 0' \
    | sed -n 's/.*"round":\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1
}

# Whether the change has a round-1 route carrying a base (a lineage to restart).
change_has_round1() {
  grep '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$(json_escape "$1")\"" \
    | grep '"round":1,' | grep -q '"base":"[0-9a-f]'
}

# Round-1 base rows of the current lineage whose base differs from the lineage's and which carry no
# restart marker (see change_lineage_start): how many.
change_unmarked_base_changes() {
  local cj ls; cj="$(json_escape "$1")"; ls="$(change_lineage_start "$1")"
  grep -n '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$cj\"" \
    | awk -F: -v s="$ls" '$1 + 0 >= s + 0' | grep '"round":1,' | grep '"base":"[0-9a-f]' \
    | awk '{ b = ""; if (match($0, /"base":"[0-9a-f]+"/)) b = substr($0, RSTART + 8, RLENGTH - 9)
             # an abbreviated spelling of the same commit is the same base (rows written before bases were full)
             if (n++ == 0) first = b; else if (index(b, first) != 1 && index(first, b) != 1 && $0 !~ /"restart":true/) c++ }
           END { print c + 0 }'
}

# The highest round with a route entry in the change's current lineage, or 1.
change_latest_round() {
  local _s _r; _s="$(change_lineage_start "$1")"
  _r="$(awk -v s="$_s" 'NR > s' "$LEDGER" 2>/dev/null | grep '"type":"route"' \
        | grep -F "\"change\":\"$(json_escape "$1")\"" \
        | sed -n 's/.*"round":\([0-9]*\),.*/\1/p' | sort -n | tail -1)"
  printf '%s' "${_r:-1}"
}

# Entries for one change+gate in the current lineage, whatever their outcome.
gate_entries() {
  local _s; _s="$(change_lineage_start "$1")"
  awk -v s="$_s" 'NR > s' "$LEDGER" 2>/dev/null \
    | grep "\"type\":\"gate\"" \
    | grep -F "\"change\":\"$(json_escape "$1")\"" \
    | grep -F "\"gate\":\"$2\""
}

gate_has_outcome() { gate_entries "$1" "$2" | grep -q "\"outcome\":\"$3\""; }

# The highest ROUND at which this (change, gate) has ANY entry, or "" if none.
# Same convention gate_passed_round already uses for "latest" — a round number,
# not file position.
gate_latest_round() {
  gate_entries "$1" "$2" \
    | sed -n 's/.*"round":\([0-9]*\).*/\1/p' \
    | sort -n | tail -1
}

# The outcome that actually governs this (change, gate) right now: the
# chronologically LAST entry logged at its highest round.
#
# `gate_has_outcome` used to answer "was this outcome EVER logged" — true
# forever once written, because the ledger is append-only. A `skipped` placeholder
# from an aborted attempt then outranked a real `fail` logged straight after it,
# at the same round, because both entries "existed" and grep does not know which
# came later. Restricting to the highest round and then taking the last line
# within it fixes that without inventing a second notion of "latest": it is the
# same "highest round" idea `gate_passed_round` already applies to `pass`,
# generalized to whichever outcome was actually logged there most recently.
gate_latest_outcome() {
  local r; r="$(gate_latest_round "$1" "$2")"
  [ -n "$r" ] || { printf ''; return; }
  gate_entries "$1" "$2" | grep "\"round\":$r," | tail -1 \
    | sed -n 's/.*"outcome":"\([^"]*\)".*/\1/p'
}

# Whether a `fail` was logged AFTER the latest `pass` for (change $1, gate $2). "After" is
# POSITION in the ledger (append order), not round number: --round defaults to 1, so a fail logged
# with the flag forgotten sat below an earlier round-2 pass and was ignored (G7 round 11). A fail
# positioned after a pass is open whatever round it carries; a retro-logged lower round fails
# closed, which is the safe direction for a gate. Only a later pass clears it: not `skipped`, not `n/a`, not silence. A `skipped` that follows a fail is precisely what
# the pre-push hook's override advice produces, and judging by the LATEST outcome alone let it
# bring the older pass back as PASS* on a gate that last failed (found by four reviewers).
# `skipped` after a PASS is a different case and stays harmless: it records an exception and
# must not revoke evidence that exists.
gate_fail_after_pass() {
  gate_entries "$1" "$2" | awk '
    { k = NR
      if ($0 ~ /"outcome":"pass"/ && k > p) p = k
      if ($0 ~ /"outcome":"fail"/ && k > f) f = k }
    END { exit !(f > p && f > 0) }'
}

# The finding count on the last `fail` entry (by position), for the FAIL row
# when a later `skipped` means the latest entry no longer carries it.
gate_last_fail_findings() {
  gate_entries "$1" "$2" | grep '"outcome":"fail"' | awk '
    { line = $0 }
    END { print line }' | sed -n 's/.*"findings":\([0-9]*\).*/\1/p'
}

# The finding count on that same latest entry, for reporting alongside `fail`.
gate_latest_findings() {
  local r; r="$(gate_latest_round "$1" "$2")"
  [ -n "$r" ] || { printf '0'; return; }
  gate_entries "$1" "$2" | grep "\"round\":$r," | tail -1 \
    | sed -n 's/.*"findings":\([0-9]*\).*/\1/p'
}

# The reason attached to an outcome. An `n/a` with no note is a bare assertion,
# and the whole value of allowing one is that it carries the reason with it.
gate_outcome_note() {
  local n
  n="$(gate_entries "$1" "$2" | grep "\"outcome\":\"$3\"" | tail -1 \
       | sed -n 's/.*"note":"\([^"]*\)".*/\1/p')"
  [ -n "$n" ] && printf '%s' "$n" || printf 'no reason recorded'
}

# Whether that same latest entry actually carries a non-empty note, as opposed
# to gate_outcome_note's "no reason recorded" placeholder, which is display text
# for a human and not safe to test equality against (a real note could
# coincidentally be that exact string). cmd_add only WARNS on `--outcome n/a`
# with no `--note` — a warning is easy to miss and this file's header says n/a
# "is only honoured by compliance where the router's own cell carries a
# footnote, and it needs a reason". Nothing enforced that; compliance accepted
# a bare n/a the same as a reasoned one, silently, as long as the cell was
# conditional.
gate_outcome_has_reason() {
  gate_entries "$1" "$2" | grep "\"outcome\":\"$3\"" | tail -1 | grep -q '"note":"[^"]'
}

# Whether ANY record of WHY this change exists is on the ledger at all: a
# route --reason (tools/reconcile.sh's REASON= env var) or ROUND 1's G1
# entry's --note (mandatory at T3+, and core/cards/G1-intent.md already
# exists to collect exactly this: "who is this for, what does done mean").
# Either is sufficient — this does not care which, only that one is on
# record.
#
# G1 is scoped to round 1 specifically, not "any G1 entry ever" — matching
# tools/dashboard/app.js's whyThisRan(), which reads only cg.rounds[0]'s G1
# note, deliberately: a change compliance calls compliant must be a change
# the dashboard can actually explain, not a second definition of "recorded"
# that can disagree with the first. An earlier, unscoped version checked
# every G1 entry regardless of round: a throwaway --note on a discarded
# round-1 attempt (or one attached to a LATER round the dashboard never
# reads) then satisfied this check permanently, even once the entry that
# actually governs the mandate carried no reason at all — the exact
# silently-degraded signal this check exists to catch, just moved one layer
# down. Unlike gate_outcome_has_reason() (which filters to a specific
# OUTCOME on the latest round, because it answers whether a governing verdict
# was reasoned), this deliberately does NOT filter by outcome — the "why"
# question does not care whether G1 passed or failed, only whether round 1
# said anything, same as whyThisRan().
change_has_recorded_reason() {
  local _ls; _ls="$(change_lineage_start "$1")"
  grep -n '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$(json_escape "$1")\"" \
    | awk -F: -v s="$_ls" '$1 + 0 >= s + 0' \
    | grep -q '"reason":"[^"]' && return 0
  gate_entries "$1" "G1" | grep '"round":1,' | grep -q '"note":"[^"]'
}

# Which kit builds produced this change's entries, other than the one running now.
# This SHOWS staleness and stops there, on purpose. The obvious next step — skipping
# a gate whose recorded artifact and tooling are byte-identical — is refused: it would
# have skipped the second round of the first real run, and both re-runs found new,
# real bugs in the first round's fixes. The kit already made this call once, for the
# same question, in gate_passed_round: an older verdict counts, and its age is
# visible, and whether the age invalidates it is the reviewer's judgment, not the
# tool's. A hash is a better staleness signal than a round number. It is not a
# licence to decide.
kit_builds_seen() {
  grep "\"type\":\"gate\"" "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$(json_escape "$1")\"" \
    | sed -n 's/.*"kit":"\([^"]*\)".*/\1/p' | sort -u
}

# The tier floor for change $1, or "". Within the current lineage it is the HIGHEST tier any
# reconcile-written row recorded (a later round re-diffed against a moved base sees a narrower
# diff, which is not a smaller change). A real downgrade is a new round-1 reconcile, which
# starts a new lineage -- and cmd_route refuses that unless --restart-lineage says it is deliberate. Without
# reconcile-written rows (older or hand-typed ledgers) the latest entry governs, the rule the
# dashboard uses for actualTier.
#
# Entries that carry a `base` are the ones reconcile.sh wrote (it derives the tier
# from the diff). A bare `ledger.sh route --actual T1` typed by hand has no diff
# behind it, so when ANY reconcile-written entry exists only those are considered;
# otherwise (older ledgers) every entry is. `--base` can be typed by hand too: this
# stops an accident, not a forger -- see project/risks.md R-008.
#
# The name is matched the way it is STORED (JSON-escaped), or a name containing a
# double quote never matched and silently skipped the floor.
change_reconciled_tier() {
  local cj rows brows r
  cj="$(json_escape "$1")"
  # Only the CURRENT lineage (change_lineage_start): a reused change name, or a round-1 reconcile
  # after the base moved, restarts, so rows before it belong to an older piece of work. Taking the
  # highest round across all lineages let an old T1 at round 3 outrank a new T4 at round 1.
  local ls; ls="$(change_lineage_start "$1")"
  rows="$(grep -n '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$cj\"" \
          | awk -F: -v s="$ls" '$1 + 0 >= s + 0' | sed 's/^[0-9]*://')"
  [ -n "$rows" ] || return 0
  brows="$(printf '%s\n' "$rows" | grep '"base":"[0-9a-f]')"
  [ -n "$brows" ] && rows="$brows"
  if [ -n "$brows" ]; then
    # Reconcile-written rows: the floor is the HIGHEST tier any of them recorded. A later round
    # re-diffed against a moved base (after a push) sees only the newest edit -- a narrower diff
    # is not a smaller change -- and "the latest governs" let that lower the floor while a gate
    # was still failing (G1 round 5). A real downgrade is a deliberate act: a new round-1
    # reconcile starts a new lineage.
    local best="" bn=-1 t
    for t in $(printf '%s\n' "$rows" | sed -n 's/.*"actual":"\(T[0-4]\)".*/\1/p'); do
      [ "$(tier_num "$t")" -gt "$bn" ] && { best="$t"; bn="$(tier_num "$t")"; }
    done
    printf '%s' "$best"
    return 0
  fi
  # No reconcile-written rows (older or hand-typed ledgers): nothing authoritative, so the
  # latest entry (highest round, last line within it) is used, as before.
  r="$(printf '%s\n' "$rows" | sed -n 's/.*"round":\([0-9]*\).*/\1/p' | sort -n | tail -1)"
  printf '%s\n' "$rows" | grep "\"round\":$r," | tail -1 \
    | sed -n 's/.*"actual":"\(T[0-4]\)".*/\1/p'
}

# E3: a gate record must belong to THIS change's commits, not merely carry its
# name. The change's base is the commit it started from, recorded on its route
# entry by reconcile.sh (--base). It is RECORDED, not re-derived from trunk: trunk
# moves, and once the branch is merged the merge-base collapses onto the change's
# own tip, which turned every earlier pass "unbound" after the merge. It is WRITE-ONCE
# per lineage: recorded at round 1 and carried unchanged by rounds 2+ (re-deriving it on
# every reconcile moved it up on every push and merge, un-binding the change's own earlier
# passes). A reused change name restarts at round 1 and gets a fresh base. Empty when no
# entry has one (old entries, or `route` called without --base) -- the caller then says
# so rather than guessing.
#
# Not strict at the base: a pass logged AT the base commit still counts, because
# that is also exactly where pre-build work (G1 runs before the first commit)
# legitimately lands, and the two cannot be told apart.
change_base_commit() {
  local cj rows r1
  cj="$(json_escape "$1")"
  rows="$(grep '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$cj\"" | grep '"base":"[0-9a-f]')"
  [ -n "$rows" ] || return 0
  # The row that started the current lineage: the latest restart-marked round-1 row, else the first
  # round-1 row (change_lineage_start). Later rounds carry its base forward unchanged (cmd_route),
  # and a round-1 row with another base but no marker (a merged branch's) does not move it.
  r1="$(printf '%s\n' "$rows" | grep '"round":1,')"
  if [ -n "$r1" ]; then
    local _rm; _rm="$(printf '%s\n' "$r1" | grep '"restart":true' | tail -1)"
    if [ -n "$_rm" ]; then r1="$_rm"; else r1="$(printf '%s\n' "$r1" | head -1)"; fi
  else
    r1="$(printf '%s\n' "$rows" | head -1)"
  fi
  local _b _bf
  _b="$(printf '%s\n' "$r1" | sed -n 's/.*"base":"\([0-9a-f]*\)".*/\1/p')"
  # A row written before bases were stored in full may hold an abbreviation: return the full sha, so
  # every comparison against a (now always full) --base is like for like. One that does not resolve
  # (object missing, ambiguous) returns NOTHING: never the raw string, which a ref of that name would
  # resolve (G4 round 24); compliance reports "cannot be checked".
  [ -n "$_b" ] || return 0
  _bf="$(resolve_commit "$_b")" || return 0
  printf '%s\n' "$_bf"
}

# The tips a pass may legitimately sit under: the commit checked out now plus the
# commit each of this change's reconciliations ran at. The base is a LOWER bound
# (nothing before the change); this is the UPPER one -- a pass on a sibling branch
# cut from the same fork point descends from the base but is under none of these.
change_tips() {
  local cj ls; cj="$(json_escape "$1")"; ls="$(change_lineage_start "$1")"
  # Each route's stored commit may be an abbreviation (rows written before round 26): resolved as an object, and dropped
  # when it does not resolve -- the raw string would be read as a ref name (G7/G4 round 24).
  { git rev-parse HEAD 2>/dev/null
    local _tc
    for _tc in $(grep -n '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$cj\"" \
      | awk -F: -v s="$ls" '$1 + 0 >= s + 0' \
      | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p' | sort -u); do
      resolve_commit "$_tc" || true
    done
  } | grep . | sort -u
}

# The commit recorded on the pass that gate_passed_round $3 found: the last
# `pass` entry logged at that round.
gate_pass_commit() {
  gate_entries "$1" "$2" | grep '"outcome":"pass"' | grep "\"round\":$3," | tail -1 \
    | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p'
}

# The commits of every pass logged AFTER the last fail (by ledger position), one per line; "-" for a
# pass that recorded none. Empty when the gate has no fail. A fail is cleared by a later pass, so it
# is THAT pass that has to be bound to the change as well as the highest-round pass (a round-1 pass
# logged last on another branch used to clear a round-2 fail unchecked; checking only the clearing
# pass let a higher-round pass outside the change through). Output: "round:commit" per pass.
gate_pass_commits_after_fail() {
  gate_entries "$1" "$2" | awk '
    { l[NR] = $0; if ($0 ~ /"outcome":"fail"/) f = NR }
    END { for (i = f + 1; i <= NR; i++) if (f > 0 && l[i] ~ /"outcome":"pass"/) {
            r = "1"; if (match(l[i], /"round":[0-9]+/)) r = substr(l[i], RSTART + 8, RLENGTH - 8)
            c = "-"; if (match(l[i], /"commit":"[^"]*"/)) { c = substr(l[i], RSTART + 10, RLENGTH - 11); if (c == "") c = "-" }
            print r ":" c } }'
}

# 0 = bound, 1 = the entry's commit predates or sits outside the change,
# 2 = cannot be checked (no base recorded, no commit on the entry, a value that is
# not a hex sha, or a commit that is not in this clone). The caller says so for 2
# instead of treating it as a quiet pass.
# EVERY string that reaches git below goes through resolve_commit (lib/commit.sh) first: the entry's
# commit, the base and each tip may be stored abbreviations (rows before round 26), and git reads a ref name of the same spelling
# before an abbreviated object (G7/G4 rounds 23 and 24).
commit_bound_to_change() {
  local base="$1" c="$2" tips="$3" t _rc
  [ -n "$base" ] && [ -n "$c" ] || return 2
  # An ambiguous prefix (two commits share it) cannot be said to lie inside the change: UNBOUND, not a
  # quiet "cannot be checked".
  c="$(resolve_commit "$c")"; _rc=$?
  [ "$_rc" -eq 2 ] && return 1
  [ "$_rc" -eq 0 ] || return 2
  # $base and $tips come from change_base_commit and change_tips, which return FULL shas already
  # resolved as objects (or nothing): resolving them again per gate was a spawn each, for nothing.
  git merge-base --is-ancestor "$base" "$c" 2>/dev/null || return 1
  [ -n "$tips" ] || return 0
  for t in $tips; do
    git merge-base --is-ancestor "$c" "$t" 2>/dev/null && return 0
  done
  return 1
}

cmd_compliance() {
  local change="" tier="" round=1 round_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --change|--tier|--round)
        case "${2-}" in
          '') echo "REFUSED: $1 needs a value (got nothing)." >&2; exit 2;;
          *[!a-z-]*) ;;
          --[a-z]*) echo "REFUSED: $1 needs a value (got the option '${2-}')." >&2; exit 2;;
        esac ;;
    esac
    case "$1" in
      --change) change="$2"; shift 2;; --tier) tier="$2"; shift 2;;
      --round) round="$2"; round_set=1; shift 2;;
      *) echo "unknown option: $1" >&2; exit 2;;
    esac
  done
  [ -n "$change" ] && [ -n "$tier" ] || {
    echo "usage: ledger.sh compliance --change <name> --tier <T1..T4> [--round N]" >&2; exit 2; }

  # Without --round the check is about where the change IS: the latest round of its current
  # lineage, not round 1. Defaulting to 1 reported "satisfied at round 1" for a change whose round 1
  # failed and whose round 2 passed (G8 round 7), and PASS* wording hid how stale a pass was.
  [ "$round_set" -eq 1 ] || round="$(change_latest_round "$change")"
  if [ "$round_set" -eq 1 ]; then
    is_uint_bounded "$round" || { echo "REFUSED: --round must be a non-negative integer (got '$round')." >&2; exit 2; }
  else
    is_uint "$round" || round=1
  fi

  # An unrecognised tier must never reach the "mandates no gates" branch below.
  #
  # Found by a fresh-context Dogfood run that simply typed the tier wrong:
  # `--tier t4` and `--tier T44` printed "Tier t4 mandates no gates. Nothing to
  # check." and exited 0, while `--tier T4` on the same change exited 1. One
  # wrong character turned the release check green — in the one command this
  # kit says is "not self-graded", and whose entire job is to answer whether a
  # change may ship. `matrix_required` correctly returns nothing for a tier
  # that is not in the router's table, and "nothing required" was then read as
  # "nothing to worry about"; the two are only the same for a tier that really
  # exists. `reconcile.sh` has guarded exactly this since an earlier round
  # (`case "$PREDICTED" in ''|T0|T1|T2|T3|T4)`) — the asymmetry between the two
  # entry points is what let this survive here. Exit 2 (usage error), matching
  # that guard and every other REFUSED in this file, never 0.
  case "$tier" in
    T0|T1|T2|T3|T4) ;;
    *)
      echo "REFUSED: tier '$tier' is not one of T0..T4." >&2
      echo "  Refusing rather than reporting 'nothing to check': an unrecognised tier" >&2
      echo "  mandates no gates for the same reason a typo does, and this command decides" >&2
      echo "  whether a change ships. Tiers are case-sensitive — 't4' is not 'T4'." >&2
      exit 2;;
  esac

  # matrix_required returns empty both when a tier genuinely mandates nothing
  # and when the router could not be read at all (see lib/matrix.sh's
  # _matrix_load) — required_gates_for below throws that distinction away, so
  # check it here first. A DIRECT call, not one wrapped in $(...): a subshell's
  # write to the cache dies with it (see cmd_gates above), and this call needs
  # its real, current-process exit status, not a forked copy's.
  if ! _matrix_load; then
    echo "REFUSED: the gate matrix could not be read — see the error above." >&2
    echo "  Compliance cannot tell 'nothing is mandated' from 'the router that says" >&2
    echo "  what is mandated is missing or broken', and reporting the former when the" >&2
    echo "  truth is the latter is the exact confident-wrong-answer this command exists" >&2
    echo "  to prevent. Fix the router, or point MATRIX_ROUTER at a good copy." >&2
    exit 2
  fi

  # --tier is a claim, not a fact: `--tier T1` on a change reconciled as T4
  # mandates nothing and exits 0 (E2). The tier reconcile recorded for this
  # change is the floor; asking about a lower one is refused, a higher one is
  # just stricter. No route entry means the tier cannot be checked -- said, not hidden.
  local rec_tier; rec_tier="$(change_reconciled_tier "$change")"
  if [ -n "$rec_tier" ]; then
    if [ "$(tier_num "$tier")" -lt "$(tier_num "$rec_tier")" ]; then
      echo "REFUSED: --tier $tier is below the tier this change was reconciled at ($rec_tier)." >&2
      echo "  The floor for '$change' is $rec_tier: the highest tier any reconcile.sh round recorded for" >&2
      echo "  its current lineage (a hand-typed 'ledger.sh route' without --base does not lower it)." >&2
      echo "  Checking it as $tier would drop gates that tier mandates. Re-run with --tier $rec_tier." >&2
      echo "  A later round cannot lower the floor. Only a new lineage can: a round-1 route that carries a" >&2
      echo "  base (reconcile.sh, or a hand-typed 'route --base') and says --restart-lineage on purpose" >&2
      echo "  (README step 6). That is the same authority as reconcile.sh -- say it only when the work restarted." >&2
      exit 2
    fi
  else
    echo "  NOTE: no reconciliation on record for '$change' -- --tier $tier is taken on trust." >&2
  fi

  local req; req="$(required_gates_for "$tier")"
  if [ -z "$req" ]; then
    echo "Tier $tier mandates no gates. Nothing to check."
    exit 0
  fi

  echo "Gate compliance — $change, tier $tier, round $round"
  echo "-------------------------------------------------------"

  # Provenance first, because it decides whether the rest of this report can be
  # believed. A stale installed copy once reported gates as SKIPPED that had
  # actually FAILED; it was caught because the output disagreed with someone's
  # memory, which is not a control.
  local now_kit seen other
  now_kit="$(detect_kit)"
  seen="$(kit_builds_seen "$change")"
  other="$(printf '%s\n' "$seen" | grep -v "^$now_kit$" | grep -v '^$')"
  if [ -n "$other" ]; then
    echo "  KIT DRIFT  entries for this change were written by a different build than"
    echo "             the one reporting now ($now_kit):"
    printf '               %s\n' $other
    echo "             The verdicts below were produced by tooling that has since changed."
    echo "             Decide per gate whether what it checked still means the same thing."
    echo
  fi

  local base_commit; base_commit="$(change_base_commit "$change")"
  local tips; tips="$(change_tips "$change")"
  local _unmarked; _unmarked="$(change_unmarked_base_changes "$change")"
  [ "${_unmarked:-0}" -gt 0 ] && echo "  NOTE: '$change' has $_unmarked round-1 route(s) with a base other than the lineage's and no restart marker (merged branches, or a hand-edited ledger). They are NOT treated as a restart; passes outside the lineage base read UNBOUND." >&2
  if [ -z "$base_commit" ]; then
    if grep '"type":"route"' "$LEDGER" 2>/dev/null | grep -F "\"change\":\"$(json_escape "$change")\"" | grep -q '"base":"[0-9a-f]'; then
      echo "  NOTE: the base commit recorded for '$change' does not resolve to one commit in this clone (missing, or an ambiguous abbreviation) -- gate records are not checked against its commits." >&2
    else
      echo "  NOTE: no base commit is recorded for '$change' (its route entry predates --base) -- gate records are not checked against its commits." >&2
    fi
  fi
  local missing="" n_missing=0 n_stale=0 n_na=0 n_unverified=0
  for g in $req; do
    local passed_at; passed_at="$(gate_passed_round "$change" "$g")"
    # An older pass counts (see gate_passed_round) -- but not over a LATER fail.
    # The failure rule sends a failed gate back to be re-run to a pass; until
    # that happens the fail is what governs, however many earlier rounds passed.
    # Without this, a round-2 G7 FAIL still exited 0 behind a round-1 PASS (E1).
    # A FAIL logged after the pass voids it, whatever was logged after that fail. A
    # `skipped` after a PASS does not: the pre-push hook's override advice has people log
    # one after a real pass, and reading that as "the gate no longer passes" re-failed
    # released changes (14 records in this repo's own ledger). `skipped` records an
    # exception; it never turns a pass into a non-pass, and never hides a fail either.
    local _voided=0
    if [ -n "$passed_at" ] && gate_fail_after_pass "$change" "$g"; then
      passed_at=""; _voided=1
    fi
    local _bound=0 _pc="" _pr=""
    if [ -n "$passed_at" ]; then
      _pr="$passed_at"
      _pc="$(gate_pass_commit "$change" "$g" "$passed_at")"
      commit_bound_to_change "$base_commit" "$_pc" "$tips"; _bound=$?
      # A fail precedes: the pass logged after it is what cleared it, and THAT has to be bound too
      # (any one of them: a re-run on the change's commits is a real re-run). Both checks must hold;
      # unbound beats unverifiable beats bound.
      if [ "$_bound" -ne 1 ] && gate_has_outcome "$change" "$g" fail; then
        local _t _cr _cc _cb _seen=0 _best=0 _fr="" _fc="" _ur="" _uc=""
        for _t in $(gate_pass_commits_after_fail "$change" "$g"); do
          _cr="${_t%%:*}"; _cc="${_t#*:}"
          if [ "$_seen" -eq 0 ]; then _fr="$_cr"; _fc="$_cc"; _best=1; fi
          _seen=1
          commit_bound_to_change "$base_commit" "$_cc" "$tips"; _cb=$?
          if [ "$_cb" -eq 0 ]; then _best=0; break; fi
          if [ "$_cb" -eq 2 ]; then _best=2; _ur="$_cr"; _uc="$_cc"; fi
        done
        if [ "$_seen" -eq 1 ] && [ "$_best" -eq 1 ]; then _bound=1; _pc="$_fc"; _pr="$_fr"
        elif [ "$_best" -eq 2 ] && [ "$_bound" -eq 0 ]; then _bound=2; _pc="$_uc"; _pr="$_ur"; fi
      fi
    fi
    [ "$_bound" -eq 2 ] && [ -n "$passed_at" ] && n_unverified=$((n_unverified + 1))
    if [ "$_bound" -eq 2 ] && [ -n "$base_commit" ]; then
      printf "  NOTE       %-4s pass commit '%s' is not checkable here (none recorded, or not a commit in this clone) -- binding not verified\n" \
        "$g" "$_pc"
    fi
    if [ "$_bound" -eq 1 ]; then
      printf "  UNBOUND    %-4s %-9s pass at round %s was logged at %s, outside this change (base %s)\n" \
        "$g" "$(gate_name "$g")" "$_pr" "$_pc" "$base_commit"
      printf "             Re-run the gate on this change's commits and log it again.\n"
      missing="${missing}${missing:+ }$g"
      n_missing=$((n_missing + 1))
      continue
    fi
    if [ -n "$passed_at" ]; then
      if [ "$passed_at" -lt "$round" ]; then
        printf "  PASS*      %-4s %-9s passed at round %s — %s round(s) of changes since\n" \
          "$g" "$(gate_name "$g")" "$passed_at" "$((round - passed_at))"
        n_stale=$((n_stale + 1))
      else
        printf "  PASS       %-4s %s\n" "$g" "$(gate_name "$g")"
      fi
      continue
    fi

    # From here on, `pass` (any round) has already been ruled out above, so
    # what governs this gate is whichever outcome the LATEST round's LATEST
    # entry actually recorded — not "was this outcome ever logged" (see
    # gate_latest_outcome).
    local latest; latest="$(gate_latest_outcome "$change" "$g")"
    # A fail positioned after the last pass (or with no pass at all) governs whatever came after it
    # by round: an `n/a` or `skipped` logged later must not clear it, and a fail logged with --round
    # forgotten must not lose to a higher-round n/a (G6 round 12). Same rule as the voided-pass path.
    if [ "$latest" != "fail" ] && gate_fail_after_pass "$change" "$g"; then latest="fail"; _voided=1; fi

    # An `n/a` entry says the gate's own card does not fire here. That is only
    # available where the matrix itself says so — a cell carrying a footnote,
    # like G8's `M⁵` ("skip only when Axis C is Invisible"). Whoever logged it
    # had to name a reason in the ledger, which is the difference between a
    # judgment call and a gap: one is on the record, the other is missing data.
    if [ "$latest" = "n/a" ]; then
      if matrix_is_conditional "$g" "$tier"; then
        if gate_outcome_has_reason "$change" "$g" "n/a"; then
          printf "  N/A        %-4s %-9s %s\n" "$g" "$(gate_name "$g")" \
            "does not fire here — $(gate_outcome_note "$change" "$g" "n/a")"
          n_na=$((n_na + 1))
          continue
        fi
        printf "  REFUSED    %-4s %-9s logged n/a with no reason — the n/a rule requires one\n" \
          "$g" "$(gate_name "$g")"
        printf "             ledger.sh add --change %s --gate %s --tier %s --outcome n/a --note '<why>'\n" \
          "$change" "$g" "$tier"
        missing="${missing}${missing:+ }$g"
        n_missing=$((n_missing + 1))
        continue
      fi
      printf "  REFUSED    %-4s %-9s logged n/a, but %s is mandatory at %s with no condition\n" \
        "$g" "$(gate_name "$g")" "$g" "$tier"
      missing="${missing}${missing:+ }$g"
      n_missing=$((n_missing + 1))
      continue
    fi

    # A gate that ran, produced real findings, and correctly logged `--outcome
    # fail` is not "no verdict" — it is the single most important verdict a
    # gate can return, and it is not a satisfied mandate either. The failure
    # rule (core/02-gates.md) requires the gate re-run to a pass before release;
    # a fail counts toward n_missing exactly like NOT RUN and SKIPPED do.
    if [ "$latest" = "fail" ] || [ "$_voided" -eq 1 ]; then
      printf "  FAIL       %-4s %-9s %s finding(s) logged — re-run required before release\n" \
        "$g" "$(gate_name "$g")" "$(gate_last_fail_findings "$change" "$g")"
      missing="${missing}${missing:+ }$g"
      n_missing=$((n_missing + 1))
      continue
    fi

    # Distinguish "ran and was skipped" from "never ran at all" from "the matrix
    # cannot tell without a fact only you have" — three different failures with
    # three different fixes.
    local state="NOT RUN"
    [ "$latest" = "skipped" ] && state="SKIPPED"
    if [ "$state" = "NOT RUN" ] && matrix_is_conditional "$g" "$tier"; then
      printf "  UNRESOLVED %-4s %s\n" "$g" "$(gate_name "$g")"
      printf "           %s says:%s\n" "$(matrix_cell "$g" "$tier")" \
        "$(matrix_footnote "$(matrix_marker "$g" "$tier")")"
      printf "           Run it, or log why it does not fire:\n"
      printf "           ledger.sh add --change %s --gate %s --tier %s --outcome n/a --note '<why>'\n" \
        "$change" "$g" "$tier"
    else
      printf "  %-10s %-4s %s\n" "$state" "$g" "$(gate_name "$g")"
    fi
    missing="${missing}${missing:+ }$g"
    n_missing=$((n_missing + 1))
  done

  # Recommended-with-a-footnote. The footnote can promote these to mandatory in
  # a circumstance the matrix cannot see, so they are named — but R means
  # recommended, and inventing a mandate the router did not write is the same
  # error in the other direction.
  local cond; cond="$(matrix_conditional "$tier")"
  if [ -n "$cond" ]; then
    echo
    echo "  Recommended here, mandatory if the footnote applies — your call:"
    for g in $cond; do
      # A gate you already reasoned about and logged is not the same as one you
      # never touched — printing the generic "your call" CHECK line for both
      # made a gate with a real, reasoned `n/a` on record look byte-identical to
      # one nobody ever looked at. Show what was logged instead, when anything was.
      if gate_entries "$change" "$g" | grep -q .; then
        local o; o="$(gate_latest_outcome "$change" "$g")"
        if gate_fail_after_pass "$change" "$g"; then o="fail"
        elif [ -n "$(gate_passed_round "$change" "$g")" ]; then o="pass"; fi
        case "$o" in
          n/a)
            printf "    LOGGED %-4s %-9s n/a — %s\n" "$g" "$(gate_name "$g")" \
              "$(gate_outcome_note "$change" "$g" "n/a")";;
          pass)
            printf "    LOGGED %-4s %-9s pass recorded\n" "$g" "$(gate_name "$g")";;
          fail)
            printf "    LOGGED %-4s %-9s fail — %s finding(s) recorded\n" "$g" "$(gate_name "$g")" \
              "$(gate_last_fail_findings "$change" "$g")";;
          skipped)
            printf "    LOGGED %-4s %-9s skipped\n" "$g" "$(gate_name "$g")";;
          *)
            # Unknown/unset outcome on record — fall back to the generic prompt.
            printf "    CHECK  %-4s %-9s %s%s\n" "$g" "$(gate_name "$g")" \
              "$(matrix_cell "$g" "$tier")" \
              "$(matrix_footnote "$(matrix_marker "$g" "$tier")" | cut -c1-64)";;
        esac
        continue
      fi
      # Truncated on purpose — this is a list to scan, not a question to answer.
      # The unabridged footnote appears where it is actually needed, on the
      # UNRESOLVED line above.
      printf "    CHECK  %-4s %-9s %s%s\n" "$g" "$(gate_name "$g")" \
        "$(matrix_cell "$g" "$tier")" \
        "$(matrix_footnote "$(matrix_marker "$g" "$tier")" | cut -c1-64)"
    done
  fi
  echo

  # Unconfirmed assumptions, at T3/T4 only.
  #
  # A gate verifies the thing that was built against the spec it was handed. If
  # a value in that spec was invented rather than asked for, every gate below
  # can pass while verifying the wrong thing — the whole run confirms a premise
  # nobody ever agreed to. That is not a gate failure, so none of the checks
  # above can see it; it is an input failure, and this is the only place that
  # looks at inputs.
  #
  # T3/T4 only, and deliberately: 10-probe.md's own table says to decide
  # yourself when a conventional default exists and the answer changes only the
  # implementation. Refusing every defaulted assumption at every tier would make
  # T1 typo fixes ask permission to exist, which is how a rule gets routed
  # around. At T3+ the definition has already changed — "one change, many
  # consumers" and "a wrong answer here is silent and confident" — so an
  # invented premise is exactly the thing the tier exists to catch.
  local unresolved n_unresolved=0
  unresolved="$(unresolved_assumptions "$change")"
  if [ -n "$unresolved" ]; then
    n_unresolved="$(printf '%s\n' "$unresolved" | sed '/^$/d' | wc -l | tr -d ' ')"
  fi
  local tier_n; tier_n="$(printf '%s' "${tier#T}")"
  if [ "$n_unresolved" -gt 0 ] && is_uint "$tier_n" && [ "$tier_n" -ge 3 ]; then
    echo "UNCONFIRMED — $n_unresolved assumption(s) on this change were never put to the requester:"
    printf '%s\n' "$unresolved" | sed '/^$/d' | sed 's/^/    · /'
    echo
    echo "  Every gate above can pass while verifying a premise nobody agreed to."
    echo "  At $tier that is what the tier exists to catch, so it is refused here"
    echo "  rather than noticed after release."
    echo
    echo "  Ask, then record the answer:"
    echo "    bash tools/ledger.sh assume --change $change --assumed '<the same text>' \\"
    echo "         --resolution asked --basis '<what they said>'"
    echo
    echo "  Or, if it was established from the code rather than asked:"
    echo "    ... --resolution verified --basis '<file:line that settles it>'"
    exit 1
  fi

  if [ "$n_missing" -eq 0 ]; then
    # A missing "why" is the same shape of problem as the assumption check
    # above: a silently-degraded signal that looks fine until someone
    # actually needs it. Checked here, inside "every mandated gate passed",
    # rather than alongside the assumption check above it: an incomplete
    # gate list is already the more specific, more actionable problem (see
    # INCOMPLETE below), and this must not mask it behind a different
    # REFUSED for a change that has not even finished its gates yet. This is
    # the actual bar for "release-ready", not a precondition for reporting
    # gate status at all.
    #
    # reconcile.sh's REASON= is optional by design, and G1's note is easy to
    # log against the wrong question when the gate is run quickly — every
    # gate above can still pass while the record of why this change exists
    # does not exist at all. At T3/T4 ("one change, many consumers" / "a
    # wrong answer here is silent and confident") that gap is what the tier
    # exists to catch. Below T3, REASON= stays genuinely optional — this
    # does not retroactively demand one from every T1 typo fix. See
    # tools/dashboard/app.js's whyThisRan(), which reads the same two
    # fields in the same order: a change compliance calls compliant must be
    # a change the dashboard can actually explain.
    if is_uint "$tier_n" && [ "$tier_n" -ge 3 ] && ! change_has_recorded_reason "$change"; then
      echo "REFUSED — every mandated gate passed, but no reason recorded for why this"
      echo "change exists."
      echo
      echo "  Neither a route --reason nor a G1 note is on record for '$change' in its current lineage. At $tier"
      echo "  that is not a documentation gap: the gates above verified the change, but"
      echo "  nothing on record says why it exists."
      echo
      echo "  Record one, either is sufficient:"
      echo "    bash $0 add --change $change --gate G1 --tier $tier --round 1 \\"
      echo "         --outcome pass --confidence fresh --note '<why this change exists>'"
      echo "  (Give REASON='<why>' on the reconcile.sh run that records the route instead, when you fire it:"
      echo "   a second round-1 route for this change would start a new lineage and drop the gates logged so far.)"
      echo
      echo "  It has to be round 1: the dashboard reads the reason from round 1 only, so a note"
      echo "  logged at a later round satisfies this check but leaves the dashboard reading 'not recorded'."
      exit 1
    fi

    if [ "$n_stale" -gt 0 ]; then
      echo "All $tier-mandated gates are satisfied, but $n_stale passed at an earlier round (PASS*)."
      echo "  The code has moved since. Decide per gate whether what it examined changed —"
      echo "  and if it did, re-run it rather than inheriting the verdict."
    else
      echo "All $tier-mandated gates satisfied at round $round."
    fi
    [ "$n_na" -gt 0 ] && \
      echo "  $n_na did not fire here (N/A), on a footnote in the matrix and a reason in the ledger."
    # The exit code cannot say this, so the text must: some passes were counted without their
    # commit being tied to this change (no base recorded, or the commit is not in this clone).
    [ "$n_unverified" -gt 0 ] && \
      echo "  $n_unverified pass(es) counted with their commit binding NOT verified -- see the NOTE lines above."
    exit 0
  fi

  echo "INCOMPLETE — $n_missing mandated gate(s) without a pass: $missing"
  echo
  echo "  This is not a verdict on the code. It is a verdict on the process:"
  echo "  the tier says these gates decide whether this ships, and they have"
  echo "  not decided. Run them. (A logged 'skipped' records an exception such as the pre-push"
  echo "  override; it does not satisfy a mandated gate, and 'n/a' is accepted only where the"
  echo "  router's cell carries a footnote.)"
  exit 1
}

# Gate ids that actually have entries in the ledger, whether or not they are
# registered in the router table. core/06-extending.md lets a project author a
# gate past G8 ("a new gate definition plus its router entry"), and
# looks_like_gate() above accepts G9, G23, anything G+digits, deliberately not
# distinguishing the built-in eight from an authored extension at write time —
# the shape check answers "can this value break out of the position it is
# spliced into", not "is this a real gate". But cmd_gates below used to loop
# only over matrix_gates() (rows present in core/01-router.md), so a project
# that started logging an authored gate's runs before its router row landed —
# or whose router row has a typo, a common way for two copies to drift, per
# this file's own header — saw that gate's runs counted in cmd_report's
# top-level totals (which grep the whole ledger, unfiltered) but silently
# absent from the per-gate breakdown table, with nothing to explain why the
# numbers did not add up.
gates_in_ledger() {
  grep '"type":"gate"' "$LEDGER" 2>/dev/null \
    | sed -n 's/.*"gate":"\([^"]*\)".*/\1/p' | sort -u
}

cmd_gates() {
  require_ledger
  # Prime the matrix cache with a DIRECT call, not one wrapped in $(...). Every
  # matrix_* call below runs inside a command substitution, and $(...) forks a
  # subshell: a subshell can READ the cache variables matrix.sh's _matrix_load()
  # sets, but a write it makes to them dies with that subshell on exit and never
  # reaches this function's own process. So the seemingly-cached
  # _MATRIX_LOAD_FAILED (matrix.sh) still re-ran and re-printed its warning once
  # per forked subshell below — 4 times, one per $(matrix_*) call in this
  # function — because no call ever actually wrote the cache anywhere the next
  # call could see it. Calling it here first, as a plain statement in THIS
  # process, sets the cache before any of those subshells fork, so each one
  # inherits it already resolved (success or failure) and never reloads.
  _matrix_load
  echo "Gate                runs  fresh  findings  yield   disagree   avg tokens  per find"
  echo "-------------------------------------------------------------------------------"
  local _unregistered="" _malformed="" _registered=" $(matrix_gates | tr '\n' ' ') "
  for g in $(printf '%s\n%s\n' "$(matrix_gates)" "$(gates_in_ledger)" | sed '/^$/d' | sort -u); do
    # A "gate" value read back from the ledger was NOT re-validated the way
    # cmd_add's looks_like_gate() enforces on every write — an older ledger.sh,
    # a hand-merged team ledger, or a manual edit could have put anything here.
    # Splicing it unvalidated into an unanchored BRE grep let a value like
    # "G.*" cross-match an unrelated gate's lines and inflate its count, and a
    # value like "G[" (invalid BRE) made every grep against it fail silently,
    # dropping the row from the table with no warning and exit 0 — the exact
    # "confident wrong answer" class surfaces.conf rates this file T4 over.
    # Fresh-context G7 found this live against a hand-built ledger
    # (security-reports/2026-08-14-cli-input-validation-hardening.md).
    # Anything that does not look like a real gate id is reported, not fed to
    # grep as a pattern at all — and every remaining match below uses -F
    # (literal, not regex) now that $g is no longer guaranteed to come only
    # from the trusted router table.
    looks_like_gate "$g" || { _malformed="${_malformed}${_malformed:+ }$g"; continue; }
    local runs fresh finds chal toks
    runs=$(grep -Fc -- "\"gate\":\"$g\"" "$LEDGER" 2>/dev/null)
    [ "${runs:-0}" -eq 0 ] && continue
    case "$_registered" in
      *" $g "*) ;;
      *) _unregistered="${_unregistered}${_unregistered:+ }$g";;
    esac
    fresh=$(grep -F -- "\"gate\":\"$g\"" "$LEDGER" | grep -c '"confidence":"fresh"')
    finds=$(grep -F -- "\"gate\":\"$g\"" "$LEDGER" | sed -n 's/.*"findings":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
    # Same population rule as the summary: `disagree` is a share of fresh runs,
    # so only fresh runs may contribute to the numerator.
    chal=$(grep -F -- "\"gate\":\"$g\"" "$LEDGER" | grep '"confidence":"fresh"' | grep -c '"challenged_premise":true')
    # Only runs that actually recorded a cost contribute to the average, so an
    # unpopulated field reads as "no data" rather than dragging the mean to zero.
    toks=$(grep -F -- "\"gate\":\"$g\"" "$LEDGER" | sed -n 's/.*"tokens":\([0-9]*\).*/\1/p' \
           | awk '$1 > 0 {s+=$1; n++} END {if(n) printf "%.0f", s/n; else print 0}')
    awk -v n="$(gate_name "$g")" -v g="$g" -v r="$runs" -v f="$fresh" -v fi="$finds" \
        -v c="$chal" -v t="$toks" 'BEGIN {
      y = (f > 0) ? fi / f : 0
      d = (f > 0) ? (c / f) * 100 : 0
      tk = (t > 0) ? sprintf("%.0fk", t/1000) : "-"
      pf = (t > 0 && fi > 0) ? sprintf("%.0fk", (t * r) / fi / 1000) : "-"
      printf "%-4s %-13s %4d %6d %9d %7.2f %8.0f%% %11s %9s\n", g, n, r, f, fi, y, d, tk, pf
    }'
  done
  echo
  if [ -n "$_unregistered" ]; then
    echo "  Not in $MATRIX_ROUTER's table (authored extension, or a router row that" >&2
    echo "  drifted — core/06-extending.md): $_unregistered" >&2
  fi
  if [ -n "$_malformed" ]; then
    echo "  Malformed \"gate\" value(s) in $LEDGER — not G+digits, excluded from the" >&2
    echo "  table above rather than matched as a pattern: $_malformed" >&2
  fi
  echo "yield    = findings per fresh-context run. Near zero across 10+ runs → retire."
  echo "disagree = share of fresh runs that contradicted the author. 0% across 10+ runs"
  echo "           means the gate is confirming, not reviewing."
  echo "per find = tokens spent per finding produced. NOT an outcome metric — escape rate"
  echo "           is the only one of those. This is the budget: it says which gate is"
  echo "           expensive, so a model tier (core/08-models.md) can be argued with data."
}

cmd_report() {
  require_ledger
  local total fresh low hotfix finds chal
  total=$(grep -c '"type":"gate"' "$LEDGER")
  fresh=$(grep -c '"confidence":"fresh"' "$LEDGER")
  low=$(grep -c '"confidence":"low"' "$LEDGER")
  hotfix=$(grep -c '"lane":"hotfix"' "$LEDGER")
  finds=$(grep '"type":"gate"' "$LEDGER" | sed -n 's/.*"findings":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
  # Numerator and denominator must describe the same population. Counting
  # challenges across ALL runs while dividing by fresh-context runs printed
  # "challenge rate 167%" — an impossible number, stated confidently, in the
  # report whose whole job is to tell you whether the gates are working.
  chal=$(grep '"confidence":"fresh"' "$LEDGER" | grep -c '"challenged_premise":true')

  echo "Ledger report — $LEDGER"
  echo "======================================================"
  printf "  gate runs          %s\n" "$total"
  printf "  fresh-context      %s\n" "$fresh"
  printf "  low-confidence     %s   (excluded from promotion/retirement)\n" "$low"
  printf "  hotfix-lane runs   %s   (excluded from yield)\n" "$hotfix"
  printf "  total findings     %s\n" "$finds"
  [ "$fresh" -gt 0 ] && awk -v c="$chal" -v f="$fresh" 'BEGIN { printf "  challenge rate     %.0f%%\n", (c/f)*100 }'
  local toks untok
  toks=$(grep '"type":"gate"' "$LEDGER" | sed -n 's/.*"tokens":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
  untok=$(grep '"type":"gate"' "$LEDGER" | sed -n 's/.*"tokens":\([0-9]*\).*/\1/p' | awk '$1 == 0 {n++} END {print n+0}')
  if [ "$toks" -gt 0 ]; then
    awk -v t="$toks" 'BEGIN { printf "  tokens spent       %.1fk   (budget metric, not an outcome one)\n", t/1000 }'
    # "tokens":0 covers two different claims the ledger cannot tell apart at
    # read time: a genuine explicit `--tokens 0` (a real zero-cost run) and
    # an omitted --tokens (cmd_add defaults to 0). The write-side note
    # distinguishes them when the entry is LOGGED; this read-side line
    # cannot, so it says so instead of asserting the stronger "floor" claim
    # for every such line (G6 Peer round 2).
    [ "$untok" -gt 0 ] && printf "                     %s run(s) show tokens:0 (explicit zero-cost, or --tokens\n                     omitted — indistinguishable here); the total above may be a floor\n" "$untok"
  else
    echo "  tokens spent       not recorded. Pass --tokens N; an unmeasured cost is the"
    echo "                     one that gets the whole pipeline dropped rather than tuned."
  fi
  # tokens_in/tokens_out are optional and additive (see --tokens-in in cmd_add):
  # only lines that recorded the split contribute here, everything else already
  # counted toward `toks` above via the aggregate `tokens` field.
  #
  # Gated on how many lines carry the KEY, not on the summed VALUE being > 0 —
  # G4 Ripple round 1: a deliberately-recorded `--tokens-in 0 --tokens-out 0`
  # (a genuine "this run split cleanly to zero" claim) summed to zero and the
  # line vanished, indistinguishable from no run ever having recorded a split.
  # `%.1fk` (not `%.0fk`) on both this line and `tokens spent` above per G8
  # Dogfood round 1: at 0-decimal precision, 1.6k and 0.4k both round to values
  # that don't visibly sum to a 2k total, reading as a discrepancy that isn't
  # actually there.
  local split_runs toks_in toks_out
  split_runs=$(grep '"type":"gate"' "$LEDGER" | grep -c '"tokens_in"')
  if [ "$split_runs" -gt 0 ]; then
    toks_in=$(grep '"type":"gate"' "$LEDGER" | sed -n 's/.*"tokens_in":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
    toks_out=$(grep '"type":"gate"' "$LEDGER" | sed -n 's/.*"tokens_out":\([0-9]*\).*/\1/p' | awk '{s+=$1} END {print s+0}')
    awk -v i="$toks_in" -v o="$toks_out" -v n="$split_runs" 'BEGIN {
      printf "  tokens in/out      %.1fk / %.1fk   (%d run(s) recorded the split)\n", i/1000, o/1000, n
    }'
  fi
  echo
  cmd_gates

  local models
  models=$(grep '"type":"gate"' "$LEDGER" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p' | sort | uniq -c | sort -rn)
  if [ -n "$models" ]; then
    echo
    echo "Models used"
    echo "-----------"
    printf '%s\n' "$models" | awk '{printf "  %-28s %s runs\n", $2, $1}'
    echo "  If results shift, check here before concluding the process changed."
  fi

  # ---- The failure loop, made visible ----
  # A change that took more than one round is the failure rule actually firing:
  # a gate failed, Build was returned to, and the gate ran again. That arc is
  # invisible in a per-gate table, and it is the thing a one-pass review cannot
  # produce by construction.
  echo
  echo "ROUNDS — where the failure rule engaged"
  echo "---------------------------------------"
  local rounds_tbl
  rounds_tbl=$(grep '"type":"gate"' "$LEDGER" \
    | sed -n 's/.*"change":"\([^"]*\)".*"round":\([0-9]*\).*"findings":\([0-9]*\).*/\1\t\2\t\3/p' \
    | awk -F'\t' '{ if ($2 > mx[$1]) mx[$1] = $2; f[$1] += $3; r[$1]++ }
        END { for (c in mx) printf "  %-34s %d round(s)  %2d gate run(s)  %2d finding(s)\n", c, mx[c], r[c], f[c] }' \
    | sort)
  if [ -n "$rounds_tbl" ]; then
    printf '%s\n' "$rounds_tbl"
    echo "  More than one round means a gate sent the change back and re-verified it."
  else
    echo "  No round data. Older entries predate the field, or --round was never passed."
  fi

  # ---- Leading indicator: available from day one ----
  local routes under over match
  # A re-run of the same reconcile (same base, commit, prediction) differs only by its date; counting
  # both made one misclassification read as two in the miss rate.
  local uroutes; uroutes="$(grep '"type":"route"' "$LEDGER" | sed 's/"date":"[^"]*",//' | sort -u)"
  routes=$(printf '%s\n' "$uroutes" | grep -c '"type":"route"')
  echo
  echo "LEADING — reconcile miss rate"
  echo "-----------------------------"
  if [ "$routes" -eq 0 ]; then
    echo "  No reconciliations recorded. Run:  bash tools/reconcile.sh <tier> --log"
  else
    under=$(printf '%s\n' "$uroutes" | grep -c '"verdict":"under"')
    over=$(printf '%s\n' "$uroutes" | grep -c '"verdict":"over"')
    match=$(printf '%s\n' "$uroutes" | grep -c '"verdict":"match"')
    printf "  reconciliations    %s   (match %s · under %s · over %s)\n" "$routes" "$match" "$under" "$over"
    awk -v u="$under" -v r="$routes" 'BEGIN {
      m = (u/r)*100
      printf "  MISS RATE          %.0f%%  ← under-classified\n", m
      if (m >= 30) print "  Routing is misfiring now. Your surfaces file is missing rules, or"
      if (m >= 30) print "  you are systematically tiering low. Fix this before trusting any gate."
      else if (m > 0) print "  Some under-classification. Check which surfaces were missed."
      else print "  Predictions are holding."
    }'
    echo "  Available immediately — this is the metric to watch in month one."
  fi

  # ---- Lagging outcome: the real one ----
  local escapes user_found
  escapes=$(grep -c '"type":"escape"' "$LEDGER")
  echo
  echo "LAGGING — escape rate (the headline)"
  echo "------------------------------------"
  if [ "$escapes" -eq 0 ] && [ "$finds" -eq 0 ]; then
    echo "  No data yet."
  else
    user_found=$(grep '"type":"escape"' "$LEDGER" | grep -c '"found_by":"user"')
    printf "  escapes            %s   (%s found by users)\n" "$escapes" "$user_found"
    awk -v e="$escapes" -v f="$finds" 'BEGIN {
      t = e + f
      if (t > 0) printf "  ESCAPE RATE        %.0f%%  = %d escaped / %d total defects\n", (e/t)*100, e, t
    }'
  fi
  echo "  Lags by months and cannot be computed retroactively — an escape only means"
  echo "  something relative to a gate that should have caught it. Expect ~3 months"
  echo "  before this number says anything. Everything above it measures activity;"
  echo "  this measures effectiveness."
}

case "${1:-}" in
  add)        shift; cmd_add "$@";;
  route)      shift; cmd_route "$@";;
  escape)     shift; cmd_escape "$@";;
  assume)     shift; cmd_assume "$@";;
  report)     shift; cmd_report "$@";;
  gates)      shift; cmd_gates "$@";;
  compliance) shift; require_ledger; cmd_compliance "$@";;
  # Bare invocation (no subcommand at all) prints the header as usage — that is
  # a real help request. A TYPO'D subcommand is not: G8 Dogfood round 1 found
  # that `ledger.sh ad` (for `add`) silently dumped the same 34-line header to
  # STDOUT with no indication anything was wrong, breaking both the brevity and
  # the stderr convention every other refusal in this file follows. Naming what
  # was actually typed, on stderr, is the fix — the full header is still one
  # bare invocation away.
  "") sed -n '3,36p' "$0"; exit 2;;
  *) echo "REFUSED: unknown subcommand '$1'." >&2
     echo "  Usage: ledger.sh add|route|escape|assume|report|gates|compliance [options]" >&2
     echo "  Run with no arguments to see the full header (options, examples)." >&2
     exit 2;;
esac
