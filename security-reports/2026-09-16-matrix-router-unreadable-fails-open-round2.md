# G7 · Threat review — `matrix-router-unreadable-fails-open` (T4, hard gate, round 2, 7c depth)

**Reviewed:** the **uncommitted working-tree diff on top of `bbcb30d6fa3974ccc8c27b41994f77bc5980dca2`**
("auto: regenerate dashboard.html (pre-push)") — `git rev-parse HEAD` confirmed →
`bbcb30d6fa3974ccc8c27b41994f77bc5980dca2`, unchanged from round 1. Subject: the FULL current
diff — round 1 (the direct, non-subshelled `_matrix_load` guards added to `cmd_compliance` in
`tools/ledger.sh` and to `tools/reconcile.sh`) plus round 2 (the new G1..G8 row-completeness check
inside `_matrix_load` itself, `tools/lib/matrix.sh:83-109`, plus three new tests in
`tests/run.sh`) — obtained via
`git diff -- tools/lib/matrix.sh tools/ledger.sh tools/reconcile.sh tests/run.sh`. This is a fresh
session; only this prompt, `project/surfaces.conf`, the diff, `core/06-extending.md`, `README.md`,
and my own round-1 report (`security-reports/2026-09-16-matrix-router-unreadable-fails-open.md`)
were read. `specs/matrix-router-unreadable-fails-open/requirements.md` was **not** opened, per the
card's `withhold` line.

**Files in scope and their tier** (`project/surfaces.conf`, `SELF: gated-change` at line 3):

| File | Tier | surfaces.conf rule |
|---|:--:|---|
| `tools/ledger.sh` | **T4** | `:27` — "Routing and evidence — a wrong answer here is silent and confident" |
| `tools/reconcile.sh` | **T4** | `:27` — same rule, same file family |
| `tools/lib/matrix.sh` | **T4** | `:28` — "The gate matrix reader — decides what is mandatory" |
| `tests/run.sh` | T3 | `:50` — "The suite — if it stops asserting, nothing else here is trustworthy" |

Change tier = **T4** (the max), which is what makes this a hard gate.

---

## What changed since round 1

`tools/ledger.sh` and `tools/reconcile.sh` are **byte-for-byte unchanged** from round 1 (re-diffed
directly against round 1's own quoted line ranges — identical). Round 1 found their guards correct
but incomplete: `_matrix_load` itself returned success (0) whenever *any* gate row parsed, so a
single removed or malformed row was silently absorbed and neither new guard ever fired.

Round 2's entire code change is inside `tools/lib/matrix.sh`'s `_matrix_load`
(`tools/lib/matrix.sh:83-109`), added directly after the existing "table came back empty" check:
after the awk parse, it walks a **hardcoded literal list** `G1 G2 G3 G4 G5 G6 G7 G8` and, for each,
checks `printf '%s\n' "$_MATRIX_TABLE" | cut -f1 | grep -qx "$_g"` — an exact-match test against
the parsed id column. Any gate not found is accumulated into `$_missing`; if non-empty, `_matrix_load`
prints which gate ids are missing, clears `$_MATRIX_TABLE`, sets the same `_MATRIX_LOAD_FAILED`
sentinel round 1 introduced, and `return 2` — the identical failure path round 1's `cmd_compliance`
and `reconcile.sh` guards already check for. No call site changed; the fix lives entirely in the
shared loader, so it automatically covers every current and future `matrix_*` consumer, not just
the two round-1 patched.

Three new tests in `tests/run.sh`: `test_matrix_load_refuses_a_single_malformed_row` (corrupts G7's
row specifically, then exercises both `ledger.sh compliance` and `reconcile.sh` end-to-end),
`test_matrix_load_refuses_a_malformed_row_for_every_gate` (loops all 8 gates, corrupting each one's
own row in turn and asserting its own name appears in the warning — explicitly written, per its own
comment, because "nothing proves that literal list itself stays complete" if only G7 is ever
exercised), and `test_ledger_compliance_reports_nothing_to_check_when_tier_legitimately_empty`
(guards against over-refusal at T0 with an intact router).

---

## Threat model — unchanged from round 1, re-applied to the new surface

Same three untrusted/relevant parties as round 1: a confused user/CI environment that corrupts
`core/01-router.md` by accident; a hostile PR author hiding an edit in a 291-line table; a reader
of `ledger.sh compliance`/`reconcile.sh` output trusting it to be complete. The new question this
round adds: **does completeness-checking against a fixed list of eight ids actually close the gap
round 1 found, for every shape of row corruption, or does it just move the blind spot** (e.g. to a
different gate, to a case-mangled id, to multiple simultaneous corruptions, or to a legitimate
install shape the fixed list doesn't anticipate)?

---

## The walk — real commands, real output, against a scratch copy

Built a fresh scratch repo mirroring `tests/run.sh`'s `newrepo()` fixture (full `.pipeline/` copy of
this worktree, `git init`) under `.../scratchpad/g7review2/repo1`, and additionally ran the new
tests through the real harness (`bash tests/run.sh <test_name>`, a genuine subprocess path, not
calls spliced into an open shell) where noted.

### 1 · Exact round-1 reproduction — closed, live and via the harness

Round 1's reproduction (G7's row truncated to 3 of 9 fields, same technique as the new test) against
both tools:

```
$ sed -i 's/| \*\*G7 · Threat\*\* |.*/| **G7 · Threat** | Security engineer | 20 min |/' core/01-router.md
$ bash tools/ledger.sh compliance --change c --tier T4
matrix: .../01-router.md is missing a row for: G7
  ...
REFUSED: the gate matrix could not be read — see the error above.
$ echo $?
2
$ BASE=<sha> bash tools/reconcile.sh T4
...
matrix: .../01-router.md is missing a row for: G7
REFUSED: the gate matrix could not be read — see the error above.
$ echo $?
2
```

Both now `REFUSED`/exit 2, naming `G7` specifically — this is round 1's blocking finding, closed.
Confirmed independently via the real test harness: `bash tests/run.sh test_matrix_load_refuses_a_single_malformed_row`
→ `passed 10 · failed 0 · skipped 0`.

### 2 · A different gate's row corrupted — no gate-specific special-casing found

Corrupted **G3**'s row only (leaving G7 intact), same truncation technique:

```
$ bash tools/ledger.sh compliance --change c --tier T4
matrix: .../01-router.md is missing a row for: G3
REFUSED: the gate matrix could not be read — see the error above.
$ echo $?
2
$ BASE=<sha> bash tools/reconcile.sh T4
matrix: .../01-router.md is missing a row for: G3
REFUSED: ...
$ echo $?
2
```

Identical behavior, `G3` named instead of `G7`. Also ran the harness's own
`test_matrix_load_refuses_a_malformed_row_for_every_gate` — which corrupts **each of the 8 built-in
gates' own row in turn**, asserting each produces its own name in the warning —
via `bash tests/run.sh test_matrix_load_refuses_a_malformed_row_for_every_gate` →
`passed 8 · failed 0 · skipped 0`. No special-casing toward G7 (or any other gate) exists: the check
is a plain loop over a literal `G1 G2 G3 G4 G5 G6 G7 G8`, and every one of the eight was verified,
independently, to trigger its own correct warning.

### 3 · Wrong gate id in column 2 — a typo/case mismatch is treated as absence, correctly

Two variants tried directly against `matrix_gates`/`matrix_required`:

**Lowercase `g7`** (row otherwise intact, 9 fields):
```
$ sed -i 's/| \*\*G7 · Threat\*\*/| **g7 · Threat**/' core/01-router.md
$ ( . tools/lib/matrix.sh; matrix_gates; matrix_required T4 ) 2>&1
matrix: .../01-router.md is missing a row for: G7
```
The row-start pattern `/^\| \*\*G[0-9]/` (case-sensitive, requires literal uppercase `G`) never
matches the line at all, so awk never enters the row-parsing block — the row is dropped exactly as
if it were absent, and the completeness check correctly reports `G7` missing. Propagated through the
full CLI: `ledger.sh compliance` and `reconcile.sh` both `REFUSED`/exit 2, `grep -c REFUSED` = 1 in
each.

**Leading space before the id** (`| ** G7 · Threat** | ...`, 9 fields otherwise intact):
```
matrix: .../01-router.md is missing a row for: G7
```
Same result — the row-start anchor requires `\*\*` immediately followed by `G[0-9]`, so a leading
space also fails the anchor and the row is dropped, correctly detected as missing.

I could not construct a variant where the row **parses** (row-start anchor matches, ≥9 fields) but
the *extracted* id fails to equal one of `G1`..`G8` in a way that silently passes: `match($2,
/G[0-9]+/)` is a substring search, so incidental whitespace *inside* the already-anchored cell
(e.g. `**G7  · Threat**`, double space) does not change the extracted id at all — cosmetic, not a
bypass. Every case that could plausibly be called "the row is still nominally there but wrong" turned
out to be one of: (a) parses fine, id extracted correctly (no attack), or (b) fails the row-start
anchor and the row is dropped, which the completeness check catches. `grep -qx` (exact match) against
the *parsed* id column, not the raw cell text, is doing real work here — it is checking a clean
`G7` against a clean `G7`, not fuzzy-matching raw markdown.

### 4 · Two gates malformed simultaneously — both named

Truncated G3's row and, separately, mangled G7's id column (leading-space variant) in the same
table:

```
$ ( . tools/lib/matrix.sh; matrix_required T4 ) 2>&1
matrix: .../01-router.md is missing a row for: G3 G7
```

Both names appear, space-separated, in the order the fixed `G1..G8` loop iterates — not truncated to
one, not deduplicated incorrectly, not silently dropping the second.

### 5 · Duplicate gate id (one intact row + one malformed row for the same gate) — reasoned about, then verified live: not exploitable

Hypothesis from the task: since the check is presence-only (`grep -qx`, not a uniqueness/count
check), could a duplicated, partially-malformed row for one gate mask a **different** gate's true
absence? Reasoning first: the loop tests each of `G1`..`G8` **independently** — `G3`'s presence
check does not read or depend on anything about `G7`'s rows. A duplicate `G7` (one intact, one
malformed-but-still-≥9-fields) at most affects what `matrix_cell`/`matrix_required` return *for
G7 itself* (both rows' cells get concatenated by the command substitution, and since `case ... in
*M*)` pattern-matches the whole string, an intact row's `M` cell always wins the substring test
regardless of a second row's content) — it does not touch the independent per-gate presence check
for any other id.

Verified live rather than left as reasoning: removed **G4**'s row entirely (the actually-missing
gate) and duplicated **G7**'s row (one intact copy immediately followed by one truncated copy) in
the same table:

```
$ grep -n '| \*\*G[0-9]' core/01-router.md
...G1..G3, G5, G6...
| **G7 · Threat** | Security engineer | 20 min | — | — | R⁴ | M | **M (hard)** |
| **G7 · Threat** | Security engineer | 20 min |
...G8...
$ ( . tools/lib/matrix.sh; matrix_required T4 ) 2>&1
matrix: .../01-router.md is missing a row for: G4
```

`G4`'s absence is caught correctly and specifically — `G7`'s duplication (intact + malformed) neither
masks it nor produces any spurious effect. **Not exploitable, confirmed live, not merely
theoretical.**

### 6 · A project with only authored/extension gates, some built-ins absent — not a legitimate shape in this kit; check does not over-refuse for real installs

Read `core/06-extending.md` and `README.md`. Both are explicit and consistent:
`core/06-extending.md:5` — "Eight gates cover any software change. They do **not** cover every
*domain*" — extension gates (the `Provision`/`Perimeter`/`Migrate`/... library, `:121-134`, or a
freshly authored `G9`) are **additions**, always getting **their own new router row**
(`:149`, "a checklist extension or a new gate definition plus its router entry"); nothing in this
chapter describes disabling or removing a built-in gate's row. `README.md:14` states plainly:
"`core/` portable. Never edit. Ships identical to every user," and `:18`: "If you find yourself
editing `core/` to fit your project, that is a bug in `core/`." `templates/` (checked directly —
`templates/project/*`, `templates/agent-instructions.md`, etc.) contains **no router template at
all** — every legitimate install gets `core/01-router.md`, G1-G8 table included, byte-identical to
the kit's own copy, exactly as `newrepo()`'s own fixture does (`cp -r "$KIT/core" ...`). There is no
supported install shape where a built-in gate's row is legitimately absent, so the new check cannot
produce a false refusal against any real project — this was confirmed from the kit's own documented
design, not merely assumed. The escape hatch for "this gate doesn't fire here" is `outcome: n/a`
logged per-run against a footnoted matrix cell (`core/01-router.md:110-111`,
`core/04-ledger.md:17`), never a missing row.

### 7 · Regression check — round-1's whole-file/whole-table cases still correctly handled

Re-ran round 1's two original cases against the round-2 code:

```
$ mv core/01-router.md core/01-router.md.bak
$ bash tools/ledger.sh compliance --change c --tier T4; echo $?
matrix: no router at .../01-router.md
  ...
REFUSED: ...
2
$ : > core/01-router.md   # 0 bytes
$ bash tools/ledger.sh compliance --change c --tier T4; echo $?
matrix: .../01-router.md has no gate rows — is the table intact?
REFUSED: ...
2
```

No regression — both still hit the pre-existing checks (`_matrix_load:43-49` file-missing,
`:77-81` table-empty) before ever reaching the new G1..G8 loop, since `_MATRIX_TABLE` is empty in
both cases and those earlier `return 2`s fire first.

**No over-refusal:** re-confirmed T0 against an intact router still reports cleanly:
```
$ bash tools/ledger.sh compliance --change c --tier T0
Tier T0 mandates no gates. Nothing to check.
$ echo $?
0
```
Also confirmed via the harness: `bash tests/run.sh test_ledger_compliance_refuses_when_router_missing`
→ `passed 3 · failed 0 · skipped 0`; `bash tests/run.sh test_ledger_compliance_reports_nothing_to_check_when_tier_legitimately_empty`
→ `passed 2 · failed 0 · skipped 0`; `bash tests/run.sh test_reconcile_refuses_when_router_missing`
→ `passed 4 · failed 0 · skipped 0`.

### 8 · Scope note — `cmd_gates`/`cmd_report` still don't check `_matrix_load`'s return (pre-existing, unrelated to this diff)

`tools/ledger.sh:1542`, `cmd_gates()` calls `_matrix_load` bare (to prime the cache, per the
round-1-of-the-sibling-change comment) but does not branch on its exit status the way
`cmd_compliance` now does — a missing/malformed router still lets `gates`/`report` print their stats
table (with the corrupted gate simply absent from it), rather than refusing. This is the same shape
as the `matrix-missing-router-warns-once-round2` report's own finding #3 (`compliance` fail-open,
there found pre-existing and out of that diff's mechanism). Here too: `cmd_gates`/`cmd_report` are
a **stats/report display**, not the release-blocking `compliance`/`reconcile` decision this diff's
own spec name targets, this diff does not touch `cmd_gates`'s code, and the behavior is identical
before and after this round's change (the new completeness check lives inside `_matrix_load`, which
`cmd_gates` already called bare in round 1 of the sibling change). Not filed as a finding against
this diff; noted because the card asks for everything found, not only what blocks.

---

## Findings

### INFO — round 2 closes round 1's blocking finding, verified live across every row-corruption shape asked for

`tools/lib/matrix.sh:83-109`. Single-row corruption (any of G1-G8, not just G7), wrong-case/misplaced
id, two simultaneous corruptions, and a duplicate-row scenario were all verified live to either
correctly refuse (naming the right gate(s)) or to be non-exploitable by reasoning that was then
confirmed live rather than left assumed. §1-§5.

### INFO — no legitimate install shape can trigger a false refusal

`core/06-extending.md`, `README.md:14,18`, `templates/`. The eight built-in gates are documented,
portable, "ships identical to every user" content; extension gates are always additive with their
own row. §6.

### INFO — whole-file/whole-table cases (round 1's own scope) unaffected, no regression, no over-refusal

§7, plus harness-verified (`test_ledger_compliance_refuses_when_router_missing`,
`test_ledger_compliance_reports_nothing_to_check_when_tier_legitimately_empty`,
`test_reconcile_refuses_when_router_missing`, all green).

### Not a finding against this diff — `cmd_gates`/`cmd_report` still don't refuse on a broken router

§8. Pre-existing (unchanged by this diff's mechanism), and those two are stats/report display
commands, not the release-blocking `compliance`/`reconcile` path this change's spec name targets.
Noted for completeness, not filed as blocking.

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed by this round's change? | Checked? |
|---|---|---|
| Round 1's blocking gap: single/removed row silently dropped from what's mandated | **No longer** — `_matrix_load` now refuses, naming the gate(s), verified for every gate individually and for G7 specifically | Yes, §1-§2 |
| Case-mangled / misplaced gate id treated as "present" | No — anchor and exact-match together correctly treat it as absent | Yes, §3 |
| Multiple simultaneous corruptions under-reported | No — both named | Yes, §4 |
| Duplicate row masking a different gate's true absence | No — verified live, independent per-gate checks | Yes, §5 |
| False refusal against a legitimate extension-gate-only install | Not reachable — no such install shape exists in this kit | Yes, §6 |
| Regression on round 1's whole-file/whole-table fixes | None | Yes, §7 |
| Privilege / new file / network / credential reach | None | Yes |

**Privilege growth:** none.

---

## Verdict

**G7 · Threat (HARD GATE, T4): PASS**, round 2.

`passes_when: no unresolved finding above low`. Round 1's blocking finding — that `_matrix_load`
returned success whenever any row parsed, silently dropping a corrupted gate from what
`matrix_required`/`matrix_conditional` report — is closed: verified live against a different gate
than the one round 1 used (G3, and separately G4), against case/placement-mangled ids rather than
only truncated ones, against two simultaneous corruptions, and against a duplicate-row scenario that
was reasoned through and then independently confirmed not exploitable rather than taken on faith.
The one adjacent question the card raised that could plausibly have produced a false positive —
whether a legitimate install might deliberately lack some built-in gates — is answered by the kit's
own documentation: no such install shape exists, since `core/01-router.md` ships identical and
unedited to every user. Everything found this round is `info`.

Confidence: **fresh** — every live claim in this report is backed by a command run against a fresh
scratch copy of this worktree, or by the real `tests/run.sh` harness invoked as a genuine
subprocess (not by reading the code and reasoning about what it should do). `specs/matrix-router-unreadable-fails-open/requirements.md`
was not opened.

**Premise challenged: yes.** The task's framing listed five specific variations to try beyond the
original G7-truncation case and one documentation question; none were skipped or answered from
memory — each was reproduced live (§2-§5) or checked against the kit's actual `core/06-extending.md`
and `README.md` rather than assumed from the chapter's opening line alone (§6). The duplicate-row
question in particular was worked through analytically first (why the per-gate independence of the
check should make it a non-issue) and then verified live specifically because the task's framing
asked whether this was "actually reachable/exploitable or purely theoretical" — a reasoning-only
answer would not have settled that.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `info` | `tools/lib/matrix.sh:83-109` | Round 2's G1..G8 row-completeness check closes round 1's blocking finding. Verified live: a single corrupted row for any of the 8 built-in gates (not only G7) is caught by name; case-mangled (`g7`) or anchor-breaking (leading-space `G7`) ids are correctly treated as absence, not a false pass; two simultaneous corruptions are both named in one message; a duplicated row (one intact + one malformed copy of the same gate) neither masks that gate's own required-ness nor a different gate's true absence, confirmed live by removing G4 entirely alongside a duplicated/malformed G7 and observing only G4 reported missing |
| 2 | `info` | `core/06-extending.md`, `README.md:14,18`, `templates/` | No legitimate gated-change install can have fewer than the 8 built-in gate rows — `core/` is portable, unedited, shipped identical to every user; extension/authored gates always add a new row rather than replacing a built-in one. The new check cannot produce a false refusal against any real install shape |
| 3 | `info` | `tools/lib/matrix.sh:40-81`, `tests/run.sh` (router-missing tests) | Round 1's whole-file-missing and whole-table-empty cases remain correctly handled (still `REFUSED`/exit 2) after this round's addition, with no over-refusal at a legitimately gate-free tier (T0, intact router) — verified live and via the real test harness (`test_ledger_compliance_refuses_when_router_missing`, `test_ledger_compliance_reports_nothing_to_check_when_tier_legitimately_empty`, `test_reconcile_refuses_when_router_missing`, all green) |
| 4 | not a finding against this diff | `tools/ledger.sh:1542` (`cmd_gates`) | `cmd_gates`/`cmd_report` prime `_matrix_load`'s cache but do not branch on its failure the way `cmd_compliance`/`reconcile.sh` now do, so a broken router still lets the stats display run with the corrupted gate silently absent from it. Pre-existing, unchanged by this diff's mechanism, and these are report/display commands rather than the release-blocking path this change targets — noted for completeness, not filed as blocking |

## Ledger line

```
cd "D:\work\gated-change\.claude\worktrees\amazing-jones-bf8e9e" && bash tools/ledger.sh add \
  --change matrix-router-unreadable-fails-open --gate G7 --tier T4 --round 2 \
  --outcome pass --confidence fresh --challenged true --model claude-sonnet-5 --tokens 70000 \
  --finding "info::tools/lib/matrix.sh:83-109::round-2 G1..G8 row-completeness check closes round-1's blocking finding; verified live for a different gate (G3/G4, not just G7), case-mangled/anchor-breaking ids treated correctly as absence, two simultaneous corruptions both named, and a duplicate-row scenario confirmed live (not just reasoned) to not mask a different gate's true absence" \
  --finding "info::core/06-extending.md,README.md:14,18,templates/::no legitimate gated-change install can have fewer than the 8 built-in gate rows (core/ ships identical/unedited to every user, extension gates always add a new row); the new check cannot false-refuse against any real install shape" \
  --finding "info::tools/lib/matrix.sh:40-81,tests/run.sh::round-1's whole-file-missing and whole-table-empty cases remain correctly handled with no over-refusal at T0, verified live and via the real test harness (three new tests all green)" \
  --finding "info::tools/ledger.sh:1542::cmd_gates/cmd_report still do not branch on _matrix_load's failure and can display stats with a corrupted gate silently absent; pre-existing, unchanged by this diff, and out of scope for the release-blocking compliance/reconcile path this change targets"
```
