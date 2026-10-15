# confidence-vocabulary-refusal — Requirements

> Written at the Intent gate, before Build. Bug fix (correctness / evidence
> integrity), not a feature — Prior art and Assets are marked N/A rather than
> deleted, so the template's shape stays legible.

## User

Anyone reading `tools/dashboard/app.js`'s rendered dashboard — or `ledger.sh
report` / `gates` — to decide whether a gate got an **independent fresh-context
review** on a given change. Concretely: a reviewer at Release checking that a T4
change's hard gates were graded by a session that did not write the code.

## Problem

`tools/ledger.sh`'s `cmd_add` validates every closed-set field it writes *before*
`emit()`:

- `--outcome` → `pass|fail|skipped|n/a`, else `REFUSED` exit 2 (`ledger.sh:470`)
- `--tier` → `T0..T4` or empty, else `REFUSED` exit 2 (`ledger.sh:428`)
- `--round` / `--minutes` / `--tokens` → uint, else `REFUSED` exit 2
- `--challenged` → `true|false`, else `REFUSED` exit 2

It did **not** validate `--confidence`. The value was `json_escape`'d and spliced
into the record as free text, and the code comment at `ledger.sh:~517` said so
explicitly: *"confidence and lane are free text by design"*.

But `--confidence` is **not** free text anywhere else in the kit:

- `core/04-ledger.md:18` gives the vocabulary as exactly **`fresh` or `low`**.
- Every gate card's `logs_with:` line (`core/cards/G1..G8`) reads
  `--confidence fresh|low`.
- `core/02-gates.md:113` (Running a gate) shows `--confidence fresh`.
- `tools/dashboard/app.js`'s `isIndependent()` (`app.js:182`) is
  `return conf === "fresh";` — it trusts **only** the exact string `fresh`.

So a typo — `--confidence freshh`, `--confidence tru`, or (the observed one)
`--confidence true` from `--challenged true|false` muscle memory — writes a
`"confidence":"true"` record that:

- `isIndependent()` reads as **not** `fresh` → not independent, **correct by luck**;
- but `isSelfCheck()` (`app.js:197`) is `isVerdict(outcome) && !isIndependent(conf)`
  → this `pass` record is now counted as a **self-check by the author** in
  `selfChecks` / `selfCheckRuns` (`app.js:352`), hatched on the gate grid
  (`outcomeClass`, `app.js:658`), and labelled *"(self-check — excluded from
  fresh-run stats)"* on the detail panel (`app.js:2425`) — for a gate that
  **actually ran in a fresh context**. The fresh-context review the ledger is
  supposed to be the record of silently stops counting, and the dashboard
  actively asserts the opposite of what happened.
- `ledger.sh report` (`ledger.sh:1366-1367`) counts `fresh` and `low`
  separately; a `"true"` record is neither, so it silently vanishes from the
  `fresh-context` / `low-confidence` readout entirely.

This is the exact *"a value nobody thought to try makes the record false,
silently"* shape the other `cmd_add` refusals already guard against — the
`--outcome passs` history is called out in the code comment at `ledger.sh:460`.
`tools/ledger.sh` is a **T4 surface** (`project/surfaces.conf:27` — *"Routing and
evidence — a wrong answer here is silent and confident"*).

**It happened for real.** A G7 round-2 gate entry for change `ci-to-codebuild`
was logged `--confidence true` and had to be superseded by a corrected append
(`ledger.jsonl`, 2026-09-08). The correction cost a manual catch and a second
line; nothing in the tool refused the bad one.

## Acceptance criteria

- [ ] `bash tools/ledger.sh add --change c --gate G7 --tier T4 --outcome pass
      --confidence bogus` (and `true`, `tru`, `freshh`, `high`, `same-session`,
      `self`, empty) exits **2**, prints `REFUSED`, and writes **nothing** to the
      ledger — the same treatment `--outcome passed` already gets.
- [ ] `--confidence fresh` and `--confidence low` still write, exit 0.
- [ ] `--outcome pass` / `--outcome fail` with **no** `--confidence` is
      **refused** (exit 2, `needs --confidence fresh|low`, nothing written) — see
      the "REQUIRED for a verdict" criterion below.
- [ ] `--outcome skipped` / `--outcome n/a` with no `--confidence` still
      auto-stamps `low` and writes (the downgrade block, unchanged) — the
      verdict-requires-confidence check exempts them explicitly.
- [ ] The stale comment (*"confidence and lane are free text by design"*) is
      corrected: `confidence` is now closed-set-checked *and* required for a
      verdict; `lane` and `model` are escaped-but-unguarded (a filed follow-up).
- [ ] A regression test in `tests/run.sh`: `led add --confidence bogus` → exit 2,
      nothing written; a companion that `fresh` / `low` still write; and
      `test_ledger_requires_confidence_on_a_verdict` (pass/fail with no
      `--confidence` → exit 2; skipped/n-a exempt).
- [ ] `--confidence` is **REQUIRED** for a `pass`/`fail` — `ledger.sh add`
      refuses a verdict logged without it (`REFUSED: --outcome <v> needs
      --confidence fresh|low`, exit 2, nothing written). A verdict with no
      confidence is an independence claim nobody made, and `isIndependent()` /
      `cmd_report` both key on the literal string, so it silently would not
      count. `skipped`/`n/a` are exempt (they reviewed nothing; stamped `low`).
      This is the resolution of a **G8 Dogfood repeat finding** (r1: silent
      default; r2: a warning was not enough — the default still favoured the
      stat-feeding value) — user decision, 2026-09-09. Regression test:
      `test_ledger_requires_confidence_on_a_verdict`. Cost: ~48 `led add`
      invocations in `tests/run.sh` gain `--confidence fresh`; two example
      invocations in `core/04-ledger.md` fixed.
- [ ] The two ledgers this repo carries with out-of-vocab `high` /
      `same-session` values (`ledger.jsonl` — 5 `high`, 19 `same-session`;
      `tools/dashboard/app.js:175` comment) **still parse** in
      `tools/dashboard/app.js` and `tests/dashboard-logic.test.js`. This change
      only refuses *new writes*; the append-only history is untouched, and the
      dashboard's `isIndependent()` blocklist-free design already handles them.
- [ ] Full `bash tests/run.sh` green (0 failed, 0 skipped beyond the pre-existing
      platform skips); `node tests/dashboard-logic.test.js` green.

## Out of scope

- **Normalising / warning instead of refusing.** Considered (the task framed it
  as the alternative if `low` were meant to be an open set of "not-fresh"
  reasons). Rejected: `core/04-ledger.md` and all eight gate cards state the
  vocabulary as exactly two values, and `isIndependent()` already treats
  everything-but-`fresh` identically, so a third value carries no information the
  `low` bucket does not — it only creates a record the dashboard has no case
  for. Refusing matches `--outcome`.
- **Backfilling or rewriting the historical `high` / `same-session` /
  `ci-to-codebuild --confidence true` records.** `core/04-ledger.md`'s "never
  backfill" rule. They stay; `isIndependent()` renders them correctly as
  non-independent already.
- **`--lane` and `--model`.** `--lane` is documented as exactly `normal|hotfix`
  (`core/04-ledger.md:23`) and `cmd_report` buckets it with a literal
  `grep -c '"lane":"hotfix"'` — so it has the *identical* latent gap this change
  closes for `--confidence` (G4 Ripple, round 1). Deliberately deferred to keep
  this change to one field; filed as a follow-up. `--model` warns only on the
  literal `unset`. The `emit()` comment is corrected to say this plainly rather
  than call `--lane` "free text by design". `test_ledger_lane_value_cannot_forge_the_outcome`
  (a security regression for the 2026-08-13 forge) is why guarding `--lane`
  here is not a one-liner — it asserts a hostile `--lane` value is *accepted
  and escaped*, and would need rewriting.
- **`cmd_route` / `cmd_escape` / `cmd_assume`.** None accept `--confidence`.
- **`ledger.sh report`'s silent drop of out-of-vocab confidence values from its
  fresh/low counts.** With new writes refused, the only such records are
  historical; making `report` account for them is a separate cosmetic change.
- **The stale line-number references in `app.js:186`** (`tools/ledger.sh:466` /
  `:148-154` — the file has grown since). Real doc drift, not this change.

## Assets required

N/A — no non-code deliverables.

## Prior art

N/A — Scout (G2) fires only for net-new user-facing capability
(`core/cards/G2-scout.md`); this is a correctness fix to an internal CLI
validator.

## Acceptance (G1b — after Build)

| Criterion | Evidence |
|---|---|
| `--confidence` outside `fresh\|low` refused before `emit()`, exit 2, nothing written | `tools/ledger.sh` diff — new `case "$confidence" in fresh\|low) ;; *) … exit 2;; esac` immediately after the `--outcome` `case` (`ledger.sh:479`). `tests/run.sh:test_ledger_refuses_an_unknown_confidence` — loops `true tru freshh high same-session self medium ""`, each asserts exit 2 + `REFUSED`, then asserts the ledger has no `"gate":"G7"` line |
| `fresh` / `low` still write; verdict-without-confidence refused; skipped/n-a exempt | `tests/run.sh:test_ledger_still_accepts_fresh_and_low_confidence` (fresh/low exit 0) + `test_ledger_requires_confidence_on_a_verdict` (pass/fail no-flag → exit 2 `needs --confidence`; skipped/n-a no-flag → exit 0, reads back `low`) |
| Stale "free text by design" comment corrected | `tools/ledger.sh` diff at the pre-`emit()` comment block — now "tier/gate/outcome/confidence reach here only after a closed-set check … `lane` has no such check (free text by design)" |
| Historical `high` / `same-session` still parse | `node tests/dashboard-logic.test.js` green (fixtures use `high`, `self`, `same-session`, `low` directly — `dashboard-logic.test.js:1344`, `:1772`, `:1942`); `bash tests/run.sh confidence` → 31/0/0 |
| `cmd_compliance`'s emitted `add` hint survives its own new guard | `tools/ledger.sh:1306` — concrete `--confidence fresh` (`3aba417`); G6 r5 pasted it verbatim → exit 0, wrote `confidence:fresh` |
| Full suite green | `bash tests/run.sh` — **789 passed / 0 failed / 0 skipped** at tip `020000c` (TMPDIR on D:; `real 38m` under Windows fork contention), + `node tests/dashboard-logic.test.js` all green. `confidence` filter 31/0/0. Baseline before this change ≈ 759. |

**Target coverage** (`reconcile.sh`'s T3/T4 checklist for this diff):
- Git Bash on Windows — this session (full suite + targeted runs).
- Linux/macOS bash — `.github/workflows/tests.yml` runs `tests/run.sh` unmodified.
  **GitHub Actions is disabled on this repo for non-payment since 2026-09-08**
  (pushes fail all legs in ~8s — not a code signal), so the Linux/macOS leg is
  unconfirmable via CI this session; the change is a pure `case` statement in
  bash with no platform branch, no new command.
- Installed at `.pipeline/` — `tests/run.sh`'s `newrepo` fixture, which the new
  tests use.
- Kit as its own repo (`INCLUDE_KIT=1`) — N/A: `cmd_add`'s field validation does
  not read `INCLUDE_KIT` (grep, zero hits); that flag only affects `reconcile.sh`
  path exclusion.

## Restatement

`cmd_add` refuses every closed-set field with a bad value except `--confidence`,
which it waved through as free text even though the docs, every gate card, and
the dashboard's own independence check all treat it as exactly `fresh|low` — so a
one-character slip writes a record that reads back as a self-check the author
never did. Make `--confidence` refuse like `--outcome` does.
