# Security review — compliance's recorded-reason check, and its R0b cross-reference

Reviewed commit: `a6298429b57fd8a3d4878406dbbcce0dc03c739c` — G7 pass, diff-only
(`git diff e7ec6aa..a629842 -- tools/ledger.sh core/01-router.md`), against the files as they
exist on disk at HEAD right now.

Files in scope: `tools/ledger.sh`, `core/01-router.md`.
Trust-boundary basis: `project/surfaces.conf` rates `tools/(reconcile|ledger|install-hook|
install-claude-hook|status)\.sh$` T4 ("Routing and evidence — a wrong answer here is silent and
confident") and `core/01-router\.md$` T4 ("The gate matrix itself — every tool derives from
it"). Both files this range touches are in that set. `tools/dashboard/app.js` (T1) and
`tests/run.sh` (T3) also changed in this range but are below the T4 threshold the hook enforces
and are not reviewed here.

## What the diff does

Two changes, traced separately below:

1. **`tools/ledger.sh`**: a new `change_has_recorded_reason()` (`tools/ledger.sh:896-919`), and a
   new block inside `cmd_compliance()`'s `n_missing -eq 0` branch (`tools/ledger.sh:1163-1200`)
   that hard-refuses (REFUSED, exit 1) at T3/T4 when every mandated gate passed but this function
   finds neither a route `--reason` nor round 1's G1 `--note` for the change. Mirrors the existing
   `gate_outcome_has_reason()` (`tools/ledger.sh:892-893`) in shape — same "does a JSON string
   field carry non-empty content" existence check — and the existing unresolved-assumption check
   directly above it in placement and rationale.
2. **`core/01-router.md`**: a six-line prose addition to the R0b section (lines 64-69),
   cross-referencing `reconcile.sh`'s `REASON=` env var and G1's note as the two ways to satisfy
   the check added in (1). No code, no table row, no footnote marker.

## Trust boundary walk

**`core/01-router.md`, positional-parser interference.** `tools/lib/matrix.sh` (`_matrix_load()`,
lines 39-63) and `tools/dashboard.sh` both derive the gate matrix and its footnotes from this
file *positionally*: the matrix awk triggers on lines starting `| **G[0-9]`, and the footnote awk
starts capturing immediately after the last such table row and stops at the first line beginning
`#`, `**`, or `---`. The new paragraph starts with `**Set...` — a pattern that, in the *wrong*
location, would either get swallowed as a spurious footnote line or (if placed right after the
real table) prematurely terminate real footnote capture. Checked concretely: the new paragraph
sits in R0b (`core/01-router.md:54-79`), roughly 180 lines above the actual gate matrix table and
its five real footnotes (`core/01-router.md:255-278`) — nowhere near either awk's positional
window, which only ever activates for text immediately following a line matching
`| **G[0-9]`. Live-verified: `bash tools/lib/matrix.sh` sourced and `matrix_required T4` /
`matrix_gates` run against the current file both return the unchanged 8-gate set with the same
five footnote markers as before this diff (`¹²³⁴⁵`, one per `R`-cell gate) — no new or dropped
gate, no shifted footnote. Also checked: the new text contains no `|` pipe characters, so it
cannot be misread as a table row of any kind by either parser.

**`change_has_recorded_reason()`, forged-field injection.** The obvious attack: craft a
different free-text field on a *legitimate* CLI call (`--model`, `--lane`) to contain a raw,
unescaped `","reason":"..."` or `","note":"..."` byte sequence, so the naive unanchored
`grep -q '"reason":"[^"]'` / `'"note":"[^"]'` fires on a forged field instead of a real one.
Live-reproduced: `ledger.sh add --change c2 --gate G1 --tier T3 --round 1 --outcome pass --model
'evil","note":"FORGED-REASON' --note ''` writes
`"model":"evil\",\"note\":\"FORGED-REASON","note":""` — `json_escape()` (`tools/ledger.sh:247-251`,
applied to every string field written by `cmd_add`/`cmd_route`, confirmed by grepping every call
site) escapes the backslash-then-quote sequence *before* the quote itself, so the raw bytes
`"note":"` never appear anywhere except at the genuine, empty `"note":""` field. `compliance`
against that record correctly refused. This is the same defense the file's own prior CLI-
hardening review (`security-reports/2026-08-14-cli-input-validation-hardening.md`) already
verified for the sibling `gate_outcome_has_reason()`; this diff adds no new field, no new sink,
and inherits the same closure — every string field in both the `gate` and `route` templates
(`tools/ledger.sh:469-472,563-566`) already passes through `json_escape()`.

**Round-number substring collision.** The G1 half of the check scopes to round 1 specifically
via `grep '"round":1,'`, matching the file's existing round-matching convention
(`gate_latest_outcome`/`gate_passed_round`'s `grep "\"round\":$r,"`). The obvious concern: does
`"round":1,` false-match `"round":10,`, `"round":11,`, `"round":21,`, etc.? It cannot — the
trailing comma immediately after the digit is part of the literal pattern, and `"round":10,`'s
character after the `1` is `0`, not `,`. Live-reproduced across rounds 1, 10, 11, 21: a G1 entry
with a real note logged at round 1 satisfies the check; the identical entry logged at round 10,
11, or 21 (all mandated gates otherwise passing at that same round) correctly refuses every time,
with no bleed-through from the shared leading digit.

**Change-name prefix collision.** The route half of the check uses `grep -F "\"change\":\"$1\""`
(literal string, not `gate_entries`'s unescaped-BRE convention used elsewhere in this file — a
deliberate hardening for this new function, not a regression). Checked whether a change named
e.g. `c1` could inherit a route `--reason` actually logged against a differently-named change
that merely shares `c1` as a prefix, e.g. `c10`. It cannot: the pattern requires the literal
closing `"` immediately after the change name, so `"change":"c1"` is not a substring of
`"change":"c10"` at any alignment. Live-reproduced: a `route --change c10 --reason "belongs to
c10 only"` record, plus a `c1` with every mandated gate passing and a note-less G1, still
correctly refuses `compliance --change c1` — c10's reason does not leak across.

**Outcome-independence, by design not oversight.** The G1 half deliberately does not filter by
outcome — round 1's G1 note counts whether that entry passed, failed, or was later superseded by
a same-round retry, matching `tools/dashboard/app.js`'s `whyThisRan()`, which reads
`round1.gates.filter(g => g.gate === "G1")[0]` unconditionally. Live-reproduced as a *positive*
control (not a vulnerability): a round-1 G1 logged `fail` with a real note, followed by a
round-1 G1 logged `pass` with none, still satisfies the check — this is the documented, tested
behavior (`tests/run.sh`'s `test_compliance_accepts_a_round_1_g1_note_regardless_of_that_entrys_own_outcome`),
not a bypass, since the "why" question is independent of whether G1's own verdict was clean.

**Tier-gating logic.** `is_uint "$tier_n" && [ "$tier_n" -ge 3 ]` runs only after `cmd_compliance`
has already validated `$tier` against the `T0|T1|T2|T3|T4` case statement (`tools/ledger.sh:951-959`)
earlier in the same function, so `$tier_n` is always a single digit by the time this check runs —
the `is_uint` guard is redundant defense-in-depth, matching the identical redundant guard on the
unresolved-assumption check directly above it, not a new trust decision.

**Placement relative to the INCOMPLETE report.** The check lives inside the `n_missing -eq 0`
branch specifically, not alongside the assumption check that fires unconditionally above it — a
deliberate choice made after a first version (unconditional) was found, during this same
session's testing, to mask the more specific `INCOMPLETE — N mandated gate(s) without a pass`
message for changes that had not finished their gates yet. Six pre-existing tests that exercised
that message were re-run and confirmed unaffected by the final placement.

No privilege grew unremarked: the new check can only make `compliance` *more* restrictive
(REFUSED where it previously exited 0), never less. No new external input source was
introduced — `$change`/`$tier`/`$round` are the same, already-validated arguments
`cmd_compliance` accepted before this diff. No check added here is itself bypassable by the
inputs it exists to reject.

## Findings

None. Two real logic bugs were found and fixed during this session's own iterative testing
(before this commit) — the G1 half originally scanned any round/outcome rather than round 1
specifically, which both diverged from `whyThisRan()`'s own resolution and let a stale note
satisfy the check permanently — and both are covered by regression tests
(`test_compliance_ignores_a_g1_note_logged_only_at_a_later_round`,
`test_compliance_accepts_a_round_1_g1_note_regardless_of_that_entrys_own_outcome`) already in
this commit, not left open.

Full suite: `bash tests/run.sh` → `passed 598 · failed 0 · skipped 0`.

Logged: `ledger.sh add --change compliance-refuses-missing-reason-at-t3-t4 --gate G7 --tier T4
--round 2 --outcome pass --confidence fresh --challenged false --model claude-sonnet-5 --note
"adversarial review covering both this change and the R0b cross-reference doc commit
(router-doc-cross-references-reason-env-var): forged-field injection via json_escape()
closure, round-number substring collision, change-name prefix collision, positional-parser
interference with matrix.sh/dashboard.sh -- all live-reproduced and closed or confirmed by
design, see security-reports/2026-08-19-reason-recorded-check.md"` — round 2, since this
change's round 1 G7 (self-graded, logged when the compliance change was first committed) is
superseded by this adversarial pass covering the full pushed range.
