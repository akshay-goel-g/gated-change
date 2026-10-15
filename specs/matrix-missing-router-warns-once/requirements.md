# matrix-missing-router-warns-once — Requirements

> Written at the Intent gate (G1a). Chip `task_0923d53d`, filed as a G8 Dogfood finding during
> the `ledger-success-shows-destination` session: `ledger.sh report`/`gates` printed the
> "no router" warning 4 times per invocation instead of once. Reproduced against a clean `HEAD`
> worktree with that session's change entirely absent, confirming the bug is pre-existing and
> unrelated to anything in that diff.

## User

Anyone running `ledger.sh report` or `ledger.sh gates` (or any tool that sources
`tools/lib/matrix.sh`) in a state where `core/01-router.md` is missing or malformed — most
realistically, mid-install before the router file has been copied into place, or a broken
`.pipeline/` checkout.

## Problem

`_matrix_load()` in `tools/lib/matrix.sh` caches a *successful* parse (`[ -n "$_MATRIX_TABLE" ]
&& return 0`) but never caches a *failed* one. Every public function in the file
(`matrix_gates`, `matrix_name`, `matrix_required`, `matrix_cell`, …) calls `_matrix_load` on
every invocation, and `ledger.sh`'s `cmd_gates` alone calls `matrix_gates` twice and
`matrix_name` (via `gate_name`) once per distinct gate row — so one missing-router invocation
reprints the same three-line "matrix: no router at …" warning once per call, not once per
process. Confirmed at exactly 4 repeats for `ledger.sh gates`/`report` against this repo's
ledger content, matching the chip's own description.

## Acceptance criteria

- [x] `_matrix_load` prints the "no router at" warning **at most once** per process when called
      directly (bare, no intervening `$(...)` fork) multiple times — the library-level cache.
- [x] `ledger.sh gates` and `ledger.sh report` — the two commands the chip actually named —
      print the warning **at most once per invocation**, verified against the real CLI (not
      just the library primitive), because every `matrix_*` call inside them goes through
      `$(...)`, which forks a subshell that can't write its cache back to the parent. **This
      does NOT generalize to every `matrix_*` caller** — `reconcile.sh` has the identical
      bug (still prints 2x, unfixed, out of scope here) via its own separate `$(...)` calls;
      `dashboard.sh`/`coverage.sh` are unaffected only because their existing call shape
      happens not to trigger it (already-redirected stderr, or a loop body never reached on
      failure). G4 round 2 found this scope gap; filed as a separate follow-up chip rather
      than expanded into this change.
- [x] Both failure paths (missing file, and file present but with no parseable gate rows) are
      covered by the same caching — a partial fix on only one path would leave the other
      re-triggering.
- [x] The existing success-path cache (`_MATRIX_TABLE`) is untouched — this only adds a
      negative cache alongside it.
- [x] No change to what `matrix_*` functions return on success — this is a diagnostics-output
      fix, not a behavior change to any gate-matrix answer.
- [x] Full suite still green after the change.

## Non-goals

- Does not change the warning's wording or destination (still 3 lines to stderr) — only how
  many times it fires per process.
- Does not address chip `task_01d75439` (the reconcile perf-test threshold) — separate chip,
  separate change.

## Assumptions

- **T4**, mechanically — `tools/lib/matrix.sh` and (incidentally, via the added test)
  `tests/run.sh` both match rows in `project/surfaces.conf` (T4 and T3 respectively; the
  change tiers at the higher of the two touched surfaces).
- **Axis C (visibility): Visible** — this changes what a user actually sees on their terminal
  (fewer duplicate warning lines) when the router is missing, so G8 Dogfood is mandatory at T4
  with no footnote to argue it away, and Ripple's "what breaks for someone mid-operation"
  question applies to the diagnostic-output path, not a normal one.
- No Scout (G2) or Craft (G3) trigger — this is a bug fix to existing internal diagnostics, not
  a net-new capability or a user-facing surface with a "look" to match.

## Round 1 → round 2: what changed

Round 1 shipped a negative-cache sentinel (`_MATRIX_LOAD_FAILED`) inside `tools/lib/matrix.sh`
only, plus a test that called `matrix_*` functions bare inside one already-running shell. Both
G7 Threat and G8 Dogfood (round 1, independently, one hard-gate one not) caught live against
the real CLI that this did **not** fix the named bug: every real caller
(`ledger.sh`/`reconcile.sh`/`dashboard.sh`/`lib/coverage.sh`) reaches `matrix_*` through a
`$(...)` command substitution, which forks a subshell — a subshell can *read* the cache
variable but a write it makes to it dies with the subshell on exit, so the next `$(matrix_*)`
call forks fresh and reprints. `ledger.sh gates`/`report` still printed the warning 4 times
after round 1's fix, confirmed directly: `bash tools/ledger.sh gates` against a missing router.

Round 2 fix: `cmd_gates()` (`tools/ledger.sh`) now calls `_matrix_load` once as a **bare
statement**, before any of its own `$(matrix_*)` subshells fork — priming the cache in the
process those subshells actually inherit from. Verified directly (not just via the test):
`bash tools/ledger.sh gates`/`report` against a missing router now print the warning exactly
once each, confirmed against a real repo clone both before (4x) and after (1x) the fix.

`tests/run.sh` gained a second test, `test_ledger_gates_warns_about_a_missing_router_only_once`,
that invokes `ledger.sh gates`/`report` as real subprocesses (the `led()` helper) rather than
calling `matrix_*` bare in one shell — this is the one that actually proves the chip's claim,
and it fails 4-vs-1 against the round-1 fix, confirmed by reverting only the round-2
`tools/ledger.sh` hunk and rerunning it.

G8 Dogfood round 1 also found a second, **pre-existing and unrelated** bug: `ledger.sh
compliance --tier T4` fails OPEN when the router is missing/broken ("Tier T4 mandates no gates.
Nothing to check.", exit 0) — because `matrix_required` returns empty on load failure and
`compliance` reads that as "nothing mandated" rather than "unknown, refuse." Reproduced
identically against `HEAD` (`f11cdb0`) with this session's diff entirely absent — pre-existing,
not introduced or worsened by this change. Per `02-gates.md`'s failure rule ("a finding can be
real and still not be about this change... route it to a separate follow-up item"), **not
fixed here** — filed as a new chip for a separate change.

## Acceptance (G1b)

Full T4 gate chain, two rounds:

| Criterion | Evidence |
|---|---|
| `ledger.sh gates`/`report` warn at most once | `tools/ledger.sh:1527` (`cmd_gates`'s bare `_matrix_load` prime). Verified live against a real repo clone: 4x before, 1x after. `tests/run.sh:1098` (`test_ledger_gates_warns_about_a_missing_router_only_once`) fails 4-vs-1 without the round-2 hunk, passes with it. |
| Library-level negative cache | `tools/lib/matrix.sh:26,42,80` (`_MATRIX_LOAD_FAILED`, set on both failure paths). `tests/run.sh:1062` (`test_matrix_missing_router_warns_once_per_process`). |
| No behavior change to gate-matrix answers | `git diff` — every `matrix_*` function's success-path return value is untouched; only the diagnostic print path changed. |
| Full suite green | **870/0/0**. |
| Gate chain | Round 1: G1 Intent, G4 Ripple, G6 Peer pass; G7 Threat (hard) passes but flags the fix doesn't survive real `$(...)` call paths (`info`, correctly not blocking a security gate — this is a fitness gap, not a trust-boundary one); G8 Dogfood **fails** on that same gap plus the pre-existing compliance fail-open bug. Round 2 (after the real fix in `tools/ledger.sh`): G1 (unchanged, requirement didn't change), G4 Ripple pass (minor: doesn't generalize to `reconcile.sh`, filed separately), G5 Proof pass (logged in-session per its `context: same session is fine` card), G6 Peer pass (0 findings), G7 Threat round 2 (hard) pass, G8 Dogfood round 2 **fails again** — not on the warning-dedup (confirmed fixed and clean this round) but on the same pre-existing compliance/reconcile fail-open bug, plus two newly-surfaced pre-existing minor findings (a `report`/`gates` exit-code mismatch on an empty ledger, `--help` not special-cased). `bash tools/ledger.sh compliance --change matrix-missing-router-warns-once --tier T4 --round 2`: **INCOMPLETE — 1 mandated gate without a pass (G8)**. |

**T4 compliance is left formally INCOMPLETE on G8, by explicit choice, not a silent gap** — matching the `ledger-success-shows-destination` precedent for the identical situation. G8's own rule (`fails_when: anything surprised you`, deliberately absolute) means a real, reproducible-in-two-independent-rounds surprise is logged `fail` honestly even though it isn't this change's bug: reproduced identically against `HEAD` (`f11cdb0`) with this entire diff reverted. Per `core/02-gates.md`'s failure rule ("a finding can be real and still not be about this change... route it to a separate follow-up item instead of back through Build for this change"), filed as two new chips rather than folded in:

- `task_8b9bc389` — `ledger.sh compliance`/`reconcile.sh` fail OPEN (exit 0, "nothing to check") when the router is missing/broken, instead of refusing. G7 round 2 rated this **high severity on its own merits** and recommended it be expedited, while confirming it does not need to block THIS change (pre-existing, and `cmd_compliance` never executes any line this diff touches).
- `task_58f5e560` — `reconcile.sh` has the identical duplicate-warning bug this change fixed for `ledger.sh gates`/`report` (still prints 2x), via its own separate `$(...)` calls to `matrix_required`/`matrix_conditional`. Found by G4 round 2, confirmed live.

The two smaller G8-round-2 findings (report/gates exit-code mismatch on an empty ledger; `--help` not special-cased) are queued in `SESSION-HANDOFF.md` rather than given individual chips — real but minor UX inconsistencies, unrelated to this change.
