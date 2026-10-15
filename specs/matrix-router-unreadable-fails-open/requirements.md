# matrix-router-unreadable-fails-open — Requirements

> Written at the Intent gate (G1a). Chip `task_8b9bc389`, filed as a G8 Dogfood finding
> (round 1) and rated high severity by G7 Threat (round 2) during the
> `matrix-missing-router-warns-once` session (`specs/matrix-missing-router-warns-once/requirements.md`):
> `ledger.sh compliance`/`reconcile.sh` fail OPEN (exit 0, "nothing to check" / "Reconciled —
> routing matches") when `core/01-router.md` is missing or unreadable, instead of refusing.
> Reproduced identically against `HEAD` (`f11cdb0`) with this session's diff entirely absent —
> confirmed pre-existing, unrelated to any recent change.

## User

Anyone running `ledger.sh compliance --tier <T>` or `reconcile.sh <tier>` — the two commands
`core/01-router.md`'s own R0b section names as the mechanical, non-negotiable release check
("not self-graded... the one that decides release") — in a state where the router file is
missing, empty, or fails to parse. Realistically: a broken `.pipeline/` checkout, a bad
`MATRIX_ROUTER` override, or the router accidentally deleted/corrupted between commits.

## Problem

`tools/lib/matrix.sh`'s `matrix_required()` and `matrix_conditional()` both call `_matrix_load`
first and correctly propagate its failure (`_matrix_load || return 2`), but their OUTPUT is
empty on failure — identical to the output when a tier legitimately mandates no gates. Every
caller reads only the output, never the exit code:

- `tools/ledger.sh`'s `required_gates_for()` wraps `matrix_required` in a pipe
  (`matrix_required "$1" | tr '\n' ' '`) and `cmd_compliance` only checked
  `[ -z "$req" ]` — never `$?` — before printing `"Tier $tier mandates no gates. Nothing to
  check."` and exiting 0.
- `tools/reconcile.sh` consumes `matrix_required`/`matrix_conditional` inside
  `for _g in $(...)` loops, which discard a command substitution's exit status entirely by
  construction — there was no `$?` left to check even if the code had tried. An unreadable
  router read back as `Gates : none mandatory` followed by `Reconciled — routing matches. This
  says nothing about whether the gates above ran.` and exit 0.

Both tools already print `_matrix_load`'s own three-line "matrix: no router at ..." warning to
stderr before falling through to the false-positive success path — the information needed to
refuse was already on screen, and the caller ignored it anyway.

## Acceptance criteria

- [x] `ledger.sh compliance --tier <any>` REFUSES (exit 2, `REFUSED` on stderr) when the router
      cannot be read, regardless of which tier was requested — never "Tier $tier mandates no
      gates."
- [x] `reconcile.sh <any tier>` REFUSES (exit 2, `REFUSED` on stderr) when the router cannot be
      read — never `Gates : none mandatory` / `Reconciled — routing matches`.
- [x] A tier that legitimately mandates nothing (T0, router intact and readable) is UNCHANGED:
      `compliance --tier T0` still prints "Tier T0 mandates no gates. Nothing to check." and
      exits 0. The fix must distinguish the two "empty" cases, not collapse both to refusal.
- [x] No change to `matrix_required`/`matrix_conditional`'s return value or output shape on the
      success path — this only adds a check at the two call sites that were ignoring the
      already-correct return code (and, for reconcile.sh, where a return code could not
      previously be observed at all).
- [x] Full suite still green after the change.

## Non-goals

- Does not change `_matrix_load`'s own caching behavior (fixed separately in
  `matrix-missing-router-warns-once`) or its warning text.
- Does not add router-recovery logic (e.g. falling back to a default matrix) — refusing loudly
  is the fix; guessing a matrix is exactly the failure mode `_matrix_load`'s own header rejects.
- Does not touch `dashboard.sh` or `lib/coverage.sh`'s use of `matrix_*` — neither reads
  `matrix_required`/`matrix_conditional` for a release-gating decision the way `compliance`/
  `reconcile` do; out of scope unless a fresh-context gate finds an equivalent fail-open there.

## Assumptions

- **T4**, mechanically — `tools/lib/matrix.sh`, `tools/ledger.sh`, and `tools/reconcile.sh` all
  match T4 rows in `project/surfaces.conf` ("Routing and evidence — a wrong answer here is
  silent and confident"). `tests/run.sh` matches its own T3 row.
- **Axis C (visibility): Visible** — this changes what a user sees on the terminal (a REFUSED
  exit 2 instead of a false "nothing to check"/"reconciled" exit 0) in the exact failure state
  the change targets, so G8 Dogfood is mandatory at T4 with no footnote to argue it away.
- No Scout (G2) or Craft (G3) trigger — bug fix to existing internal tooling, not a net-new
  capability or a user-facing surface with a "look" to match.

## Round 1 → round 2: what changed

Round 1 shipped exactly the fix scoped above: a direct `_matrix_load` check inserted at the two
call sites (`tools/ledger.sh`'s `cmd_compliance`, `tools/reconcile.sh`) that were reading
`matrix_required`/`matrix_conditional`'s empty output as "nothing mandated" without checking
whether the load itself had failed. That closes the whole-file-missing and whole-table-empty
cases, and only those.

G7 Threat (round 1, hard gate) and G8 Dogfood (round 1), independently and in fresh sessions,
both found the same gap live: `_matrix_load` itself (unchanged by round 1, and not in this
change's original scope) accepts the table as intact once **any** row parses — a single
malformed row (a dropped column, a reflowed line from a bad merge) is silently skipped by the
awk parser's `NF < 9` guard and never surfaces as an error, so `_MATRIX_TABLE` stays non-empty
and `_matrix_load` returns success. Both gates reproduced this against **G7's own row** — at
T4 the router marks G7 `**M (hard)**`, so this is the one gate whose entire purpose is to be
non-skippable, silently disappearing from `matrix_required`/`matrix_gates` with the round-1
fix never triggering (its own `_matrix_load` check saw success, correctly, because load really
did "succeed" by the old, insufficient definition of success). `reconcile.sh T4` printed
`Gates : Intent, Ripple, Proof, Peer, Dogfood` (Threat silently absent) and `Reconciled —
routing matches`, exit 0; `ledger.sh compliance` printed `All T4-mandated gates satisfied`,
exit 0, with G7 never logged.

This is not a new, unrelated bug: it is the same failure class this change's own name commits
to closing ("router unreadable" fails open), one row deep instead of the whole file — and it
was already found and explicitly deferred once before, over a month earlier
(`security-reports/2026-08-13-first-push-matrix-hook-review.md`, Finding 1, reproduced against
this exact G7 row, "not fixed in this pass... flagging for a deliberate follow-up"). Per
`core/02-gates.md`'s failure rule, a finding stays in scope for the change under review when it
is about that change; this is.

Round 2 fix: `_matrix_load` (`tools/lib/matrix.sh`) now verifies, after parsing, that every one
of the eight built-in gates (G1..G8) actually produced a row — not just that the table is
non-empty — and fails loud (same `_MATRIX_LOAD_FAILED` / exit 2 path as the whole-file-missing
case) naming which gate id(s) are missing. Verified live against the exact G7-row-truncation
reproduction from the 2026-08-13 report: `matrix_required T4`, `ledger.sh compliance --tier
T4`, and `reconcile.sh T4` all now refuse (exit 2, `REFUSED`) instead of silently omitting G7.
A new test, `test_matrix_load_refuses_a_single_malformed_row` (`tests/run.sh`), pins this via
the same G7-row-truncation shape and exercises all three surfaces (`matrix_required` directly,
`ledger.sh compliance`, `reconcile.sh`).

## Acceptance criteria — round 2 addendum

- [x] A single malformed/dropped gate row (table otherwise intact) is treated identically to a
      wholly missing/empty router by `matrix_required`/`matrix_conditional`'s callers: REFUSED,
      exit 2, not a silently short gate list.
- [x] The check names which gate id(s) are missing, not just "something is wrong" — a
      operator fixing the router needs to know which row to look at.
- [x] No change to `matrix_required`/`matrix_conditional`'s behavior when the table is fully
      intact (all eight rows present) — verified via the full suite and direct sanity check.

## Round 3 → round 4: what changed, and where this change's scope ends

Round 3 (a fresh-context G7 Threat run) found round 2's row-presence check was itself
insufficient in two more ways, both live-reproduced: a row missing exactly ONE pipe (fusing
two adjacent cells) landed at `NF=9`, which the old `NF < 9` guard let through; and a row with
the correct field count but one cell blanked outright also passed. The same G7 session then
found a third gap: two edits to one row whose pipe-count changes cancel out (`NF` stays exactly
10, no cell blank) while content shifts into the wrong column.

Round 4 fix: replaced every shape-only check (`NF < 9`, `NF != 10`, blank-cell) with a single
CONTENT allow-list — each tier cell, after trimming and de-asterisking, must match one of the
nine values every real row in `core/01-router.md` actually uses (an em dash, or `M`/`R`
optionally suffixed with `(hard)` or one footnote superscript). This closes round 3's finding
(verified live) and, being a positive allow-list rather than another negative shape check,
closes the whole class of "wrong-shaped cell content" at once rather than the one shape most
recently found.

**A fourth fresh-context G7 round then found a different-in-kind gap, and this is where Build
stopped rather than continuing to patch `_matrix_load`:** the content allow-list validates
*vocabulary*, never *position*. Swapping two cells that are each individually legal — within
one row (G7's T1 and T4 cells), or across two rows (G7's and G4's T4 cells) — produces a
syntactically perfect table, with `_matrix_load` returning success and no warning, while a
gate's mandate silently attaches to the wrong tier or the `(HARD GATE)` label migrates onto
the wrong gate in `reconcile.sh`'s printed output. Full transcripts:
`security-reports/2026-09-16-matrix-router-unreadable-fails-open-round4.md`.

**This is not the bug this change set out to fix, and it cannot be closed by tightening
`_matrix_load` further.** The original ask (see "Problem" above) is about `_matrix_load`
*failing to parse* the router and that failure reading back as "nothing mandated". A permuted
row is not a parse failure — every field is present, every cell is legal vocabulary, and
`_matrix_load` succeeding on it is *correct* behavior for a parser whose job is syntactic
validation. Detecting that the table's *content* has been silently rearranged is a different
problem (data-integrity / tamper-detection against a known-good reference — a checksum or a
canonical copy, regenerated whenever the router legitimately changes) requiring a mechanism
this change never built and was never asked to build. Per `core/02-gates.md`'s failure rule — a
real finding outside the change under review is logged as the fail it is, not softened, and
routed to a separate follow-up rather than folded back through Build here — this is filed as
chip `task_f2ac7ba7` rather than attempted as a round 5.

A fresh-context G8 Dogfood round (also round 4, run independently and blind to G7's report per
the card's withhold rule) converged on the same architectural limit by a different route:
hunting for a "lucky coincidence" rather than deliberately constructing one, it found that
G4's row — which happens to carry the same value (`M`) across three consecutive tier
columns — survives the identical compensating-double-edit technique round 3/4 were built to
catch, producing a fully clean, exit-0 result with the row's actual T0/T1 values scrambled to
values that appear nowhere else in the table. Reproduced twice. G7's round-4 report and this
independent confirmation agree: per-cell vocabulary validation cannot close this, no matter how
tightly the allow-list is drawn, because whether a scrambled row happens to still validate is a
property of that gate's own specific cell values, not of the check. Two independent
fresh-context reviewers reaching the same conclusion by different paths is why Build stopped
here rather than attempting a round 5 shape patch.

**T4 compliance is left formally INCOMPLETE on G8, by explicit choice, not a silent gap** —
the same precedent this repo already set for the identical situation in
`matrix-missing-router-warns-once` (see that change's own requirements.md). `cmd_compliance`
counts a gate as satisfied if it passed at ANY round (`gate_passed_round`), marking it stale
(`PASS*`) rather than failed once a later round moves past it — so G7's genuine round-2 pass
still counts, `PASS*` at round 4, even though rounds 3 and 4 found new, real findings past that
point. G8 never passed at any round for this change (all four rounds found something real), so
it is the one gate `bash tools/ledger.sh compliance --change matrix-router-unreadable-fails-open
--tier T4 --round 4` reports as unsatisfied:

```
PASS*      G1   Intent    passed at round 1 — 3 round(s) of changes since
PASS*      G4   Ripple    passed at round 2 — 2 round(s) of changes since
PASS*      G5   Proof     passed at round 1 — 3 round(s) of changes since
PASS*      G6   Peer      passed at round 2 — 2 round(s) of changes since
PASS*      G7   Threat    passed at round 2 — 2 round(s) of changes since
FAIL       G8   Dogfood   4 finding(s) logged — re-run required before release
INCOMPLETE — 1 mandated gate(s) without a pass: G8
```

What this change actually closes — parse-failure fail-open, in every shape found across four
rounds (whole file, single malformed row, fused/blank cells, content-shifted cells) — is
complete and verified, per G7's own `PASS*` history and the tests pinning each shape.
Row-permutation (G7 round 4's finding, independently reproduced by G8 round 4) is a distinct,
real, separately-owned problem, filed as `task_f2ac7ba7` rather than chased into a round 5.

## Acceptance (G1b)

| Criterion | Evidence |
|---|---|
| `compliance` refuses on unreadable router, any tier | `tools/ledger.sh` (`cmd_compliance`, the `_matrix_load` check inserted directly after the tier-validation `case`). `tests/run.sh` `test_ledger_compliance_refuses_when_router_missing` — fails (exit 1, "No ledger…") before fixture correction, then fails correctly (exit 1 got vs exit 2 want, no REFUSED) against the unfixed `tools/ledger.sh` with the fixture corrected; passes after the fix. Confirmed via `git stash` isolating the fix commits from the test commit and re-running. |
| `reconcile` refuses on unreadable router, any tier | `tools/reconcile.sh` (the `_matrix_load` check inserted directly before the `GATES=""` computation). `tests/run.sh` `test_reconcile_refuses_when_router_missing` — same stash-isolated fail-before/pass-after proof. |
| T0 (legitimately empty) unaffected | `tests/run.sh` `test_ledger_compliance_reports_nothing_to_check_when_tier_legitimately_empty` — exit 0, "mandates no gates", router intact. |
| Single malformed row (any gate), fused cell, blank cell, content-shifted cell all refuse | `tests/run.sh`: `test_matrix_load_refuses_a_single_malformed_row`, `test_matrix_load_refuses_a_malformed_row_for_every_gate` (all 8 gates individually), `test_matrix_load_refuses_a_fused_cell_row`, `test_matrix_load_refuses_a_row_with_a_blank_cell`, `test_matrix_load_refuses_a_content_shifted_row` — each stash-isolated fail-before/pass-after. |
| Manual reproduction, both before and after | Scratch copy of the worktree with `core/01-router.md` removed, and separately with single rows corrupted in each of the above shapes: `ledger.sh compliance --change x --tier T4` and `BASE=HEAD reconcile.sh T4` both now print `REFUSED` and exit 2 (previously exit 0/1 with a false-positive "all clear"). Router restored: both tools' normal behavior is bit-for-bit unchanged. |
| Cell-permutation (out of scope) honestly tracked, not silently dropped | G7 and G8 round 4 `fail` on the ledger, both independently reproduced; chip `task_f2ac7ba7` filed; `bash tools/ledger.sh compliance --tier T4 --round 4` reports `INCOMPLETE — G8` accordingly (this document's "Round 3 → round 4" section above). |
| Full suite | See ledger G5 entry and the final pre-commit run — 0 failures across every round's own filtered runs; a fresh top-to-bottom run confirms no regression. |
