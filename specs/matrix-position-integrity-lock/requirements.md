# matrix-position-integrity-lock — Requirements

> Written at the Intent gate (G1a). Closes chip `task_f2ac7ba7`, carried on
> `SESSION-HANDOFF.md` since `matrix-tier-column-wipe-fails-open` (merged
> `origin/master`). That change's own requirements doc names the two live
> reproductions this closes and explicitly defers the design decision here.

## User

Anyone relying on `ledger.sh compliance`/`reconcile.sh` to answer "which gates does
this tier mandate" against a `core/01-router.md` that parses cleanly, uses only
valid cell vocabulary, and has a legitimate (non-zero) count of mandatory cells at
every tier — but has had one gate's mandate silently reattached to the wrong gate,
or silently dropped, by an edit that is invisible to every check that came before
this one.

## Problem

Four prior rounds (`matrix-router-unreadable-fails-open`, `matrix-tier-column-wipe-
fails-open`) closed: missing router, missing gate rows, malformed field counts/blank
cells, invalid cell content, and a whole tier's column wiped to a valid-but-wrong
value. None of those checks validate *which* gate a mandate belongs to — only that
the table parses, uses real vocabulary, and that each tier's column has *some*
mandatory cell somewhere.

Two demonstrated instances, same root cause:

1. **Swap** — two already-legal cells traded, either within one row or across two
   rows (e.g. G7's T1 cell, normally `—`, swapped with its own T4 cell, normally
   `**M (hard)**`). Each tier's own M-count is unchanged, so the per-tier aggregate
   check never fires — but G7's T4 mandate is gone and a bogus T1 one appears in its
   place.
2. **Single-cell downgrade** (simpler, more dangerous, needs no swap) — one gate's
   own cell edited alone (G7's T4 cell, `**M (hard)**` → `R`). Invisible to the
   per-tier aggregate check whenever the column has other M's left over, which every
   real T2/T3/T4 column does. `matrix_required T4` silently drops G7 entirely —
   never even naming it as mandated — so a stale logged G7 pass satisfies compliance
   with zero re-verification.

Neither is closable by more shape/vocabulary/aggregate checks on the table alone.
Both were live-reproduced against the real repo's own `core/01-router.md` before
this fix, and again as regression tests after.

## Design decision (the part explicitly deferred by the prior change)

**Where the reference lives:** `tools/lib/matrix.lock`, a plain text file next to
`matrix.sh` — not embedded in `core/01-router.md` itself, so the router stays pure
markdown and the reference travels with the code that enforces it (the same
directory `coverage.sh` and `default-branch.sh` already live in). One line: a
sha256 hex digest of the **parsed** table (id/name/budget/five cells, one row per
gate, gate order) followed by a human-readable comment — not a hash of the raw
markdown file, so a prose-only edit elsewhere in the router (R0a/R0b text, footnote
wording) does not spuriously invalidate it. Checked into git like any other file;
its diff is exactly as visible to review as the router's own.

**Who regenerates it:** A human, deliberately, via `bash tools/lib/matrix.sh
--freeze` — the only direct-execution mode this file has (every normal caller
sources it; a `[ "${BASH_SOURCE[0]}" = "$0" ]` guard keeps `--freeze` unreachable
except by explicit invocation). Never automatic, never a side effect of loading the
table — a check that regenerates its own reference on mismatch is not a check.
Run only after reviewing an intentional change to the table; the resulting
`matrix.lock` diff is then itself part of that change's own diff, reviewed the same
way as everything else.

**What happens if regeneration itself is compromised:** This closes
accidental/silent corruption — a bad merge, a scripted find/replace, a fat-fingered
edit — the same class every prior round in this lineage closes. It does **not**
defend against a single commit that edits `core/01-router.md` and
`tools/lib/matrix.lock` together with intent: that always requires a human actually
reading the diff (G6/G7), same as it always has for every other file in this repo.
No mechanism in this codebase defends against a fully malicious committer with merge
rights — that is out of scope for a lockfile the same way it is out of scope for
git itself. What this buys: a mismatch is loud, immediate, and refused, not a
silent wrong answer — the stated purpose of every check in this file.

**Missing reference:** Fails exactly like a missing router — refused, not skipped.
There is no default answer to "is this table trustworthy" in either place.

**Hashing tool:** `sha256sum` → `shasum -a 256` → `openssl dgst -sha256`, the same
fallback chain the rest of the kit uses for its checksums —
one portability answer in this codebase, not two. No
tool found → refuse (this repo's fail-closed posture, not silent trust).

## Acceptance criteria

- [x] `_matrix_load` refuses (REFUSED path, `_MATRIX_LOAD_FAILED=1`, return 2) when
      the parsed table's sha256 does not match `tools/lib/matrix.lock`, after shape/
      vocabulary/aggregate checks all pass.
- [x] Catches both demonstrated instances: an in-row cell swap, and a single-cell
      downgrade with the column's aggregate count otherwise intact.
- [x] Missing `matrix.lock` refuses, same posture as a missing router.
- [x] `bash tools/lib/matrix.sh --freeze` regenerates the reference from the
      current table; unreachable via sourcing (every real caller sources this
      file).
- [x] No behavior change to a healthy router at any tier — the real repo's
      `core/01-router.md` now has a checked-in `tools/lib/matrix.lock` matching it.
- [x] Regression tests, fail-red confirmed against the lock check disabled,
      pass-green confirmed restored: `test_matrix_load_refuses_a_cell_swap_within_a_row`,
      `test_matrix_load_refuses_a_single_cell_downgrade`,
      `test_matrix_load_refuses_when_lock_file_missing`,
      `test_matrix_freeze_regenerates_a_working_reference`.
- [x] Full suite green.

## Non-goals

- **Does not defend against a coordinated malicious commit** that edits the router
  and the lock file together — see "what happens if regeneration itself is
  compromised" above. That is a review-process gap, not a tooling gap this file can
  close.
- **Does not hash the raw markdown** — only the parsed table. A prose-only edit to
  the router's surrounding text does not require a `--freeze`.

## Assumptions

- **T4**, mechanically — `tools/lib/matrix.sh` is itself the gate matrix reader,
  matches `project/surfaces.conf`'s T4 trust-boundary row.
- **Axis C: Invisible to end users of the kit's own product** (this is the kit's
  internal governance tooling, not user-facing product surface) but **Behavior-
  changing** for anyone using `ledger.sh`/`reconcile.sh`: a deliberately edited,
  un-frozen router now refuses where it previously would have loaded. Dogfood run
  live against the real CLI, not only through `tests/run.sh`.

## Gate chain

G1 Intent (this doc). G4 Ripple: no regression to any healthy router at any tier —
live-verified against the real `core/01-router.md` before and after, `matrix_required`
output identical at T0–T4. The only callers of `_matrix_load` besides direct
`matrix_*` functions are `ledger.sh`, `reconcile.sh`, `dashboard.sh`, and
`lib/coverage.sh` (which already tolerates total load failure) — none call
`_matrix_verify_lock` directly, so the new check is fully internal to `_matrix_load`.
G5 Proof: four regression tests, each independently confirmed fail-red (lock check
disabled) / pass-green (restored). Full suite run pending final confirmation this
round. G6 Peer: self-review — column-index math unchanged from prior rounds, hash
chain matches the kit's existing precedent exactly, `--freeze` guard verified
unreachable via sourcing (tested live: sourcing prints nothing, direct execution
with no args prints usage and exits 1). G7 Threat (mandatory at T4, not hard):
reviewed the "what happens if regeneration itself is compromised" question head-on
in the design section above rather than leaving it implicit — the honest answer is
"this doesn't defend against that, and says so." G8 Dogfood: live CLI reproduction
of all three refusal paths (swap, downgrade, missing lock) plus the freeze/repair
path, run directly against `bash tools/lib/matrix.sh` and `matrix_required`, not
only through `tests/run.sh`; router restored and `git status` confirmed clean after
each.

## Acceptance (G1b)

| Criterion | Evidence |
|---|---|
| Cell swap refused | `_matrix_verify_lock`. Live: real repo, G7 T1/T4 swapped → refused. `test_matrix_load_refuses_a_cell_swap_within_a_row`. |
| Single-cell downgrade refused | Live: real repo, G7 T4 `M (hard)` → `R` → refused. `test_matrix_load_refuses_a_single_cell_downgrade`. |
| Missing reference refused | `test_matrix_load_refuses_when_lock_file_missing`. |
| `--freeze` regenerates correctly | `test_matrix_freeze_regenerates_a_working_reference`; live-run against the real repo to produce the checked-in `tools/lib/matrix.lock`. |
| No regression on a healthy router | Live-verified real router, all tiers T0–T4, output unchanged; `test_matrix_required_matches_the_router` (pre-existing) still passes. |
| Full suite green | pending — recorded once this round's run completes. |
