# ledger-token-split — Requirements

> Written at the Intent gate (G1a), before Build. Prompted by a maintainer question during a
> planning session: the ledger's `tokens` field is one aggregate number, and input/output are
> priced differently by every provider — an aggregate hides which direction a gate's cost
> actually grew in.

## User

Anyone reading `ledger.sh report`/`gates` or the dashboard to decide whether a gate's model
tier (`core/08-models.md`) is worth its cost, or whether a gate is expensive because of what
it is handed (a large diff) versus what it produces (a long report).

## Problem

`tools/ledger.sh add --tokens N` records one number. Two runs with the same `tokens` total can
be opposite in shape — one spent mostly on a large diff handed in, the other on a long report
handed back — and the aggregate cannot tell them apart. `LEARNINGS.md`'s
`experiments/001-first-run` entry already needed `tokens_in`/`tokens_out` as concepts for a
benchmark session-record template; the ledger itself never grew the equivalent fields.

## Acceptance criteria

- [x] `ledger.sh add` gains `--tokens-in N` / `--tokens-out N`, optional and **paired** — one
      without the other is refused. The pairing exists because the two values are used to
      *compute* `tokens` (below), not because a lone value is meaningless on its own — checked
      on whether the flag was passed, not on the value being non-empty, so `--tokens-in ''` is
      refused as an invalid value rather than read as omitted.
- [x] When `--tokens` is not also given, `tokens` (the existing aggregate field) is computed as
      the sum of the split, so every existing reader that only ever knew the aggregate —
      `cmd_gates`, `cmd_report`, the dashboard's token math — keeps working unchanged with no
      code of its own to update.
- [x] An explicit `--tokens` **less than** `tokens_in + tokens_out` is refused (the parts can't
      outweigh the whole). One **greater than or equal to** the split is accepted and kept as
      given, not overwritten — a true billed total may legitimately exceed the split when it
      includes cost the split doesn't categorize (cache-read/cache-creation tokens, which this
      kit's own subagent gates incur every run). *Originally specified as exact equality; G4
      Ripple round 1 challenged that as unable to record a true total alongside an honest
      partial split, and this was relaxed in response — see Assumptions.*
- [x] `tokens_in`/`tokens_out` are written to the JSON record only when given — a line from an
      older `ledger.sh`, or one that only ever passed `--tokens`, stays valid and readable by
      every existing tool. Same widening `core/04-ledger.md` already documents for `date`
      (bare-day → full-instant): mixed shapes are the permanent, ordinary state.
- [x] `tokens_in`/`tokens_out`/`tokens` land in the same bare (unquoted) JSON position `tokens`
      always has, and are validated before reaching `emit()`, not escaped. Validation is
      **bounded**, not plain non-negative-integer: bash's signed 64-bit arithmetic overflows
      silently past 2^63, so each of the three is capped at 15 digits — far beyond any real
      token count, but
      enough to keep the sum from ever reaching a value that could wrap. *Plain `is_uint` was
      the round-1 shape; G6 Peer / G7 Threat round 2, independently, showed a 20-digit operand
      wraps to an arbitrary in-range value that passes a sign-only check — see Assumptions.*
- [x] `ledger.sh report` shows a summed `tokens in/out` line — counted by how many recorded
      lines carry the `tokens_in` key (so a genuine `0`/`0` split still shows), not by the
      summed value being positive — in addition to the existing aggregate `tokens spent` line.
      Both lines are formatted to one decimal place so a total and its split visibly reconcile.
- [x] `core/04-ledger.md` documents the new fields, accurately, in the field table and in "Cost
      is a constraint, not an outcome."
- [x] All 8 gate cards (`core/cards/G1..G8`) document `--tokens-in`/`--tokens-out` on their
      `logs_with:` line, the same way `--withhold-breached` already is — a subagent handed only
      its card has no other way to learn the flags exist (G6 Peer round 1, blocking).
- [x] A genuine `--tokens 0` does not trigger the "no --tokens recorded" note (write side) and
      `cmd_report`'s floor caveat states honestly that it cannot distinguish an explicit zero
      from an omission at read time, rather than asserting the stronger "floor" claim for every
      zero-valued line (G8 Dogfood round 1; G6 Peer round 2).
- [x] Regression tests in `tests/run.sh`: records the split and computed total; refuses each
      one-sided pairing (including an explicitly-empty value); accepts a `--tokens` greater
      than the split and keeps it as given; refuses a `--tokens` less than the split; refuses
      oversized operands that would otherwise wrap; refuses non-integer/injection values in the
      same bare position `tokens` is already tested against.

## Out of scope

- **Per-gate average tokens-in/out in `cmd_gates`'s table.** The aggregate `avg tokens`/`per
  find` columns are untouched; splitting those too is a follow-up if the report-level total
  turns out not to be enough.
- **Backfilling old ledger lines.** Never — `04-ledger.md`'s "Keeping it honest" rule.
- **A model-tier re-evaluation trigger in `core/08-models.md`.** Related (this field is what
  would make that trigger measurable instead of a guess) but tracked as a separate change —
  see earlier session notes on model-version cadence.

## Assets required

N/A — no non-code deliverables.

## Prior art

N/A — Scout (G2) fires only for net-new user-facing capability (`core/cards/G2-scout.md`);
this is an additive field on an existing internal tool, not a new capability.

## Assumptions (10-probe.md checkpoint 1 — logged via `ledger.sh assume`)

1. **`tokens` should stay the source of truth for the total**, computed from the split when
   given, rather than requiring every caller to switch to `tokens_in + tokens_out`.
   `resolution: defaulted`, basis: every existing reader (`cmd_gates`, `cmd_report`, the
   dashboard) sums/averages the aggregate field, and revisiting all of them was out of scope
   for this change.
2. **A one-sided `--tokens-in`/`--tokens-out` is a mistake, not a "spent nothing in the other
   direction" signal**, so it is refused rather than defaulted to zero. `resolution:
   defaulted`. Originally justified by analogy to `--action`/`--evidence`'s pairing rule in
   `cmd_route`; G6 Peer round 1 correctly rejected that analogy (a lone `--evidence` is
   meaningless, a lone `--tokens-in` is a true, usable number) — the real reason is that the
   pair feeds a computation (`tokens = tokens_in + tokens_out`), so a one-sided value would
   corrupt that computation rather than merely describe a direction as zero.
3. **An explicit `--tokens` must equal the split exactly, or be refused as a contradiction.**
   `resolution: reversed`. This was round 1's rule; G4 Ripple round 1 challenged it directly
   (`challenged_premise: true`) — this kit's own subagent gates bill cache-read/cache-creation
   tokens on every run, which belong to neither `tokens_in` nor `tokens_out` as this field
   defines them, so exact equality made a true, honest total unrecordable alongside a partial
   split. Reversed to: refused only if *less than* the split; accepted and kept as given if
   *greater than or equal to* it.
4. **Non-negative-integer format validation (`is_uint`) is sufficient for `tokens`/
   `tokens_in`/`tokens_out`.** `resolution: reversed`. `is_uint` checks shape, not magnitude;
   G6 Peer and G7 Threat, independently in round 2, showed a 20-digit operand wraps bash's
   64-bit arithmetic to an arbitrary positive value that then passes a sign-only check (round
   1 had only closed the *negative*-wrap case). Reversed to a bounded check (`is_uint_bounded`,
   15-digit cap) on all three fields.

## Acceptance (G1b — after Build)

| Criterion | Evidence |
|---|---|
| `--tokens-in`/`--tokens-out` added, paired on flag-presence, validated as bounded bare-position integers | `tools/ledger.sh` diff (`cmd_add`, `is_uint_bounded`) |
| `tokens` computed as the sum when the split is given and `--tokens` is not; `--tokens` less than the split refused, greater-or-equal accepted and kept | `tests/run.sh:test_ledger_records_tokens_in_and_out_and_computes_the_total`, `test_ledger_refuses_tokens_that_contradicts_the_split`, `test_ledger_accepts_tokens_that_agrees_with_the_split`, `test_ledger_accepts_and_keeps_tokens_greater_than_the_split` |
| One-sided pairing refused both directions, including an explicitly-empty value | `tests/run.sh:test_ledger_refuses_tokens_in_without_tokens_out`, `test_ledger_refuses_tokens_out_without_tokens_in`, `test_ledger_refuses_an_explicitly_empty_tokens_in`, `test_ledger_refuses_an_explicitly_empty_tokens_out` |
| Bare-position injection and magnitude overflow refused | `tests/run.sh:test_ledger_refuses_non_integer_tokens_in_and_out`, `test_ledger_refuses_tokens_in_out_that_overflow_the_sum` |
| Explicit zero vs. omission handled honestly on write and read | `tests/run.sh:test_ledger_explicit_zero_tokens_does_not_warn_that_nothing_was_recorded`, `test_ledger_omitted_tokens_still_warns_that_nothing_was_recorded`; `tools/ledger.sh` diff (`cmd_report` floor-caveat wording) |
| `cmd_report` shows a split line counted by presence, not summed value | `tests/run.sh:test_ledger_report_counts_a_genuine_zero_zero_split`; `tools/ledger.sh` diff (`cmd_report`) |
| Unknown subcommand gives a short stderr refusal; bare invocation still shows the header | `tests/run.sh:test_ledger_unknown_subcommand_gives_a_short_stderr_refusal`, `test_ledger_bare_invocation_still_prints_the_header` |
| All 8 gate cards document the new flags | `core/cards/G1..G8-*.md` diffs (`logs_with:` line) |
| `core/04-ledger.md` documents the fields accurately (>= semantics, bounded validation) | diff to the field table and "Cost is a constraint, not an outcome" |
| Discrimination proof, every round: new/changed assertions fail against the pre-fix code, pass after | round 1 (9 assertions), round 2 (9 more), and round 3 (6 more, incl. a mutation test G7 round 3 proved actually catches the regression) all verified via `git stash push -- tools/ledger.sh` / re-run / `git stash pop`, or live mutation, this session |
| Full suite green | round-1 code: 807/0/0 → round-2: 807/0/0 → round-3: 838/0/0 → final (round-3 polish + coverage additions): **845/0/0** |
| G1 Intent, G5 Proof | pass (all rounds) — same-session gates, logged directly |
| G4 Ripple | **pass, round 1**, `challenged_premise: true` — see Assumption 3 |
| G6 Peer | fail round 1 (1 blocking + 7 minor/info) → fail round 2 (7 minor + 4 info + 1 out-of-scope, filed as `task_0d68cd41`) → **pass round 3** (0 blocking/minor, 4 info + 1 out-of-scope — the out-of-scope item is `cmd_compliance`'s own unbounded `--round`, independently rediscovered and already filed via G7's report) |
| G7 Threat (hard gate) | fail round 1 (1 minor: unbounded overflow) → fail round 2 (1 minor: bound was sign-only, not magnitude) → **pass round 3** (0 blocking/minor, 4 info + 1 out-of-scope, `challenged_premise: true` — verified airtight via mutation testing) |
| G8 Dogfood | fail round 1 (4 minor UX surprises, all fixed) → fail round 2 (fix confirmed for all 4 target items, but a pre-existing unrelated footgun + a self-disclosed non-contaminating withhold breach surfaced during self-logging — filed as `task_f3521d2e`, routed out of this change per the failure rule in `02-gates.md`: "a finding can be real and still not be about this change"). **Not re-run a third time** — round 2 already confirmed the fix itself is correct; a third blind pass would re-hit the same known, already-filed footgun for no new information about this change's correctness. Routing this fail as non-blocking is the change owner's judgment call, stated here rather than silently overturning the gate's own verdict. |

## Restatement

Widen the ledger's `tokens` field so a gate run can optionally record input and output cost
separately, without breaking any existing reader of the aggregate — because input and output
are priced differently and an aggregate number cannot tell you which one grew.
