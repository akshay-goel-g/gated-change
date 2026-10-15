# G7 · Threat review — `matrix-router-unreadable-fails-open` (T4, hard gate, round 3, 7c depth)

**Reviewed:** the **uncommitted working-tree diff on top of `bbcb30d6fa3974ccc8c27b41994f77bc5980dca2`**
("auto: regenerate dashboard.html (pre-push)") — `git rev-parse HEAD` confirmed →
`bbcb30d6fa3974ccc8c27b41994f77bc5980dca2`, unchanged from rounds 1-2. Subject: the FULL current
diff (round 1's direct `_matrix_load` guards in `tools/ledger.sh`/`tools/reconcile.sh`, round 2's
G1..G8 row-completeness loop, and round 3's `NF != 10` + blank-cell tightening inside
`tools/lib/matrix.sh`'s `_matrix_load`, plus the accompanying `tests/run.sh` additions), obtained
via `git diff -- tools/lib/matrix.sh tools/ledger.sh tools/reconcile.sh tests/run.sh`. Fresh
session; only this prompt, `project/surfaces.conf`, the diff, `core/06-extending.md`, and my own
round-1/round-2 reports (`security-reports/2026-09-16-matrix-router-unreadable-fails-open.md`,
`...-round2.md`) were read. `specs/matrix-router-unreadable-fails-open/requirements.md` was **not**
opened, per the card's `withhold` line.

**Files in scope and their tier** (`project/surfaces.conf`): `tools/ledger.sh` and
`tools/reconcile.sh` — **T4** (`:27`, "Routing and evidence — a wrong answer here is silent and
confident"); `tools/lib/matrix.sh` — **T4** (`:28`, "The gate matrix reader — decides what is
mandatory"); `tests/run.sh` — T3. Change tier = **T4**, hard gate.

---

## What changed since round 2

`tools/ledger.sh` and `tools/reconcile.sh` are unchanged from round 1. Round 2's contribution
(`_matrix_load` walking a hardcoded `G1..G8` and refusing if any is absent from the parsed table)
was itself found, live, by a fresh-context **G8 Dogfood** run after my round-2 G7 pass: the awk
guard it depended on was `NF < 9`, which accepts `NF == 9` — a row missing exactly one pipe (two
adjacent cells fused) lands at NF=9 and is kept, with the fused pair eating the last cell (always
T4) and leaving it empty. A sibling shape — correct pipe count, one tier cell's text deleted
outright — produced the identical outcome by a different path.

Round 3 (Build), reviewed here, changed `tools/lib/matrix.sh:75` from `if (NF < 9) next` to
`if (NF != 10) next` — exact field count, not a minimum — and added a per-cell blank check
(`:85-93`): each of the five tier cells is trimmed and tested for emptiness after trimming; if any
is blank, the row is dropped (`next`) exactly as an insufficient-NF row already was. Both routes
feed the same downstream mechanism: a dropped row leaves that gate absent from `_MATRIX_TABLE`,
which round 2's `G1..G8` presence loop (`:116-129`) catches and refuses on (`return 2`, naming the
gate). No caller changed.

---

## The walk — real commands, real output, against a scratch copy

Built a fresh scratch repo mirroring `tests/run.sh`'s `newrepo()` fixture
(`.../scratchpad/g7round3/repo1`, full `.pipeline/` copy of this worktree, `git init`), and ran the
kit's own new tests through the real harness where noted.

### 1 · Round 2's own findings — fused cell and blank cell — closed, live and via the harness, through the full CLI

Re-ran G8's exact two round-2 repros, this time driving `ledger.sh compliance` and `reconcile.sh`
directly (not just the library function), since round 2's own new tests for these two shapes
(`test_matrix_load_refuses_a_fused_cell_row`, `test_matrix_load_refuses_a_row_with_a_blank_cell`)
only call `matrix_required` — the library primitive — and never exercise the CLI. **Fused cell**
(G7's T3/T4 pipe dropped, `NF=9`):
```
$ sed -i 's/| R⁴ | M | \*\*M (hard)\*\* |/| R⁴ | M **M (hard)** |/' core/01-router.md
$ bash tools/ledger.sh compliance --change c --tier T4; echo $?
matrix: .../01-router.md is missing a row for: G7
REFUSED: the gate matrix could not be read — see the error above.
2
$ BASE=<sha> bash tools/reconcile.sh T4; echo $?
matrix: .../01-router.md is missing a row for: G7
REFUSED: ...
2
```
**Blank cell** (G6's T4 cell text deleted, `NF=10`, correct count):
```
$ sed -i 's/| \*\*G6 · Peer\*\* | Staff engineer | 15 min | — | R | M | M | M |/| **G6 · Peer** | ... | M |  |/' core/01-router.md
$ bash tools/ledger.sh compliance --change c --tier T4; echo $?
matrix: .../01-router.md is missing a row for: G6
REFUSED: ...
2
$ BASE=<sha> bash tools/reconcile.sh T4; echo $?
matrix: .../01-router.md is missing a row for: G6
REFUSED: ...
2
```
Both of round 2's blocking findings are closed, confirmed through the release-blocking commands
themselves, not only the library. Also confirmed via the real harness:
`bash tests/run.sh matrix_load_refuses` → `passed 20 · failed 0 · skipped 0` (covers both shapes
for every one of the 8 built-in gates, per `test_matrix_load_refuses_a_malformed_row_for_every_gate`'s
pattern extended to the new checks).

### 2 · NF > 10 — a stray extra pipe inside a cell's text — correctly rejected

Round 2's `NF < 9` would have let this through untouched (9 was never checked against an upper
bound). Injected a literal `|` inside G7's `R⁴` cell text (`R⁴` → `R|⁴`, the shape a typo or a
careless find-and-replace produces), landing at `NF=11`:
```
$ awk -F'|' '/^\| \*\*G7/ {print NF}' core/01-router.md
11
$ ( . tools/lib/matrix.sh; matrix_gates; matrix_required T4 ) 2>&1
matrix: .../01-router.md is missing a row for: G7
```
`NF != 10` closes the "too many" direction as well as "too few" — confirmed live, not just read
from the awk source.

### 3 · Whitespace-only cell — correctly treated as blank

`   ` (three spaces, no visible text) in place of G7's T4 marker, pipe count intact (`NF=10`):
```
$ ( . tools/lib/matrix.sh; matrix_required T4 ) 2>&1
matrix: .../01-router.md is missing a row for: G7
```
`gsub(/^[ \t]+|[ \t]+$/, "", cell)` (`matrix.sh:87`) strips the whitespace to nothing, and the
`cell == ""` test (`:89`) fires — a whitespace-only cell is exactly as caught as a truly empty one.

### 4 · Two different gates blanked simultaneously — both named, through the full CLI

Blanked G4's and G8's T4 cells in the same table (structure intact, `NF=10` for both rows):
```
$ ( . tools/lib/matrix.sh; matrix_required T4 ) 2>&1
matrix: .../01-router.md is missing a row for: G4 G8
$ bash tools/ledger.sh compliance --change c --tier T4
matrix: .../01-router.md is missing a row for: G4 G8
REFUSED: the gate matrix could not be read — see the error above.
$ BASE=<sha> bash tools/reconcile.sh T4
matrix: .../01-router.md is missing a row for: G4 G8
REFUSED: ...
```
`$_missing`'s accumulation loop (`matrix.sh:116-119`) names both, space-separated, not truncated to
one — confirmed at the library level and through both CLI entry points.

### 5 · Regression — no false positive against the real, intact router

```
$ awk -F'|' '/^\| \*\*G[0-9]/ {print $2, "NF="NF}' core/01-router.md
 **G1 · Intent**  NF=10
 **G2 · Scout**  NF=10
 **G3 · Craft**  NF=10
 **G4 · Ripple**  NF=10
 **G5 · Proof**  NF=10
 **G6 · Peer**  NF=10
 **G7 · Threat**  NF=10
 **G8 · Dogfood**  NF=10
$ ( . tools/lib/matrix.sh; matrix_gates; echo exit=$?; matrix_required T4; matrix_cell G7 T4 )
G1
G2
...
G8
exit=0
matrix_required T4:
G1 G4 G5 G6 G7 G8
matrix_cell G7 T4:
M (hard)
```
All 8 real rows parse at exactly `NF=10`, none blank; `matrix_required T4` and `matrix_cell G7 T4`
are unchanged from what rounds 1-2 already established. No over-refusal.

### 6 · Authored (G9+) gates — same mechanism, no special-casing, no false-positive risk

`core/06-extending.md`'s gate schema (`:15-27`) gives a `tiers: {T0: "-", T1: "-", T2: "R", T3: "M",
T4: "M"}` field — the same five-tier shape as the built-in table — and its own text says a new gate
gets "a new gate definition **plus its router entry**" (`:149`), i.e. a row added to the *same*
`core/01-router.md` table, not a separate file or format. `tools/ledger.sh:1512-1519`'s own comment
confirms: `looks_like_gate()` deliberately accepts `G9`, `G23`, "anything G+digits," and the awk
row-start anchor in `matrix.sh` (`/^\| \*\*G[0-9]/`) is not gate-id-specific — it matches any
`G<digits>` row, built-in or authored, through the identical `NF != 10` / blank-cell logic. A
legitimately-shaped authored row (11-field YAML mapped 1:1 onto the same 8-pipe layout) would parse
identically to a built-in one and is not rejected. Confirmed by construction (the schema's own
worked examples use the same tier markers `M`/`R`/`—` the built-in rows use) rather than by finding
an actual G9 row to test against — `templates/` ships no router additions and no authored gate is
enabled by default, so there is no live G9 row in this repo to test.

One asymmetry worth naming, not filed as blocking: round 2's `G1..G8` presence loop (`:117`) is a
**hardcoded literal list**, deliberately scoped to the built-in eight (round 2's own report reasons
through why deriving it from another file would reintroduce the exact bug being fixed). A malformed
*authored* G9+ row would still be silently dropped by the `NF != 10`/blank-cell awk guard, with
**no presence check to catch it** the way G1-G8 have — the original silent-fail-open bug, just for
extension gates. Not reachable in this repo (no G9 ships or is enabled by default), unchanged by
this round's diff, and outside what `matrix-router-unreadable-fails-open`'s own scope (the built-in
matrix) was ever framed to cover — noted for completeness per the card, not filed as blocking
against this round.

### 7 · A compensating double-edit inside one row defeats both `NF != 10` and the blank-cell check — reproduced live through the full CLI, T4 hard gate G7 silently vanishes again

This is the finding the task's own framing ("do not assume this is the last one") turned out to be
right about. Both of round 3's checks validate **shape** (field count, non-blankness) but not that
each field's *content* actually belongs in its column. Two edits to the *same row* whose pipe-count
changes cancel out (one dropped, one added elsewhere) leave `NF == 10` and every cell non-blank,
while silently shifting every tier cell after the first edit into the wrong column.

Constructed against G7's row — dropped the pipe between the persona and budget cells (fusing
`Security engineer` and `20 min`) **and** inserted a stray pipe inside the T4 cell's own text
(`(hard)` → `(h|ard)`) — a shape no more contrived than the single-edit fused/blank cases already
found twice in this series; it is exactly what a merge conflict touching two parts of one long
table row, or a deliberate hostile edit in a 291-line table (this diff's own named threat actor),
would produce:

```
$ sed -i 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security engineer 20 min | — | — | R⁴ | M | **M (h|ard)** |/' core/01-router.md
$ awk -F'|' '/^\| \*\*G7/ {print NF}' core/01-router.md
10
$ ( . tools/lib/matrix.sh
    _matrix_load; echo "load_exit=$?"
    matrix_budget G7
    for t in T0 T1 T2 T3 T4; do echo "$t: [$(matrix_cell G7 $t)]"; done
    matrix_required T4 )
load_exit=0
0
T0: [—]
T1: [R⁴]
T2: [M]
T3: [M (h]
T4: [ard)]
matrix_required T4:
G1 G4 G5 G6 G8
```

`_matrix_load` returns **success** (`load_exit=0`, no warning printed anywhere) — the `NF != 10`
check never fires (field count is exactly 10) and the blank-cell check never fires (every cell,
including the two garbled ones, is non-empty after trimming). Every field after the fusion point
silently shifted one column left: budget reads `0` (was `20`), and — critically — **`matrix_required
T4` is `G1 G4 G5 G6 G8`, with G7 completely absent**. This is the identical class of bug rounds 1-3
all exist to close (a T4 HARD GATE silently missing from the mandated list, confident success, no
warning), reproduced a third time through a shape round 3's fix does not cover.

Confirmed through the actual release-blocking commands, not just the library:

```
$ bash tools/ledger.sh compliance --change c --tier T4
Gate compliance — c, tier T4, round 1
-------------------------------------------------------
  PASS       G1   Intent
  NOT RUN    G4   Ripple
  NOT RUN    G5   Proof
  NOT RUN    G6   Peer
  NOT RUN    G8   Dogfood

  Recommended here, mandatory if the footnote applies — your call:
    CHECK  G2   Scout     R¹ Never blocks a *release*. For net-new user-facing capability on
    CHECK  G3   Craft     R² Only when a UI surface changes.
    CHECK  G7   Threat    ard)

INCOMPLETE — 4 mandated gate(s) without a pass: G4 G5 G6 G8
$ echo $?
1
$ BASE=<sha> bash tools/reconcile.sh T4
...
Gates       : Intent, Ripple, Proof, Peer, Dogfood
Also check  : Scout¹, Craft², Threatard)  (recommended; the footnote may make it mandatory)

Reconciled — routing matches. This says nothing about whether the
gates above ran.
$ echo $?
0
```

`compliance`'s own mandated-gate list is `G4 G5 G6 G8` — **G7 is not in it**, and if a real change
logged passes for G1/G4/G5/G6/G8, `compliance` would print "All T4-mandated gates satisfied" at
**exit 0** with the T4 HARD GATE never named, exactly the outcome round 1's original finding
described. `reconcile.sh`'s `Gates:` line omits `Threat(HARD GATE)` entirely and reports
"Reconciled — routing matches" at **exit 0**. Both commands additionally leak the corrupted raw
cell text (`ard)`, `Threatard)`) directly into their output — a second, smaller symptom of the same
root cause (content is trusted once shape checks pass) surfacing as garbled, misleading report text
even in the "CHECK"/"Also check" (non-mandatory) rows.

I verified this is not an artifact of my test setup: `NF` was checked independently before running
any tool (`awk -F'|' '/^\| \*\*G7/ {print NF}'` → `10`, confirmed against the edited file directly),
and both CLI invocations above are real subprocess runs of the unmodified `tools/ledger.sh` and
`tools/reconcile.sh` in this diff, not calls spliced into an open shell.

**Root cause:** `_matrix_load`'s awk block validates row *shape* (exact field count, no blank
tier cell) but never validates that a given field's *content* is plausible for its column — a
budget cell is accepted whatever it contains (non-numeric text silently becomes `"0"`, `matrix.sh:83`,
already a known "silent default" per that line's own comment for a different reason), and a tier
cell is accepted as long as it is non-blank, with no check that it actually looks like `M`, `R`,
`—`, or one of those with a footnote/`(hard)` marker. Two edits whose net pipe-count is zero produce
a row that satisfies both of round 3's checks while every downstream value is wrong.

**A precise, minimal fix** (described, not applied, per this gate's card): after the existing
trim/blank check for each of the 5 tier cells (`matrix.sh:85-93`), validate the trimmed, asterisk-
stripped cell against an allow-list pattern for what a real tier cell can ever contain — e.g.
`cell !~ /^(—|M( \(hard\))?|M[⁰¹²³⁴⁵⁶⁷⁸⁹]*|R[⁰¹²³⁴⁵⁶⁷⁸⁹]*)$/` (every real cell in
`core/01-router.md` today is one of `—`, `M`, `R`, `M (hard)`, `M⁵`, `R¹`, `R²`, `R³`, `R⁴` — see
§5's dump) — and `next` (drop, caught downstream by the existing G1..G8 presence check) on a
mismatch, exactly as the blank case is handled now. This would have caught `T3: [M (h]` and
`T4: [ard)]` directly (neither matches the pattern) without needing to reason about column shifts
at all. A lighter-weight companion check — validating the budget cell's *original* text (before
digit-stripping) matches `^\s*\d+\s*min\s*$` rather than silently accepting anything and defaulting
to `"0"` — would independently have caught this same row (budget cell became `20 min` merged into
persona text, no longer matching `min` alone at that position). Either alone closes this specific
repro; both together close the general class (a shift that happens to leave every individual cell
still pattern-valid, which is a narrower attack this round's report does not attempt to construct
live, having found this much already).

---

## Findings

### BLOCKING — a compensating double-edit (net pipe-count unchanged) is invisible to both `NF != 10` and the blank-cell check; T4 HARD GATE G7 vanishes from `matrix_required`/`compliance`/`reconcile` again

`tools/lib/matrix.sh:75-93`. §7. Verified live, through the full CLI (`ledger.sh compliance`,
`reconcile.sh`), not just the library function. Root cause: shape-only validation (field count,
non-blankness) with no per-column content check. Fix described in §7, not applied.

### INFO — round 3 closes round 2's own two findings (fused cell, blank cell), now confirmed through the full CLI in addition to the library

§1. Round 2's own regression tests for these two shapes only call `matrix_required` directly;
I additionally drove `ledger.sh compliance` and `reconcile.sh` end-to-end for both, per this round's
brief, and both refuse correctly.

### INFO — the "too many pipes" direction, whitespace-only cells, and multi-gate simultaneous corruption all handled correctly, verified live

§2-§4. None of these three shapes are pinned by a dedicated unit test in `tests/run.sh` today
(only the single-gate fused-cell and single-gate blank-cell cases are) — see the minor note below.

### INFO — no false-positive regression; authored G9+ gates share the mechanism without being rejected

§5-§6. All 8 built-in rows still parse at `NF=10`, `matrix_required T4`/`matrix_cell G7 T4`
unchanged. Authored gates use the identical row shape and go through the same code path, unmodified
by this round. The `G1..G8` presence check's own built-in-only scope leaves a malformed authored
row uncaught by that specific loop — pre-existing (round 2's own design choice), not reachable in
this repo today (no G9 ships or is enabled by default), not filed as blocking.

### MINOR — new round-2 tests for the fused-cell/blank-cell shapes exercise only the library, not the CLI; no test yet pins the three shapes this round found un-covered by any test

`tests/run.sh` (`test_matrix_load_refuses_a_fused_cell_row`, `test_matrix_load_refuses_a_row_with_a_blank_cell`).
Both only call `( . matrix.sh; matrix_required T4 )`. §1 shows the CLI-level behavior is correct
today, but nothing pins it as a regression test the way `test_matrix_load_refuses_a_single_malformed_row`
does for the original truncated-row case. Recommend extending those two tests (or adding CLI
assertions) the same way, and adding dedicated tests for: NF>10 (§2), whitespace-only cell (§3), two
gates blanked simultaneously (§4), and — highest priority given the BLOCKING finding above — the
compensating double-edit shape (§7), once a fix for it lands.

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed by this round's change? | Checked? |
|---|---|---|
| Round 2's own findings: fused cell (NF=9), blank cell (correct NF) | **No longer** — refused, naming the gate, through the full CLI | Yes, §1 |
| Extra-pipe direction (NF>10) | No — refused | Yes, §2 |
| Whitespace-only cell | No — trim treats it as blank, refused | Yes, §3 |
| Two gates malformed simultaneously | No — both named | Yes, §4 |
| False refusal against the real router or a legitimately-shaped authored gate | Not observed | Yes, §5-§6 |
| **Compensating double-edit (net NF unchanged, content shifted)** | **Yes — T4 HARD GATE G7 silently absent from `matrix_required`, `compliance`, and `reconcile`, exit 0/clean report** | Yes, §7 — **BLOCKING** |
| Privilege / new file / network / credential reach | None | Yes |

**Privilege growth:** none directly from this diff's own code; the open finding is a mandate
silently *shrinking* (a hard gate no longer required) rather than growing, which is the specific
failure mode this whole change targets.

---

## Verdict

**G7 · Threat (HARD GATE, T4): FAIL**, round 3.

Round 3 correctly and verifiably closes everything round 2 found (§1), plus three additional shapes
this round was asked to try live that round 2 never tested (§2-§4), with no regression against the
real router or authored-gate shapes (§5-§6). But the underlying vulnerability class — a T4 hard
gate's mandate silently vanishing from `matrix_required`/`compliance`/`reconcile` with a clean exit
0 — is not closed in general. A row corrupted in two places whose pipe-count changes cancel out
(§7) reproduces the exact original bug a third time, through the real CLI, not merely reasoned
about. `passes_when: no unresolved finding above low` — this one is above low.

Confidence: **fresh** — every live claim in this report, including the BLOCKING finding, is backed
by a command run against a fresh scratch copy of this worktree or the real `tests/run.sh` harness,
not by reading the awk and reasoning about what it should do. `specs/matrix-router-unreadable-fails-open/requirements.md`
was not opened.

**Premise challenged: yes.** The task listed five specific shapes to try beyond round 2's two
findings, plus a regression check and an authored-gate documentation check; all were run live
(§1-§6). Rather than stop there, I went further per the task's own instruction ("hunt for anything
it still misses... do not assume this is the last one") and constructed an adversarial shape not on
the list — a second, compensating edit in the same row — reasoning from the fact that both new
checks validate shape, not content. It reproduced the T4 hard gate's silent disappearance live,
through the real CLI. This is not a manufactured finding to extend a streak: it is the same bug
class round 1 opened this series to fix, found again, with a command transcript to back it, and a
concrete fix described for the next round to apply and verify.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `blocking` | `tools/lib/matrix.sh:75-93` | A row corrupted in two places whose net pipe-count change is zero (one pipe dropped, one added elsewhere in the same row) passes both `NF != 10` and the per-cell blank check while every field after the first edit silently shifts into the wrong column. Reproduced live against G7: `matrix_required T4` returns `G1 G4 G5 G6 G8` (G7 absent), `_matrix_load` returns exit 0 with no warning, `ledger.sh compliance --tier T4` omits G7 from its mandated list (`INCOMPLETE — 4 mandated gate(s): G4 G5 G6 G8`), and `reconcile.sh T4` reports `Gates: Intent, Ripple, Proof, Peer, Dogfood` (no Threat) and exits 0 with "Reconciled — routing matches." Fix described: validate each trimmed tier cell against an allow-list pattern (`—`, `M`, `R`, `M (hard)`, `M`/`R` + superscript digit — the only shapes any real row in `core/01-router.md` ever uses) and reject on mismatch the same way a blank cell is rejected now; a companion check validating the budget cell's raw text matches `<digits> min` before digit-stripping independently catches this specific repro |
| 2 | `info` | `tools/lib/matrix.sh:75,85-93` | Round 3's `NF != 10` and blank-cell checks correctly close both of round 2's own findings (fused cell at NF=9, blank cell at correct NF), now additionally confirmed through the full CLI (`ledger.sh compliance`, `reconcile.sh`), not only the library function round 2's own tests exercise |
| 3 | `info` | `tools/lib/matrix.sh:75` | `NF != 10` correctly rejects the "too many pipes" direction (a stray pipe typed inside a cell's text, NF=11) — round 2's `NF < 9` would have silently accepted this; whitespace-only tier cells are correctly treated as blank by the existing trim; two gates blanked simultaneously are both named in the refusal message and through both CLI tools — all three verified live |
| 4 | `info` | `core/01-router.md`, `core/06-extending.md` | No false-positive regression: all 8 built-in rows still parse at exactly NF=10 with no blank cells, `matrix_required T4`/`matrix_cell G7 T4` unchanged. Authored (G9+) gates use the identical row shape and the same unmodified code path (`/^\| \*\*G[0-9]/` is not gate-id-specific) so a legitimately-shaped authored row is not rejected; the G1..G8 presence check remains deliberately scoped to built-ins only (round 2's own choice), leaving a malformed authored row uncaught by that specific loop — not reachable in this repo (no G9 ships or is enabled by default), unchanged by this round, not filed as blocking |
| 5 | `minor` | `tests/run.sh` (`test_matrix_load_refuses_a_fused_cell_row`, `test_matrix_load_refuses_a_row_with_a_blank_cell`) | Both new round-2 tests call the library function directly and never exercise `ledger.sh compliance`/`reconcile.sh` the way the original single-malformed-row test does; recommend extending them, and adding dedicated regression tests for the NF>10, whitespace-only-cell, two-simultaneous-gates, and (once fixed) compensating-double-edit shapes — none of the last four are pinned by any test today |

## Ledger line

```
cd "D:\work\gated-change\.claude\worktrees\amazing-jones-bf8e9e" && bash tools/ledger.sh add \
  --change matrix-router-unreadable-fails-open --gate G7 --tier T4 --round 3 \
  --outcome fail --confidence fresh --challenged true --model claude-sonnet-5 --tokens 95000 \
  --finding "blocking::tools/lib/matrix.sh:75-93::a row corrupted in two places whose net pipe-count change is zero (one pipe dropped, one added elsewhere in the same row) passes both NF!=10 and the per-cell blank check while fields shift columns; reproduced live against G7 through the full CLI -- matrix_required T4 returns G1 G4 G5 G6 G8 (G7 absent), compliance's INCOMPLETE list omits G7, reconcile's Gates line omits Threat and exits 0 'Reconciled -- routing matches'. fix: validate each trimmed tier cell against an allow-list pattern (—, M, R, M (hard), M/R+superscript) and reject on mismatch same as a blank cell; companion check on the budget cell's raw '<digits> min' shape independently catches this repro" \
  --finding "info::tools/lib/matrix.sh:75,85-93::round 3's NF!=10 and blank-cell checks correctly close both of round 2's own findings (fused cell NF=9, blank cell correct-NF), now confirmed through the full CLI not just the library" \
  --finding "info::tools/lib/matrix.sh:75::NF!=10 correctly rejects the too-many-pipes direction (NF=11), whitespace-only cells are correctly treated as blank, and two gates blanked simultaneously are both named -- all three verified live, none were covered by round 2's own tests" \
  --finding "info::core/01-router.md,core/06-extending.md::no false-positive regression against the real router (all 8 rows NF=10, matrix_required T4/matrix_cell G7 T4 unchanged); authored G9+ gates share the identical unmodified code path and are not rejected; the G1..G8 presence check remains built-in-only by round 2's own design, leaving a malformed authored row uncaught by that loop specifically -- not reachable in this repo today, not filed as blocking" \
  --finding "minor::tests/run.sh::round 2's fused-cell/blank-cell tests exercise only the library function, not the CLI; no test pins NF>10, whitespace-only-cell, two-simultaneous-gates, or the compensating-double-edit shape"
```
