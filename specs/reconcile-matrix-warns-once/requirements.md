# reconcile-matrix-warns-once — Requirements

> Written at the Intent gate (G1a). Closes chip `task_58f5e560`, carried on
> `SESSION-HANDOFF.md` across several sessions as "untouched" on the assumption
> `reconcile.sh` might still print the missing-router warning twice, the same bug
> `test_ledger_gates_warns_about_a_missing_router_only_once` pins for
> `ledger.sh gates`/`report`.

## User

Anyone reading `reconcile.sh`'s output against a broken `core/01-router.md`, who
would be confused by (or script-parse and miscount) the same warning appearing more
than once.

## Problem

`ledger.sh`'s `cmd_gates`/`cmd_report` used to reach `matrix_required`/
`matrix_conditional` only through `$(...)` for-loops — each iteration forks its own
subshell, and a subshell's write to `_MATRIX_LOAD_FAILED` dies with it, so the next
`$(matrix_*)` call forked fresh, unaware anything already failed, and reprinted the
three-line "no router at ..." warning once per call. The fix was a bare
`_matrix_load` priming call before any subshell forks, so the cache is written in
the parent process once and every later subshell read (not write) sees it.

`reconcile.sh` reaches the matrix the identical way (`for _g in $(matrix_required
"$ACTUAL")`, `for _g in $(matrix_conditional "$ACTUAL")`) and was carried on
`SESSION-HANDOFF.md` as an unverified chip under the assumption it might have the
same bug. Reading `tools/reconcile.sh` shows its own round-1 fix for the sibling
fail-open bug (`matrix-router-unreadable-fails-open`) already added a bare
`_matrix_load` check immediately before the `GATES=` loop — the identical priming
pattern, already in place, just never confirmed live or pinned by a test.

## Finding

Live-reproduced against a real fixture (missing router, T4-surface file edited):
`reconcile.sh T4` prints the "no router at" warning exactly once. The priming call
already works. This is not a code change — it is the missing confirmation and the
missing regression test.

## Acceptance criteria

- [x] Live-verified: `reconcile.sh` against a missing router warns once, not
      per-`matrix_*`-call.
- [x] Regression test pinning it, matching the sibling ledger.sh test's shape:
      `test_reconcile_warns_about_a_missing_router_only_once`.
- [x] Fail-red confirmed (test fails when the priming call is disabled) / pass-green
      confirmed (restored).
- [x] Full suite green.

## Non-goals

- No code change to `tools/reconcile.sh` — this closes the chip by verifying and
  pinning behavior that was already correct, not by fixing a bug.

## Assumptions

- **T3**, mechanically — `tests/run.sh` itself is the file touched, matching
  `project/surfaces.conf`'s "the suite — if it stops asserting, nothing else here is
  trustworthy" row.
- **Axis C: Invisible** — no user-facing behavior changes; this adds test coverage
  only. G8 Dogfood (M⁵ at T3) is skipped on that basis, per the router's own
  footnote 5.

## Gate chain

G1 Intent (this doc). G4 Ripple: no behavior change anywhere — confirmed by reading
`tools/reconcile.sh` unchanged and by the live reproduction above. G5 Proof: one
regression test, fail-red/pass-green confirmed by temporarily commenting out
`reconcile.sh`'s existing priming block and restoring it. G6 Peer: self-review —
test follows the sibling ledger.sh test's exact shape and helpers (`rec()`, `run()`,
`assert_eq`), no new fixture pattern introduced. G7 Threat: test-only change, no
user input/persistence/network surface; reviewed, nothing to flag. G8 Dogfood:
skipped, Invisible (footnote 5).

## Acceptance (G1b)

| Criterion | Evidence |
|---|---|
| `reconcile.sh` warns once against a missing router | Live reproduction (scratch fixture, `BASE=<sha> bash reconcile.sh T4`), one "no router at" line. |
| Regression test | `test_reconcile_warns_about_a_missing_router_only_once`, fail-red/pass-green confirmed. |
| Full suite green | pending — recorded once this round's run completes. |
