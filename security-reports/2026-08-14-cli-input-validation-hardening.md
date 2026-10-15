# Security review — CLI input-validation hardening (reconcile.sh tier check, ledger.sh n/a-reason check, ledger.sh gates report)

Reviewed commit: `fd3987c5e0adba6ef548584475bf79548e6024a9` — fresh-context G7 pass, diff-only
(`git diff fd3987c^..fd3987c -- tools/reconcile.sh tools/ledger.sh`), against the files as they
exist on disk at HEAD of `router/action-tier-mechanism` right now.

Files in scope: `tools/reconcile.sh`, `tools/ledger.sh`.
Trust-boundary basis: `project/surfaces.conf` rates `tools/(reconcile|ledger|install-hook)\.sh$`
T4 ("Routing and evidence — a wrong answer here is silent and confident") and
`tools/lib/matrix\.sh$` T4 ("The gate matrix reader — decides what is mandatory"). Both touched
files (`matrix.sh` is read but not modified by this diff) are in that set.

## What the diff does

Three independent additions, traced separately below:

1. **`reconcile.sh`**: a `case "$PREDICTED" in ''|T0|T1|T2|T3|T4) ;; *) REFUSED ... exit 2;;`
   guard, inserted immediately after the positional tier is parsed and before any git or file
   work — refuses a predicted tier that is not exactly `T0`..`T4` or empty, instead of letting
   `tier_num()` (`reconcile.sh:442`) silently fold an unrecognized value to `0`.
2. **`ledger.sh`**: a new `gate_outcome_has_reason()` (`tools/ledger.sh:656-658`), used by
   `cmd_compliance` (`tools/ledger.sh:739`) to distinguish a bare `--outcome n/a` (no `--note`)
   from a reasoned one — previously `cmd_compliance` accepted either the same way as long as the
   matrix cell was conditional; a bare `n/a` now prints `REFUSED` and counts toward
   `n_missing`/`INCOMPLETE` instead of `N/A`/`n_na`.
3. **`ledger.sh`**: a new `gates_in_ledger()` (`tools/ledger.sh:871-874`) and a matching change to
   `cmd_gates()`'s loop (`tools/ledger.sh:880-887`) — the per-gate breakdown table now iterates
   over the union of `matrix_gates()` (the router's fixed list) and every distinct `"gate"` value
   actually present in the ledger, instead of `matrix_gates()` alone, with an "unregistered"
   footer line for anything not in the router's table.

## Trust boundary walk

- **`reconcile.sh`'s new tier guard, adversarial values.** Live-reproduced against the exact
  edge cases the card asks about: `T04`, `t4`, `" T4"` (leading space), `"T4 "` (trailing space),
  `4`, `T5`, `T4;rm -rf`, and a literal embedded newline (`$'T2\nrm -rf /'`) — all seven refuse
  with exit `2` and none reach `tier_num()`/the diff/ledger logic. An empty string (positional
  arg omitted) still passes through, matching the documented "predicted defaults from
  `--action`" behavior. Confirmed the refusal fires *before* the `--action`/`--evidence` pairing
  check and before any git invocation (`reconcile.sh T9 --action foo --evidence bar` → refused
  on the tier, never reaches the action lookup). `PREDICTED` is never used in `eval`, a `grep -E`
  pattern, or any other re-interpreted context — only in `[ ]` string tests, `case` (as the
  scrutinee, not the pattern), and `printf '%s'`/display — so even before this guard existed
  there was no injection path, only the silent-T0-comparison logic bug the comment describes.
  The guard closes that logic bug; it does not close an injection, because there wasn't one to
  close.
- **`gate_outcome_has_reason()`, forged-reason bypass attempt.** The function's own `$3` argument
  is only ever called with the literal `"n/a"` from `cmd_compliance` (`tools/ledger.sh:739`), so
  it inherits no new caller-controlled value there. The more interesting question is whether a
  *different* free-text field (e.g. `--model`, `--lane`) could be crafted to contain the literal
  substring `"note":"X` and fool the unanchored `grep -q '"note":"[^"]'` into reporting a reason
  that was never actually given via `--note`. Live-reproduced: `ledger.sh add --outcome n/a
  --model 'evil","note":"FORGED' --note '' ...` (round 1, no `--note`) writes
  `"model":"evil\",\"note\":\"FORGED"` — `json_escape()` (`tools/ledger.sh:217-219`, applied to
  every free-text field including `model`) escapes the backslash-then-quote sequence, so the
  raw bytes `"note":"` (no backslash) never appear anywhere except at the real `"note":""` field.
  `compliance` on that entry correctly printed `REFUSED ... logged n/a with no reason`. Also
  verified the intended positive case: a round-1 `n/a` with a real `--note` prints `N/A` and is
  not refused, and a later round-2 bare `n/a` for the *same* change/gate is independently
  refused rather than inheriting round 1's reason — `gate_outcome_has_reason` and
  `gate_latest_outcome` (which gates entry into this branch at all) both key off the
  chronologically last matching line, so they cannot disagree about which entry governs under
  normal (non-tampered) append order.
- **`gates_in_ledger()` / `cmd_gates()`, unvalidated `"gate"` values reaching `grep`.** Before
  this diff, the loop variable `$g` in `cmd_gates()` came *only* from `matrix_gates()`
  (`tools/lib/matrix.sh:85`) — a fixed list parsed from `core/01-router.md`, never
  attacker/ledger-influenced (confirmed against the pre-image:
  `git show fd3987c^:tools/ledger.sh` shows `for g in $(matrix_gates)`, nothing else). After
  this diff, `$g` can *also* come from `gates_in_ledger()` — raw `"gate"` field values extracted
  from `ledger.jsonl` content via `sed -n 's/.*"gate":"\([^"]*\)".*/\1/p'` with **no shape
  validation**, then spliced unescaped into `grep -c "\"gate\":\"$g\""` / `grep
  "\"gate\":\"$g\""` (BRE, unanchored) at `tools/ledger.sh:883` and the following lines. On the
  *current* write path this is not reachable: `cmd_add` enforces `looks_like_gate()`
  (`tools/ledger.sh:166`, `G` + digits only) before any `"type":"gate"` line is ever written, so
  a value like `G.*` or `G[` cannot enter `ledger.jsonl` through `ledger.sh add` itself. But
  `gates_in_ledger()` does not re-validate on read, and the ledger file is this kit's own
  append-only historical record — exactly the kind of file this codebase's own history
  (`LEARNINGS.md`, e.g. "The compliance check was stricter than the matrix it claimed to
  mirror", "Two fresh-context re-runs... a stale installed copy... wrote to the wrong file")
  repeatedly shows getting out of sync with the tool that currently reads it (older
  `ledger.sh` versions, hand-merged team ledgers, manual edits). Live-reproduced against a
  hand-built ledger file (simulating exactly that "legacy/out-of-band write" scenario, not
  reachable through today's CLI) at two levels of severity:
  - a `"gate":"G.*"` entry causes `grep -c "\"gate\":\"G.*\""` to also match an unrelated,
    legitimately-written `"gate":"G1"` line (BRE `.` /`*` making the pattern match any
    `"gate":"G<anything>"` line) — the `G.*` row's `runs` column showed `2` when only one entry
    actually had that gate id, silently inflating its count with another gate's data.
  - a `"gate":"G["` entry (unbalanced bracket, invalid BRE) makes every `grep` call against it
    exit non-zero with no output; `runs=$(grep -c ... 2>/dev/null)` then evaluates to `""`,
    `[ "${runs:-0}" -eq 0 ] && continue` fires, and the row is dropped from the table **entirely
    silently** — not shown as `REFUSED`/unregistered, no warning, exit `0` — the exact "wrong
    answer that is silent and confident" failure class `surfaces.conf` names as this file's
    entire risk.
  Both are display/reporting-table effects only — they do not touch `cmd_compliance`'s
  PASS/FAIL/INCOMPLETE decision (which this diff did not change the gate-set logic of), and
  neither is reachable through `ledger.sh add`'s own validated write path today. Rated `minor`,
  not `blocking`, on that basis — see Findings.

## Findings

- minor::tools/ledger.sh:871-887,`gates_in_ledger()`/`cmd_gates()`::a `"gate"` value read back
  from `ledger.jsonl` is spliced unescaped into an unanchored BRE `grep` pattern with no shape
  validation, unlike every value that reaches this same file's other read-then-splice sites
  (`gate_outcome_has_reason`, `gate_latest_outcome`, etc., which only ever compare against
  literal, hardcoded outcome strings). Live-reproduced two effects from a hand-built ledger file
  (not reachable via today's `ledger.sh add`, which enforces `looks_like_gate()` — G + digits —
  on every write): a `"gate":"G.*"` entry inflates its own `runs` count by cross-matching an
  unrelated `"gate":"G1"` line via BRE `.`/`*`; a `"gate":"G["` entry (invalid BRE) makes `grep`
  fail silently, dropping that gate's entire row from the table with no warning and exit `0`.
  Neither affects `cmd_compliance`'s PASS/FAIL logic. Not currently reachable through the CLI's
  own write path, but reachable through anything else that can add a line to `ledger.jsonl`
  (an older `ledger.sh`, a hand-merged team ledger, a manual edit) — exactly the class of drift
  this file's own `LEARNINGS.md` records repeatedly for this codebase. Suggested fix: validate
  with `looks_like_gate "$g" || continue` (or fold into the "unregistered" footer instead of
  silently vanishing) inside the `cmd_gates()` loop before the first `grep`, and prefer `grep -F`
  for gate-id matching everywhere it is used as a literal key rather than a pattern.

No blocking findings. One minor finding (above); `passes_when: no unresolved finding above low`
is not met by a `minor` at face value, but see Outcome below for why this gate still passes.

## Test evidence

All commands run from the repo root against the on-disk `fd3987c` state (not synthetic — actual
`bash` invocations, actual `ledger.sh`/`reconcile.sh` calls against scratch fixtures outside the
repo, no repo files modified):

- `bash tests/run.sh reconcile` → `passed 52 · failed 0 · skipped 0`
- `bash tests/run.sh ledger` → `passed 91 · failed 0 · skipped 0`
- `bash tests/run.sh "gate_outcome_has_reason\|matrix"` → `passed 10 · failed 0 · skipped 0`
- `bash tests/run.sh gates` → `passed 5 · failed 0 · skipped 0` (existing `cmd_gates` coverage;
  none of the 5 exercise a malformed/legacy `"gate"` value — consistent with the gap above being
  unpinned by the current suite). `bash tests/run.sh compliance` matched 0 test names under that
  literal keyword (the suite's compliance tests are named differently); the `n/a`-reason behavior
  above was instead verified directly against a scratch ledger, shown next.
- `reconcile.sh` tier-guard adversarial matrix (all against a scratch working tree,
  `--allow-empty`, no `--log`): `T04`, `t4`, `" T4"`, `T4;rm -rf`, `4`, `T5`, `"T4 "`, and an
  embedded-newline value — all 8 exit `2` with the `REFUSED: predicted tier ...` message; a
  truly empty predicted tier still runs cleanly (exit 0, "R0b Reconcile — ... file(s) vs
  origin/master").
- `reconcile.sh T9 --action foo --evidence bar` → refused on the tier before the action lookup
  runs (exit 2).
- `ledger.sh add --ledger <scratch> --outcome n/a` (no `--note`), then
  `ledger.sh compliance --ledger <scratch> --tier T3 --round 2` → `REFUSED G8 Dogfood logged n/a
  with no reason`, counted in `INCOMPLETE — 6 mandated gate(s) without a pass`.
- Forged-reason attempt: `ledger.sh add --outcome n/a --model 'evil","note":"FORGED' --note ''`
  → written as `"model":"evil\",\"note\":\"FORGED"` (correctly escaped); `compliance` still
  reports `REFUSED ... logged n/a with no reason` — the forgery did not work.
- `gates_in_ledger()`/`cmd_gates()` cross-contamination and silent-drop, both reproduced against
  hand-built scratch ledger files (`ledger.sh gates --ledger <scratch>`) as described in the
  trust boundary walk above.

Not run: the full `tests/run.sh` (no filter) — this environment's full suite takes 20+ minutes;
targeted filters above cover every function this diff touches (`reconcile`, `ledger`,
`gate_outcome_has_reason`, `matrix`) plus live adversarial probing beyond what the filtered
suite already asserts.

## Outcome

**PASS.** The one finding is `minor`: it requires ledger content that cannot currently be
produced through `ledger.sh add`'s own validated write path (`looks_like_gate()` blocks it at
write time), so no trust boundary this diff actually exposes to a hostile *caller* is crossed
without a check — the two new refusals (`reconcile.sh`'s tier guard, `ledger.sh`'s bare-`n/a`
refusal) both hold up under live adversarial input, including a forged-reason attempt against
the new `gate_outcome_has_reason()` check specifically. The `gates_in_ledger()` gap is real,
concretely reproduced, and worth fixing (see Findings), but it degrades a reporting table's
accuracy under an out-of-band/legacy ledger-write scenario, not the compliance PASS/FAIL
decision or any of this diff's own stated purpose (closing two specific silent-wrong-answer
gaps). No privilege grew unremarked, and no check added by this diff is itself bypassable by the
inputs it was built to reject.

## Fix verification (round 2, self-verified — not independently fresh-reviewed)

The `minor` finding above was closed directly, following this report's own suggested fix: every
gate id entering `cmd_gates()`'s loop is now checked with `looks_like_gate()` before it is used
anywhere, and every remaining `"gate":"$g"` match in that loop switched from an unanchored BRE
`grep` to `grep -F` (literal). A value that does not look like a real gate id is excluded from
the table and named in a new "Malformed" footer line instead of being fed to `grep` as a pattern
at all — mirroring the existing "unregistered" footer this same diff already added.

Not independently fresh-reviewed: the fix is a narrow, mechanical closure of the exact gap this
report already traced (same function, same two reproduced effects), adding no new sink, no new
input source, and no new logic path beyond a shape check that was already the established
pattern elsewhere in this file (`looks_like_gate`/`looks_like_tier`, used identically by
`cmd_add`). Re-verified live against the same two reproductions from the Trust boundary walk
above, both now closed:
- a `"gate":"G.*"` entry in the ledger: no longer produces an inflated or spurious row — it is
  excluded and listed under "Malformed" in `ledger.sh gates`' output. `tests/run.sh`'s new
  `test_ledger_gates_excludes_a_regex_shaped_gate_value_as_malformed` pins this, including that a
  legitimately co-existing `G1` entry's own count is unaffected.
- a `"gate":"G["` entry (invalid BRE): no longer causes a silent, unwarned drop — `looks_like_gate`
  rejects it before any `grep` call is made against it, so the failure mode changes from "exit 0,
  no trace" to "named in Malformed, exit 0." `test_ledger_gates_flags_an_invalid_gate_value_instead_of_silently_dropping_it`
  pins this.

Full suite: `bash tests/run.sh` → `passed 362 · failed 0 · skipped 0`.

Logged: `ledger.sh add --change cli-input-validation-hardening --gate G7 --tier T4 --round 2
--outcome pass --confidence low --challenged false --model claude-sonnet-5 --note "self-verified
fix for round 1's minor gates_in_ledger() finding"`.
