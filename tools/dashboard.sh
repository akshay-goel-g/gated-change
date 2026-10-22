#!/usr/bin/env bash
#
# dashboard.sh — derive the pipeline's state machine from the kit itself.
#
# The gate cards already are a state machine definition in all but name: each
# carries question, input, withhold, output, passes_when, fails_when. This reads
# them, reads the router's gate matrix, and emits one JSON model.
#
# Nothing here describes a gate. Everything is derived, so a gate authored per
# core/06-extending.md appears with zero edits to this file — and so this can
# never become the second description of the pipeline that core/02-gates.md
# exists to prevent.
#
# Usage:
#   bash dashboard.sh --print-model                          # emit the derived model as JSON
#   bash dashboard.sh [--ledger path]... [--out path]         # one project (the normal case)
#   bash dashboard.sh --project NAME --ledger path            # a fleet view across several
#           [--ledger path]... --project NAME2 --ledger path...
#           [--split-per-project dir]                         # + one standalone file per project
#
# --ledger is repeatable (default: .pipeline/ledger.jsonl, skipped if absent).
# --project tags every --ledger that follows it, up to the next --project, so
# the dashboard can group executions by project instead of merging them —
# two projects both naming a change "fix-login-bug" stay distinct.
# --out defaults to .pipeline/dashboard.html — the combined view, always
# written. --split-per-project additionally writes dir/<project-slug>.html
# per project: the same page a solo `bash dashboard.sh --ledger <that
# project's ledger>` would produce, generated in one pass instead of one
# invocation per project.
#
# This is read-only. It renders what the ledger already says; it does not run
# gates, write to a ledger, or call out anywhere. A page opened as file:// can't
# fetch a sibling .jsonl (CORS), so the ledger is inlined into the HTML at
# generation time — the page is a snapshot, stamped with when it was made.
#
# Env:
#   KIT=<path>    kit root (default: the directory above this script)
#
# Exit codes:
#   0  emitted
#   1  a card is malformed — named, with its line
#   2  usage or environment error
#
set -uo pipefail

# Byte-wise. Card values carry U+00B7 (·) separators and the matrix carries
# superscript footnote markers; every pattern here is ASCII, so treating input
# as bytes passes multibyte through untouched instead of depending on the
# locale to agree with us. Git Bash on Windows does not reliably agree.
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$(dirname "$HERE")}"
CARDS="$KIT/core/cards"
ROUTER="$KIT/core/01-router.md"
START="$KIT/core/00-start.md"
LEDGER_SH="$KIT/tools/ledger.sh"

# The gate matrix, read the same way every other tool reads it.
MATRIX_ROUTER="$ROUTER"
. "$HERE/lib/matrix.sh"

# The repo's default branch, resolved the one way tools/ledger.sh resolves it
# (R-005) — this file bakes it into the model for app.js's changeIsBranchy(),
# which has no git of its own.
. "$HERE/lib/default-branch.sh"

DASH="$HERE/dashboard"

# KIT locates the ASSETS (cards, router, app.js) — fixed relative to this
# script, correct whether the kit lives at a repo root or inside an adopting
# project's .pipeline/. Ledger and output are DATA: $PIPELINE_DATA, which is the
# kit's own directory unless set -- the same default tools/ledger.sh, status.sh and
# the Stop hook use, and independent of the cwd. (They used to be `.pipeline/...`
# relative to the cwd; run from a subdirectory, or with the kit vendored elsewhere,
# that read a ledger nobody had written and wrote a stray .pipeline/dashboard.html.)
PRINT_MODEL=0
CHECK_ONLY=0
. "$HERE/lib/data-root.sh"
data_root_require dashboard.sh
OUT="${PIPELINE_DATA:-$KIT}/dashboard.html"
SPLIT_DIR=""
LEDGERS=()
PROJECT_NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --print-model) PRINT_MODEL=1; shift;;
    --check)       CHECK_ONLY=1; shift;;
    --ledger) LEDGERS+=("$2"); PROJECT_NAMES+=(""); shift 2;;
    --project)
      # --project <name> --ledger <path> [--ledger <path> ...] — every
      # --ledger up to the next --project is tagged with this project name.
      # Named projects group in the dashboard; unnamed ones fall back to a
      # name derived from the ledger's own path.
      _pname="$2"; shift 2
      while [ $# -gt 0 ] && [ "$1" = "--ledger" ]; do
        LEDGERS+=("$2"); PROJECT_NAMES+=("$_pname"); shift 2
      done;;
    --out) OUT="$2"; shift 2;;
    --split-per-project) SPLIT_DIR="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ "${#LEDGERS[@]}" -gt 0 ] || { LEDGERS=("${PIPELINE_DATA:-$KIT}/ledger.jsonl"); PROJECT_NAMES=(""); }

[ -d "$CARDS" ]  || { echo "no cards directory at $CARDS" >&2; exit 2; }
[ -f "$ROUTER" ] || { echo "no router at $ROUTER" >&2; exit 2; }

# A DIRECT call, not one wrapped in $(...): parse_matrix() below reaches every
# matrix_* function through its own "for g in $(matrix_gates)" loop, and each
# of those forks a subshell whose own load-failure return code is discarded
# the instant only its stdout is captured. So a router that EXISTS (passing
# the check above) but fails to parse for any other reason _matrix_load
# checks — no gate rows, a missing gate row, invalid cell content, an entire
# tier's column wiped, see tools/lib/matrix.sh — silently produced an EMPTY
# matrix object instead of a refusal, indistinguishable on the rendered
# dashboard from "this router legitimately has no gates". ledger.sh and
# reconcile.sh already guard against the identical shape by checking
# _matrix_load's own return code directly before trusting any $(matrix_*)
# result; this file had no such guard at all until now (chip task_8338372f).
# A pre-push regen still only WARNS on this (never blocks the push it rode in
# on — see test_hook_warns_but_does_not_block_when_dashboard_sh_fails) exactly
# like every other documented dashboard.sh failure mode.
_matrix_load || { echo "dashboard: gate matrix failed to load — see the 'matrix:' error above." >&2; exit 2; }

# Every key a card must carry. A card missing one is a malformed card, not a
# state with a blank field — a half-populated state renders as a gate that
# asks nothing, and nobody notices.
# `must_ask`, `overfit_when` and `underfit_when` are required for the same reason
# every other key here is: a card is what a subagent is handed, and a card that
# cannot say what it must never invent, or what its own two calibration failures
# look like, is a card whose author has not decided. Making them REQUIRED is the
# enforcement — `--check` fails a card that omits one, so the question cannot be
# skipped by simply not answering it.
CARD_FIELDS="id name persona question owns does_not_own responsible fires trigger input withhold context output passes_when fails_when must_ask overfit_when underfit_when budget escalate_to retire_if"

WARNINGS=""
warn() { WARNINGS="${WARNINGS}${WARNINGS:+$'\n'}$1"; echo "warning: $1" >&2; }

# ---------------------------------------------------------------- card parsing
#
# Reads one card, emits one JSON object. Handles the three shapes that actually
# occur in the shipped cards:
#   · wrapped values      G1.input, G4.trigger and G7.trigger span two lines
#   · trailing comments   `responsible:  Change owner   # govern.md`
#   · quoted scalars      `question: "..."`
parse_card() {
  awk -v card="$1" '
    function esc(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\")      out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\t") out = out " "
        else                out = out c
      }
      return out
    }
    function flush(   v) {
      if (key == "") return
      v = val
      sub(/[ \t]+$/, "", v)
      # A YAML quoted scalar: drop the delimiters, keep the text.
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      printf "%s\"%s\":\"%s\"", (first ? "" : ","), key, esc(v)
      first = 0
      key = ""
    }
    BEGIN { inblock = 0; seen = 0; first = 1; key = ""; printf "{" }

    /^```yaml/ && !seen { inblock = 1; seen = 1; next }
    /^```/ && inblock   { inblock = 0; next }
    !inblock            { next }

    {
      line = $0
      # Strip a trailing comment only when whitespace precedes the #, so a #
      # inside a value survives.
      sub(/[ \t]+#.*$/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "") next

      if (line ~ /^[a-z_]+:/) {
        flush()
        i = index(line, ":")
        key = substr(line, 1, i - 1)
        val = substr(line, i + 1)
        sub(/^[ \t]+/, "", val)
        keyline[key] = FNR
      } else if (line ~ /^[ \t]+[^ \t]/) {
        if (key == "") {
          printf "\n" > "/dev/stderr"
          printf "%s:%d: continuation line with no key\n", card, FNR > "/dev/stderr"
          exit 3
        }
        sub(/^[ \t]+/, "", line)
        val = val " " line
      } else {
        printf "%s:%d: cannot parse: %s\n", card, FNR, line > "/dev/stderr"
        exit 3
      }
    }
    END { flush(); printf "}" }
  ' "$1"
}

# ---------------------------------------------------------------- router matrix
#
# Read through tools/lib/matrix.sh, which is the same reader ledger.sh and
# reconcile.sh use. This file used to parse the router itself — a second reader
# of one source, which is not a duplicated *fact* but is a duplicated chance to
# read it differently. Cells stay raw: "R¹" and "M (hard)" keep their markers so
# the renderer can show a conditional as conditional. Resolving a footnote here
# would mean inventing a fact the ledger has no field for.
# Cells only — no "budgetMin". app.js dropped its last reader of it in the P1
# pass (the minutes-budget checks are gone); the shell-side budget-drift warning
# below now asks matrix_budget() directly rather than parsing the field back out
# of this string. (P2, the 2026-09-01 review.)
parse_matrix() {
  local first=1 g t sep cell out="{"
  for g in $(matrix_gates); do
    [ "$first" -eq 1 ] || out="${out},"
    first=0
    out="${out}\"$g\":{"
    sep=""
    for t in T0 T1 T2 T3 T4; do
      cell="$(matrix_cell "$g" "$t" | tr -d '"')"
      out="${out}${sep}\"$t\":\"$cell\""
      sep=","
    done
    out="${out}}"
  done
  printf '%s}' "$out"
}

# Footnote lines sit directly under the table. They begin with a superscript
# (multibyte), so they are found positionally — the non-empty lines after the
# last table row, up to the next heading or bold paragraph — rather than by
# matching a character class we would have to leave byte-safety to.
parse_footnotes() {
  awk '
    BEGIN { intable = 0; done = 0; first = 1; printf "[" }
    done { next }
    /^\| \*\*G[0-9]/ { intable = 1; next }
    intable && /^\|/ { next }
    intable {
      if ($0 ~ /^[ \t]*$/) next
      if ($0 ~ /^(#|\*\*|---)/) { done = 1; next }
      line = $0
      gsub(/\\/, "", line); gsub(/"/, "\\\"", line)
      printf "%s\"%s\"", (first ? "" : ","), line
      first = 0
    }
    END { printf "]" }
  ' "$ROUTER"
}

# ---------------------------------------------------------------- the spine
#
# The only hand-maintained duplicate in this file. Non-gate states have no card
# to derive from, so the phase order is declared once, here, and nowhere else.
# Gates are NOT listed — which gate lands in which phase is derived below.
spine_json() {
  cat <<'EOF'
[
 {"id":"R0A_TRIAGE","name":"R0a · Triage","sub":"Predict the tier, before work","kind":"task"},
 {"id":"PLAN_GATES","name":"Plan gates","sub":"Before the code exists","kind":"phase"},
 {"id":"BUILD","name":"Build","sub":"The change itself","kind":"task"},
 {"id":"VERIFY_SEQ","name":"Verify","sub":"Against the built change","kind":"phase"},
 {"id":"VERIFY_PARALLEL","name":"Verify · fresh context","sub":"Blind, independent, no shared data","kind":"parallel"},
 {"id":"R0B_RECONCILE","name":"R0b · Reconcile","sub":"Did the diff match the prediction?","kind":"choice",
  "exits":[{"on":"match","label":"actual == predicted","to":"RECORD"},
           {"on":"under","label":"actual > predicted — STOP, run the higher tier","to":"PLAN_GATES"},
           {"on":"over","label":"actual < predicted — proceed, note it","to":"RECORD"}]},
 {"id":"RECORD","name":"Record","sub":"Ledger, handoff, intent log","kind":"task"},
 {"id":"RELEASE","name":"Release","sub":"","kind":"task"}
]
EOF
}

loops_json() {
  cat <<'EOF'
[
 {"id":"HARVEST","name":"Harvest","sub":"After any escaped defect or T3/T4 change → a learnings entry, sometimes a registry rule"},
 {"id":"ADAPT","name":"Adapt","sub":"When Triage finds an uncovered surface → a new gate"}
]
EOF
}

# ---------------------------------------------------------------- main
CARD_FILES=$(ls "$CARDS"/G*.md 2>/dev/null | sort)
[ -n "$CARD_FILES" ] || { echo "no cards matched $CARDS/G*.md" >&2; exit 2; }

GATES_JSON=""
PARALLEL=""; VERIFY_SEQ=""; PLAN=""

while IFS= read -r cf; do
  [ -n "$cf" ] || continue
  obj=$(parse_card "$cf") || { echo "failed parsing $cf" >&2; exit 1; }

  id=$(printf '%s' "$obj" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  [ -n "$id" ] || { echo "$cf: no id: key in the yaml block" >&2; exit 1; }

  for k in $CARD_FIELDS; do
    printf '%s' "$obj" | grep -q "\"$k\":" || {
      echo "$cf: missing required key '$k'" >&2
      echo "  a card missing a key is a malformed card, not a state with a blank field" >&2
      exit 1; }
  done

  # Phase, derived from the card — never from core/00-start.md's ASCII diagram,
  # which places G4 in PLAN GATES while G4's own card says FRESH SESSION
  # REQUIRED and input: the diff. A diff does not exist before Build, and
  # core/02-gates.md:5-7 says the card wins when the two disagree.
  ctx=$(printf '%s' "$obj" | sed -n 's/.*"context":"\([^"]*\)".*/\1/p')
  inp=$(printf '%s' "$obj" | sed -n 's/.*"input":"\([^"]*\)".*/\1/p')
  case "$ctx" in
    *"FRESH SESSION REQUIRED"*) phase="VERIFY_PARALLEL"; PARALLEL="$PARALLEL $id";;
    *) case "$inp" in
         *"the diff"*) phase="VERIFY_SEQ"; VERIFY_SEQ="$VERIFY_SEQ $id";;
         *)            phase="PLAN_GATES"; PLAN="$PLAN $id";;
       esac;;
  esac

  obj="${obj%\}},\"phase\":\"$phase\"}"
  obj="$(printf '%s' "$obj" | sed "s/}$/,\"phase\":\"$phase\"}/")"
  GATES_JSON="${GATES_JSON}${GATES_JSON:+,}\"$id\":$obj"
done <<EOF
$CARD_FILES
EOF

MATRIX=$(parse_matrix)
FOOTNOTES=$(parse_footnotes)

# ---- consistency checks: turn known latent disagreements into caught ones ----

# core/00-start.md's diagram vs the derived phases. The diagram lays the two
# columns side by side, separated by a box-drawing rule, so the plan column is
# the first token of each line under PLAN GATES.
if [ -f "$START" ]; then
  planblock=$(awk '/PLAN GATES/,/R0b/' "$START" 2>/dev/null | awk 'NR>1 && NF {print $1}')
  for g in $PARALLEL; do
    gname=$(printf '%s' "$GATES_JSON" | sed -n "s/.*\"$g\":{[^}]*\"name\":\"\([^\"]*\)\".*/\1/p")
    if [ -n "$gname" ] && printf '%s\n' "$planblock" | grep -qx "$gname"; then
      warn "core/00-start.md's diagram puts $g ($gname) under PLAN GATES, but its card says FRESH SESSION REQUIRED and input: the diff — which does not exist before Build. Card wins (core/02-gates.md:5-7); the diagram is wrong."
    fi
  done
fi

# The loop is drawn in three places: core/00-start.md twice (the phase diagram
# near the top, the "Your first feature" block near the bottom) and README.md.
# They disagreed for four commits — the two later ones gained Package, Deploy and
# the compliance check while the first-feature block kept an older order with
# reconcile *before* the gates and no compliance at all. That block is the one a
# new user follows, so the stalest copy was the one being read.
#
# Compared as ordered step lists rather than as text, so wording and box-drawing
# differences do not register as drift.
# The box-drawing prefix is stripped as "everything before the first letter"
# rather than by matching ├ and ─ exactly. Under LC_ALL=C a bracket expression
# holding a multibyte character matches one BYTE of it, so `[├└]─` never matches
# the three-byte sequence it looks like it should — and the next sub then ate
# the whole line and the check silently compared nothing to nothing. A drift
# check that cannot fire is worse than no drift check, so this one is tested.
loop_steps() {
  awk '
    /^   [├└]/ {
      line = $0
      sub(/^[^A-Za-z]*/, "", line)             # indent and box-drawing
      sub(/[ \t][ \t]+.*$/, "", line)          # the trailing annotation
      sub(/[ \t]+$/, "", line)
      if (line != "") print line
    }
  ' "$1"
}

if [ -f "$START" ] && [ -f "$KIT/README.md" ]; then
  _s_start="$(loop_steps "$START")"
  _s_readme="$(loop_steps "$KIT/README.md")"
  if [ -n "$_s_start" ] && [ -n "$_s_readme" ] && [ "$_s_start" != "$_s_readme" ]; then
    warn "the loop in core/00-start.md and the loop in README.md list different steps.
    00-start.md: $(printf '%s' "$_s_start" | tr '\n' ' ')
    README.md  : $(printf '%s' "$_s_readme" | tr '\n' ' ')
    A user follows one of them; whichever they follow, the other is wrong."
  fi
fi

# A card with no row in the router matrix is a gate nobody can route to — the
# half-finished state of authoring one (core/06-extending.md). Worth naming,
# since the card alone makes it look installed.
ALL_GATES="$PLAN $VERIFY_SEQ $PARALLEL"
for g in $ALL_GATES; do
  printf '%s' "$MATRIX" | grep -q "\"$g\":" || \
    warn "$g has a card but no row in core/01-router.md's gate matrix — nothing routes to it. Add a row, or it fires at no tier."
done

# Budgets were stated in four places and this compared three of them. Two of
# those copies are gone — ledger.sh now asks lib/matrix.sh, which reads the
# router, so a budget cannot disagree with itself there any more. What remains
# is the prose index in 02-gates.md, which no tool reads and nothing keeps true.
for g in $ALL_GATES; do
  rb=$(matrix_budget "$g" 2>/dev/null)
  # matrix_budget() answers "0" for a gate with no matrix row (and for a row
  # whose budget cell is non-numeric). Either way the router states no budget
  # for it — skip, exactly as the old sed-on-$MATRIX did by matching nothing,
  # rather than warn that "the router says 0min" (G6 Peer, 2026-09-03).
  case "$rb" in ""|0) continue;; esac

  ib=$(awk -F'|' -v g="$g" '$2 ~ ("\\*\\*" g " ") { b=$5; gsub(/[^0-9]/,"",b); print b; exit }' "$KIT/core/02-gates.md" 2>/dev/null)
  [ -n "$ib" ] && [ "$rb" != "$ib" ] && \
    warn "$g budget: router (core/01-router.md) says ${rb}min, the index in core/02-gates.md says ${ib}min. The card is authoritative per core/02-gates.md:5-7."
done

WARN_JSON=$(printf '%s' "$WARNINGS" | awk 'BEGIN{first=1;printf "["} NF{gsub(/\\/,"");gsub(/"/,"\\\"");printf "%s\"%s\"",(first?"":","),$0;first=0} END{printf "]"}')

# Mirrors tools/ledger.sh's json_escape() exactly, same idiom, same reason:
# a note is long agent-written prose that quotes real code, and an unescaped
# " or \ is not hypothetical here either.
json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' \
    | awk 'NR>1 { printf "\\n" } { printf "%s", $0 }'
}

# The path to reach file $1 FROM directory $2, both taken relative to the
# current directory. dashboard.sh reads the ledger relative to where it was
# RUN (its long-standing rule, see the header above) — but a browser resolves
# a relative fetch() against the PAGE's own URL. So a page written to
# .pipeline/dashboard.html that fetches ".pipeline/ledger.jsonl" asks the
# server for .pipeline/.pipeline/ledger.jsonl and 404s, and live mode silently
# never leaves "Snapshot". This is the path that actually works from the
# page's location; app.js fetches it as `src.fetchPath`. Pure string math on
# absolutised, `.`-stripped paths — no realpath(1), which Git Bash and macOS
# disagree about.
#
# Two hardening rules, both from the G7 pass of 2026-09-01:
#
# 1. The inputs arrive through ENVIRON, not `awk -v`. -v runs its value through
#    escape-sequence processing, so a ledger under `a\tb/` became `a<TAB>b/` and
#    — worse — one under `a\057b/` became `a/b/`: an extra PATH SEPARATOR the
#    real filename never had, silently relocating the emitted reference.
#    ENVIRON does no such processing.
#
# 2. abs() collapses every run of slashes. A filesystem ignores the extra ones,
#    but the RESULT of this function is a URL reference, where they are load
#    bearing. A doubled slash surviving into the common prefix emits a reference
#    starting "/" — the server ROOT, i.e. on a host serving several projects,
#    a DIFFERENT project's ledger rendered under this one's name — or "//",
#    which is protocol-relative and leaves the ORIGIN entirely for whatever host
#    the path happens to name. `--ledger "$ROOT/$SUB/ledger.jsonl"` with an
#    empty $SUB is the whole exploit. app.js re-checks at the fetch itself
#    (ledgerRefIsSafe), because pages generated by older copies still exist.
#
# 3. abs() also resolves ".." (G6, 2026-09-02). The prefix walk below treats
#    every segment as a directory name, so a surviving ".." in EITHER path is
#    counted as one — `--out ../site/dash.html` emitted a reference one level
#    too high and 404'd, which is the same silent "Snapshot forever" this
#    function was written to remove.
_relpath() {
  _rp_tgt="$1" _rp_base="$2" _rp_cwd="$(pwd)" awk '
    function abs(p,   n, m, k, seg, res){
      gsub(/\\/, "/", p)                           # Windows separators -> /
      # Normalise a drive path (D:/x) to the /d/x form `pwd` uses on Git Bash,
      # so an absolute --out and a relative --ledger (or vice versa) end up in
      # ONE form before they are compared. Mixing the two produced a common
      # prefix of nothing and a fetchPath of ../../../… — an off-origin fetch
      # reference (G4 Ripple + G7, 2026-09-01).
      if (p ~ /^[A-Za-z]:\//) p = "/" tolower(substr(p, 1, 1)) substr(p, 3)
      if (p !~ /^\//) p = cwd "/" p
      while (p ~ /\/\.\//) sub(/\/\.\//, "/", p)   # collapse a /./ segment
      sub(/\/\.$/, "", p); sub(/\/+$/, "", p)      # and a trailing /.
      # Collapse every run of slashes -- see the shell comment above _relpath.
      while (p ~ /\/\//) sub(/\/\//, "/", p)
      # Resolve ".." against the segment before it. The BEGIN block below
      # compares the two paths segment by segment and emits one "../" per
      # remaining BASE segment, so a ".." left in place is counted as a real
      # directory name: `--out ../site/dash.html` diverged AT the ".." and
      # emitted a reference climbing one level too far, which 404s in exactly
      # the silent way fetchPath exists to stop (G6, 2026-09-02). A leading run
      # of ".." has nothing to cancel against and is kept, not dropped -- a
      # wrong-and-confident answer is worse than a visibly odd one.
      n = split(p, seg, "/"); m = 1; res[1] = seg[1]
      for (k = 2; k <= n; k++){
        if (seg[k] == ".." && m > 1 && res[m] != "..") m--
        else { m++; res[m] = seg[k] }
      }
      p = res[1]
      for (k = 2; k <= m; k++) p = p "/" res[k]
      if (p == "") p = "/"
      return p
    }
    BEGIN{
      tgt = ENVIRON["_rp_tgt"]; base = ENVIRON["_rp_base"]; cwd = ENVIRON["_rp_cwd"]
      t = abs(tgt); b = abs(base)
      nt = split(t, ta, "/"); nb = split(b, ba, "/")
      i = 1
      while (i <= nt && i <= nb && ta[i] == ba[i]) i++
      out = ""
      for (k = i; k <= nb; k++) if (ba[k] != "") out = out "../"
      for (k = i; k <= nt; k++) out = out ta[k] (k < nt ? "/" : "")
      if (out == "") out = "."
      # A leading path SEGMENT containing a colon reads as a URL SCHEME, not as
      # a directory name: a ledger under a directory literally named "https:"
      # emitted "https:/<host>/ledger.jsonl", and the URL parser tolerates the
      # single slash and resolves that to https://<host>, a remote host
      # — off origin, the same boundary rule 2 above is about. "data:" likewise
      # makes the reference itself the payload. ":" is not a legal filename
      # character on Windows, so this is a POSIX-only shape, but the kit TARGETs
      # Linux/macOS too. "./" in front makes it unambiguously a relative path.
      # ledgerRefIsSafe in app.js refuses a scheme at the sink as well; this is
      # the generator half of the same check. NOTE: no apostrophes anywhere in
      # this awk program -- it is single-quoted shell, and one ends it.
      # (G7 round 2, 2026-09-02.)
      if (out ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) out = "./" out
      print out
    }'
}

# ---------------------------------------------------------------- coverage
#
# What has landed that no gate has seen — the one thing on this page not
# derived from the ledger. The ledger only knows what was written INTO it, so
# its silence cannot distinguish "no work happened" from "work happened and
# every gate was asleep", and an empty dashboard was reported (correctly) as
# indistinguishable from a broken one. Computed by tools/lib/coverage.sh, the
# same function tools/status.sh calls, so the terminal and this page cannot
# disagree about what counts as unrouted — tools/lib/matrix.sh exists one
# level down for exactly this reason.
#
# ONLY for a single ledger that lives inside THIS repository. Coverage is
# git-derived, and `--project`/`--ledger` fleet views point at other projects'
# ledgers while git would still answer about the repo this script runs in;
# reporting one project's commits against another's gate records is a
# confident wrong answer, which is the failure this panel exists to remove.
# Anything else emits `null`, and the page says why rather than rendering a
# number nobody should trust.
COVERAGE_JSON="null"
_cov_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
if [ -n "$_cov_repo_root" ] && [ "${#LEDGERS[@]}" -eq 1 ] && [ -f "$KIT/tools/lib/coverage.sh" ]; then
  _cov_led="${LEDGERS[0]}"
  # Absolute is POSIX `/...` OR a Windows drive path (`D:/...`, `D:\...`) —
  # Git Bash hands the latter straight through from the command line, and
  # treating it as relative built `$(pwd)/D:/...`, a directory that never
  # exists, which then fell through the "doesn't exist yet, so it passes"
  # branch below and let a FOREIGN repo's ledger compute coverage against
  # THIS repo's git history. G8 dogfooding hit exactly that.
  case "$_cov_led" in
    /*|[A-Za-z]:[/\\]*) _cov_led_abs="$_cov_led" ;;
                     *) _cov_led_abs="$(pwd)/$_cov_led" ;;
  esac
  _cov_conf="${PIPELINE_DATA:-$KIT}/project/surfaces.conf"

  # The ledger must belong to THIS repo. Comparing path STRINGS is wrong here,
  # and was: on Git Bash for Windows `git rev-parse --show-toplevel` yields
  # "D:/work/gated-change" while `pwd` yields "/d/work/gated-change"
  # — the same drive-letter-form mismatch tools/ledger.sh's own header already
  # documents. The prefix test never matched, so coverage silently computed to
  # null forever on the platform surfaces.conf lists as this kit's primary
  # TARGET, failing closed (a blank panel) rather than loudly. Ask git about the
  # ledger's own directory instead, so both sides of the comparison are produced
  # the same way and there is no path-form normalising of our own to get wrong.
  # A ledger that does not exist yet cannot belong to some other repo, so it
  # passes — "nothing has ever been gated here" is a coverage answer, and it is
  # the case that most needs one.
  # Walk up to the nearest directory that actually exists — a ledger that has
  # not been created yet still has an existing ancestor inside its own repo,
  # and asking git there answers "same repo?" for the not-yet-gated case
  # without the old blanket "missing dir => passes", which is what let a
  # foreign absolute path through.
  _cov_led_dir="$(dirname "$_cov_led_abs")"
  _cov_probe="$_cov_led_dir"
  while [ -n "$_cov_probe" ] && [ "$_cov_probe" != "/" ] && [ "$_cov_probe" != "." ] && [ ! -d "$_cov_probe" ]; do
    _cov_probe="$(dirname "$_cov_probe")"
  done
  _cov_same_repo=0
  if [ -d "$_cov_probe" ]; then
    _cov_led_root="$(git -C "$_cov_probe" rev-parse --show-toplevel 2>/dev/null || printf '')"
    [ -n "$_cov_led_root" ] && [ "$_cov_led_root" = "$_cov_repo_root" ] && _cov_same_repo=1
  fi

  if [ "$_cov_same_repo" -eq 1 ] && [ -f "$_cov_conf" ]; then
    # shellcheck disable=SC1090
    . "$KIT/tools/lib/coverage.sh"
    _cov_anchor="$(coverage_anchor "$_cov_led_abs")"
    _cov_claimed="$(coverage_claimed_anchor "$_cov_led_abs")"
    if [ -n "$_cov_anchor" ]; then _cov_range="$(coverage_range "$_cov_anchor")"
    else
      _cov_base="$(coverage_baseline "$KIT")"   # same cutoff as status.sh (E10)
      if [ -n "$_cov_base" ]; then _cov_range="${_cov_base}..HEAD"; else _cov_range="HEAD"; fi
    fi
    _cov_total="$(git rev-list --count $_cov_range -- 2>/dev/null || echo 0)"   # `--`: a root file named HEAD is not a revision
    _cov_max="${MAX_SCAN:-500}"
    _cov_scanned="$_cov_total"
    [ "$_cov_scanned" -gt "$_cov_max" ] && _cov_scanned="$_cov_max"
    _cov_trunc=false
    [ "$_cov_total" -gt "$_cov_max" ] && _cov_trunc=true
    _cov_never="$(coverage_never_run "$_cov_led_abs" "$KIT")"

    # Same escaping idiom as WARN_JSON above: a commit subject is free text and
    # lands inside a JSON string here. escape_payload() then neutralises
    # "</script>" for the whole MODEL before it is inlined into the page.
    _cov_raw="$(coverage_scan "$_cov_conf" "$_cov_range" "$_cov_scanned" "$(coverage_kit_prefix "$KIT")" "$(coverage_data_prefix)")"
    _cov_rows="$(printf '%s\n' "$_cov_raw" \
      | awk -F'\t' 'BEGIN{first=1;printf "["}
          $1+0 >= 3 {
            s=$2; gsub(/\\/,"",s); gsub(/"/,"\\\"",s)
            printf "%s{\"tier\":%d,\"text\":\"%s\"}",(first?"":","),$1,s; first=0
          }
          END{printf "]"}')"
    _cov_highest="$(printf '%s\n' "$_cov_raw" \
      | awk -F'\t' 'BEGIN{h=0} {if ($1+0 > h) h=$1+0} END{print h+0}')"
    _cov_never_json="$(printf '%s' "$_cov_never" | awk 'BEGIN{first=1;printf "["}
          {for(i=1;i<=NF;i++){printf "%s\"%s\"",(first?"":","),$i;first=0}}
          END{printf "]"}')"

    # The claimed commit exists here but nothing could be picked as THE anchor (separate lines of
    # history): the page must not say "not a commit in this repository" (G8 round 11).
    _cov_inrepo=false
    if [ -z "$_cov_anchor" ] && [ -n "$_cov_claimed" ] \
       && resolve_commit "$_cov_claimed" >/dev/null 2>&1; then _cov_inrepo=true; fi
    COVERAGE_JSON="{\"anchor\":\"$(printf '%s' "$_cov_anchor" | sed 's/ /, /g')\",\"anchorClaimed\":\"$_cov_claimed\",\"anchorInRepo\":$_cov_inrepo,\"commits\":$_cov_total,\"scanned\":$_cov_scanned,\"truncated\":$_cov_trunc,\"highest\":$_cov_highest,\"unrouted\":$_cov_rows,\"neverRun\":$_cov_never_json}"
  fi
fi

# Kit identity — the same fingerprint tools/status.sh prints and tools/ledger.sh
# stamps on every gate record: VERSION plus a checksum of the shell that does
# the work, so a locally-edited tool shows a different hash at the same version.
# NOT `git rev-parse HEAD`: in an installed kit this script's own directory has
# no .git of its own (README install step 1 deletes it), so rev-parse there
# resolves to the HOST project's HEAD — a different, wrong answer to "what kit
# is this" than every other kit tool gives, on the same repo.
_kit_v=""
[ -f "$KIT/VERSION" ] && _kit_v="$(tr -d ' \t\r\n' < "$KIT/VERSION" 2>/dev/null)"
[ -n "$_kit_v" ] || _kit_v="unknown"
_kit_h="$(cat "$KIT"/tools/*.sh "$KIT"/tools/lib/*.sh 2>/dev/null | cksum 2>/dev/null | awk '{printf "%08x", $1}')"
# json_escape'd like every other value in MODEL, because this one is now FILE
# CONTENT. The field it replaced was `git rev-parse --short HEAD` — constrained
# hex, safe raw. VERSION is arbitrary bytes: `tr -d ' \t\r\n'` strips whitespace
# and nothing else, so a `"` in it closed the JSON string and injected a
# sibling key into PIPELINE (later keys win in a JS object literal, so `gates`
# or `matrix` could be replaced wholesale), and `1.0.0"+f()+"` executed as JS
# on page load — verified, not theorised. A stray quote from an honest fork
# blanked the whole page with no diagnostic. (G7, 2026-09-01.)
KIT_ID="$(json_escape "${_kit_v}+${_kit_h:-nohash}")"

# The repo's actual default branch, for tools/dashboard/app.js's changeIsBranchy()
# (R-005). app.js has no git access of its own, so this is the only place the
# computed name can come from. resolve_default_branch() (tools/lib/default-branch.sh,
# sourced above) is the SAME function tools/ledger.sh's write-side refusal uses —
# origin/HEAD's target, then init.defaultBranch, then empty. Computed against the
# repo this script runs in, like the coverage panel above; a --project fleet view
# pointing at other repos still gets this repo's answer, and a foreign project on
# a non-standard trunk keeps the hand-list fallback for its rows — the narrowed
# residue recorded in project/risks.md (R-005, still mitigate).
DEFAULT_BRANCH_ID="$(json_escape "$(resolve_default_branch)")"

MODEL=$(cat <<EOF
{
"generated":"$(date -u +%Y-%m-%dT%H:%M:%SZ)",
"coverage":$COVERAGE_JSON,
"kitCommit":"$KIT_ID",
"defaultBranch":"$DEFAULT_BRANCH_ID",
"gates":{$GATES_JSON},
"matrix":$MATRIX,
"footnotes":$FOOTNOTES,
"spine":$(spine_json),
"loops":$(loops_json),
"phases":{"PLAN_GATES":"$(echo $PLAN)","VERIFY_SEQ":"$(echo $VERIFY_SEQ)","VERIFY_PARALLEL":"$(echo $PARALLEL)"},
"warnings":$WARN_JSON
}
EOF
)

if [ "$PRINT_MODEL" -eq 1 ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# --check turns the warnings above into an exit code.
#
# They already existed — cards missing a matrix row, budgets disagreeing between
# files, a diagram contradicting a card — and they scrolled past on stderr while
# a dashboard was written anyway. A warning nobody is obliged to read is a note,
# and the loop-diagram drift this run now catches survived four commits under
# exactly that arrangement, including one that touched ten files.
if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ -n "$WARNINGS" ]; then
    echo >&2
    echo "FAILED — the kit disagrees with itself. Every line above is a place where two" >&2
    echo "  files state the same fact differently; whichever a reader follows, the other" >&2
    echo "  is wrong." >&2
    exit 1
  fi
  echo "OK — cards, router matrix and the loop diagrams all agree." >&2
  exit 0
fi

# ---------------------------------------------------------------- ledger ingestion
#
# Each ledger line is already valid JSON (ledger.sh emits it). Rather than
# re-serialize it in shell, embed each raw line as a JSON STRING and let the
# browser JSON.parse it — one parse per line, in a try/catch, so one malformed
# line degrades to "N of M unparseable" instead of a blank page.
# Falls back to the ledger's own containing directory name when --project
# wasn't given, so a fleet view is still legible without requiring every
# invocation to name itself.
derive_project_name() {
  local d; d="$(dirname "$1")"
  case "$(basename "$d")" in
    .pipeline|.|"") printf '%s' "$1";;
    *) basename "$d";;
  esac
}

# One JSON object per source, built once and kept in an array (not just
# concatenated into the combined string) so --split-per-project can later
# pick out the subset belonging to one project without re-reading any file.
# Plain indexed arrays only — no `declare -A`, so this still runs on the
# bash 3.2 that ships as /bin/bash on macOS, the same portability bar the
# rest of this kit holds to.
SOURCE_JSON=()
RESOLVED_PROJECTS=()
SOURCE_PATHS=()
i=0
for path in "${LEDGERS[@]}"; do
  proj="${PROJECT_NAMES[$i]:-}"
  i=$((i+1))
  [ -f "$path" ] || { echo "no ledger at $path — skipped" >&2; continue; }
  [ -n "$proj" ] || proj="$(derive_project_name "$path")"
  lines_json=""
  first_ln=1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
    lines_json="${lines_json}$([ "$first_ln" -eq 1 ] || printf ',')\"$(json_escape "$line")\""
    first_ln=0
  done < "$path"
  SOURCE_JSON+=("{\"path\":\"$(json_escape "$path")\",\"project\":\"$(json_escape "$proj")\",\"lines\":[${lines_json}]}")
  RESOLVED_PROJECTS+=("$proj")
  SOURCE_PATHS+=("$path")
done

# The `[...]` array LEDGERS expects, optionally narrowed to one project.
# Index-filtered rather than re-reading files. Each source also gains a
# "fetchPath" — the ledger's location relative to THIS output file's own
# directory (see _relpath), which is what a browser needs to re-fetch it in
# live mode. `src.path` (relative to the CWD dashboard.sh ran in) stays for
# the header display and as app.js's fallback for pages generated before
# fetchPath existed.
build_sources_json() {
  local out_dir="$1" filter="${2:-}" out="[" first=1 j=0 fp
  for src in "${SOURCE_JSON[@]}"; do
    if [ -z "$filter" ] || [ "${RESOLVED_PROJECTS[$j]}" = "$filter" ]; then
      fp="$(_relpath "${SOURCE_PATHS[$j]}" "$out_dir")"
      # Insert "fetchPath" right after src's opening brace. Prefix-strip
      # (`${src#\{}`) + concatenation, NOT `${src/#\{/$rep}`: bash pattern
      # substitution treats `&` in the replacement as the matched text and
      # collapses a `\\` pair, so a ledger path containing either would
      # corrupt the JSON. Prefix removal has no replacement string and no
      # such rule.
      out="${out}$([ "$first" -eq 1 ] || printf ',')"
      out="${out}{\"fetchPath\":\"$(json_escape "$fp")\",${src#\{}"
      first=0
    fi
    j=$((j+1))
  done
  printf '%s]' "$out"
}

# ---------------------------------------------------------------- assembly
#
# No sed token substitution on a template — the payload has &, /, backslashes
# and quotes, and sed would corrupt it. Concatenate pieces in order instead.
# The two escapes below apply ONLY to the inlined data (MODEL, the sources
# JSON), never to app.css/app.js, which we control and which don't contain them: a
# ledger note quoting real code CAN contain "</script>" or "<!--", and that
# must not be able to end the page's own <script> tag.
#
# CASE-INSENSITIVE on the tag name, and that is the whole point (G7 round 2,
# 2026-09-02). HTML's script-data end-tag matching is ASCII case-insensitive —
# "</SCRIPT>" ends a <script> element exactly as "</script>" does — while this
# sed only ever rewrote the lowercase spelling. A ledger note (or a git commit
# subject, which reaches the Coverage rows, or a --ledger path, which reaches
# fetchPath) carrying "</SCRIPT><img src=x onerror=...>" therefore landed RAW
# inside this page's own <script>, closed it, and had the rest parsed as
# markup. Reproduced end to end at d25a867. It breaks out at GENERATION time,
# so every escapeHtml() in app.js is downstream of it and none of them help,
# and it fires on file:// too. Matched with explicit character classes, not
# `sed -I`/`/I`, which is GNU-only — macOS/BSD sed is a stated TARGET in
# project/surfaces.conf. The backreference keeps the note's original spelling
# on screen; only the slash is escaped.
escape_payload() {
  printf '%s' "$1" | sed -e 's#</\([Ss][Cc][Rr][Ii][Pp][Tt]\)#<\\/\1#g' -e 's/<!--/<\\!--/g'
}
MODEL_SAFE=$(escape_payload "$MODEL")

[ -f "$DASH/app.css" ] || { echo "missing $DASH/app.css" >&2; exit 2; }
[ -f "$DASH/app.js" ]  || { echo "missing $DASH/app.js" >&2; exit 2; }

# Writes one self-contained page. Takes a project filter ("" = all) and a
# target path — called once for the combined view, and once per project under
# --split-per-project, so a per-project file is not a different code path,
# just this same assembly fed a narrower slice of SOURCE_JSON. The sources
# JSON is built HERE, not passed in, because each source's fetchPath is
# relative to THIS out_path's directory (see build_sources_json / _relpath).
assemble_html() {
  local filter="$1" out_path="$2"
  local ledgers_json; ledgers_json="$(build_sources_json "$(dirname "$out_path")" "$filter")"
  local ledgers_safe; ledgers_safe=$(escape_payload "$ledgers_json")
  mkdir -p "$(dirname "$out_path")"
  {
    cat <<'HTML_HEAD'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pipeline dashboard</title>
<style>
HTML_HEAD
    cat "$DASH/app.css"
    cat <<'HTML_MID'
</style>
</head>
<body>
<header>
  <h1>Pipeline dashboard</h1>
  <span class="meta">kit @ <code id="kit-commit"></code></span>
  <span class="meta">generated <span id="gen-time"></span></span>
  <span class="meta">source: <span id="sources"></span></span>
  <span class="live-pill" id="live-status"
        title="Served over http(s), this page re-fetches the ledger on focus/tab-visible and re-renders live. Opened as file://, it always shows the snapshot baked in at generation time — a file:// page cannot fetch a sibling .jsonl."></span>
  <span class="warn-pill" id="warn-pill" style="display:none" title=""></span>
</header>
<div id="banner" role="status"></div>
<div id="coverage" role="status"></div>
<div id="body">
  <nav id="rail" aria-label="Changes and review rounds"><div id="rail-project-head"></div><div id="rail-list"></div></nav>
  <main id="center"><div id="graphwrap"></div></main>
  <aside id="drawer" aria-label="Gate detail"><div class="inner"></div></aside>
</div>
<footer class="legend">
  <span><b>Read-only.</b> This renders what the ledger already says — it does not run gates.</span>
  <span id="legend-mode"><b>Snapshot.</b> Regenerate with <code>bash tools/dashboard.sh</code> after logging new gate runs — or open this page over http(s) instead of file://, where it fetches the ledger itself (see the status pill in the header).</span>
  <span>Graph box that <b>ran</b>: <b>green</b> = pass · <b>hatched</b> = a self-check (the author's own review, kept out of the stats) · <b>dashed green</b> = <code>PASS*</code>, a pass carried forward from an earlier round (age shows on click) · <b>red</b> = fail.</span>
  <span>Graph box with <b>no verdict</b>: <b>amber dashed</b> = <code>SKIPPED</code>, required here but not run · <b>grey dashed</b> = <code>NO RECORD</code>, required and never ran · <b>faint grey</b> = <code>N/A</code>, marked not-applicable · <b>faded</b> <code>—</code> = the gate's card does not fire at this tier · <b>faded</b> <code>R¹ · not run</code> = it can fire here (hover for the condition), it just didn't.</span>
  <span>The parallel block shows structural concurrency (the context rule), not measured timing — gates inside it aren't plotted by clock time even on a record that now carries one. Older ledger lines still carry no finer timestamp than a date; only entries written going forward carry a time of day.</span>
</footer>
<script>
const PIPELINE =
HTML_MID
    printf '%s' "$MODEL_SAFE"
    printf ';\nconst LEDGERS =\n'
    printf '%s' "$ledgers_safe"
    printf ';\n'
    cat "$DASH/app.js"
    cat <<'HTML_TAIL'
</script>
</body>
</html>
HTML_TAIL
  } > "$out_path"
  echo "Wrote $out_path" >&2
}

assemble_html "" "$OUT"
echo "  $(printf '%s\n' "$CARD_FILES" | wc -l | tr -d ' ') gates · ${#LEDGERS[@]} ledger path(s) requested" >&2
[ -n "$WARNINGS" ] && echo "  $(printf '%s\n' "$WARNINGS" | grep -c .) kit warning(s) — see the warning pill in the page" >&2

if [ -n "$SPLIT_DIR" ]; then
  echo >&2
  echo "--split-per-project: writing one file per project into $SPLIT_DIR/" >&2
  # Unique projects, in first-seen order — a plain loop, not sort -u, so the
  # file-per-project order matches --project's order on the command line.
  seen=""
  for proj in "${RESOLVED_PROJECTS[@]}"; do
    case " $seen " in *" ${proj} "*) continue;; esac
    seen="$seen $proj"
    slug=$(printf '%s' "$proj" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
    [ -n "$slug" ] || slug="project"
    assemble_html "$proj" "$SPLIT_DIR/$slug.html"
  done
fi

echo >&2
echo "Open by double-clicking — no server needed." >&2
