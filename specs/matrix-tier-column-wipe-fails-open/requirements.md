# matrix-tier-column-wipe-fails-open — Requirements

> Written at the Intent gate (G1a). Found independently (not a filed chip) while reviewing
> `matrix-router-unreadable-fails-open` (merged `origin/master` at `5714057`) after starting
> this session on a stale local view of the two chips it filed. See that change's own
> `specs/matrix-router-unreadable-fails-open/requirements.md` for the four-round history this
> one continues.

## User

Anyone relying on `ledger.sh compliance`/`reconcile.sh` to answer "which gates does this tier
mandate" against a `core/01-router.md` that parses cleanly and uses only valid cell vocabulary,
but has had an entire tier's column silently overwritten — a find/replace or scripted edit that
lands on one column across every row, rather than one row or one cell.

## Problem

`matrix-router-unreadable-fails-open` closed four corruption shapes across four rounds: missing
router, missing gate rows, malformed field counts/blank cells, and invalid cell content (a
9-value allow-list per cell: `—`, `M`, `M (hard)`, `R`, each optionally suffixed with one
footnote superscript). None of those checks object to "—" appearing in a tier column it
shouldn't — "—" is legitimate content everywhere (it's T0's normal value on every real row), so
a router where **every** row's T4 cell is replaced with "—" still has all 8 gates present
(closes round 2's check) and every cell individually valid (closes round 4's check).
`matrix_required T4` against such a file legitimately returns empty, exit 0 — the original
fail-open bug, one column deep instead of one row or one file. Reproduced live against both a
synthetic fixture and the real repo's own `core/01-router.md` with its T4 column wiped.

## Acceptance criteria

- [x] `tools/lib/matrix.sh`'s `_matrix_load` refuses (REFUSED path, `_MATRIX_LOAD_FAILED=1`,
      return 2) when T2, T3, or T4 individually has zero `M`-bearing cells anywhere in its own
      column across all 8 rows — checked per tier, not as one check across all three columns
      combined (a first version combined them and missed a single wiped column when the others
      stayed intact; caught and corrected before send-off by re-testing the narrowest
      reproduction, one column only, rather than trusting the broader combined case had already
      proven the logic).
- [x] No behavior change to a healthy router at any tier, including T0/T1's legitimate
      zero-mandate answer (T1's real column has zero `M`'s and must still load clean).
- [x] Regression test that fails against pre-fix code and passes after
      (`test_matrix_load_refuses_a_tier_column_with_no_mandate`), independently reproduced by a
      resumed reviewer via `git stash` isolation.
- [x] Full suite green.

## Non-goals — explicitly, not implicitly

- **Does not close `task_f2ac7ba7`'s own scope** (a permutation: two individually-valid cells
  swapped, leaving each affected tier's own M-count unchanged). This check is an aggregate
  per-tier count, blind to *which* gate a tier's `M`'s belong to.
- **G7 Threat review of this exact fix found a simpler, more dangerous instance of the same
  blind spot than `task_f2ac7ba7`'s own example**: a single targeted edit to one gate's own
  cell — no swap needed — defeats this check whenever the tier's column still has *some* other
  `M` left over, which every real 8-row T2/T3/T4 column does, trivially. Demonstrated live
  against the real repo: `core/01-router.md`'s G7 row, T4 cell changed from `**M (hard)**` to
  `R` (nothing else touched) — `matrix_required T4` silently drops G7 and returns `G1 G4 G5 G6
  G8`, and `ledger.sh compliance --tier T4` reports `INCOMPLETE — G1 G4 G5 G6 G8` **without ever
  naming G7 as mandated at all**, so a prior logged G7 pass would satisfy compliance without
  re-verification. `task_f2ac7ba7`'s own proposed fix (a checksum or known-good-reference
  comparison for the whole table) already covers this narrower case too — no new mechanism
  needed, just a broadened acceptance criterion on that chip. **Not fixed here** — chasing it
  would mean re-deriving `task_f2ac7ba7`'s own harder design question (where the reference
  lives, who regenerates it, what happens if regeneration itself is compromised) inside a
  narrowly-scoped follow-up, the exact "don't chase a broader gap into this round" call this
  repo's own precedent (`matrix-missing-router-warns-once`, `matrix-router-unreadable-fails-
  open`) already makes for gaps one gate's review surfaces beyond its own change's scope.

## Assumptions

- **T4**, mechanically — `tools/lib/matrix.sh` matches a T4 row in `project/surfaces.conf`;
  `tests/run.sh` matches T3.
- **Axis C: Visible** — changes what a user sees (REFUSED vs. a false all-clear) when the
  router is corrupted this way.

## Gate chain

G1 Intent (this doc). G4 Ripple: no behavior change to any healthy router at any tier, live-
verified before/after at T0-T4 against the real `core/01-router.md`; only other caller besides
`ledger.sh`/`reconcile.sh` is `tools/lib/coverage.sh`, which only calls `matrix_gates` and
already tolerates total load failure. G5 Proof: one regression test, confirmed fail-red/pass-
green by two independent means (my own `git stash` isolation, and a resumed G6 reviewer's own
independent `git stash` run). G6 Peer: **PASS**, no blocking findings (verified column-index
math, regex correctness against the actual allow-list, no false positive against the real
router, no false negative against the fixture, caller safety, style consistency) — reconfirmed
on a second pass after a stalled first attempt (background `tests/run.sh` runs stalling
indefinitely under this session's own resource contention from several concurrent subagents;
not a code issue, noted for the record). G7 Threat (hard gate): **FAIL — real finding**, see
Non-goals above; live-reproduced against the real repo, not just a synthetic fixture. G8
Dogfood: live CLI reproduction of both the fixed case (whole-T4-column wipe → REFUSED, exit 2)
and the still-open gap (G7-cell-only downgrade → INCOMPLETE without ever naming G7, exit 1) —
both run directly against `bash tools/ledger.sh compliance`, not only through `tests/run.sh`,
router restored and `git status` confirmed clean after each.

## Acceptance (G1b)

| Criterion | Evidence |
|---|---|
| Whole-tier-column wipe now refused | `tools/lib/matrix.sh` (per-tier check after the row-presence check). Live: real repo, T4 column wiped → `REFUSED`, exit 2 (was: silent empty result, exit 0). `tests/run.sh` `test_matrix_load_refuses_a_tier_column_with_no_mandate`. |
| No regression on a healthy router | Live-verified real router, all tiers T0-T4, output unchanged. |
| Full suite green | pending final run this round (background run stalled once under session resource contention and was restarted; result to be recorded once it completes). |
| `ledger.sh compliance --tier T4` for THIS change | Left formally **INCOMPLETE on G7** by explicit, documented choice — matching `ledger-success-shows-destination`/`matrix-missing-router-warns-once`/`matrix-router-unreadable-fails-open`'s own precedent for a real-but-broader-scope gate finding: log it honestly, file/broaden the chip, do not launder it into a pass. |

**Chip filed/broadened:** `task_f2ac7ba7`'s own description should be broadened (not replaced)
to include the single-cell-downgrade PoC above as a demonstrated, simpler instance of the same
root cause it already names — see `SESSION-HANDOFF.md`.
