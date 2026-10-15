# Security review — the `assumption` record type, compliance refusal, and card calibration

Self-authored fresh-context G7 pass. Filed before the commit that carries it, for the same
structural reason the other reports on this branch give.

Files in scope: `tools/ledger.sh` (T4 — "Routing and evidence"), `tools/status.sh` (T4),
`tools/dashboard.sh` (T3), the eight `core/cards/G*.md` (T3),
`templates/agent-instructions.md` (T3). Docs (`06-extending.md`, `10-probe.md`,
`05-enforcement.md`, the PR template) carry no executable surface and are noted, not walked.

## What the change does

A fourth ledger record type, `assumption`, written by `ledger.sh assume` with a three-word
`resolution` vocabulary (`asked` / `verified` / `defaulted`). `cmd_compliance` gains a check
that refuses a **T3/T4** change still carrying a `defaulted` assumption. Every gate card gains
three required fields (`must_ask`, `overfit_when`, `underfit_when`), enforced by
`dashboard.sh --check` via `REQUIRED_KEYS`. `status.sh` gains a bounded check naming gates
whose project input is absent or still the shipped example.

## Trust boundary walk

- **The new refusal is the thing to attack.** `compliance` exiting 1 is what gates a release,
  so the question is whether an agent (or a crafted value) can make an unconfirmed assumption
  *look* resolved. `unresolved_assumptions()` extracts `assumed` and `resolution` from each
  line with greedy `sub(/.*"assumed":"/ ...)` — a forged `"resolution":"asked"` embedded in a
  free-text field is exactly the shape that would defeat it, and it is the same forged-reason
  attack the `cli-input-validation-hardening` round ran against `gate_outcome_has_reason`.
  Live-reproduced, not reasoned about: `--assumed 'x","resolution":"asked'` with
  `--resolution defaulted`, and separately the same payload in `--basis`. Both are written
  through `json_escape()` (`s/"/\\"/g`), so the raw bytes `"resolution":"` never appear
  outside the real field; the record reads back as
  `assumed='x","resolution":"asked' resolution='defaulted'`, and **`compliance` still exited
  1 with both assumptions listed**. The forgery does not work.
- **Newline injection into an append-only, line-oriented file.** `assumed` is free text and
  the ledger's whole structure is one-record-per-line. `json_escape()` folds newlines to a
  literal `\n` (its `awk NR>1` clause), so a multi-line value stays one line: after a probe
  with an embedded newline the file held 9 lines and 9 records, and every line parsed as JSON.
- **Greedy-match direction, checked rather than assumed.** `sub(/.*"resolution":"/)` takes the
  LAST occurrence. That is the safe direction here — `resolution` is the final field in the
  record template, so even a hypothetical unescaped injection earlier in the line could not
  shadow the real value, only be shadowed by it.
- **`--round` reaches a bare JSON position.** `round` is emitted unquoted (`"round":%s`), the
  same position `cmd_add` already guards. It goes through `is_uint` first and is refused
  otherwise, so a non-integer cannot make the line syntactically invalid — the existing
  `emit`/`looks_like_json_object` structural check remains the backstop.
- **Does the refusal fail open or closed?** Closed, but narrowly and on purpose. It fires only
  at T3/T4 (`is_uint "$tier_n" && [ "$tier_n" -ge 3 ]`), so a malformed tier string cannot
  accidentally trigger *or* accidentally suppress it — a non-numeric tier fails `is_uint` and
  the check simply does not apply, which is the same outcome as T0–T2 and never a silent pass
  at T4. Verified live at T1 (no `UNCONFIRMED` line, exit unaffected) and T3 (exit 1 with
  every mandated gate passing).
- **`status.sh`'s starved-gate check reads project files and prints them.** It only greps for
  fixed markers and prints fixed strings — no project content is interpolated into the output,
  so a hostile `registry.md` or `surfaces.conf` cannot inject text into the report. It is
  deliberately *not* derived from the cards' prose `input:` lines: a check that mis-parses its
  own criteria is the failure this command exists to remove. Both directions are asserted by
  tests, because a check that cannot fire is worse than none.
- **Card fields are data read by `parse_card`.** `must_ask`/`overfit_when`/`underfit_when` are
  ordinary YAML scalars handled by the existing parser and escaped by its `esc()` on the way
  into JSON; they reach the dashboard as strings and are rendered through the same path as
  every other card field. Adding them to `REQUIRED_KEYS` cannot weaken anything — it can only
  turn a previously-accepted card into a refused one, which is the intent.

## Findings

No findings. The one privilege this change adds is the ability to *block* a release, which
fails closed and is bounded to T3/T4; the one new free-text input reaches the ledger through
the same `json_escape()` path every other field already used, and the forged-resolution attack
that would defeat the new refusal was run and does not work.

Worth recording as a deliberate design decision rather than a gap: **`defaulted` is legal.**
Refusing to record it would only teach people to log `verified` instead — the same failure
with better paperwork — which is precisely the reasoning `05-enforcement.md` already gives for
keeping `--no-verify` and insisting it be logged. `verified` is therefore the value that
carries a bar: it is refused without `--basis`, because an unsupported "verified" is
indistinguishable from "defaulted" (`12-grounding.md`).

## Test evidence

- `bash tests/run.sh "assume\|assumption\|calibration\|must_ask\|invent\|declares_its_constraints"`
  → `passed 23 · failed 0`, covering: the record written and valid JSON; the vocabulary
  refusal; `verified` refused without a basis; **compliance refusing at T3 with every mandated
  gate passing**; no block below T3; answering clearing the block while *both* records survive
  (append-only, the guess is not erased); all eight cards declaring all three fields; a card
  with `must_ask` removed genuinely failing `--check`; starved gates named, and *not* named
  when the inputs are real.
- `bash tests/run.sh ledger` → `passed 107 · failed 0` (no regression in the existing
  compliance/report/gates behaviour).
- Injection probes above, run directly against a scratch ledger.

## Outcome

**PASS.** The new refusal cannot be cleared by forged input; the new record type cannot break
the ledger's line structure or its JSON; the new required card fields can only tighten what
`--check` accepts. The design choice most likely to be questioned — allowing `defaulted` — is
deliberate and follows this kit's existing precedent for logged exceptions, with the check
that would be gamed instead (`verified`) carrying the citation requirement.

Logged: `ledger.sh add --change assumptions-and-calibration --gate G7 --tier T4 --round 1
--outcome pass --confidence high --challenged false --model claude-sonnet-5 --note
"self-authored fresh-context G7 pass on the assumption record type, the T3/T4 compliance
refusal, and required card calibration fields; see
security-reports/2026-08-15-assumptions-and-calibration.md"`.
