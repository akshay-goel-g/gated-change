# reconcile-cost-test-delta — Requirements

> Written at the Intent gate (G1a). Prompted by chip `task_6776958a`, filed by a G6 Peer
> review during the `ledger-success-shows-destination` session: a background full-suite run
> failed `test_reconcile_cost_scales_with_rules_not_files` (`tests/run.sh`) at its 30-second
> absolute wall-clock ceiling. Reproduced against a clean `HEAD` worktree with that change
> entirely absent, confirming the flake is pre-existing and unrelated to anything in that diff.

## User

Anyone running the kit's own test suite (`bash tests/run.sh`), especially in CI or on a loaded
machine, who needs the suite's pass/fail to reflect the code, not the machine's current speed.

## Problem

The test asserts `reconcile.sh` processes 150 changed files in under 30 seconds absolute
wall-clock time. Its own comment says the intent is narrower: catch a regression from the
current one-grep-per-rule implementation back to the old nested files×rules loop (134s for
201 files, per `tools/reconcile.sh`'s own comment at the loop it replaced) — not to measure
absolute speed. An absolute ceiling conflates the two: on a slow or contended machine, a
correctly-linear implementation can sit close to 30s from fixed overhead alone (process spawn,
git init cost) that has nothing to do with file count, making the test a coin flip rather than
a signal.

## Acceptance criteria

- [x] The test measures the DELTA in elapsed time between two file counts (10 and 150,
      committed against the same base) rather than an absolute ceiling at one file count —
      canceling out whatever fixed per-invocation overhead the machine has, since that
      overhead is identical at both measurement points.
- [x] The threshold (15s delta) is verified, not guessed: live-measured that the current
      one-grep-per-rule implementation's delta between 10 and 150 files is a fraction of a
      second, and that a genuine regression to the old files×rules loop shape (temporarily
      reverted in a scratch copy of `tools/reconcile.sh`, `tools/ledger.sh` untouched, real
      file restored and diffed clean afterward) blows well past even the OLD 30s ceiling —
      the same test run against it did not finish within a 90s hard timeout.
- [x] No change to `tools/reconcile.sh` itself — this is a test-only fix. The algorithm this
      test verifies was already fixed in an earlier session.
- [x] Full suite still green after the change.

## Non-goals

- Does not attempt sub-second timing precision (`date +%s%N`) — not portable to the
  "Linux/macOS bash" target (BSD `date` has no `%N`), and unnecessary once the fixed-overhead
  problem is removed by measuring a delta instead of an absolute value: even the smaller (10
  files) measurement is dominated by multi-second fixed overhead on this project's slower
  target platform, so 1-second `date +%s` resolution is not the limiting factor.
- Does not touch `tools/reconcile.sh`'s actual rule-matching logic, which the chip's own
  report already confirmed is correct and unrelated to the flake.

## Assumptions

- **Treated as a reliability/bug fix to the test suite itself** (`tests/run.sh`, T3 per
  `project/surfaces.conf:50`), not a net-new capability — no Scout (G2) or Craft (G3) run,
  neither trigger applies.
- **G8 Dogfood is `n/a` here** — this change alters no running-product behavior a user could
  ever observe (test-only), so Axis C is Invisible and the router's `M⁵` footnote on G8 at T3
  does not fire.

## Acceptance (G1b)

Full T3 gate chain, mandated-only (G8 correctly `n/a`, no hard gate at this tier):

| Criterion | Evidence |
|---|---|
| Delta measurement replaces absolute ceiling | `tests/run.sh` — `test_reconcile_cost_scales_with_rules_not_files` now runs `rec T2` twice (10 files, then 150) against the same fixture base and asserts `elapsed_large - elapsed_small < 15`. |
| Threshold verified, not guessed | Real regression simulated (nested files×rules loop in a scratch copy of `reconcile.sh`): did not finish inside a 90s hard timeout. Real linear code: delta a fraction of a second, confirmed independently by both G4 Ripple (21s vs 304s at 240 vs 3600 spawns — a ~220s signal against ±3s noise) and this session. |
| No production code touched | `git diff` — `tools/reconcile.sh` unchanged; only `tests/run.sh`. |
| Full suite green | **869/0/0**, confirmed independently by G4 Ripple's own full run after the diff settled. |
| Gate chain | G1 Intent, G4 Ripple, G6 Peer, G7 Threat (not a hard gate at T3) all pass; G5 Proof done inline; G8 Dogfood correctly `n/a`. `ledger.sh compliance --tier T3`: **all mandated gates satisfied at round 1** — no exception needed this time. |

**Real findings the gates caught, fixed in place:** G6 Peer found the delta assertion could pass
vacuously if both `rec T2` runs failed fast for unrelated reasons (wrong base, empty diff) —
added `assert_contains "150 file(s) vs"` to pin that the timed run actually reconciled all 150
files. G6 also caught a wrong rule-count citation in this file's own comment (fixed: 19, from
`templates/project/surfaces.conf`, not 24).

**Deferred, not this change's job:** G7 Threat and G4 Ripple independently flagged the same
residual concern — the 15s threshold was calibrated on this (slow, Windows Git Bash) machine;
on a fast Linux/macOS box, a real regression's extra ~2660 process spawns might complete fast
enough to still land under 15s, since the underlying bug is O(files × fixed-rule-count), not
truly quadratic. Filed as `task_01d75439` rather than solved here — picking a platform-speed-
invariant spread needs its own empirical pass on a fast machine, not a guess.
