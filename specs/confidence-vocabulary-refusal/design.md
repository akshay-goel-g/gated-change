# confidence-vocabulary-refusal — Design

> Written at the Ripple gate, after requirements are confirmed.

## Approach

One `case` statement in `cmd_add` (`tools/ledger.sh`), placed immediately after
the existing `--outcome` `case` (`ledger.sh:470-477`) and before the `n/a`-reason
warning. Plus a one-line correction to the pre-`emit()` comment block. Nothing
else in the kit changes — no consumer of the ledger reimplements confidence
handling, and `tools/dashboard/app.js` already keys independence on the single
trusted value rather than a blocklist.

### Current shape (`tools/ledger.sh` cmd_add)

```
parse loop:  --confidence) confidence="$2"; confidence_set=1; shift 2;;   # default "fresh"
…
case "$outcome" in pass|fail|skipped|n/a) ;; *) REFUSED; exit 2;; esac
…
if {skipped|n/a} && confidence_set==0:  confidence="low"                  # auto-downgrade
…
emit "{… \"confidence\":\"$(json_escape "$confidence")\" …}"              # spliced as free text
```

### New shape

```
case "$outcome" in … esac
+ case "$confidence" in
+   fresh|low) ;;
+   *) echo "REFUSED: --confidence '$confidence' is not one of fresh|low." >&2
+      … ; exit 2;;
+ esac
…
if {skipped|n/a} && confidence_set==0:  confidence="low"   # unchanged
```

### Why here, and why refuse (not warn)

`--confidence` is the one closed-set field `cmd_add` splices in unchecked. The
value's only consumer semantics are `tools/dashboard/app.js:182`
`isIndependent(conf){ return conf === "fresh"; }` — a deliberate allow-list of
exactly one string (`app.js:173-181` comment: *"Keyed on the ONE value that is
safe to trust rather than a blocklist, so an unrecognised value fails toward 'not
independent'"*). That design means every non-`fresh` value is already
**equivalent** downstream: it is not independent, it is a self-check if the
outcome is a verdict. A third accepted spelling therefore adds **zero
information** over `low` — it only produces a `"confidence":"true"` record that:

- `report` (`ledger.sh:1366-1367`) counts as neither `fresh` nor `low` → drops
  from the readout;
- `isSelfCheck()` counts as a self-check by the author, for a gate that ran fresh.

`core/04-ledger.md:18` and all eight `core/cards/G*.md` `logs_with:` lines state
the vocabulary as exactly `fresh|low`. So the correct move is the one `--outcome`
already makes: refuse before `emit()`, exit 2, write nothing. The
`ledger.sh:460-469` comment already lays out this exact reasoning for `--outcome`
("Refusing before it reaches emit() matches --tier … and --resolution … exactly,
and the same reasoning applies: append-only means a bad value here is never
backfilled").

### Placement relative to the skipped/n-a auto-downgrade

The refusal is evaluated on the **user-supplied or default** value, before the
`confidence_set==0` downgrade block (`ledger.sh:491`). This is correct in both
directions:

- `--outcome skipped` with **no** `--confidence` → `confidence` is still the
  default `fresh` at the `case` → passes the check → then downgraded to `low`.
  Unchanged behaviour, pinned by a test.
- `--outcome skipped --confidence bogus` → `confidence_set=1`, value `bogus` →
  **refused**. Desired: an explicit bad value is a typo whichever outcome it
  rides on.
- `--outcome skipped --confidence low` → passes, no downgrade needed. Fine.

The downgrade block only ever *produces* `low`, which is in-vocabulary, so it can
never be tripped by the new `case`.

### Inline `case`, not a helper

`is_uint` / `is_bool` / `looks_like_tier` / `looks_like_gate` are helpers because
their values land in a **bare** (unquoted) JSON position and several are reused.
`--outcome` and `--resolution` (cmd_assume) are quoted-position closed-set string
enums checked with an **inline `case`** at their use site. `--confidence` is the
same kind of value in the same kind of position, used once — so it gets an inline
`case`, matching its closest siblings exactly.

### Round-1 gate additions

Four fresh blind gates (G4/G6/G7/G8) converged on one finding: the *rationale
prose* — the new code comment, the operator-facing `REFUSED` string, and the
test comment — described the dashboard as failing **open** (a bad value "renders
as a clean independent pass") when `app.js`'s `isIndependent()` is a deliberate
`=== "fresh"` allow-list that fails **closed** (a bad value → `isSelfCheck()`
true → hatched as an author self-check, dropped from the fresh/low/challenge
counts). The guard *logic* was unanimously found correct and well-placed. Fixed
by rewording all three; the real harm — a genuine challenged fresh review
logged with a typo silently vanishing from the disagreement quota, per the real
`ci-to-codebuild` `--confidence true` record (`b471896`) — is now stated
directly.

Two round-1 additions from those gates:

- **G8 Dogfood (r1 → r2 → user decision):** omitting `--confidence` on a
  `pass`/`fail` defaulted to `fresh` silently — the closed-set refusal is hollow
  if the protected value has an unspoken default. R1 fix added a *warning*; G8 r2
  found that insufficient (the default still favours the stat-feeding value,
  inconsistent with `skipped`/`n-a` → `low` and `--model` → `unset`). Per the
  user's decision (2026-09-09): **`--confidence` is now REQUIRED for a verdict**
  — `cmd_add` refuses `pass`/`fail` logged without it, exit 2, nothing written.
  The `if [ "$confidence_set" -eq 1 ]` branch does the vocab check; the `elif
  pass|fail` branch does the required check; `skipped`/`n/a` fall through
  (exempt, downgraded to `low`). The default initialiser dropped from `"fresh"`
  to `""` (now unreachable for emit). ~48 `led add` invocations in
  `tests/run.sh` and two `core/04-ledger.md` examples gained `--confidence
  fresh`. Regression test: `test_ledger_requires_confidence_on_a_verdict`.
- **G4 Ripple:** the rewritten `emit()` comment claimed `--lane` is "free text
  by design" — false: `core/04-ledger.md` documents it as exactly `normal|hotfix`
  and `cmd_report` buckets it literally, so it carries the *identical* latent
  gap. Comment corrected to say so; guarding `--lane` / `--model` deferred to a
  follow-up (guarding `--lane` requires rewriting the 2026-08-13 forge
  regression test, which asserts a hostile `--lane` is accepted-and-escaped).
  Registry row added for the 4-way `confidence` vocabulary coupling.

### `json_escape` on `confidence` in `emit()` — kept

Now redundant (the value can only be `fresh` or `low`), kept as defense-in-depth
against the check ever being loosened — the same rationale the file already
applies to `tier`/`gate`/`outcome`, and `finding_json` applies to `severity`. The
comment at `ledger.sh:~513` is updated to say so.

## Couplings triggered

Curated `project/registry.md` is empty (the `status.sh` "G4 would invent its
input" warning is pre-existing, not introduced here). `project/map.md` is the
applicable coupling record.

| Registry / map entry | Check performed | Result |
|---|---|---|
| `project/map.md` — `tools/ledger.sh` writes the ledger; `tools/dashboard/app.js`, `ledger.sh report`/`gates`/`compliance`, `tools/status.sh` read it | Every reader of `confidence`: `app.js` `isIndependent`/`isSelfCheck` (allow-list on `"fresh"`, blocklist-free — unaffected, tolerates any string); `ledger.sh report` (`grep -c '"confidence":"fresh"'` / `'"low"'` — literal, unaffected); `ledger.sh gates` (`:1327` — `grep -c '"confidence":"fresh"'`, literal). No reader enumerates the confidence vocabulary or would break on the *absence* of new out-of-vocab values. | Refusing new out-of-vocab writes strictly shrinks the set of values readers see. No consumer coordination needed. |
| `core/04-ledger.md:18` / `core/cards/G*.md` `logs_with:` / `core/02-gates.md:113` | All already state `fresh\|low`. The tool was the lenient one; the docs mandated the closed set. | No doc change required — this brings the tool into line with docs that were already right (mirrors the `--outcome passs` fix, which cited `04-ledger.md` / `--tier` / `--resolution` as already-strict siblings). |
| `core/03-registry.md` universal couplings (auth/session, migrations, quotas, id-space, load-order) | Scanned — none apply. A CLI arg validator with no persisted state, no schema, no shared namespace. | None triggered. |
| Append-only ledger history (`ledger.jsonl`: 5×`high`, 19×`same-session`; `experiments/**` clean) | These predate the check and stay. `isIndependent()` renders them non-independent correctly today. `tests/dashboard-logic.test.js` fixtures deliberately use `high`/`self`/`same-session` and must stay green. | Verified: `node tests/dashboard-logic.test.js` is untouched by a `ledger.sh` `cmd_add` change and continues to pass. |

## Edge decisions

| Edge | Decided behavior | Decided by |
|---|---|---|
| `--confidence fresh` / `--confidence low` | Accepted, written, exit 0. | vocabulary |
| No `--confidence` flag, `--outcome pass`/`fail` | **Refused**, exit 2, nothing written (`needs --confidence fresh\|low`). | G8 r1/r2 → user decision 2026-09-09 |
| No `--confidence` flag, `--outcome skipped`/`n/a` | Auto-stamped `low`, written. The verdict-requires check exempts these outcomes; the downgrade block is unchanged. | existing downgrade block |
| `--confidence ""` (empty string arg) | Refused — empty is not `fresh`/`low`. Matches `--outcome ""` (also refused). | design |
| `--confidence true` (the real incident) | Refused, exit 2, nothing written. | design |
| `--confidence high` / `same-session` (historical spellings) | Refused for **new** writes. Existing ledger lines untouched (append-only). | design + `04-ledger.md` never-backfill |
| `--confidence FRESH` (case) | Refused — `case` is exact-match, and `isIndependent()` is `=== "fresh"` exact too, so accepting a case variant would write a record the dashboard reads as non-independent. Consistent. | design |
| Multiple `--confidence` flags | Last wins (parse loop overwrites), then the single value is checked. Same as every other repeated flag here. | existing contract |

## Error contract

| Failure | User | Developer | System |
|---|---|---|---|
| `--confidence` outside `fresh\|low` | `REFUSED: --confidence '<v>' is not one of fresh\|low.` + 3 lines naming the consequence (dashboard reads non-`fresh` as a self-check that ran fresh) + `Nothing was written`. Exit 2. | Same text on stderr; `run()` in the suite captures it. `reconcile.sh` does not call `ledger.sh add`, so no wrapper masks it. | Nothing appended. Identical shape to `--outcome` refusal. |
| No *new* success path, no new silent path. | | | |

## Silent failure

> **How would we know if this refusal itself broke?**
>
> - **Too strict** (rejects a legal `fresh`/`low`): every gate log in the repo
>   starts failing at exit 2 — the loudest possible signal, and
>   `test_ledger_still_accepts_fresh_and_low_confidence` pins all four legal
>   forms (explicit fresh, explicit low, defaulted, skipped-downgraded).
> - **Too lax** (a bad value still writes): the original bug. Pinned by
>   `test_ledger_refuses_an_unknown_confidence`, which asserts both the exit code
>   **and** that the ledger file has no `"gate":"G7"` line afterward — the record
>   is the assertion, not the message (same discipline as
>   `test_ledger_refuses_an_invalid_severity_and_writes_nothing`).
>
> The validator has no telemetry and needs none — a refusal is synchronous and
> exit-coded, and the suite drives it directly.

## Independence

- [x] No new shared symbol in a shared scope — the `case` uses only the existing
      function-local `$confidence`.
- [x] No storage key added or renamed — the record shape is byte-identical for
      every value that was already legal.
- [x] No id/priority from a shared space.
- [x] No load-order dependence — a `case` in an already-defined function.
- [x] Tests pass with no other change applied — this is the only change in
      flight.

**Verdict:** independent. Ships alone.
