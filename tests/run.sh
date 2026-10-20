#!/usr/bin/env bash
#
# run.sh — the kit's own test suite.
#
# A pipeline whose thesis is "verification is the product" shipped 1,300 lines of
# shell with no tests. Every bug LEARNINGS.md records was found by *using* the
# tools, which is the slowest and most expensive way to find any of them.
#
# No dependencies. The kit installs with `cp` and runs on bash + git + coreutils;
# a test suite that needs bats would add an install step to a product whose
# selling point is a 30-minute setup. JSON assertions use python when it is
# present and SKIP (loudly) when it is not — a skipped assertion is visible, a
# silently weakened one is not.
#
# Usage:
#   bash tests/run.sh              # everything
#   bash tests/run.sh compliance   # only tests whose name matches
#
# Env:
#   KEEP=1   do not delete the temp repos, and print where they are
#
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-}"

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""
CURRENT=""

TMPROOT="$(mktemp -d 2>/dev/null || mktemp -d -t gated-change-tests)"
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    echo "KEEP=1 — fixtures left at $TMPROOT" >&2
  else
    rm -rf "$TMPROOT"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- assertions
#
# Every assertion prints the actual value on failure. A test suite that says
# "assertion failed" and nothing else costs more time than it saves.

note() { printf '      %s\n' "$1"; }

_ok()   { PASS=$((PASS + 1)); }
_fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES="${FAILED_NAMES}${FAILED_NAMES:+ }$CURRENT"
  printf '  FAIL  %s\n' "$CURRENT"
  printf '        %s\n' "$1"
}
_skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s — %s\n' "$CURRENT" "$1"; }

# run <cmd...> — captures combined output and exit code into LAST_OUT/LAST_EXIT.
# Combined on purpose: these tools write their most important lines (the example
# config warning, the evidence-rule warning) to stderr, and a test that only
# reads stdout would call that silence a pass.
run() {
  LAST_OUT="$("$@" 2>&1)"
  LAST_EXIT=$?
  return 0
}

assert_exit() {
  local want="$1" msg="${2:-}"
  if [ "$LAST_EXIT" = "$want" ]; then _ok
  else _fail "expected exit $want, got $LAST_EXIT${msg:+ ($msg)}
        output was:
$(printf '%s' "$LAST_OUT" | sed 's/^/          /')"
  fi
}

assert_contains() {
  local needle="$1"
  case "$LAST_OUT" in
    *"$needle"*) _ok;;
    *) _fail "expected output to contain: $needle
        output was:
$(printf '%s' "$LAST_OUT" | sed 's/^/          /')";;
  esac
}

assert_not_contains() {
  local needle="$1"
  case "$LAST_OUT" in
    *"$needle"*) _fail "expected output NOT to contain: $needle
        output was:
$(printf '%s' "$LAST_OUT" | sed 's/^/          /')";;
    *) _ok;;
  esac
}

assert_re() {
  local re="$1"
  if printf '%s\n' "$LAST_OUT" | grep -Eq "$re"; then _ok
  else _fail "expected output to match: $re
        output was:
$(printf '%s' "$LAST_OUT" | sed 's/^/          /')"
  fi
}

# A compliance row, matched independently of column widths. The state and the
# gate are the behaviour; the spacing between them is not, and a test that fails
# when a column moves teaches people to stop trusting the suite.
assert_row() { assert_re "^[[:space:]]*$1[[:space:]]+$2([[:space:]]|$)"; }

assert_eq() {
  local want="$1" got="$2" what="${3:-value}"
  if [ "$want" = "$got" ]; then _ok
  else _fail "$what: expected [$want], got [$got]"
  fi
}

assert_file_contains() {
  local f="$1" needle="$2"
  if grep -qF "$needle" "$f" 2>/dev/null; then _ok
  else _fail "expected $f to contain: $needle
        file was:
$(sed 's/^/          /' "$f" 2>/dev/null)"
  fi
}

# The assertion that matters for a refusal. "It printed REFUSED" is a message;
# "the record does not contain it" is the actual guarantee, and it is the one
# that would have caught an invalid severity being warned about and then written
# through anyway. A missing file trivially satisfies it.
assert_not_file_contains() {
  local f="$1" needle="$2"
  if [ ! -f "$f" ] || ! grep -qF "$needle" "$f" 2>/dev/null; then _ok
  else _fail "expected $f NOT to contain: $needle
        file was:
$(sed 's/^/          /' "$f" 2>/dev/null)"
  fi
}

# ---------------------------------------------------------------- portable file edits
# `sed -i EXPR FILE` means different things to GNU sed (no suffix argument) and BSD sed on macOS (the next argument is a
# suffix, so the expression is read as one and fails with "invalid command code"). `-i.bak` plus deleting the backup works
# on both. The expression must itself be portable: no \r, no `2a text` on one line (use sedi_crlf / sedi_after below).
sedi() { local last rc; for last; do :; done; sed -i.sedibak "$@"; rc=$?; rm -f "$last.sedibak"; return $rc; }
# Every line ends CRLF (what a Windows checkout does). BSD sed does not understand \r in a replacement.
sedi_crlf() { local rc=0; awk '{ printf "%s\r\n", $0 }' "$1" > "$1.sedibak" && cat "$1.sedibak" > "$1" || rc=$?; rm -f "$1.sedibak"; return $rc; }
# Insert TEXT as a new line after line N. BSD sed's `Na text` form needs a newline; awk does not. TEXT goes through the
# environment so awk does not process backslash escapes in it (awk -v does).
sedi_after() { local rc=0; SEDI_TEXT="$2" awk -v n="$1" '{ print } NR == n { print ENVIRON["SEDI_TEXT"] }' "$3" > "$3.sedibak" && cat "$3.sedibak" > "$3" || rc=$?; rm -f "$3.sedibak"; return $rc; }

# ---------------------------------------------------------------- json
PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

# Same graceful-skip idiom as PY above, not a stricter one: no JS runtime
# means the JS-logic tests are skipped loudly (see test_dashboard_logic_*
# below), never silently weakened or made a hard requirement to install.
NODE=""
command -v node >/dev/null 2>&1 && NODE="node"

# Resolved once, absolute: `PATH=<curated> bash -c ...` resolves `bash` itself
# against the CURATED path, not the caller's — a restrictive PATH built for
# the checksum-fallback tests below would make plain `bash` unresolvable too.
BASH_BIN="$(command -v bash)"

# Every line of the ledger must be parseable. `json_escape` exists because an
# unescaped quote in an agent-written note produces a line no consumer can read,
# silently, forever (tools/ledger.sh:80-88) — this is the assertion that keeps
# that fix honest.
assert_jsonl_valid() {
  local f="$1"
  [ -n "$PY" ] || { _skip "no python — cannot validate JSON"; return; }
  local out
  out="$("$PY" - "$f" <<'EOF' 2>&1
import json, sys
bad = []
for i, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as e:
        bad.append("line %d: %s" % (i, e))
print("\n".join(bad))
EOF
)"
  if [ -z "$out" ]; then _ok; else _fail "invalid JSON in $f:
$(printf '%s' "$out" | sed 's/^/          /')"; fi
}

# Read one field out of the last JSONL line, so a test can assert on what was
# actually recorded rather than on what the tool printed to the terminal.
jsonl_last_field() {
  local f="$1" field="$2"
  [ -n "$PY" ] || { printf '__NOPY__'; return; }
  "$PY" - "$f" "$field" <<'EOF'
import json, sys
last = None
for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip():
        last = json.loads(line)
path = sys.argv[2].split(".")
val = last
for key in path:
    if isinstance(val, list):
        val = val[int(key)]
    else:
        val = val.get(key) if isinstance(val, dict) else None
print("" if val is None else val)
EOF
}

# ---------------------------------------------------------------- fixtures
#
# A realistic install: the kit at .pipeline/, committed, so the base commit
# already contains it. Tests that care about the kit being in its own diff
# build their own fixture — this one deliberately isolates the tool under test
# from that question.
#
# newrepo() is called ~270 times across this suite. Until this comment, every
# call re-ran `git init` + 4x `git config` + a ~900KB `cp -r` of
# tools/project/core/templates + `git add` + `git commit` — about 8 subprocess
# spawns per call, on Windows Git Bash, which surfaces.conf's own TARGET rows
# and coverage.sh's cost comments both already name as the environment where
# process-spawn cost is the expensive part, not the algorithm. That payload is
# byte-identical on every call within one suite run — nothing here ever
# mutates $KIT — so it is built into a template repo ONCE below, and
# newrepo() becomes a single `cp -r` of an already-initialized, already-
# committed repo instead of redoing the git/copy work every time.
#
# Deliberately plain `cp -r`, not `cp -rl`/hardlinks: several tests mutate
# files under $REPO/.pipeline/... in place after calling newrepo() (e.g.
# test_action_row_missing_evidence_field_refuses_loudly appends a row to
# surfaces.conf). A hardlinked copy would make that edit visible in every
# OTHER fixture sharing the same inode — a silent cross-fixture leak plain
# copying cannot have.
REPO=""
BASE_SHA=""
_REPO_TEMPLATE="$TMPROOT/_template"
_build_repo_template() {
  local t="$_REPO_TEMPLATE"
  mkdir -p "$t"
  git -C "$t" init -q
  git -C "$t" config user.email test@example.com
  git -C "$t" config user.name  "test"
  git -C "$t" config core.autocrlf false
  git -C "$t" config commit.gpgsign false

  mkdir -p "$t/src/auth" "$t/src/components"
  printf 'console.log(1)\n' > "$t/src/app.js"
  printf 'body{}\n'         > "$t/src/theme.css"
  printf 'const k = 1\n'    > "$t/src/auth/existing.js"   # tracked T4, for edit-in-place tests

  # The project exists BEFORE the kit is installed, in its own commit: an install commit that also
  # carries project work is counted as work (G7 round 8), and this fixture models adopting the kit
  # into an existing repo.
  git -C "$t" add -A >/dev/null 2>&1
  git -C "$t" commit -qm "project" >/dev/null 2>&1

  mkdir -p "$t/.pipeline"
  cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$t/.pipeline/"
  cp "$KIT/README.md" "$t/.pipeline/README.md"
  # What the install instructions say to do: the example is what a new project
  # starts from. The kit's own surfaces describe the kit and match nothing here.
  cp "$KIT/templates/project/surfaces.conf" "$t/.pipeline/project/surfaces.conf"

  git -C "$t" add -A >/dev/null 2>&1
  git -C "$t" commit -qm "base" >/dev/null 2>&1
}
_build_repo_template
_TEMPLATE_BASE_SHA="$(git -C "$_REPO_TEMPLATE" rev-parse HEAD)"

newrepo() {
  REPO="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  rmdir "$REPO"                # mktemp -d creates it; cp -r needs the target absent
  cp -r "$_REPO_TEMPLATE" "$REPO"
  BASE_SHA="$_TEMPLATE_BASE_SHA"
}

# A ledger path inside the fixture, so no test can touch the real one.
ledger_path() { printf '%s/.pipeline/ledger.jsonl' "$REPO"; }

rec()  { ( cd "$REPO" && BASE="$BASE_SHA" bash .pipeline/tools/reconcile.sh "$@" ); }
# C1: a fresh T3/T4 pass must cite something (ledger.sh evidence rule). The fixtures log hundreds of bare passes
# to exercise routing and compliance, not citations, so `add` gets a stand-in citation unless the test opts out
# with LED_NO_EVIDENCE=1 (the C1 tests do) or supplies its own.
led()  {
  local _ev=()
  [ "${1-}" = add ] && [ -z "${LED_NO_EVIDENCE-}" ] && _ev=(--evidence .pipeline/tools/ledger.sh:1)
  # Injected BEFORE the caller's own arguments, so a test that passes --evidence wins (last flag wins).
  if [ "${1-}" = add ]; then
    ( cd "$REPO" && bash .pipeline/tools/ledger.sh --ledger "$(ledger_path)" add ${_ev[@]+"${_ev[@]}"} "${@:2}" )
  else
    ( cd "$REPO" && bash .pipeline/tools/ledger.sh --ledger "$(ledger_path)" "$@" )
  fi
}

# `led()` above ALWAYS passes --ledger explicitly, which means every other test
# in this file exercises the override, never the DEFAULT. That is exactly how a
# wrong default hid: `git -C "$KIT_ROOT" rev-parse ...` resolving to the wrong
# ledger location silently, with a "logged: ... pass" success message and exit 0,
# while writing nothing anyone would ever find. This fixture makes the kit itself
# the repo root — tools/ directly under it, not nested under .pipeline/ — the
# self-hosting shape, and its tests call ledger.sh with NO --ledger flag at all.
#
# Same one-time-template treatment as newrepo() above, same reason (~fewer
# calls than newrepo(), but the per-call cost shape is identical).
_SELFHOST_TEMPLATE="$TMPROOT/_selftemplate"
_build_selfhost_template() {
  local t="$_SELFHOST_TEMPLATE"
  mkdir -p "$t"
  git -C "$t" init -q
  git -C "$t" config user.email test@example.com
  git -C "$t" config user.name  "test"
  git -C "$t" config commit.gpgsign false
  cp -r "$KIT/tools" "$KIT/core" "$t/"
  git -C "$t" add -A >/dev/null 2>&1
  git -C "$t" commit -qm "base" >/dev/null 2>&1
}
_build_selfhost_template

selfhostrepo() {
  SELFREPO="$(mktemp -d "$TMPROOT/selfrepo.XXXXXX")"
  rmdir "$SELFREPO"
  cp -r "$_SELFHOST_TEMPLATE" "$SELFREPO"
}
# No --ledger — this is the point.
led_default() {
  local _ev=()
  [ "${1-}" = add ] && [ -z "${LED_NO_EVIDENCE-}" ] && _ev=(--evidence tools/ledger.sh:1)
  if [ "${1-}" = add ]; then
    ( cd "$SELFREPO" && bash tools/ledger.sh add ${_ev[@]+"${_ev[@]}"} "${@:2}" )
  else
    ( cd "$SELFREPO" && bash tools/ledger.sh "$@" )
  fi
}

# A repo built to exercise the BASE resolution chain, so BASE is deliberately
# NOT set and not inherited. Two commits, so HEAD~1 exists as a last resort.
# No kit copy — reconcile resolves its own config against its own location.
baserepo() {
  local branch="$1"
  REPO="$(mktemp -d "$TMPROOT/base.XXXXXX")"
  git -C "$REPO" init -q -b "$branch" 2>/dev/null || {
    git -C "$REPO" init -q; git -C "$REPO" checkout -q -b "$branch" 2>/dev/null; }
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name  "test"
  git -C "$REPO" config core.autocrlf false
  git -C "$REPO" config commit.gpgsign false
  printf 'a\n' > "$REPO/a.txt"; git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm one >/dev/null 2>&1
  printf 'b\n' > "$REPO/b.txt"; git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm two >/dev/null 2>&1
}

# BASE unset on purpose — the chain is the thing under test.
recbare() { ( cd "$REPO" && env -u BASE bash "$KIT/tools/reconcile.sh" "$@" ); }

# ================================================================ reconcile
#
# These pin behaviour that already works. The tier a change lands at decides
# which gates are mandatory, so a silent change here is a silent change to what
# ships unreviewed.

test_reconcile_under_classified_exits_1() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/session.js"
  run rec T1
  assert_exit 1 "auth/ forces T4; predicted T1"
  assert_contains "UNDER-CLASSIFIED"
  assert_contains "Trust boundary"
}

test_reconcile_over_classified_exits_0() {
  newrepo
  printf 'body{color:red}\n' > "$REPO/src/theme.css"
  run rec T4
  assert_exit 0
  assert_contains "Over-classified"
}

test_reconcile_match_exits_0() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/session.js"
  run rec T4
  assert_exit 0
  assert_contains "Reconciled"
}

# Reconciled is a ROUTING verdict. An earlier version ended with a flat
# "Proceed to release." above a gate list containing a HARD GATE, which read as
# an all-clear at 2am (tools/reconcile.sh:193-197). The pointer at the
# compliance check is the fix, and it must not quietly disappear.
test_reconcile_match_points_at_compliance() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/session.js"
  run rec T4
  assert_contains "ledger.sh compliance"
  assert_not_contains "Proceed to release"
}

# R0b normally runs after Build and before any commit exists. An earlier version
# only looked at the committed diff, so the common case reconciled against
# nothing and passed (tools/reconcile.sh:92-100).
test_reconcile_counts_untracked_files() {
  newrepo
  printf 'x\n' > "$REPO/src/auth/token.js"     # never added to the index
  run rec T1
  assert_exit 1 "an untracked T4 file must still raise the tier"
  assert_contains "src/auth/token.js"
}

test_reconcile_counts_uncommitted_edits() {
  newrepo
  printf 'const k = 2\n' > "$REPO/src/auth/existing.js"    # tracked, edited, not staged
  run rec T1
  assert_exit 1 "an unstaged edit to a tracked T4 file must still raise the tier"
  assert_contains "src/auth/existing.js"
}

# `reconcile.sh --log T3` must not read "--log" as the predicted tier
# (tools/reconcile.sh:44-55). CHANGE= is set so --log actually records rather
# than hitting the trunk-branch refusal (P1-5) — this test is about flag order,
# not about the write.
test_reconcile_flag_order_independent() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/session.js"
  LAST_OUT="$( cd "$REPO" && BASE="$BASE_SHA" CHANGE=session-token \
    bash .pipeline/tools/reconcile.sh --log T4 2>&1 )"; LAST_EXIT=$?
  assert_contains "Predicted   : T4"
  assert_not_contains "Predicted   : --log"
  assert_contains "(logged to ledger)"
}

# The shipped surfaces.conf is somebody else's project. Three identical
# mechanical misfires against it, on one diff, is what put this warning in.
test_reconcile_warns_on_unmodified_example_config() {
  newrepo
  printf 'x\n' > "$REPO/src/app.js"
  run rec T1
  assert_contains "still has the shipped example surfaces"
}

# --log writes a route record, and the route record is the only source for the
# one metric available on day one (miss rate). CHANGE= is set: a plain reconcile
# with no CHANGE on a trunk branch is refused now (P1-5).
test_reconcile_log_writes_route_record() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/session.js"
  ( cd "$REPO" && BASE="$BASE_SHA" CHANGE=session-token \
      bash .pipeline/tools/reconcile.sh T1 --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  assert_file_contains "$(ledger_path)" '"type":"route"'
  assert_file_contains "$(ledger_path)" '"verdict":"under"'
  assert_file_contains "$(ledger_path)" '"change":"session-token"'
  assert_jsonl_valid "$(ledger_path)"
}

# Staging moves a file out of all three other queries at once: it is no longer
# untracked, no longer differs from the index, and not yet in any commit. That
# is the ordinary state at R0b — work staged, not yet committed — and it was
# the one state reconcile could not see. Found by this suite on its first run.
test_reconcile_counts_staged_files() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/staged.js"
  git -C "$REPO" add src/auth/staged.js >/dev/null 2>&1
  run rec T1
  assert_exit 1 "a staged-but-uncommitted T4 file must still raise the tier"
  assert_contains "src/auth/staged.js"
}

# "Nothing to compare" is not "nothing wrong" — it is usually a wrong base, and
# agent-instructions.md tells an agent to branch on this exit code.
test_reconcile_empty_diff_exits_2() {
  newrepo
  run rec T1
  assert_exit 2 "an empty diff must not read as a pass"
  assert_contains "This is NOT a pass"
}

test_reconcile_allow_empty_opts_back_into_0() {
  newrepo
  run rec T1 --allow-empty
  assert_exit 0
}

# A typo in the predicted tier ("t1", "T5", "T1x") used to map silently to T0
# via tier_num()'s default case — indistinguishable from a deliberate,
# legitimate "T0" prediction — rather than being refused as a usage error, so
# a real T0 change with a mistyped predicted tier reported "Reconciled",
# implying the typo was accepted and matched, when nothing was ever validated.
test_reconcile_refuses_a_malformed_predicted_tier() {
  newrepo
  run rec t1
  assert_exit 2 "a lowercase tier must be refused, not silently read as T0"
  assert_contains "REFUSED"
  assert_contains "not one of T0..T4"
}

test_reconcile_refuses_a_predicted_tier_that_is_not_in_the_enum() {
  newrepo
  run rec T5
  assert_exit 2 "T5 is not a real tier"
  assert_contains "REFUSED"
}

# The valid values must still work exactly as before — this is a refusal on
# the invalid shapes, not a stricter check on the legitimate ones. T0 is a
# real, deliberate prediction ("nothing mandatory"), not a typo — it must
# still be accepted, same as T1..T4.
test_reconcile_accepts_every_real_predicted_tier() {
  newrepo
  local t
  for t in T0 T1 T2 T3 T4; do
    run rec "$t" --allow-empty
    assert_not_contains "REFUSED"
  done
}

# ---- The kit is not the project ----
#
# The documented install puts the kit in .pipeline/, where its own filenames
# collide with the words surfaces files are made of. A fresh install reported
# seventeen T4 hits on its first run, none of them the user's code.

test_reconcile_excludes_the_kits_own_files() {
  newrepo
  # The state right after `ledger.sh add`: the kit's own ledger is new on disk.
  printf '{"type":"gate"}\n' > "$REPO/.pipeline/ledger.jsonl"
  printf 'body{color:red}\n' > "$REPO/src/theme.css"
  run rec T1
  assert_exit 0 "recording a gate run must not raise the tier of the change"
  assert_not_contains ".pipeline/ledger.jsonl"
  assert_contains "Actual tier : T1"
}

test_reconcile_reports_what_it_excluded() {
  newrepo
  printf '{"type":"gate"}\n' > "$REPO/.pipeline/ledger.jsonl"
  printf 'x\n' > "$REPO/src/app.js"
  run rec T1
  assert_contains "excluded — the kit itself"
}

test_reconcile_include_kit_opts_back_in() {
  newrepo
  printf '{"type":"gate"}\n' > "$REPO/.pipeline/ledger.jsonl"
  printf 'x\n' > "$REPO/src/app.js"
  LAST_OUT="$( cd "$REPO" && BASE="$BASE_SHA" INCLUDE_KIT=1 \
      bash .pipeline/tools/reconcile.sh T1 2>&1 )"; LAST_EXIT=$?
  assert_contains ".pipeline/ledger.jsonl"
}

# Everything excluded is not everything reviewed.
test_reconcile_all_excluded_is_not_a_pass() {
  newrepo
  printf '{"type":"gate"}\n' > "$REPO/.pipeline/ledger.jsonl"
  run rec T1
  assert_exit 2
}

# ---- Anchored rules: a path segment, not a substring of a name ----

# Routing a project against the KIT's surfaces fails OPEN — nothing of theirs
# matches rules written about tools/reconcile.sh, so every change lands at T0 and
# no gate is ever mandatory. A pipeline reporting success while doing nothing is
# worse than no pipeline, so this refuses rather than warns.
test_reconcile_refuses_the_kits_own_surfaces_in_an_installed_copy() {
  newrepo
  cp "$KIT/project/surfaces.conf" "$REPO/.pipeline/project/surfaces.conf"
  printf 'token=1
' > "$REPO/src/auth/session.js"
  run rec T1
  assert_exit 2
  assert_contains "own surfaces file, not yours"
  assert_contains "cp .pipeline/templates/project/surfaces.conf"
}

# ...but the kit reviewing itself is exactly when that file IS the right one.
test_reconcile_accepts_the_kits_own_surfaces_in_the_kit_itself() {
  run bash -c "cd '$KIT' && BASE=HEAD~1 bash tools/reconcile.sh T4 --allow-empty"
  case "$LAST_EXIT" in 0|1) _ok;; *) _fail "the kit's own surfaces must work in the kit: exit $LAST_EXIT";; esac
  assert_not_contains "not yours"
}

test_surfaces_do_not_fire_on_words_inside_filenames() {
  newrepo
  mkdir -p "$REPO/docs"
  printf 'x\n' > "$REPO/docs/session-record-arm-a.md"
  printf 'x\n' > "$REPO/docs/04-ledger.md"
  printf 'x\n' > "$REPO/docs/rate-limiting-notes.md"
  run rec T0
  assert_exit 0 "docs about auth and ledgers are not auth and ledgers"
  assert_not_contains "T4"
}

test_surfaces_still_fire_on_real_segments() {
  newrepo
  printf 'x\n' > "$REPO/src/auth/handler.js"      # directory form
  run rec T0
  assert_exit 1
  assert_contains "Trust boundary"
}

test_surfaces_fire_on_an_exact_file() {
  newrepo
  printf 'x\n' > "$REPO/src/ledger.js"            # file form
  run rec T0
  assert_exit 1
  assert_contains "Quota accounting"
}

# ---- IGNORE rows ----

test_ignore_rows_drop_paths_before_tiering() {
  newrepo
  mkdir -p "$REPO/vendor/auth"
  printf 'x\n' > "$REPO/vendor/auth/lib.js"       # would be T4 without the IGNORE row
  printf 'x\n' > "$REPO/src/app.js"
  run rec T1
  assert_exit 0
  assert_not_contains "vendor/auth/lib.js"
}

# ---- ACTION rows: declared events, not diffs (01-router.md R0d) ----
#
# newrepo's fixture copies templates/project/surfaces.conf as-is, which now
# ships five worked ACTION rows (store-publish, permission-delta, rollout-ramp,
# key-rotation, listing-edit), all T4 — so most of these tests use
# "store-publish" directly rather than injecting a synthetic row, on the
# theory that the shipped example is the thing that actually has to work.

# The bug this shape would produce: an ACTION row's NAME field ("store-publish")
# grepped against the changed-file list as if it were a path regex. It matches
# nothing, so it would silently fail to raise the tier and print nothing to
# say why — the exact "confident wrong answer" class this file's own history
# (and matrix.sh's Finding 1) warns about. Touching an ORDINARY T1 file and
# reconciling with no --action at all must produce the same T1 result whether
# or not ACTION rows exist in the file.
test_action_rows_do_not_corrupt_path_tiering() {
  newrepo
  printf 'body{color:red}\n' > "$REPO/src/theme.css"
  run rec T1
  assert_exit 0
  assert_contains "Actual tier : T1"
  assert_not_contains "store-publish"
}

# If an ACTION row were ever fed to the path-tiering loop (i.e. the ACTION::
# exclusion in its case statement were removed), the loop's own field-split
# would derive a "regex" of TIER::NAME from it — and because NAME is free
# text, `|` in a NAME turns that derived string into an ALTERNATION: a NAME of
# "x|theme" parses as the regex "T4::x|theme", i.e. "(T4::x)|(theme)" — the
# second branch matches ANY path containing "theme". Confirmed this is not
# hypothetical: with the ACTION:: exclusion removed, this exact row prints a
# bogus "ACTION  src/theme.css  desc" line in the Surfaces-hit table (the
# derived tier "ACTION" is not T1..T4, so it happens not to raise ACTUAL here
# — but it silently pollutes the report with a hit that should not exist,
# which is its own confident-wrong-answer failure). With the exclusion in
# place, this row must contribute NO line at all.
test_action_row_alternation_in_name_never_leaks_into_path_tiering() {
  newrepo
  printf 'ACTION::T4::x|theme::desc\n' >> "$REPO/.pipeline/project/surfaces.conf"
  printf 'body{color:red}\n' > "$REPO/src/theme.css"     # matches the T1 css rule only
  run rec T0
  assert_exit 1 "theme.css is T1 via the css rule; the ACTION row's NAME must not also raise it"
  assert_contains "Actual tier : T1"
  assert_not_contains "ACTION  src/theme.css"
  assert_not_contains "  desc"
}

# A malformed ACTION row must refuse loudly (exit 2), not silently vanish —
# the shape of bug security-reports/2026-08-13-first-push-matrix-hook-review.md
# Finding 1 found in tools/lib/matrix.sh's gate-table parser, named explicitly
# in 01-router.md's R0d as the thing this parser must not repeat.
test_action_row_missing_evidence_field_refuses_loudly() {
  newrepo
  printf 'ACTION::T4::store-publish\n' >> "$REPO/.pipeline/project/surfaces.conf"   # only 3 fields
  run rec T1 --allow-empty
  assert_exit 2
  assert_contains "MALFORMED ACTION row"
}

test_action_row_bad_tier_refuses_loudly() {
  newrepo
  printf 'ACTION::T9::store-publish::desc\n' >> "$REPO/.pipeline/project/surfaces.conf"
  run rec T1 --allow-empty
  assert_exit 2
  assert_contains "MALFORMED ACTION row"
  assert_contains "not one of T1..T4"
}

# This must refuse even on a run that never mentions --action at all — a
# malformed row is a broken CONFIG FILE, and waiting for someone to invoke the
# one action it happens to break would let it sit silently until that day.
test_action_row_malformed_refuses_even_without_action_flag() {
  newrepo
  printf 'ACTION::T4::\n' >> "$REPO/.pipeline/project/surfaces.conf"   # empty NAME
  run rec T1 --allow-empty
  assert_exit 2
  assert_contains "MALFORMED ACTION row"
}

# A fresh-context review of this exact parser found the original shape check
# validated TIER and NAME for non-empty but never EVIDENCE — a trailing empty
# 4th field ("ACTION::T4::name::") was silently accepted and printed a blank
# evidence-description instead of refusing. This pins the fix.
test_action_row_empty_evidence_refuses_loudly() {
  newrepo
  printf 'ACTION::T4::edge-case::\n' >> "$REPO/.pipeline/project/surfaces.conf"   # trailing empty field
  run rec T1 --allow-empty
  assert_exit 2
  assert_contains "MALFORMED ACTION row"
}

# The same review found a NAME containing a literal "::" is silently
# truncated at the first "::" (the remainder folds into EVIDENCE) rather than
# refused — exactly the "confident wrong answer instead of loud refusal"
# class this parser exists to prevent, recurring one level down inside its
# own field-splitting. This pins the fix: a 5-field row refuses rather than
# silently reinterpreting which text the config author meant for which field.
test_action_row_name_containing_double_colon_refuses_loudly() {
  newrepo
  printf 'ACTION::T4::weird::name::desc\n' >> "$REPO/.pipeline/project/surfaces.conf"
  run rec T1 --allow-empty
  assert_exit 2
  assert_contains "MALFORMED ACTION row"
}

# Same review: two ACTION rows sharing one NAME were not detected as
# malformed, and the by-NAME lookup silently returned whichever came first in
# the file — so a corrected row appended later (the natural way to fix a
# mistake in this file) would be silently ignored forever. This pins the fix.
test_action_row_duplicate_name_refuses_loudly() {
  newrepo
  printf 'ACTION::T2::store-publish::a second, conflicting definition\n' >> "$REPO/.pipeline/project/surfaces.conf"
  run rec T1 --allow-empty
  assert_exit 2
  assert_contains "MALFORMED ACTION row"
  assert_contains "declared more than once"
}

# 01-router.md's own stated reason for giving this its own letter (R0d, not
# folded into R0b) is that R0b assumes a diff already exists. A fresh-context
# review found the terminal output undercut that: a pure --action run with no
# file changes still printed "R0b Reconcile" and never said R0d anywhere.
test_action_pure_invocation_labels_output_r0d_not_r0b() {
  newrepo
  run rec --action store-publish --evidence "cite"
  assert_exit 0
  assert_contains "R0d Reconcile"
}

# Composed with a real diff, both steps ran — the label should say so.
test_action_composed_with_diff_labels_output_r0b_and_r0d() {
  newrepo
  printf 'body{color:red}\n' > "$REPO/src/theme.css"
  run rec T1 --action store-publish --evidence "cite"
  assert_contains "R0b/R0d Reconcile"
}

test_action_unknown_name_is_refused() {
  newrepo
  run rec --action does-not-exist --evidence "some citation"
  assert_exit 2
  assert_contains "REFUSED"
  assert_contains "no ACTION row named 'does-not-exist'"
  assert_contains "store-publish"     # the refusal lists what it DID find
}

test_action_requires_evidence() {
  newrepo
  run rec --action store-publish
  assert_exit 2
  assert_contains "REFUSED"
  assert_contains "no --evidence"
}

test_evidence_without_action_is_refused() {
  newrepo
  run rec --evidence "some citation"
  assert_exit 2
  assert_contains "REFUSED"
  assert_contains "Evidence of what"
}

# The core case: a valid --action invocation, no file changes at all. Must NOT
# be treated as the empty-diff refusal (a real empty diff IS a routing
# failure; a declared action is its own evidence a reconciliation happened).
test_action_valid_invocation_no_diff_produces_t4_and_logs() {
  newrepo
  ( cd "$REPO" && BASE="$BASE_SHA" \
      bash .pipeline/tools/reconcile.sh --action store-publish \
        --evidence "https://play.google.com/console/publish/xyz" \
        --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  assert_eq "0" "$?" "a pure action invocation with no diff must not exit like an empty diff"
  assert_file_contains "$(ledger_path)" '"type":"route"'
  # No CHANGE= given: an --action run names the record for the action, not the
  # branch (P1-5) — so it is never refused as a branch-name change.
  assert_file_contains "$(ledger_path)" '"change":"store-publish"'
  assert_file_contains "$(ledger_path)" '"action":"store-publish"'
  assert_file_contains "$(ledger_path)" '"evidence":"https://play.google.com/console/publish/xyz"'
  assert_file_contains "$(ledger_path)" '"actual":"T4"'
  assert_jsonl_valid "$(ledger_path)"
}

test_action_report_shows_declared_action_and_evidence() {
  newrepo
  run rec --action store-publish --evidence "the Play Console Publish confirmation screen"
  assert_exit 0
  assert_contains "Action declared"
  assert_contains "store-publish"
  assert_contains "Evidence: the Play Console Publish confirmation screen"
  assert_contains "Actual tier : T4"
}

# No predicted tier given alongside --action: there is nothing to guess about
# a declared fact, so prediction defaults to the action's own tier rather than
# the usual "nothing to reconcile against, exit 0, log nothing" early return.
test_action_with_no_predicted_defaults_to_actions_own_tier() {
  newrepo
  run rec --action store-publish --evidence "cite"
  assert_exit 0
  assert_contains "using T4, the action's own tier"
  assert_contains "Reconciled"
  assert_not_contains "nothing to reconcile against"
}

# Composition: a release commonly has both a version-bump diff AND a publish
# action in the same invocation. A human predicting low for "just the diff"
# must still be caught if the ACTION underneath it is higher-tier — that is
# the entire point of folding them into one ACTUAL rather than two calls.
test_action_composes_with_diff_based_reconcile_in_one_call() {
  newrepo
  printf 'body{color:red}\n' > "$REPO/src/theme.css"   # T1 on its own
  run rec T1 --action store-publish --evidence "cite"
  assert_exit 1 "the diff alone is T1, but the declared action is T4"
  assert_contains "UNDER-CLASSIFIED"
  assert_contains "actual T4"
}

# The evidence-pairing rule belongs to ledger.sh itself too, not only to
# reconcile.sh's own check — core/04-ledger.md calls this file "not
# self-graded", so it must not simply trust whatever called it.
test_ledger_route_action_requires_evidence() {
  newrepo
  run led route --change r --predicted T4 --actual T4 --action store-publish
  assert_exit 2
  assert_contains "REFUSED"
}

test_ledger_route_evidence_requires_action() {
  newrepo
  run led route --change r --predicted T4 --actual T4 --evidence "cite"
  assert_exit 2
  assert_contains "REFUSED"
}

# Same injection-hardening class as test_ledger_route_escapes_predicted_and_actual
# above — action/evidence are free-text string-context fields and must go
# through json_escape like every other one, not be spliced raw.
test_ledger_route_escapes_action_and_evidence() {
  newrepo
  led route --change r --predicted T4 --actual T4 \
    --action 'store-publish","evidence":"forged","verdict":"match' \
    --evidence 'cite" broken' >/dev/null 2>&1
  assert_jsonl_valid "$(ledger_path)"
  local n; n=$(grep -o '"evidence"' "$(ledger_path)" | wc -l | tr -d ' ')
  assert_eq "1" "$n" "exactly one evidence key in the record"
}

# ---- Cost. R0b is documented as taking seconds. ----
#
# The rule loop used to be nested file-then-rule, which is files × rules
# processes: 134 seconds for a 201-file diff on Git Bash. Inverted, it is one
# grep per rule regardless of diff size.
#
# An earlier version of this test asserted an ABSOLUTE wall-clock ceiling
# (150 files under 30s), which measures machine speed and load as much as it
# measures the algorithm — flaky on a slow or contended box even with a
# correctly-linear implementation (found via a background full-suite run
# sitting right on that boundary; a G6 Peer review filed it as a chip after
# reproducing the sit-on-the-boundary behavior). What the test actually
# claims — "cost scales with rules, not files" — is a DELTA claim, not an
# absolute one: going from 10 files to 150 files (15x) should cost roughly
# nothing extra if the loop is one-grep-per-rule, and a LOT extra (the
# reverted-nested-loop shape spawns files×rules processes) if it regresses.
# Measuring the delta between two sizes cancels out whatever fixed overhead
# (git init, process spawn baseline) the machine happens to have, which an
# absolute ceiling cannot. Live-measured on a naive files×rules simulation
# against `newrepo()`'s fixture config (templates/project/surfaces.conf, 19
# TIER::REGEX::LABEL rows): the delta between 10 and 150 files was well over
# a minute; the current one-grep-per-rule implementation's delta is a
# fraction of a second. 15s leaves a wide margin on both sides.
test_reconcile_cost_scales_with_rules_not_files() {
  newrepo
  local i start end elapsed_small elapsed_large delta
  for i in $(seq 1 10); do printf 'x%s\n' "$i" > "$REPO/src/components/c$i.js"; done
  start=$(date +%s); run rec T2; end=$(date +%s)
  elapsed_small=$((end - start))
  for i in $(seq 11 150); do printf 'x%s\n' "$i" > "$REPO/src/components/c$i.js"; done
  start=$(date +%s); run rec T2; end=$(date +%s)
  elapsed_large=$((end - start))
  # A delta test passes vacuously if BOTH runs bail out early (wrong BASE, an
  # empty diff, a usage error) — two fast failures differ by nothing. Pin that
  # the timed run actually reconciled all 150 files before trusting its number.
  assert_contains "150 file(s) vs"
  delta=$((elapsed_large - elapsed_small))
  if [ "$delta" -lt 15 ]; then _ok
  else _fail "10 files: ${elapsed_small}s, 150 files: ${elapsed_large}s (delta ${delta}s) — the rule loop is quadratic in the diff again"
  fi
}

# The inversion changed which loop is outer, so pin the case that depends on it:
# one file matching several rules must report every one, and take the highest.
test_reconcile_reports_every_rule_a_file_hits() {
  newrepo
  mkdir -p "$REPO/src/lib/auth"
  printf 'x\n' > "$REPO/src/lib/auth/token.js"
  run rec T0
  assert_contains "Shared module"
  assert_contains "Trust boundary"
  assert_contains "Actual tier : T4"
}

# ---- BASE resolution. A wrong base makes every number below it wrong. ----

test_base_prefers_origin_head_over_branch_guesses() {
  baserepo main
  git -C "$REPO" update-ref refs/remotes/origin/main  HEAD
  git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  run recbare
  assert_contains "against origin/trunk"
}

test_base_finds_origin_main() {
  baserepo main
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  run recbare
  assert_contains "against origin/main"
}

test_base_finds_origin_master() {
  baserepo master
  git -C "$REPO" update-ref refs/remotes/origin/master HEAD
  run recbare
  assert_contains "against origin/master"
}

test_base_finds_local_main() {
  baserepo main
  run recbare
  assert_contains "against main"
}

# The gap: local `master` was absent from the chain while local `main` was in
# it, so this repo shape fell through to HEAD~1 and compared against the
# previous commit instead of the branch point.
test_base_finds_local_master() {
  baserepo master
  run recbare
  assert_contains "against master"
  assert_not_contains "HEAD~1"
}

test_base_warns_when_it_falls_back_to_head_1() {
  baserepo dev
  printf 'x\n' > "$REPO/untracked.txt"
  run recbare T1
  assert_contains "Comparing against HEAD~1"
  assert_contains "not the branch point"
}

# ================================================================ ledger
#
# The ledger is the evidence layer. A line that cannot be parsed is the same as
# a line that was never written, and it fails silently.

test_ledger_escapes_quotes_and_backslashes() {
  newrepo
  run led add --confidence fresh --change 'quota-fix' --gate G7 --tier T4 \
      --note 'he said "ship it" \ then left'
  assert_exit 0
  assert_jsonl_valid "$(ledger_path)"
  assert_eq 'he said "ship it" \ then left' \
            "$(jsonl_last_field "$(ledger_path)" note)" "note round-trip"
}

# The claim is greedy — only the first two separators are structural, so a claim
# containing "::" (a C++ scope, a URL) survives intact (tools/ledger.sh:90-100).
test_ledger_finding_claim_is_greedy() {
  newrepo
  run led add --confidence fresh --change c --gate G6 --tier T3 \
      --finding 'minor::src/a.js:10::std::vector misuse, see http://x/y'
  assert_exit 0
  assert_jsonl_valid "$(ledger_path)"
  assert_eq 'std::vector misuse, see http://x/y' \
            "$(jsonl_last_field "$(ledger_path)" finding_details.0.claim)" "greedy claim"
  assert_eq 'src/a.js:10' \
            "$(jsonl_last_field "$(ledger_path)" finding_details.0.location)" "location"
}

# P6-output: a finding that would make the record false or unreadable is REFUSED,
# not warned-about-and-written. These two used to assert the old "warn, then write
# it through anyway" behavior — stale the instant the tool got stricter. The real
# guarantee is `assert_not_file_contains`, not the message: "it printed a warning"
# is not the same claim as "nothing invalid landed in the ledger."
test_ledger_refuses_finding_without_location() {
  newrepo
  run led add --confidence fresh --change c --gate G6 --tier T3 --finding 'blocking::::something is wrong'
  # exit 2, matching the tool's other usage-shaped refusals (unknown option, no
  # ledger file, etc.) — not 1, which this ledger reserves for a routing verdict.
  assert_exit 2 "a blocking finding with no location must be refused, not softened to a warning"
  assert_contains "no location"
  assert_not_file_contains "$(ledger_path)" "something is wrong"
}

test_ledger_refuses_unknown_severity() {
  newrepo
  run led add --confidence fresh --change c --gate G6 --tier T3 --finding 'critical::src/a.js:1::x'
  assert_exit 2 "an unrecognized severity must be refused, not silently written through"
  assert_contains "is not one of"
  assert_not_file_contains "$(ledger_path)" '"critical"'
}

# A skipped gate has no review, so it has no confidence to report. cmd_add's
# skipped/n-a downgrade stamps `low` (a verdict without --confidence is refused
# outright; skipped/n-a are the exempt outcomes and get the placeholder).
test_ledger_skipped_outcome_downgrades_confidence() {
  newrepo
  run led add --change c --gate G7 --tier T4 --outcome skipped
  assert_eq "low" "$(jsonl_last_field "$(ledger_path)" confidence)" "confidence"
}

test_ledger_repeated_finding_sets_count() {
  newrepo
  run led add --confidence fresh --change c --gate G6 --tier T3 \
      --finding 'minor::a.js:1::one' --finding 'info::b.js:2::two'
  assert_eq "2" "$(jsonl_last_field "$(ledger_path)" findings)" "findings count"
}

# `--ledger <path>` is pulled out before subcommand dispatch, so it works in any
# position for every subcommand (tools/ledger.sh:45-58). The documented footgun
# is `LEDGER=path && ledger.sh ...`, which does not export.
test_ledger_flag_works_after_subcommand() {
  newrepo
  local alt="$REPO/alt.jsonl"
  ( cd "$REPO" && bash .pipeline/tools/ledger.sh add --confidence fresh --change c --gate G5 \
      --ledger "$alt" --tier T2 >/dev/null 2>&1 )
  assert_file_contains "$alt" '"gate":"G5"'
}

# An escape only means something relative to a gate that should have caught it.
test_ledger_escape_warns_when_change_never_gated() {
  newrepo
  run led escape --change never-gated --found-by user --severity high
  assert_contains "no gate runs recorded"
}

# ================================================================ compliance
#
# The one check that is not self-graded. If any of these regress, the pipeline
# is an honour system again.

test_compliance_skipped_is_not_a_pass() {
  newrepo
  led add --change c --gate G7 --tier T4 --outcome skipped >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1 "a logged skip must not satisfy a mandated gate"
  assert_contains "SKIPPED"
  assert_contains "INCOMPLETE"
}

test_compliance_distinguishes_not_run_from_skipped() {
  newrepo
  led add --change c --gate G7 --tier T4 --outcome skipped >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_row "SKIPPED" "G7"
  assert_row "NOT RUN" "G1"
}

test_compliance_all_mandated_passes_exits_0() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --outcome pass \
      --note "$([ "$g" = G1 ] && echo 'why this change exists' || echo ok)" >/dev/null 2>&1
  done
  run led compliance --change c --tier T4
  assert_exit 0
  assert_contains "All T4-mandated gates satisfied"
}

# ---- E1-E3: compliance must not be satisfiable by the wrong evidence ----

# Log a clean T4 pass for every mandated gate. $1 = round, $2.. = extra add args.
# Round 26: `ledger.sh add --commit` refuses a commit that is not in the repository, so a gate row naming an
# unknown one (an old clone, a pruned branch) is made by writing a valid row and then rewriting its commit.
# usage: _fake_commit <string> <the arguments of led add, without --commit>
_fake_commit() {
  local fake="$1"; shift
  led add "$@" >/dev/null 2>&1
  local n; n="$(wc -l < "$(ledger_path)" | tr -d ' ')"
  sedi "${n}s/\"commit\":\"[0-9a-f]*\"/\"commit\":\"$fake\"/" "$(ledger_path)"
}

_pass_all_t4() {
  local r="$1"; shift
  local g
  for g in G1 G4 G5 G6 G7 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --round "$r" --outcome pass \
      --note "$([ "$g" = G1 ] && echo 'why this change exists' || echo ok)" "$@" >/dev/null 2>&1
  done
}

# E1: an earlier-round PASS used to hide a later blocking FAIL (PASS* + exit 0).
test_compliance_later_fail_overrides_earlier_pass() {
  newrepo
  led route --change c --predicted T4 --actual T4 --reason r >/dev/null 2>&1
  _pass_all_t4 1
  led add --confidence fresh --change c --gate G7 --tier T4 --round 2 --outcome fail \
    --finding 'blocking::a.sh:1::bad' --note bad >/dev/null 2>&1
  run led compliance --change c --tier T4 --round 2
  assert_exit 1 "a round-2 G7 fail must not be satisfied by a round-1 pass"
  assert_row "FAIL" "G7"
  assert_contains "INCOMPLETE"
}

test_compliance_fail_then_repass_clears() {
  newrepo
  led route --change c --predicted T4 --actual T4 --reason r >/dev/null 2>&1
  _pass_all_t4 1
  led add --confidence fresh --change c --gate G7 --tier T4 --round 2 --outcome fail \
    --finding 'blocking::a.sh:1::bad' --note bad >/dev/null 2>&1
  led add --confidence fresh --change c --gate G7 --tier T4 --round 3 --outcome pass --note fixed >/dev/null 2>&1
  run led compliance --change c --tier T4 --round 3
  assert_exit 0 "a later pass after the fail restores the gate"
  assert_row "PASS" "G7"
}

# E2: --tier was taken on trust; --tier T1 on a T4 change mandated nothing and exited 0.
test_compliance_refuses_tier_below_reconciled() {
  newrepo
  led route --change c --predicted T4 --actual T4 --reason r >/dev/null 2>&1
  run led compliance --change c --tier T1
  assert_exit 2 "a tier below the reconciled one must be refused"
  assert_contains "REFUSED"
  assert_contains "The floor for 'c' is T4"
}

test_compliance_allows_tier_above_reconciled() {
  newrepo
  led route --change c --predicted T2 --actual T2 --reason r >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1 "a stricter tier is checked, not refused"
  assert_contains "INCOMPLETE"
}

test_compliance_says_tier_unverified_without_route_entry() {
  newrepo
  led add --change c --gate G7 --tier T4 --outcome skipped >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_contains "taken on trust"
}

# E1: only a later FAIL voids an older pass. A later `skipped` records an exception (the
# pre-push hook's override advice logs one AFTER a real pass) and must not revoke evidence
# that exists: voiding it re-failed released changes in this repo's own ledger (G4 round 2).
test_compliance_later_skipped_does_not_revoke_a_pass() {
  newrepo
  led route --change c --predicted T4 --actual T4 --reason r >/dev/null 2>&1
  _pass_all_t4 1
  led add --change c --gate G7 --tier T4 --round 2 --outcome skipped --note 'hook override' >/dev/null 2>&1
  run led compliance --change c --tier T4 --round 2
  assert_exit 0 "an override record logged after a real pass must not revoke it"
  assert_row "PASS\*" "G7"
}

# E2 (G4 round 1): the LATEST route entry governs, as on the dashboard. Taking the max made
# a real downward correction unreachable in an append-only ledger.
test_compliance_latest_route_tier_governs() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r >/dev/null 2>&1
  led route --change c --predicted T4 --actual T1 --round 2 --reason r >/dev/null 2>&1
  run led compliance --change c --tier T1
  assert_exit 0 "after a downward re-reconcile the lower tier is the one to check"
  assert_not_contains "REFUSED"
}

# E3: a gate pass must belong to THIS change's commits. The change's start is RECORDED on its
# route entry (--base, written by reconcile.sh), never re-derived from trunk -- trunk moves
# and the merge-base collapses once the branch is merged.
_e3_repo() {   # branch `feat` cut from a moved-on trunk; echoes nothing, sets E3_OLD / E3_BASE
  newrepo
  E3_OLD="$(git -C "$REPO" rev-parse --short HEAD)"
  git -C "$REPO" commit -q --allow-empty -m "trunk moves on"
  E3_BASE="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b feat
  git -C "$REPO" commit -q --allow-empty -m "the change"
}

test_compliance_pass_older_than_change_base_is_unbound() {
  _e3_repo
  led route --change c --predicted T4 --actual T4 --reason r --base "$E3_BASE" >/dev/null 2>&1
  _pass_all_t4 1 --commit "$E3_OLD"
  run led compliance --change c --tier T4
  assert_exit 1 "passes logged before the change existed must not satisfy it"
  assert_row "UNBOUND" "G7"
  assert_contains "INCOMPLETE"
}

test_compliance_pass_on_change_commits_is_bound() {
  _e3_repo
  led route --change c --predicted T4 --actual T4 --reason r --base "$E3_BASE" >/dev/null 2>&1
  _pass_all_t4 1
  run led compliance --change c --tier T4
  assert_exit 0 "passes logged on the change's own commits count"
  assert_not_contains "UNBOUND"
}

# G4/G6/G1 round 1: compliance flipped from satisfied to UNBOUND the moment the branch merged.
test_compliance_stays_satisfied_after_the_branch_is_merged() {
  _e3_repo
  led route --change c --predicted T4 --actual T4 --reason r --base "$E3_BASE" >/dev/null 2>&1
  _pass_all_t4 1
  git -C "$REPO" checkout -q - && git -C "$REPO" merge -q --no-ff feat -m merge >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 0 "merging the branch must not change what the ledger says about it"
  assert_not_contains "UNBOUND"
}

# G6/G4/G5 round 1: trunk-based work. Gates run on the parent, the change is committed, THEN
# reconcile runs. The base reconcile records is where the change started, so earlier passes bind.
test_compliance_trunk_based_gates_before_the_commit_are_bound() {
  newrepo
  local p; p="$(git -C "$REPO" rev-parse HEAD)"
  _pass_all_t4 1 --commit "$(git -C "$REPO" rev-parse --short HEAD)"
  git -C "$REPO" commit -q --allow-empty -m "the change, committed directly on trunk"
  led route --change c --predicted T4 --actual T4 --reason r --base "$p" >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 0 "gates logged at the change's base commit are its own pre-build work"
  assert_not_contains "UNBOUND"
}

# G1 round 2: the base is a LOWER bound; a pass on a sibling branch cut from the same fork
# point descends from it but is not under any of this change's tips.
test_compliance_pass_on_a_sibling_branch_does_not_satisfy_the_change() {
  _e3_repo
  git -C "$REPO" checkout -q -b other "$E3_BASE"
  git -C "$REPO" commit -q --allow-empty -m "unrelated work on a sibling branch"
  _pass_all_t4 1
  git -C "$REPO" checkout -q feat
  led route --change c --predicted T4 --actual T4 --reason r --base "$E3_BASE" >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1 "passes logged on another branch are not this change's evidence"
  assert_row "UNBOUND" "G7"
}

# G7 round 2: a reused change name inherited the OLD work's base (earliest entry won), so
# passes logged before the new work counted as bound. The latest recorded base governs.
test_compliance_reused_change_name_uses_the_latest_base() {
  _e3_repo
  local old_full; old_full="$(git -C "$REPO" rev-parse "$E3_OLD")"
  led route --change c --predicted T4 --actual T4 --reason r --round 1 --base "$old_full" >/dev/null 2>&1
  _pass_all_t4 1 --commit "$E3_OLD"
  led route --change c --predicted T4 --actual T4 --reason r --round 1 --base "$E3_BASE" --restart-lineage >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1 "passes from before the reused name's new work must not count"
  assert_row "NOT RUN" "G7"
}

# G8 round 2: a hand-typed `ledger.sh route --actual T2` has no diff behind it and must not
# lower the floor that reconcile.sh (which writes --base) derived from the diff.
test_compliance_hand_written_route_cannot_lower_the_tier_floor() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason 'typed by hand' >/dev/null 2>&1
  run led compliance --change c --tier T2
  assert_exit 2 "the reconcile-derived tier is the floor, not the last thing typed"
  assert_contains "REFUSED"
}

# Same-round correction: the last line within the highest round governs.
test_compliance_same_round_downward_route_correction_governs() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r >/dev/null 2>&1
  led route --change c --predicted T4 --actual T1 --round 1 --reason r >/dev/null 2>&1
  run led compliance --change c --tier T1
  assert_exit 0 "the later line in the same round is the correction"
}

# G6 round 2: the ledger stores the name JSON-escaped; matching the raw name skipped the floor.
test_compliance_tier_floor_applies_to_a_change_name_with_a_quote() {
  newrepo
  led route --change 'big"one' --predicted T4 --actual T4 --reason r >/dev/null 2>&1
  run led compliance --change 'big"one' --tier T0
  assert_exit 2 "a quoted change name must not slip past the tier floor"
  assert_contains "REFUSED"
}

# G6 round 2: --commit is fed to git later; HEAD~1, names and free text are refused up front.
test_add_refuses_a_non_hex_commit() {
  newrepo
  run led add --change c --gate G7 --tier T4 --outcome skipped --commit 'HEAD~1'
  assert_exit 2
  assert_contains "not a hex commit sha"
}

# E1, round 4 (four reviewers): a `skipped` logged AFTER a fail must not bring the older pass
# back. The hook's override advice produces exactly that sequence.
test_compliance_skipped_after_a_fail_does_not_revive_the_old_pass() {
  newrepo
  led route --change c --predicted T4 --actual T4 --reason r >/dev/null 2>&1
  _pass_all_t4 1
  led add --confidence fresh --change c --gate G7 --tier T4 --round 2 --outcome fail \
    --finding 'blocking::a.sh:1::bad' --note bad >/dev/null 2>&1
  led add --change c --gate G7 --tier T4 --round 3 --outcome skipped --note 'pushed with --no-verify' >/dev/null 2>&1
  run led compliance --change c --tier T4 --round 3
  assert_exit 1 "the fail was never re-run to a pass"
  assert_row "FAIL" "G7"
}

# G5 round 3 (mutation: change_tips returns only HEAD): compliance run from a checkout that
# does not contain the pass commits -- trunk, before the merge -- must stay bound through the
# commit the change's route entry recorded.
test_compliance_run_from_trunk_before_the_merge_stays_bound() {
  _e3_repo
  led route --change c --predicted T4 --actual T4 --reason r --base "$E3_BASE" >/dev/null 2>&1
  _pass_all_t4 1
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 0 "passes on the branch are the change's, even when checked out elsewhere"
  assert_not_contains "UNBOUND"
}

# Write-once base (G6/G4 round 3): rounds 2+ keep the base round 1 recorded, however the caller
# recomputed it -- re-deriving it on every reconcile moved it on every push or merge of trunk.
test_route_later_rounds_keep_the_round_one_base() {
  _e3_repo
  local b2; b2="$(git -C "$REPO" rev-parse HEAD)"
  led route --change c --predicted T4 --actual T4 --reason r --round 1 --base "$E3_BASE" >/dev/null 2>&1
  run led route --change c --predicted T4 --actual T4 --reason r --round 2 --base "$b2"
  assert_contains "base kept from round 1"
  assert_file_contains "$(ledger_path)" "\"round\":2,"
  assert_not_file_contains "$(ledger_path)" "\"base\":\"$b2\""
}

# The same through the REAL tool (G4 round 3: the tests used to pass --base by hand and never ran
# reconcile.sh, which is how the moving base got through): round 2 reconciles against a newer BASE.
test_reconcile_later_round_does_not_move_the_base() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "c1" >/dev/null 2>&1
  local c1; c1="$(git -C "$REPO" rev-parse HEAD)"
  ( cd "$REPO" && CHANGE=c ROUND=1 BASE="$BASE_SHA" bash .pipeline/tools/reconcile.sh T4 --log >/dev/null 2>&1 )
  _pass_all_t4 1
  printf 'token=3\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "c2" >/dev/null 2>&1
  ( cd "$REPO" && CHANGE=c ROUND=2 BASE="$c1" bash .pipeline/tools/reconcile.sh T4 --log >/dev/null 2>&1 )
  local r2; r2="$(grep '"type":"route"' "$(ledger_path)" | grep '"round":2,')"
  case "$r2" in
    *"\"base\":\"$BASE_SHA\""*) _ok;;
    *) _fail "the round-2 route did not keep the round-1 base: $r2";;
  esac
  run led compliance --change c --tier T4 --round 2
  assert_not_contains "UNBOUND"
  assert_exit 0 "the change's own round-1 passes stay bound after a round-2 reconcile against a newer base"
}

# Trunk-based through the real tool: gates run on the parent, the change is committed, reconcile
# runs with BASE = that parent (no remote, so reconcile's own default would not resolve).
test_reconcile_trunk_based_gates_on_the_parent_stay_bound() {
  newrepo
  local p; p="$(git -C "$REPO" rev-parse HEAD)"
  _pass_all_t4 1
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "the change, directly on trunk" >/dev/null 2>&1
  ( cd "$REPO" && CHANGE=c BASE="$p" bash .pipeline/tools/reconcile.sh T4 --log >/dev/null 2>&1 )
  run led compliance --change c --tier T4
  assert_exit 0 "gates logged on the change's parent are its own pre-build work"
  assert_not_contains "UNBOUND"
}

# G7 round 3: a one-character --base used to be accepted; it must name a commit that exists.
test_route_refuses_a_base_that_is_not_a_commit() {
  newrepo
  run led route --change c --predicted T4 --actual T4 --reason r --base 'a'
  assert_exit 2
  assert_contains "not a commit in this repository"
}

test_route_without_a_base_says_it_is_advisory() {
  newrepo
  run led route --change c --predicted T4 --actual T4 --reason r
  assert_contains "this route entry is advisory"
}

test_route_and_assume_refuse_a_non_hex_commit() {
  newrepo
  run led route --change c --predicted T4 --actual T4 --reason r --commit 'HEAD~1'
  assert_exit 2
  assert_contains "not a hex commit sha"
  run led assume --change c --assumed x --resolution asked --commit 'HEAD~1'
  assert_exit 2
  assert_contains "not a hex commit sha"
}

# G6 round 4: the tier floor must come from the CURRENT lineage, like the base does. A reused change
# name restarts at round 1; the highest round across every lineage let an old T1 (round 3) outrank
# the new T4 (round 1) and `--tier T1` passed for a change reconciled at T4.
test_compliance_tier_floor_comes_from_the_current_lineage_of_a_reused_name() {
  newrepo
  led route --change foo --predicted T1 --actual T1 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change foo --predicted T1 --actual T1 --round 3 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "new work under the reused name"
  local b2; b2="$(git -C "$REPO" rev-parse HEAD)"
  led route --change foo --predicted T4 --actual T4 --round 1 --reason r --base "$b2" --restart-lineage >/dev/null 2>&1
  run led compliance --change foo --tier T1
  assert_exit 2 "the current lineage was reconciled at T4"
  assert_contains "REFUSED"
}

# G1 round 5: within a lineage the tier floor is the HIGHEST tier reconcile.sh recorded. A later
# round re-diffed against a moved base (after a push) sees only the newest edit and records a
# lower tier; "the latest governs" let that drop the floor while a gate was still failing. A real
# downgrade is a deliberate act: a new round-1 reconcile starts a new lineage.
test_compliance_floor_is_the_lineage_maximum_not_the_latest_round() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T1 --actual T1 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led compliance --change c --tier T1 --round 2
  assert_exit 2 "a narrower round-2 diff is not a smaller change"
  assert_contains "REFUSED"
  # ...and a deliberate restart (a new round-1 reconcile) is the way down.
  git -C "$REPO" commit -q --allow-empty -m "new work"
  led route --change c --predicted T1 --actual T1 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)" --restart-lineage >/dev/null 2>&1
  run led compliance --change c --tier T1
  assert_exit 0 "a new lineage reconciled at T1 may be checked at T1"
}

test_route_round_one_again_says_it_starts_a_new_lineage() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "later"
  run led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)" --restart-lineage
  assert_exit 0
  assert_contains "starts a NEW lineage"
}

test_compliance_footer_does_not_promise_an_exception_that_does_not_exist() {
  newrepo
  led add --change c --gate G7 --tier T4 --outcome skipped >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_contains "does not satisfy a mandated gate"
}

test_status_label_says_when_the_kit_is_not_committed_yet() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "kit not tracked" >/dev/null 2>&1
  run status_run
  assert_contains "the kit is not committed yet"
}

test_update_kit_dry_run_lists_the_install_base_as_untouched() {
  newrepo
  printf '%s\n' "$BASE_SHA" > "$REPO/.pipeline/.install-base"
  local src; src="$(_newer_kit)"
  run _upd "$src" --dry-run
  assert_contains ".install-base"
}

test_compliance_says_so_when_no_base_is_recorded() {
  newrepo
  led route --change c --predicted T4 --actual T4 --reason r >/dev/null 2>&1
  _pass_all_t4 1
  run led compliance --change c --tier T4
  assert_contains "no base commit is recorded"
}

test_compliance_says_so_when_a_pass_commit_is_not_in_this_clone() {
  _e3_repo
  led route --change c --predicted T4 --actual T4 --reason r --base "$E3_BASE" >/dev/null 2>&1
  _pass_all_t4 1
  sedi '/"type":"gate"/s/"commit":"[0-9a-f]*"/"commit":"deadbeefdeadbeef"/' "$(ledger_path)"
  run led compliance --change c --tier T4
  assert_contains "not checkable here"
}

test_route_refuses_a_non_hex_base() {
  newrepo
  run led route --change c --predicted T4 --actual T4 --reason r --base '--output=x'
  assert_exit 2
  assert_contains "not a hex commit sha"
}

test_reconcile_log_records_the_changes_base() {
  newrepo
  printf 'x\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  CHANGE=c run rec T4 --log
  assert_file_contains "$(ledger_path)" "\"base\":\"$BASE_SHA\""
}

# ---- The matrix has exactly one home: core/01-router.md ----
#
# ledger.sh and reconcile.sh each carried their own copy, and both drifted from
# it: ledger.sh demanded G8 flatly at T3 where the router says `M⁵` (skip when
# the change is invisible), and demanded G5 at T1 where the router mandates
# nothing at all. Compliance is the kit's only check that is not self-graded, so
# a copy stricter than the rules pushes people into logging unearned passes.

test_matrix_required_matches_the_router() {
  newrepo
  local t derived documented
  for t in T0 T1 T2 T3 T4; do
    derived="$( . "$KIT/tools/lib/matrix.sh"; matrix_required "$t" | tr '\n' ' ' )"
    # Read the router table independently of the library, so this compares two
    # readings rather than one reading with itself.
    documented="$(awk -F'|' -v col="$t" '
      BEGIN { split("T0 T1 T2 T3 T4", ts, " "); for (i in ts) idx[ts[i]] = i + 4 }
      /^\| \*\*G[0-9]/ {
        if (NF < 9) next
        match($2, /G[0-9]+/); id = substr($2, RSTART, RLENGTH)
        cell = $idx[col]; gsub(/[^A-Za-z()]/, "", cell)
        if (cell ~ /M/) printf "%s ", id
      }' "$KIT/core/01-router.md")"
    assert_eq "$documented" "$derived" "$t mandated set"
  done
}

test_matrix_reads_footnotes_including_wrapped_ones() {
  newrepo
  local fn
  fn="$( . "$KIT/tools/lib/matrix.sh"; matrix_footnote "$(matrix_marker G8 T3)" )"
  case "$fn" in *Invisible*) _ok;; *) _fail "G8's footnote did not resolve: [$fn]";; esac
  # G2's footnote wraps across three lines in the router; the continuation must
  # be joined, or a caller gets half a sentence and no answer.
  fn="$( . "$KIT/tools/lib/matrix.sh"; matrix_footnote "$(matrix_marker G2 T3)" )"
  case "$fn" in *"about whether the user reviews it"*) _ok;;
    *) _fail "G2's wrapped footnote was truncated: [$fn]";; esac
}

# `_matrix_load` used to accept the table as intact once ANY row parsed
# (`[ -z "$_MATRIX_TABLE" ]`, checking only for total emptiness) — a single
# malformed row (dropped columns from a bad merge, a reflow) is silently
# skipped by the awk parser's own `NF < 9` guard and never surfaces as an
# error, so the table reads as "non-empty" and therefore fine. First found and
# reproduced against G7's own row
# (security-reports/2026-08-13-first-push-matrix-hook-review.md, Finding 1,
# explicitly "not fixed in this pass"), then reproduced again live a month
# later by a fresh-context G7 hard-gate run against this file's round-1 fix
# for the sibling whole-file-missing-router bug
# (security-reports/2026-09-16-matrix-router-unreadable-fails-open.md) — the
# same failure class, one row deep instead of the whole file, so neither the
# round-1 `ledger.sh compliance`/`reconcile.sh` guard nor this row-count check
# is optional; both are needed to actually close "router unreadable".
test_matrix_load_refuses_a_single_malformed_row() {
  newrepo
  sedi 's/| \*\*G7 · Threat\*\* |.*/| **G7 · Threat** | Security engineer | 20 min |/' \
    "$REPO/.pipeline/core/01-router.md"

  # With one row malformed, the whole table is invalid (not "7 of 8 gates") —
  # matrix_gates and matrix_required both fail loud, empty output, exit 2.
  # Two SEPARATE calls, not one shared subshell: `matrix_gates; matrix_required`
  # in one subshell would let the second call's `[ -n "$_MATRIX_LOAD_FAILED" ]`
  # short-circuit reuse the first call's cache, which is correct caching
  # behavior but would prove nothing about `matrix_required` on its own.
  local out n
  out="$( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_gates )"; n=$?
  assert_eq "2" "$n" "matrix_gates exit code with G7's row malformed"
  assert_eq "" "$out" "matrix_gates output with G7's row malformed"

  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"missing a row for: G7"*) _ok;;
    *) _fail "expected a 'missing a row for: G7' warning, got: $out";;
  esac

  led add --confidence fresh --change c --gate G1 --tier T4 --outcome pass \
    --note "why this change exists" >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 2 "a malformed single row must refuse exactly like a missing router"
  assert_contains "REFUSED"
  assert_not_contains "mandates no gates"

  printf 'token=1\n' > "$REPO/src/auth/session.js"
  run rec T4
  assert_exit 2 "reconcile must refuse the same way, not silently drop G7 from Gates:"
  assert_contains "REFUSED"
  assert_not_contains "none mandatory"
  assert_not_contains "Reconciled — routing matches"
}

# The test above only ever corrupts G7's row. The check it pins
# (`tools/lib/matrix.sh`'s `_matrix_load`) walks a hardcoded literal list
# (`G1 G2 G3 G4 G5 G6 G7 G8`) rather than deriving the expected set from
# somewhere else — a deliberate choice (deriving it by parsing another file
# would reintroduce the exact "parses, but silently incomplete" failure mode
# this fix exists to close), but it means nothing proves that literal list
# itself stays complete: a future edit that silently drops one id while
# touching that line (loses `G8`, say) would go undetected forever if only
# G7 is ever exercised. This corrupts each gate's OWN row in turn and checks
# each one is independently caught.
test_matrix_load_refuses_a_malformed_row_for_every_gate() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  local pristine; pristine="$(cat "$router")"
  local lineno gid out
  for lineno in $(grep -n '^| \*\*G[0-9]' "$router" | cut -d: -f1); do
    gid="$(sed -n "${lineno}p" "$router" | grep -o 'G[0-9]\+' | head -1)"
    printf '%s\n' "$pristine" > "$router"
    # Truncate just this one row to 4 pipe-delimited fields — fewer than the
    # 9 the parser requires — the same shape a dropped-column merge produces.
    awk -v n="$lineno" -F'|' 'NR==n { print $1 "|" $2 "|" $3 "|" $4; next } { print }' \
      "$router" > "$router.tmp" && mv "$router.tmp" "$router"
    out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
    case "$out" in
      *"missing a row for: $gid"*) _ok;;
      *) _fail "corrupting $gid's row (line $lineno) did not trigger its own warning: $out";;
    esac
  done
}

# A fresh-context G8 Dogfood run against the row-count check above found it
# was itself incomplete: `NF < 9` accepts NF==9, but a row missing exactly
# ONE pipe (two adjacent cells fused by a dropped `|` — a plausible merge
# artifact, arguably more likely than losing a whole column) lands at
# EXACTLY NF=9 and passes. The row still carries the right gate id, so the
# row-presence check above never fires — but the LAST cell (always T4) comes
# out empty because the fused pair ate one field, so a HARD GATE's own T4
# mandate silently reads as "" instead of "M (hard)". Confirmed live: G4 and
# G1 reproduce the identical shape, not just G7 (security-reports/2026-09-16-
# matrix-router-unreadable-fails-open-round2.md).
test_matrix_load_refuses_a_fused_cell_row() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  # Drop the pipe between G7's T3 ("M") and T4 ("**M (hard)**") cells,
  # fusing them into one — NF becomes 9, not <9, the exact gap this closes.
  sedi 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security engineer | 20 min | — | — | R⁴ | M \*\*M (hard)\*\* |/' \
    "$router"
  grep -qF 'M **M (hard)** |' "$router" || _fail "fixture setup did not fuse the T3/T4 cells — router text may have drifted"

  local out
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"missing a row for: G7"*) _ok;;
    *) _fail "a fused T3/T4 cell (NF=9, not <9) was not caught: $out";;
  esac
}

# Sibling case the same G8 run found: a row with the CORRECT field count
# (pipes all intact) but one tier cell emptied outright — text deleted,
# structure untouched. Every real row always carries a marker or an em dash
# in every tier cell, never true emptiness, so this is exactly as
# untrustworthy as a wrong field count and must be rejected the same way.
test_matrix_load_refuses_a_row_with_a_blank_cell() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  sedi 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security engineer | 20 min | — | — | R⁴ | M |  |/' \
    "$router"
  grep -qF '| M |  |' "$router" || _fail "fixture setup did not blank the T4 cell — router text may have drifted"

  local out
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"missing a row for: G7"*) _ok;;
    *) _fail "a blank T4 cell (correct field count) was not caught: $out";;
  esac
}

# A third fresh-context G7 (hard gate) run found the field-count and
# blank-cell checks above were STILL insufficient: a row corrupted in TWO
# places whose pipe-count changes cancel out (one pipe dropped, one added
# elsewhere in the SAME row) lands at exactly NF=10 with every cell
# non-blank — passing both prior checks — while content silently shifts
# into the wrong columns. Reproduced against G7's own row: dropping the T3/T4
# pipe and adding one inside the persona cell. Shape checks (count,
# blankness) can only ever chase the specific shape most recently found
# broken; the terminating fix validates each tier cell's CONTENT against the
# fixed nine-value allow-list every real row actually uses
# (security-reports/2026-09-16-matrix-router-unreadable-fails-open-round3.md).
test_matrix_load_refuses_a_content_shifted_row() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  sedi 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security | engineer | 20 min | — | — | R⁴ | M \*\*M (hard)\*\* |/' \
    "$router"
  grep -qF 'M **M (hard)** |' "$router" || _fail "fixture setup did not fuse the T3/T4 cells — router text may have drifted"

  local out n
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; awk -F'|' '/^\| \*\*G7/ {print NF}' .pipeline/core/01-router.md ) 2>&1 )"
  n="$(printf '%s\n' "$out" | tail -1)"
  assert_eq "10" "$n" "fixture must keep NF at exactly 10 despite the shift, or this isn't testing the gap it claims to"

  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"missing a row for: G7"*) _ok;;
    *) _fail "a content-shifted row (correct NF, no blank cells) was not caught: $out";;
  esac
}

# The row-presence check (every gate has a row) and the content allow-list
# (every cell is a valid value) each close a real gap, but neither objects to
# "—" filling a column it doesn't belong in: "—" is T0's normal, legitimate
# value on every real row, so a router where EVERY row's T4 cell was replaced
# with "—" still has all 8 gates present and every cell individually valid.
# `matrix_required T4` against such a file legitimately returns empty per both
# checks above — the original fail-open bug, one column deep instead of one
# row or one file. Reproduced live against exactly this fixture before the
# per-tier check existed.
test_matrix_load_refuses_a_tier_column_with_no_mandate() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  awk -F'|' 'BEGIN{OFS="|"} /^\| \*\*G[0-9]/ { $9=" — " } { print }' "$router" > "$router.tmp" && mv "$router.tmp" "$router"
  grep -c '| — |$' "$router" | { read -r n; [ "$n" -eq 8 ] || _fail "fixture setup did not wipe all 8 rows' T4 cell — router text may have drifted"; }

  local out
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"no gate is mandatory (M) anywhere at T4"*) _ok;;
    *) _fail "a router with every T4 cell wiped to a valid-but-wrong value was not caught: $out";;
  esac
}

# The per-tier aggregate check above (no tier's column may be all-"—") closes
# a whole-column wipe, but it counts M's per tier, never per gate — so it
# cannot see a MANDATE MOVING to the wrong gate as long as the tier's total
# count of M's stays put. Two individually-valid cells in the SAME row
# swapped (G7's T1 cell, normally "—", trades places with its own T4 cell,
# normally "**M (hard)**") leaves T4's total M-count unchanged — some other
# gate still has an M there — but G7's own T4 mandate is now silently gone,
# replaced by a bogus T1 one. Every prior check (shape, row presence,
# vocabulary, per-tier aggregate) passes this fixture clean; only the
# known-good reference comparison (`_matrix_verify_lock`, task_f2ac7ba7)
# catches it. Live-reproduced against the real repo's own G7 row before this
# test was written.
test_matrix_load_refuses_a_cell_swap_within_a_row() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  sedi 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security engineer | 20 min | — | **M (hard)** | R⁴ | M | — |/' "$router"
  grep -qF '| — | **M (hard)** | R⁴ | M | — |' "$router" || _fail "fixture setup did not swap G7's T1/T4 cells — router text may have drifted"

  local out
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"does not match its known-good reference"*) _ok;;
    *) _fail "a within-row cell swap (per-tier M-count unchanged) was not caught: $out";;
  esac
  case "$out" in *G7*) _fail "swap must be caught by content, not by G7 still appearing mandated: $out";; esac
}

# The simpler, more dangerous sibling the G7 review of the aggregate check
# found: no swap needed at all. A single targeted edit to one gate's own
# cell — G7's T4 cell downgraded from "**M (hard)**" to "R", nothing else
# touched — is invisible to the per-tier aggregate check as long as the
# column has other M's left over, which every real T2/T3/T4 column does.
# `matrix_required T4` against this would silently drop G7 entirely, never
# even naming it as mandated, so a stale logged G7 pass would satisfy
# compliance with zero re-verification. Live-reproduced against the real
# repo's own G7 row before this test was written.
test_matrix_load_refuses_a_single_cell_downgrade() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  sedi 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security engineer | 20 min | — | — | R⁴ | M | R |/' "$router"
  grep -qF '| R⁴ | M | R |' "$router" || _fail "fixture setup did not downgrade G7's T4 cell — router text may have drifted"

  local out
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"does not match its known-good reference"*) _ok;;
    *) _fail "a single-cell M->R downgrade (column still has other M's) was not caught: $out";;
  esac
}

# Bootstrapping / tampering: no reference at all fails exactly like a missing
# router does — there is no default answer to "is this table trustworthy"
# either place.
test_matrix_load_refuses_when_lock_file_missing() {
  newrepo
  rm "$REPO/.pipeline/tools/lib/matrix.lock"

  local out
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 ) 2>&1 )"
  case "$out" in
    *"no known-good reference at"*) _ok;;
    *) _fail "a missing matrix.lock was not caught: $out";;
  esac
}

# The regeneration path itself: `--freeze` is the only sanctioned way to
# update the reference, and it must actually make a legitimately-changed
# table load clean again (not just fail loudly forever). Change the table for
# real (T4 downgraded to R, same edit as the test above) and freeze it —
# `matrix_required T4` must now legitimately reflect the new table (G7
# absent), not refuse.
test_matrix_freeze_regenerates_a_working_reference() {
  newrepo
  local router="$REPO/.pipeline/core/01-router.md"
  sedi 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security engineer | 20 min | — | — | R⁴ | M | R |/' "$router"

  ( cd "$REPO" && bash .pipeline/tools/lib/matrix.sh --freeze ) >/dev/null 2>&1

  local out
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/matrix.sh; matrix_required T4 | tr '\n' ' ' ) 2>&1 )"
  case "$out" in
    *"does not match"*) _fail "--freeze did not produce a reference the freshly-changed table satisfies: $out";;
  esac
  case "$out" in *G7*) _fail "G7 should no longer be T4-mandated after its own cell was downgraded: $out";; esac
  case "$out" in *G1*) _ok;; *) _fail "expected the rest of T4's mandated gates to still be present: $out";; esac
}

# A missing router is not cached as a failure the way a found one is cached as a
# success (`_matrix_load`'s early `[ -n "$_MATRIX_TABLE" ] && return 0`), so a
# caller that asks the matrix several questions in one process retried the load
# and reprinted the three-line warning once per question. This is the library
# primitive in isolation: 4 `matrix_*` calls made as plain statements in ONE
# already-running shell (no forking between them) print the warning once.
#
# This does NOT prove `ledger.sh gates`/`report` only warn once, and an earlier
# round of this change shipped believing it did — every real caller
# (`ledger.sh`, `reconcile.sh`, `dashboard.sh`, `lib/coverage.sh`) reaches
# `matrix_*` through a `$(...)` command substitution, and `$(...)` FORKS a
# subshell: a subshell can READ `_MATRIX_LOAD_FAILED`, but a write it makes to
# that variable dies with the subshell on exit and never reaches the parent
# process's own copy — so the next `$(matrix_*)` call forks fresh, unaware
# anything already failed, and reprints. G8 Dogfood and G7 Threat (round 1)
# both caught this live against the real CLI (`ledger.sh gates` still printed 4
# times) despite this exact test passing throughout. See
# `test_ledger_gates_warns_about_a_missing_router_only_once` below for the test
# that actually exercises the real call path and would have failed round 1's
# fix.
test_matrix_missing_router_warns_once_per_process() {
  newrepo
  local out n
  out="$( (
            MATRIX_ROUTER="$REPO/.pipeline/core/no-such-router.md"
            export MATRIX_ROUTER
            . "$KIT/tools/lib/matrix.sh"
            matrix_gates
            matrix_gates
            matrix_name G1
            matrix_required T4
          ) 2>&1 )"
  n=$(printf '%s\n' "$out" | grep -c "no router at")
  assert_eq "1" "$n" "warning lines across 4 matrix_* calls made bare in one already-running shell"
}

# The test that actually proves the chip's claim: `ledger.sh gates`/`report`,
# invoked the way a user invokes them (a real subprocess, via `led()` below —
# NOT function calls spliced into an already-open shell), warn at most once
# when the router is missing. `cmd_gates()` primes the cache with a bare
# `_matrix_load` call before any of its own `$(matrix_*)` subshells fork
# (tools/ledger.sh) — that priming call, not the library-level cache alone, is
# what makes this hold.
test_ledger_gates_warns_about_a_missing_router_only_once() {
  newrepo
  led add --confidence fresh --change c --gate G1 --tier T3 --outcome pass >/dev/null 2>&1
  led add --confidence fresh --change c --gate G4 --tier T3 --outcome pass >/dev/null 2>&1
  mv "$REPO/.pipeline/core/01-router.md" "$REPO/.pipeline/core/01-router.md.bak"

  run led gates
  local n; n=$(printf '%s\n' "$LAST_OUT" | grep -c "no router at")
  assert_eq "1" "$n" "warning lines in 'ledger.sh gates' output with the router missing"

  run led report
  n=$(printf '%s\n' "$LAST_OUT" | grep -c "no router at")
  assert_eq "1" "$n" "warning lines in 'ledger.sh report' output with the router missing"
}

# reconcile.sh reaches matrix_required/matrix_conditional only through
# `$(...)` for-loops — the same shape that made ledger.sh's cmd_gates/
# cmd_report warn multiple times before they grew their own priming call (see
# the test above). reconcile.sh's own round-1 fix for the fail-open bug
# (matrix-router-unreadable-fails-open) already added a bare `_matrix_load`
# check right before the `GATES=` loop, which primes the cache before any
# `$(matrix_*)` subshell forks — SESSION-HANDOFF.md carried this as an
# untouched, unverified chip (task_58f5e560) across several sessions on the
# assumption it might not have. This is a live confirmation it already does;
# no code change, just the regression test that was missing.
test_reconcile_warns_about_a_missing_router_only_once() {
  newrepo
  mv "$REPO/.pipeline/core/01-router.md" "$REPO/.pipeline/core/01-router.md.bak"
  printf 'token=1\n' >> "$REPO/src/auth/existing.js"

  run rec T4
  local n; n=$(printf '%s\n' "$LAST_OUT" | grep -c "no router at")
  assert_eq "1" "$n" "warning lines in 'reconcile.sh T4' output with the router missing"
}

# matrix_required/matrix_conditional (tools/lib/matrix.sh) return EMPTY output
# both when a tier genuinely mandates no gates and when `_matrix_load` could
# not read the router at all — the two failures are indistinguishable from the
# output alone, only from `_matrix_load`'s own return code (2 on failure),
# which callers used to ignore entirely. `cmd_compliance` read that empty
# output as "Tier $tier mandates no gates. Nothing to check." and exited 0 —
# the one check this kit's own header calls "not self-graded... the one that
# decides release" going green because the thing that was supposed to say
# what to check could not be read. A legitimately gate-free tier (T0) must
# still report "nothing to check" — see the pass case below.
test_ledger_compliance_refuses_when_router_missing() {
  newrepo
  led add --confidence fresh --change c --gate G1 --tier T4 --outcome pass \
    --note "why this change exists" >/dev/null 2>&1
  mv "$REPO/.pipeline/core/01-router.md" "$REPO/.pipeline/core/01-router.md.bak"
  run led compliance --change c --tier T4
  assert_exit 2 "router unreadable must refuse, not report a clean tier"
  assert_contains "REFUSED"
  assert_not_contains "mandates no gates"
}

test_ledger_compliance_reports_nothing_to_check_when_tier_legitimately_empty() {
  newrepo
  led add --confidence fresh --change c --gate G1 --tier T4 --outcome pass \
    --note "why this change exists" >/dev/null 2>&1
  run led compliance --change c --tier T0
  assert_exit 0 "T0 legitimately mandates nothing, router intact"
  assert_contains "mandates no gates"
}

# reconcile.sh has the identical shape: `for _g in $(matrix_required ...)` and
# `for _g in $(matrix_conditional ...)` (tools/reconcile.sh) discard the exit
# status of a command substitution entirely, so a missing router read back as
# `Gates : none mandatory` followed by `Reconciled — routing matches.` —
# exit 0, no warning that the routing verdict was never actually computed.
test_reconcile_refuses_when_router_missing() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/session.js"
  mv "$REPO/.pipeline/core/01-router.md" "$REPO/.pipeline/core/01-router.md.bak"
  run rec T4
  assert_exit 2 "router unreadable must refuse, not report a routing verdict"
  assert_contains "REFUSED"
  assert_not_contains "none mandatory"
  assert_not_contains "Reconciled — routing matches"
}

# Bug 6: a card is "the unit you hand a subagent" (core/02-gates.md:28), but the
# `--finding "severity::location::claim"` vocabulary only lived in 04-ledger.md.
# A subagent given only its card had no way to learn the four allowed severities
# and would guess a plausible word instead — silently coerced with a warning.
# The pointer belongs in 02-gates.md's shared "Running a gate" protocol, since
# every card refers back to that section for the `ledger.sh add` invocation.
test_gates_doc_points_to_the_severity_vocabulary() {
  assert_file_contains "$KIT/core/02-gates.md" "blocking | minor | info | out-of-scope"
}

# ---- Authored extension gates (core/06-extending.md: "G9", not just G1..G8) ----
#
# looks_like_gate() deliberately accepts any G<digits> — the shape check answers
# "can this value break out of its JSON position", not "is this one of the
# built-in eight". `report`/`gates` used to loop only over matrix_gates(), the
# rows actually present in core/01-router.md's table, so an authored gate's runs
# (logged before its router row landed, or against a router row that had drifted
# — the exact class of drift this file's own header warns two copies produce)
# counted toward report's top-level totals but vanished from the per-gate
# breakdown with no explanation for the mismatch.
test_ledger_gates_includes_an_authored_extension_gate() {
  newrepo
  led add --confidence fresh --change c --gate G9 --tier T3 --outcome pass >/dev/null 2>&1
  run led gates
  assert_row "G9" "G9"
}

test_ledger_gates_flags_gate_ids_not_in_the_router_table() {
  newrepo
  led add --confidence fresh --change c --gate G9 --tier T3 --outcome pass >/dev/null 2>&1
  run led gates
  assert_contains "Not in"
  assert_contains "G9"
}

# Fresh-context G7 found this live, against the fix above
# (security-reports/2026-08-14-cli-input-validation-hardening.md): unioning in
# gate ids read back from the ledger means `$g` is no longer guaranteed to be a
# real gate id — it was spliced unvalidated into an unanchored BRE grep. A
# crafted/legacy value like "G.*" cross-matched other gates' lines and inflated
# its OWN row's count; a value like "G[" (invalid BRE) made every grep against
# it fail, silently dropping that row from the table with no warning — exit 0,
# nothing to indicate anything was ever wrong. Neither is reachable through
# `ledger.sh add` itself (looks_like_gate blocks it at write time) but both are
# real for anything else that can append a line — an older ledger.sh, a
# hand-merged team ledger, a manual edit.
test_ledger_gates_excludes_a_regex_shaped_gate_value_as_malformed() {
  newrepo
  led add --confidence fresh --change c --gate G1 --tier T3 --outcome pass >/dev/null 2>&1
  printf '{"type":"gate","change":"c","gate":"G.*","tier":"T3","round":1,"commit":"x","kit":"x","findings":0,"outcome":"pass","confidence":"fresh","challenged_premise":false,"minutes":0,"tokens":0,"lane":"normal","model":"x","note":""}\n' >> "$(ledger_path)"
  run led gates
  assert_contains "Malformed"
  assert_contains "G.*"
  # G1's own count must not have been inflated by the crafted row sitting
  # alongside it in the ledger.
  assert_re "G1[[:space:]]+[A-Za-z]+[[:space:]]+1[[:space:]]"
}

test_ledger_gates_flags_an_invalid_gate_value_instead_of_silently_dropping_it() {
  newrepo
  printf '{"type":"gate","change":"c","gate":"G[","tier":"T3","round":1,"commit":"x","kit":"x","findings":0,"outcome":"pass","confidence":"fresh","challenged_premise":false,"minutes":0,"tokens":0,"lane":"normal","model":"x","note":""}\n' > "$(ledger_path)"
  run led gates
  assert_exit 0 "a malformed gate id must not crash the report, only be excluded from it"
  assert_contains "Malformed"
  assert_contains "G["
}

# The regression this whole class of bug produces: a top-level total that the
# per-gate breakdown directly below it cannot account for.
test_ledger_report_totals_and_gate_breakdown_agree_for_an_authored_gate() {
  newrepo
  led add --confidence fresh --change c --gate G9 --tier T3 --outcome pass --tokens 100 >/dev/null 2>&1
  run led report
  assert_contains "gate runs          1"
  assert_row "G9" "G9"
}

# ---- Footnoted mandates: resolvable, but only on the record ----

test_compliance_flags_a_footnoted_mandate_as_unresolved() {
  newrepo
  for g in G1 G4 G5 G6 G7; do
    led add --confidence fresh --change c --gate "$g" --tier T3 --outcome pass >/dev/null 2>&1
  done
  run led compliance --change c --tier T3
  assert_exit 1 "G8 is M-with-a-footnote at T3 and nothing resolved it"
  assert_row "UNRESOLVED" "G8"
  assert_contains "Invisible"          # the question, not just the verdict
}

test_compliance_accepts_n_a_for_a_footnoted_mandate() {
  newrepo
  for g in G1 G4 G5 G6 G7; do
    led add --confidence fresh --change c --gate "$g" --tier T3 --outcome pass \
      --note "$([ "$g" = G1 ] && echo 'why this change exists' || echo ok)" >/dev/null 2>&1
  done
  led add --change c --gate G8 --tier T3 --outcome n/a \
      --note "internal refactor, Axis C invisible" >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 0
  assert_row "N/A" "G8"
  assert_contains "internal refactor, Axis C invisible"
}

# The escape hatch is only as good as its boundary. G7 at T4 is `M (hard)` with
# no footnote, so nothing in the matrix permits declaring it inapplicable.
test_compliance_refuses_n_a_for_an_unconditional_mandate() {
  newrepo
  for g in G1 G4 G5 G6 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --outcome pass >/dev/null 2>&1
  done
  led add --change c --gate G7 --tier T4 --outcome n/a --note "seems fine" >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1
  assert_row "REFUSED" "G7"
}

# n/a is only honoured where the matrix marks a cell conditional — but even
# then, this file's own header says n/a "needs a reason": a bare n/a is an
# assertion, not the judgment call the escape hatch exists for. cmd_add only
# WARNS when --note is missing (easy to miss, and the entry is still written);
# compliance used to accept that bare n/a anyway, printing "no reason
# recorded" as if that satisfied the mandate instead of refusing it.
test_compliance_refuses_n_a_with_no_reason_even_when_conditional() {
  newrepo
  # --note ok on G1 records a reason (see the recorded-reason tests below) so
  # this test isolates the n/a-reason behaviour it's actually about, rather
  # than tripping the separate no-recorded-reason refusal instead.
  for g in G1 G4 G5 G6 G7; do
    led add --confidence fresh --change c --gate "$g" --tier T3 --outcome pass --note ok >/dev/null 2>&1
  done
  led add --change c --gate G8 --tier T3 --outcome n/a >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 1 "a bare n/a with no reason must not satisfy a footnoted mandate"
  assert_row "REFUSED" "G8"
  assert_contains "INCOMPLETE"
}

# Bug 3: G7 is R⁴ at T2 (recommended-with-footnote, not mandated) — the
# "Recommended here... your call" block used to print a generic CHECK line for
# it unconditionally, even when a reasoned entry already existed on the
# record. A gate you thought about and logged must not look identical to one
# you never touched.
test_compliance_shows_logged_reasoning_instead_of_generic_check() {
  newrepo
  led add --change c --gate G7 --tier T2 --outcome n/a \
      --note "no user input, no persistence, no network call" >/dev/null 2>&1
  run led compliance --change c --tier T2
  assert_contains "LOGGED"
  assert_contains "no user input, no persistence, no network call"
  assert_not_contains "CHECK  G7"
}

# A gate in that same block with nothing logged still gets the original
# generic prompt — the fix must not suppress it for gates nobody touched.
#
# Two distinct guards stand between "nothing logged for G7" and this test:
# a MISSING ledger file is a hard error (mirrors the install docs' own step 5,
# `touch ledger.jsonl` — a mistyped --ledger path must fail loudly, not report
# as if nothing happened), and separately an EMPTY ledger file — `[ -s ... ]`
# in ledger.sh — is ALSO refused, on "a gate with no entries did not run".
# Neither guard cares which change an entry is FOR, only whether the file has
# any bytes — so a real ledger with an entry for an unrelated change makes the
# file non-empty while change "c" (and G7 on it) still has genuinely zero
# entries, which is the actual state this test means to exercise.
test_compliance_still_checks_untouched_recommended_gates() {
  newrepo
  led add --confidence fresh --change unrelated-change --gate G5 --tier T2 --outcome pass >/dev/null 2>&1
  run led compliance --change c --tier T2
  assert_contains "CHECK  G7"
}

# Found by a fresh-context G8 Dogfood run: a hand-typed --outcome typo
# ("passs") only warned and still wrote the line, unlike --tier and
# --resolution's identical closed-set checks elsewhere in this file, which
# REFUSE. compliance reads a non-vocabulary outcome as no verdict at all, so
# the record existed, looked fine in the file, and counted as nothing.
test_ledger_refuses_an_unknown_outcome() {
  newrepo
  run led add --change c --gate G5 --tier T2 --outcome passed
  assert_exit 2 "an outcome outside pass|fail|skipped|n/a must be refused, never silently written"
  assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" '"gate":"G5"'
}

test_ledger_warns_on_n_a_without_a_reason() {
  newrepo
  run led add --change c --gate G8 --tier T3 --outcome n/a
  assert_contains "no --note"
}

# `--confidence` was the one closed-set field cmd_add did not guard: --outcome,
# --tier, --round/--minutes/--tokens and --challenged all refuse a bad value
# before emit(), but --confidence was spliced in as free text. core/04-ledger.md
# and every gate card's `logs_with:` line give the vocabulary as exactly
# `fresh|low`. A typo fails CLOSED: tools/dashboard/app.js's isIndependent() is
# an allow-list (`=== "fresh"`), so an out-of-vocab value makes isSelfCheck()
# true and `ledger.sh report` counts it in neither the fresh nor the low
# bucket — a gate that genuinely ran fresh, logged `--confidence tru`, silently
# drops out of the fresh-run and challenge-rate stats. It happened: the
# ci-to-codebuild G7 round-2 line was `--confidence true` (commit b471896),
# superseded by a corrected append. Same refusal --outcome already gets, same
# reason: append-only means a bad value here is never backfilled.
test_ledger_refuses_an_unknown_confidence() {
  newrepo
  for bad in true tru freshh high same-session self medium ""; do
    run led add --change c --gate G7 --tier T4 --outcome pass --confidence "$bad"
    assert_exit 2 "a confidence outside fresh|low ('$bad') must be refused, never silently written"
    assert_contains "REFUSED"
  done
  assert_not_file_contains "$(ledger_path)" '"gate":"G7"'
}

# The guard must reject ONLY what is outside the vocabulary — `fresh` and `low`
# must still write, or one silent wrong answer has been traded for a refusal
# nobody can satisfy (LEARNINGS.md).
test_ledger_still_accepts_fresh_and_low_confidence() {
  newrepo
  run led add --change c --gate G6 --tier T3 --outcome pass --confidence fresh
  assert_exit 0 "fresh must still be accepted"
  run led add --change c --gate G7 --tier T3 --outcome pass --confidence low
  assert_exit 0 "low must still be accepted"
  assert_eq "low" "$(jsonl_last_field "$(ledger_path)" confidence)" "confidence"
}

# --confidence is REQUIRED for a verdict (pass/fail): a verdict with no
# confidence is an independence claim nobody made, and the dashboard /
# ledger.sh report both key on the literal string, so it would silently not
# count. Not defaulted -- G8 Dogfood found the default handed out the
# privileged `fresh` silently, twice (rounds 1 and 2). skipped/n-a are exempt
# (they reviewed nothing; stamped `low` below).
test_ledger_requires_confidence_on_a_verdict() {
  newrepo
  for v in pass fail; do
    run led add --change c --gate G6 --tier T3 --outcome "$v"
    assert_exit 2 "--outcome $v with no --confidence must be refused"
    assert_contains "needs --confidence fresh|low"
  done
  assert_not_file_contains "$(ledger_path)" '"gate":"G6"'
  # A bare `led add` (no --outcome) defaults to pass, so it is a verdict too.
  run led add --change c --gate G6 --tier T3
  assert_exit 2 "a bare add (default outcome pass) still needs --confidence"
  # skipped / n-a do NOT require it -- they get `low` stamped.
  run led add --change c --gate G5 --tier T3 --outcome skipped
  assert_exit 0 "skipped does not require --confidence"
  assert_eq "low" "$(jsonl_last_field "$(ledger_path)" confidence)" "skipped -> low"
  run led add --change c --gate G5 --tier T3 --outcome n/a --note "card does not fire here"
  assert_exit 0 "n/a does not require --confidence"
  assert_eq "low" "$(jsonl_last_field "$(ledger_path)" confidence)" "n/a -> low"
}

# ---- What the tool DOES, not what the docs say about it -------------------
#
# The severity vocabulary already had a test. It asserted that 02-gates.md
# CONTAINED the string "blocking | minor | info | out-of-scope" — and passed the
# whole time the doc's claim about the behaviour ("silently coerced, with a
# warning") was false: ledger.sh warned and then wrote the invalid value
# through verbatim, so `"severity":"medium"` reached a real ledger. A test that
# greps a document proves the document was written. Every test below drives the
# tool and reads the record it produced.

# A severity outside the four is refused, and NOTHING is written. The old
# behaviour wrote it through, which puts a value into the record that no report
# can group by and no later reader can interpret.
test_ledger_refuses_an_invalid_severity_and_writes_nothing() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome fail --finding "medium::a.js:1::x"
  assert_exit 2
  assert_contains "REFUSED"
  # The record is the assertion, not the message.
  assert_not_file_contains "$(ledger_path)" "medium"
}

# A dogfight review found this live: a crafted --lane value used to splice
# unescaped into the JSON template, forging a duplicate "outcome" key that
# `compliance` read as a PASS for a gate that actually failed with a blocking
# finding. The fix is json_escape() on every string-context field that reaches
# emit(). This is the fail-before/pass-after proof — the exact payload from
# security-reports/2026-08-13-587e8e1.md, checked against what compliance
# actually reports, not just that the line still parses as JSON.
test_ledger_lane_value_cannot_forge_the_outcome() {
  newrepo
  led add --change forge-test --gate G7 --tier T4 --outcome fail --confidence fresh \
    --lane 'normal","outcome":"pass","confidence":"fresh' \
    --model m --finding "blocking::x.js:1::real vuln found" >/dev/null 2>&1
  assert_jsonl_valid "$(ledger_path)"
  assert_eq "fail" "$(jsonl_last_field "$(ledger_path)" outcome)" "outcome must read back as the real value, not the forged one"
  # A forged duplicate key means the raw line has "outcome" written twice.
  local n; n=$(grep -o '"outcome"' "$(ledger_path)" | wc -l | tr -d ' ')
  assert_eq "1" "$n" "exactly one outcome key in the record"
  run led compliance --change forge-test --tier T4
  assert_contains "FAIL       G7"
}

# The companion bare-position vector: round/minutes/tokens/challenged sit
# UNQUOTED in the JSON template ("round":%s, not "round":"%s"), so escaping
# cannot protect them — only rejecting a non-integer/non-boolean value can.
test_ledger_refuses_non_integer_bare_fields_and_writes_nothing() {
  newrepo
  run led add --confidence fresh --change c --gate G6 --tier T2 --outcome pass --round '1,"outcome":"pass'
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "outcome\":\"pass"

  run led add --confidence fresh --change c --gate G6 --tier T2 --outcome pass --minutes '5,"x":"y'
  assert_exit 2; assert_contains "REFUSED"

  run led add --confidence fresh --change c --gate G6 --tier T2 --outcome pass --tokens '5,"x":"y'
  assert_exit 2; assert_contains "REFUSED"

  run led add --confidence fresh --change c --gate G6 --tier T2 --outcome pass --challenged 'false,"x":"y'
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "x\":\"y"
}

test_ledger_refuses_a_malformed_gate_or_tier_and_writes_nothing() {
  newrepo
  run led add --confidence fresh --change c --gate 'G7","x":"y' --tier T2 --outcome pass
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "x\":\"y"

  run led add --confidence fresh --change c --gate G6 --tier 'T2","x":"y' --outcome pass
  assert_exit 2; assert_contains "REFUSED"
}

# Same class of fix in cmd_route and cmd_escape — predicted/actual/found_by/
# severity are all free-text string-context fields that used to splice raw.
test_ledger_route_escapes_predicted_and_actual() {
  newrepo
  led route --change r --predicted 'T1","actual":"T4","verdict":"match' --actual T4 >/dev/null 2>&1
  assert_jsonl_valid "$(ledger_path)"
  local n; n=$(grep -o '"actual"' "$(ledger_path)" | wc -l | tr -d ' ')
  assert_eq "1" "$n" "exactly one actual key in the record"
}

test_ledger_route_refuses_a_non_integer_round() {
  newrepo
  run led route --change r --predicted T1 --actual T4 --round '1,"x":"y'
  assert_exit 2; assert_contains "REFUSED"
}

# P1-5: reconcile.sh defaults --change to the branch name, so a run on a trunk
# branch with no CHANGE= set writes a route record named "master" — one that
# collects reconciles from many changes and correlates with none. Refuse the
# branch/placeholder names at write time, in BOTH cmd_route and cmd_add.
test_ledger_route_refuses_a_branch_name_as_the_change() {
  newrepo
  for name in master main develop development dev trunk HEAD unknown; do
    run led route --change "$name" --predicted T3 --actual T3
    assert_exit 2
    assert_contains "REFUSED"
    assert_not_file_contains "$(ledger_path)" "\"change\":\"$name\""
  done
}
# The branchy-name FALLBACK list lives in two hand-kept copies —
# change_is_branchy() in ledger.sh and changeIsBranchy() in dashboard/app.js —
# because bash and JS cannot share it. A one-sided edit would let the write-side
# refuse a name the read-side still renders as a change (or vice versa). Pin them
# equal (G5 Proof). The computed default-branch check that runs BEFORE this list
# (R-005) is exercised separately — see test_ledger_refuses_the_computed_*.
test_branchy_change_list_matches_between_ledger_and_dashboard() {
  local sh_list js_list
  sh_list="$(sed -n '/^change_is_branchy()/,/esac/p' "$KIT/tools/ledger.sh" \
    | grep -oE '[A-Za-z][A-Za-z|]*\)' | head -1 | tr -d ')' | tr '|' '\n' | sort)"
  js_list="$(grep -oE 'return \["master"[^]]*\]' "$KIT/tools/dashboard/app.js" \
    | tr -d '[]"' | sed 's/^return //' | tr ',' '\n' | sed 's/ //g' | sort)"
  [ -n "$sh_list" ] || { _fail "could not extract change_is_branchy list from ledger.sh"; return; }
  [ -n "$js_list" ] || { _fail "could not extract changeIsBranchy list from app.js"; return; }
  assert_eq "$sh_list" "$js_list" "ledger.sh change_is_branchy vs app.js changeIsBranchy"

  # The computed default-branch check (R-005) that runs BEFORE the list must be
  # on all three sides — a one-sided removal re-opens R-005.
  grep -q 'DEFAULT_BRANCH' "$KIT/tools/ledger.sh" \
    || _fail "ledger.sh change_is_branchy lost its computed default-branch check"
  grep -q 'PIPELINE.defaultBranch' "$KIT/tools/dashboard/app.js" \
    || _fail "app.js changeIsBranchy lost its computed default-branch check"
  grep -q '"defaultBranch"' "$KIT/tools/dashboard.sh" \
    || _fail "dashboard.sh no longer bakes defaultBranch into the model"
}

# The RESOLUTION itself (origin/HEAD → init.defaultBranch → empty) lives in one
# file, sourced by both the write side (ledger.sh) and the read side
# (dashboard.sh), so the two cannot resolve it differently — the finding G4/G5/G6
# all raised against the first version's two hand-kept copies. Pin that the file
# exists and that neither tool has re-inlined its own copy.
test_default_branch_resolution_is_a_single_sourced_lib() {
  [ -f "$KIT/tools/lib/default-branch.sh" ] \
    || { _fail "tools/lib/default-branch.sh is missing"; return; }
  grep -q 'lib/default-branch\.sh' "$KIT/tools/ledger.sh" \
    || _fail "ledger.sh does not source lib/default-branch.sh"
  grep -q 'lib/default-branch\.sh' "$KIT/tools/dashboard.sh" \
    || _fail "dashboard.sh does not source lib/default-branch.sh"
  # The lib must carry BOTH halves of the resolution, and neither tool may
  # re-inline EITHER half — a partial re-inline (just origin/HEAD, or just
  # init.defaultBranch) is the divergence this test exists to catch (G4 Ripple
  # round 2). `if`, not `&& _fail || _ok`, so a hit records exactly one _fail.
  grep -q 'symbolic-ref .*refs/remotes/origin/HEAD' "$KIT/tools/lib/default-branch.sh" \
    || _fail "lib/default-branch.sh lost the origin/HEAD lookup"
  grep -q 'git config .*init\.defaultBranch' "$KIT/tools/lib/default-branch.sh" \
    || _fail "lib/default-branch.sh lost the init.defaultBranch fallback"
  # Match the COMMAND forms only — `init.defaultBranch` also appears as prose in
  # ledger.sh's refusal message and a dashboard.sh comment, which are fine.
  local f
  for f in ledger.sh dashboard.sh; do
    if grep -q 'symbolic-ref .*refs/remotes/origin/HEAD' "$KIT/tools/$f"; then
      _fail "$f re-inlined the origin/HEAD lookup instead of using the lib"
    else _ok; fi
    if grep -q 'git config .*init\.defaultBranch' "$KIT/tools/$f"; then
      _fail "$f re-inlined the init.defaultBranch fallback instead of using the lib"
    else _ok; fi
  done
}

# route and add are not the only --change writers: escape (the change that
# CAUSED a defect) and assume (the change being worked on) take it too. An
# agent refused at `add` on a trunk branch should not be able to land a
# branch-named record through a sibling command (G4 Ripple, G7 Threat).
test_ledger_all_change_writers_refuse_a_branch_name() {
  newrepo
  run led add --confidence fresh    --change master --gate G4 --tier T3 --outcome pass --model m
  assert_exit 2; assert_contains "REFUSED"
  run led escape --change main --found-by user --severity high
  assert_exit 2; assert_contains "REFUSED"
  run led assume --change trunk --assumed "x" --resolution defaulted
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" '"change":"master"'
  assert_not_file_contains "$(ledger_path)" '"change":"main"'
  assert_not_file_contains "$(ledger_path)" '"change":"trunk"'
}
# A branch-per-change workflow names its branch for the change, and gates land
# under that name — those must still go through. Only the trunk names are refused.
test_ledger_accepts_a_feature_branch_name_as_the_change() {
  newrepo
  run led add --confidence fresh --change "feat/quota-race" --gate G4 --tier T3 --outcome pass --model m
  assert_exit 0
  assert_file_contains "$(ledger_path)" '"change":"feat/quota-race"'
}

# reconcile.sh --log calls ledger.sh route; when that refuses (branch-name
# change), reconcile used to print "(is tools/ledger.sh present?)" and exit 0 —
# a recorded reconciliation that never happened, which R0b forbids. It must now
# surface the real reason and exit non-zero.
test_reconcile_log_surfaces_a_refused_ledger_write_and_fails() {
  newrepo
  printf 'console.log(2)\n' > "$REPO/src/app.js"
  git -C "$REPO" commit -qam "a change" >/dev/null 2>&1
  LAST_OUT="$( cd "$REPO" && BASE="$BASE_SHA" CHANGE=master LEDGER="$(ledger_path)" \
    bash .pipeline/tools/reconcile.sh T1 --log 2>&1 )"; LAST_EXIT=$?
  assert_exit 2
  assert_contains "REFUSED"
  assert_contains "NOT RECORDED"
  assert_not_file_contains "$(ledger_path)" '"change":"master"'
}

# R-005: change_is_branchy() used to be a hand-enumerated list ONLY, so a repo
# whose real trunk is `prod` (or a team convention) could still write a route
# record named for that branch — one that correlates with no gates (P1-5), on a
# name the list does not carry. It now resolves the repo's ACTUAL default branch
# from git first (origin/HEAD's target, then init.defaultBranch), and refuses
# THAT, keeping the hand-list as the fallback for when git resolves nothing.
#
# (a) — origin/HEAD path. `prod` is refused here because it is the resolved
# default branch; the SAME name is accepted in a plain newrepo below, which is
# the discrimination proof: the hand-list alone never caught `prod`, so the
# computed check is the only thing refusing it here.
test_ledger_refuses_the_computed_default_branch_via_origin_head() {
  newrepo
  git -C "$REPO" update-ref refs/remotes/origin/prod HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/prod
  # All four --change writers funnel through change_is_branchy() — route/add and
  # the two easier-to-forget siblings, escape and assume (G5 Proof round 1).
  run led route  --change prod --predicted T3 --actual T3
  assert_exit 2; assert_contains "REFUSED"
  # The message must say WHY — that git resolved it, not just "a branch name"
  # (G8 Dogfood round 1).
  assert_contains "this repository's default branch"
  run led add --confidence fresh    --change prod --gate G4 --tier T3 --outcome pass --model m
  assert_exit 2; assert_contains "REFUSED"
  run led escape --change prod --found-by user --severity high
  assert_exit 2; assert_contains "REFUSED"
  run led assume --change prod --assumed x --resolution defaulted
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" '"change":"prod"'
}

# Resolution ORDER: origin/HEAD is the repo's own answer and wins over the
# init.defaultBranch fallback. Set them to DIFFERENT names — the origin/HEAD one
# is refused, the init.defaultBranch one is a usable change name. If the order
# were reversed this test's two assertions swap. (G5 Proof round 1.)
test_ledger_default_branch_resolution_prefers_origin_head() {
  newrepo
  git -C "$REPO" update-ref refs/remotes/origin/trunk-a HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk-a
  git -C "$REPO" config init.defaultBranch trunk-b
  run led route --change trunk-a --predicted T3 --actual T3
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" '"change":"trunk-a"'
  run led route --change trunk-b --predicted T3 --actual T3
  assert_exit 0
  assert_file_contains "$(ledger_path)" '"change":"trunk-b"'
}

# (a) — init.defaultBranch path. No remote at all; the fallback resolution still
# resolves `prod` and refuses it.
test_ledger_refuses_the_computed_default_branch_via_init_defaultbranch() {
  newrepo
  git -C "$REPO" config init.defaultBranch prod
  run led route --change prod --predicted T3 --actual T3
  assert_exit 2
  assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" '"change":"prod"'
}

# The discrimination half of (a): in a repo where `prod` is NOT the resolved
# default branch, it is a perfectly good change name and must be written. If
# this ever fails, the computed check has started refusing real change names —
# the other edge of R-005 the risk entry warns about.
test_ledger_accepts_a_non_default_branch_name_as_the_change() {
  newrepo
  git -C "$REPO" config init.defaultBranch main   # pin it, so a stray global cannot make `prod` the default
  run led route --change prod --predicted T3 --actual T3
  assert_exit 0
  assert_file_contains "$(ledger_path)" '"change":"prod"'
}

# (b) — the hand-enumerated fallback is intact when git resolves NO default
# branch: no remote, and init.defaultBranch pinned empty so a global value
# cannot leak in. master/trunk/unknown must still be refused with nothing but
# the list to go on.
test_ledger_hand_enumerated_fallback_still_refuses_when_git_resolves_nothing() {
  newrepo
  git -C "$REPO" config init.defaultBranch ""
  for name in master main develop development dev trunk HEAD unknown; do
    run led route --change "$name" --predicted T3 --actual T3
    assert_exit 2
    assert_contains "REFUSED"
    assert_not_file_contains "$(ledger_path)" "\"change\":\"$name\""
  done
}

test_ledger_escape_escapes_found_by_and_severity() {
  newrepo
  # --found-by is a closed set now (E8): an injection attempt is refused outright, nothing written.
  run led escape --change c --found-by 'user","severity":"critical'
  assert_exit 2
  assert_contains "REFUSED"
  # --severity is free text, so it still has to be escaped rather than refused.
  run led escape --change c --found-by user --severity 'high","note":"forged'
  assert_exit 0
  assert_jsonl_valid "$(ledger_path)"
  local n; n=$(grep -o '"severity"' "$(ledger_path)" | wc -l | tr -d ' ')
  assert_eq "1" "$n" "exactly one severity key in the record"
}

# core/02-gates.md: a finding without a citation is DELETED, not softened. The
# doc mandated rejection; only the tool was lenient.
test_ledger_refuses_a_blocking_finding_with_no_location() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome fail --finding "blocking::::no citation"
  assert_exit 2
  assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "no citation"
}

# ...but `info` is a disclosed observation, not a claim that blocks anything, so
# it does not need one. Rejecting it too would be the strictness LEARNINGS.md
# warns about: a check nobody can satisfy gets bypassed.
test_ledger_allows_an_info_finding_with_no_location() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --finding "info::::just noting"
  assert_exit 0
  assert_file_contains "$(ledger_path)" "just noting"
}

# core/02-gates.md routes an out-of-scope finding to a separate follow-up item.
# Nothing implemented the routing, so they accumulated in the ledger and nowhere
# else — five of them on one real Dogfood run.
test_ledger_refuses_an_unfiled_out_of_scope_finding() {
  newrepo
  run led add --confidence fresh --change c --gate G8 --tier T4 --outcome fail \
    --finding "out-of-scope::a.js:1::pre-existing, unrelated"
  assert_exit 2
  assert_contains "filed:"
  assert_not_file_contains "$(ledger_path)" "pre-existing"
}

test_ledger_accepts_an_out_of_scope_finding_that_names_where_it_went() {
  newrepo
  run led add --confidence fresh --change c --gate G8 --tier T4 --outcome fail \
    --finding "out-of-scope::a.js:1::toast overlap, page-wide; filed:ISSUE-412"
  assert_exit 0
  # Extracted into its own field, so "did we file these?" is answerable by a
  # query rather than by reading prose.
  assert_file_contains "$(ledger_path)" '"filed":"ISSUE-412"'
}

# One refused finding aborts the whole entry. A partially-recorded run is a run
# the ledger describes WRONGLY, which is worse than one it does not describe.
test_ledger_refuses_the_whole_entry_when_one_finding_is_bad() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome fail \
    --finding "blocking::a.js:1::good one" --finding "sev-typo::a.js:2::bad one"
  assert_exit 2
  assert_not_file_contains "$(ledger_path)" "good one"
}

# emit() is the last gate before the record: it refuses anything that is not a
# single JSON object on one line. Reached by loading the functions without the
# dispatch block at the bottom, because no CLI path can produce a malformed line
# any more — which is the point. This is the backstop, tested as a backstop.
#
# The functions are staged in a real file, not sourced from `. <(sed …)`:
# process-substitution sourcing is unreliable on the bash 3.2 that ships on
# macOS — the prefix silently fails to load, emit() is never defined, and the
# call exits 127 instead of 3 (green on Linux/Windows, red on macOS CI only).
#
# Round 26: ledger.sh now stops (exit 2) when lib/commit.sh is not beside it, so the staged copy gets a
# lib/ of its own. Prints the path of the (empty) file to write the functions to.
_stage_fns_file() {
  local d; d="$(mktemp -d "$TMPROOT/ledger-fns.XXXXXX")"
  cp -r "$KIT/tools/lib" "$d/lib"
  printf '%s/ledger-fns.sh\n' "$d"
}

test_emit_refuses_a_line_that_is_not_a_json_object() {
  newrepo
  local fns; fns="$(_stage_fns_file)"
  sed '/^case "${1:-}"/,$d' "$REPO/.pipeline/tools/ledger.sh" > "$fns"
  run bash -c "LEDGER='$(ledger_path)'; . '$fns'; emit 'not json at all'"
  rm -f "$fns"
  assert_exit 3
  assert_not_file_contains "$(ledger_path)" "not json at all"
}

# G7 Threat (ledger-success-shows-destination review): before this, emit()
# never checked whether its own append succeeded. A blocked write (path is a
# directory, or its parent cannot be created) still fell through to the
# caller's unconditional "logged: ... pass" — now naming a destination the
# write never reached. These pin that a blocked append is REFUSED, not
# silently reported as a success.
test_emit_refuses_when_the_ledger_path_is_a_directory() {
  newrepo
  local fns dirpath; fns="$(_stage_fns_file)"
  sed '/^case "${1:-}"/,$d' "$REPO/.pipeline/tools/ledger.sh" > "$fns"
  dirpath="$(mktemp -d "$TMPROOT/ledger-is-a-dir.XXXXXX")"
  run bash -c "LEDGER='$dirpath'; . '$fns'; emit '{\"type\":\"gate\"}'"
  rm -f "$fns"
  assert_exit 3 "a directory in place of the ledger file must be refused, not silently treated as written"
  assert_contains "REFUSED"
}

test_emit_refuses_when_the_ledger_directory_cannot_be_created() {
  newrepo
  local fns blocker; fns="$(_stage_fns_file)"
  sed '/^case "${1:-}"/,$d' "$REPO/.pipeline/tools/ledger.sh" > "$fns"
  blocker="$(mktemp "$TMPROOT/ledger-blocker.XXXXXX")"   # a FILE, so mkdir -p under it must fail
  run bash -c "LEDGER='$blocker/sub/ledger.jsonl'; . '$fns'; emit '{\"type\":\"gate\"}'"
  rm -f "$fns"
  assert_exit 3 "an uncreatable parent directory must be refused, not silently treated as written"
  assert_contains "REFUSED"
}

# G7 Threat round 2 (ledger-success-shows-destination review): an append
# SUCCEEDS against /dev/null (or a symlink to any non-regular file) — exit 0,
# a clean "logged: ... pass" line, and the record silently never exists
# anywhere. Refusing anything that exists and is not a regular file closes
# this without needing to special-case /dev/null itself.
test_emit_refuses_when_the_ledger_is_not_a_regular_file() {
  newrepo
  local fns; fns="$(_stage_fns_file)"
  sed '/^case "${1:-}"/,$d' "$REPO/.pipeline/tools/ledger.sh" > "$fns"
  run bash -c "LEDGER='/dev/null'; . '$fns'; emit '{\"type\":\"gate\"}'"
  rm -f "$fns"
  assert_exit 3 "/dev/null (or any non-regular destination) must be refused, not silently discard the record"
  assert_contains "REFUSED"
}

# G7 Threat round 2: `[ -n "$summary" ] && echo ...` as emit()'s LAST
# statement means emit() itself returns 1 (the test's own exit status) on a
# perfectly successful write whenever no summary is passed — a caller that
# checks emit()'s return code (cmd_route ends with a bare `emit ...`, so its
# own exit code IS emit()'s) would see a false failure. This pins that a
# summary-less call still reports success and the record still lands.
test_emit_with_no_summary_still_reports_success_after_a_real_write() {
  newrepo
  local fns; fns="$(_stage_fns_file)"
  sed '/^case "${1:-}"/,$d' "$REPO/.pipeline/tools/ledger.sh" > "$fns"
  run bash -c "LEDGER='$(ledger_path)'; . '$fns'; emit '{\"type\":\"gate\"}'"
  rm -f "$fns"
  assert_exit 0 "a real write with no summary argument must not be reported as a failure"
  # the record lands, with its chain link appended as the last key
  assert_file_contains "$(ledger_path)" '{"type":"gate","prev":"'
}

# G7 Threat round 3: the non-regular-file guard above now catches the
# is-a-directory case FIRST, so nothing in the suite reached the original
# round-1 append-failure guard (the printf check) any more — proved by G7
# deleting that guard in a scratch copy and watching the whole suite stay
# green while a real permission failure silently "succeeded" again. A
# read-only REGULAR file passes the non-regular-file check (it IS a regular
# file) and only fails at the actual append, exercising that exact branch.
test_emit_refuses_when_the_ledger_file_is_not_writable() {
  newrepo
  local fns ro; fns="$(_stage_fns_file)"
  sed '/^case "${1:-}"/,$d' "$REPO/.pipeline/tools/ledger.sh" > "$fns"
  ro="$(mktemp "$TMPROOT/ledger-readonly.XXXXXX")"
  printf '{"type":"gate"}\n' > "$ro"
  chmod 444 "$ro"
  run bash -c "LEDGER='$ro'; . '$fns'; emit '{\"type\":\"gate\"}'"
  chmod 644 "$ro"; rm -f "$fns"
  assert_exit 3 "a read-only ledger file must be refused, not silently treated as written"
  assert_contains "REFUSED"
}

# The invariant the test above exists to protect: no kit shell file may source a
# process substitution (`. <(…)` / `source <(…)`). It silently fails to load on
# the bash 3.2 that ships on macOS — which is how the emit() backstop above went
# red on macOS CI for two weeks while staying green everywhere else. A grep is
# cheap; rediscovering this from a CI log is not. Commented-out lines are
# excluded — a `# … . <(…)` in a script is dormant, not a live sourcing.
test_no_kit_shell_file_sources_a_process_substitution() {
  local f rc scan hits
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(
    git -C "$KIT" ls-files '*.sh' 'templates/pre-push')
  # A miscounted file list means the scan below proves nothing — fail loud
  # rather than green on an empty match.
  [ "${#files[@]}" -ge 10 ] || { _fail "guard enumerated ${#files[@]} kit shell files (expected ~20) — git ls-files misconfigured?"; return; }
  # Relative paths (cd first) so grep's path:lineno:content lines carry no drive
  # letter, which the comment filter below anchors against.
  scan="$(cd "$KIT" && grep -nHE '(^|;|[[:space:]])(\.|source)[[:space:]]+<\(' "${files[@]}")"; rc=$?
  [ "$rc" -le 1 ] || { _fail "guard grep errored (exit $rc) — a future edit likely broke the pattern or a file is unreadable"; return; }
  # grep prints path:lineno:content — drop only hits whose CONTENT is a # comment.
  hits="$(printf '%s' "$scan" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  if [ -n "$hits" ]; then
    _fail "process-substitution sourcing found — breaks bash 3.2 on macOS:
$(printf '%s' "$hits" | sed 's/^/          /')"
  else
    _ok
  fi
}

# ...and a legitimate note containing the exact shape the corruption had must
# still go through. A check that refuses valid input gets bypassed, and a
# bypassed check measures nothing (LEARNINGS.md).
test_a_note_containing_double_commas_is_still_recorded() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --note "counts were 3,,4 in the raw export"
  assert_exit 0
  assert_file_contains "$(ledger_path)" "3,,4"
}

# Nine findings in, nine findings out. The count is derived from the rows, so it
# cannot disagree with them.
test_ledger_keeps_every_finding_it_was_given() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome fail \
    --finding "blocking::a.js:1::one"   --finding "blocking::a.js:2::two" \
    --finding "minor::a.js:3::three"    --finding "minor::a.js:4::four" \
    --finding "info::a.js:5::five"      --finding "info::a.js:6::six" \
    --finding "info::a.js:7::seven"     --finding "minor::a.js:8::eight" \
    --finding "blocking::a.js:9::nine" >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"findings":9'
  local n; n=$(grep -o '"severity"' "$(ledger_path)" | wc -l | tr -d ' ')
  [ "$n" = "9" ] || _fail "expected 9 finding objects on the line, got $n"
}

# The bare count flag is gone, and says so rather than reporting "unknown option"
# — the reason a flag was removed is the part worth keeping.
test_ledger_refuses_the_removed_findings_flag_with_a_reason() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome fail --findings 3
  assert_exit 2
  assert_contains "--findings was removed"
}

# ---- Provenance: model, tokens, kit ---------------------------------------

# core/08-models.md assigns every gate a tier and says "say which you picked".
# Every line of the first real run said "unset", because nothing asked.
test_ledger_warns_when_no_model_is_recorded() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass
  assert_contains "no --model recorded"
}

test_ledger_is_quiet_when_the_model_is_recorded() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model some-model --tokens 1000
  assert_not_contains "no --model recorded"
  assert_file_contains "$(ledger_path)" '"model":"some-model"'
}

test_ledger_records_tokens() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m --tokens 132376 >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"tokens":132376'
}

# --tokens-in/--tokens-out (core/04-ledger.md's widened `tokens` field) split the
# aggregate by direction. Given without an explicit --tokens, the total is computed
# so every existing reader of the aggregate field keeps working unchanged.
test_ledger_records_tokens_in_and_out_and_computes_the_total() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 800 --tokens-out 200 >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"tokens_in":800'
  assert_file_contains "$(ledger_path)" '"tokens_out":200'
  assert_file_contains "$(ledger_path)" '"tokens":1000'
}

# --tokens-in/--tokens-out are PAIRED. Not because a lone value is meaningless
# (unlike --action/--evidence, on which this rule was originally modeled and
# wrongly justified by analogy — G6 Peer round 1) — a lone --tokens-in is a
# true, usable number. It is refused because the pair is used to COMPUTE the
# total (tools/ledger.sh cmd_add), and a one-sided value would corrupt that
# computation rather than merely describe a direction as zero.
test_ledger_refuses_tokens_in_without_tokens_out() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m --tokens-in 800
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "tokens_in"
}

test_ledger_refuses_tokens_out_without_tokens_in() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m --tokens-out 200
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "tokens_out"
}

# An explicit --tokens SMALLER than tokens-in + tokens-out is a contradiction —
# the parts can't outweigh the whole — not a value the split may silently
# overwrite.
test_ledger_refuses_tokens_that_contradicts_the_split() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens 500 --tokens-in 800 --tokens-out 200
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "tokens_in"
}

# A --tokens that agrees with the split is accepted — the pairing rule refuses
# a total smaller than its parts, not redundancy.
test_ledger_accepts_tokens_that_agrees_with_the_split() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens 1000 --tokens-in 800 --tokens-out 200 >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"tokens":1000'
}

# G4 Ripple round 1 (challenged_premise): a true billed total can legitimately
# EXCEED tokens_in + tokens_out — this kit's own subagent gates re-read core/ on
# every run, incurring cache-read/cache-creation tokens that belong to neither
# "in" nor "out". A --tokens greater than the split must be accepted and kept
# AS GIVEN, not silently replaced by the (smaller) computed sum.
test_ledger_accepts_and_keeps_tokens_greater_than_the_split() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens 1500 --tokens-in 800 --tokens-out 200 >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"tokens":1500'
  assert_file_contains "$(ledger_path)" '"tokens_in":800'
}

# --tokens-in/--tokens-out are checked on the FLAG being passed, not the value
# being non-empty (G8 Dogfood round 1: --tokens-in "" --tokens-out 200 read as
# "tokens-in omitted" and produced the wrong refusal message). An explicitly
# empty value must reach is_uint and be refused as an invalid value.
test_ledger_refuses_an_explicitly_empty_tokens_in() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in '' --tokens-out 200
  assert_exit 2; assert_contains "REFUSED"
  assert_contains "not a non-negative integer"
  assert_not_file_contains "$(ledger_path)" "tokens_out"
}

test_ledger_refuses_an_explicitly_empty_tokens_out() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 200 --tokens-out ''
  assert_exit 2; assert_contains "REFUSED"
  assert_contains "not a non-negative integer"
}

# The original round-1 regression payload: bash arithmetic is signed 64-bit
# and silently wraps a huge sum to a negative number, which reached emit()
# unvalidated (G6 Peer / G7 Threat round 1, independently). Pinned here as a
# historical regression test even though, after round 3's fix, this 19-digit
# --tokens-in is now caught earlier by is_uint_bounded's operand cap rather
# than by computed_total's own (still-present, now-defense-in-depth) check —
# see test_ledger_refuses_an_oversized_single_operand_even_when_the_wrapped_
# sum_is_positive for the round-2 payload that specifically needed the cap
# (G6 Peer round 3).
test_ledger_refuses_tokens_in_out_that_overflow_the_sum() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 9223372036854775807 --tokens-out 1
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "tokens_in"
}

# G6 Peer / G7 Threat round 2, independently: the round-2 fix above only
# rejected a NEGATIVE wrapped sum. A 20-digit operand wraps bash's 64-bit
# arithmetic to an arbitrary POSITIVE value instead, which then passes a
# sign-only check and is silently accepted as a plausible-looking total.
test_ledger_refuses_an_oversized_single_operand_even_when_the_wrapped_sum_is_positive() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 18446744073709551617 --tokens-out 1
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "tokens_in"
}

# The wrap also broke the >= comparison itself: comparing --tokens against an
# already-wrapped (small, positive) computed_total let a --tokens far smaller
# than the REAL split through, writing a record whose stated total was less
# than its own split — the exact thing the >= rule exists to prevent.
test_ledger_refuses_tokens_smaller_than_an_oversized_split_even_via_the_wrap() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens 2 --tokens-in 18446744073709551617 --tokens-out 1
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "tokens_in"
}

# Boundary: a 15-digit operand (the cap) is accepted; 16 digits is refused.
# Real token counts are nowhere near this range — the cap exists purely to
# keep bash's arithmetic on the SUM away from anywhere it could wrap, not as
# a realistic usage limit.
test_ledger_accepts_tokens_at_the_fifteen_digit_cap() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 999999999999999 --tokens-out 0 >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"tokens_in":999999999999999'
}

test_ledger_refuses_tokens_past_the_fifteen_digit_cap() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 1000000000000000 --tokens-out 0
  assert_exit 2; assert_contains "REFUSED"
}

# G7 Threat round 3 (mutation-tested): every prior overflow test pairs a huge
# value with --tokens-in/--tokens-out, so reverting the bound on plain
# --tokens alone (used standalone, no split) back to unbounded is_uint left
# every existing test green while reopening round 2's fail-open comparison
# crash (`--tokens <huge>` breaking the `-lt` check with a raw shell error
# instead of a clean REFUSED). This is the test that actually pins --tokens
# itself, with no split involved at all.
test_ledger_refuses_an_oversized_standalone_tokens_value() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens 99999999999999999999
  assert_exit 2; assert_contains "REFUSED"
  assert_not_contains "integer expected"
  assert_not_file_contains "$(ledger_path)" "99999999999999999999"
}

# --tokens 0 is a genuine, explicit zero-cost claim, not an omission — it must
# NOT trigger the "no --tokens recorded" note (G8 Dogfood round 1: it did).
test_ledger_explicit_zero_tokens_does_not_warn_that_nothing_was_recorded() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m --tokens 0
  assert_not_contains "no --tokens recorded"
  assert_file_contains "$(ledger_path)" '"tokens":0'
}

test_ledger_omitted_tokens_still_warns_that_nothing_was_recorded() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m
  assert_contains "no --tokens recorded"
}

# G4 Ripple round 1: a deliberately-recorded 0/0 split is a genuine claim ("this
# run's cost split cleanly to zero"), not the same as no run ever recording a
# split — cmd_report must still surface it, not silently sum to nothing and
# vanish.
test_ledger_report_counts_a_genuine_zero_zero_split() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 0 --tokens-out 0 >/dev/null 2>&1
  run led report
  assert_contains "tokens in/out"
  assert_contains "1 run(s) recorded the split"
}

# G8 Dogfood round 1 / G6 Peer round 3: the %.1fk formatting fix was only ever
# pinned by the 0/0 case above (which prints "0.0k / 0.0k" regardless of
# precision). This exercises a real non-zero split, at values chosen so the
# total and the split visibly reconcile at one-decimal precision.
test_ledger_report_shows_nonzero_split_at_one_decimal_precision() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 1600 --tokens-out 400 >/dev/null 2>&1
  run led report
  assert_contains "tokens spent       2.0k"
  assert_contains "tokens in/out      1.6k / 0.4k"
  assert_contains "1 run(s) recorded the split"
}

# G8 Dogfood round 1: an unrecognized subcommand silently dumped the whole
# 34-line header to STDOUT with no indication of what was wrong, breaking the
# stderr convention every other refusal in this file follows. A typo now gets a
# short, specific message; a genuinely bare invocation still gets the header
# (that is a real help request, not a typo).
test_ledger_unknown_subcommand_gives_a_short_stderr_refusal() {
  newrepo
  run led ad --change c --gate G4
  assert_exit 2
  assert_contains "REFUSED: unknown subcommand 'ad'"
}

test_ledger_bare_invocation_still_prints_the_header() {
  newrepo
  run led
  assert_exit 2
  assert_contains "Usage:"
}

# tokens_in/tokens_out land in the same BARE, unquoted JSON position as tokens
# itself — same injection vector test_ledger_refuses_non_integer_bare_fields_and_
# writes_nothing already covers for round/minutes/tokens/challenged.
test_ledger_refuses_non_integer_tokens_in_and_out() {
  newrepo
  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in '5,"x":"y' --tokens-out 5
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "x\":\"y"

  run led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m \
    --tokens-in 5 --tokens-out '5,"x":"y'
  assert_exit 2; assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "x\":\"y"
}

# --withhold-breached is OPTIONAL and TRIAL (core/11-evolution.md Step 7) — these
# three pin exactly what "optional" has to mean: omitting it writes nothing and
# warns nothing (an existing caller that has never heard of this flag must see no
# behavior change at all), a valid true|false value is recorded verbatim, and an
# invalid value is warned about and DROPPED rather than written — writing it raw
# would emit a JSON line with a non-boolean literal in a boolean position, which
# is exactly the "silent JSON corruption" class of bug this file's json_escape
# comment (tools/ledger.sh:80-88) already exists to prevent for --note.
test_ledger_withhold_breached_omitted_writes_nothing_and_warns_nothing() {
  newrepo
  run led add --confidence fresh --change c --gate G7 --tier T4 --outcome pass --model m
  assert_not_contains "withhold-breached"
  assert_not_file_contains "$(ledger_path)" "withhold_breached"
}

test_ledger_withhold_breached_records_a_valid_value() {
  newrepo
  led add --confidence fresh --change c --gate G7 --tier T4 --outcome pass --model m --withhold-breached true >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"withhold_breached":true'
}

test_ledger_withhold_breached_invalid_value_is_warned_and_not_written() {
  newrepo
  run led add --confidence fresh --change c --gate G7 --tier T4 --outcome pass --model m --withhold-breached maybe
  assert_contains "expected true|false"
  assert_not_file_contains "$(ledger_path)" "withhold_breached"
}

# Auto-detected the same way `commit` is: a provenance field you have to
# remember is one you will eventually not.
test_ledger_stamps_the_kit_build_without_being_asked() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"kit":"'
}

# REGRESSION: `ledger.sh`'s hardcoded default (`.pipeline/ledger.jsonl`) is the
# INSTALLED-copy convention. Run it self-hosted — the kit IS the repo root, the
# shape this repo itself is in — with no --ledger flag, and it silently wrote to
# a stray `.pipeline/ledger.jsonl` one level under the real root, printing
# "logged: ... pass" and exiting 0 the entire time. reconcile.sh already tells
# these two shapes apart (`KIT_PREFIX`, `SELF: gated-change`); this pins that
# ledger.sh now does too, using --show-prefix rather than a --show-toplevel
# path comparison (an earlier version of the fix compared a `pwd`-built path
# against a git-built one and always resolved to "installed" — the exact
# drive-letter mismatch reconcile.sh's own comment warns about).
test_ledger_default_path_is_self_hosting_aware() {
  selfhostrepo
  led_default add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m >/dev/null 2>&1
  [ -f "$SELFREPO/ledger.jsonl" ] || { _fail "self-hosted default should write to <repo-root>/ledger.jsonl"; return; }
  _ok
  [ -f "$SELFREPO/.pipeline/ledger.jsonl" ] && _fail "also wrote a stray .pipeline/ledger.jsonl — the old default leaking through" || _ok
}

# G7 Threat (ledger-success-shows-destination review): every prior test of the
# success-message-names-$LEDGER behavior used led(), which always passes
# --ledger explicitly — proving only that the tool echoes a path just handed to
# it, never the resolved DEFAULT. This exercises the actual footgun scenario:
# no --ledger, no LEDGER export, self-hosted default resolution, and pins that
# the success line names the path it actually resolved to — not merely some
# path.
test_ledger_default_path_success_message_names_the_resolved_path() {
  selfhostrepo
  run led_default add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m
  assert_exit 0
  assert_contains "$SELFREPO/ledger.jsonl"
}

# The installed shape must not regress while fixing the self-hosting one.
test_ledger_default_path_is_still_dot_pipeline_when_installed() {
  newrepo
  ( cd "$REPO" && bash .pipeline/tools/ledger.sh add --confidence fresh --change c --gate G4 --tier T4 --outcome pass --model m --evidence .pipeline/tools/ledger.sh:1 ) >/dev/null 2>&1
  [ -f "$(ledger_path)" ] || _fail "an installed copy (kit nested under .pipeline/ inside a bigger repo) must still default there"
  _ok
}

# The stale-install incident: the project's copy of ledger.sh had drifted from
# the kit source and silently produced wrong answers, caught only because the
# output disagreed with a human's memory. compliance now says so itself.
test_compliance_reports_kit_drift() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --outcome pass --model m >/dev/null 2>&1
  done
  # Simulate the drift: the tool changes after the entries were written.
  printf '\n# drift\n' >> "$REPO/.pipeline/tools/ledger.sh"
  run led compliance --change c --tier T4
  assert_contains "KIT DRIFT"
}

# ...and it SHOWS the drift without acting on it. Nothing here may skip a gate
# or flip a verdict: round 2 of the first real run re-reviewed round 1's fixes
# and found new real bugs in them, so "same artifact, same tooling" is not a
# licence to skip. A drifted-but-passing change still exits 0.
test_kit_drift_shows_but_never_decides() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --outcome pass --model m \
      --note "$([ "$g" = G1 ] && echo 'why this change exists' || echo ok)" >/dev/null 2>&1
  done
  printf '\n# drift\n' >> "$REPO/.pipeline/tools/ledger.sh"
  run led compliance --change c --tier T4
  assert_exit 0
  assert_contains "All T4-mandated gates satisfied"
}

# ---- Finding identity, without finding state ------------------------------

# An id lets a later conversation name a finding instead of re-describing it.
test_findings_get_stable_ids() {
  newrepo
  led add --confidence fresh --change week-strip --gate G4 --tier T4 --round 2 --outcome fail --model m \
    --finding "blocking::a.js:1::first" --finding "minor::a.js:2::second" >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"id":"week-strip-r2-G4-1"'
  assert_file_contains "$(ledger_path)" '"id":"week-strip-r2-G4-2"'
}

# The id is deliberately NOT a state. If a resolution field existed it would be
# written by the author about the author's own fix, and would then be the
# obvious thing to hand the next reviewer — which is the anchoring the blind
# review rule exists to prevent. This test fails the day someone adds one.
test_the_ledger_records_no_finding_resolution_state() {
  newrepo
  led add --confidence fresh --change c --gate G4 --tier T4 --outcome fail --model m \
    --finding "blocking::a.js:1::x" >/dev/null 2>&1
  assert_not_file_contains "$(ledger_path)" '"resolved"'
  assert_not_file_contains "$(ledger_path)" '"status"'
}

# ---- The cards are the unit handed to a subagent --------------------------
#
# core/02-gates.md says so. They were not: the severity vocabulary lived only in
# 04-ledger.md, the model tier only in 08-models.md, and no card mentioned
# ledger.sh at all. One run produced invented severities, model:"unset" on every
# line, and bare counts — three defects, one cause.
test_every_card_carries_its_model_tier() {
  for c in "$KIT"/core/cards/G*.md; do
    assert_file_contains "$c" "model:"
  done
}

test_every_card_carries_the_severity_vocabulary() {
  for c in "$KIT"/core/cards/G*.md; do
    assert_file_contains "$c" "blocking | minor | info | out-of-scope"
  done
}

test_every_card_says_how_to_log_the_run() {
  for c in "$KIT"/core/cards/G*.md; do
    assert_file_contains "$c" "ledger.sh add"
  done
}

# 08-models.md is the reasoning, the card is what the dispatcher reads. A tier
# stated in one place and not the other is the drift this kit has shipped four
# times, so the two are compared rather than trusted.
test_dogfood_model_tier_agrees_between_card_and_chapter() {
  assert_file_contains "$KIT/core/cards/G8-dogfood.md" "whatever drives the interface"
  # 08-models.md's table cell capitalizes it (sentence-initial), same reason the
  # Ripple test right below checks "strongest available" vs "Strongest available".
  assert_file_contains "$KIT/core/08-models.md" "Whatever drives the interface"
}

test_ripple_model_tier_agrees_between_card_and_chapter() {
  assert_file_contains "$KIT/core/cards/G4-ripple.md" "strongest available"
  assert_file_contains "$KIT/core/08-models.md" "Strongest available"
}

# An older pass counts — requiring every gate to re-pass at every round means a
# one-line fix in round 3 re-runs all six, which nobody does twice. But the age
# has to be visible, because judging whether it is still valid is the reviewer's
# call and they can only make it if they can see it (tools/ledger.sh:265-278).
test_compliance_older_pass_counts_but_shows_its_age() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --outcome pass --round 1 \
      --note "$([ "$g" = G1 ] && echo 'why this change exists' || echo ok)" >/dev/null 2>&1
  done
  run led compliance --change c --tier T4 --round 3
  assert_exit 0
  assert_contains "PASS*"
  assert_contains "2 round(s) of changes since"
}

test_compliance_fail_outcome_is_not_a_pass() {
  newrepo
  for g in G1 G4 G5 G6 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --outcome pass >/dev/null 2>&1
  done
  led add --confidence fresh --change c --gate G7 --tier T4 --outcome fail --finding \
    'blocking::src/quota.js:88::read-time check passes for parallel requests' >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1 "a failed hard gate must not satisfy the tier"
  # Bug 1: a gate that ran, found real problems, and correctly logged `fail`
  # must be reported as FAIL — not folded into the generic "NOT RUN" bucket
  # where it is indistinguishable from a gate nobody attempted.
  assert_row "FAIL" "G7"
  assert_not_contains "NOT RUN    G7"
  assert_contains "1 finding(s)"
}

# Bug 2: the ledger is append-only, so a `skipped` placeholder from an aborted
# attempt never stops existing — `gate_has_outcome` matched it forever, even
# after a real `fail` was logged straight after it. Compliance must key off the
# LATEST entry for (change, gate), not "was this outcome ever logged".
test_compliance_latest_entry_wins_over_stale_skip() {
  newrepo
  for g in G1 G4 G5 G6 G8; do
    led add --confidence fresh --change c --gate "$g" --tier T4 --outcome pass >/dev/null 2>&1
  done
  led add --change c --gate G7 --tier T4 --outcome skipped >/dev/null 2>&1
  led add --confidence fresh --change c --gate G7 --tier T4 --outcome fail \
    --finding "blocking::a.js:1::one"  --finding "blocking::a.js:2::two" \
    --finding "minor::a.js:3::three"   --finding "info::a.js:4::four" \
    --finding "info::a.js:5::five"     --finding "info::a.js:6::six" \
    --finding "info::a.js:7::seven" >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1
  assert_row "FAIL" "G7"
  assert_not_contains "SKIPPED    G7"
  assert_contains "7 finding(s)"
}

# The reverse order: a real fail logged first, then a `skipped` (what the pre-push override advice
# logs) on record. Only a later PASS clears a fail -- not `skipped`, not `n/a` -- whether or not the
# gate ever passed before (G6 round 12: with a prior pass it already read FAIL, without one it read
# SKIPPED, so a gate's verdict depended on history that had nothing to do with the fail).
test_a_skipped_after_a_fail_does_not_clear_the_fail() {
  newrepo
  led add --confidence fresh --change c --gate G7 --tier T4 --outcome fail \
    --finding "blocking::a.js:1::one" --finding "minor::a.js:2::two" \
    --finding "info::a.js:3::three" >/dev/null 2>&1
  led add --change c --gate G7 --tier T4 --outcome skipped >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_row "FAIL" "G7"
  assert_not_contains "SKIPPED    G7"
}

# Compliance reads one change at a time. A pass logged against a *different*
# change must not satisfy this one — that would make the check trivially
# gameable by naming.
test_compliance_ignores_other_changes() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --confidence fresh --change other --gate "$g" --tier T4 --outcome pass >/dev/null 2>&1
  done
  run led compliance --change c --tier T4
  assert_exit 1
  assert_contains "INCOMPLETE"
}

# ================================================================ report
#
# The report's whole job is telling you whether the gates are working. A metric
# that prints an impossible number is worse than one that prints nothing.

test_report_challenge_rate_cannot_exceed_100() {
  newrepo
  led add --change c --gate G6 --tier T3 --challenged true --confidence fresh >/dev/null 2>&1
  led add --change c --gate G7 --tier T3 --challenged true --confidence low   >/dev/null 2>&1
  led add --change c --gate G4 --tier T3 --challenged false --confidence fresh >/dev/null 2>&1
  run led report
  assert_exit 0
  # 2 challenged / 3 runs, but only 1 of the challengers ran fresh: 1/2 = 50%.
  assert_contains "challenge rate     50%"
}

test_report_refuses_an_empty_ledger() {
  newrepo
  : > "$(ledger_path)"
  run led report
  assert_exit 1
  assert_contains "did not run"
}

test_report_miss_rate_counts_under_classifications() {
  newrepo
  led route --change a --predicted T1 --actual T4 >/dev/null 2>&1
  led route --change b --predicted T3 --actual T3 >/dev/null 2>&1
  run led report
  assert_contains "MISS RATE          50%"
}

# ================================================================ pre-push hook
#
# The only enforcement point that runs whether or not anyone remembers it — and
# the one whose success is silent, so a hook that has stopped working looks
# exactly like a hook that is working.

hook() { ( cd "$REPO" && BASE="$BASE_SHA" sh .pipeline/templates/pre-push ); }

# The shipped placeholder `<your|trust|boundary|paths>` was a valid ERE, so an
# unedited hook installed, ran, matched nothing anyone owns, and said nothing.
test_hook_refuses_to_run_with_no_rules() {
  newrepo
  rm -f "$REPO/.pipeline/project/surfaces.conf"
  printf 'x\n' > "$REPO/src/app.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  run hook
  assert_exit 1 "a hook with no rules must not report success"
  assert_contains "cannot tell which files are trust boundaries"
}

test_hook_blocks_a_trust_boundary_push_without_a_report() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  run hook
  assert_exit 1
  assert_contains "BLOCKED"
  assert_contains "src/auth/existing.js"
}

test_hook_passes_a_push_that_touches_nothing_guarded() {
  newrepo
  printf 'docs\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  run hook
  assert_exit 0
}

# Commit-scoped, not time-windowed: a report proves this diff was reviewed, not
# that a file exists.
test_hook_accepts_a_report_naming_this_commit() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  git -C "$REPO" rev-parse HEAD > "$REPO/.pipeline/security-reports/g7.md"
  run hook
  assert_exit 0
}

test_hook_rejects_a_report_about_a_different_commit() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s thoroughly\n' "$BASE_SHA" > "$REPO/.pipeline/security-reports/g7.md"
  run hook
  assert_exit 1
}

# E4: a report cannot name the commit that contains it. Committing the report moved HEAD,
# so a HEAD-scoped hook re-blocked the push forever. The newest trust-touching commit is
# what needs a report; commits after it (the report itself) must not invalidate it.
test_hook_accepts_report_committed_after_the_reviewed_commit() {
  newrepo
  printf 'token=2
' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "the T4 change" >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  git -C "$REPO" rev-parse HEAD > "$REPO/.pipeline/security-reports/g7.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "add the report" >/dev/null 2>&1
  run hook
  assert_exit 0 "committing the report must not re-block the push"
}

test_hook_still_blocks_a_newer_trust_edit_after_the_reviewed_one() {
  newrepo
  printf 'token=2
' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "reviewed T4 change" >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  git -C "$REPO" rev-parse HEAD > "$REPO/.pipeline/security-reports/g7.md"
  printf 'token=3
' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "later, unreviewed T4 edit" >/dev/null 2>&1
  run hook
  assert_exit 1 "a trust edit newer than the reviewed commit needs its own report"
  assert_contains "BLOCKED"
}

# E4 (G6/G7 round 1): "contains every trust commit", not "newest by date". A real report
# about an unrelated commit merged in from elsewhere is not evidence about the trust change.
test_hook_report_on_a_merged_in_unrelated_commit_does_not_clear_a_trust_commit() {
  newrepo
  git -C "$REPO" checkout -q -b side
  printf 'docs\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "harmless" >/dev/null 2>&1
  local c; c="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$c" > "$REPO/.pipeline/security-reports/other.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "report for the harmless commit" >/dev/null 2>&1
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  git -C "$REPO" checkout -q -b feat "$BASE_SHA"
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "unreviewed T4 change" >/dev/null 2>&1
  git -C "$REPO" merge -q --no-ff side -m "merge side" >/dev/null 2>&1
  run hook
  assert_exit 1 "a report about a merged-in harmless commit must not clear the unreviewed trust edit"
  assert_contains "BLOCKED"
  # Control: a report naming the merge (which contains the trust commit) does clear it.
  git -C "$REPO" rev-parse HEAD > "$REPO/.pipeline/security-reports/merge.md"
  run hook
  assert_exit 0 "a report naming a commit that contains the trust change clears it"
}

# The same two properties through the path a real `git push` takes (stdin), which every
# earlier hook test bypassed with the BASE override (G5 round 1).
test_hook_stdin_path_blocks_without_a_report_and_passes_with_one() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "T4 change" >/dev/null 2>&1
  local x; x="$(git -C "$REPO" rev-parse HEAD)"
  run hook_stdin refs/heads/master "$x" refs/heads/master "$BASE_SHA"
  assert_exit 1 "no report: blocked on the stdin path"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$x" > "$REPO/.pipeline/security-reports/g7.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "the report" >/dev/null 2>&1
  run hook_stdin refs/heads/master "$(git -C "$REPO" rev-parse HEAD)" refs/heads/master "$BASE_SHA"
  assert_exit 0 "report committed after the reviewed commit: passes on the stdin path"
}

# G6/G5 round 1: a trust edit made ONLY while resolving a merge conflict is invisible to a
# plain diff-tree, and an older report then cleared the push.
test_hook_counts_a_trust_edit_made_only_in_a_merge_commit() {
  newrepo
  git -C "$REPO" checkout -q -b side
  printf 'a\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "side edit" >/dev/null 2>&1
  local s; s="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b feat "$BASE_SHA"
  printf 'b\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "feat edit" >/dev/null 2>&1
  git -C "$REPO" merge side >/dev/null 2>&1
  printf 'resolved\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "merge, resolved by hand" >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s" > "$REPO/.pipeline/security-reports/old.md"
  run hook
  assert_exit 1 "a report on a side commit must not clear a hand-resolved trust edit in the merge"
}

# G8/G6 round 2: the README's own flow. A reviewed branch merged with --no-ff, report
# committed -- `diff-tree -m` counted the merge itself as a trust-touching commit the
# reviewed commit does not contain, so it blocked forever. Also kills the -m/-c mutation.
test_hook_passes_a_reviewed_branch_merged_with_no_ff() {
  newrepo
  git -C "$REPO" checkout -q -b feat
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "reviewed T4 change" >/dev/null 2>&1
  local x; x="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$x" > "$REPO/.pipeline/security-reports/g7.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "the report" >/dev/null 2>&1
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  printf 'docs\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "unrelated trunk work" >/dev/null 2>&1
  git -C "$REPO" merge -q --no-ff feat -m "merge feat" >/dev/null 2>&1
  run hook
  assert_exit 0 "a reviewed branch merged with --no-ff must not need a second report"
}

# G5 round 2 (mutation: drop the merge flag entirely): a trust edit made ONLY while resolving
# a merge of a side branch that never touched the file. Plain diff-tree shows nothing for a
# merge, so without -c the push passed on the strength of the earlier commit's report.
test_hook_blocks_a_trust_edit_made_only_inside_a_merge_of_an_unrelated_branch() {
  newrepo
  git -C "$REPO" checkout -q -b side
  printf 'docs\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "side: docs only" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b feat "$BASE_SHA"
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "reviewed T4 change" >/dev/null 2>&1
  local x; x="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff side >/dev/null 2>&1
  printf 'token=EVIL\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "merge, slipping in a trust edit" >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$x" > "$REPO/.pipeline/security-reports/g7.md"
  run hook
  assert_exit 1 "the edit inside the merge was never reviewed"
}

# G5 round 2 (mutation: drop 'must be part of THIS push'): a report naming an unpushed
# descendant of the trust commit, on another branch, is not evidence about what is pushed.
test_hook_ignores_a_report_naming_a_commit_that_is_not_in_the_push() {
  newrepo
  git -C "$REPO" checkout -q -b feat
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "T4 change" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b later
  git -C "$REPO" commit -q --allow-empty -m "later, unpushed"
  local y; y="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q feat
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$y" > "$REPO/.pipeline/security-reports/g7.md"
  run hook
  assert_exit 1 "a commit outside the pushed range cannot vouch for it"
}

# G8 round 3: on Git for Windows, `git push 2>&1 | head -2` killed the hook with SIGPIPE (rc 141)
# after BLOCKED printed and before `exit 1`; git treats that as success and pushed anyway.
test_hook_still_blocks_when_its_output_is_piped_into_something_that_exits_early() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "T4 change" >/dev/null 2>&1
  local rc
  ( cd "$REPO" && BASE="$BASE_SHA" sh .pipeline/templates/pre-push 2>&1 | head -1 >/dev/null; exit "${PIPESTATUS[0]}" )
  rc=$?
  assert_eq "1" "$rc" "the hook must exit 1 (blocked), not die of SIGPIPE (141) which git reads as success"
}

# G5 round 3: a first push (remote sha all zeros -> empty-tree base) cleared by a report. Only the
# block case was tested.
test_hook_first_push_is_cleared_by_a_report_naming_the_tip() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "T4 change" >/dev/null 2>&1
  local x; x="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$x" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$x" refs/heads/master "$ZERO_SHA"
  assert_exit 0 "a report naming a commit that contains every trust commit clears a first push"
}

# G6 round 4: `diff-tree -c` lists only files that differ from EVERY parent, so a merge that resolves
# a trust file to the incoming side -- quietly reverting a change already on the remote -- listed
# nothing, and a report covering just the side branch's own commit let the revert through. Content
# attribution: some non-merge commit in the push must have written what ends up at the tip.
test_hook_blocks_a_merge_that_silently_reverts_a_trust_change_already_on_the_remote() {
  newrepo
  printf 'x1\n' > "$REPO/src/auth/x.js"; printf 'y1\n' > "$REPO/src/auth/y.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "root2" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b feat
  printf 'y2\n' > "$REPO/src/auth/y.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "F: the reviewed change to y" >/dev/null 2>&1
  local f; f="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  printf 'x2\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "P1: trunk change to x, already pushed" >/dev/null 2>&1
  local p1; p1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff feat >/dev/null 2>&1
  printf 'x1\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M: merge that quietly reverts x" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$f" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$p1"
  assert_exit 1 "the revert of x was written by no reviewed commit"
  printf 'reviewed %s\n' "$m" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$p1"
  assert_exit 0 "a report naming the merge itself covers what the merge did"
}

# ---- Round 6: findings from round 5 ----
#
# G6/G7 round 5: a merge that quietly reverts a trust change already on the remote, where the
# result equals one parent, is invisible to `diff-tree -c`. What a correct merge produces is fixed
# by its parents and their merge base, so the result is compared with that expectation.
# (a) side branch writes W then reverts to base; trunk (already pushed) sets Y; the merge sets base.
test_hook_blocks_a_merge_that_reverts_trunk_to_content_a_side_commit_restored() {
  newrepo
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R0" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side
  printf 'W\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S1" >/dev/null 2>&1
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S2: back to base" >/dev/null 2>&1
  local s2; s2="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  printf 'Y\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R1: trunk change, already pushed" >/dev/null 2>&1
  local r1; r1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff side >/dev/null 2>&1
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M: reverts Y" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s2" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$r1"
  assert_exit 1 "S2 wrote the base content, but the merge used it to revert Y -- that is the merge's own act"
  printf 'reviewed %s\n' "$m" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$r1"
  assert_exit 0 "naming the merge covers it"
}

# (b) the fix (GOOD) landed after BAD; a branch cut at BAD is merged and resolved back to BAD.
test_hook_blocks_a_merge_that_restores_a_state_the_push_already_replaced() {
  newrepo
  printf 'BAD\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "c0: BAD" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side
  printf 'docs\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "side: docs" >/dev/null 2>&1
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  printf 'GOOD\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "c1: GOOD (the fix)" >/dev/null 2>&1
  local c1; c1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff side >/dev/null 2>&1
  printf 'BAD\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M: resolved back to BAD" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$c1" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$BASE_SHA"
  assert_exit 1 "a report on the fix does not cover the merge that undid it"
}

# A trust file whose name contains glob characters (Next.js [...nextauth].ts is real). With the
# old rev-list pathspec the name picked up a sibling's commits and "explained" the revert.
test_hook_blocks_a_revert_of_a_trust_file_with_glob_characters_in_its_name() {
  newrepo
  printf 'X\n' > "$REPO/src/auth/[ab].js"; printf 'A\n' > "$REPO/src/auth/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "base" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side
  printf 'A2\n' > "$REPO/src/auth/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S1: only a.js" >/dev/null 2>&1
  local s1; s1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  printf 'Y\n' > "$REPO/src/auth/[ab].js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R1: pushed" >/dev/null 2>&1
  local r1; r1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff side >/dev/null 2>&1
  printf 'X\n' > "$REPO/src/auth/[ab].js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M: reverts [ab].js" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s1" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$r1"
  assert_exit 1 "S1 touched a different file; it cannot vouch for the revert of [ab].js"
}

# git quotes non-ASCII paths ("auth/caf\303\251.js") so an anchored TRUST regex never matched.
test_hook_sees_a_trust_file_with_a_non_ascii_name() {
  newrepo
  printf 'x\n' > "$REPO/src/auth/caf$(printf '\303\251').js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "non-ASCII trust file" >/dev/null 2>&1
  # An ANCHORED trust regex: git quotes the name as "src/auth/cafÃ©.js" (leading quote), so a
  # pattern anchored at the start never matches the quoted form. (The fixture's own unanchored
  # `(^|/)auth/` would still match mid-string and hide the bug.)
  run bash -c "cd '$REPO' && printf 'refs/heads/master %s refs/heads/master %s
' \"\$(git rev-parse HEAD)\" '$BASE_SHA' | TRUST='^src/auth/' sh .pipeline/templates/pre-push"
  assert_exit 1 "a trust file with a non-ASCII name still needs a report"
}

# ---- round 7: findings from the round-6 reviews (compliance-e1-e11-correctness) ----

# G7 r6 #1: `git diff --name-only` detects renames and lists only the destination, so moving a
# trust file out of a guarded path matched nothing and the hook passed. --no-renames lists both.
test_hook_blocks_moving_a_trust_file_out_of_a_guarded_path() {
  newrepo
  mkdir -p "$REPO/src/legacy"
  git -C "$REPO" mv src/auth/existing.js src/legacy/existing.js >/dev/null 2>&1
  git -C "$REPO" commit -qm "move the trust file away" >/dev/null 2>&1
  run bash -c "cd '$REPO' && printf 'refs/heads/master %s refs/heads/master %s\n' \"\$(git rev-parse HEAD)\" '$BASE_SHA' | TRUST='^src/auth/' sh .pipeline/templates/pre-push"
  assert_exit 1 "a rename out of a trust path is a change to the trust file"
  assert_contains "src/auth/existing.js"
}

test_hook_blocks_moving_a_trust_file_and_editing_it_in_the_same_commit() {
  newrepo
  local i
  : > "$REPO/src/auth/big.js"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf 'line %s\n' "$i" >> "$REPO/src/auth/big.js"; done
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "big trust file" >/dev/null 2>&1
  local base; base="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/src/legacy"
  git -C "$REPO" mv src/auth/big.js src/legacy/big.js >/dev/null 2>&1
  sedi '5d' "$REPO/src/legacy/big.js"; printf 'exportAll()\n' >> "$REPO/src/legacy/big.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "move and weaken" >/dev/null 2>&1
  run bash -c "cd '$REPO' && printf 'refs/heads/master %s refs/heads/master %s\n' \"\$(git rev-parse HEAD)\" '$base' | TRUST='^src/auth/' sh .pipeline/templates/pre-push"
  assert_exit 1 "a move that also edits the file must not hide the edit"
}

# G7 r6 #2: git still quotes a path containing a tab, a double quote or a backslash, so an anchored
# rule missed it. The fixture builds the commit with plumbing (NTFS refuses a tab in a file name).
test_hook_sees_a_trust_file_whose_name_git_would_quote() {
  newrepo
  local blob tree c idx="$REPO/.git/r7idx" name
  name="$(printf 'src/auth/a\tb.js')"
  blob="$(printf 'x\n' | git -C "$REPO" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$REPO" read-tree HEAD
  GIT_INDEX_FILE="$idx" git -C "$REPO" -c core.protectNTFS=false update-index --add --cacheinfo "100644,$blob,$name"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree)"
  c="$(git -C "$REPO" commit-tree "$tree" -p HEAD -m "tab in a trust file name")"
  run bash -c "cd '$REPO' && printf 'refs/heads/master %s refs/heads/master %s\n' '$c' '$BASE_SHA' | TRUST='^src/auth/' sh .pipeline/templates/pre-push"
  assert_exit 1 "a quoted path must still match an anchored trust rule"
}

# G8 r6 #5: the message must say the surfaces FILE is missing, not that it has no T4 rows.
test_hook_says_so_when_the_surfaces_file_is_missing() {
  newrepo
  printf 'docs\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  run bash -c "cd '$REPO' && SURFACES=/nonexistent/surfaces.conf BASE='$BASE_SHA' sh .pipeline/templates/pre-push"
  assert_exit 1
  assert_contains "does not exist"
}

# G5 r6 #5: the BASE= override path fails closed too.
test_hook_base_override_fails_closed_when_git_cannot_diff() {
  newrepo
  run bash -c "cd '$REPO' && BASE=no-such-ref-r7 sh .pipeline/templates/pre-push"
  assert_exit 1 "an unresolvable BASE must block, not read as 'nothing changed'"
  assert_contains "cannot compare"
}

# G5 r6 #1/#2/#3/#4: merge-check branches that no test pinned (mutations survived).
test_hook_merge_only_edit_is_not_covered_by_a_report_on_another_trust_commit() {
  newrepo
  local tr; tr="$(git -C "$REPO" symbolic-ref --short HEAD)"
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R0" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side
  printf 'a2\n' > "$REPO/src/auth/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S1 a.js" >/dev/null 2>&1
  local s1; s1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$tr"
  printf 'doc\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R1 docs" >/dev/null 2>&1
  local r1; r1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff side >/dev/null 2>&1
  printf 'EVIL\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M edits x.js only in merge" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s1" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$r1"
  assert_exit 1 "an edit made only in the merge is not covered by a report on S1"
}

test_hook_merge_picking_one_side_of_a_file_both_sides_changed_is_blocked() {
  newrepo
  local tr; tr="$(git -C "$REPO" symbolic-ref --short HEAD)"
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R0" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side
  printf 'W\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S1 W" >/dev/null 2>&1
  local s1; s1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$tr"
  printf 'Y\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R1 Y pushed" >/dev/null 2>&1
  local r1; r1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff side >/dev/null 2>&1
  printf 'W\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M takes W, drops Y" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s1" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$r1"
  assert_exit 1 "a merge discarding the pushed Y needs its own report"
}

test_hook_octopus_merge_that_reverts_a_pushed_trust_change_is_blocked() {
  newrepo
  local tr; tr="$(git -C "$REPO" symbolic-ref --short HEAD)"
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R0" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b s1
  printf 'a2\n' > "$REPO/src/auth/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S1 trust a.js" >/dev/null 2>&1
  local s1; s1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$tr"
  git -C "$REPO" checkout -q -b s2
  printf 'doc\n' > "$REPO/README.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S2 docs" >/dev/null 2>&1
  git -C "$REPO" checkout -q "$tr"
  printf 'Y\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R1 pushed" >/dev/null 2>&1
  local r1; r1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff s1 s2 >/dev/null 2>&1
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M octopus reverts Y" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  assert_eq 4 "$(git -C "$REPO" rev-list --parents -n1 "$m" | wc -w | tr -d ' ')" "is an octopus"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s1" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/master "$m" refs/heads/master "$r1"
  assert_exit 1 "an octopus revert of a pushed trust change is the merge's own act"
}

test_hook_later_non_ascii_trust_commit_is_not_covered_by_an_earlier_report() {
  newrepo
  printf 'a2\n' > "$REPO/src/auth/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "A: ascii trust" >/dev/null 2>&1
  local a; a="$(git -C "$REPO" rev-parse HEAD)"
  printf 'x\n' > "$REPO/src/auth/caf$(printf '\303\251').js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "B: non-ascii trust" >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$a" > "$REPO/.pipeline/security-reports/g7.md"
  run bash -c "cd '$REPO' && printf 'refs/heads/master %s refs/heads/master %s\n' \"\$(git rev-parse HEAD)\" '$BASE_SHA' | TRUST='^src/auth/' sh .pipeline/templates/pre-push"
  assert_exit 1 "a report on A does not cover the later non-ASCII trust commit B"
}

test_hook_merge_reverting_a_non_ascii_trust_file_is_blocked() {
  newrepo
  local tr; tr="$(git -C "$REPO" symbolic-ref --short HEAD)"
  local f="src/auth/caf$(printf '\303\251').js"
  printf 'base\n' > "$REPO/$f"; printf 'A\n' > "$REPO/src/auth/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R0" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side
  printf 'A2\n' > "$REPO/src/auth/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S1" >/dev/null 2>&1
  local s1; s1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$tr"
  printf 'Y\n' > "$REPO/$f"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R1" >/dev/null 2>&1
  local r1; r1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-commit --no-ff side >/dev/null 2>&1
  printf 'base\n' > "$REPO/$f"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M reverts" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s1" > "$REPO/.pipeline/security-reports/g7.md"
  run bash -c "cd '$REPO' && printf 'refs/heads/master %s refs/heads/master %s\n' '$m' '$r1' | TRUST='^src/auth/' sh .pipeline/templates/pre-push"
  assert_exit 1 "a merge reverting a non-ASCII trust file"
}

# G8 r6 #1: the next flag standing where a value belongs is not a value.
test_reconcile_refuses_a_flag_where_an_option_value_belongs() {
  newrepo
  run rec T4 --round --log
  assert_exit 2 "--round --log must not read --log as the round"
  assert_contains "needs a value"
  run rec T4 --action --evidence x
  assert_exit 2
}

test_compliance_refuses_an_option_with_no_value() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1   # a ledger must exist
  run led compliance --change c --tier T4 --round
  assert_exit 2 "a trailing --round is a usage error, not 'not compliant'"
  assert_contains "needs a value"
  run led compliance --change c --round --tier T4
  assert_exit 2
}

# G6/G7/G8 r6: gate results are scoped to the CURRENT lineage, like the base and the tier floor.
_r7_pass_all() {   # $1 = change, $2 = tier, $3 = round
  local g
  for g in G3 G4 G5 G6 G8; do
    led add --change "$1" --gate "$g" --tier "$2" --round "$3" --outcome pass --confidence fresh --model m >/dev/null 2>&1
  done
}

test_compliance_new_lineage_passes_are_not_outranked_by_old_higher_round_passes() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "work 1"
  _r7_pass_all c T2 2
  git -C "$REPO" commit -q --allow-empty -m "work 2"
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)" --restart-lineage >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "work 3"
  _r7_pass_all c T2 1
  run led compliance --change c --tier T2 --round 1
  assert_exit 0 "passes logged in the new lineage count; the old round-2 passes are another lineage's"
  assert_not_contains "UNBOUND"
}

test_route_refuses_to_restart_a_lineage_while_a_gate_failure_is_open() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G7 --tier T4 --round 1 --outcome fail --confidence fresh --model m --finding "blocking::src/auth/a.js:1::bad" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "later"
  local b2; b2="$(git -C "$REPO" rev-parse HEAD)"
  local before; before="$(wc -l < "$(ledger_path)")"
  run led route --change c --predicted T1 --actual T1 --round 1 --reason r --base "$b2"
  assert_exit 2 "a new round-1 route must not launder an unresolved G7 fail"
  assert_contains "unresolved FAIL"
  assert_eq "$before" "$(wc -l < "$(ledger_path)")" "nothing was written"
  # the floor and the failure still stand
  run led compliance --change c --tier T1
  assert_exit 2 "still floored at T4"
  # a deliberate restart is allowed, and says so
  run led route --change c --predicted T1 --actual T1 --round 1 --reason r --base "$b2" --restart-lineage
  assert_exit 0
  assert_contains "NEW lineage"
}

# ---- round 8: findings from the round-7 reviews (compliance-e1-e11-correctness) ----

# G6/G7/G8 r7: a restart is never guessed. A round-1 route with a DIFFERENT base needs the flag
# whatever is on record (an open FAIL, gates never run, only passes); the SAME base is a re-run.
test_route_refuses_a_restart_without_the_flag_even_when_everything_passed() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G7 --tier T4 --round 1 --outcome pass --confidence fresh --model m >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "later"
  local b2; b2="$(git -C "$REPO" rev-parse HEAD)"
  local before; before="$(wc -l < "$(ledger_path)")"
  run led route --change c --predicted T1 --actual T1 --round 1 --reason r --base "$b2"
  assert_exit 2 "forgetting ROUND after a push must not silently start a new lineage"
  assert_contains "--restart-lineage"
  assert_eq "$before" "$(wc -l < "$(ledger_path)")" "nothing was written"
}

test_route_refuses_a_restart_when_mandated_gates_never_ran() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "later"
  run led route --change c --predicted T1 --actual T1 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)"
  assert_exit 2 "never-reviewed is no easier to launder than reviewed-and-failed"
  run led compliance --change c --tier T1
  assert_exit 2 "the T4 floor still stands"
}

test_route_same_base_again_is_a_rerun_not_a_new_lineage() {
  newrepo
  led route --change c --predicted T1 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G7 --tier T4 --round 1 --outcome pass --confidence fresh --model m >/dev/null 2>&1
  run led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA"
  assert_exit 0 "the same reconcile run again needs no flag"
  assert_not_contains "NEW lineage"
  run led compliance --change c --tier T4
  assert_row "PASS" "G7"
}

# G1/G5/G6/G7 r7: only the exact value 1 restarts a lineage. Driven through reconcile.sh.
_r8_two_commits() {   # leaves HEAD one commit past the first reconciled one; sets R8_C1
  printf 'x\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c1 >/dev/null 2>&1
  R8_C1="$(git -C "$REPO" rev-parse HEAD)"
}

test_reconcile_restart_lineage_env_must_be_exactly_one() {
  newrepo
  _r8_two_commits
  CHANGE=c run rec T4 --log
  printf 'y\n' > "$REPO/src/auth/second.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c2 >/dev/null 2>&1
  local before; before="$(grep -c '"type":"route"' "$(ledger_path)")"
  run bash -c "cd '$REPO' && BASE='$R8_C1' CHANGE=c RESTART_LINEAGE=0 bash .pipeline/tools/reconcile.sh T4 --log"
  assert_contains "--restart-lineage"
  assert_eq "$before" "$(grep -c '"type":"route"' "$(ledger_path)")" "RESTART_LINEAGE=0 must not restart"
  run bash -c "cd '$REPO' && BASE='$R8_C1' CHANGE=c RESTART_LINEAGE=1 bash .pipeline/tools/reconcile.sh T4 --log"
  assert_eq "$((before + 1))" "$(grep -c '"type":"route"' "$(ledger_path)")" "RESTART_LINEAGE=1 restarts"
}

test_reconcile_forwards_the_restart_lineage_flag_to_route() {
  newrepo
  _r8_two_commits
  CHANGE=c run rec T4 --log
  printf 'y\n' > "$REPO/src/auth/second.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c2 >/dev/null 2>&1
  local before; before="$(grep -c '"type":"route"' "$(ledger_path)")"
  run bash -c "cd '$REPO' && BASE='$R8_C1' CHANGE=c bash .pipeline/tools/reconcile.sh T4 --log --restart-lineage"
  assert_eq "$((before + 1))" "$(grep -c '"type":"route"' "$(ledger_path)")" "the flag reached ledger.sh route"
}

# G6 r6 / G4 r7: the lineage helper ignores hand-typed (base-less) routes; a hand-typed round-1
# route must not wipe the passes of a reconciled lineage.
test_compliance_hand_typed_round_one_route_does_not_wipe_a_reconciled_lineage() {
  newrepo
  led route --change e --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m w
  _r7_pass_all e T2 1
  led route --change e --predicted T2 --actual T2 --round 1 --reason 'typed by hand' >/dev/null 2>&1
  run led compliance --change e --tier T2 --round 1
  assert_exit 0 "a route without --base is not a lineage"
}

# G8 r7 #2: a flag is not a change name (the ledger is append-only).
test_ledger_add_and_route_refuse_a_flag_as_the_change_name() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  local before; before="$(wc -l < "$(ledger_path)")"
  run led add --change --log --gate G7 --tier T4 --round 1 --outcome pass --confidence fresh --model m
  assert_exit 2 "add must not store '--log' as a change"
  assert_contains "needs a value"
  run led route --change --restart-lineage --predicted T4 --actual T4
  assert_exit 2
  run led add --gate G7 --tier T4 --round 1 --outcome pass --confidence fresh --model m --change
  assert_exit 2 "a trailing --change is a usage error, not an unbound variable"
  assert_not_contains "unbound variable"
  assert_eq "$before" "$(wc -l < "$(ledger_path)")" "nothing was written"
}

# G4/G5 r7: the compliance flag-as-value case must say so.
test_compliance_names_the_option_missing_its_value() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led compliance --tier T4 --change --round
  assert_exit 2
  assert_contains "--change needs a value"
}

# G8 r7 #5: without --round the check is about the latest round, not round 1.
test_compliance_default_round_is_the_latest_round_of_the_lineage() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome fail --confidence fresh --model m --finding "blocking::a.js:1::bad" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m fix
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  _r7_pass_all c T2 2
  run led compliance --change c --tier T2
  assert_exit 0 "round 1 failed but round 2 passed: that is where the change is"
  assert_contains "round 2"
}

# G8 r7 #1: the router and status.sh must see a trust file moved out of its guarded path, like the hook.
test_reconcile_classifies_a_trust_file_renamed_out_of_its_path_as_trust() {
  newrepo
  mkdir -p "$REPO/src/legacy"
  git -C "$REPO" mv src/auth/existing.js src/legacy/existing.js >/dev/null 2>&1
  git -C "$REPO" commit -qm "move the trust file away" >/dev/null 2>&1
  CHANGE=c run rec T1
  assert_exit 1 "a rename out of a T4 path is under-classified as T1, not 'safe'"
  assert_contains "T4"
}

test_status_counts_a_trust_file_renamed_out_of_its_path() {
  newrepo
  mkdir -p "$REPO/src/legacy"
  git -C "$REPO" mv src/auth/existing.js src/legacy/existing.js >/dev/null 2>&1
  git -C "$REPO" commit -qm "move the trust file away" >/dev/null 2>&1
  run status_run
  assert_exit 1 "a trust file moved out of its path is still unrouted T4 work"
  assert_contains "T4 — trust boundary"
}

# G7 r7 #3: a merge that drops the other side's MODE change on a trust file is still a change.
test_hook_merge_dropping_a_mode_change_is_blocked() {
  newrepo
  local tr; tr="$(git -C "$REPO" symbolic-ref --short HEAD)"
  printf 'g\n' > "$REPO/src/auth/guard.sh"; printf 'o\n' > "$REPO/src/auth/other.sh"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R0" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b feat
  printf 'o2\n' > "$REPO/src/auth/other.sh"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "L1 edits other.sh" >/dev/null 2>&1
  local l1; l1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$tr"
  git -C "$REPO" update-index --chmod=+x src/auth/guard.sh
  git -C "$REPO" commit -qm "C1 makes guard.sh executable" >/dev/null 2>&1
  local c1; c1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q feat
  git -C "$REPO" merge -q --no-commit --no-ff "$tr" >/dev/null 2>&1
  git -C "$REPO" update-index --chmod=-x src/auth/guard.sh
  git -C "$REPO" commit -qm "M merges and drops the exec bit" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$l1" > "$REPO/.pipeline/security-reports/g7.md"
  run bash -c "cd '$REPO' && printf 'refs/heads/feat %s refs/heads/main %s\n' '$m' '$c1' | TRUST='^src/auth/' sh .pipeline/templates/pre-push"
  assert_exit 1 "removing the exec bit of a guarded script in a merge needs its own report"
}

# G5 r7 #2: the merge made on the SIDE branch (first parent = side), keeping its own version and
# dropping the change already on the remote -- the case the trunk-side test does not cover.
test_hook_merge_on_the_side_branch_dropping_a_pushed_change_is_blocked() {
  newrepo
  local tr; tr="$(git -C "$REPO" symbolic-ref --short HEAD)"
  printf 'base\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R0" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side
  printf 'W\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "S1 W" >/dev/null 2>&1
  local s1; s1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$tr"
  printf 'Y\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "R1 Y pushed" >/dev/null 2>&1
  local r1; r1="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q side
  git -C "$REPO" merge -q --no-commit --no-ff "$tr" >/dev/null 2>&1
  printf 'W\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "M on side keeps W, drops Y" >/dev/null 2>&1
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed %s\n' "$s1" > "$REPO/.pipeline/security-reports/g7.md"
  run hook_stdin refs/heads/side "$m" refs/heads/master "$r1"
  assert_exit 1 "a merge on the side branch that discards the pushed Y needs its own report"
}

# ---- round 9: findings from the round-8 reviews (compliance-e1-e11-correctness) ----

# Another branch's ledger, written by the tool inside the fixture repo (so --base/--commit resolve there).
_r9_other() { ( cd "$REPO" && bash .pipeline/tools/ledger.sh --ledger "$REPO/other.jsonl" "$@" ); }

# G7 r8: a restart is an explicit marker on the route row. A round-1 route with another base and no
# marker is what a union merge of two branches' ledgers produces; it must not drop an open FAIL.
test_route_restart_writes_a_marker_and_a_rerun_does_not() {
  newrepo
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  assert_not_file_contains "$(ledger_path)" '"restart":true'
  git -C "$REPO" commit -q --allow-empty -m later
  led route --change c --predicted T4 --actual T4 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)" --restart-lineage >/dev/null 2>&1
  assert_file_contains "$(ledger_path)" '"restart":true'
}

test_a_merged_ledger_cannot_restart_a_lineage_and_drop_an_open_fail() {
  newrepo
  # branch 1: the change starts at c1 and G6 fails there
  git -C "$REPO" commit -q --allow-empty -m c1
  local c1; c1="$(git -C "$REPO" rev-parse HEAD)"
  led route --change zz --predicted T2 --actual T2 --round 1 --reason r --base "$c1" >/dev/null 2>&1
  led add --change zz --gate G6 --tier T2 --round 1 --outcome fail --confidence fresh --model m --finding "blocking::a.js:1::bad" >/dev/null 2>&1
  # branch 2 (cut from the first commit): its own round-1 route from another base and its own passes,
  # produced by the tool on ITS ledger and then union-merged in. Nobody ran `route --restart-lineage`.
  _r9_other route --change zz --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  local g
  for g in G4 G5 G6 G8; do
    _r9_other add --change zz --gate $g --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  done
  cat "$REPO/other.jsonl" >> "$(ledger_path)"
  run led compliance --change zz --tier T2
  assert_exit 1 "the merged-in route is not a restart: the first base governs and the other branch's passes are outside it"
  assert_contains "no restart marker"
  assert_row "UNBOUND" "G6"
}

test_route_refuses_round_zero() {
  newrepo
  run led route --change c --predicted T4 --actual T4 --round 0 --reason r --base "$BASE_SHA"
  assert_exit 2
  assert_contains "rounds start at 1"
}

# G8/G6 r8: only a value that IS the next option is refused; ordinary text may start with "--".
test_ledger_note_may_start_with_two_dashes() {
  newrepo
  run led add --change c --gate G7 --tier T4 --round 1 --outcome skipped --model m --note "--no-verify was used for the push"
  assert_exit 0 "the note the pre-push hook itself advises is legitimate text"
  run led add --change c --gate G7 --tier T4 --round 1 --outcome skipped --model m --note --finding
  assert_exit 2 "a value that is exactly an option name is still refused"
}

# G8 r8 #2: a re-run of the same reconcile must not read as a second misclassification.
test_report_counts_a_rerun_of_the_same_reconcile_once() {
  newrepo
  led route --change c --predicted T1 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  sleep 1
  led route --change c --predicted T1 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led report
  assert_re "reconciliations[[:space:]]+1[[:space:]]"
}

# G5 r8 #4: change_latest_round must look at the current lineage only.
test_compliance_default_round_ignores_the_previous_lineage() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 3 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m restart
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)" --restart-lineage >/dev/null 2>&1
  _r7_pass_all c T2 1
  run led compliance --change c --tier T2
  assert_exit 0
  assert_contains "round 1"
  assert_not_contains "PASS*"
}

# G5 r8 #5: a round-2 route that precedes any round-1 route is no lineage to restart.
test_route_round_one_after_a_lone_round_two_is_not_called_a_restart() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m later
  run led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)"
  assert_exit 0
  assert_not_contains "NEW lineage"
}

# G6 r8 #3: a change reconciled at T0 has a recorded tier.
test_compliance_does_not_call_a_t0_reconciliation_missing() {
  newrepo
  led route --change c --predicted T0 --actual T0 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led compliance --change c --tier T0
  assert_not_contains "no reconciliation on record"
}

# G5 r8 #3: the uncommitted-kit branch of the "earlier commits" count (the pin is itself earlier history).
test_status_counts_the_pinned_commit_as_earlier_when_the_kit_is_not_committed() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "kit not tracked" >/dev/null 2>&1
  _cov_baseline "$REPO/.pipeline" >/dev/null     # pins HEAD
  git -C "$REPO" commit -q --allow-empty -m "work after install"
  run status_run
  assert_contains "3 earlier commit(s) predate the install"
}

# G7 r8 #2: an install commit that ALSO carries project work is counted, or a T4 change in it drops out.
test_status_counts_project_work_bundled_into_the_install_commit() {
  local r="$TMPROOT/bundled.$$"
  rm -rf "$r"; mkdir -p "$r/src/auth"
  git -C "$r" init -q; git -C "$r" config user.email t@e; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.autocrlf false
  printf 'readme\n' > "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm "first" >/dev/null 2>&1
  mkdir -p "$r/.pipeline"; cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$r/.pipeline/"
  cp "$KIT/templates/project/surfaces.conf" "$r/.pipeline/project/surfaces.conf"
  printf 'login\n' > "$r/src/auth/login.js"
  git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm "install kit + auth login" >/dev/null 2>&1
  printf 'more\n' >> "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm "docs" >/dev/null 2>&1
  run bash -c "cd '$r' && bash .pipeline/tools/status.sh"
  assert_contains "T4"
  assert_contains "install kit + auth login"
  assert_contains "since just before the kit was installed"
  assert_contains "1 earlier commit(s) predate the install"
}

# Round 7/8 lesson: the dashboard re-implements the verdict logic in JavaScript. Run both on the same
# ledger and compare the per-gate state, so a divergence fails here and not in a review round.
_r9_xcheck() {   # $1 = change, $2 = tier; asserts compliance and the dashboard agree per gate
  [ -n "$NODE" ] || { _skip "node not available"; return; }
  local comp dash g c d
  comp="$(led compliance --change "$1" --tier "$2" 2>/dev/null)"
  dash="$(cd "$REPO" && node "$KIT/tests/dash-gate-states.js" "$(ledger_path)" "$1" 2>&1)"
  for g in G3 G4 G5 G6 G8; do
    c="$(printf '%s\n' "$comp" | sed -n "s/^[[:space:]]*\(PASS\*\|PASS\|FAIL\|NOT RUN\|UNBOUND\)[[:space:]][[:space:]]*$g[[:space:]].*/\1/p" | head -1)"
    d="$(printf '%s\n' "$dash" | sed -n "s/^$g //p" | head -1)"
    [ -n "$c" ] || continue
    # UNBOUND means compliance found a pass it refuses to count; the dashboard has no git and shows
    # that pass, so compare it as a pass -- a lineage-start divergence then shows up as a mismatch.
    case "$c" in PASS|'PASS*'|UNBOUND) c=pass;; FAIL) c=fail;; *) c=none;; esac
    assert_eq "$c" "$d" "compliance and the dashboard disagree on $g for $1"
  done
}

test_dashboard_and_compliance_agree_after_a_lineage_restart() {
  newrepo
  led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m w1
  led add --change x --gate G4 --tier T2 --round 3 --outcome pass --confidence fresh --model m >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m w2
  led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)" --restart-lineage >/dev/null 2>&1
  led add --change x --gate G4 --tier T2 --round 1 --outcome fail --confidence fresh --model m --finding "blocking::a:1::bad" >/dev/null 2>&1
  _r9_xcheck x T2
}

test_dashboard_and_compliance_agree_on_a_merged_ledger() {
  newrepo
  led route --change zz --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change zz --gate G6 --tier T2 --round 1 --outcome fail --confidence fresh --model m --finding "blocking::a.js:1::bad" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m other-branch
  _r9_other route --change zz --predicted T2 --actual T2 \
    --round 1 --reason r --base "$(git -C "$REPO" rev-parse HEAD)" >/dev/null 2>&1
  cat "$REPO/other.jsonl" >> "$(ledger_path)"
  led add --change zz --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m >/dev/null 2>&1
  _r9_xcheck zz T2
}

# ---- round 10: findings from the round-9 reviews (compliance-e1-e11-correctness) ----

# G5 r9 #1: after a restart, the SAME reconcile again is a re-run, and the restart's base (not the
# first one) is what binds. Passes logged between the two bases read UNBOUND.
test_rerun_after_a_restart_is_accepted_and_the_restart_base_binds() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m mid
  local mid; mid="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" commit -q --allow-empty -m restart-point
  local b; b="$(git -C "$REPO" rev-parse HEAD)"
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$b" --restart-lineage >/dev/null 2>&1
  run led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$b"
  assert_exit 0 "the same reconcile again, after a restart, is still a re-run"
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$mid" >/dev/null 2>&1
  run led compliance --change c --tier T2
  assert_row "UNBOUND" "G4"
}

# G5 r9 #2: an install commit with no parent that also carries project work: the whole history counts.
test_status_counts_project_work_in_a_root_install_commit() {
  local r="$TMPROOT/rootins.$$"
  rm -rf "$r"; mkdir -p "$r/src/auth" "$r/.pipeline"
  git -C "$r" init -q; git -C "$r" config user.email t@e; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.autocrlf false
  cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$r/.pipeline/"
  cp "$KIT/templates/project/surfaces.conf" "$r/.pipeline/project/surfaces.conf"
  printf 'login\n' > "$r/src/auth/login.js"
  git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm "install kit + auth login" >/dev/null 2>&1
  printf 'x\n' > "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm docs >/dev/null 2>&1
  run bash -c "cd '$r' && bash .pipeline/tools/status.sh"
  assert_contains "install kit + auth login"
  assert_contains "T4"
}

# G5 r9 #3/#4: the reason and the tips of an OLD lineage must not satisfy the current one.
test_compliance_reason_from_an_old_lineage_does_not_count() {
  newrepo
  led route --change c --predicted T3 --actual T3 --round 1 --reason 'the old reason' --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m restart
  led route --change c --predicted T3 --actual T3 --round 1 --base "$(git -C "$REPO" rev-parse HEAD)" --restart-lineage >/dev/null 2>&1
  local g
  for g in G1 G2 G3 G4 G5 G6 G7 G8; do
    led add --change c --gate $g --tier T3 --round 1 --outcome pass --confidence fresh --model m >/dev/null 2>&1
  done
  run led compliance --change c --tier T3
  assert_contains "no reason recorded"
}

test_compliance_tip_from_an_old_lineage_does_not_bind_a_new_pass() {
  newrepo
  local tr; tr="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" commit -q --allow-empty -m new-base
  local nb; nb="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b sib
  git -C "$REPO" commit -q --allow-empty -m on-sibling
  local s2; s2="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$tr"
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" --commit "$s2" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$nb" --restart-lineage >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$s2" >/dev/null 2>&1
  run led compliance --change c --tier T2
  assert_row "UNBOUND" "G4"
}

# G5 r9 #5 / G6 r9 #1: the bundled-install labels and the earlier-commits count.
test_status_labels_a_bundled_install_commit_and_counts_earlier_history() {
  local r="$TMPROOT/bundled2.$$"
  rm -rf "$r"; mkdir -p "$r/src/auth"
  git -C "$r" init -q; git -C "$r" config user.email t@e; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.autocrlf false
  printf 'readme\n' > "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm first >/dev/null 2>&1
  mkdir -p "$r/.pipeline"; cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$r/.pipeline/"
  cp "$KIT/templates/project/surfaces.conf" "$r/.pipeline/project/surfaces.conf"
  printf 'login\n' > "$r/src/auth/login.js"
  git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm "install kit + auth login" >/dev/null 2>&1
  printf 'more\n' >> "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm docs >/dev/null 2>&1
  run bash -c "cd '$r' && bash .pipeline/tools/status.sh"
  assert_contains "since just before the kit was installed"
  assert_contains "1 earlier commit(s) predate the install"
  # an explicit BASELINE is the user's cutoff, not the install commit: the label must not claim it
  local first; first="$(git -C "$r" rev-list --max-parents=0 HEAD)"
  run bash -c "cd '$r' && BASELINE='$first' bash .pipeline/tools/status.sh"
  assert_not_contains "carries project work"
  assert_not_contains "kit was installed"
  assert_contains "your cutoff"
}

# G6 r9 #2: the kit-prefix test is anchored; src/x.pipeline/ is not the kit.
test_coverage_baseline_prefix_match_is_anchored() {
  local r="$TMPROOT/anch.$$"
  rm -rf "$r"; mkdir -p "$r/src/x.pipeline" "$r/.pipeline"
  git -C "$r" init -q; git -C "$r" config user.email t@e; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.autocrlf false
  printf 'r\n' > "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm c1 >/dev/null 2>&1
  local c1; c1="$(git -C "$r" rev-parse HEAD)"
  cp -r "$KIT/tools" "$r/.pipeline/"; printf 'x\n' > "$r/src/x.pipeline/auth.js"
  git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm "install + sneaky path" >/dev/null 2>&1
  assert_eq "$c1" "$(cd "$r" && . "$KIT/tools/lib/coverage.sh" && coverage_baseline "$r/.pipeline")" "a project path that merely contains .pipeline/ is project work"
}

# G6 r9 #3 / G1 r9: explicit bad values are refused, not defaulted.
test_compliance_refuses_a_non_numeric_round() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 3x
  assert_exit 2 "an explicit bad --round is refused, not silently replaced with 1"
}

test_ledger_add_refuses_round_zero() {
  newrepo
  run led add --change c --gate G1 --tier T1 --round 0 --outcome pass --confidence fresh --model m
  assert_exit 2
  assert_contains "rounds start at 1"
}

# G7/G4 r9: the change name is matched exactly for gate rows too (a.b must not pick up aXb).
test_gate_rows_match_the_change_name_exactly() {
  newrepo
  led route --change a.b --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  local g
  for g in G4 G5 G6 G8; do
    led add --change aXb --gate $g --tier T2 --round 1 --outcome pass --confidence fresh --model m >/dev/null 2>&1
  done
  run led compliance --change a.b --tier T2
  assert_row "NOT RUN" "G4"
}

# G5 r9 #10: ordinary text that starts with dashes is a value in compliance and reconcile too.
test_compliance_and_reconcile_accept_option_looking_text_with_spaces() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led compliance --change "--odd name" --tier T2
  assert_not_contains "needs a value"
  run rec T4 --ledger "--odd path"
  assert_not_contains "needs a value"
}

# G6 round 5: fail CLOSED when git cannot diff (the remote's commit is not in this clone).
test_hook_blocks_when_the_remote_commit_is_not_in_this_clone() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "T4 change, no report" >/dev/null 2>&1
  run hook_stdin refs/heads/master "$(git -C "$REPO" rev-parse HEAD)" refs/heads/master "1111111111111111111111111111111111111111"
  assert_exit 1 "an unknown remote sha must block, not read as 'nothing changed'"
  assert_contains "cannot compare"
  assert_contains "git fetch"
}

# G8 round 5: a missing option value crashed with 'unbound variable' and exit 1, which README
# defines as UNDER-CLASSIFIED -- a typo read as a routing verdict.
test_reconcile_option_without_a_value_is_refused_with_exit_2() {
  newrepo
  run rec T4 --round
  assert_exit 2 "usage errors are exit 2"
  assert_contains "needs a value"
}

# --------------------------------------------------- pre-push: stdin protocol / first push
#
# `hook()` above always sets BASE explicitly, which exercises the override
# path only. These feed the hook the same stdin git itself sends a real
# pre-push hook -- "<local ref> <local sha> <remote ref> <remote sha>" -- one
# line per ref, to exercise the path a real `git push` actually takes.
ZERO_SHA="0000000000000000000000000000000000000000"
hook_stdin() {
  local local_ref="$1" local_sha="$2" remote_ref="$3" remote_sha="$4"
  ( cd "$REPO" && printf '%s %s %s %s\n' "$local_ref" "$local_sha" "$remote_ref" "$remote_sha" \
      | sh .pipeline/templates/pre-push )
}

# The bug: a brand-new repo's first-ever push has no origin/* ref to diff
# against, and the old code fell back to a local main/master -- which, on
# this exact push, IS the branch being pushed, so BASE...HEAD compared a
# branch to itself and was always empty. newrepo()'s base commit already
# carries a tracked T4 file (src/auth/existing.js), so a first push of it
# must be caught, not waved through.
test_hook_catches_a_trust_boundary_on_a_repos_first_push() {
  newrepo
  run hook_stdin "refs/heads/master" "$BASE_SHA" "refs/heads/master" "$ZERO_SHA"
  assert_exit 1 "first push of a repo must not exit 0 unchecked"
  assert_contains "BLOCKED"
  assert_contains "src/auth/existing.js"
}

# Branch deletion (local sha all zero): nothing was pushed, nothing to check.
test_hook_stdin_is_a_noop_on_a_branch_deletion() {
  newrepo
  run hook_stdin "refs/heads/gone" "$ZERO_SHA" "refs/heads/gone" "$BASE_SHA"
  assert_exit 0
}

# A normal, non-first push: remote sha is real, so the diff is scoped to what
# actually moved since it, same as the BASE-override path already covers --
# this just confirms the stdin branch of the same logic reaches the same
# verdict.
test_hook_stdin_normal_push_diffs_from_the_remote_sha() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  local new_sha; new_sha="$(git -C "$REPO" rev-parse HEAD)"
  run hook_stdin "refs/heads/master" "$new_sha" "refs/heads/master" "$BASE_SHA"
  assert_exit 1
  assert_contains "src/auth/existing.js"
}

# A new branch (remote sha zero) with an origin/main ref already present must
# diff from the merge-base with it, not from the empty tree -- otherwise
# every file already on trunk looks newly added on every feature branch's
# first push, and the T4 file this fixture ships in the BASE commit would
# block a push that never touched it.
test_hook_new_branch_diffs_from_merge_base_with_origin_not_empty_tree() {
  newrepo
  git -C "$REPO" update-ref refs/remotes/origin/main "$BASE_SHA"
  printf 'note\n' > "$REPO/docs-note.txt"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "unrelated" >/dev/null 2>&1
  local new_sha; new_sha="$(git -C "$REPO" rev-parse HEAD)"
  run hook_stdin "refs/heads/feature" "$new_sha" "refs/heads/feature" "$ZERO_SHA"
  assert_exit 0 "a new branch's first push must diff from the merge-base with origin, not from nothing"
}

# Same setup, but the new branch's own new commit is what touches the T4
# file -- confirms the merge-base diff still catches a real hit, not just
# stays quiet.
test_hook_new_branch_still_catches_a_trust_boundary_added_on_the_branch() {
  newrepo
  git -C "$REPO" update-ref refs/remotes/origin/main "$BASE_SHA"
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "touches auth" >/dev/null 2>&1
  local new_sha; new_sha="$(git -C "$REPO" rev-parse HEAD)"
  run hook_stdin "refs/heads/feature" "$new_sha" "refs/heads/feature" "$ZERO_SHA"
  assert_exit 1
  assert_contains "src/auth/existing.js"
}

test_install_hook_refuses_an_empty_surfaces_file() {
  newrepo
  : > "$REPO/.pipeline/project/surfaces.conf"
  run bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh"
  assert_exit 2
  assert_contains "no T4 rows"
  [ -f "$REPO/.git/hooks/pre-push" ] && _fail "installed a hook that guards nothing" || _ok
}

test_install_hook_installs_and_reports_what_it_guards() {
  newrepo
  run bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh"
  assert_exit 0
  assert_contains "Installed"
  assert_contains "Trust boundary"
  [ -f "$REPO/.git/hooks/pre-push" ] && _ok || _fail "no hook at .git/hooks/pre-push"
}

# Found by a fresh-context G4 Ripple review, and the most consequential finding
# of that round: the installed hook is a COPY, so a fix to templates/pre-push
# reaches nobody who already installed. install-hook.sh actively refuses to
# replace it, and status.sh reported "[x] pre-push hook installed" for a copy
# that was 102 lines against the template's 204 — missing an entire feature.
# Every part of that chain reported success.
# Found by a fresh-context G8 Dogfood run (round 3) that actually followed the
# README's step 1, byte for byte: `cp -r gated-change/ your-project/.pipeline/`
# copies the kit's OWN development-repo artifacts too, and the documented
# cleanup line only removed .git/ledger.jsonl/dashboard.html/security-reports/
# project -- SESSION-HANDOFF.md, INTENT-LOG.md, LEARNINGS.md, dist/ (with a
# real encrypted release tarball inside), releases/, tests/, experiments/,
# .claude/ and .github/ all still landed in every fresh install. Executes the
# actual documented command against a scratch copy -- never $KIT itself -- so
# this is the real recipe, not a paraphrase of it.
test_readme_cleanup_removes_the_kits_own_dev_artifacts_too() {
  local scratch; scratch="$(mktemp -d "$TMPROOT/readme-cleanup.XXXXXX")"
  mkdir -p "$scratch/your-project"
  cp -r "$KIT" "$scratch/your-project/.pipeline"
  # The command is read OUT OF THE README, not restated here: a copy in this test passed
  # whether or not the README named a file (E9 shipped ACTION-PLAN.md into installs).
  local rmcmd
  rmcmd="$(awk '/^rm -rf \.git/{f=1} f{print} f&&/\.github[[:space:]]*$/{exit}' "$KIT/README.md")"
  [ -n "$rmcmd" ] && _ok || _fail "could not find the README's cleanup command"
  ( cd "$scratch/your-project/.pipeline" || exit 1
    eval "$rmcmd" )
  for leaked in .git ledger.jsonl dashboard.html security-reports project \
      SESSION-HANDOFF.md INTENT-LOG.md LEARNINGS.md ACTION-PLAN.md dist releases tests experiments docs \
      plugin .claude-plugin .claude .github; do
    [ -e "$scratch/your-project/.pipeline/$leaked" ] \
      && _fail "$leaked survived the README's own cleanup command" || _ok
  done
  # Portable kit content must still be there -- this is a cleanup, not a wipe.
  [ -d "$scratch/your-project/.pipeline/core" ] && _ok || _fail "cleanup deleted core/, which the README never asked for"
  [ -f "$scratch/your-project/.pipeline/CHANGELOG.md" ] && _ok \
    || _fail "CHANGELOG.md should survive -- it travels with a real install (tools/update-kit.sh treats it as portable), not a leak"
}

# The Claude Code plugin installs a COPY of plugin/. plugin/kit/ is generated from the
# kit's own sources by tools/build-plugin.sh; a stale copy would ship an old kit under a
# new version number, and a copy that carried this repo's own ledger or tests would hand
# every user the project's history. Builds into a scratch directory and compares.
test_plugin_kit_copy_matches_the_sources_and_leaks_nothing() {
  local out; out="$(mktemp -d "$TMPROOT/plugin-build.XXXXXX")"
  cp -R "$KIT/plugin/.claude-plugin" "$out/" 2>/dev/null
  bash "$KIT/tools/build-plugin.sh" "$out" >/dev/null 2>&1 && _ok || _fail "build-plugin.sh failed"
  if diff -r --strip-trailing-cr "$out/kit" "$KIT/plugin/kit" >/dev/null 2>&1; then _ok
  else _fail "plugin/kit/ is stale against the sources: run bash tools/build-plugin.sh"; fi
  local leaked
  for leaked in ledger.jsonl dashboard.html security-reports project tests experiments specs docs       plugin .claude-plugin .claude .github .git SESSION-HANDOFF.md INTENT-LOG.md LEARNINGS.md       ACTION-PLAN.md dist; do
    [ -e "$KIT/plugin/kit/$leaked" ] && _fail "$leaked is inside plugin/kit/" || _ok
  done
  [ -z "$(find "$KIT/plugin" -name .gitattributes -type f 2>/dev/null)" ] && _ok \
    || _fail "a .gitattributes is inside plugin/ (the directory rejects it)"
  [ -f "$KIT/plugin/LICENSE" ] && [ -f "$KIT/plugin/NOTICE" ] && _ok     || _fail "the plugin root lacks LICENSE or NOTICE"
  [ -f "$KIT/plugin/kit/tools/status.sh" ] && [ -f "$KIT/plugin/kit/core/01-router.md" ] && _ok     || _fail "plugin/kit/ is missing the kit's tools or core"
  grep -q '"name": "gated-change"' "$KIT/plugin/.claude-plugin/plugin.json" && _ok     || _fail "plugin.json does not name the plugin gated-change"
  grep -q '"source": "./plugin"' "$KIT/.claude-plugin/marketplace.json" && _ok     || _fail "marketplace.json does not point at ./plugin"
  # Every skill is a folder with a SKILL.md that has a name and a description.
  local f
  for f in "$KIT"/plugin/skills/*/SKILL.md; do
    grep -q '^name: ' "$f" && grep -q '^description: ' "$f" && _ok || _fail "$f lacks name/description"
  done
}

# Found by a fresh-context G8 Dogfood run that simply followed the README top to
# bottom — the only way it could be found, since everyone who already knew the
# kit had a working install. `cp -r gated-change/ .pipeline/` carries the kit's
# own SELF-marked config, its ledger and its security reports, so the adopter's
# very first status.sh reported the KIT's newest gate run as their project's.
test_status_warns_when_an_install_carried_the_kits_own_records() {
  newrepo
  # newrepo installs the shipped EXAMPLE config; put the kit's own SELF-marked
  # file there instead, which is what a plain cp -r produces.
  cp "$KIT/project/surfaces.conf" "$REPO/.pipeline/project/surfaces.conf"
  run status_run
  assert_contains "CARRYING THE KIT'S OWN RECORDS"
}

# The same guard must stay silent on a correct install, or it is noise that
# teaches people to ignore the banner.
test_status_is_silent_about_self_records_on_a_correct_install() {
  newrepo
  run status_run
  assert_not_contains "CARRYING THE KIT'S OWN RECORDS"
}

test_status_reports_a_differing_installed_hook_rather_than_a_green_tick() {
  newrepo
  bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh" >/dev/null 2>&1
  run status_run
  assert_contains "[x] pre-push hook installed"
  # Case matters: the banner reads "DIFFERS from templates/pre-push". Asserting
  # the lower-case form here made this check vacuous — it passed against output
  # that did contain the warning, which is the same class of always-true
  # assertion the suite exists to avoid.
  assert_not_contains "DIFFERS from templates/pre-push"

  # Simulate the real situation: an installed hook that no longer matches the
  # shipped template byte-for-byte — could be an older kit's copy, could be
  # someone's own edit. This check cannot and must not claim to know which.
  printf '#!/bin/sh\n# an older version\nexit 0\n' > "$REPO/.git/hooks/pre-push"
  run status_run
  assert_contains "DIFFERS from templates/pre-push"
  assert_contains "install-hook.sh --force"
}

# The banner used to assert "OUT OF DATE" as fact and lead straight into
# --force -- which is exactly the command that destroys a hook someone
# deliberately customized, the case install-hook.sh's own refusal message
# ("someone put it there on purpose") already exists to protect. Locks in
# that the banner now admits it cannot tell the two cases apart, rather than
# only hedging in a parenthetical while the headline still claimed certainty.
test_status_hook_diff_banner_does_not_assert_definite_staleness() {
  newrepo
  bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh" >/dev/null 2>&1
  printf '#!/bin/sh\n# hand-customized on purpose\nexit 0\n' > "$REPO/.git/hooks/pre-push"
  run status_run
  assert_not_contains "OUT OF DATE"
  assert_contains "cannot tell which"
}

test_install_hook_force_replaces_a_stale_copy() {
  newrepo
  printf '#!/bin/sh\n# an older version\nexit 0\n' > "$REPO/.git/hooks/pre-push"
  run bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh --force"
  assert_exit 0
  assert_file_contains "$REPO/.git/hooks/pre-push" "Dashboard auto-regeneration"
}

# B3: the installed hook has its PIPELINE_DIR rewritten to the kit's prefix, so comparing the TEMPLATE with it said
# "a different hook exists" on every re-run for a kit that is not at .pipeline/ (this repo runs the hook on itself).
# The self-hosting fixture carries only tools/ and core/; the installer also needs the pre-push template and a surfaces file.
_selfhost_install_ready() {
  selfhostrepo
  cp -r "$KIT/templates" "$SELFREPO/templates"
  mkdir -p "$SELFREPO/project"; cp "$KIT/project/surfaces.conf" "$SELFREPO/project/surfaces.conf"
}

test_install_hook_is_idempotent_for_a_kit_that_is_not_at_dot_pipeline() {
  _selfhost_install_ready
  run bash -c "cd '$SELFREPO' && bash tools/install-hook.sh"
  assert_exit 0
  assert_contains "Installed"
  assert_file_contains "$SELFREPO/.git/hooks/pre-push" 'PIPELINE_DIR="${PIPELINE_DIR:-.}"'
  run bash -c "cd '$SELFREPO' && bash tools/install-hook.sh"
  assert_exit 0 "a re-run of the same install is not a conflict"
  assert_contains "Already installed and identical"
}

test_install_hook_is_idempotent_at_the_default_prefix_too() {
  newrepo
  bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh" >/dev/null 2>&1
  run bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh"
  assert_exit 0
  assert_contains "Already installed and identical"
}

test_install_hook_still_refuses_a_hook_that_really_differs_at_a_custom_prefix() {
  _selfhost_install_ready
  bash -c "cd '$SELFREPO' && bash tools/install-hook.sh" >/dev/null 2>&1
  printf '\n# local edit\n' >> "$SELFREPO/.git/hooks/pre-push"
  run bash -c "cd '$SELFREPO' && bash tools/install-hook.sh"
  assert_exit 2
  assert_contains "Refusing to overwrite"
}

test_install_hook_does_not_clobber_an_existing_hook() {
  newrepo
  mkdir -p "$REPO/.git/hooks"
  printf '#!/bin/sh\necho mine\n' > "$REPO/.git/hooks/pre-push"
  run bash -c "cd '$REPO' && bash .pipeline/tools/install-hook.sh"
  assert_exit 2
  assert_contains "Refusing to overwrite"
  assert_file_contains "$REPO/.git/hooks/pre-push" "echo mine"
}

# ---------------------------------------------------------------- pre-push: dashboard auto-regen
#
# dashboard.sh writes a snapshot that nothing regenerates on its own (see its
# own header). The pre-push hook is the one mechanism in the kit that already
# fires on every push with no memory dependency, so it now carries the regen
# too. `ledger` is itself a T4 surface in the shipped example surfaces.conf
# ((quota|limits?|ledger)) that newrepo() installs, so every fixture below
# satisfies the trust-boundary check first with a same-sha report — these
# tests are about the block that runs AFTER it, not a retest of it.
_report_current_head() {
  mkdir -p "$REPO/.pipeline/security-reports"
  git -C "$REPO" rev-parse HEAD > "$REPO/.pipeline/security-reports/g7.md"
}

test_hook_regenerates_and_commits_dashboard_when_ledger_present() {
  newrepo
  printf '{"type":"gate","date":"2026-08-14","change":"c1","tier":"T1","gate":"G1","round":1,"commit":"aaa1111","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$REPO/.pipeline/ledger.jsonl"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "add ledger" >/dev/null 2>&1
  _report_current_head
  run hook
  assert_exit 0
  [ -f "$REPO/.pipeline/dashboard.html" ] && _ok || _fail "dashboard.html was not generated"
  git -C "$REPO" log -1 --format=%s | grep -q "auto: regenerate dashboard.html" \
    && _ok || _fail "no auto-commit landed on top of the push"
  # Found by a fresh-context G8 Dogfood run (round 3): this commit lands too
  # late to ship in the push that triggered it (git already computed what
  # that push sends), which surprised a real user into a redundant `git push`
  # with no explanation on screen. The hook must say so, not leave it silent.
  assert_contains "Push once more to sync it"
}

# The real bug this guards against: dashboard.sh bakes a fresh "generated"
# timestamp AND a "kitCommit" (== the enclosing repo's own HEAD, for a kit
# with no separate .git under it — the normal install) into every run. A
# raw diff on either field looks like a change forever, including against
# the auto-commit's OWN dashboard.html, which would auto-commit again on
# every subsequent push without end. Caught by hand before this test
# existed (see LEARNINGS.md) — this is the regression lock for it.
test_hook_dashboard_regen_is_a_noop_once_settled() {
  newrepo
  printf '{"type":"gate","date":"2026-08-14","change":"c1","tier":"T1","gate":"G1","round":1,"commit":"aaa1111","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$REPO/.pipeline/ledger.jsonl"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "add ledger" >/dev/null 2>&1
  _report_current_head
  run hook
  assert_exit 0

  # A second push needs SOMETHING new to push (the hook's own early return
  # on an empty diff would otherwise make this a trivial pass) but nothing
  # that should make the DASHBOARD look stale — an unrelated, non-T4 file.
  printf 'note\n' > "$REPO/docs-note.txt"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "unrelated" >/dev/null 2>&1
  local before_second; before_second="$(git -C "$REPO" rev-parse HEAD)"
  _report_current_head
  run hook
  assert_exit 0
  local after_second; after_second="$(git -C "$REPO" rev-parse HEAD)"
  [ "$after_second" = "$before_second" ] \
    && _ok || _fail "hook committed a dashboard regen though the ledger hadn't moved since it was last generated"
}

test_hook_warns_but_does_not_block_when_dashboard_sh_fails() {
  newrepo
  printf '{"type":"gate","date":"2026-08-14","change":"c1","tier":"T1","gate":"G1","round":1,"commit":"aaa1111","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$REPO/.pipeline/ledger.jsonl"
  # A malformed card is a documented dashboard.sh failure mode (exit 1, "a
  # card is malformed" — see its own header) — cheap to trigger without
  # reaching into any other tool's internals.
  echo "not yaml, no closing fence" > "$REPO/.pipeline/core/cards/G1-intent.md"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "add ledger, break a card" >/dev/null 2>&1
  _report_current_head
  run hook
  assert_exit 0 "a dashboard.sh failure must not block the push it rode in on"
  assert_contains "WARNING"
  assert_contains "dashboard.sh failed to regenerate"
}

# ---------------------------------------------------------------- claude-hook (R0c)
#
# core/01-router.md's R0c: any edit to a T3/T4 surface, made after Triage has
# already run, re-enters the pipeline for that edit. tools/hooks/r0c-post-edit.sh
# is what makes that mechanical on Claude Code — a PostToolUse hook, not a git
# hook, so these feed it the same JSON payload Claude Code would put on stdin,
# rather than diffing a working tree the way `hook()` above does.
# The repo path as Claude Code would send it on Windows: drive-letter form where cygpath exists, every separator a
# backslash, each backslash doubled for the JSON string.
_r0c_json_backslashed() {
  local p="$1"
  command -v cygpath >/dev/null 2>&1 && p="$(cygpath -m "$p")"
  printf '%s' "${p//\//\\\\}"
}

r0c_hook() {
  local tool="$1" file="$2"
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool" "$file" \
    | ( cd "$REPO" && bash .pipeline/tools/hooks/r0c-post-edit.sh )
}

test_r0c_hook_reminds_on_a_t4_edit() {
  newrepo
  run r0c_hook Edit "$REPO/src/auth/existing.js"
  assert_exit 2
  assert_contains "R0c"
  assert_contains "src/auth/existing.js"
  assert_contains "T4"
  assert_contains "Trust boundary"
}

test_r0c_hook_reminds_on_a_t3_edit() {
  newrepo
  mkdir -p "$REPO/src/shared"
  run r0c_hook Write "$REPO/src/shared/util.js"
  assert_exit 2
  assert_contains "T3"
  assert_contains "Shared module"
}

# Found by a fresh-context G6 Peer run. Claude Code sends `file_path` as a JSON
# string, so on Windows it arrives backslash-separated AND backslash-escaped
# (`D:\\repo\\tools\\ledger.sh`). Every surfaces.conf rule is `/`-anchored
# (`(^|/)tools/...`), so nothing matched and the hook exited 0 — the R0c
# enforcement point silently dead on Git Bash for Windows, which
# project/surfaces.conf names as this kit's primary TARGET. Invisible to the
# suite because every other fixture here builds `/`-separated paths, the same
# blind spot that hid the coverage path-form bug one round earlier.
test_r0c_hook_fires_on_a_windows_form_path() {
  newrepo
  local out code win
  win="$(_r0c_json_backslashed "$REPO")\\\\src\\\\auth\\\\existing.js"
  out="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$win" \
    | ( cd "$REPO" && bash .pipeline/tools/hooks/r0c-post-edit.sh ) 2>&1)"; code=$?
  LAST_OUT="$out"; LAST_EXIT=$code
  assert_exit 2 "a JSON-escaped Windows path must trip R0c, not pass silently"
  assert_contains "R0c"
}

# The path is a JSON string value, so a literal backslash in it is escaped. It
# must not be treated as a path separator after unescaping either.
test_r0c_hook_still_ignores_a_windows_path_outside_any_rule() {
  newrepo
  local out code win
  win="$(_r0c_json_backslashed "$REPO")\\\\src\\\\theme.css"
  out="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$win" \
    | ( cd "$REPO" && bash .pipeline/tools/hooks/r0c-post-edit.sh ) 2>&1)"; code=$?
  LAST_OUT="$out"; LAST_EXIT=$code
  assert_exit 0 "a Windows path matching no T3/T4 rule must stay silent"
}

# B2: the payload path is absolute, the rules are repo-relative. A file outside THIS repository must not trip a rule
# just because its absolute path contains `tools/hooks/` or `core/`, and a repository that lives under a directory
# called core/ must not have every file read as T4.
test_r0c_hook_ignores_a_file_outside_the_repository_even_if_its_path_looks_guarded() {
  newrepo
  local outside; outside="$(mktemp -d "$TMPROOT/outside.XXXXXX")"
  mkdir -p "$outside/src/auth" "$outside/core"
  : > "$outside/src/auth/x.js"; : > "$outside/core/y.js"
  run r0c_hook Edit "$outside/src/auth/x.js"
  assert_exit 0 "a file in another project's auth/ is not this repository's surface"
  run r0c_hook Edit "$outside/core/y.js"
  assert_exit 0 "nor is another project's core/"
  # ...while the same shapes INSIDE the repository still fire
  run r0c_hook Edit "$REPO/src/auth/existing.js"
  assert_exit 2
}

test_r0c_hook_matches_relative_to_the_repo_root_not_to_where_the_repo_lives() {
  newrepo
  # a repository checked out beneath a directory literally named core/ (a T4 rule in the shipped template)
  local base; base="$(mktemp -d "$TMPROOT/host.XXXXXX")"; mkdir -p "$base/core"
  cp -r "$REPO" "$base/core/proj"
  local saved="$REPO"; REPO="$base/core/proj"
  run r0c_hook Edit "$REPO/src/theme.css"
  assert_exit 0 "src/theme.css is T1; the core/ above the repository must not make it T4"
  run r0c_hook Edit "$REPO/src/auth/existing.js"
  assert_exit 2
  REPO="$saved"
}

test_r0c_hook_handles_a_new_file_in_a_directory_that_does_not_exist_yet() {
  newrepo
  run r0c_hook Write "$REPO/src/auth/brand/new/dir/token.js"
  assert_exit 2 "a Write may create its directories; membership is found by walking up"
  assert_contains "src/auth/brand/new/dir/token.js"
}

test_r0c_hook_is_silent_on_a_t1_or_t2_edit() {
  newrepo
  run r0c_hook Edit "$REPO/src/theme.css"
  assert_exit 0
  assert_eq "" "$LAST_OUT" "hook output for a non-T3/T4 edit"
}

test_r0c_hook_ignores_tools_other_than_edit_write_multiedit() {
  newrepo
  run r0c_hook Read "$REPO/src/auth/existing.js"
  assert_exit 0
  assert_eq "" "$LAST_OUT" "a Read of a T4 file must not trip the reminder"
}

# MultiEdit is included on purpose (see the hook's own header): it is an Edit
# in every way that matters here, and excluding it would leave exactly the
# memory-dependent gap R0c exists to close for anyone who reaches for it
# instead of Edit.
test_r0c_hook_multiedit_is_covered() {
  newrepo
  run r0c_hook MultiEdit "$REPO/src/auth/existing.js"
  assert_exit 2
  assert_contains "R0c"
}

# The pre-push hook fails CLOSED with no surfaces file (test_hook_refuses_to_
# run_with_no_rules, above) because it is the last mechanical check before
# code leaves the machine. This one is a mid-session reminder with no such
# role, so it fails OPEN instead — a repo that has not answered surfaces.conf's
# questions yet should not have every edit blocked on that basis.
test_r0c_hook_fails_open_with_no_surfaces_file() {
  newrepo
  rm -f "$REPO/.pipeline/project/surfaces.conf"
  run r0c_hook Edit "$REPO/src/auth/existing.js"
  assert_exit 0 "a missing surfaces file must not block a mid-session reminder"
}

# One row at a time, first match wins, so the message can name the row that
# actually fired — a `blocking` finding with no location is refused in
# 04-ledger.md for the same reason: a reminder that cannot say what it is
# about trains people to skim past it.
test_r0c_hook_names_the_specific_matched_row_not_a_generic_message() {
  newrepo
  run r0c_hook Edit "$REPO/src/auth/existing.js"
  assert_contains "Trust boundary"
  assert_not_contains "Quota accounting"
}

claude_settings_path() { printf '%s/.claude/settings.json' "$REPO"; }
install_claude_hook() { ( cd "$REPO" && bash .pipeline/tools/install-claude-hook.sh ); }

test_install_claude_hook_fresh_install_writes_valid_settings_json() {
  newrepo
  run install_claude_hook
  assert_exit 0
  assert_contains "Installed into"
  local settings; settings="$(claude_settings_path)"
  [ -f "$settings" ] || { _fail "no settings.json written at $settings"; return; }
  assert_file_contains "$settings" ".pipeline/tools/hooks/r0c-post-edit.sh"
  assert_file_contains "$settings" "PostToolUse"
  [ -n "$PY" ] || { _skip "no python — cannot validate settings.json is well-formed"; return; }
  run "$PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$settings"
  assert_exit 0 "settings.json written by the installer is not valid JSON"
}

test_install_claude_hook_is_idempotent() {
  newrepo
  [ -n "$PY" ] || { _skip "no python — the merge path this exercises needs it"; return; }
  run install_claude_hook
  assert_exit 0
  run install_claude_hook
  assert_exit 0
  assert_contains "Already installed"
  local settings n
  settings="$(claude_settings_path)"
  n=$(grep -o "r0c-post-edit.sh" "$settings" | wc -l | tr -d ' ')
  assert_eq "1" "$n" "the hook command must appear exactly once after two installs"
}

test_install_claude_hook_preserves_existing_settings_content() {
  newrepo
  [ -n "$PY" ] || { _skip "no python — the merge path this exercises needs it"; return; }
  mkdir -p "$REPO/.claude"
  cat > "$REPO/.claude/settings.json" <<'JSONEOF'
{
  "permissions": {"allow": ["Bash(git status)"]},
  "hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hi"}]}]}
}
JSONEOF
  run install_claude_hook
  assert_exit 0
  local settings; settings="$(claude_settings_path)"
  assert_file_contains "$settings" "Bash(git status)"
  assert_file_contains "$settings" "echo hi"
  assert_file_contains "$settings" "r0c-post-edit.sh"
}

test_install_claude_hook_refuses_on_corrupted_settings_json() {
  newrepo
  [ -n "$PY" ] || { _skip "no python — this refusal path only triggers once python is found"; return; }
  mkdir -p "$REPO/.claude"
  printf '{ not json' > "$REPO/.claude/settings.json"
  run install_claude_hook
  assert_exit 2
  assert_contains "Could not merge"
  assert_file_contains "$(claude_settings_path)" "{ not json"
}

test_install_claude_hook_refuses_with_no_t3_t4_rows() {
  newrepo
  printf 'T1::(^|/)README\\.md$::docs\n' > "$REPO/.pipeline/project/surfaces.conf"
  run install_claude_hook
  assert_exit 2
  assert_contains "no T3 or T4 rows"
}

# Same "refuse to hand-edit JSON that isn't mine" path a missing python takes
# — proven by actually hiding python from PATH, not by reading the code and
# assuming the branch works. The printed fallback snippet has to be valid
# JSON on its own: a user is meant to paste it straight into settings.json.
test_install_claude_hook_refuses_and_prints_a_valid_snippet_without_python() {
  newrepo
  local gitdir bashdir
  # Hide python by building a PATH that contains ONLY git and bash, rather than
  # by trusting their parent directories to be python-free.
  #
  # The first version used `dirname $(command -v git)`:`dirname $(command -v bash)`,
  # which is a Git-Bash-on-Windows assumption: there those live in a directory
  # without python. On Linux both resolve to /usr/bin, which also holds python3 —
  # so the installer took its python merge path, exited 0 instead of 2, and this
  # test failed. Found by a fresh-context G4 Ripple run that executed the suite on
  # Ubuntu rather than reasoning about it, and it would have turned the new CI
  # workflow red on its very first run.
  # A shim holding a FORWARDING SCRIPT, not a copied or symlinked binary.
  #
  # Two earlier attempts each worked on exactly one platform. Rebuilding PATH
  # from the parent directories of git and bash is a Git-Bash assumption (on
  # Linux both are /usr/bin, which holds python3, so nothing was hidden).
  # Copying/symlinking the binaries into a shim then failed on Windows with exit
  # 127, because a copied bash.exe cannot find its DLLs. A `#!/bin/sh` wrapper
  # that execs the real git needs neither symlink support nor a private DLL set,
  # and bash is invoked by ABSOLUTE path ($BASH_BIN, resolved once at the top of
  # this file for exactly this reason) so it does not need to be on PATH at all.
  local shim; shim="$(mktemp -d "$TMPROOT/nopy.XXXXXX")"
  local _c _p
  # Everything install-claude-hook.sh actually invokes, and nothing else — the
  # point is a PATH that is complete except for python. Enumerated from the
  # script rather than guessed; if it grows a dependency this test skips loudly
  # (the git probe below) instead of passing for the wrong reason.
  for _c in git dirname grep mkdir sed awk; do
    _p="$(command -v "$_c" 2>/dev/null)" || continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$_p" > "$shim/$_c"
    chmod +x "$shim/$_c"
  done

  # Prove the shim really does hide python, and that git still works through it
  # — otherwise a 127 masquerades as the refusal this test is asserting.
  if env -i PATH="$shim" "$BASH_BIN" -c 'command -v python3 || command -v python' >/dev/null 2>&1; then
    _skip "could not build a python-free PATH on this platform"; return
  fi
  if ! env -i PATH="$shim" "$BASH_BIN" -c 'git --version' >/dev/null 2>&1; then
    _skip "git does not work through the shim on this platform"; return
  fi

  LAST_OUT="$(cd "$REPO" && env -i PATH="$shim" HOME="${HOME:-}" "$BASH_BIN" .pipeline/tools/install-claude-hook.sh 2>&1)"
  LAST_EXIT=$?
  assert_exit 2
  assert_contains "No python3/python found"
  assert_contains "PostToolUse"
  [ -n "$PY" ] || { _skip "no python to validate the printed snippet with"; return; }
  local snippet; snippet="$(printf '%s\n' "$LAST_OUT" | sed -n '/^  {/p' | head -1)"
  [ -n "$snippet" ] || { _fail "no snippet line found in fallback output"; return; }
  run "$PY" -c "import json,sys; json.loads(sys.argv[1])" "$snippet"
  assert_exit 0 "the manual-merge snippet printed without python must itself be valid JSON"
}

# ---------------------------------------------------------------- status (coverage)
#
# Every other read command needs the answer before it will answer: `compliance
# --change <name> --tier T4`. status.sh is the zero-argument entry point, and
# the only thing in the kit that compares the ledger against git history — so
# the failure that matters most is a confident "all clear" over real unrouted
# work. Exit codes are load-bearing: 0 clean, 1 unrouted T3/T4, 2 cannot tell.
status_run() { ( cd "$REPO" && bash .pipeline/tools/status.sh "$@" ); }

# Write a gate record naming a real commit in the fixture, so the "since the
# last gated commit" anchor resolves.
_ledger_gate_at() {
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' \
    "$(git -C "$REPO" rev-parse --short HEAD)" >> "$(ledger_path)"
}

test_status_reports_unrouted_t4_work_when_nothing_was_ever_gated() {
  newrepo   # base commit carries src/auth/existing.js — T4 in the example conf
  # Work landed AFTER the install is what "unrouted" counts when nothing was ever gated (E10).
  printf 'token=9
' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "post-install T4 edit" >/dev/null 2>&1
  run status_run
  assert_exit 1 "unrouted T4 work must not report success"
  assert_contains "UNROUTED WORK"
  assert_contains "T4"
  assert_contains "no gated commit to anchor to"
}

# E10: history from before the kit was installed is not "unrouted work" -- the kit never had
# the chance to route it. Right after install, status must be clean, not exit 1.
test_status_ignores_pre_install_history_when_nothing_was_ever_gated() {
  newrepo   # the T4 file is in the SAME commit that installs the kit
  run status_run
  assert_exit 0 "pre-install history must not count as unrouted"
  assert_contains "since the kit was installed"
  BASELINE=none run status_run
  assert_exit 1 "BASELINE=none restores whole-history counting"
}

# coverage_baseline (E10): every branch, not just the committed-kit path (G5/G6 round 1).
_cov_baseline() { ( cd "$REPO" && . "$KIT/tools/lib/coverage.sh" && coverage_baseline "$1" ); }

test_coverage_baseline_is_the_install_commit_when_the_kit_is_committed() {
  newrepo
  assert_eq "$BASE_SHA" "$(_cov_baseline "$REPO/.pipeline")" "the commit that added the kit"
}

test_coverage_baseline_pins_head_when_the_kit_is_not_committed_yet() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "kit not tracked" >/dev/null 2>&1
  local at_install; at_install="$(git -C "$REPO" rev-parse HEAD)"
  assert_eq "$at_install" "$(_cov_baseline "$REPO/.pipeline")" "nothing is since-install until it is committed"
  # G6 round 2: this used to return the CURRENT head every time, so the range was HEAD..HEAD
  # forever and later work was never counted. It must stay where the install was.
  git -C "$REPO" commit -q --allow-empty -m "work after install"
  assert_eq "$at_install" "$(_cov_baseline "$REPO/.pipeline")" "the cutoff stays pinned"
}

test_status_counts_work_committed_after_an_uncommitted_install() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "kit not tracked" >/dev/null 2>&1
  run status_run
  assert_exit 0 "right after install, nothing is unrouted"
  printf 'token=9\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add src/auth/existing.js >/dev/null 2>&1; git -C "$REPO" commit -qm "T4 work after install" >/dev/null 2>&1
  run status_run
  assert_exit 1 "work committed after the install must be counted, not swallowed by a moving cutoff"
}

test_coverage_baseline_is_empty_when_the_kit_is_git_ignored() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  printf '.pipeline/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore >/dev/null 2>&1; git -C "$REPO" commit -qm "ignore the kit" >/dev/null 2>&1
  assert_eq "" "$(_cov_baseline "$REPO/.pipeline")" "an ignored kit is never committed: HEAD would hide everything forever"
}

test_coverage_baseline_is_empty_when_the_kit_is_the_repo() {
  newrepo
  assert_eq "" "$(_cov_baseline "$REPO")" "the kit's own development repo keeps whole-history counting"
}

test_coverage_baseline_honours_an_explicit_ref() {
  newrepo
  git -C "$REPO" commit -q --allow-empty -m "later"
  local later; later="$(git -C "$REPO" rev-parse HEAD)"
  assert_eq "$later" "$(cd "$REPO" && BASELINE=HEAD . "$KIT/tools/lib/coverage.sh" && BASELINE=HEAD coverage_baseline "$REPO/.pipeline")" "BASELINE=<ref>"
}

# Rounds 20/21: a pin that is not a usable commit is NEVER rewritten with HEAD (the range HEAD..HEAD made every
# unrouted commit vanish). Counting the whole history is the direction that cannot hide work. The pin is
# written only when the file is ABSENT (round 23: an empty one is not re-pinned either).
test_coverage_baseline_never_replaces_a_corrupt_or_stale_pin_with_head() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "kit not tracked" >/dev/null 2>&1
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  printf 'not-a-sha\n' > "$REPO/.pipeline/.install-base"
  assert_eq "" "$(_cov_baseline "$REPO/.pipeline")" "a corrupt pin counts everything"
  assert_eq "not-a-sha" "$(tr -d ' \t\r\n' < "$REPO/.pipeline/.install-base")" "and is left alone"
  printf '%s\n' "1111111111111111111111111111111111111111" > "$REPO/.pipeline/.install-base"
  assert_eq "" "$(_cov_baseline "$REPO/.pipeline")" "a pin that is no longer a commit counts everything"
  : > "$REPO/.pipeline/.install-base"
  assert_eq "" "$(_cov_baseline "$REPO/.pipeline")" "an empty pin counts everything too"
  assert_eq "0" "$(wc -c < "$REPO/.pipeline/.install-base" | tr -d ' ')" "and stays empty"
  rm -f "$REPO/.pipeline/.install-base"
  assert_eq "$head" "$(_cov_baseline "$REPO/.pipeline")" "an absent pin is written"
  assert_eq "$head" "$(tr -d ' \t\r\n' < "$REPO/.pipeline/.install-base")" "with the current HEAD"
}

# G4 r22 blocking: a pin that cannot be written (here a directory) returned the CURRENT HEAD on every call, so the
# cutoff moved with every commit and unrouted work vanished.
test_coverage_baseline_gives_no_cutoff_when_the_pin_cannot_be_written() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "kit not tracked" >/dev/null 2>&1
  mkdir "$REPO/.pipeline/.install-base"
  assert_eq "" "$(_cov_baseline "$REPO/.pipeline")" "a directory in the pin's place gives no cutoff"
  git -C "$REPO" commit -q --allow-empty -m "later work"
  assert_eq "" "$(_cov_baseline "$REPO/.pipeline")" "and does not follow HEAD"
}

# G4 r22: the whole-history label never said why, or how to get out.
test_status_names_an_unusable_pin_and_the_way_out() {
  newrepo
  git -C "$REPO" rm -rq --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "kit not tracked" >/dev/null 2>&1
  printf 'not-a-sha\n' > "$REPO/.pipeline/.install-base"
  run status_run
  assert_contains "delete that file to pin again"
}

# Round 25 (G7/G4 round 24): ONE resolver (tools/lib/commit.sh) is the only way a stored commit string reaches
# git. Unit tests of the resolver itself, then each consumer that was found calling git with the raw string.
_resolve() { ( cd "$REPO" && . "$KIT/tools/lib/commit.sh" && resolve_commit "$1" ); }

test_resolve_commit_never_goes_through_a_ref_name() {
  newrepo
  local c0 c1; c0="$BASE_SHA"; git -C "$REPO" commit -q --allow-empty -m one; c1="$(git -C "$REPO" rev-parse HEAD)"
  assert_eq "$c0" "$(_resolve "${c0:0:7}")" "an abbreviation resolves to its commit"
  git -C "$REPO" tag "${c0:0:7}" "$c1"
  assert_eq "$c0" "$(_resolve "${c0:0:7}")" "a tag named like it does not redirect it"
  git -C "$REPO" branch "${c0}0" "$c1"
  assert_eq "" "$(_resolve "${c0}0")" "41 hex characters is not an object name (it would be read as a ref)"
  assert_eq "" "$(_resolve "${c0:0:3}")" "fewer than 4 characters is refused"
  assert_eq "" "$(_resolve "ABCDEF1")" "upper case is refused"
  git -C "$REPO" tag -a -m t annotated "$c0"
  assert_eq "$c0" "$(_resolve "$(git -C "$REPO" rev-parse annotated)")" "a full annotated-tag object id is peeled to its commit"
  assert_eq "" "$(_resolve "$(git -C "$REPO" rev-parse "$c0^{tree}")")" "a tree is not a commit"
}

# G7/G4 r24 blocking: the route's stored commit (a short sha) is a TIP; a tag named like it, pointing at a commit
# on another branch, moved the upper bound and an UNBOUND pass read PASS.
test_a_tag_named_like_a_route_short_sha_does_not_move_the_upper_bound() {
  newrepo
  git -C "$REPO" checkout -q -b side
  git -C "$REPO" commit -q --allow-empty -m "side work"
  local p; p="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -
  git -C "$REPO" commit -q --allow-empty -m "main work"
  local m; m="$(git -C "$REPO" rev-parse HEAD)"
  led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "${p:0:7}" >/dev/null 2>&1
  run led compliance --change x --tier T2
  assert_contains "UNBOUND"
  git -C "$REPO" tag "${m:0:7}" "$p"
  run led compliance --change x --tier T2
  assert_contains "UNBOUND"
}

# G4 r24: 41 hex characters were treated as an already-full sha and resolved as a ref.
test_a_base_of_more_than_a_full_sha_is_refused() {
  newrepo
  git -C "$REPO" branch "${BASE_SHA}0" "$BASE_SHA"
  run led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "${BASE_SHA}0"
  assert_exit 2 "a 41-hex base is not a commit"
  assert_not_file_contains "$(ledger_path)" "${BASE_SHA}0"
}

# G4 r24: an annotated-tag object id given as --base was stored unpeeled, so the commit's own sha later read as
# a different base.
test_a_tag_object_id_given_as_base_is_stored_as_its_commit() {
  newrepo
  git -C "$REPO" tag -a -m t v1 "$BASE_SHA"
  local tagsha; tagsha="$(git -C "$REPO" rev-parse v1)"
  run led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$tagsha"
  assert_exit 0 "accepted"
  assert_eq "1" "$(grep -c "\"base\":\"$BASE_SHA\"" "$(ledger_path)")" "the commit, not the tag object, is stored"
  run led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA"
  assert_exit 0 "the commit's own sha is the same base"
}

# G4 r24: status labels resolved the raw ledger string with ref-first rev-parse and disagreed with the anchor.
test_status_label_is_not_redirected_by_a_tag_named_like_the_gate_commit() {
  newrepo
  # Written by hand: `ledger.sh add` now refuses a commit that is not in the repository (round 26).
  printf '{"type":"gate","date":"2026-08-14","change":"x","tier":"T2","gate":"G4","round":1,"commit":"deadbee","outcome":"pass","findings":0,"note":"n"}\n' >> "$(ledger_path)"
  git -C "$REPO" tag deadbee HEAD
  run status_run
  assert_contains "not found in this repo"
}

# G4 r23: the line that writes the pin must give up (no cutoff) when the write fails, never print the current HEAD.
# A write failure cannot be provoked portably (chmod does nothing on Windows), so the guard is pinned in source:
# if it became `|| true` followed by a printf of HEAD, the moving cutoff of G6 round 2 would be back.
test_coverage_baseline_pin_write_failure_gives_no_cutoff_in_source() {
  assert_file_contains "$KIT/tools/lib/coverage.sh" '{ printf '"'"'%s\n'"'"' "$_cb_head" > "$_cb_pin"; } 2>/dev/null || return 0'
}

# G4 r23: a pin that is a link is neither read nor written (a link to a loose ref reads as the current HEAD).
test_coverage_baseline_does_not_read_a_pin_that_is_a_link_in_source() {
  assert_file_contains "$KIT/tools/lib/coverage.sh" '[ -L "$_cb_pin" ] && return 0'
}

# G7 r23 blocking: dash's echo interprets backslash escapes and `\c` stops all output, so `echo "$CHANGED"` cut the
# changed-file list at a file named 0\c and switched the trust check off. bash -O xpg_echo makes bash's echo
# behave the same way, so the hook is run that way here.
test_hook_is_not_switched_off_by_a_file_name_with_a_backslash_c_under_an_escaping_echo() {
  newrepo
  local blob t1 t2 c1 c2
  blob="$(printf 'k\n' | git -C "$REPO" hash-object -w --stdin)"
  t1="$(printf '100644 blob %s\tauth.js\n' "$blob" | git -C "$REPO" mktree)"
  t2="$(printf '100644 blob %s\t0\\c\n100644 blob %s\tauth.js\n' "$blob" "$blob" | git -C "$REPO" mktree)"
  c1="$(git -C "$REPO" commit-tree "$t1" -m c1)"
  c2="$(git -C "$REPO" commit-tree "$t2" -p "$c1" -m c2)"
  LAST_OUT="$( cd "$REPO" && printf 'refs/heads/x %s refs/heads/x %s\n' "$c2" "$ZERO_SHA" \
      | TRUST='(^|/)auth\.js$' PIPELINE_DIR=/nonexistent REPORTS=/nonexistent bash -O xpg_echo .pipeline/templates/pre-push origin u 2>&1 )"; LAST_EXIT=$?
  assert_exit 1 "a trust file in the push still blocks when another name contains \\c"
  assert_contains "BLOCKED"
}

# G7 r23 blocking: git resolves REF NAMES before abbreviated object names, so a tag or branch named like a stored
# short sha redirected the E3 binding (UNBOUND became PASS) and the coverage anchor. Resolution is among objects.
test_a_tag_named_like_a_short_sha_does_not_redirect_the_binding() {
  newrepo
  git -C "$REPO" commit -q --allow-empty -m "work"
  local old short; old="$(git -C "$REPO" rev-parse "$BASE_SHA^")"; short="${old:0:7}"
  led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$short" >/dev/null 2>&1
  run led compliance --change x --tier T2
  assert_contains "UNBOUND"
  git -C "$REPO" tag "$short" HEAD
  run led compliance --change x --tier T2
  assert_contains "UNBOUND"
}

test_a_tag_named_like_a_short_sha_does_not_redirect_the_coverage_anchor() {
  newrepo
  git -C "$REPO" commit -q --allow-empty -m "a"
  local a short; a="$(git -C "$REPO" rev-parse HEAD)"; short="${a:0:7}"
  git -C "$REPO" commit -q --allow-empty -m "b"
  git -C "$REPO" commit -q --allow-empty -m "c"
  led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$short" >/dev/null 2>&1
  git -C "$REPO" tag "$short" HEAD
  # The anchor is printed as the raw ledger string either way; what the tag redirected was the range
  # built from it (HEAD ^<full sha>), so that is what is asserted.
  local out; out="$( cd "$REPO" && . "$REPO/.pipeline/tools/lib/coverage.sh" \
      && coverage_range "$(coverage_anchor "$(ledger_path)")" 2>/dev/null )"
  assert_eq "HEAD ^$a" "$out" "the range excludes the gated commit, not whatever the tag points at"
}

# Round 26 (G7 r25 blocking): the default base is named by FULL ref, so a tag called like the default branch
# (`git tag master HEAD`, which beats the short name) cannot move it to HEAD.
test_a_tag_named_like_the_default_branch_does_not_move_the_reconcile_base() {
  newrepo
  local br; br="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" checkout -q -b work
  printf 'token=2\n' > "$REPO/src/auth/new.js"
  git -C "$REPO" add src/auth/new.js >/dev/null 2>&1
  git -C "$REPO" commit -qm "auth work" >/dev/null 2>&1
  # The tag shares the default branch's name and points at HEAD: `master` alone would mean HEAD (no diff).
  git -C "$REPO" tag "$br" HEAD 2>/dev/null
  LAST_OUT="$( cd "$REPO" && env -u BASE bash .pipeline/tools/reconcile.sh T1 2>&1 )"; LAST_EXIT=$?
  assert_contains "src/auth/new.js"
}

test_the_pre_push_default_base_is_a_full_ref_in_source() {
  assert_file_contains "$KIT/templates/pre-push" 'refs/remotes/origin/main'
  assert_not_file_contains "$KIT/templates/pre-push" 'rev-parse --verify -q origin/main'
  assert_not_file_contains "$KIT/tools/reconcile.sh" 'rev-parse --verify -q origin/main'
}

# Round 29 (G7 r28 blocking): `rev-parse --verify refs/remotes/origin/main` is NOT an exact-ref check. With
# that ref missing, git's name search finds a TAG called `refs/remotes/origin/main` (a plain `git fetch`
# delivers one) and the tag chose the base: the hook dropped the trust commits from the pushed range and
# reconcile tiered a T4 change T0. The default base is now checked with `show-ref --verify` and handed to
# git as the object id.
test_a_tag_named_like_the_remote_default_branch_does_not_become_the_reconcile_base() {
  newrepo
  git -C "$REPO" checkout -q -b work
  printf 'token=2\n' > "$REPO/src/auth/new.js"
  git -C "$REPO" add src/auth/new.js >/dev/null 2>&1
  git -C "$REPO" commit -qm "auth work" >/dev/null 2>&1
  # No origin/HEAD, no refs/remotes/origin/main: only a tag with that full name, at HEAD (an empty diff).
  git -C "$REPO" tag refs/remotes/origin/main HEAD
  LAST_OUT="$( cd "$REPO" && env -u BASE bash .pipeline/tools/reconcile.sh T1 2>&1 )"; LAST_EXIT=$?
  assert_contains "src/auth/new.js"
  assert_not_contains "No changes against"
}

test_a_tag_named_like_a_dangling_origin_head_target_is_refused_by_reconcile() {
  newrepo
  git -C "$REPO" checkout -q -b work
  printf 'token=2\n' > "$REPO/src/auth/new.js"
  git -C "$REPO" add src/auth/new.js >/dev/null 2>&1
  git -C "$REPO" commit -qm "auth work" >/dev/null 2>&1
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  git -C "$REPO" tag refs/remotes/origin/trunk HEAD
  LAST_OUT="$( cd "$REPO" && env -u BASE bash .pipeline/tools/reconcile.sh T1 2>&1 )"; LAST_EXIT=$?
  assert_exit 2 "a dangling origin/HEAD must refuse, not let a tag stand in for the missing ref"
  assert_contains "Cannot compare"
}

test_a_tag_named_like_the_remote_default_branch_does_not_become_the_hook_base() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  local new_sha; new_sha="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" tag refs/remotes/origin/main "$new_sha"
  run hook_stdin "refs/heads/feature" "$new_sha" "refs/heads/feature" "$ZERO_SHA"
  assert_exit 1 "the tag must not empty the pushed range"
  assert_contains "BLOCKED"
}

test_a_tag_named_like_a_dangling_origin_head_target_does_not_become_the_hook_base() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  local new_sha; new_sha="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  git -C "$REPO" tag refs/remotes/origin/trunk "$new_sha"
  run hook_stdin "refs/heads/feature" "$new_sha" "refs/heads/feature" "$ZERO_SHA"
  assert_exit 1 "a dangling origin/HEAD target must not be answered by a tag"
  assert_contains "BLOCKED"
}

# The exact ref still works (a real remote-tracking branch is the base), so the fix did not turn the hook
# into one that checks everything on every push.
test_the_hook_still_uses_an_exact_remote_tracking_ref_as_the_base() {
  newrepo
  git -C "$REPO" update-ref refs/remotes/origin/main "$BASE_SHA"
  printf 'note\n' > "$REPO/docs-note.txt"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "unrelated" >/dev/null 2>&1
  local new_sha; new_sha="$(git -C "$REPO" rev-parse HEAD)"
  run hook_stdin "refs/heads/feature" "$new_sha" "refs/heads/feature" "$ZERO_SHA"
  assert_exit 0 "an exact origin/main is still the base"
}

test_the_default_base_checks_use_show_ref_in_source() {
  assert_file_contains "$KIT/templates/pre-push" 'show-ref --verify'
  assert_file_contains "$KIT/tools/reconcile.sh" 'show-ref --verify'
  assert_not_file_contains "$KIT/templates/pre-push" 'rev-parse --verify -q refs/remotes'
  assert_not_file_contains "$KIT/tools/reconcile.sh" 'rev-parse --verify -q refs/remotes'
  assert_not_file_contains "$KIT/tools/reconcile.sh" 'rev-parse --verify -q refs/heads'
}

# G7 r28 minor: the stored change name is JSON-escaped, the search key was not, so a name with a backslash
# skipped the "defaulted assumption" refusal.
test_a_defaulted_assumption_on_a_change_name_with_a_backslash_is_still_refused() {
  newrepo
  led assume --change 'auth\fix' --assumed x --resolution defaulted --basis c >/dev/null 2>&1
  run led compliance --change 'auth\fix' --tier T4
  assert_contains "UNCONFIRMED"
}

# Round 29 (G4 r28 blocking): json_escape left every control byte except tab, CR and LF raw. A pasted ESC
# (coloured test output) made a line that grep-based consumers read and JSON.parse rejected, so compliance
# said FAIL where the dashboard said pass. Every byte below 0x20 is now escaped, and text is untouched.
test_a_control_byte_in_a_finding_is_escaped_so_the_line_is_valid_json() {
  newrepo
  run led add --change x --gate G7 --tier T4 --round 1 --outcome fail --confidence fresh --model m \
      --finding "$(printf 'blocking::src/auth/x.js:1::out \033[31mFAILED\033[0m bell\007 caf\303\251')"
  assert_exit 0
  assert_jsonl_valid "$(ledger_path)"
  assert_eq "2" "$(grep -o '\\u001b' "$(ledger_path)" | wc -l | tr -d ' ')" "both ESC bytes are escaped"
  assert_eq "1" "$(grep -c '\\u0007' "$(ledger_path)")" "the bell byte is escaped"
  assert_eq "1" "$(grep -c 'caf.*FAILED\|FAILED.*caf' "$(ledger_path)")" "plain text is kept"
  assert_eq "1" "$(grep -c 'café' "$(ledger_path)")" "multi-byte text is not touched"
}

# Round 29 (G4 r28 blocking): a ledger whose last line has no trailing newline (a truncated write, a hand-
# resolved merge) had the next record glued onto it; consumers rank by line, so a FAIL behind a PASS on one
# physical line never counted as "after" it and compliance exited 0 over a logged failure.
test_ledger_add_after_a_missing_final_newline_starts_a_new_line_and_the_fail_counts() {
  newrepo
  local p; p="$(ledger_path)"
  led add --change x --gate G7 --tier T4 --round 1 --outcome pass --confidence fresh --model m >/dev/null 2>&1
  printf '%s' "$(cat "$p")" > "$p.tmp" && mv "$p.tmp" "$p"
  assert_eq "1" "$([ -n "$(tail -c 1 "$p")" ] && echo 1 || echo 0)" "(setup) the file ends without a newline"
  run led add --change x --gate G7 --tier T4 --round 1 --outcome fail --confidence fresh --model m \
      --finding "blocking::src/auth/x.js:1::bad"
  assert_exit 0
  assert_contains "did not end in a newline"
  assert_jsonl_valid "$p"
  assert_eq "0" "$(grep -c '"outcome":"pass".*"outcome":"fail"' "$p")" "the two records are not on one line"
  run led compliance --change x --tier T4
  assert_re "FAIL[[:space:]]+G7"
}

# G4 r25 blocking: a commit edited in tools/lib/commit.sh or tools/check-refs.sh reconciled T0.
test_commit_resolver_and_check_refs_are_routed_surfaces() {
  assert_file_contains "$KIT/project/surfaces.conf" 'tools/lib/commit\.sh$'
  assert_file_contains "$KIT/project/surfaces.conf" 'tools/check-refs\.sh$'
}

# G4 r25: BASELINE goes through the resolver when it is hex.
test_a_tag_named_like_a_hex_baseline_does_not_redirect_the_cutoff() {
  newrepo
  git -C "$REPO" commit -q --allow-empty -m a
  local a; a="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" commit -q --allow-empty -m b
  git -C "$REPO" tag "${a:0:7}" HEAD
  local out; out="$( cd "$REPO" && BASELINE="${a:0:7}" && . "$REPO/.pipeline/tools/lib/coverage.sh" \
      && coverage_baseline "$REPO/.pipeline" 2>/dev/null )"
  assert_eq "$a" "$out" "the commit object, not the tag"
}

# G4 r25: a hex string that is not one commit is refused when logging a gate, and the full sha is stored.
test_ledger_add_refuses_a_commit_that_is_not_a_commit_and_stores_the_full_sha() {
  newrepo
  local tree; tree="$(git -C "$REPO" rev-parse "$BASE_SHA^{tree}")"
  run led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$tree"
  assert_exit 2 "a tree id is not a commit"
  run led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "${BASE_SHA:0:3}"
  assert_exit 2 "three characters are not a commit"
  run led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "${BASE_SHA}0"
  assert_exit 2 "41 characters are not a commit"
  run led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "${BASE_SHA:0:7}"
  assert_exit 0 "an abbreviation is accepted"
  assert_eq "1" "$(grep -c "\"commit\":\"$BASE_SHA\"" "$(ledger_path)")" "and stored in full"
  run led add --change y --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m
  assert_eq "1" "$(grep -c "\"change\":\"y\".*\"commit\":\"$(git -C "$REPO" rev-parse HEAD)\"" "$(ledger_path)")" "detect_commit stores the full sha"
}

# G4 r25: two commits sharing a stored prefix is ambiguous = the resolver exits 2 and the pass reads UNBOUND.
test_resolve_commit_reports_an_ambiguous_prefix_with_status_two() {
  newrepo
  local i p tree
  tree="$(git -C "$REPO" rev-parse "HEAD^{tree}")"
  # Unreferenced commit objects are enough (--disambiguate reads objects). 1200 of them share a
  # 4-character prefix with probability ~1 (birthday bound over 65536 prefixes); retry in batches.
  p=""
  for i in $(seq 1 1200); do git -C "$REPO" commit-tree "$tree" -m "c$i"; done > "$TMPROOT/ids.$$"
  p="$(cut -c1-4 "$TMPROOT/ids.$$" | sort | uniq -d | head -1)"
  rm -f "$TMPROOT/ids.$$"
  [ -n "$p" ] || { echo "no 4-character collision found"; return 1; }
  ( cd "$REPO" && . "$KIT/tools/lib/commit.sh" && resolve_commit "$p" >/dev/null ); local rc=$?
  assert_eq "2" "$rc" "ambiguous is 2, not 1"
  # ...and a pass logged at that ambiguous prefix reads UNBOUND, not "cannot be checked" (a quiet pass).
  led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  _fake_commit "$p" --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m
  run led compliance --change x --tier T2
  assert_contains "UNBOUND"
}

# G4 r25: a missing lib/commit.sh failed OPEN (every gate PASS, rc 0). Loud exit 2 now.
test_a_missing_commit_library_stops_ledger_check_refs_and_coverage() {
  newrepo
  mv "$REPO/.pipeline/tools/lib/commit.sh" "$REPO/.pipeline/tools/lib/commit.sh.off"
  run led compliance --change x --tier T2
  assert_exit 2 "ledger.sh"
  assert_contains "commit.sh"
  run status_run
  assert_exit 2 "status.sh"
  LAST_OUT="$( cd "$REPO" && bash .pipeline/tools/check-refs.sh --help 2>&1 )"; LAST_EXIT=$?
  assert_exit 2 "check-refs.sh"
}

# G4 r26 blocking: in a repository with no commit yet (G1 is logged before the first one) the default
# --commit was the word HEAD, which the hex check refused. Nothing is recorded instead.
test_ledger_add_route_assume_work_in_a_repository_with_no_commit_yet() {
  local e; e="$(mktemp -d "$TMPROOT/unborn.XXXXXX")"
  git -C "$e" init -q
  local l="$e/l.jsonl" t="$KIT/tools/ledger.sh"
  run bash -c "cd '$e' && bash '$t' --ledger '$l' add --change x --tier T1 --gate G1 --outcome pass --confidence fresh --model m --note why"
  assert_exit 0 "add"
  run bash -c "cd '$e' && bash '$t' --ledger '$l' route --change x --predicted T1 --actual T1 --round 1 --reason r"
  assert_exit 0 "route"
  run bash -c "cd '$e' && bash '$t' --ledger '$l' assume --change x --assumed a --resolution asked --basis b"
  assert_exit 0 "assume"
  assert_eq "3" "$(grep -c '"commit":""' "$l")" "all three rows record no commit"
}

# Round 27 (G7 r26 blocking): git quotes a non-ASCII path ("src/auth/na\303\257ve.js") and the anchored
# T4 rule never matched it: reconcile tiered T0, status said nothing was unrouted.
test_a_non_ascii_file_name_is_still_tiered_by_reconcile_and_status() {
  newrepo
  # The fixture's own rule is not anchored, so a leading quote does not hide the path from it; this one is.
  printf 'T4::(^|/)src/auth/::auth\n' > "$REPO/.pipeline/project/surfaces.conf"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "anchored rule" >/dev/null 2>&1
  BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
  printf 'token=1\n' > "$REPO/src/auth/na$(printf '\303\257')ve.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "auth with a non-ASCII name" >/dev/null 2>&1
  run rec T1
  assert_exit 1 "a T4 file with a non-ASCII name must still raise the tier"
  run status_run
  assert_exit 1 "and still count as unrouted"
  assert_contains "UNROUTED WORK"
}

# G7 r26 blocking: with no merge base `git diff BASE...HEAD` fails with nothing on stdout, which read as
# "no committed changes" and reconcile said "Reconciled".
test_reconcile_refuses_when_the_base_shares_no_history_with_head() {
  newrepo
  git -C "$REPO" checkout -q --orphan orph >/dev/null 2>&1
  git -C "$REPO" commit -qm "orphan" --allow-empty >/dev/null 2>&1
  printf 'docs\n' > "$REPO/notes.txt"
  run rec T1
  assert_exit 2 "an unrelated base is not a pass"
  assert_contains "Cannot compare against"
  run bash -c "cd '$REPO' && BASE=mian-no-such-ref bash .pipeline/tools/reconcile.sh T1"
  assert_exit 2 "a mistyped BASE is not a pass either"
}

# Round 28 (G7/G4 r27 minor): with a guessed base (no main/master/origin) and ONE commit there is no HEAD~1,
# and that commit's own files were never tiered.
test_a_repository_with_one_commit_and_a_guessed_base_tiers_that_commit() {
  newrepo
  local old; old="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" checkout -q --orphan trunk >/dev/null 2>&1
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "only commit" >/dev/null 2>&1
  git -C "$REPO" branch -D "$old" >/dev/null 2>&1
  printf 'x\n' >> "$REPO/README.md"
  LAST_OUT="$( cd "$REPO" && env -u BASE bash .pipeline/tools/reconcile.sh T1 2>&1 )"; LAST_EXIT=$?
  assert_exit 1 "src/auth/existing.js is in the only commit: T4, predicted T1"
}

# G4 r27: from a subdirectory `git ls-files --others` listed only that directory's files, relative to it.
test_reconcile_from_a_subdirectory_still_sees_untracked_files_elsewhere() {
  newrepo
  printf 'token=1\n' > "$REPO/src/auth/fresh.js"
  LAST_OUT="$( cd "$REPO/src/components" && BASE="$BASE_SHA" bash ../../.pipeline/tools/reconcile.sh T1 2>&1 )"; LAST_EXIT=$?
  assert_exit 1 "an untracked T4 file outside the working directory still raises the tier"
  assert_contains "src/auth/fresh.js"
}

# G7 r27: `for f in $TARGETS` split on spaces; a note called "my notes.md" was never checked.
test_check_refs_dir_checks_a_note_whose_name_has_a_space() {
  newrepo
  mkdir -p "$REPO/notes"
  printf 'See `src/does/not/exist.ts` now.\n' > "$REPO/notes/my notes.md"
  LAST_OUT="$( cd "$REPO" && bash .pipeline/tools/check-refs.sh --dir notes 2>&1 )"; LAST_EXIT=$?
  assert_exit 1 "a stale claim in a note with a space in its name is a mismatch"
}

# G4 r26 minor: route and assume resolved nothing; an explicit empty --commit slipped through add.
test_route_and_assume_store_the_full_sha_and_refuse_a_non_commit() {
  newrepo
  run led route --change x --predicted T2 --actual T2 --round 1 --reason r --commit abc
  assert_exit 2 "route: 3 hex characters"
  run led assume --change x --assumed a --resolution asked --basis b --commit 123
  assert_exit 2 "assume: 3 hex characters"
  run led route --change x --predicted T2 --actual T2 --round 1 --reason r --commit "${BASE_SHA:0:7}"
  assert_exit 0 "route: an abbreviation"
  assert_eq "1" "$(grep -c "\"type\":\"route\".*\"commit\":\"$BASE_SHA\"" "$(ledger_path)")" "stored in full"
  run led assume --change x --assumed a --resolution asked --basis b --commit "${BASE_SHA:0:7}"
  assert_exit 0 "assume: an abbreviation"
  assert_eq "1" "$(grep -c "\"type\":\"assumption\".*\"commit\":\"$BASE_SHA\"" "$(ledger_path)")" "stored in full"
}

test_an_explicit_empty_commit_is_refused_in_a_repository_with_a_commit() {
  newrepo
  run led add --change c --tier T2 --gate G4 --outcome pass --confidence fresh --model m --commit ""
  assert_exit 2 "an explicit empty --commit is the door to a PASS with a note"
  assert_contains "Omit --commit"
}

# G4 r26 minor: the object-format cache lived and died in command substitutions, so status.sh never
# benefited. It is loaded when the file is sourced, and an inherited value is not trusted.
test_the_object_format_cache_is_loaded_at_source_time_and_not_inherited() {
  newrepo
  local out
  out="$( cd "$REPO" && . "$KIT/tools/lib/commit.sh" && printf "%s" "$_RC_HASHLEN" )"
  assert_eq "40" "$out" "loaded without a single resolve_commit call"
  out="$( cd "$REPO" && _RC_HASHLEN=64 _RC_HASHLEN_KEY="$REPO|" bash -c ". '$KIT/tools/lib/commit.sh'; printf '%s' \"\$_RC_HASHLEN\"" )"
  assert_eq "40" "$out" "an exported value is overwritten when the library is sourced"
}

# G4 r25: an unresolvable legacy base is not "predates --base".
test_an_unresolvable_recorded_base_is_not_called_a_missing_one() {
  newrepo
  printf '{"type":"route","date":"2026-08-14","change":"x","round":1,"predicted":"T2","actual":"T2","commit":"%s","base":"abcdef1","reason":"r"}\n' \
    "$BASE_SHA" >> "$(ledger_path)"
  run led compliance --change x --tier T2
  assert_contains "does not resolve to one commit"
}

# G4 r22: the round-22 change itself had no test: an explicit restart at --round 2/3 on a change with NO route
# is round 1 (a round-3 row let a later plain round-1 route with another base through unrefused).
test_an_explicit_restart_lineage_at_round_three_on_a_change_with_no_route_is_round_one() {
  newrepo
  run led route --change fresh --predicted T2 --actual T2 --round 3 --reason r --base "$BASE_SHA" --restart-lineage
  assert_exit 0 "accepted"
  assert_contains "--round 3 ignored"
  assert_eq "1" "$(grep -c '"round":1,' "$(ledger_path)")" "recorded as round 1"
  assert_eq "0" "$(grep -c '"round":3,' "$(ledger_path)")" "not as round 3"
  git -C "$REPO" commit -q --allow-empty -m other
  local other; other="$(git -C "$REPO" rev-parse HEAD)"
  run led route --change fresh --predicted T2 --actual T2 --round 1 --reason r --base "$other"
  assert_exit 2 "a later round-1 route with another base is refused, as for any change with a round-1 route"
}

test_coverage_baseline_is_empty_for_a_kit_in_another_repo_or_an_invalid_ref() {
  newrepo
  local other; other="$(mktemp -d "$TMPROOT/otherrepo.XXXXXX")"
  git -C "$other" init -q; mkdir -p "$other/.pipeline/tools"; printf 'x\n' > "$other/.pipeline/tools/status.sh"
  git -C "$other" add -A >/dev/null 2>&1
  git -C "$other" -c user.email=t@e -c user.name=t commit -qm k >/dev/null 2>&1
  assert_eq "" "$(_cov_baseline "$other/.pipeline")" "a kit that lives in a different repo has no install commit here"
  assert_eq "" "$(cd "$REPO" && BASELINE=no-such-ref . "$KIT/tools/lib/coverage.sh" && BASELINE=no-such-ref coverage_baseline "$REPO/.pipeline")" "an unresolvable BASELINE ref counts the whole history"
}

# G5 round 3: "N earlier commit(s) predate the install" was never asserted -- the fixture installs
# the kit in the root commit, so the number was always 0.
test_status_reports_how_many_commits_predate_the_install() {
  local d; d="$(mktemp -d "$TMPROOT/preinstall.XXXXXX")"
  git -C "$d" init -q; git -C "$d" config user.email t@e; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false; git -C "$d" config core.autocrlf false
  printf 'a\n' > "$d/a.txt"; git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm "one" >/dev/null 2>&1
  printf 'b\n' > "$d/b.txt"; git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm "two" >/dev/null 2>&1
  cp -r "$_REPO_TEMPLATE/.pipeline" "$d/.pipeline"
  git -C "$d" add -A >/dev/null 2>&1; git -C "$d" commit -qm "install the kit" >/dev/null 2>&1
  REPO="$d"
  run status_run
  assert_contains "2 earlier commit(s) predate the install"
}

test_status_label_keeps_the_missing_commit_note_when_baselined() {
  newrepo
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"deadbee","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$(ledger_path)"
  run status_run
  assert_contains "counted from the kit's install"
  assert_contains "not found in this repo"
  assert_not_contains "0 commit(s) since"
}

test_status_anchors_to_the_last_gated_commit() {
  newrepo
  _ledger_gate_at
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "later T4 edit" >/dev/null 2>&1
  run status_run
  assert_exit 1
  assert_contains "since the last gated commit"
  assert_contains "later T4 edit"
}

# The whole point: work that lands AFTER routing already ran is R0c's concern,
# and is exactly what a ledger reading itself cannot see.
test_status_is_clean_when_the_only_work_since_is_below_t3() {
  newrepo
  _ledger_gate_at
  printf 'body{color:red}\n' > "$REPO/src/theme.css"
  # Explicit pathspec, not `add -A`: the fixture's own ledger.jsonl is dirty at
  # this point and `ledger` is itself a T4 path in the example surfaces.conf, so
  # a blanket add would sweep it in and make this "T1-only" commit genuinely T4.
  git -C "$REPO" add src/theme.css >/dev/null 2>&1
  git -C "$REPO" commit -qm "css only" -- src/theme.css >/dev/null 2>&1
  run status_run
  assert_exit 0 "a T1-only commit mandates no gate"
  assert_contains "Nothing above T2"
}

# "0 commits since" is the best-looking possible output and a lie when the
# anchor does not exist here — a fleet ledger, a squashed history, a short sha
# from another repo. Refusing to anchor must be visible, not silent.
test_status_says_so_when_the_ledger_commit_is_not_in_this_repo() {
  newrepo
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"deadbee","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$(ledger_path)"
  run status_run
  assert_contains "not found in this repo"
  assert_not_contains "0 commit(s) since"
}

# 04-ledger.md: "A gate with no ledger entries did not run." Read from the
# router via matrix.sh, so this cannot drift into a second copy of that list.
test_status_names_gates_that_have_never_run() {
  newrepo
  run status_run
  assert_contains "NEVER RUN"
  assert_contains "G2"
}

test_status_quiet_prints_nothing_but_still_sets_the_exit_code() {
  newrepo
  printf 'token=9
' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "post-install T4 edit" >/dev/null 2>&1
  run status_run --quiet
  assert_exit 1
  assert_eq "" "$LAST_OUT" "--quiet must print nothing at all"
}

test_status_reports_which_enforcement_points_are_missing() {
  newrepo
  run status_run
  assert_contains "pre-push hook NOT installed"
  assert_contains "dashboard.html NOT generated"
}

# IGNORE rows are dropped before tiering, exactly as reconcile.sh does — a
# vendored or generated path must never raise a tier.
test_status_ignored_paths_do_not_raise_the_tier() {
  newrepo
  _ledger_gate_at
  mkdir -p "$REPO/node_modules/pkg"
  printf 'x\n' > "$REPO/node_modules/pkg/index.js"
  # Explicit pathspec for the same reason as the T1-only test above.
  git -C "$REPO" add -f node_modules/pkg/index.js >/dev/null 2>&1
  git -C "$REPO" commit -qm "vendored" -- node_modules/pkg/index.js >/dev/null 2>&1
  run status_run
  assert_exit 0 "an IGNORE-only commit must not count as unrouted work"
}

# The first version measured 61s for 63 commits (a git call plus a grep per
# rule, per commit). The window keeps a first run on a large existing repo
# usable, and truncation is stated rather than quietly narrowing "unrouted".
test_status_states_when_it_truncates_the_scan() {
  newrepo
  printf 'a\n' > "$REPO/src/app.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm second >/dev/null 2>&1
  printf 'b
' > "$REPO/src/app.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm third >/dev/null 2>&1
  LAST_OUT="$(cd "$REPO" && MAX_SCAN=1 bash .pipeline/tools/status.sh 2>&1)"; LAST_EXIT=$?
  assert_contains "tiering the most recent 1"
}

test_status_exits_2_when_it_cannot_tell() {
  newrepo
  rm -f "$REPO/.pipeline/project/surfaces.conf"
  run status_run
  assert_exit 2 "no surfaces file means it cannot tell, which is not the same as clean"
  assert_contains "Refusing to"

  local nonrepo; nonrepo="$(mktemp -d "$TMPROOT/notrepo.XXXXXX")"
  LAST_OUT="$(cd "$nonrepo" && bash "$KIT/tools/status.sh" 2>&1)"; LAST_EXIT=$?
  assert_exit 2 "outside a git repository status cannot be computed"
}

# ---------------------------------------------------------------- add: tier validation
#
# `add` used to only shape-check --tier the same loose way it shape-checks
# --gate ("T", then digits) — reasonable for gate ids, which core/06-extending.md
# deliberately lets a project extend past G8, but tier has no such extension
# point: T0-T4 is a closed set everywhere else in this file reads one. The gap
# let `add --tier T44` write a record that `compliance --tier T44` (below)
# would then refuse to even evaluate — a gate logged at a tier compliance can
# never check, which looks like coverage and is actually a hole.
test_add_refuses_a_tier_that_is_not_a_real_tier() {
  newrepo
  for bad in t4 T44 4 T tier4; do
    run led add --confidence fresh --change c --gate G7 --tier "$bad" --outcome pass
    assert_exit 2 "an unparseable tier ('$bad') must be refused, never silently written"
    assert_contains "REFUSED"
  done
  assert_not_file_contains "$(ledger_path)" '"gate":"G7"'
}

# T0-T4 and empty (tier is optional on add) must keep working — the guard
# above must reject only what compliance would also reject, not narrow the
# real set.
test_add_still_accepts_every_real_tier_and_empty() {
  newrepo
  for good in T0 T1 T2 T3 T4 ""; do
    run led add --confidence fresh --change c --gate G1 --tier "$good" --outcome pass
    assert_exit 0 "a real tier ('$good') must still be accepted"
  done
}

# ---------------------------------------------------------------- add/route/escape/assume: destination on success
#
# chip task_f3521d2e (filed by a G8 Dogfood run): every REFUSED path already names
# $LEDGER, but the success path did not — a misfired `LEDGER=path && ...` (does
# not export; documented in ledger.sh's own header) landed an entry in this
# repo's real ledger.jsonl with no visible sign it had happened, discovered only
# by going looking for it afterward. These pin that the destination is now named
# on the success line too, for every subcommand that writes.
test_add_success_message_names_the_ledger_path() {
  newrepo
  run led add --confidence fresh --change c --gate G1 --tier T1 --outcome pass
  assert_exit 0
  assert_contains "$(ledger_path)"
}

test_route_success_message_names_the_ledger_path() {
  newrepo
  run led route --change r --predicted T1 --actual T1
  assert_exit 0
  assert_contains "$(ledger_path)"
}

test_route_with_action_success_message_names_the_ledger_path() {
  newrepo
  run led route --change r --predicted T4 --actual T4 --action store-publish \
    --evidence "cite"
  assert_exit 0
  assert_contains "$(ledger_path)"
  # Without this the test is indistinguishable from the no-action one above:
  # both assert only the path, so the `[ -n "$action" ]` branch that appends the
  # action to the summary could be deleted and both would still pass (G6 Peer
  # round 2). The path must come AFTER the action, not instead of it.
  assert_contains "action 'store-publish' → $(ledger_path)"
}

test_escape_success_message_names_the_ledger_path() {
  newrepo
  run led escape --change c --found-by user --severity high
  assert_exit 0
  assert_contains "$(ledger_path)"
}

test_assume_success_message_names_the_ledger_path() {
  newrepo
  run led assume --change c --assumed "x" --resolution defaulted
  assert_exit 0
  assert_contains "$(ledger_path)"
}

# ---------------------------------------------------------------- compliance: tier validation
#
# Found by a fresh-context G8 Dogfood run, by typing the tier wrong. `--tier t4`
# and `--tier T44` printed "mandates no gates. Nothing to check." and exited 0,
# where `--tier T4` on the same ungated change exits 1 — one wrong character
# turning the ship/no-ship check green, silently, in the command that decides
# release. `reconcile.sh` has guarded exactly this since an earlier round
# (`case "$PREDICTED" in ''|T0|T1|T2|T3|T4)`); compliance never got the same
# guard, and the asymmetry is what let it survive.
test_compliance_refuses_a_tier_that_is_not_a_real_tier() {
  newrepo
  led add --change c --gate G7 --tier T4 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  # The control: the correctly-spelled tier must still refuse (gates missing).
  run led compliance --change c --tier T4
  assert_exit 1 "control: a real tier with missing gates must refuse"

  for bad in t4 T44 4 T tier4; do
    run led compliance --change c --tier "$bad"
    assert_exit 2 "an unparseable tier ('$bad') must be refused, never silently satisfied"
    assert_not_contains "Nothing to check"
  done
}

# T0 is a REAL tier that genuinely mandates nothing — it must keep working, or
# the guard above has traded one silent wrong answer for another.
test_compliance_still_accepts_t0_which_mandates_nothing() {
  newrepo
  # A ledger must exist — require_ledger runs before cmd_compliance, and a test
  # that fails on a missing ledger proves nothing about tier handling.
  led add --change c --gate G7 --tier T4 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  run led compliance --change c --tier T0
  assert_exit 0
  assert_contains "mandates no gates"
}

# ---------------------------------------------------------------- assumptions
#
# The fourth record type, and the only one about the INPUT rather than the
# output. An agent handed an underspecified request does not stop — it supplies
# a plausible value and every gate below verifies that invention, passing
# honestly while checking the wrong thing. No gate check can see that, because
# it is not a gate failure.
test_assume_records_what_was_never_stated() {
  newrepo
  run led assume --change feat --assumed "users want CSV not XLSX" --resolution defaulted
  assert_exit 0
  assert_contains "defaulted"
  assert_file_contains "$(ledger_path)" '"type":"assumption"'
  assert_file_contains "$(ledger_path)" '"resolution":"defaulted"'
  assert_jsonl_valid "$(ledger_path)"
}

# Three words, the same way the four severities are the whole vocabulary — a
# resolution outside them cannot be counted, so it is refused rather than stored.
test_assume_refuses_a_resolution_outside_the_vocabulary() {
  newrepo
  run led assume --change feat --assumed "x" --resolution probably
  assert_exit 2
  assert_contains "REFUSED"
  assert_not_file_contains "$(ledger_path)" "probably"
}

# 12-grounding.md: "Looks correct" without a citation is indistinguishable from
# not having checked. `verified` with no basis is that sentence in a new hat.
test_assume_refuses_verified_without_a_basis() {
  newrepo
  run led assume --change feat --assumed "x" --resolution verified
  assert_exit 2
  assert_contains "indistinguishable from"
  assert_not_file_contains "$(ledger_path)" '"assumed":"x"'
}

# The point of the whole mechanism: every mandated gate can pass and the change
# still must not ship, because the premise was never agreed to.
test_compliance_refuses_a_t3_change_with_an_unconfirmed_assumption() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change feat --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led assume --change feat --assumed "export format is CSV" --resolution defaulted >/dev/null 2>&1
  run led compliance --change feat --tier T3
  assert_exit 1 "a defaulted assumption must block at T3 even with every gate passing"
  assert_contains "UNCONFIRMED"
  assert_contains "export format is CSV"
}

# junesc (the display-side JSON unescaper unresolved_assumptions() uses) used
# to turn a \n escape into a real newline. Every caller treats its output as
# one record per line -- wc -l counts unresolved assumptions, and a sed pass
# turns each line into one "· " bullet -- so a single --assume record whose
# text itself spanned two lines split into two printed lines, and was counted
# and bulleted as two separate unconfirmed assumptions instead of one.
test_compliance_counts_a_multiline_assumption_once_not_twice() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change feat --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led assume --change feat --assumed "$(printf 'export format is CSV\nnot XLSX')" \
    --resolution defaulted >/dev/null 2>&1
  run led compliance --change feat --tier T3
  assert_contains "1 assumption(s)"
  assert_not_contains "2 assumption(s)"
  local bullets; bullets="$(printf '%s' "$LAST_OUT" | grep -c '    · ')"
  assert_eq "1" "$bullets" "bullet count for one multi-line assumption"
}

# 10-probe.md's own table says to decide yourself when a conventional default
# exists. Refusing every defaulted assumption at every tier would make a T1 typo
# fix ask permission to exist, which is how a rule gets routed around.
test_compliance_does_not_block_below_t3_on_an_assumption() {
  newrepo
  led add --change feat --gate G4 --tier T1 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  led add --change feat --gate G6 --tier T1 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  led assume --change feat --assumed "colour is blue" --resolution defaulted >/dev/null 2>&1
  run led compliance --change feat --tier T1
  assert_not_contains "UNCONFIRMED"
}

# Append-only: the answer is a NEW record, never an edit. The pair is the audit
# trail — you can still see it was once a guess.
test_asking_clears_an_assumption_without_rewriting_history() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change feat --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led assume --change feat --assumed "export format is CSV" --resolution defaulted >/dev/null 2>&1
  led assume --change feat --assumed "export format is CSV" --resolution asked \
    --basis "requester confirmed CSV" >/dev/null 2>&1
  run led compliance --change feat --tier T3
  assert_exit 0 "answering the question must clear the block"
  local n; n=$(grep -c '"type":"assumption"' "$(ledger_path)")
  assert_eq "2" "$n" "both records must survive — the guess is not erased by the answer"
}

# Both found by a fresh-context G6 Peer run. The keying in
# unresolved_assumptions decided whether a T3/T4 change ships, and it could be
# defeated two ways — neither exotic, both producing a FALSE PASS on the exact
# refusal the feature exists to enforce.
#
# 1. The `assumed` text was truncated at the first ESCAPED quote, so two
#    distinct assumptions that quote the requester collapsed to one key.
test_two_quote_bearing_assumptions_do_not_collapse_into_one() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led assume --change c --assumed 'the "widget" size is 10' --resolution defaulted >/dev/null 2>&1
  led assume --change c --assumed 'the "widget" color is red' --resolution defaulted >/dev/null 2>&1
  # Resolve ONLY the first. The second must still block.
  led assume --change c --assumed 'the "widget" size is 10' --resolution asked --basis "confirmed" >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 1 "resolving one quoted assumption must not silently clear a different one"
  assert_contains "color is red"
  # The caller tells you to pass this text back to `assume`. Showing the stored
  # JSON-escaped form (`the \"widget\" color`) would be escaped a second time on
  # the way back in and match nothing, so what is printed must be retypeable.
  assert_not_contains '\"widget\"'
  # And prove the round trip, rather than only that it looks right.
  led assume --change c --assumed 'the "widget" color is red' --resolution asked \
    --basis "confirmed" >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 0 "the text compliance printed must be the text that resolves it"
}

# 2. A TRUNCATED assumption line — no `resolution` field, which is exactly what
#    a killed process or a full disk leaves on an append-only file — masked a
#    genuine `defaulted` record, because the unmatched sub() left the whole line
#    as the "resolution" and overwrote the real one.
test_a_truncated_assumption_line_cannot_mask_a_real_refusal() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led assume --change c --assumed "unconfirmed premise" --resolution defaulted >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 1 "control: the refusal must fire before corruption"

  # Truncation at EVERY offset, not just before the field. Round 1 of this fix
  # only handled a line cut before `resolution`, and this test only tested that
  # — so a line cut INSIDE the resolution value still produced a false PASS, and
  # the test passed straight over it. Two independent fresh-context gates found
  # what the test could not. Each offset is checked against a fresh copy.
  local base; base="$(cat "$(ledger_path)")"
  local cut
  for cut in \
    '{"type":"assumption","change":"c","assumed":"unconfirmed premise"' \
    '{"type":"assumption","change":"c","assumed":"unconfirmed premise","resolution' \
    '{"type":"assumption","change":"c","assumed":"unconfirmed premise","resolution":"' \
    '{"type":"assumption","change":"c","assumed":"unconfirmed premise","resolution":"defaulte' \
    '{"type":"assumption","change":"c","assumed":"unconfirmed prem' \
  ; do
    printf '%s\n' "$base" > "$(ledger_path)"
    printf '%s\n' "$cut" >> "$(ledger_path)"
    run led compliance --change c --tier T3
    assert_exit 1 "a line truncated at [${cut##*,}] must never turn a refusal into a pass"
  done

  # And the original record must still be named, not replaced by the corruption.
  printf '%s\n' "$base" > "$(ledger_path)"
  printf '{"type":"assumption","change":"c","assumed":"unconfirmed premise","resolution":"defaulte\n' >> "$(ledger_path)"
  run led compliance --change c --tier T3
  assert_contains "unconfirmed premise"
}

# ---------------------------------------------------------------- recorded reason
#
# gated-change-issue-friendly-reason-not-recorded.md: two experienced passes
# through this exact repo followed the documented Triage -> requirements.md ->
# design.md -> tasks.md -> Build workflow and neither one separately set
# reconcile.sh's REASON= (undiscoverable outside its own header comment) or
# thought to check that G1's --note carried a "why" the dashboard could read
# back later. Every gate could pass and the change still carried no record of
# why it existed. Same shape as the unconfirmed-assumption checks above —
# every gate green, the change still must not ship — so it gets the same
# hard-refuse treatment, at the same T3/T4 boundary.
test_compliance_refuses_a_t3_change_with_no_recorded_reason() {
  newrepo
  # G1 deliberately gets NO --note — the other gates' boilerplate "ok" note is
  # not itself a reason for the CHANGE (see the "note ok" convention used
  # throughout this file), only G1's is, so it is the one field this test
  # must leave empty to exercise "no reason anywhere on record".
  for g in G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led add --change c --gate G1 --tier T3 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 1 "every mandated gate passing must not be enough without a recorded reason"
  assert_contains "REFUSED"
  assert_contains "no reason recorded"
}

# A G1 --note IS a recorded reason (see whyThisRan() in tools/dashboard/app.js,
# which reads the identical field for the identical question) — the gate loop
# above logs G1's outcome with --note "ok", which is a non-empty note, so this
# proves the check reads the right field rather than merely requiring G1 to
# exist as a gate row.
test_compliance_accepts_a_g1_note_as_the_recorded_reason() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m \
      --note "$([ "$g" = G1 ] && echo 'requested by support to stop silent drops' || echo ok)" \
      >/dev/null 2>&1
  done
  run led compliance --change c --tier T3
  assert_exit 0 "a non-empty G1 note is a recorded reason and must clear the check"
}

# A route --reason clears it too, independent of G1 — whyThisRan() checks this
# one FIRST, and compliance must recognise the same field or the two would
# disagree about whether this change's "why" is on record.
test_compliance_accepts_a_route_reason_as_the_recorded_reason() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led route --change c --predicted T3 --actual T3 --reason "Bug fix" >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 0 "a route --reason is a recorded reason and must clear the check"
}

# 10-probe.md's own table: below T3 nothing here demands a reason at all.
# Refusing every T1 typo fix for lacking a REASON= would just teach everyone
# to set a meaningless one to get past the check.
test_compliance_does_not_require_a_reason_below_t3() {
  newrepo
  # T1 mandates NO gates at all (core/01-router.md's matrix) and short-
  # circuits at "Tier T1 mandates no gates. Nothing to check." before ever
  # reaching the n_missing-eq-0 branch the reason check lives in -- so a T1
  # fixture would pass this test for the wrong reason. T2 mandates
  # G4/G5/G6/G8 and actually reaches that branch, which is what exercises
  # the tier_n < 3 guard this test means to prove.
  for g in G4 G5 G6 G8; do
    led add --change c --gate "$g" --tier T2 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  run led compliance --change c --tier T2
  assert_exit 0 "T2 must not require a recorded reason"
  assert_not_contains "no reason recorded"
}

# An empty --note (or a G1 entry logged with no --note at all) must not
# accidentally satisfy the check — the same false-positive shape
# gate_outcome_has_reason already guards against for n/a entries.
test_compliance_does_not_accept_an_empty_g1_note_as_a_reason() {
  newrepo
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m >/dev/null 2>&1
  done
  run led compliance --change c --tier T3
  assert_exit 1 "a G1 entry with no note must not count as a recorded reason"
  assert_contains "no reason recorded"
}

# The missing-reason refusal must fire even when every other check on this
# change (mandated gates, unresolved assumptions) already passes clean —
# proving it is an independent gate, not a side effect of one of the others.
test_compliance_reason_check_is_independent_of_the_assumption_check() {
  newrepo
  # G1 deliberately gets NO --note, same reason as the test above — otherwise
  # its boilerplate note would clear the very check this test is proving is
  # independent of the assumption check.
  for g in G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T4 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led add --change c --gate G1 --tier T4 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m >/dev/null 2>&1
  led assume --change c --assumed "export format is CSV" --resolution asked \
    --basis "requester confirmed CSV" >/dev/null 2>&1
  run led compliance --change c --tier T4
  assert_exit 1 "no unresolved assumption and every gate passing must still not be enough"
  assert_not_contains "UNCONFIRMED"
  assert_contains "no reason recorded"
}

# A fresh-context review of this feature found that an EARLIER version of
# change_has_recorded_reason() checked ANY G1 entry for the change, at any
# round — so a note logged only once G1 is re-run at round 2 satisfied the
# check, even though tools/dashboard/app.js's whyThisRan() (the function
# this is meant to mirror) only ever reads round 1's G1 entry. compliance
# would say "satisfied" for a change the dashboard still shows as "Reason
# not recorded" -- the exact disagreement the code's own comment claimed
# could not happen. Fixed by scoping the G1 half of the check to round 1.
# This pins the fix: a note recorded only at round 2 must not count.
test_compliance_ignores_a_g1_note_logged_only_at_a_later_round() {
  newrepo
  for g in G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led add --change c --gate G1 --tier T3 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m >/dev/null 2>&1
  led add --change c --gate G1 --tier T3 --round 2 --outcome pass \
    --confidence fresh --challenged false --model m --note "why this change exists" >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 1 "a G1 note recorded only at round 2 must not satisfy the check -- whyThisRan() only ever reads round 1"
  assert_contains "no reason recorded"
}

# The other half of the same fix, proven separately: round 1's G1 note must
# count regardless of THAT entry's own outcome -- whyThisRan() reads
# round1.gates.filter(g => g.gate === "G1")[0] unconditionally, with no
# outcome filter, so a round-1 G1 that failed but explained the "why" (then
# passed cleanly on re-run, still at round 1 -- a same-round retry, not a
# new R0c round) must still satisfy this check. Distinguishes "scoped to
# round 1" from "scoped to round 1 AND outcome pass", which would have been
# the wrong fix for the bug above.
test_compliance_accepts_a_round_1_g1_note_regardless_of_that_entrys_own_outcome() {
  newrepo
  for g in G4 G5 G6 G7 G8; do
    led add --change c --gate "$g" --tier T3 --round 1 --outcome pass \
      --confidence fresh --challenged false --model m --note ok >/dev/null 2>&1
  done
  led add --change c --gate G1 --tier T3 --round 1 --outcome fail \
    --confidence fresh --challenged false --model m --note "why this change exists" \
    >/dev/null 2>&1
  led add --change c --gate G1 --tier T3 --round 1 --outcome pass \
    --confidence fresh --challenged false --model m >/dev/null 2>&1
  run led compliance --change c --tier T3
  assert_exit 0 "a note on ANY round-1 G1 entry must satisfy the check regardless of that entry's own outcome, same as whyThisRan()"
}

# ---------------------------------------------------------------- card calibration
#
# must_ask / overfit_when / underfit_when are REQUIRED keys. A card that cannot
# say what it must never invent, or what its own two drift failures look like,
# is a card whose author has not decided what the gate is for — and the check
# has to actually fail, or it is decoration.
test_every_shipped_card_declares_its_constraints() {
  newrepo
  local missing=""
  for f in "$REPO"/.pipeline/core/cards/G*.md; do
    for k in must_ask overfit_when underfit_when; do
      grep -q "^$k:" "$f" || missing="${missing} $(basename "$f"):$k"
    done
  done
  assert_eq "" "$missing" "cards missing a calibration key"
}

test_dashboard_check_fails_a_card_with_no_must_ask() {
  newrepo
  grep -v '^must_ask:' "$REPO/.pipeline/core/cards/G8-dogfood.md" > "$REPO/g8.tmp"
  mv "$REPO/g8.tmp" "$REPO/.pipeline/core/cards/G8-dogfood.md"
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --check"
  assert_exit 1 "a card missing a required key must fail the check, not warn"
  assert_contains "must_ask"
}

# ---------------------------------------------------------------- starved gates
#
# A gate whose declared input does not exist does not refuse to run — it infers
# the input and reviews against the inference. A check that cannot fire is worse
# than none, so both directions are asserted.
test_status_names_gates_that_would_invent_their_input() {
  newrepo   # newrepo installs the shipped EXAMPLE surfaces.conf
  printf '# Coupling registry\n\nNothing yet.\n' > "$REPO/.pipeline/project/registry.md"
  run status_run
  assert_contains "GATES THAT WOULD INVENT THEIR INPUT"
  assert_contains "G7 Threat"
  assert_contains "G4 Ripple"
}

# Found by a fresh-context G4 Ripple run. The check tested for couplings with a
# regex that matched the SHIPPED registry template's table HEADER
# ("| If you touch… | You must also check… | Because |") rather than an entry,
# so a project whose entries row is literally "| | | |" reported as populated
# and G4 was never named as starved. The two tests above passed only because
# their fixtures were hand-written and omitted that header — my code and my
# fixtures agreed with each other and both were wrong. This uses the REAL
# shipped template, which is the only fixture that could have caught it.
test_status_names_g4_as_starved_against_the_real_registry_template() {
  newrepo
  cp "$REPO/.pipeline/templates/project/registry.md" "$REPO/.pipeline/project/registry.md"
  # Real surfaces so ONLY the registry can be the thing that starves a gate.
  printf 'T4::(^|/)auth/::Trust boundary\nTARGET::Linux::tests\n' \
    > "$REPO/.pipeline/project/surfaces.conf"
  run status_run
  assert_contains "GATES THAT WOULD INVENT THEIR INPUT"
  assert_contains "G4 Ripple"
}

test_status_is_quiet_about_starved_gates_when_the_inputs_are_real() {
  newrepo
  # A real surfaces file (no example marker), with targets.
  printf 'T4::(^|/)auth/::Trust boundary\nTARGET::Linux::tests\n' \
    > "$REPO/.pipeline/project/surfaces.conf"
  printf '# Coupling registry\n\nIf you touch auth, you must also check session invalidation.\n' \
    > "$REPO/.pipeline/project/registry.md"
  run status_run
  assert_not_contains "GATES THAT WOULD INVENT THEIR INPUT"
}

# ---------------------------------------------------------------- update-kit
#
# A vendored kit is a COPY, so every upstream fix — including the ones that stop
# `compliance` passing a change it should refuse — reaches an existing install
# only if the files are copied again. Two consecutive fresh-context Ripple
# reviews raised the absence of any refresh path. The dangerous half is not
# forgetting to update; it is updating by hand and clobbering project/,
# ledger.jsonl or security-reports/, which are the only unrecoverable things in
# an install.
_newer_kit() {
  # A minimal "newer" kit: real enough to pass the structure check, with a
  # different fingerprint and one file the installed copy does not have.
  local d; d="$(mktemp -d "$TMPROOT/newkit.XXXXXX")"
  mkdir -p "$d/core" "$d/tools/lib" "$d/templates"
  cp "$KIT/core/01-router.md" "$d/core/01-router.md"
  printf '#!/usr/bin/env bash\n# newer\n' > "$d/tools/ledger.sh"
  printf '# newer lib\n' > "$d/tools/lib/matrix.sh"
  printf 'brand new\n' > "$d/tools/BRAND-NEW.sh"
  printf 'skeleton\n' > "$d/templates/marker.txt"
  printf '9.9.9\n' > "$d/VERSION"
  printf '# changelog\n' > "$d/CHANGELOG.md"
  printf '%s' "$d"
}

_upd() { ( cd "$REPO" && bash .pipeline/tools/update-kit.sh "$@" ); }

# THE property. Everything else this script does is replaceable; losing a
# project's ledger or its answered surfaces.conf is not.
test_update_kit_never_touches_the_projects_own_records() {
  newrepo
  local src; src="$(_newer_kit)"
  printf '{"type":"gate","date":"2026-01-01","change":"mine","tier":"T4","gate":"G7","round":1,"commit":"aaa","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$REPO/.pipeline/ledger.jsonl"
  printf 'T4::(^|/)mine/::my own answer\n' > "$REPO/.pipeline/project/surfaces.conf"
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'my report\n' > "$REPO/.pipeline/security-reports/mine.md"
  printf '<html>mine</html>\n' > "$REPO/.pipeline/dashboard.html"

  run _upd "$src"
  assert_exit 0
  assert_file_contains "$REPO/.pipeline/ledger.jsonl" '"change":"mine"'
  assert_file_contains "$REPO/.pipeline/project/surfaces.conf" "my own answer"
  assert_file_contains "$REPO/.pipeline/security-reports/mine.md" "my report"
  assert_file_contains "$REPO/.pipeline/dashboard.html" "mine"
}

test_update_kit_replaces_the_portable_parts() {
  newrepo
  local src; src="$(_newer_kit)"
  run _upd "$src"
  assert_exit 0
  assert_file_contains "$REPO/.pipeline/VERSION" "9.9.9"
  assert_file_contains "$REPO/.pipeline/tools/ledger.sh" "newer"
  [ -f "$REPO/.pipeline/tools/BRAND-NEW.sh" ] && _ok || _fail "a new upstream file did not arrive"
}

# E6: "is this newer?" looked only at version + tools/*.sh, so an upstream change to core/
# (the gate matrix, the cards) alone read as "Already current" and was never applied.
test_update_kit_applies_a_core_only_change() {
  newrepo
  local src; src="$(mktemp -d "$TMPROOT/samekit.XXXXXX")"
  cp -r "$REPO/.pipeline/core" "$REPO/.pipeline/tools" "$REPO/.pipeline/templates" "$src/"
  # Identical in EVERY other portable file, so core/ is the only difference (G5 round 1: a
  # source missing README.md differed for that reason alone and hid a tools-only checksum).
  for f in README.md CHANGELOG.md VERSION; do [ -f "$REPO/.pipeline/$f" ] && cp "$REPO/.pipeline/$f" "$src/$f"; done
  printf '
<!-- upstream core change -->
' >> "$src/core/02-gates.md"
  run _upd "$src"
  assert_exit 0
  assert_not_contains "Already current"
  assert_file_contains "$REPO/.pipeline/core/02-gates.md" "upstream core change"
}

# G5 round 2: a checksum that only looked at core/ and tools/ would survive the core test.
test_update_kit_applies_a_templates_only_change() {
  newrepo
  local src; src="$(mktemp -d "$TMPROOT/samekit.XXXXXX")"
  cp -r "$REPO/.pipeline/core" "$REPO/.pipeline/tools" "$REPO/.pipeline/templates" "$src/"
  for f in README.md CHANGELOG.md VERSION; do [ -f "$REPO/.pipeline/$f" ] && cp "$REPO/.pipeline/$f" "$src/$f"; done
  printf '# upstream template change\n' >> "$src/templates/PULL_REQUEST_TEMPLATE.md"
  run _upd "$src"
  assert_exit 0
  assert_not_contains "Already current"
  assert_file_contains "$REPO/.pipeline/templates/PULL_REQUEST_TEMPLATE.md" "upstream template change"
  assert_contains "core/ or templates/ differ"
}

test_update_kit_reports_current_when_nothing_differs() {
  newrepo
  local src; src="$(mktemp -d "$TMPROOT/samekit.XXXXXX")"
  cp -r "$REPO/.pipeline/core" "$REPO/.pipeline/tools" "$REPO/.pipeline/templates" "$src/"
  for f in README.md CHANGELOG.md VERSION; do [ -f "$REPO/.pipeline/$f" ] && cp "$REPO/.pipeline/$f" "$src/$f"; done
  run _upd "$src"
  assert_contains "Already current"
}

# Found by a fresh-context G6 Peer review (round 3): ledger.sh's detect_kit()
# prefers .kit-version's `version=` line over plain VERSION whenever the file
# exists -- which every install that wrote one does. Left
# untouched by the replace loop above, .kit-version goes stale the moment
# VERSION is updated: every future ledger record keeps stamping the OLD
# version forever, while this script's own fingerprint output and status.sh's
# banner (both read plain VERSION) correctly report the new one.
test_update_kit_refreshes_the_kit_version_stamp_but_keeps_its_provenance() {
  newrepo
  local src; src="$(_newer_kit)"
  # An install that stamps provenance writes this shape; newrepo()'s
  # fixture does not run the installer, so simulate one by hand.
  printf 'version=1.0.0\ninstalled=2026-01-01T00:00:00Z\nsource=installer\n' \
    > "$REPO/.pipeline/.kit-version"
  run _upd "$src"
  assert_exit 0
  assert_file_contains "$REPO/.pipeline/.kit-version" "version=9.9.9"
  # This install's own original provenance must survive -- an update is not
  # a re-install, and overwriting these would erase when this copy was
  # actually installed.
  assert_file_contains "$REPO/.pipeline/.kit-version" "installed=2026-01-01T00:00:00Z"
  assert_file_contains "$REPO/.pipeline/.kit-version" "source=installer"
}

# Found by a fresh-context G4 Ripple review (round 3): the replace loop had no
# `set -e` and never checked `rm`/`cp`'s exit status, so a failure partway
# through -- a full disk, a permission error, a lock held on Windows -- still
# fell through to the unconditional "Updated" success banner, over a directory
# `rm -rf` had already emptied and `cp -r` never finished refilling. A stub
# `cp` on PATH that fails specifically for the `tools/` copy simulates that
# without needing a real disk-full or permission-denied condition.
test_update_kit_stops_loudly_when_a_copy_fails_partway() {
  newrepo
  local src; src="$(_newer_kit)"
  local real_cp; real_cp="$(command -v cp)"
  local stub; stub="$(mktemp -d "$TMPROOT/cpstub.XXXXXX")"
  cat > "$stub/cp" <<SHIM
#!/bin/sh
case "\$*" in
  *"/tools "*) echo "cp: stub failure" >&2; exit 1;;
esac
exec "$real_cp" "\$@"
SHIM
  chmod +x "$stub/cp"
  LAST_OUT="$( cd "$REPO" && PATH="$stub:$PATH" bash .pipeline/tools/update-kit.sh "$src" 2>&1 )"; LAST_EXIT=$?
  assert_exit 1 "a failed cp mid-refresh must not report success"
  assert_contains "FAILED copying"
  assert_not_contains "Updated"
}

# A tool retired upstream must actually disappear, not linger as an executable
# that still looks installed — the failure mode this kit spends most of its
# words on.
test_update_kit_removes_a_tool_retired_upstream() {
  newrepo
  local src; src="$(_newer_kit)"
  [ -f "$REPO/.pipeline/tools/status.sh" ] || { _fail "fixture lacks status.sh"; return; }
  run _upd "$src"
  assert_exit 0
  [ -f "$REPO/.pipeline/tools/status.sh" ] && _fail "a tool absent upstream survived the update" || _ok
}

# Copying an arbitrary directory over a project's .pipeline/ is unrecoverable.
test_update_kit_refuses_a_source_that_is_not_a_kit() {
  newrepo
  local notkit; notkit="$(mktemp -d "$TMPROOT/notkit.XXXXXX")"
  printf 'hi\n' > "$notkit/readme.txt"
  run _upd "$notkit"
  assert_exit 1
  assert_contains "not a kit"
  assert_file_contains "$REPO/.pipeline/tools/status.sh" "status.sh"
}

test_update_kit_refuses_to_update_itself() {
  newrepo
  run _upd "$REPO/.pipeline"
  assert_exit 1
  assert_contains "same directory"
}

test_update_kit_is_a_noop_when_already_current() {
  newrepo
  local same; same="$(mktemp -d "$TMPROOT/same.XXXXXX")"
  cp -r "$REPO/.pipeline/core" "$REPO/.pipeline/tools" "$REPO/.pipeline/templates" "$same/"
  # Copy VERSION only if the install actually has one. Inventing a fallback here
  # made the "identical" source differ from the installed copy by exactly the
  # field the comparison keys on, so the test proved the opposite of its name.
  [ -f "$REPO/.pipeline/VERSION" ] && cp "$REPO/.pipeline/VERSION" "$same/VERSION"
  # The comparison now covers every portable file (E6), so "identical" includes these.
  for f in README.md CHANGELOG.md; do [ -f "$REPO/.pipeline/$f" ] && cp "$REPO/.pipeline/$f" "$same/$f"; done
  run _upd "$same"
  assert_exit 0
  assert_contains "Already current"
}

test_update_kit_dry_run_writes_nothing() {
  newrepo
  local src; src="$(_newer_kit)"
  local before; before="$(cat "$REPO/.pipeline/VERSION" 2>/dev/null)"
  run _upd "$src" --dry-run
  assert_exit 0
  assert_contains "DRY RUN"
  assert_eq "$before" "$(cat "$REPO/.pipeline/VERSION" 2>/dev/null)" "VERSION after a dry run"
}

# The hook is a separate copy in .git/hooks/ and this script cannot reach it.
# Saying so is the difference between an upgrade that works and one that leaves
# the enforcement point a version behind while reporting success.
test_update_kit_tells_you_the_hook_is_still_stale() {
  newrepo
  local src; src="$(_newer_kit)"
  run _upd "$src"
  assert_contains "install-hook.sh --force"
}

# ---------------------------------------------------------------- coverage (shared lib)
#
# tools/lib/coverage.sh exists so status.sh and dashboard.sh cannot disagree
# about what counts as unrouted — the same reason tools/lib/matrix.sh exists one
# level down, after the gate matrix was restated per tool and the copies drifted.
# The agreement test below is the point of the whole arrangement.
_cov_model() { ( cd "$REPO" && bash .pipeline/tools/dashboard.sh --print-model "$@" 2>/dev/null ); }

test_dashboard_bakes_coverage_for_a_single_in_repo_ledger() {
  newrepo
  _ledger_gate_at
  printf 'token=3\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "later T4" >/dev/null 2>&1
  run _cov_model
  assert_exit 0
  assert_contains '"coverage":{'
  assert_contains '"highest":4'
}

# Coverage is git-derived. A fleet view points at other projects' ledgers while
# git still answers about THIS repo — reporting one project's commits against
# another's gate records is exactly the confident wrong answer the panel exists
# to remove, so it must decline rather than guess.
test_dashboard_declines_coverage_for_a_fleet_view() {
  newrepo
  _ledger_gate_at
  run _cov_model --project A --ledger .pipeline/ledger.jsonl --project B --ledger .pipeline/ledger.jsonl
  assert_exit 0
  assert_contains '"coverage":null'
}

test_dashboard_declines_coverage_for_a_ledger_outside_this_repo() {
  newrepo
  local outside; outside="$(mktemp -d "$TMPROOT/outside.XXXXXX")"
  git -C "$outside" init -q 2>/dev/null
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"aaa1111","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$outside/l.jsonl"
  run _cov_model --ledger "$outside/l.jsonl"
  assert_exit 0
  assert_contains '"coverage":null'
}

# The drive-letter form of the same thing. Git Bash passes `D:\...` / `D:/...`
# through from the command line; the abs-path `case` only matched POSIX `/...`,
# so a Windows-absolute foreign ledger built `$(pwd)/D:/...` (never a real
# dir), fell through the old blanket "missing dir => same repo" branch, and
# computed THIS repo's git history against another project's ledger. G8 hit it.
test_dashboard_declines_coverage_for_a_drive_letter_path_outside_this_repo() {
  newrepo
  local outside; outside="$(mktemp -d "$TMPROOT/outside2.XXXXXX")"
  git -C "$outside" init -q 2>/dev/null
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"aaa1111","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$outside/l.jsonl"
  # A path whose directory genuinely does not exist must also decline, not
  # fall back to "nothing gated here yet, so it's ours".
  run _cov_model --ledger "$outside/nope/l.jsonl"
  assert_exit 0
  assert_contains '"coverage":null'
  # And if `cygpath` is around, prove the literal `D:\` form too.
  if command -v cygpath >/dev/null 2>&1; then
    local win; win="$(cygpath -w "$outside/l.jsonl")"
    run _cov_model --ledger "$win"
    assert_exit 0
    assert_contains '"coverage":null'
  fi
}

# THE anti-drift test. Two readers of the same question, asserted equal against a
# live fixture rather than by inspection — a comment claiming they share a
# library proves nothing if one of them stops calling it.
test_status_and_dashboard_agree_on_the_unrouted_count() {
  newrepo
  _ledger_gate_at
  printf 'token=4\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "one" >/dev/null 2>&1
  printf 'body{}\n' > "$REPO/src/theme.css"
  git -C "$REPO" add src/theme.css >/dev/null 2>&1
  git -C "$REPO" commit -qm "two" -- src/theme.css >/dev/null 2>&1

  local from_status from_dash
  from_status="$( ( cd "$REPO" && bash .pipeline/tools/status.sh 2>/dev/null ) \
    | sed -n 's/^  \([0-9][0-9]*\) commit(s).*/\1/p' | head -1)"
  from_dash="$(_cov_model | sed -n 's/.*"coverage":{[^}]*"commits":\([0-9][0-9]*\).*/\1/p' | head -1)"
  assert_eq "$from_status" "$from_dash" "unrouted commit count (status.sh vs dashboard.sh)"
  [ -n "$from_status" ] && _ok || _fail "status.sh printed no commit count to compare"
}

# G5 round 2: dashboard.sh's use of coverage_baseline was untested -- it could drift from
# status.sh on exactly the E10 path (nothing gated, count from the install).
test_status_and_dashboard_agree_when_nothing_was_ever_gated() {
  newrepo
  printf 'token=4\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "post-install one" >/dev/null 2>&1
  printf 'body{color:red}\n' > "$REPO/src/theme.css"
  git -C "$REPO" add src/theme.css >/dev/null 2>&1
  git -C "$REPO" commit -qm "post-install two" -- src/theme.css >/dev/null 2>&1
  local from_status from_dash
  from_status="$( ( cd "$REPO" && bash .pipeline/tools/status.sh 2>/dev/null ) \
    | sed -n 's/^  \([0-9][0-9]*\) commit(s).*/\1/p' | head -1)"
  from_dash="$(_cov_model | sed -n 's/.*"coverage":{[^}]*"commits":\([0-9][0-9]*\).*/\1/p' | head -1)"
  assert_eq "2" "$from_status" "status.sh counts only the post-install commits"
  assert_eq "$from_status" "$from_dash" "dashboard.sh must count the same range"
}

# Regression lock for a real bug: the in-repo check compared path STRINGS, and on
# Git Bash for Windows `git rev-parse --show-toplevel` yields "D:/x" while `pwd`
# yields "/d/x". The prefix never matched, so coverage silently computed to null
# forever on this kit's own primary TARGET platform — failing closed, which is
# safe but invisible. This asserts the positive case actually fires.
test_dashboard_coverage_survives_the_pwd_vs_git_toplevel_path_form() {
  newrepo
  _ledger_gate_at
  run _cov_model
  assert_exit 0
  assert_not_contains '"coverage":null'
}

# A retro/backfilled `ledger.sh add --commit <old-sha>` gate entry (a real,
# documented option — tools/ledger.sh:59) can be appended to the ledger AFTER
# a real, later gate run already logged a newer commit: gate lines are
# appended when the REVIEW happens, not in commit-graph order. The old
# `coverage_anchor()` trusted file order ("last line = newest"), so the
# older, retro-logged commit silently displaced the true newer anchor and
# already-gated work (commit B below) reported as unrouted all over again.
test_coverage_anchor_ignores_a_retro_logged_older_commit_appended_last() {
  newrepo
  # Explicit, strictly-increasing PAST dates, all before real "now": `coverage_anchor()`
  # rejects a future-dated candidate outright (a separate defense against a forged
  # anchor — see test_coverage_anchor_rejects_a_future_dated_forged_commit below), so
  # this scenario has to stay in the past to test what it is actually testing. `newrepo`'s
  # own "base" commit lands at the real current system time, which is fine here — base is
  # never named by any ledger line, so it never competes to be the anchor; only A/B/C need
  # to be distinct from EACH OTHER, not from "now" — same-second real commits on a fast
  # machine would tie, which is a different bug than the one under test here.
  export GIT_AUTHOR_DATE="2020-01-01T10:00:00" GIT_COMMITTER_DATE="2020-01-01T10:00:00"
  printf 'token=4\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit A" >/dev/null 2>&1
  _ledger_gate_at                      # real, timely gate on commit A (current HEAD)
  local sha_a; sha_a="$(git -C "$REPO" rev-parse --short HEAD)"

  export GIT_AUTHOR_DATE="2020-01-01T11:00:00" GIT_COMMITTER_DATE="2020-01-01T11:00:00"
  printf 'token=5\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit B" >/dev/null 2>&1
  _ledger_gate_at                      # real, timely gate on commit B (new HEAD)
  local sha_b; sha_b="$(git -C "$REPO" rev-parse --short HEAD)"

  export GIT_AUTHOR_DATE="2020-01-01T12:00:00" GIT_COMMITTER_DATE="2020-01-01T12:00:00"
  printf 'token=6\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit C, unrouted" >/dev/null 2>&1
  unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

  # Retro-log: backfill a gate entry for the OLDER commit A, appended LAST —
  # physically after B's real, timely entry above.
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"retro"}\n' \
    "$sha_a" >> "$(ledger_path)"

  run _cov_model
  assert_exit 0
  assert_contains "\"anchor\":\"$sha_b\"" "coverage_anchor must pick the newer real gate (B), not the retro-logged older one (A) just because it was appended last"
}

# `--commit` is ledger data — untrusted, from whoever last ran `ledger.sh
# add`. A fresh G7 round on the fix above found (and this repro confirmed
# directly, outside the suite) that `git log`, unlike `git rev-parse
# --verify`, treats a leading-`-` argument as an OPTION: a ledger value of
# `--output=<path>` reaching `git log -1 --format=%ct "$sha^{commit}" --`
# really does create `<path>^{commit}`. The fix verifies with `rev-parse
# --verify` FIRST and only ever hands a resolved, always-hex, never-`-`-
# leading full sha to any later git call.
test_coverage_anchor_does_not_let_a_ledger_commit_value_become_a_git_option() {
  newrepo
  _ledger_gate_at
  local pwned="$REPO/../pwned-by-coverage-anchor.txt"
  rm -f "$pwned" "${pwned}^{commit}" 2>/dev/null
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"--output=%s","outcome":"pass","findings":0,"note":"malicious"}\n' \
    "$pwned" >> "$(ledger_path)"
  run _cov_model
  assert_exit 0
  if [ -e "$pwned" ] || [ -e "${pwned}^{commit}" ]; then
    _fail "a ledger --commit value shaped like a git option must never make git WRITE a file"
  else
    _ok
  fi
}

# Ranking by commit TIMESTAMP (an earlier version of this fix did exactly
# that) is forgeable by the same untrusted writer who can name a `--commit`
# at all: a real commit with a forged, far-future `GIT_COMMITTER_DATE` would
# win permanently the instant it's logged; a fix that only rejects FUTURE
# dates just delays that to the moment real time reaches the forged date —
# narrower, not closed (a second fresh G7 round on that fix named this).
# `coverage_anchor()` no longer looks at commit dates AT ALL — it ranks by
# commit-graph ANCESTRY (`git merge-base --independent`), which has no date
# to forge. This test proves that directly: commit B is a REAL descendant of
# commit A, but B's date is set EARLIER than A's — the wrong answer under any
# date-based scheme, including the "reject the future" one this replaced —
# and the anchor must still correctly land on B.
test_coverage_anchor_ranks_by_ancestry_not_by_a_forgeable_commit_date() {
  newrepo
  export GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00"
  printf 'token=a\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit A" >/dev/null 2>&1
  _ledger_gate_at
  local sha_a; sha_a="$(git -C "$REPO" rev-parse --short HEAD)"

  # Commit B is a real descendant of A (committed after it, same branch) but
  # carries an EARLIER date than A — backdated, the way a forged date could
  # go either direction. Any timestamp-based ranking picks A here; ancestry
  # does not care what date B claims.
  export GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00"
  printf 'token=b\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit B, backdated but really newer" >/dev/null 2>&1
  unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  _ledger_gate_at
  local sha_b; sha_b="$(git -C "$REPO" rev-parse --short HEAD)"

  run _cov_model
  assert_exit 0
  assert_contains "\"anchor\":\"$sha_b\"" "a real descendant must win the anchor regardless of what date it claims"
  assert_not_contains "\"anchor\":\"$sha_a\""
}

# An unmerged gated commit is not a rival for "newest reviewed commit on this
# line" — it is on a DIFFERENT line, and must not be a `merge-base
# --independent` candidate at all. Before the HEAD-ancestor filter, a gate
# logged on `branch-one` (never merged, HEAD sits on `branch-two`) was a
# legitimate independent tip alongside `branch-two`'s own gate, the count went
# past 1, and `coverage_anchor` returned NO anchor — status.sh then scanned the
# whole history as unrouted. The append-only ledger cannot rewrite that entry
# (04-ledger.md) and the orphan's object survives git's gc window, so this is
# the ordinary rebase/squash-merge workflow, not an edge case. Post-filter:
# `branch-one`'s commit is dropped for not being reachable from HEAD, and the
# anchor correctly resolves to `branch-two`'s tip.
#
# (This test previously asserted `"anchor":""` for this exact setup — encoding
# the pre-filter decision that an unmerged commit is a rankable rival. It is
# not. The genuine-divergence refusal it was guarding is still tested, one
# function down, for the case that can actually still happen: two commits BOTH
# reachable from a merge HEAD.)
test_coverage_anchor_ignores_an_unmerged_gated_commit_and_anchors_to_head_side() {
  newrepo
  local base; base="$(git -C "$REPO" rev-parse HEAD)"

  git -C "$REPO" checkout -qb branch-one "$base"
  printf 'token=one\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "branch one" >/dev/null 2>&1
  local sha_one; sha_one="$(git -C "$REPO" rev-parse --short HEAD)"

  git -C "$REPO" checkout -q "$base"
  git -C "$REPO" checkout -qb branch-two "$base"
  printf 'token=two\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "branch two" >/dev/null 2>&1
  local sha_two; sha_two="$(git -C "$REPO" rev-parse --short HEAD)"

  # Sitting on branch-two, log BOTH as gated in one uncommitted ledger — the
  # one file on disk names both. `git rev-parse --verify` resolves sha_one by
  # object id even off its branch, so it still enters as a candidate and the
  # filter has real work to do.
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' \
    "$sha_one" >> "$(ledger_path)"
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' \
    "$sha_two" >> "$(ledger_path)"

  run _cov_model
  assert_exit 0
  assert_contains "\"anchor\":\"$sha_two\"" "the unmerged branch-one gate must be filtered out, anchoring to branch-two's tip (HEAD)"
  assert_not_contains "\"anchor\":\"$sha_one\""
  assert_not_contains '"anchor":""'

  # Same repo, same ledger — deterministic.
  run _cov_model
  assert_contains "\"anchor\":\"$sha_two\""
}

# A gate logged against a commit that was later rebased/squashed away and its
# branch deleted: the object survives git's gc grace window, so `rev-parse
# --verify` still resolves it, but it is on no branch and is not an ancestor of
# HEAD. It must not blank the anchor. Reproduces the real-repo bug that
# prompted this change (ledger.jsonl named an early superseded
# coverage-anchor-retro-fix commit; status.sh fell back to a 209-commit
# whole-history scan). Discrimination proof (T4 target rule) done manually this
# session: `git show HEAD:tools/lib/coverage.sh` swapped in → this scenario
# returns "" ; fix restored → returns commit C. Recorded in the G5 ledger note.
test_coverage_anchor_ignores_an_orphaned_gated_commit_from_a_deleted_branch() {
  newrepo

  printf 'token=a\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit A" >/dev/null 2>&1
  local sha_a; sha_a="$(git -C "$REPO" rev-parse --short HEAD)"

  # A branch commit, gated, then the branch is deleted — the object lingers.
  git -C "$REPO" checkout -qb feat >/dev/null 2>&1
  printf 'token=b\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit B on feat" >/dev/null 2>&1
  local sha_b; sha_b="$(git -C "$REPO" rev-parse --short HEAD)"
  git -C "$REPO" checkout -q master >/dev/null 2>&1   # newrepo's default branch
  git -C "$REPO" branch -qD feat

  # A real, later commit on the trunk, also gated.
  printf 'token=c\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit C on trunk" >/dev/null 2>&1
  local sha_c; sha_c="$(git -C "$REPO" rev-parse --short HEAD)"

  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' "$sha_a" >> "$(ledger_path)"
  printf '{"type":"gate","date":"2026-08-15","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' "$sha_b" >> "$(ledger_path)"
  printf '{"type":"gate","date":"2026-08-16","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' "$sha_c" >> "$(ledger_path)"

  # sha_b is still resolvable (object not gc'd) but not an ancestor of HEAD.
  assert_eq "$sha_b" "$(git -C "$REPO" rev-parse --short "$sha_b" 2>/dev/null)" "precondition: orphaned commit object still resolves"

  run _cov_model
  assert_exit 0
  assert_contains "\"anchor\":\"$sha_c\"" "the orphaned branch gate must be filtered, anchoring to the newest trunk gate (C)"
  assert_not_contains "\"anchor\":\"$sha_b\""
  assert_not_contains '"anchor":""'
}

# Two gated commits, both reachable from HEAD, neither descending from the other: both are anchors.
# (This used to be a refusal; the name is kept so the history of the case stays findable.)
# The genuine-divergence case, narrowed to the case that can still occur:
# two commits BOTH reachable from HEAD (HEAD is a real merge of two lines),
# neither descending from the other, each gated. `merge-base --independent`
# returns both, and there is still no honest, non-gameable way to rank them —
# so `coverage_anchor` returns NO anchor rather than guess. This is what the
# rewritten test above used to cover with an unmerged commit; the mechanism it
# was really guarding lives here.
test_coverage_anchor_still_refuses_genuine_head_side_divergence() {
  newrepo
  local base; base="$(git -C "$REPO" rev-parse HEAD)"

  git -C "$REPO" checkout -qb line-x "$base"
  printf 'token=x\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "line x" >/dev/null 2>&1
  local sha_x; sha_x="$(git -C "$REPO" rev-parse --short HEAD)"

  git -C "$REPO" checkout -q "$base"
  git -C "$REPO" checkout -qb line-y "$base"
  printf 'token=y\n' > "$REPO/src/components/y.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "line y" >/dev/null 2>&1
  local sha_y; sha_y="$(git -C "$REPO" rev-parse --short HEAD)"

  # A real merge commit with both lines as parents — X and Y are now both
  # ancestors of HEAD, neither an ancestor of the other.
  git -C "$REPO" checkout -qb trunk "$base"
  git -C "$REPO" merge -q --no-ff -m "merge x and y" "$sha_x" "$sha_y" >/dev/null 2>&1

  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' "$sha_x" >> "$(ledger_path)"
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"n"}\n' "$sha_y" >> "$(ledger_path)"

  # precondition: both are ancestors of the merge HEAD, neither descends from the other
  git -C "$REPO" merge-base --is-ancestor "$sha_x" HEAD; local _pa=$?
  git -C "$REPO" merge-base --is-ancestor "$sha_y" HEAD; local _pb=$?
  assert_eq "0 0" "$_pa $_pb" "precondition: both gated commits are ancestors of the merge HEAD"

  run _cov_model
  assert_exit 0
  # G8 r12: there is nothing to rank, so BOTH tips anchor (everything they contain is reviewed)
  assert_not_contains '"anchor":""' "two mutually-non-descending HEAD ancestors are both anchors"
  assert_contains "$sha_x" "the first gated tip is named"
  assert_contains "$sha_y" "the second gated tip is named"
}

# The old single-candidate code was `if verify; then printf; fi` with no
# `else` — POSIX always exits 0 for an `if` whose condition was false and had
# no else, so `coverage_anchor` was guaranteed to exit 0 even when its only
# candidate could not be verified. A fresh G6 round found the rewrite's tail,
# `[ -n "$best" ] && printf`, does NOT share that guarantee: `&&` propagates
# the test's own (false → 1) exit status when nothing resolves. This is the
# exact "commits this clone has never seen" case the function's own header
# comment calls legitimate (a fleet ledger, a foreign sha) — it must not
# change this function's exit-status contract.
test_coverage_anchor_exits_zero_even_when_every_candidate_is_unresolvable() {
  newrepo
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"deadbeef0000000000000000000000000000foreign","outcome":"pass","findings":0,"note":"n"}\n' \
    > "$(ledger_path)"
  local out exit_code
  out="$( ( cd "$REPO" && . .pipeline/tools/lib/coverage.sh && coverage_anchor "$(ledger_path)" ) )"
  exit_code=$?
  assert_eq "0" "$exit_code" "coverage_anchor must still exit 0 when every ledger-named commit is unresolvable, matching its pre-fix contract"
  assert_eq "" "$out" "and print nothing, since there is no verified anchor"
}

# `for _cov_sha in $_cov_shas` needs unquoted expansion to word-split the
# candidate list — which also exposes it to pathname expansion. A ledger
# `"commit"` value of `*` would otherwise iterate over this repo's actual
# filenames instead of the literal string `*` (confirmed by direct repro
# outside the suite). A fresh G6 round found this; the fix wraps the loop in
# `set -f`. This only needs to prove the glob-shaped value doesn't crash or
# misbehave — `coverage_anchor` failing closed on a value this nonsensical
# is correct; iterating actual filenames instead would not be.
test_coverage_anchor_does_not_glob_expand_a_ledger_commit_value() {
  newrepo
  printf 'x\n' > "$REPO/decoy-file-one"
  printf 'x\n' > "$REPO/decoy-file-two"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "decoys" >/dev/null 2>&1
  _ledger_gate_at                        # real, timely gate on the actual current HEAD
  local sha_real; sha_real="$(git -C "$REPO" rev-parse --short HEAD)"
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"*","outcome":"pass","findings":0,"note":"glob"}\n' \
    >> "$(ledger_path)"

  run _cov_model
  assert_exit 0
  assert_contains "\"anchor\":\"$sha_real\"" "the glob-shaped ledger value must be skipped as unresolvable, leaving the real gate as the anchor"
}

# LAST_COMMIT and SINCE_REF can each be sourced from a DIFFERENT ledger line
# (see the disagreement note above them) — if those two lines logged the same
# commit under different sha lengths (short vs full, both legal `--commit`
# forms), a naive string compare would call them "different" when they name
# one commit. A fresh G6 round found this false-positive risk in the note
# added for the disagreement case itself.
test_status_does_not_false_flag_the_same_commit_in_different_sha_forms() {
  newrepo
  _ledger_gate_at                        # real, timely gate on commit A (current HEAD), short sha
  local sha_short; sha_short="$(git -C "$REPO" rev-parse --short HEAD)"
  local sha_full; sha_full="$(git -C "$REPO" rev-parse HEAD)"

  # Retro-log the SAME commit again, logged with its FULL sha this time —
  # physically last, so LAST_COMMIT reads the full form while SINCE_REF (the
  # newest REVIEWED commit) still resolves to this same, only, commit.
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"retro, full sha"}\n' \
    "$sha_full" >> "$(ledger_path)"

  run status_run
  assert_contains "commit $sha_full)"                # LAST GATE shows the full form as logged
  assert_not_contains "names a different commit than this"
}

# status.sh's own "LAST GATE" line reads the physically-last ledger line
# directly (a separate, correct computation — the last thing LOGGED, not the
# newest thing REVIEWED); once `coverage_anchor()` was fixed to answer the
# latter correctly, the two can disagree for the first time on one screen.
# A fresh G4 round and a fresh, code-blind G8 round independently hit this
# same confusion using only the tool's own output. status.sh now says so.
test_status_explains_when_last_gate_and_the_coverage_anchor_disagree() {
  newrepo
  # Explicit, distinct past dates — real wall-clock commits on a fast machine
  # can tie to the same second, which would make the anchor's tie-break
  # (first-found-in-sha-sort-order) nondeterministic and this test flaky.
  export GIT_AUTHOR_DATE="2020-01-01T10:00:00" GIT_COMMITTER_DATE="2020-01-01T10:00:00"
  printf 'token=earlier\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit A" >/dev/null 2>&1
  _ledger_gate_at                      # real, timely gate on commit A (current HEAD)
  local sha_a; sha_a="$(git -C "$REPO" rev-parse --short HEAD)"

  export GIT_AUTHOR_DATE="2020-01-01T11:00:00" GIT_COMMITTER_DATE="2020-01-01T11:00:00"
  printf 'token=later\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "commit B" >/dev/null 2>&1
  unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  _ledger_gate_at                      # real, timely gate on commit B (new HEAD)
  local sha_b; sha_b="$(git -C "$REPO" rev-parse --short HEAD)"

  # Retro-log: backfill a gate entry for the OLDER commit A, appended LAST.
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"%s","outcome":"pass","findings":0,"note":"retro"}\n' \
    "$sha_a" >> "$(ledger_path)"

  run status_run
  assert_contains "LAST GATE"
  assert_contains "commit $sha_a)"                       # LAST GATE: still the physically-last logged entry (A)
  assert_contains "since the last gated commit ($sha_b)" # anchor: still the newer, really-reviewed commit (B)
  assert_contains "names a different commit than this"   # the disagreement must be explained, not silent
}

# The common case — no retro-logging at all — must stay quiet. A note that
# fires unconditionally would train users to ignore it.
test_status_says_nothing_when_last_gate_and_the_anchor_agree() {
  newrepo
  _ledger_gate_at
  run status_run
  assert_not_contains "names a different commit than this"
}

# ================================================================ dashboard
#
# It renders the matrix through the same library the other tools read, so it
# cannot disagree with them about what a tier requires. This checks it still
# runs and still emits every gate the router defines.
# The kit must agree with itself. These checks existed and only ever printed to
# stderr while writing a dashboard anyway, so the loop-diagram drift they now
# catch survived four commits — including one that touched ten files.
test_dashboard_check_passes_on_a_consistent_kit() {
  newrepo
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --check"
  assert_exit 0
  assert_contains "agree"
}

# A drift check that cannot fire is worse than none, so prove it fires. The
# first version of this one silently compared nothing to nothing: under LC_ALL=C
# a bracket expression holding a multibyte box-drawing character matches a
# single byte of it, and the strip that followed ate the whole line.
test_dashboard_check_catches_a_diverged_loop_diagram() {
  newrepo
  # Remove one step from README's loop, leaving 00-start.md's intact.
  sedi '/├─ Package + Deploy/d' "$REPO/.pipeline/README.md"
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --check"
  assert_exit 1
  assert_contains "different steps"
}

# The budget-drift check (dashboard.sh ~line 380) was rewritten in the P2 pass:
# it used to sed "budgetMin" back out of the baked matrix string — a field that
# no longer exists — and now calls matrix_budget() directly, guarded by
# `case "$rb" in ""|0)`. A check that cannot fire is worse than none, so prove
# it still catches the one disagreement it is left to catch: the prose budget
# index in core/02-gates.md drifting from the router. (G5 Proof, 2026-09-04.)
test_dashboard_check_catches_a_drifted_budget_index() {
  newrepo
  # Bump G5's budget in the 02-gates.md prose index only; the router keeps 30m.
  sedi 's/\(\*\*G5 · Proof\*\*.*\)| 30m |/\1| 25m |/' "$REPO/.pipeline/core/02-gates.md"
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --check"
  assert_exit 1 "a budget stated two ways must fail the check"
  assert_contains "G5 budget"
}

test_dashboard_emits_the_router_matrix() {
  newrepo
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --out '$REPO/dash.html'"
  assert_exit 0
  local html="$REPO/dash.html"
  [ -f "$html" ] || html="$REPO/.pipeline/dashboard.html"
  assert_file_contains "$html" '"matrix":'
  # Cells only — "budgetMin" left the model in the 2026-09-01 P2 pass (app.js had
  # no reader left; the shell-side budget-drift check asks matrix_budget()
  # directly now). First: G8's row opens with a tier cell, not "budgetMin".
  assert_file_contains "$html" '"G8":{"T0":'
  # Second: a gate object closes cleanly on its last cell (matches G1/G4/G8's
  # "T4":"M" tail — a valid-serialization smoke check, not G8-specific).
  assert_file_contains "$html" '"T4":"M"}'
}

# `parse_matrix()` reaches every matrix_* call through its own "for g in
# $(matrix_gates)" loop -- a command substitution that forks a subshell and
# discards the subshell's own exit status the instant only its stdout is
# captured. dashboard.sh's own early guard (`[ -f "$ROUTER" ]`) only checks
# that the file EXISTS, not that it parses -- so a router present but
# otherwise unreadable (empty, no gate rows) sailed past that guard and then
# silently produced an empty `"matrix":{}` instead of a refusal, identical to
# the shape already fixed in ledger.sh/reconcile.sh (chip task_8338372f).
test_dashboard_refuses_when_the_router_fails_to_parse() {
  newrepo
  printf '# not a real router, no gate rows\n' > "$REPO/.pipeline/core/01-router.md"
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --out '$REPO/dash.html'"
  assert_exit 2 "a router present but unparseable must refuse, not silently emit an empty matrix"
  assert_contains "gate matrix failed to load"
  [ -f "$REPO/dash.html" ] && _fail "dashboard.sh must not write a page it never trusted"
}

# parse_matrix() in tools/dashboard.sh builds the matrix JSON by hand — an
# inter-gate comma and a per-cell `sep`, both placed by string concatenation
# (rewritten in the 2026-09-01 P2 pass, which also dropped the "budgetMin"
# field). The row-shape asserts above are substring checks: a missing comma
# between two gate objects, or a dropped closing brace, leaves them green while
# making the model invalid JSON — which breaks the page's `const PIPELINE = {…}`
# parse at load. Validate the whole emitted model parses and that every router
# gate carries a full T0..T4 row. (G5 Proof, 2026-09-04.)
test_dashboard_model_matrix_is_valid_json() {
  newrepo
  [ -n "$PY" ] || { _skip "no python — cannot validate the model JSON"; return; }
  run _cov_model
  assert_exit 0
  printf '%s\n' "$LAST_OUT" > "$REPO/model.json"
  run "$PY" -c '
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
mx = m["matrix"]
gates = list(mx)
assert len(gates) >= 8, "expected >=8 gate rows, got %r" % gates
for g, row in mx.items():
    assert list(row) == ["T0", "T1", "T2", "T3", "T4"], "%s row keys %r" % (g, list(row))
    assert all(isinstance(v, str) and v != "" for v in row.values()), "%s empty cell %r" % (g, row)
' "$REPO/model.json"
  assert_exit 0 "dashboard.sh --print-model did not emit valid, fully-shaped matrix JSON"
}

# R-005 — app.js has no git access, so tools/dashboard.sh resolves the repo's
# real default branch and bakes it into the model. changeIsBranchy() reads it
# from PIPELINE.defaultBranch. A repo whose trunk is `prod` must carry
# "defaultBranch":"prod"; a repo where git resolves nothing carries "".
test_dashboard_model_carries_the_computed_default_branch() {
  newrepo
  git -C "$REPO" update-ref refs/remotes/origin/prod HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/prod
  run _cov_model
  assert_exit 0
  assert_contains '"defaultBranch":"prod"'
}

test_dashboard_model_default_branch_is_empty_when_git_resolves_nothing() {
  newrepo
  git -C "$REPO" config init.defaultBranch ""   # no remote, config pinned empty
  run _cov_model
  assert_exit 0
  assert_contains '"defaultBranch":""'
}

# End to end: the generated page carries it, so changeIsBranchy() can read it live.
test_dashboard_page_carries_the_computed_default_branch() {
  newrepo
  _ledger_gate_at
  git -C "$REPO" update-ref refs/remotes/origin/prod HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/prod
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --ledger .pipeline/ledger.jsonl --out .pipeline/dashboard.html"
  assert_exit 0
  assert_file_contains "$REPO/.pipeline/dashboard.html" '"defaultBranch":"prod"'
}

# `init.defaultBranch` is a plain config string, not validated as a refname on
# read — `resolve_default_branch()` returns it verbatim into the model. It must
# go through json_escape + the whole-MODEL escape_payload, the same defence the
# KIT_ID / VERSION-quote finding established (G7 round 1/2, 2026-09-01/06). A
# `"` must not inject a sibling PIPELINE key; a `</script>` must not close the
# page's own <script>. G7 verified this by hand at round 2; this pins it.
test_dashboard_default_branch_hostile_value_is_escaped_in_the_page() {
  newrepo
  _ledger_gate_at
  git -C "$REPO" config init.defaultBranch 'prodX</script><img src=x onerror=alert(1)>","evilKey":"pwned'
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --ledger .pipeline/ledger.jsonl --out .pipeline/dashboard.html"
  assert_exit 0
  local html="$REPO/.pipeline/dashboard.html"
  # The only un-escaped </script> in the file is the page's own closing tag.
  local raw; raw=$(grep -o -i '</script' "$html" | wc -l | tr -d ' ')
  assert_eq "1" "$raw" "un-escaped </script from the branch name survived into the page"
  # The escaped form is what our payload became.
  assert_file_contains "$html" '<\/script'
  # The quote did not break the JSON string and inject a sibling key.
  assert_not_file_contains "$html" '"evilKey":"pwned"'
  # The model still parses and still carries the (escaped) key.
  assert_file_contains "$html" '"defaultBranch":"prodX'
}

# Live mode fetches src.fetchPath — the ledger relative to the PAGE's
# directory, not the CWD dashboard.sh ran in. In the documented install both
# the page (.pipeline/dashboard.html) and the ledger (.pipeline/ledger.jsonl)
# are named relative to the project root, so a naive bake of ".pipeline/
# ledger.jsonl" resolves against the page URL to .pipeline/.pipeline/... and
# 404s — live mode then silently never leaves "Snapshot". This pins that the
# baked fetchPath is what a browser can actually reach from the page.
test_dashboard_bakes_a_page_relative_fetch_path() {
  newrepo
  _ledger_gate_at
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --ledger .pipeline/ledger.jsonl --out .pipeline/dashboard.html"
  assert_exit 0
  local html="$REPO/.pipeline/dashboard.html"
  assert_file_contains "$html" '"fetchPath":"ledger.jsonl"'
  # and NOT the CWD-relative form that would double the prefix
  grep -q '"fetchPath":".pipeline/ledger.jsonl"' "$html" \
    && _fail "fetchPath was baked relative to the CWD, not the page — live mode will 404" || _ok
}

# _relpath's absolute test only matched POSIX /... , so a Windows drive-letter
# path (D:/...) was treated as relative — `cwd/D:/...` never shared a prefix
# with the other side and fetchPath came out `../../../...`, an off-origin
# reference (G4 Ripple + G7). With both paths in drive-letter form they must
# still resolve to the sibling filename. (Needs cygpath to name the drive
# form; skips loudly without it rather than asserting nothing.)
test_dashboard_fetch_path_handles_a_drive_letter_path() {
  newrepo
  _ledger_gate_at
  command -v cygpath >/dev/null 2>&1 || { _skip "no cygpath — cannot construct a drive-letter path"; return; }
  local w; w="$(cygpath -m "$REPO" 2>/dev/null)"
  [ -n "$w" ] || { _skip "cygpath produced nothing"; return; }
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --ledger '$w/.pipeline/ledger.jsonl' --out '$w/.pipeline/dashboard.html'"
  assert_exit 0
  assert_file_contains "$REPO/.pipeline/dashboard.html" '"fetchPath":"ledger.jsonl"'
  grep -q '"fetchPath":"\.\./\|"fetchPath":"/' "$REPO/.pipeline/dashboard.html" \
    && _fail "fetchPath escaped the page directory for a drive-letter path" || _ok
}

# _relpath compares two absolutised paths segment by segment, so every segment
# it compares has to be a real directory name. `..` was left in place, which
# made `--out ../elsewhere/dash.html` diverge from the ledger at the `..`
# itself: the walk emitted one `../` per remaining BASE segment — including the
# `..` — and the reference climbed from a directory the page does not live in.
# Silent, and the exact symptom fetchPath exists to remove: live mode 404s and
# never leaves "Snapshot". (G6, 2026-09-02.)
test_dashboard_fetch_path_resolves_dotdot_in_the_out_path() {
  newrepo
  _ledger_gate_at
  mkdir -p "$REPO/site"
  run bash -c "cd '$REPO/.pipeline' && bash tools/dashboard.sh --ledger ledger.jsonl --out ../site/dash.html"
  assert_exit 0
  local html="$REPO/site/dash.html"
  # from $REPO/site, the ledger at $REPO/.pipeline/ledger.jsonl is one up
  assert_file_contains "$html" '"fetchPath":"../.pipeline/ledger.jsonl"'
}

# The fetchPath is spliced into src's JSON. An early version used
# `${src/#\{/$rep}`, and bash pattern-substitution treats `&` in the
# replacement as the matched text (and eats a `\\` pair) — so a ledger path
# with an `&` in it produced corrupt JSON and a blank page. This pins the
# splice against that.
test_dashboard_fetch_path_survives_an_ampersand_in_the_path() {
  newrepo
  local weird="$REPO/a & b"
  mkdir -p "$weird"
  _ledger_gate_at
  cp "$(ledger_path)" "$weird/ledger.jsonl"
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --ledger 'a & b/ledger.jsonl' --out 'a & b/dash.html'"
  assert_exit 0
  local html="$weird/dash.html"
  assert_file_contains "$html" '"fetchPath":"ledger.jsonl"'
  # the payload must still be parseable JSON — a mangled brace/escape shows up
  # as the app finding zero sources
  assert_file_contains "$html" '"path":"a & b/ledger.jsonl"'
}

# escape_payload() is the ONE thing standing between an untrusted ledger note
# (or a git commit subject, which reaches the Coverage rows) and the end of this
# page's own <script> element. It rewrote only the lowercase "</script" — but
# HTML's script-data end-tag matching is ASCII CASE-INSENSITIVE, so "</SCRIPT>"
# closed the element just as well and everything after it was parsed as markup.
# That breaks out at GENERATION time, upstream of every escapeHtml() in app.js,
# and it fires on file:// too. Found by G7 round 2 against d25a867; this test
# fails against that sha. All three spellings, because the fix is a character
# class and a mixed-case one is what proves it is not just a second literal.
test_dashboard_payload_escaping_is_case_insensitive() {
  newrepo
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"outcome":"pass","findings":0,"note":"lower </script><img src=x> UPPER </SCRIPT><img src=y> mixed </ScRiPt><img src=z>"}\n' \
    >> "$(ledger_path)"
  run bash -c "cd '$REPO' && bash .pipeline/tools/dashboard.sh --ledger .pipeline/ledger.jsonl --out .pipeline/dashboard.html"
  assert_exit 0
  local html="$REPO/.pipeline/dashboard.html"
  # Exactly one un-escaped script close may exist in the whole file: the page's
  # own closing tag. Every spelling from the note must carry the backslash.
  # An escaped one reads "<\/script", which does not contain "</script" — so a
  # plain count of the un-escaped spelling is the whole assertion.
  local raw esc
  raw=$(grep -o -i '</script' "$html" | wc -l | tr -d ' ')
  esc=$(grep -o -i '<\\/script' "$html" | wc -l | tr -d ' ')
  if [ "$raw" -eq 1 ] && [ "$esc" -eq 3 ]; then _ok
  else _fail "script-closes from the ledger note survived un-escaped ($raw un-escaped, expected 1 — the page's own tag; $esc escaped, expected 3)"; fi
  # and the note still READS the way it was written, in its original case —
  # the fix escapes the slash, it does not lowercase the payload
  assert_file_contains "$html" '<\/SCRIPT'
  assert_file_contains "$html" '<\/ScRiPt'
}

# The 3 checks above only ever grep GENERATED HTML for static strings/
# structure — none of them execute app.js's client-side status logic. That
# gap is exactly how two real bugs in computeStatus()/buildExecutions()
# shipped invisibly: a same-round fail-then-corrected-to-pass permanently
# tripped the top-level status to "Failed" (anyFail never un-set), and a
# gate that genuinely passed in round 1 rendered in round 2 as "should have
# reviewed this, but didn't" (rounds did not carry forward). This runs
# tests/dashboard-logic.test.js under node, which requires app.js directly
# and exercises computeStatus/buildExecutions against crafted ledger
# fixtures — see that file for exactly what it proves, and the fix's commit
# for the discrimination proof (fails against the old logic, passes against
# the new). Skips loudly when no JS runtime is present, same idiom as
# assert_jsonl_valid does for python — never a silent weakening.
test_dashboard_logic_js_unit_tests() {
  [ -n "$NODE" ] || { _skip "no node — cannot run tests/dashboard-logic.test.js"; return; }
  run "$NODE" "$KIT/tests/dashboard-logic.test.js"
  assert_exit 0
  assert_contains "all dashboard logic tests passed"
}

# ================================================================ mine-registry
#
# The install's step 2. Its documented answer for a young repo is "you get
# nothing, and that is correct" — inventing couplings is the failure mode.
test_mine_registry_is_graceful_on_a_young_repo() {
  newrepo
  run bash -c "cd '$REPO' && bash .pipeline/tools/mine-registry.sh '$REPO/draft.md'"
  assert_exit 0
  assert_contains "Not enough history to mine"
}

# E7: the draft belongs INSIDE the install (.pipeline/project), not at the repo root,
# or the next step's `cp -r templates/project` nests into project/project.
test_mine_registry_default_output_lands_inside_the_kit() {
  newrepo
  # Two fix commits touching the same pair: enough history that the miner WRITES (on the
  # fixture's single commit it exits at "Not enough history" before any write, so a test
  # on that cannot tell where the default output goes -- G5 round 1).
  local i
  for i in 1 2; do
    printf 'v%s\n' "$i" > "$REPO/src/a.js"; printf 'v%s\n' "$i" > "$REPO/src/b.js"
    git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "fix: a and b together ($i)" >/dev/null 2>&1
  done
  run bash -c "cd '$REPO' && bash .pipeline/tools/mine-registry.sh"
  assert_exit 0
  [ -f "$REPO/.pipeline/project/registry-draft.md" ] && _ok || _fail "draft not written inside .pipeline/project"
  [ ! -e "$REPO/project" ] && _ok || _fail "wrote ./project at the repo root"
}

# E5, revised in round 10: the ledger is NOT union-merged. Union made a verdict depend on merge
# direction (R-008); a conflict is the signal that two branches logged the same change.
test_gitattributes_does_not_union_merge_the_ledger() {
  local ga
  for ga in "$KIT/.gitattributes" "$KIT"/*/.gitattributes; do
    [ -f "$ga" ] || continue
    grep -q '^ledger\.jsonl[[:space:]].*merge=union' "$ga" && _fail "$ga still union-merges ledger.jsonl" || _ok
  done
  grep -q "merge=union" "$KIT/README.md" && grep -q "echo '.pipeline/ledger.jsonl merge=union'" "$KIT/README.md" && _fail "README still tells installs to union-merge the ledger" || _ok
}

# E8: inputs that used to be swallowed silently.
test_reconcile_refuses_unknown_flag() {
  newrepo
  run rec T1 --bogus
  assert_exit 2 "an unknown flag must not be ignored"
  assert_contains "unknown option '--bogus'"
}

test_reconcile_round_flag_is_honoured() {
  newrepo
  echo 'x' > "$REPO/src/app.js"
  CHANGE=c run rec T4 --log --round 3
  assert_file_contains "$(ledger_path)" '"round":3'
}

test_ledger_escape_refuses_unknown_found_by() {
  newrepo
  run led escape --change c --found-by nobody
  assert_exit 2 "found-by is a closed set"
  assert_contains "REFUSED"
}

test_ledger_add_warns_on_gate_not_in_router() {
  newrepo
  run led add --confidence fresh --change c --gate G99 --tier T3 --outcome pass
  assert_exit 0 "an authored gate stays legal"
  assert_contains "not a gate in the router table"
}

# G6 r10 (blocking): a declared action recurs once per event. reconcile.sh always sends --base and
# defaults the round to 1, so the second firing after the base moved was refused and never recorded.
test_a_declared_action_can_fire_again_after_the_base_moved() {
  newrepo
  ( cd "$REPO" && BASE="$BASE_SHA" bash .pipeline/tools/reconcile.sh --action store-publish \
      --evidence "https://example.test/1" --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  led add --change store-publish --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m moved
  local b; b="$(git -C "$REPO" rev-parse HEAD)"
  ( cd "$REPO" && BASE="$b" bash .pipeline/tools/reconcile.sh --action store-publish \
      --evidence "https://example.test/2" --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  assert_eq "0" "$?" "the second firing of the same action after the base moved must be recorded"
  assert_eq "2" "$(grep -c '"action":"store-publish"' "$(ledger_path)")" "both declarations are in the ledger"
  # G1 r11 (blocking): the second firing is a NEW event, so the first event's passes must not count for it.
  run led compliance --change store-publish --tier T4
  assert_row "NOT RUN" "G4"
  assert_not_contains "merged branches"
  # ... while an ordinary change keeps the refusal
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$b"
  assert_exit 2 "a plain change still refuses a round-1 route with a different base"
}

# G8 r10 (blocking): `skipped` is the absence of a verdict; it must not reset the unrouted-work anchor.
test_a_skipped_gate_row_does_not_reset_the_unrouted_work_anchor() {
  newrepo
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  mkdir -p "$REPO/src/auth"; printf 'x\n' > "$REPO/src/auth/login.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "auth work" >/dev/null 2>&1
  local head; head="$(git -C "$REPO" rev-parse HEAD)"
  run status_run
  assert_contains "1 commit(s) since the last gated commit"
  led add --change c --gate G2 --tier T2 --round 1 --outcome skipped --note "no time" --commit "$head" >/dev/null 2>&1
  led add --change other --gate G2 --tier T1 --round 1 --outcome n/a --note "n/a" --commit "$head" >/dev/null 2>&1
  run status_run
  assert_contains "1 commit(s) since the last gated commit"
  assert_contains "auth work"
  # the LAST GATE line must still name the last VERDICT (change c), not the n/a row of "other"
  assert_not_contains "— other (commit"
}

# G4 r10: an absurdly long --round is refused cleanly, not with a raw shell "integer expected" error.
test_an_oversized_round_is_refused_cleanly() {
  newrepo
  run led add --change c --gate G1 --tier T1 --round 99999999999999999999 --outcome pass --confidence fresh --model m
  assert_exit 2
  assert_not_contains "integer expected"
  assert_not_contains "rounds start at 1"
}

# G7 r11 (blocking): "after" is position in the ledger, not round number. A fail logged with --round
# forgotten (it defaults to 1) after a round-2 pass used to be ignored and the gate read PASS.
test_a_fail_logged_after_a_pass_at_a_lower_round_still_voids_it() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --outcome fail --confidence fresh --model m --commit "$BASE_SHA" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_row "FAIL" "G4"
}

# G6 r11 (blocking): status was run while the kit was untracked (which pins the cutoff), project work
# was committed, THEN the kit was committed. The pin was dropped at that point and the work in between
# stopped counting.
test_work_committed_between_the_first_check_and_the_kit_commit_still_counts() {
  local r="$TMPROOT/pinthen.$$"
  rm -rf "$r"; mkdir -p "$r/src/auth"
  git -C "$r" init -q; git -C "$r" config user.email t@e; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.autocrlf false
  printf 'one\n' > "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm one >/dev/null 2>&1
  mkdir -p "$r/.pipeline"; cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$r/.pipeline/"
  cp "$KIT/templates/project/surfaces.conf" "$r/.pipeline/project/surfaces.conf"
  ( cd "$r" && bash .pipeline/tools/status.sh >/dev/null 2>&1 )
  printf 'login\n' > "$r/src/auth/login.js"
  git -C "$r" add src >/dev/null 2>&1; git -C "$r" commit -qm "unreviewed auth work" >/dev/null 2>&1
  git -C "$r" add .pipeline >/dev/null 2>&1; git -C "$r" commit -qm "add kit" >/dev/null 2>&1
  run bash -c "cd '$r' && bash .pipeline/tools/status.sh"
  assert_contains "unreviewed auth work"
  assert_contains "2 commit(s)"
  assert_not_contains "carries project work"
  # ... while the ordinary flow (status, then the kit committed on its own, no work between) stays at 0
  local q="$TMPROOT/pinclean.$$"
  rm -rf "$q"; mkdir -p "$q"
  git -C "$q" init -q; git -C "$q" config user.email t@e; git -C "$q" config user.name t
  git -C "$q" config commit.gpgsign false; git -C "$q" config core.autocrlf false
  printf 'one\n' > "$q/README.md"; git -C "$q" add -A >/dev/null 2>&1; git -C "$q" commit -qm one >/dev/null 2>&1
  mkdir -p "$q/.pipeline"; cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$q/.pipeline/"
  ( cd "$q" && bash .pipeline/tools/status.sh >/dev/null 2>&1 )
  git -C "$q" add .pipeline >/dev/null 2>&1; git -C "$q" commit -qm "add kit" >/dev/null 2>&1
  run bash -c "cd '$q' && bash .pipeline/tools/status.sh"
  assert_contains "0 commit(s)"
}

# G8 r11 (blocking): the README's own two-branch flow. Two branches, each gated on its own, merged: no
# single gated commit is the newest. status must say so, not "ledger names commit X, not found in this repo".
test_gated_commits_on_two_merged_branches_are_not_called_missing() {
  newrepo
  git -C "$REPO" checkout -q -b fa >/dev/null 2>&1
  printf 'a\n' > "$REPO/src/auth/a.js"; git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "feature a" >/dev/null 2>&1
  local a; a="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" checkout -q -b fb >/dev/null 2>&1
  printf 'b\n' > "$REPO/src/auth/b.js"; git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "feature b" >/dev/null 2>&1
  local b; b="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" merge -q --no-ff -m "merge a" "$a" >/dev/null 2>&1
  led add --change fa --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$a" >/dev/null 2>&1
  led add --change fb --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$b" >/dev/null 2>&1
  run status_run
  # G8 r12 (blocking): both gated tips are anchors; nothing they contain is unrouted.
  assert_exit 0 "two branches gated and merged leave nothing unrouted"
  assert_not_contains "not found in this repo"
  assert_not_contains "never re-gated"
  assert_contains "two lines of history"
  # ... and a commit made AFTER the merge is still counted, from both anchors
  printf 'c\n' > "$REPO/src/auth/c.js"; git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "after the merge" >/dev/null 2>&1
  run status_run
  assert_exit 1 "new T4 work after the merge is unrouted"
  assert_contains "after the merge"
  assert_not_contains "feature a"
}

# G5 r11 (blocking): rev-parse resolves ref NAMES before abbreviated shas, so a tag or branch with a
# hex-looking name that a report mentions counted as review evidence. The token must prefix the sha.
test_hook_does_not_count_a_hex_named_tag_as_review_evidence() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/existing.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  git -C "$REPO" tag deadbee1 >/dev/null 2>&1
  mkdir -p "$REPO/.pipeline/security-reports"
  printf 'reviewed deadbee1 thoroughly\n' > "$REPO/.pipeline/security-reports/g7.md"
  run hook
  assert_exit 1 "a report naming only a hex-looking tag is not evidence about that commit"
  # ... while an abbreviated real sha still is
  local abbr; abbr="$(git -C "$REPO" rev-parse --short=9 HEAD)"
  printf 'reviewed %s thoroughly\n' "$abbr" > "$REPO/.pipeline/security-reports/g7.md"
  run hook
  assert_exit 0 "a 9-character abbreviation of the real sha still counts"
}

# G7/G4/G1 r12 (blocking): one lineage per EVENT. reconcile.sh computes merge-base(BASE, HEAD), which does
# not move across new local commits, so a redeploy arrives with the SAME base.
test_a_declared_action_fired_again_at_the_same_base_is_a_new_event() {
  newrepo
  ( cd "$REPO" && BASE="$BASE_SHA" bash .pipeline/tools/reconcile.sh --action store-publish \
      --evidence "https://example.test/1" --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  led add --change store-publish --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  ( cd "$REPO" && BASE="$BASE_SHA" bash .pipeline/tools/reconcile.sh --action store-publish \
      --evidence "https://example.test/2" --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  assert_eq "0" "$?" "a second firing at the same base is accepted"
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the second firing (and only it) is marked a restart"
  run led compliance --change store-publish --tier T4
  assert_row "NOT RUN" "G4"
}

# G6 r12 (blocking): a later `n/a` must not clear a FAIL on a gate that never passed.
test_a_later_na_does_not_clear_a_fail_on_a_gate_that_never_passed() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G8 --tier T2 --round 1 --outcome fail --confidence fresh --model m --commit "$BASE_SHA" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G8 --tier T2 --round 2 --outcome n/a --note "does not apply" --model m >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_row "FAIL" "G8"
}

# G5 r12: the FAIL row names the finding count of the fail that governs: the last one by position.
test_the_fail_row_counts_the_findings_of_the_last_fail_by_position() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$BASE_SHA" \
      --finding "blocking::a.sh:1::one" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --outcome fail --confidence fresh --model m --commit "$BASE_SHA" \
      --finding "blocking::a.sh:2::two" --finding "minor::a.sh:3::three" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_contains "G4   Ripple    2 finding(s) logged"
}

# G5 r12: --round is bounded at every site, not only `add`.
test_an_oversized_round_is_refused_at_route_and_compliance() {
  newrepo
  run led route --change c --predicted T2 --actual T2 --round 99999999999999999999 --reason r
  assert_exit 2
  assert_not_contains "integer expected"
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 99999999999999999999
  assert_exit 2
  assert_not_contains "integer expected"
}

# G5 r12: a change name with a quote still finds its own recorded reason (the name is JSON-escaped).
test_a_change_name_with_a_quote_still_finds_its_recorded_reason() {
  newrepo
  # T4: the recorded-reason check applies from T3 up, and only once every mandated gate has passed.
  led route --change 'a"b' --predicted T4 --actual T4 --round 1 --reason "why it exists" --base "$BASE_SHA" >/dev/null 2>&1
  local g
  for g in G1 G4 G5 G6 G7 G8; do
    led add --change 'a"b' --gate $g --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  done
  run led compliance --change 'a"b' --tier T4
  assert_not_contains "no reason recorded"
  assert_contains "All T4-mandated gates satisfied"
}

# G5 r12 (blocking): blob_of must look a path up as itself. Pathspec magic like ":(top)src/auth/x.js" used
# to resolve to the real file; a file literally named that is a different path.
test_blob_of_does_not_read_pathspec_magic() {
  newrepo
  printf 'token=2\n' > "$REPO/src/auth/x.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm c >/dev/null 2>&1
  local fn; fn="$(sed -n '/^blob_of() {/,/^}/p' "$KIT/templates/pre-push")"
  [ -n "$fn" ] || { _fail "blob_of not found in templates/pre-push"; return; }
  run bash -c "cd '$REPO' && $fn
    printf 'real=%s\n' \"\$(blob_of HEAD src/auth/x.js | cut -c1-6)\"
    printf 'magic=%s\n' \"\$(blob_of HEAD ':(top)src/auth/x.js')\""
  assert_contains "real=100644"
  assert_contains "magic=absent"
}

# G6/G4/G1 r12: gated commits that exist but are NOT reachable from HEAD (a branch the gates were logged on,
# or a squash/rebase merge) are a different fact from "two merged lines" and from "not in this repo".
test_gated_commits_not_reachable_from_head_get_an_honest_label() {
  newrepo
  git -C "$REPO" checkout -q -b side >/dev/null 2>&1
  printf 's\n' > "$REPO/src/auth/s.js"; git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "side work" >/dev/null 2>&1
  local s; s="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q "$BASE_SHA" >/dev/null 2>&1
  printf 'm\n' > "$REPO/src/auth/m.js"; git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "main work" >/dev/null 2>&1
  led add --change c --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$s" >/dev/null 2>&1
  run status_run
  assert_contains "none is reachable from HEAD"
  assert_not_contains "not found in this repo"
  # ... and with no baseline in effect (the other label branch)
  run bash -c "cd '$REPO' && BASELINE=none bash .pipeline/tools/status.sh"
  assert_contains "in the whole history — the ledger names gated commits, but none is reachable from HEAD"
  run _cov_model
  assert_contains '"anchorInRepo":true'
  assert_contains '"anchor":""'
}

# G8 r12 (blocking): the kit's own files are not project work. `.pipeline/tools/lib/*.sh` matches an ordinary
# `lib/` rule, so a kit commit of its own (README step 6) was listed as T3 work and status exited 1.
test_the_kits_own_install_commit_is_not_listed_as_unrouted_work() {
  local r="$TMPROOT/kitown.$$"
  rm -rf "$r"; mkdir -p "$r/.pipeline"
  git -C "$r" init -q; git -C "$r" config user.email t@e; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.autocrlf false
  printf 'one\n' > "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm one >/dev/null 2>&1
  cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$r/.pipeline/"
  cp "$KIT/templates/project/surfaces.conf" "$r/.pipeline/project/surfaces.conf"
  printf 'T3::(^|/)lib/::shared library\n' >> "$r/.pipeline/project/surfaces.conf"
  ( cd "$r" && bash .pipeline/tools/status.sh >/dev/null 2>&1 )
  # real work before the kit is committed puts the kit commit inside the counted range (the pin is used)
  printf 'two\n' >> "$r/README.md"; git -C "$r" add README.md >/dev/null 2>&1; git -C "$r" commit -qm "readme tweak" >/dev/null 2>&1
  git -C "$r" add .pipeline >/dev/null 2>&1; git -C "$r" commit -qm "add kit" >/dev/null 2>&1
  run bash -c "cd '$r' && bash .pipeline/tools/status.sh"
  assert_not_contains "never re-gated"
  assert_not_contains "add kit"
  # ... and INCLUDE_KIT=1 (as for reconcile.sh) puts it back
  run bash -c "cd '$r' && INCLUDE_KIT=1 bash .pipeline/tools/status.sh"
  assert_contains "add kit"
}

# G5 r12: a pin that is not a strict ancestor of the install commit's parent must not be used (it could
# only hide work), and the pin still counts more when real work sits before the kit commit.
test_a_pin_naming_a_later_commit_is_ignored_once_the_kit_is_committed() {
  local r="$TMPROOT/pinlate.$$"
  rm -rf "$r"; mkdir -p "$r/.pipeline" "$r/src/auth"
  git -C "$r" init -q; git -C "$r" config user.email t@e; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.autocrlf false
  printf 'one\n' > "$r/README.md"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm one >/dev/null 2>&1
  cp -r "$KIT/tools" "$KIT/project" "$KIT/core" "$KIT/templates" "$r/.pipeline/"
  cp "$KIT/templates/project/surfaces.conf" "$r/.pipeline/project/surfaces.conf"
  ( cd "$r" && bash .pipeline/tools/status.sh >/dev/null 2>&1 )
  git -C "$r" add .pipeline >/dev/null 2>&1; git -C "$r" commit -qm "add kit" >/dev/null 2>&1
  printf 'x\n' > "$r/src/auth/x.js"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm "auth after the kit" >/dev/null 2>&1
  git -C "$r" rev-parse HEAD > "$r/.pipeline/.install-base"
  run bash -c "cd '$r' && bash .pipeline/tools/status.sh"
  assert_contains "auth after the kit"
  assert_contains "1 commit(s)"
}

# G5 r12: coverage_claimed_anchor, like the anchor, ignores skipped and n/a rows.
test_the_claimed_anchor_ignores_skipped_and_na_rows() {
  newrepo
  local l; l="$(ledger_path)"
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"aaaaaaa","outcome":"skipped","findings":0}\n' > "$l"
  run bash -c "cd '$REPO' && . .pipeline/tools/lib/coverage.sh && coverage_claimed_anchor '$l'"
  assert_eq "" "$LAST_OUT" "a ledger of only skipped rows claims no anchor"
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"bbbbbbb","outcome":"pass","findings":0}\n' >> "$l"
  printf '{"type":"gate","date":"2026-08-14","change":"c","tier":"T4","gate":"G7","round":1,"commit":"ccccccc","outcome":"n/a","findings":0}\n' >> "$l"
  run bash -c "cd '$REPO' && . .pipeline/tools/lib/coverage.sh && coverage_claimed_anchor '$l'"
  assert_eq "bbbbbbb" "$LAST_OUT" "the last row WITH A VERDICT is the claimed anchor"
}

# G8 r12: BASELINE that names nothing says so; BASELINE=none reads sensibly.
test_status_says_when_a_baseline_names_nothing() {
  newrepo
  run bash -c "cd '$REPO' && BASELINE=nonexistent123 bash .pipeline/tools/status.sh"
  assert_contains "BASELINE='nonexistent123' is not a commit in this repository"
  run bash -c "cd '$REPO' && BASELINE=none bash .pipeline/tools/status.sh"
  assert_contains "in the whole history"
  assert_not_contains "is not a commit in this repository"
}

# G7 r13 (blocking): a firing is an EVENT, always recorded as round 1. At --round 2 (the knob the refusal
# text offers for follow-ups) it used to skip the restart and the first event's passes carried forward.
test_a_declared_action_fired_at_round_two_is_still_a_new_event() {
  newrepo
  ( cd "$REPO" && BASE="$BASE_SHA" bash .pipeline/tools/reconcile.sh --action store-publish \
      --evidence "https://example.test/1" --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  led add --change store-publish --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "fix before the second deploy"
  run bash -c "cd '$REPO' && ROUND=2 BASE='$BASE_SHA' bash .pipeline/tools/reconcile.sh --action store-publish --evidence https://example.test/2 --log --ledger '$(ledger_path)'"
  assert_contains "recorded as round 1"
  assert_eq "2" "$(grep '"action":"store-publish"' "$(ledger_path)" | grep -c '"round":1,')" "both firings are round-1 rows"
  run led compliance --change store-publish --tier T4
  assert_row "NOT RUN" "G4"
}

# G4 r13: only a REPEAT of the same action restarts on its own; a diff change later fired with --action
# keeps the ordinary refusal for a round-1 route with a different base.
test_the_first_action_firing_on_a_diff_change_still_gets_the_refusal() {
  newrepo
  led route --change feat --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m moved
  local b; b="$(git -C "$REPO" rev-parse HEAD)"
  run led route --change feat --predicted T4 --actual T4 --round 1 --reason r --base "$b" --action prod-deploy --evidence https://example.test/1
  assert_exit 2 "an action's first firing does not bypass the restart refusal of a diff change"
}

# G1/G8 r13: leaving --round off while the change is already past round 1 says so.
test_add_without_round_says_so_when_the_change_is_past_round_one() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led add --change c --gate G4 --tier T2 --outcome pass --confidence fresh --model m
  assert_contains "no --round given"
  assert_contains "has a route at round 2"
  run led add --change c --gate G5 --tier T2 --round 2 --outcome pass --confidence fresh --model m
  assert_not_contains "no --round given"
}

# G5 r13: the Recommended-here section follows the same rule as the verdict.
test_recommended_here_follows_the_position_rule() {
  newrepo
  led route --change c --predicted T3 --actual T3 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G2 --tier T3 --round 2 --outcome fail --confidence fresh --model m --commit "$BASE_SHA" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  run led compliance --change c --tier T3 --round 2
  assert_contains "LOGGED G2"
  assert_contains "fail — 1 finding(s) recorded"
  led add --change c --gate G2 --tier T3 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G2 --tier T3 --round 2 --outcome n/a --note "no" --model m >/dev/null 2>&1
  run led compliance --change c --tier T3 --round 2
  assert_contains "LOGGED G2"
  assert_contains "pass recorded"
  # a fail logged LATER at a LOWER round than an earlier pass still shows as the fail (G3, recommended at T3)
  led add --change c --gate G3 --tier T3 --round 2 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G3 --tier T3 --outcome fail --confidence fresh --model m --commit "$BASE_SHA" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  run led compliance --change c --tier T3 --round 2
  assert_contains "LOGGED G3"
  assert_contains "fail — 1 finding(s) recorded"
}

# G5 r13: --round is bounded at `assume` too.
test_an_oversized_round_is_refused_at_assume() {
  newrepo
  run led assume --change c --assumed x --resolution defaulted --round 99999999999999999999
  assert_exit 2
  assert_not_contains "integer expected"
}

# G8 r13: rows that cost nothing do not print the --tokens nag.
test_skipped_and_na_rows_do_not_nag_about_tokens() {
  newrepo
  run led add --change c --gate G2 --tier T3 --outcome skipped --note x --model m
  assert_not_contains "no --tokens recorded"
  run led add --change c --gate G4 --tier T3 --outcome pass --confidence fresh --model m
  assert_contains "no --tokens recorded"
}

# G6 r13: an explicit --restart-lineage is honoured even when the base has not moved.
test_an_explicit_restart_lineage_is_honoured_at_the_same_base() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" --restart-lineage >/dev/null 2>&1
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the explicit flag writes the restart marker"
  run led compliance --change c --tier T2
  assert_row "NOT RUN" "G4"
}

# G4 r14 (blocking): the first firing of a declared action on a change that so far has only diff routes is a
# follow-up of that work: it keeps the round it was given, so the refusal's --round 2 advice works.
test_the_first_action_firing_on_a_diff_change_accepts_round_two() {
  newrepo
  led route --change feat --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m moved
  local b; b="$(git -C "$REPO" rev-parse HEAD)"
  run led route --change feat --predicted T4 --actual T4 --round 2 --reason r --base "$b" --action prod-deploy --evidence https://example.test/1
  assert_exit 0 "an action's first firing at round 2 is a follow-up and is recorded"
  assert_not_contains "--round 2 ignored"
  assert_eq "1" "$(grep -c '"action":"prod-deploy"' "$(ledger_path)")" "the route was written"
  assert_eq "1" "$(grep '"action":"prod-deploy"' "$(ledger_path)" | grep -c '"round":2,')" "at the round it was given"
  assert_eq "0" "$(grep -c '"restart":true' "$(ledger_path)")" "and it is not a restart"
}

# G1/G7 r14: ANY second firing is a new event, whatever the action is called.
test_a_different_action_on_the_same_change_starts_its_own_lineage() {
  newrepo
  led route --change release --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" --action rollout-ramp --evidence u1 >/dev/null 2>&1
  led add --change release --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "unreviewed"
  local b; b="$(git -C "$REPO" rev-parse HEAD)"
  run led route --change release --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" --commit "$b" --action store-publish --evidence u2
  assert_exit 0
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the second, different action restarts"
  run led compliance --change release --tier T4
  assert_row "NOT RUN" "G4"
}

# G7 r14 (blocking): the pass that CLEARS a fail must be bound to the change. A round-1 pass logged last,
# at a commit outside the change, used to clear a round-2 fail: the binding check looked at the
# highest-round pass (the bound round-2 one) instead of the pass that governs.
test_a_pass_outside_the_change_does_not_clear_a_fail() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_contains "UNBOUND    G4"
  assert_not_contains "PASS       G4"
  # control: the same re-run logged on the change's own commit does clear it
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_not_contains "UNBOUND    G4"
}

# G1/G4/G6 r14: the --round note names the CURRENT lineage's round, not one a restart closed.
test_the_add_round_note_is_scoped_to_the_current_lineage() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 3 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" --restart-lineage >/dev/null 2>&1
  run led add --change c --gate G4 --tier T2 --outcome pass --confidence fresh --model m --tokens 1
  assert_not_contains "has a route at round 3"
}

# G5 r14: the n/a exclusion from the --tokens note is its own condition.
test_an_na_row_does_not_nag_about_tokens() {
  newrepo
  run led add --change c --gate G2 --tier T3 --outcome n/a --note "not applicable here" --model m
  assert_not_contains "no --tokens recorded"
}

# G1/G4 r15 (blocking): with a fail in the lineage the HIGHEST-round pass must stay bound as well as the pass
# that cleared the fail. fail r1 at tip, pass r1 at tip, pass r2 outside used to read PASS (and UNBOUND without
# the fail): an earlier fail made compliance more lenient.
test_a_higher_round_pass_outside_the_change_stays_unbound_after_a_cleared_fail() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  led add --change c --gate G4 --tier T2 --round 1 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_contains "UNBOUND    G4"
  assert_contains "pass at round 2 was logged at $outside"
  assert_not_contains "PASS       G4"
}

# G5 r15: the UNBOUND line names the round of the pass whose commit it prints.
test_the_unbound_line_names_the_round_of_the_pass_it_prints() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_contains "pass at round 1 was logged at $outside"
}

# G5 r15: ANY bound pass after the fail clears it: a stray unbound pass logged after a bound re-run does not undo it.
test_a_stray_pass_after_a_bound_rerun_does_not_unbind_the_gate() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_not_contains "UNBOUND    G4"
  assert_row "PASS" "G4"
}

# G5 r15: a clearing pass that cannot be checked here is a NOTE, not UNBOUND ("unverifiable beats unbound").
test_an_unverifiable_clearing_pass_is_a_note_not_unbound() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip; tip="$(git -C "$REPO" rev-parse HEAD)"
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  _fake_commit deadbee --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m
  run led compliance --change c --tier T2 --round 2
  assert_contains "not checkable here"
  assert_not_contains "UNBOUND    G4"
}

# G5 r15 (blocking): the first firing of a declared action on a change with no routes is round 1, so a repeat
# firing has a round-1 route to restart from. Logged at ROUND=2 it was kept at round 2 and the second firing
# skipped the restart: the first event's passes carried over to an unreviewed deploy.
test_a_first_action_firing_at_round_two_still_lets_the_repeat_restart() {
  newrepo
  run bash -c "cd '$REPO' && ROUND=2 BASE='$BASE_SHA' bash .pipeline/tools/reconcile.sh --action store-publish --evidence https://example.test/1 --log --ledger '$(ledger_path)'"
  assert_contains "recorded as round 1"
  assert_eq "1" "$(grep '"action":"store-publish"' "$(ledger_path)" | grep -c '"round":1,')" "the first firing is round 1"
  led add --change store-publish --gate G4 --tier T4 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "fix before the second deploy"
  ( cd "$REPO" && BASE="$BASE_SHA" bash .pipeline/tools/reconcile.sh --action store-publish \
      --evidence https://example.test/2 --log --ledger "$(ledger_path)" >/dev/null 2>&1 )
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the repeat firing restarts"
  run led compliance --change store-publish --tier T4
  assert_row "NOT RUN" "G4"
}

# G5 r15: the closing hint of an action run names no round (the route is round 1 on a repeat whatever ROUND= said).
test_the_action_hint_names_no_round() {
  newrepo
  run bash -c "cd '$REPO' && ROUND=3 BASE='$BASE_SHA' bash .pipeline/tools/reconcile.sh --action store-publish --evidence https://example.test/1 --ledger '$(ledger_path)'"
  assert_contains "compliance --change \"store-publish\" --tier T4"
  assert_not_contains "--tier T4 --round"
}

# G4 r16 (blocking): a repeat firing restarts the lineage WHATEVER routes the change already has. The first
# firing is kept at round 2 when the change has a diff route (a stale ROUND=2, or a follow-up), so no round-1
# route with a base exists; the repeat used to skip the restart and the first event's passes carried over.
test_a_repeat_firing_restarts_when_the_first_firing_was_kept_at_round_two() {
  newrepo
  led route --change rel --predicted T4 --actual T4 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change rel --predicted T4 --actual T4 --round 2 --reason r --base "$BASE_SHA" --action prod-deploy --evidence u1 >/dev/null 2>&1
  assert_eq "2" "$(grep -c '"round":2,' "$(ledger_path)")" "the first firing is kept at round 2"
  led add --change rel --gate G4 --tier T4 --round 2 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "unreviewed"
  run led route --change rel --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" --action prod-deploy --evidence u2
  assert_exit 0
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the repeat firing carries the restart marker"
  run led compliance --change rel --tier T4
  assert_row "NOT RUN" "G4"
}

# G4 r16: the same with an advisory baseless route first (nothing carries a round-1 base).
test_a_repeat_firing_restarts_after_an_advisory_baseless_route() {
  newrepo
  led route --change rel --predicted T4 --actual T4 --round 1 --reason r >/dev/null 2>&1
  led route --change rel --predicted T4 --actual T4 --round 2 --reason r --base "$BASE_SHA" --action prod-deploy --evidence u1 >/dev/null 2>&1
  led add --change rel --gate G4 --tier T4 --round 2 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  led route --change rel --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" --action prod-deploy --evidence u2 >/dev/null 2>&1
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the repeat firing carries the restart marker"
  run led compliance --change rel --tier T4
  assert_row "NOT RUN" "G4"
}

# G5 r16: the clearing pass's round is parsed from its own row (a round-1 clearing pass cannot tell a parse
# from a constant).
test_the_unbound_line_names_a_clearing_pass_round_other_than_one() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 3 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  led add --change c --gate G4 --tier T2 --round 3 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 3 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 3
  assert_contains "pass at round 2 was logged at $outside"
}

# G4 r17 (blocking): a route with no base is advisory: it must not start a lineage (marked or not), so it
# cannot lower the tier floor the change's based route recorded.
test_a_baseless_repeat_firing_neither_restarts_nor_lowers_the_floor() {
  newrepo
  led route --change x --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" --action prod-deploy --evidence u1 >/dev/null 2>&1
  run led route --change x --predicted T1 --actual T1 --round 1 --reason r --action prod-deploy --evidence u2
  assert_contains "cannot start a new"
  assert_eq "0" "$(grep -c '"restart":true' "$(ledger_path)")" "a baseless route is not marked restart"
  run led compliance --change x --tier T1
  assert_exit 2 "the T4 floor still holds"
  assert_not_contains "mandates no gates"
}

# G4 r17: the lineage rule itself, independent of what cmd_route writes: a hand-written (or merged-in) route with
# no base and a restart marker starts nothing, so it cannot lower the floor.
test_a_hand_written_baseless_marked_route_does_not_start_a_lineage() {
  newrepo
  led route --change x --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  printf '%s\n' '{"type":"route","date":"2026-10-12T00:00:00Z","change":"x","round":1,"predicted":"T1","actual":"T1","verdict":"match","reason":"r","restart":true}' >> "$(ledger_path)"
  run led compliance --change x --tier T1
  assert_exit 2 "the T4 floor still holds"
  assert_not_contains "mandates no gates"
}

# G5 r17 (blocking): unbound beats unverifiable. The highest-round pass cannot be checked here, the pass that
# cleared the fail is outside the change: the gate must read UNBOUND, not PASS with a "not checkable" note.
test_an_unbound_clearing_pass_beats_an_unverifiable_highest_round_pass() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  _fake_commit deadbee --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_contains "UNBOUND    G4"
  assert_contains "pass at round 1 was logged at $outside"
  assert_not_contains "PASS       G4"
}

# G5 r18 (blocking): only the passes logged after the LAST fail can clear it. A mutant that keeps the FIRST fail
# counted a pass logged before the second fail as clearing it.
test_only_passes_after_the_last_fail_count_as_clearing_it() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  led add --change c --gate G4 --tier T2 --round 1 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken again" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_contains "UNBOUND    G4"
  assert_not_contains "PASS       G4"
}

# G5 r18: a same-base round-1 re-run AFTER a restart is not a new start: a gate logged between the restart and
# the re-run still counts (the `!seen` clause of the lineage start).
test_a_same_base_rerun_after_a_restart_keeps_gates_logged_in_between() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m one
  local b; b="$(git -C "$REPO" rev-parse HEAD)"
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$b" --restart-lineage >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m two
  local tip; tip="$(git -C "$REPO" rev-parse HEAD)"
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$b" >/dev/null 2>&1
  run led compliance --change c --tier T2
  assert_row "PASS" "G4"
}

# G5 r18: with several passes after the fail an unverifiable one followed by an unbound one reads as
# "not checkable" (unverifiable beats unbound), not UNBOUND.
test_the_order_of_several_clearing_passes_is_handled() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip outside; tip="$(git -C "$REPO" rev-parse HEAD)"; outside="$(git -C "$REPO" rev-parse "$BASE_SHA^")"
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  _fake_commit deadbee --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m
  led add --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$outside" >/dev/null 2>&1
  run led compliance --change c --tier T2 --round 2
  assert_contains "not checkable here"
  assert_not_contains "UNBOUND    G4"
}

# G5 r18: a bound clearing pass settles the gate: later passes are not examined (no spurious "not checkable").
test_a_bound_clearing_pass_stops_the_search() {
  newrepo
  led route --change c --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led route --change c --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m work
  local tip; tip="$(git -C "$REPO" rev-parse HEAD)"
  led add --change c --gate G4 --tier T2 --round 1 --outcome fail --confidence fresh --model m --commit "$tip" \
      --finding "blocking::a.sh:1::broken" >/dev/null 2>&1
  led add --change c --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$tip" >/dev/null 2>&1
  _fake_commit deadbee --change c --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m
  run led compliance --change c --tier T2 --round 2
  assert_row "PASS" "G4"
  assert_not_contains "not checkable here"
}

# G4 r18: an explicit --restart-lineage is honoured when the change has no round-1 route with a base (its first
# route was logged at a stale ROUND=2); it used to be dropped without a word.
test_an_explicit_restart_lineage_is_not_dropped_without_a_round_one_base_route() {
  newrepo
  led route --change x --predicted T2 --actual T2 --round 2 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change x --gate G4 --tier T2 --round 2 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  run led route --change x --predicted T2 --actual T2 --round 1 --reason r2 --base "$BASE_SHA" --restart-lineage
  assert_contains "starts a NEW lineage"
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the explicit flag writes the marker"
  run led compliance --change x --tier T2
  assert_row "NOT RUN" "G4"
}

# ---- Round 20: findings from round 19 ----
# G6 blocking / G1 G4 G5: an explicit --restart-lineage at a round other than 1 was dropped without a word
# (RESTART_LINEAGE=1 added while ROUND=2 was still exported), and the old lineage's passes kept counting.
test_an_explicit_restart_lineage_at_round_two_is_recorded_as_round_one() {
  newrepo
  led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change x --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  run led route --change x --predicted T2 --actual T2 --round 2 --reason r2 --base "$BASE_SHA" --restart-lineage
  assert_exit 0 "a restart given with a stale --round is accepted"
  assert_contains "is round 1; --round 2 ignored"
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the marker is written"
  run led compliance --change x --tier T2
  assert_row "NOT RUN" "G4"
}

# G8 r19 / G1 r19: a restart on a change with no route at all has nothing to restart; it says so.
test_an_explicit_restart_lineage_on_a_change_with_no_route_says_so() {
  newrepo
  run led route --change fresh --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" --restart-lineage
  assert_exit 0 "the first route is accepted"
  assert_contains "has no earlier route"
  assert_eq "0" "$(grep -c '"restart":true' "$(ledger_path)")" "no marker: the first route starts the lineage anyway"
}

# G8 r19: the same commit abbreviated read as "a different base" and was refused as a new lineage; the stored
# base is now always the full sha, so a re-run with a short one is the same re-run.
test_an_abbreviated_base_is_the_same_base_as_the_full_sha() {
  newrepo
  led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led route --change x --predicted T2 --actual T2 --round 1 --reason r --base "${BASE_SHA:0:7}"
  assert_exit 0 "an abbreviated spelling of the same base is not a new lineage"
  assert_eq "2" "$(grep -c "\"base\":\"$BASE_SHA\"" "$(ledger_path)")" "both rows store the full sha"
}

# G8 r19: the tier-floor refusal said only a round-1 reconcile with a different base could lower the floor.
test_the_tier_floor_refusal_names_the_real_escape_hatch() {
  newrepo
  led route --change x --predicted T4 --actual T4 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  run led compliance --change x --tier T2
  assert_exit 2 "below the floor is refused"
  assert_contains "hand-typed 'route --base'"
  assert_not_contains "Only a new round-1 reconcile with a different base"
}

# G4 r20: the --not HEAD sibling of the -- fix: a root file named HEAD made the orphan filter fail (error swallowed)
# and an orphaned gated commit became the anchor.
test_coverage_anchor_ignores_an_orphaned_gated_commit_when_a_root_file_is_named_head() {
  newrepo
  printf 'x\n' > "$REPO/HEAD"; git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "HEAD file" >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m A >/dev/null 2>&1
  local a; a="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" commit -q --allow-empty -m C >/dev/null 2>&1
  git -C "$REPO" checkout -q -b side >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m O >/dev/null 2>&1
  local o; o="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q - >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m D >/dev/null 2>&1
  led add --change a --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$a" >/dev/null 2>&1
  led add --change o --gate G4 --tier T2 --round 1 --outcome pass --confidence fresh --model m --commit "$o" >/dev/null 2>&1
  local out; out="$( cd "$REPO" && . "$REPO/.pipeline/tools/lib/coverage.sh" && coverage_anchor "$(ledger_path)" 2>/dev/null )"
  assert_eq "$a" "$out" "the anchor is the gated commit on HEAD's own history, not the orphan"
}

# G7 r19: an invalid ERE in a T4 row made grep exit 2, read as "no trust file changed": everything passed.
test_hook_blocks_when_the_trust_pattern_is_not_a_valid_regex() {
  newrepo
  printf 'z\n' > "$REPO/src/auth/z.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "Z" >/dev/null 2>&1
  local z; z="$(git -C "$REPO" rev-parse HEAD)"
  LAST_OUT="$( export TRUST='src/(auth'; hook_stdin refs/heads/master "$z" refs/heads/master "$BASE_SHA" 2>&1 )"; LAST_EXIT=$?
  assert_exit 1 "an unparsable pattern is not a pass"
  assert_contains "not a valid extended regex"
}

# ---- Change B (coverage anchor and baseline) ----
# G7 r13: a committed root file named HEAD made `git log HEAD ^a` fail; the swallowed error read "0 unrouted".
test_coverage_counts_commits_when_a_root_file_is_named_head() {
  newrepo
  printf 'x\n' > "$REPO/HEAD"
  mkdir -p "$REPO/src/auth"; printf 'w\n' > "$REPO/src/auth/w.js"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "work with a file named HEAD" >/dev/null 2>&1
  run status_run
  assert_contains "work with a file named HEAD"
}

# G1 r13: a pin that is a real commit but not an ancestor of HEAD was overwritten with HEAD, moving the cutoff
# later and dropping work. The pin is left alone and the lines' merge-base is the cutoff.
test_coverage_baseline_does_not_overwrite_a_pin_that_is_not_an_ancestor() {
  newrepo
  local kit="$REPO/.pipeline"
  # The pin is only consulted while the kit is NOT tracked yet: untrack it so that path is the one under test.
  git -C "$REPO" rm -r -q --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "untrack the kit" >/dev/null 2>&1
  printf '%s\n' "$BASE_SHA" > "$kit/.install-base"
  local out; out="$( cd "$REPO" && . "$kit/tools/lib/coverage.sh" && coverage_baseline "$kit" 2>/dev/null )"
  assert_eq "$BASE_SHA" "$out" "an ancestor pin is used as the cutoff"
  git -C "$REPO" checkout -q --orphan other >/dev/null 2>&1
  git -C "$REPO" commit -q --allow-empty -m "unrelated line" >/dev/null 2>&1
  out="$( cd "$REPO" && . "$kit/tools/lib/coverage.sh" && coverage_baseline "$kit" 2>/dev/null )"
  assert_eq "" "$out" "a pin with no common history counts everything"
  assert_eq "$BASE_SHA" "$(tr -d ' \t\r\n' < "$kit/.install-base")" "the pin file is not rewritten with HEAD"
}

# G1 r20: a pin that is hex but not a commit here (a rebase plus gc, or copied from another clone) was
# overwritten with HEAD (range HEAD..HEAD, "0 unrouted").
test_coverage_baseline_does_not_overwrite_a_pin_that_names_no_commit() {
  newrepo
  local kit="$REPO/.pipeline"
  git -C "$REPO" rm -r -q --cached .pipeline >/dev/null 2>&1
  git -C "$REPO" commit -qm "untrack the kit" >/dev/null 2>&1
  printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$kit/.install-base"
  local out; out="$( cd "$REPO" && . "$kit/tools/lib/coverage.sh" && coverage_baseline "$kit" 2>/dev/null )"
  assert_eq "" "$out" "an unresolvable pin counts everything"
  assert_eq "0123456789abcdef0123456789abcdef01234567" "$(tr -d ' \t\r\n' < "$kit/.install-base")" "the pin file is left alone"
}

# G1 r20 (no test existed): edits under <kit>/project/ are the project's own rules and count as work; the
# rest of the kit does not.
test_coverage_scan_counts_edits_under_the_kit_project_directory() {
  newrepo
  local kit="$REPO/.pipeline"
  mkdir -p "$kit/project" "$kit/tools"
  printf 'x\n' > "$kit/project/note.md"; git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm "projA" >/dev/null 2>&1
  printf 'y\n' > "$kit/tools/y.sh"; git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm "toolsB" >/dev/null 2>&1
  printf 'T3::(^|/)project/::proj\nT3::(^|/)tools/::tools\n' > "$TMPROOT/cov.conf"
  local out; out="$( cd "$REPO" && . "$kit/tools/lib/coverage.sh" && coverage_scan "$TMPROOT/cov.conf" "HEAD~2..HEAD" 10 ".pipeline/" 2>/dev/null )"
  LAST_OUT="$out"
  assert_re "^3[[:space:]]+[0-9a-f]+ projA"     # tiered T3: counted as project work
  assert_re "^0[[:space:]]+[0-9a-f]+ toolsB"    # the kit's own tools: tier 0, not counted
}

# G1 r20 blocking: an explicit restart with a stale --round AND --action was still dropped (the guard
# excluded actions). A restart is never a follow-up.
test_an_explicit_restart_lineage_with_an_action_at_round_two_is_recorded_as_round_one() {
  newrepo
  led route --change c --predicted T2 --actual T3 --round 1 --reason r --base "$BASE_SHA" >/dev/null 2>&1
  led add --change c --gate G4 --tier T3 --round 1 --outcome pass --confidence fresh --model m --commit "$BASE_SHA" >/dev/null 2>&1
  run led route --change c --predicted T2 --actual T3 --round 2 --reason r2 --base "$BASE_SHA" \
        --restart-lineage --action store-publish --evidence "published build 7"
  assert_exit 0 "accepted"
  assert_contains "is round 1; --round 2 ignored"
  assert_eq "1" "$(grep -c '"restart":true' "$(ledger_path)")" "the marker is written"
}

# G1 r20: a ledger row written before bases were stored in full holds an abbreviation; the same spelling must
# still be a re-run, not a refused new lineage.
test_a_legacy_abbreviated_base_row_still_reads_as_the_same_base() {
  newrepo
  printf '{"type":"route","date":"2026-01-01T00:00:00Z","change":"legacy","round":1,"commit":"%s","kit":"1.0.0","predicted":"T2","actual":"T2","verdict":"match","reason":"r","base":"%s"}\n' \
    "$BASE_SHA" "${BASE_SHA:0:7}" >> "$(ledger_path)"
  run led route --change legacy --predicted T2 --actual T2 --round 1 --reason r --base "${BASE_SHA:0:7}"
  assert_exit 0 "the same abbreviation is a re-run"
  assert_not_contains "REFUSED"
}

# G1 r20: a T4 row beginning with "-" must be validated and matched as the pattern it is.
test_hook_treats_a_trust_pattern_that_starts_with_a_dash_as_a_pattern() {
  newrepo
  mkdir -p "$REPO/-secrets"; printf 'k\n' > "$REPO/-secrets/key"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "dash dir" >/dev/null 2>&1
  local d; d="$(git -C "$REPO" rev-parse HEAD)"
  LAST_OUT="$( export TRUST='-secrets/'; hook_stdin refs/heads/master "$d" refs/heads/master "$BASE_SHA" 2>&1 )"; LAST_EXIT=$?
  assert_exit 1 "a change under -secrets/ is a trust-boundary change"
  assert_contains "BLOCKED"
}

# ================================================================ C1: gate evidence
# A fresh T3/T4 pass must cite something: an info finding with a location, --evidence file:line, or
# --evidence-cmd EVIDENCE::<name> from project/commands.conf (ledger.sh evidence_run).
c1_conf() { printf '%s\n' "$@" >> "$REPO/.pipeline/project/commands.conf"
            git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "evidence lines" >/dev/null 2>&1; }
c1_add() { LED_NO_EVIDENCE=1 led add --change c1 --model m --confidence fresh "$@"; }

test_c1_bare_fresh_t4_pass_is_refused_and_writes_nothing() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome pass
  assert_exit 2
  assert_contains "no evidence"
  [ ! -s "$(ledger_path)" ] || _fail "a refused pass wrote a line"
}

test_c1_t2_pass_and_t4_fail_and_low_confidence_need_no_evidence() {
  newrepo
  run c1_add --gate G4 --tier T2 --outcome pass;                              assert_exit 0 "T2 is below the evidence rule"
  run c1_add --gate G4 --tier T4 --outcome pass --confidence low;             assert_exit 0 "a low-confidence pass is not a fresh verdict"
  run c1_add --gate G4 --tier T4 --outcome fail --finding "blocking::a.sh:1::x"; assert_exit 0
}

test_c1_info_finding_with_location_satisfies_it_but_one_without_does_not() {
  newrepo
  run c1_add --gate G4 --tier T3 --outcome pass --finding "info::.pipeline/tools/ledger.sh:5::held"; assert_exit 0
  run c1_add --gate G4 --tier T3 --outcome pass --finding "info::claim only";          assert_exit 2
}

test_c1_evidence_flag_must_be_file_line() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "looks fine"; assert_exit 2; assert_contains "file:line"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools/ledger.sh:5"; assert_exit 0
  assert_file_contains "$(ledger_path)" '"citation":".pipeline/tools/ledger.sh:5"'
}

test_c1_evidence_cmd_runs_the_declared_line_and_records_exit_and_hashes() {
  newrepo
  c1_conf 'EVIDENCE::ok::echo hi'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::ok
  assert_exit 0
  assert_file_contains "$(ledger_path)" '"evidence_cmd":"EVIDENCE::ok","evidence_exit":0,"evidence_sha256":"'
  assert_file_contains "$(ledger_path)" '"evidence_line_sha256":"'
  assert_jsonl_valid "$(ledger_path)"
}

test_c1_evidence_cmd_refuses_unknown_manual_wrong_kind_and_failing_command() {
  newrepo
  c1_conf 'EVIDENCE::bad::exit 3' 'EVIDENCE::man::MANUAL::a human'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::nope;  assert_exit 2; assert_contains "no 'EVIDENCE::nope' line"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::man;   assert_exit 2; assert_contains "MANUAL"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd DEPS::default;   assert_exit 2; assert_contains "not EVIDENCE"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::bad;   assert_exit 2; assert_contains "exited 3"
  [ ! -s "$(ledger_path)" ] || _fail "a refused evidence command wrote a line"
  # A failing command is still recordable as the evidence for a FAIL.
  run c1_add --gate G4 --tier T4 --outcome fail --evidence-cmd EVIDENCE::bad --finding "blocking::a.sh:1::x"
  assert_exit 0
  assert_file_contains "$(ledger_path)" '"evidence_exit":3'
}

test_c1_an_untiered_fresh_pass_is_held_to_the_same_rule() {
  newrepo
  run c1_add --gate G4 --outcome pass
  assert_exit 2
  assert_contains "untiered"
}

test_c1_a_citation_must_name_a_real_file_and_a_line_within_it() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "nonexistent.sh:3";            assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools/ledger.sh:99999999"; assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools/ledger.sh:0";  assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "a b:9 x"; assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --finding "info:: ::blank";                assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --finding "info::nofile::x";               assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools/ledger.sh:2-9"; assert_exit 0 "a line range cites its first line"
}

test_c1_a_command_that_prints_nothing_does_not_support_a_pass() {
  newrepo
  c1_conf 'EVIDENCE::silent::true'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::silent
  assert_exit 2
  assert_contains "printed nothing"
}

test_c1_an_uncommitted_commands_conf_is_refused() {
  newrepo
  c1_conf 'EVIDENCE::ok::echo hi'
  printf 'EVIDENCE::sneaky::echo pwned\n' >> "$REPO/.pipeline/project/commands.conf"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::ok
  assert_exit 2
  assert_contains "not committed"
}

test_c1_skipped_and_na_outcomes_need_no_citation() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome skipped; assert_exit 0
  run c1_add --gate G4 --tier T4 --outcome n/a --note "not applicable here"; assert_exit 0
}

test_c1_evidence_key_matches_whole_names_only_and_tolerates_crlf() {
  newrepo
  c1_conf 'EVIDENCE::okay::exit 3' 'EVIDENCE::ok::echo hi'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::ok
  assert_exit 0 "EVIDENCE::ok must not match the EVIDENCE::okay line"
  printf 'EVIDENCE::crlf::echo hello\r\n' >> "$REPO/.pipeline/project/commands.conf"
  git -C "$REPO" commit -qam crlf >/dev/null 2>&1
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::crlf
  assert_exit 0 "a CRLF conf line runs"
}

test_c1_only_an_info_finding_counts_and_citations_stay_inside_the_repo() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome pass --finding "blocking::.pipeline/tools/ledger.sh:3::x"; assert_exit 2 "a blocking finding is not a citation"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "/etc/hosts:1";                              assert_exit 2; assert_contains "absolute"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "../x:1";                                    assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools/ledger.sh:5-2";             assert_exit 2 "reversed range"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools/ledger.sh:3-zz";            assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools/ledger.sh:99999999999999999999"; assert_exit 2
}

test_c1_an_untracked_or_skip_worktree_commands_conf_is_refused() {
  newrepo
  c1_conf 'EVIDENCE::ok::echo hi'
  git -C "$REPO" update-index --skip-worktree .pipeline/project/commands.conf
  printf 'EVIDENCE::sneak::echo sneak\n' >> "$REPO/.pipeline/project/commands.conf"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::sneak
  assert_exit 2 "skip-worktree hides the edit from git diff, not from this check"
  git -C "$REPO" update-index --no-skip-worktree .pipeline/project/commands.conf
  git -C "$REPO" checkout -q -- .pipeline/project/commands.conf
  cp "$REPO/.pipeline/project/commands.conf" "$REPO/commands.keep"
  git -C "$REPO" rm -q .pipeline/project/commands.conf
  git -C "$REPO" commit -qm "drop conf" >/dev/null 2>&1
  mv "$REPO/commands.keep" "$REPO/.pipeline/project/commands.conf"   # now present but never committed
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::ok
  assert_exit 2 "an untracked conf is not a reviewed conf"
}

test_c1_an_evidence_command_runs_in_the_kits_repository_not_the_callers_cwd() {
  newrepo
  c1_conf 'EVIDENCE::where::pwd'
  local other; other="$(mktemp -d "$TMPROOT/other.XXXXXX")"; git -C "$other" init -q
  run bash -c "cd '$other' && LED_NO_EVIDENCE=1 bash '$REPO/.pipeline/tools/ledger.sh' --ledger '$(ledger_path)' add --change c1 --model m --confidence fresh --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::where"
  assert_exit 0
  assert_not_contains "$(basename "$other")"
}

test_c1_the_recorded_hash_covers_the_real_output_and_the_conf_line() {
  newrepo
  c1_conf 'EVIDENCE::fixed::printf abc'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::fixed
  assert_exit 0
  # sha256("abc")
  assert_file_contains "$(ledger_path)" '"evidence_sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"'
  local want; want="$(printf '%s' 'EVIDENCE::fixed::printf abc' | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  assert_file_contains "$(ledger_path)" "\"evidence_line_sha256\":\"$want\""
}

test_c1_an_evidence_command_sees_the_repository_root_as_its_cwd() {
  newrepo
  c1_conf 'EVIDENCE::rel::cat src/app.js'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::rel
  assert_exit 0 "a relative path in a conf line resolves from the repository root"
  assert_contains "console.log"
}

test_c1_a_directory_or_a_line_past_the_end_is_not_a_citation() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome pass --evidence ".pipeline/tools:1"; assert_exit 2 "a directory is not a file"
  local n; n="$(awk 'END{print NR}' "$REPO/src/app.js")"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "src/app.js:$n";       assert_exit 0 "the last line is citable"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "src/app.js:$((n+1))"; assert_exit 2 "one past the end is not"
}

test_c1_a_backslash_path_or_an_overlong_range_end_is_not_a_citation() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome pass --evidence '..\x:1';                          assert_exit 2; assert_contains "backslash"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence 'src\..\..\x:1';                   assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "src/app.js:1-99999";              assert_exit 2 "a range end past the file"
}

test_c1_a_citation_resolves_against_the_kits_repository_not_the_callers_cwd() {
  newrepo
  local other; other="$(mktemp -d "$TMPROOT/other.XXXXXX")"; git -C "$other" init -q; printf 'x\n' > "$other/only-here.txt"
  run bash -c "cd '$other' && LED_NO_EVIDENCE=1 bash '$REPO/.pipeline/tools/ledger.sh' --ledger '$(ledger_path)' add --change c1 --model m --confidence fresh --gate G4 --tier T4 --outcome pass --evidence only-here.txt:1"
  assert_exit 2 "a file that exists only in the caller's repository is not citable"
}

test_c1_an_unknown_or_escaped_key_is_refused_and_the_declared_names_are_listed() {
  newrepo
  c1_conf 'EVIDENCE::ok::echo hi'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd 'EVIDENCE::o\x6b'
  assert_exit 2
  assert_contains "Declared EVIDENCE names:"
  assert_contains " ok "
}

test_c1_drive_letter_nested_dotdot_and_bare_manual_are_all_refused() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "C:/x:1";        assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "a/../../x:1";   assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "a/..:1";        assert_exit 2
  c1_conf 'EVIDENCE::bare::MANUAL'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::bare
  assert_exit 2
  assert_contains "MANUAL"
}

test_c1_a_silent_command_may_still_be_recorded_as_the_evidence_for_a_fail() {
  newrepo
  c1_conf 'EVIDENCE::quiet::true'
  run c1_add --gate G4 --tier T4 --outcome fail --evidence-cmd EVIDENCE::quiet --finding "blocking::src/app.js:1::x"
  assert_exit 0
  assert_file_contains "$(ledger_path)" '"evidence_exit":0'
}

test_c1_stderr_counts_as_output_and_is_hashed() {
  newrepo
  c1_conf 'EVIDENCE::err::echo oops >&2'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::err
  assert_exit 0 "a command that only writes to stderr still printed something"
  local want; want="$(printf '%s' 'oops' | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  assert_file_contains "$(ledger_path)" "\"evidence_sha256\":\"$want\""
}

test_c1_the_key_matches_only_at_the_start_of_a_line() {
  newrepo
  c1_conf '# EVIDENCE::ok::echo wrong-commented' 'x EVIDENCE::ok::echo wrong-midline' 'EVIDENCE::ok::echo right'
  run c1_add --gate G4 --tier T4 --outcome pass --evidence-cmd EVIDENCE::ok
  assert_exit 0
  assert_contains "right"
  assert_not_contains "wrong"
  local want; want="$(printf '%s' 'EVIDENCE::ok::echo right' | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  assert_file_contains "$(ledger_path)" "\"evidence_line_sha256\":\"$want\""
}

test_c1_a_bad_evidence_citation_is_refused_whatever_the_outcome() {
  newrepo
  run c1_add --gate G4 --tier T4 --outcome fail --evidence "looks fine" --finding "blocking::src/app.js:1::x"; assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome skipped --evidence "nofile.txt:1";                                   assert_exit 2
  run c1_add --gate G4 --tier T4 --outcome pass --confidence low --evidence "nofile.txt:1";                     assert_exit 2
  [ ! -s "$(ledger_path)" ] || _fail "a refused citation wrote a line"
}

test_c1_a_real_file_outside_the_repository_is_not_citable() {
  newrepo
  printf 'outside\n' > "$REPO/../c1-sibling.txt"
  run c1_add --gate G4 --tier T4 --outcome pass --evidence "../c1-sibling.txt:1"
  assert_exit 2
  assert_contains ".."
  rm -f "$REPO/../c1-sibling.txt"
}

# ================================================================ C3: the ledger hash chain
c3_route() { led route --change c3 --predicted T2 --actual T2 --reason "chain test $1" >/dev/null 2>&1; }
c3_head() { run led verify; printf '%s\n' "$LAST_OUT" | sed -n 's/^chain head: \([0-9a-f]*\) .*/\1/p'; }

test_c3_every_record_links_to_the_hash_of_the_line_before() {
  newrepo
  c3_route 1; c3_route 2
  local l1 l2 want
  l1="$(sed -n 1p "$(ledger_path)")"; l2="$(sed -n 2p "$(ledger_path)")"
  assert_file_contains "$(ledger_path)" '"prev":"0000000000000000000000000000000000000000000000000000000000000000"'
  want="$(printf '%s\n' "$l1" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  case "$l2" in *"\"prev\":\"$want\"}") _ok;; *) _fail "line 2 does not carry the sha256 of line 1: $l2";; esac
  assert_jsonl_valid "$(ledger_path)"
}

test_c3_verify_passes_an_untouched_chain_and_prints_the_head() {
  newrepo
  c3_route 1; c3_route 2; c3_route 3
  run led verify
  assert_exit 0
  assert_contains "3 chained (3 linked, 0 join(s), 0 break(s))"
  assert_contains "chain head: "
  assert_contains "verify: OK"
}

test_c3_verify_catches_an_edit_a_deletion_and_an_insertion() {
  newrepo
  c3_route 1; c3_route 2; c3_route 3; c3_route 4
  local f; f="$(ledger_path)"; cp "$f" "$f.good"
  sedi '2s/chain test 2/EDITED/' "$f"
  run led verify; assert_exit 1 "an edited line"; assert_contains "BREAK  record 3"
  cp "$f.good" "$f"; sedi '2d' "$f"
  run led verify; assert_exit 1 "a deleted line"; assert_contains "BREAK"
  cp "$f.good" "$f"; sedi_after 2 '{"type":"note"}' "$f"
  run led verify; assert_exit 1 "an inserted unchained line"; assert_contains "no \"prev\""
}

test_c3_a_legacy_prefix_is_fine_and_a_tail_truncation_needs_the_pinned_head() {
  newrepo
  printf '{"type":"note","n":1}\n{"type":"note","n":2}\n' > "$(ledger_path)"
  run led verify; assert_exit 0 "legacy lines before any chained line are fine"; assert_contains "2 legacy"
  c3_route 1; c3_route 2
  local head; head="$(c3_head)"
  sedi '$d' "$(ledger_path)"
  run led verify; assert_exit 0 "without a pinned head a truncated tail is invisible"
  run led verify --expect-head "$head"; assert_exit 1; assert_contains "--expect-head"
}

test_c3_two_branches_concatenated_are_a_join_not_a_break() {
  newrepo
  c3_route 1; c3_route 2
  local f; f="$(ledger_path)"; cp "$f" "$f.fork"
  c3_route 3; local a_tail; a_tail="$(tail -n 1 "$f")"
  cp "$f.fork" "$f"; c3_route 4
  printf '%s\n' "$a_tail" >> "$f"          # branch B's line appended after branch A's: its prev points at line 2
  run led verify
  assert_exit 1 "strict by default"
  assert_contains "--allow-joins"
  run led verify --allow-joins
  assert_exit 0
  assert_contains "JOIN"
  assert_contains "1 join(s)"
}

test_c3_a_crlf_checkout_still_verifies() {
  newrepo
  c3_route 1; c3_route 2
  sedi_crlf "$(ledger_path)"
  run led verify
  assert_exit 0 "line endings are not tampering"
}

test_c3_a_forged_or_edited_record_cannot_pass_as_a_join() {
  newrepo
  c3_route 1; c3_route 2; c3_route 3; c3_route 4; c3_route 5
  local f h1; f="$(ledger_path)"; cp "$f" "$f.good"
  h1="$(sed -n 1p "$f" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  # a forged record after record 2 that links to record 1's hash: no hashing needed by the forger
  awk -v h="$h1" 'NR==2{print; print "{\"type\":\"forged\",\"prev\":\"" h "\"}"; next}1' "$f.good" > "$f"
  run led verify; assert_exit 1 "a forged insert"; assert_contains "BREAK"
  # an edit, with the downstream prevs rewritten to an old hash
  cp "$f.good" "$f"; sedi '3s/chain test 3/EVIL/' "$f"
  sedi -E "4s/\"prev\":\"[0-9a-f]+\"/\"prev\":\"$h1\"/;5s/\"prev\":\"[0-9a-f]+\"/\"prev\":\"$h1\"/" "$f"
  run led verify; assert_exit 1 "an edit with cheap prev rewrites"; assert_contains "BREAK"
  # A byte-for-byte copy of an existing record has the same hash, so it is a BREAK wherever it sits.
  cp "$f.good" "$f"; sed -n 2p "$f.good" >> "$f"
  run led verify; assert_exit 1 "a copy appended at the tail"; assert_contains "exact copy of record 2"
  cp "$f.good" "$f"; sed -n 2p "$f.good" > "$f.dup"
  { sed -n 1,2p "$f.good"; cat "$f.dup"; sed -n '3,$p' "$f.good"; } > "$f"
  run led verify; assert_exit 1 "a copy inserted right after the original"; assert_contains "exact copy"
  # DOCUMENTED LIMIT: a FORGED (not copied) record appended at the tail is a normal append to the chain.
  cp "$f.good" "$f"; c3_route 6
  run led verify; assert_exit 0
}

test_c3_a_two_line_branch_concatenated_is_still_a_join() {
  newrepo
  c3_route 1; c3_route 2
  local f; f="$(ledger_path)"; cp "$f" "$f.fork"
  c3_route 3; c3_route 4; cp "$f" "$f.a"
  cp "$f.fork" "$f"; c3_route 5; c3_route 6
  tail -n 2 "$f" > "$f.b"; cat "$f.a" "$f.b" > "$f"
  run led verify; assert_exit 1 "strict by default: a join is also the shape of an inserted record"; assert_contains "--allow-joins"
  run led verify --allow-joins; assert_exit 0; assert_contains "1 join(s)"
}

test_c3_stripping_every_prev_is_caught_only_against_git() {
  newrepo
  c3_route 1; c3_route 2; c3_route 3
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "ledger" >/dev/null 2>&1
  local f; f="$(ledger_path)"
  sedi -E 's/,"prev":"[0-9a-f]+"\}$/}/' "$f"
  run led verify; assert_exit 0 "plain verify reads a stripped ledger as all-legacy"; assert_contains "3 legacy"
  run led verify --against HEAD; assert_exit 1 "committed history is the anchor"; assert_contains "NOT a prefix"
  git -C "$REPO" checkout -q -- "$f"
  run led verify --against HEAD; assert_exit 0; assert_contains "exact prefix"
  assert_not_contains "unpinned and unanchored"
  c3_route 4
  run led verify --against HEAD; assert_exit 0 "new records after the commit are fine"
  sedi '$d' "$f"; sedi '$d' "$f"
  run led verify --against HEAD; assert_exit 1 "a truncation into committed records"
  run led verify --against no-such-rev; assert_exit 2
}

test_c3_blank_lines_are_ignored_and_never_chained_onto() {
  newrepo
  c3_route 1; c3_route 2
  printf '\n\n' >> "$(ledger_path)"
  run led verify; assert_exit 0 "a trailing blank line is not a break"; assert_contains "2 chained"
  c3_route 3
  run led verify; assert_exit 0 "a record after a blank line links to the last real record"; assert_contains "3 chained (3 linked"
}

test_c3_a_ledger_path_with_spaces_and_a_prevlike_note_verify() {
  newrepo
  local d="$REPO/dir with space"; mkdir -p "$d"
  ( cd "$REPO" && bash .pipeline/tools/ledger.sh --ledger "$d/l.jsonl" route --change c3 --predicted T2 --actual T2 --reason 'x,"prev":"abc"}' ) >/dev/null 2>&1
  ( cd "$REPO" && bash .pipeline/tools/ledger.sh --ledger "$d/l.jsonl" route --change c3 --predicted T2 --actual T2 --reason y ) >/dev/null 2>&1
  run bash -c "cd '$REPO' && bash .pipeline/tools/ledger.sh --ledger '$d/l.jsonl' verify"
  assert_exit 0
  assert_contains "2 chained (2 linked"
}

test_c3_a_reordered_pair_of_records_is_a_break() {
  newrepo
  c3_route 1; c3_route 2; c3_route 3; c3_route 4
  local f; f="$(ledger_path)"
  { sed -n 1p "$f"; sed -n 3p "$f"; sed -n 2p "$f"; sed -n 4p "$f"; } > "$f.swap"; cp "$f.swap" "$f"
  run led verify; assert_exit 1; assert_contains "BREAK"
}

test_c3_a_matching_pinned_head_passes_and_a_stale_one_fails() {
  newrepo
  c3_route 1; c3_route 2
  local head; head="$(c3_head)"
  [ -n "$head" ] || _fail "no chain head was printed"
  run led verify --expect-head "$head"; assert_exit 0 "the right pin passes"; assert_contains "verify: OK"
  c3_route 3
  run led verify --expect-head "$head"; assert_exit 1 "after a legitimate append the old pin is stale"
  assert_contains "--expect-head"
}

test_c3_a_record_written_after_a_crlf_conversion_still_chains() {
  newrepo
  c3_route 1; c3_route 2
  sedi_crlf "$(ledger_path)"
  c3_route 3
  run led verify
  assert_exit 0 "the writer must hash the CRLF last line the way verify does"
  assert_contains "3 chained (3 linked"
}

test_c3_an_empty_pin_a_dash_revision_and_a_plain_ok_notice() {
  newrepo
  c3_route 1; c3_route 2
  run led verify --expect-head ""; assert_exit 2 "an unset CI variable must not pin nothing"; assert_contains "REFUSED"
  run led verify --expect-head "NOTHEX"; assert_exit 2
  run led verify --against "--output=PWNED"; assert_exit 2
  run led verify --against ""; assert_exit 2
  [ ! -e "$REPO/PWNED" ] && _ok || _fail "an option reached git"
  run led verify; assert_exit 0; assert_contains "unpinned and unanchored"
  local head; head="$(c3_head)"
  run led verify --expect-head "$head"; assert_exit 0; assert_not_contains "unpinned and unanchored"
}

test_c3_a_ledger_of_only_blank_lines_has_no_records() {
  newrepo
  printf '\n  \n\t\n' > "$(ledger_path)"
  run led verify
  assert_exit 0
  assert_contains "0 record(s)"
  assert_not_contains "1 chained"
}

test_c3_a_git_conflict_marker_is_named_as_one() {
  newrepo
  c3_route 1; c3_route 2
  local f; f="$(ledger_path)"
  { sed -n 1p "$f"; echo '<<<<<<< HEAD'; sed -n 2p "$f"; echo '======='; echo '>>>>>>> other'; } > "$f.m"; cp "$f.m" "$f"
  run led verify; assert_exit 1; assert_contains "git conflict marker"
}

test_c3_two_branches_that_both_started_from_an_empty_ledger_are_a_genesis_join() {
  newrepo
  local f; f="$(ledger_path)"
  : > "$f"; c3_route 1; c3_route 2; cp "$f" "$f.a"
  : > "$f"; c3_route 3; c3_route 4; cp "$f" "$f.b"
  cat "$f.a" "$f.b" > "$f"
  run led verify --allow-joins
  assert_exit 0 "both lines of descent start at the zero hash"
  assert_contains "JOIN"
}

test_c3_a_whitespace_only_line_is_blank_for_the_writer_and_the_verifier() {
  newrepo
  c3_route 1
  printf '   \t \n' >> "$(ledger_path)"
  run led verify; assert_exit 0 "a whitespace-only line is not a record"; assert_contains "1 chained"
  c3_route 2
  run led verify; assert_exit 0 "and the writer chains onto the last real record"; assert_contains "2 chained (2 linked"
}

test_c3_parallel_writers_chain_correctly() {
  newrepo
  c3_route 0
  local i
  for i in 1 2 3 4 5; do ( c3_route "p$i" ) & done
  wait
  run led verify
  assert_exit 0 "six writers, one ledger: the lock keeps the chain intact"
  assert_contains "6 chained (6 linked, 0 join(s), 0 break(s))"
  [ ! -d "$(ledger_path).lock" ] && _ok || _fail "the lock directory was left behind"
}

test_c3_a_stale_lock_from_a_crashed_writer_is_broken() {
  newrepo
  c3_route 1
  mkdir "$(ledger_path).lock"
  touch -d '10 minutes ago' "$(ledger_path).lock" 2>/dev/null || touch -t 200001010000 "$(ledger_path).lock"
  c3_route 2
  run led verify
  assert_exit 0
  assert_contains "2 chained (2 linked"
}

test_c3_three_branches_forked_from_one_record_concatenate_cleanly() {
  newrepo
  local f; f="$(ledger_path)"
  c3_route 0; cp "$f" "$f.base"
  c3_route x1; c3_route x2; tail -n 2 "$f" > "$f.x"
  cp "$f.base" "$f"; c3_route y1; c3_route y2; tail -n 2 "$f" > "$f.y"
  cp "$f.base" "$f"; c3_route z1; c3_route z2; tail -n 2 "$f" > "$f.z"
  cat "$f.base" "$f.x" "$f.y" "$f.z" > "$f"
  run led verify --allow-joins
  assert_exit 0 "a three-way merge is an ordinary event"
  assert_contains "2 join(s)"
}

test_c3_a_record_inserted_with_a_correct_link_is_a_break_unless_joins_are_allowed() {
  newrepo
  c3_route 1; c3_route 2; c3_route 3
  local f h2; f="$(ledger_path)"; cp "$f" "$f.good"
  h2="$(sed -n 2p "$f" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  { sed -n 1,2p "$f.good"; printf '{"type":"forged","prev":"%s"}\n' "$h2"; sed -n 3p "$f.good"; } > "$f"
  run led verify; assert_exit 1 "a forged record with a correct link, no hashing needed"; assert_contains "--allow-joins"
  run led verify --allow-joins; assert_exit 0 "DOCUMENTED LIMIT: with joins allowed it reads as a one-record branch"
}

test_c3_a_numeric_looking_prev_is_not_equal_to_the_zero_hash() {
  newrepo
  printf '{"type":"x","prev":"0"}\n' > "$(ledger_path)"
  run led verify; assert_exit 1 "prev 0 is not 64 zeros"
}

test_c3_an_empty_ledger_has_nothing_to_verify() {
  newrepo
  : > "$(ledger_path)"
  run led verify; assert_exit 0; assert_contains "nothing to verify"
  rm -f "$(ledger_path)"
  run led verify; assert_exit 1 "a missing ledger is still an error"
}

test_c3_a_stale_lock_that_cannot_be_removed_ends_in_a_refusal_not_a_hang() {
  newrepo
  c3_route 1
  local lock; lock="$(ledger_path).lock"
  : > "$lock"                                   # a regular file: rmdir cannot remove it
  touch -d '10 minutes ago' "$lock" 2>/dev/null || touch -t 200001010000 "$lock"
  run env LEDGER_LOCK_WAIT=3 bash -c "cd '$REPO' && LED_NO_EVIDENCE=1 bash .pipeline/tools/ledger.sh --ledger '$(ledger_path)' route --change c3 --predicted T2 --actual T2 --reason blocked"
  assert_exit 3
  assert_contains "rmdir"
  assert_contains "Nothing was written"
  rm -f "$lock"
}

test_c3_truncating_to_zero_bytes_cannot_slip_past_a_pin_or_an_anchor() {
  newrepo
  c3_route 1; c3_route 2
  local head; head="$(c3_head)"
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "ledger" >/dev/null 2>&1
  : > "$(ledger_path)"
  run led verify; assert_exit 0 "no pin: an empty ledger is just nothing to verify"; assert_contains "nothing to verify"
  run led verify --expect-head "$head"; assert_exit 1 "the pinned head catches a truncation to zero bytes"; assert_contains "BREAK"
  run led verify --against HEAD; assert_exit 1 "so does the git anchor"; assert_contains "NOT a prefix"
}

test_c3_the_ok_lines_say_what_they_do_not_prove() {
  newrepo
  c3_route 1
  git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "ledger" >/dev/null 2>&1
  run led verify; assert_exit 0; assert_contains "recomputing every later prev"
  run led verify --against HEAD; assert_exit 0; assert_contains "not anchored by this check"
}

test_c3_verify_refuses_unknown_options() {
  newrepo
  c3_route 1
  run led verify --bogus
  assert_exit 2
}

test_c1_commands_conf_is_a_t4_surface_in_the_kit_and_the_template() {
  assert_file_contains "$KIT/project/surfaces.conf" 'project/commands\.conf$::'
  assert_file_contains "$KIT/templates/project/surfaces.conf" '# T4::(^|/)project/commands\.conf$::'
  if grep -qE '^T4::.*project/commands' "$KIT/templates/project/surfaces.conf"; then
    _fail "the template must ship the commands.conf T4 row commented out"
  else _ok; fi
}

# ================================================================ runner
main() {
  local tests
  tests="$(declare -F | awk '{print $3}' | grep '^test_' | sort)"
  [ -n "$FILTER" ] && tests="$(printf '%s\n' "$tests" | grep -- "$FILTER")"

  if [ -z "$tests" ]; then
    echo "no tests matched '${FILTER}'" >&2
    exit 2
  fi

  echo "gated-change tests"
  echo "=================="
  [ -n "$PY" ]   || echo "  (no python found — JSON assertions will be skipped)"
  [ -n "$NODE" ] || echo "  (no node found — dashboard JS-logic assertions will be skipped)"

  local t
  for t in $tests; do
    CURRENT="$t"
    "$t"
  done

  echo
  printf 'passed %s · failed %s · skipped %s\n' "$PASS" "$FAIL" "$SKIP"
  if [ "$FAIL" -gt 0 ]; then
    echo
    echo "failing tests:"
    printf '  %s\n' $FAILED_NAMES | sort -u
    exit 1
  fi
  exit 0
}

main
