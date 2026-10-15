# G7 · Threat review — `ledger-token-split` (T4, hard gate, round 1, 7c depth)

**Reviewed:** the **uncommitted working-tree diff on top of `9dd69c4`** ("LEARNINGS.md: remove
the committed NUL byte at offset 100775"). No commit exists for this change at review time;
the subject is `git diff -- tools/ledger.sh core/04-ledger.md tests/run.sh
specs/ledger-token-split/requirements.md`, plus the files as they sit on disk right now.

**Files in scope and their tier** (`project/surfaces.conf`, which declares `SELF: gated-change`
at line 3 — these are **this repository's own** trust boundaries, not the shipped example, so a
clean or dirty report against them is about real surfaces):

| File | Tier | surfaces.conf rule |
|---|:--:|---|
| `tools/ledger.sh` | **T4** | `:27` — "Routing and evidence — a wrong answer here is silent and confident" |
| `tests/run.sh` | T3 | `:50` — "The suite — if it stops asserting, nothing else here is trustworthy" |
| `core/04-ledger.md` | T1 | `:59` — Reference prose |
| `specs/ledger-token-split/requirements.md` | T0 | no rule matches |

Change tier = **T4** (the max), which is what makes this a hard gate.

**Prior findings inherited** (standing threat model for this file, not re-derived):
`security-reports/2026-08-13-587e8e1.md` (BLOCKING — `--lane` spliced a duplicate JSON key and
flipped `compliance` from FAIL to PASS), `2026-08-13-ledger-injection-fix-round2.md` (MINOR —
`is_uint` accepted `007`), `2026-08-14-cli-input-validation-hardening.md`,
`2026-09-06-r005-computed-default-branch.md`, `2026-09-08-confidence-vocabulary-refusal.md`.
The first of these established the standing rule this review tests against: **a value that
lands in a bare, unquoted JSON position is refused, not escaped** — `json_escape()` cannot
protect a position that has no quotes (`tools/ledger.sh:175-191`).

---

## Threat model — who is untrusted here

`ledger.jsonl` is this repo's **evidence of record**: `compliance` reads it to decide whether a
T4 change may ship, `cmd_report`/`cmd_gates` read it to decide whether a gate is worth its
budget, and `tools/dashboard/app.js` renders it. It is **append-only** (`04-ledger.md`'s
"Keeping it honest" rule forbids backfilling), so a bad record cannot be withdrawn — only
superseded. That is what raises the stakes on any new write path into it.

The untrusted parties, in the order they matter:

1. **A subagent invoking `ledger.sh add` to grade itself or another gate.** This is the normal
   caller. Its argument values are model-generated, sometimes derived from diff or PR text it
   does not control. It is not malicious but it is not trusted to be well-formed either — the
   `--lane` forge in `2026-08-13-587e8e1.md` was found in exactly this caller.
2. **A careless human or script.** `--tokens-in $SOME_VAR`, a pasted figure, a computed
   expression. The gate card names "a confused user" alongside a hostile input for this reason.
3. **A reader of the ledger.** Not a threat, but the party harmed: everything below is about
   whether what they read back is what was written.

**The new surface:** two new CLI flags, `--tokens-in` / `--tokens-out`
(`tools/ledger.sh:409-410`), whose values land in a **bare, unquoted** JSON position —
`,"tokens_in":%s,"tokens_out":%s` (`tools/ledger.sh:621`) — and, critically, whose **sum
replaces the existing `tokens` field** (`tools/ledger.sh:486,492`), which lands in the bare
`"tokens":%s` position of the main template (`tools/ledger.sh:640`). That last part is the
change's novel surface: this is the first value in `cmd_add` that reaches `emit()` **derived**
rather than **as supplied**.

---

## The trust-boundary walk

Setup for everything below: `mktemp -d`, `git init`, a real commit, `export LEDGER=...`, and
`bash tools/ledger.sh` invoked against that scratch ledger. All output pasted is real.

### 1. Can either new value escape its bare JSON position? — **No.**

Thirteen payloads spanning whitespace padding, sign prefixes, floats, hex, scientific notation,
leading zeros, shell metacharacters, command substitution, a JSON brace, a duplicate-key forge
modelled directly on the round-1 `--lane` payload, and an Arabic-Indic digit:

```
[ 5]                   rc=2  REFUSED: --tokens-in ' 5' is not a non-negative integer.
[5 ]                   rc=2  REFUSED: --tokens-in '5 ' is not a non-negative integer.
[+5]                   rc=2  REFUSED: --tokens-in '+5' is not a non-negative integer.
[5.0]                  rc=2  REFUSED: --tokens-in '5.0' is not a non-negative integer.
[0x10]                 rc=2  REFUSED: --tokens-in '0x10' is not a non-negative integer.
[1e3]                  rc=2  REFUSED: --tokens-in '1e3' is not a non-negative integer.
[007]                  rc=2  REFUSED: --tokens-in '007' is not a non-negative integer.
[5;echo hi]            rc=2  REFUSED: --tokens-in '5;echo hi' is not a non-negative integer.
[$(id)]                rc=2  REFUSED: --tokens-in '$(id)' is not a non-negative integer.
[`id`]                 rc=2  REFUSED: --tokens-in '`id`' is not a non-negative integer.
[5}]                   rc=2  REFUSED: --tokens-in '5}' is not a non-negative integer.
[5,"lane":"hotfix]     rc=2  REFUSED: --tokens-in '5,"lane":"hotfix' is not a non-negative integer.
[٥]                    rc=2  REFUSED: --tokens-in '٥' is not a non-negative integer.
file exists after all payloads: NO
```

Every one exits 2 and **the ledger file is never even created** — the refusals fire before
`emit()`. `is_uint` (`tools/ledger.sh:191`) admits only `[0-9]+` with no leading zero, so the
forge class from `2026-08-13-587e8e1.md` is genuinely closed on these two flags. The `007`
refusal confirms the `2026-08-13-ledger-injection-fix-round2.md` MINOR stays closed on the new
flags too, rather than being re-opened by a new entry point.

### 2. Arithmetic-evaluation injection into `$(( ))` — **No.**

`local computed_total=$((tokens_in + tokens_out))` (`tools/ledger.sh:486`) names the variables
*bare* inside an arithmetic context, which is the classic recursive-evaluation sink: bash
re-evaluates a bare name's contents as an arithmetic expression, and `a[$(cmd)]` executes
`cmd`. This is the sharpest vector the change creates. It is closed **only** because
`is_uint` runs first (`:475`, `:478`) — ordering, not escaping, is what saves it:

```
$ ledger.sh add ... --tokens-in 'a[$(touch /tmp/PWNED)]' --tokens-out 5
REFUSED: --tokens-in 'a[$(touch /tmp/PWNED)]' is not a non-negative integer.
$ ls /tmp/PWNED
ls: cannot access '/tmp/PWNED': No such file or directory
```

No execution. Recorded here explicitly so that a future edit reordering those two blocks is
visibly a security change, not a cosmetic one.

### 3. Can the pairing rule be half-satisfied? — **No, in the direction that matters.**

`--tokens-in` alone and `--tokens-out` alone are both refused with exit 2 and nothing written
(`tools/ledger.sh:462-469`), confirmed live and by `tests/run.sh:1753` / `:1760`. A value that
arrives empty (unset shell variable) reads as "not given", so `--tokens-in '' --tokens-out 200`
is correctly refused as one-sided. Both empty is accepted and silently records no split — see
finding 3.

### 4. The derived value: **`tokens` is written unvalidated. This is the finding.**

`is_uint "$tokens"` runs at `tools/ledger.sh:453`. `tokens` is then **overwritten** at
`tools/ledger.sh:492` with `$((tokens_in + tokens_out))` and **never checked again** before it
is spliced into the bare `"tokens":%s` position. Bash arithmetic is 64-bit signed and wraps
silently. Live:

```
$ ledger.sh add --change c4 --gate G7 --tier T4 --outcome fail --confidence fresh --model m \
    --tokens-in 9223372036854775807 --tokens-out 1
logged: G7 (Threat) on c4 — round 1, 0 finding(s), fail
exit=0
```

```json
{"type":"gate", ... "outcome":"fail","confidence":"fresh","challenged_premise":false,
 "minutes":0,"tokens":-9223372036854775808,"lane":"normal","model":"m","note":"",
 "tokens_in":9223372036854775807,"tokens_out":1}
```

Both inputs passed `is_uint`. The written `tokens` is **negative** — a value `ledger.sh`
refuses at its own front door (`--tokens -5` → `REFUSED`, live-confirmed, as is `--tokens-in
-5`). `emit()`'s structural check (`tools/ledger.sh:270-288`) passes it because the line is
still a syntactically valid JSON object, exactly as it passed the round-1 `--lane` forge.
Strict `JSON.parse` accepts it too — it is not malformed, it is **wrong**.

**Where it lands, traced to each consumer:**

- **`cmd_report`'s aggregate (`tools/ledger.sh:1501`)** — `sed -n 's/.*"tokens":\([0-9]*\).*/\1/p'`
  cannot match a `-`, so `\1` captures the empty string and the record contributes **0**. Raw
  extraction over the two-record scratch ledger, `cat -A`:
  ```
  1000$
  $
  ```
  The report shows `tokens spent 1k` — the 9.2-quintillion run is simply gone.
- **The "this figure is a floor" caveat (`tools/ledger.sh:1502`)** — `awk '$1 == 0 {n++}'` over
  that same output returns `untok=0`, so the caveat that exists precisely to say "some runs
  recorded no cost" **does not fire**. Verified: `untok=0`. The record vanishes from the total
  *and* from the disclaimer about the total. This is `surfaces.conf:27`'s stated failure mode
  verbatim — a confident wrong answer, silently.
- **`cmd_gates`' per-gate `avg tokens` (`tools/ledger.sh:1450`)** — same `[0-9]*` sed, same
  silent drop; the scratch run's G7 row reported `avg tokens 1k` across 2 runs.
- **The new split line (`tools/ledger.sh:1516`)** — `[ "$toks_in" -gt 0 ]` receives awk's
  double-precision sum and **errors on the operator's terminal**:
  ```
  /d/work/gated-change/tools/ledger.sh: line 1516: [: 9223372036854775808: integer expected
    tokens in/out      9223372036854776k / 0k   (only runs that recorded the split)
  ```
  Bounded, though: a sum of `900000000000000000 × 3` (2.7e18) prints and compares fine, so this
  symptom needs a total past `INT64_MAX` and is downstream of the same root, not independent.
- **`tools/dashboard/app.js:367`** — `gates.reduce(function(s,g){ return s + (+g.tokens || 0); }, 0)`
  has no `[0-9]*` filter, so unlike the shell readers it *does* ingest the value. Reproduced
  with the dashboard's own coercion:
  ```
  2 OK tokens= -9223372036854776000 in= 9223372036854776000 out= 1
  dashboard-style token sum = -9223372036854775000
  ```
  The project-wide token total goes **negative**, and `tokensPerFinding`
  (`tools/dashboard/app.js:376`) divides it. Two readers of the same field now disagree about
  the same record — one drops it, one takes it — which is worse than either alone.

**Reachability, stated honestly.** Producing this needs a ~19-digit input. No genuine subagent
estimate or human figure looks like that, so the realistic path is a script or a shell variable
carrying a concatenated or computed value, not an attacker choosing it. But the hostile path is
not empty either: a caller that *wants* the cost record to be wrong can now drive the
dashboard's aggregate arbitrarily negative, one record at a time, into a file from which
nothing can be removed.

### 5. Does the split interact with the other optional blocks? — **Clean.**

`tokens_split_json` is appended after `withhold_json` (`tools/ledger.sh:640-645`). Exercised
together with `--withhold-breached true`, a quote-bearing `--note`, and a quote-bearing
`--finding`:

```json
{"type":"gate", ... "findings":1,"finding_details":[{"id":"wb-r1-G7-1","severity":"minor",
 "location":"tools/x.sh:12","claim":"claim with \"quotes\""}], ... "tokens":30,"lane":"normal",
 "model":"m","note":"a \"quoted\" note","withhold_breached":true,"tokens_in":10,"tokens_out":20}
```

Well-formed, one `tokens` key, no duplicates, correct sum. Field order now varies by which
optional blocks fired, but every reader is `sed`/`JSON.parse` keyed by name, so order carries
no meaning. No finding.

### 6. Could a free-text field forge a `"tokens_in":` for `cmd_report`'s new sed? — **No.**

The new extractors (`tools/ledger.sh:1514-1515`) are unanchored `sed` over the whole line, so
the question is whether `--note`/`--model`/a finding claim can plant the literal bytes
`"tokens_in":999`. `json_escape()` (`tools/ledger.sh:313-317`) turns an embedded `"` into `\"`,
so the text becomes `\"tokens_in\":` — the byte after `tokens_in` is a backslash, not the quote
the pattern requires. This is the same mechanism `2026-08-14-cli-input-validation-hardening.md`
verified for the `"note":"` forge against `gate_outcome_has_reason`. Not reproducible.

### 7. Backward compatibility of the widening — **holds.**

A record with no `tokens_in`/`tokens_out` produces no `sed` match and contributes nothing;
`tokens` still carries a total on every line old and new. The mixed-shape claim in
`core/04-ledger.md` (field table row, and the new "The aggregate hides which direction grew"
paragraph) matches observed behavior. Confirmed against a ledger holding both shapes.

### 8. Regression suite

`bash tests/run.sh test_ledger_records_tokens` → 4 passed, `test_ledger_refuses_tokens` → 8
passed, `test_ledger_accepts_tokens` → 1 passed. 13/13, 0 failed, 0 skipped. The suite asserts
what it claims to assert; the gap is that none of it reaches the arithmetic range boundary —
see finding 2.

---

## Findings

### MINOR — the computed `tokens` is written to a bare JSON position without re-validation, and 64-bit overflow makes it negative

`tools/ledger.sh:492` (`tokens=$computed_total`, from `:486`). Every other value in that bare
position is validated immediately before `emit()`; this one is validated at `:453` and then
replaced. Walk and repro in §4 above.

This contradicts the change's own acceptance criterion — `specs/ledger-token-split/requirements.md:36`
states the new values are "validated (non-negative integer) before reaching `emit()`". The two
*supplied* values are. The *derived* value they replace, which sits in the position every
existing reader actually consumes, is not.

**Not rated blocking**, and the reasoning should be visible to the T4 approver: `04-ledger.md`
states in the diff under review that `tokens` is "a leading/budget metric and never an outcome
metric" — it feeds no pass/fail, no `compliance` verdict, no promotion or retirement decision.
That is materially narrower than `2026-08-13-587e8e1.md`'s `--lane` forge, which flipped a gate
verdict from FAIL to PASS. **Not rated info** either: the action required is concrete and
one-line, the record is unwithdrawable once appended, and three consumers disagree about it —
downgrading it because the trigger value looks implausible is the `underfit_when` the card
names ("a finding rated low because fixing it is inconvenient").

**Fix:** re-run the existing guard on the derived value — `is_uint "$computed_total" || REFUSED`
immediately after `:486`, which catches the wrap because a wrapped sum is negative and
`is_uint` already rejects `-`. A range check on the operands (refuse either input above some
sane ceiling) is the alternative and also fixes the `:1516` `integer expected` symptom.

### INFO — no test reaches the arithmetic range boundary

`tests/run.sh:1741-1799`. The six new tests cover pairing, contradiction, redundancy and
non-integer/injection rejection, all with single- to three-digit values
(`tests/run.sh:1745-1748`, `:1790`). Nothing exercises a value large enough to wrap, which is
why finding 1 shipped through a suite the spec calls a discrimination-proven set of 9
assertions. A test asserting that a wrapping pair is refused (or that the written `tokens` is
never negative) would have caught it.

### INFO — a deliberately-recorded `0/0` split is written but never displayed

`tools/ledger.sh:1516` gates the new line on `[ "$toks_in" -gt 0 ] || [ "$toks_out" -gt 0 ]`.
A run logged with `--tokens-in 0 --tokens-out 0` writes `"tokens_in":0,"tokens_out":0`
(verified) but `cmd_report` prints no split line, so "recorded a zero split" and "recorded no
split" are indistinguishable in the report. Cosmetic, no trust-boundary impact; noted because
the `untok` caveat at `:1502` exists to make exactly that distinction for the aggregate.

### Not findings — checked and cleared

- **Missing-value argument underflow.** `--tokens-in` as the final argument dies with
  `line 414: $2: unbound variable`, exit 1, rather than a `REFUSED`. Confirmed **pre-existing
  and identical** for `--tokens` (`line 413`) and every other flag in the same `case`, so it is
  shared existing behavior, not introduced here. Out of scope for this change; not filed
  separately because it is a cosmetic error-message issue with no write path.
- Duplicate-key forgery via the two new flags (§1), arithmetic-eval injection (§2), one-sided
  pairing (§3), interaction with `withhold_breached`/`note`/`finding_details` (§5), free-text
  forgery of the new `sed` extractors (§6), mixed-shape backward compatibility (§7).

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed by this change? | Checked? |
|---|---|---|
| Untrusted CLI argument → bare JSON position in `ledger.jsonl` | **Yes** — two new flags | Yes, `is_uint` (§1) |
| Untrusted CLI argument → bash arithmetic evaluation | **Yes** — new, `$((…))` at `:486` | Yes, ordering (§2) |
| **Derived value → bare JSON position** | **Yes — novel to this change** | **No — finding 1** |
| Untrusted argument → `emit()` structural check | Yes | Passes, but does not catch a valid-JSON wrong number (§4) |
| `ledger.jsonl` → `cmd_report`/`cmd_gates` `grep`/`sed` readers | Yes, two new extractors | Yes (§4, §6) |
| `ledger.jsonl` → `tools/dashboard/app.js` `JSON.parse` | Yes | Yes — disagrees with the shell readers (§4) |
| `ledger.jsonl` → `compliance` verdict path | **No** — `tokens` feeds no verdict | Confirmed, `04-ledger.md` |

**Privilege growth:** none. No new file, network, process or credential reach; `cmd_add` writes
the same single file through the same `emit()`.

---

## Verdict

**G7 · Threat (HARD GATE, T4): FAIL**, round 1.

`passes_when: no unresolved finding above low`. One unresolved **minor** finding
(`tools/ledger.sh:492`) is above low, so the gate does not pass as it stands. This is a
mechanical call on a one-line fix, not a judgment that the change is unsound: the injection and
forgery classes this file's history is built around are genuinely closed on the new flags, the
pairing rule is right, and the widening is backward-compatible. Re-run G7 after the derived
value is validated; per the failure rule the fix returns to Build and re-triggers G5 Proof
(the missing range test) alongside.

Confidence: **fresh** — this session received the diff, the cards, `surfaces.conf` and the
prior reports only. `INTENT-LOG.md`, `SESSION-HANDOFF.md` and the author's stated purpose were
withheld and not read; the unrelated working-tree change on `core/08-models.md` was not opened.
Threat model above was derived from `surfaces.conf` and the diff. The change's purpose was
correctly inferred from the diff before `specs/.../requirements.md` (itself in scope) was read,
and the spec's own acceptance criteria were then used **against** the implementation rather
than as a description of it.

**Premise challenged: yes.** The change's stated design — "`tokens` is computed as their sum,
so every existing reader keeps working unchanged" (`tools/ledger.sh:481-485`,
`core/04-ledger.md:22`) — is the source of the finding, not incidental to it. Making a
previously-supplied field derived moved it outside the validation boundary that the whole file
is organized around, and the spec's claim that the values are validated before `emit()` is true
of the inputs and false of the field that actually reaches it.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `minor` | `tools/ledger.sh:492` | Computed `tokens=$((tokens_in+tokens_out))` is never re-validated before landing in the bare `"tokens":%s` position; 64-bit wrap writes a negative value that `--tokens` itself refuses — `cmd_report`/`cmd_gates` silently drop it (and the "floor" caveat does not fire), `dashboard/app.js:367` sums it negative |
| 2 | `info` | `tests/run.sh:1741` | The six new token-split tests use only 1-3 digit values, so no assertion reaches the arithmetic range boundary that finding 1 exploits |
| 3 | `info` | `tools/ledger.sh:1516` | A run that deliberately records a `0/0` split writes the fields but prints no split line, making "zero split" indistinguishable from "no split" in `cmd_report` |

## Ledger line

```
bash tools/ledger.sh add --change ledger-token-split --gate G7 --tier T4 --round 1 \
  --outcome fail --confidence fresh --challenged true --model opus \
  --tokens-in 78000 --tokens-out 9000 \
  --finding "minor::tools/ledger.sh:492::computed tokens from --tokens-in/--tokens-out is not re-validated before the bare JSON position; 64-bit overflow writes a negative tokens that ledger.sh itself refuses via --tokens, silently dropped by cmd_report/cmd_gates and summed negative by dashboard/app.js:367" \
  --finding "info::tests/run.sh:1741::the six new token-split tests use only 1-3 digit values, so none reaches the arithmetic range boundary finding 1 exploits" \
  --finding "info::tools/ledger.sh:1516::a deliberately-recorded 0/0 split writes tokens_in/tokens_out but prints no split line, making zero-split indistinguishable from no-split in cmd_report"
```

---

## Round 2

**Reviewed:** the **uncommitted working-tree diff on top of `9dd69c4`** — the same base commit
round 1 named, still the tip; no commit exists for this change at review time either. Subject:
`git diff -- tools/ledger.sh core/04-ledger.md tests/run.sh core/cards/
specs/ledger-token-split/requirements.md project/map.md`, plus the files as they sit on disk.
Scope widened since round 1 by `core/cards/*` (T3, `surfaces.conf:50`) and `project/map.md`
(no rule matches) — both one-line additive edits, walked in §5 below. Change tier is still **T4**.

FRESH context: this session received the cards, `02-gates.md`, `surfaces.conf`, the round-1
report and the diff. `INTENT-LOG.md`, `SESSION-HANDOFF.md` and the pending `core/08-models.md`
edit were withheld and not opened.

### What round 2 changes

1. **The round-1 finding's claimed fix** — `is_uint "$computed_total"` at `tools/ledger.sh:512`,
   immediately after `local computed_total=$((tokens_in + tokens_out))` at `:511`.
2. **A new relationship rule, not reviewed by any prior round.** `--tokens` must now be `>=`
   the split, not `==` it (`tools/ledger.sh:515-519`); a greater total is accepted and **kept
   as given** (`:520` assigns the computed sum only when `--tokens` was omitted).
3. **Unknown-subcommand dispatch** (`tools/ledger.sh:1657-1664`): a bare invocation still prints
   the header to stdout; anything else now gets a three-line `REFUSED` on stderr naming `'$1'`.
4. Non-security round-1 fixes from other gates: the split-line gate is now count-based
   (`:1557`), `%.1fk` precision, and the "no --tokens recorded" note is gated on the flag
   rather than the value (`:693`).

---

### 1 · Is the round-1 overflow finding fixed? — **Half of it. The guard is a SIGN check, not an overflow check.**

**The round-1 payload, verbatim, is now refused.** Confirmed live against a scratch ledger in a
throwaway git repo with `LEDGER=` exported — never the repo ledger:

```
$ ledger.sh add --change c --gate G7 --tier T4 --outcome fail --confidence fresh --model m \
    --tokens-in 9223372036854775807 --tokens-out 1
REFUSED: --tokens-in + --tokens-out overflowed to '-9223372036854775808'.
  Nothing was written to .../ledger.jsonl.
exit=2      ledger file created: NO
```

Both operands at `INT64_MAX` likewise refuse (`overflowed to '-2'`). Within the space round 1
actually probed, the fix holds and nothing is written.

**It does not hold one step out.** `is_uint` rejects a leading `-`, so `:512` catches exactly
those sums that wrap into `[2^63, 2^64)`. Bash 5.3 wraps an out-of-range *decimal constant*
modulo 2^64 rather than saturating — verified directly:

```
a=18446744073709551617; echo $((a+0))   ->  1          # 2^64 + 1
a=18446744073709551616; echo $((a+0))   ->  0          # 2^64
a=100000000000000000000; echo $((a+0))  ->  7766279631452241920
```

`is_uint` only checks digits, so an operand at or above 2^64 passes it, wraps to a **positive**
sum, and that sum passes `:512` and is written:

```
$ ledger.sh add ... --tokens-in 18446744073709551617 --tokens-out 1
logged: G7 (Threat) on c — round 1, 0 finding(s), fail
exit=0
```

```json
{"type":"gate", ... "tokens":2,"lane":"normal","model":"m","note":"",
 "tokens_in":18446744073709551617,"tokens_out":1}
```

`tokens` is `2`. The record claims a run that consumed 18.4 quintillion input tokens cost two
tokens in total.

**Reachability is better than round 1's, not worse.** Round 1 conceded its trigger needed a
19-digit `INT64_MAX`, a value nobody types by accident. This one needs any value at or above
2^64, and **a 20-digit value is what a shell concatenation accident produces** —
`--tokens-in "$a$b"` with two 10-digit figures. Because the wrap is mod 2^64, roughly half of
such values land in a positive residue and are silently accepted; the other half land negative
and are correctly refused. Measured across plausible 20-digit inputs:

```
12345678901234567890     wraps to -6101065172474983726   refused
18446744073709551700     wraps to 84                     ACCEPTED -> "tokens":84
20000000000000000000     wraps to 1553255926290448384    ACCEPTED -> "tokens":1553255926290448384
25000000000000000000     wraps to 6553255926290448384    ACCEPTED -> "tokens":6553255926290448384
30000000000000000000     wraps to -6893488147419103232   refused
99999999999999999999     wraps to 7766279631452241919    ACCEPTED -> "tokens":7766279631452241919
```

A guard that refuses a typo half the time and fabricates a 19-digit cost figure the other half
is the `surfaces.conf:27` failure mode — "a wrong answer here is silent and confident" — applied
to the very check added to prevent it. The code comment at `:504-510` and the refusal string at
`:513` both call this an overflow check; it detects one of the two residue classes.

**Harm, traced — materially smaller than round 1's.** The round-1 damage is genuinely gone:

| Round-1 symptom | Round 2 |
|---|---|
| `tokens` written **negative** | Gone — `:512` refuses every negative wrap |
| `cmd_report`/`cmd_gates` silently **drop** the record (`[0-9]*` sed cannot match `-`) | Gone — the value is positive and counts |
| `untok` "the figure is a floor" caveat fails to fire | Gone |
| `dashboard/app.js:367` sums the project total **negative** | Gone — verified `totalTokens = 1002` on a two-record ledger holding the wrapped line |
| `:1516` `[: …: integer expected` on the split line | Gone — `:1557` now gates on a **count** of lines carrying the key, not on the summed value |

What remains is a record that is **internally inconsistent and unreconcilable in the report**:

```
  tokens spent       1.0k   (budget metric, not an outcome one)
  tokens in/out      18446744073709552.0k / 0.2k   (2 run(s) recorded the split)
```

A total of 1.0k printed directly above a split of 18.4 quintillion, with nothing warning that
they cannot both be true. No reader disagrees about a *field* any more; every reader agrees,
and what they agree on is false.

**Secondary consequence — the round-2 `>=` rule is violable through the same wrap.** `:515`
compares `$tokens` against the already-wrapped `$computed_total`, so the invariant it exists to
enforce can be broken by satisfying it:

```
$ ledger.sh add ... --tokens 2 --tokens-in 18446744073709551617 --tokens-out 1
logged: ...  exit=0      -> "tokens":2,"tokens_in":18446744073709551617,"tokens_out":1
```

The written record has a total smaller than its own split — precisely what `:517` calls
impossible ("The total cannot be smaller than the split that makes it up"). And the refusal
message, when it does fire on this input, prints arithmetic that is simply false to the human
deciding whether their number was wrong:

```
$ ledger.sh add ... --tokens 1 --tokens-in 18446744073709551617 --tokens-out 1
REFUSED: --tokens 1 is less than --tokens-in 18446744073709551617 + --tokens-out 1 (=2).
```

**Fix.** `is_uint` on the sum cannot detect a wrap, because after the wrap there is nothing left
to detect. Bound the **operands** before the addition — a length or ceiling check on
`tokens_in`/`tokens_out` (19 digits, or a documented sane maximum), refused with the same
`REFUSED` shape — or do the addition and the comparison in `awk`, which is not 64-bit-bound.
A ceiling on the operands also removes the `:515` symptom in §3 below.

### 2 · The new `>=` relationship rule — **posture is neutral-to-better; the documentation of it is wrong**

Evaluated on its own merits; this rule has not been threat-reviewed before.

**Is the relaxation itself a weakening?** No. Under the old `==` rule the split acted as a
checksum on `tokens`: a caller could not claim a large total alongside a modest split. But
`--tokens N` **alone** was, and still is, an unconstrained self-reported figure — a caller who
wants a wrong total never had to involve the split at all. The relaxation therefore removes no
control that was load-bearing, and it removes a false-refusal path: a truthful caller whose
billed total legitimately exceeds in+out (cache-read/cache-creation tokens, which this kit's own
subagent gates incur every run) previously had to either lie or omit the split. Refusing honest
input is how a check gets bypassed rather than satisfied.

**Does any consumer derive a value from the relationship?** No. Checked all four:
`cmd_report:1533` sums `tokens`; `cmd_report:1558-1559` sums `tokens_in`/`tokens_out`
**independently**; `cmd_gates:1450` reads only `tokens`; `tools/dashboard/app.js:367,376,2449`
reads only `tokens` — `grep -n tokens tools/dashboard/app.js` returns **no reference to
`tokens_in`/`tokens_out` at all**. Nothing computes `tokens - (in + out)`, so nothing can be
driven negative by the widened gap. **`cmd_compliance` contains no reference to `tokens`** —
confirmed by extracting the whole function and grepping it — so `tokens` still feeds no verdict,
exactly as round 1 established. **No privilege growth, no new derivation path.**

**But the two documents that define the rule now describe the old one.** Both are in this diff:

- `core/04-ledger.md:22` (the normative field table): *"When given, `tokens` is computed as
  their sum"* — false whenever `--tokens` is also given and greater.
- `specs/ledger-token-split/requirements.md:29`: *"An explicit `--tokens` that **disagrees**
  with `--tokens-in + --tokens-out` is refused as a contradiction"* — with the acceptance box
  ticked `[x]`, while `tools/ledger.sh:515` refuses only a *smaller* total and
  `tests/run.sh:1810` (`test_ledger_accepts_and_keeps_tokens_greater_than_the_split`) asserts a
  greater one is kept as given. `requirements.md:26` carries the same stale "computed as their
  sum" claim.

Only `tools/ledger.sh:54-63` (the header) states the rule correctly. `04-ledger.md` is the
document a downstream consumer author reads before writing token math against this ledger, and
`tokens == tokens_in + tokens_out` is exactly the sort of invariant someone builds a
reconciliation or a cache-token derivation on. Filed as `info` rather than `minor`: no trust
boundary is crossed by the prose itself, and correctness of ticked acceptance criteria is G1's
and G6's territory, not this gate's. Noted here because the invariant it advertises is an
integrity property, and §1 shows the code cannot actually guarantee it in either direction.

### 3 · The `>=` comparison as a sink — **no bypass; one stderr leak with a success exit**

`[ "$tokens" -lt "$computed_total" ]` (`:515`) is `test`, not `$(( ))`, so it performs no
recursive arithmetic evaluation and is not the `a[$(cmd)]` sink `$(( ))` is. Bash's `test`
errors on an operand outside `int64`:

```
$ ledger.sh add ... --tokens 99999999999999999999 --tokens-in 1 --tokens-out 1
/d/work/gated-change/tools/ledger.sh: line 515: [: 99999999999999999999: integer expected
logged: G7 (Threat) on c — round 1, 0 finding(s), fail
exit=0      -> "tokens":99999999999999999999,"tokens_in":1,"tokens_out":1
```

**Not a bypass.** For the guard to wrongly *accept*, we would need `tokens < computed_total` with
the comparison failing. `computed_total` is always in `[0, 2^63)` after `:512`, so it never
errors; only `$tokens` can, and only when `$tokens` is at or above 2^63 — a case where the
guard's verdict (accept) is the correct one anyway. Traced over both operands' ranges; there is
no input where a genuinely-too-small total slips through. A 20-digit `--tokens` was already
accepted before this change (`is_uint` permits any digit string), so the written value is not
new. What **is** new is a shell error on stderr accompanying a `logged:` success and `exit=0` —
noise on the T4 surface, resolved by the same operand ceiling §1 asks for. Not filed separately;
same root, same one-line fix.

### 4 · Unknown-subcommand dispatch — **no injection. One new reflection surface.**

`*) echo "REFUSED: unknown subcommand '$1'." >&2` (`tools/ledger.sh:1661`). The interpolated
`'$1'` is inside a double-quoted string passed to the **`echo` builtin**, so there is no word
splitting, no pathname expansion, no second round of expansion, and no format string.
`grep -n 'shopt\|xpg_echo' tools/ledger.sh` returns nothing, so `echo` does not interpret
backslash escapes either. Sixteen payloads, run live, every one inert:

```
[ad]                       rc=2 | REFUSED: unknown subcommand 'ad'.
[$(touch PWNED_SUB)]       rc=2 | REFUSED: unknown subcommand '$(touch PWNED_SUB)'.
[`touch PWNED_BT`]         rc=2 | REFUSED: unknown subcommand '`touch PWNED_BT`'.
[*]                        rc=2 | REFUSED: unknown subcommand '*'.
[../../etc/passwd]         rc=2 | REFUSED: unknown subcommand '../../etc/passwd'.
[-e]  [-n]  [-E]  [--]     rc=2 | reflected literally, not consumed as echo options
[\ttab\nnewline]           rc=2 | reflected literally — no backslash interpretation
[add; rm -rf /]            rc=2 | REFUSED: unknown subcommand 'add; rm -rf /'.
[%s%s%s] [%n] [%1000000d]  rc=2 | reflected literally — echo, not printf
[8000-byte A-run]          rc=2 | reflected, no truncation fault
PWNED files present: none
```

No file created, no command run, exit 2 every time, nothing written to any ledger.

**The `--ledger` interaction, which the new `*)` arm could plausibly have broken, does not
break.** `--ledger <path>` is stripped from the argument list *before* the `case`
(`tools/ledger.sh:151-164`), so `ledger.sh --ledger path add …` still reaches `add`, not the
refusal — verified live in both flag positions (2 records written to the alternate path).
`ledger.sh --ledger path` with no subcommand collapses to `set --` and hits the `""` arm, still
printing the header to stdout with an empty stderr. Verified.

**What is new:** `$1` is now echoed at all. Previously the `*)` arm printed the file's own header
and never reflected the argument. Arbitrary caller bytes, including ANSI and control sequences,
now reach the operator's terminal unfiltered:

```
$ ledger.sh "$(printf 'X\033[31mRED\033[0m\007')"
REFUSED: unknown subcommand 'X^[[31mRED^[[0m^G'.   (shown through cat -v; raw, the terminal renders it)
```

Impact today is genuinely small, and the reason is worth stating rather than asserting: the only
party who supplies `$1` is whoever types the command, in their own terminal. `grep -rn
'ledger\.sh'` across `tools/`, `templates/` and the hooks finds **no caller that passes a
variable as the subcommand** — `tools/dashboard.sh:57` stores the path and every invocation uses
a literal (`add`, `report`, `compliance`). So there is no path by which a hostile value reaches
this `echo`. Filed `info` so that a future change which does route an untrusted name into this
dispatch is visibly a security change rather than a refactor.

### 5 · The newly-in-scope files — **clean**

`core/cards/G1..G8` (T3, `surfaces.conf:50` — "every tool parses these") each gain one line to
`logs_with:`. The parsers are `tools/lib/matrix.sh` and `tools/dashboard.sh`, which read the
router table and card **metadata**, not the `logs_with:` prose; the added line sits inside the
existing YAML block and introduces no new key, no new regex anchor, and nothing a card reader
dispatches on. `project/map.md` gains one data-inventory row correctly stating the split lives in
`ledger.jsonl`, leaves the process only via a published `dashboard.html`, and is not personal —
accurate against the code. No finding.

### 6 · Round-1 classes re-verified at this diff — **all still closed**

Re-run rather than assumed, because `cmd_add`'s validation block was restructured:

- **Bare-JSON escape / duplicate-key forgery on the two new flags.** `5,"lane":"hotfix`, `5}`,
  `007`, `-5`, `+5`, `0x10`, `' 5'` — all `REFUSED`, ledger file never created.
- **Arithmetic-evaluation injection into `$(( ))` at `:511`.** `a[$(touch PWNED_ARITH)]`,
  `1,x=$(touch PWNED2)`, `$(touch PWNED3)`, `x[0]` — all refused by `is_uint` *before* the
  arithmetic context. `ls PWNED*` → none. Ordering, not escaping, is still what saves this.
- **Free-text forgery of the new report extractors — including the new unfiltered `split_runs`
  counter** (`:1557`, `grep -c '"tokens_in"'` over the *whole* file, not just `"type":"gate"`
  lines). A `--note` containing `"tokens_in":999999`, a `--model` of
  `m","tokens_in":888888,"x":"`, and an `escape` record whose note is `"tokens_in":777777` were
  all written; `json_escape` turned each embedded `"` into `\"`, so `grep -c` counted **1** (the
  one genuine split line) and the sed extractor pulled **100**, the true value. Report line
  correct: `tokens in/out 0.1k / 0.1k (1 run(s) recorded the split)`.

### 7 · Round-1 findings 2 and 3

- **Finding 3 (info, `0/0` split invisible) — RESOLVED.** `:1557` now gates on the count of lines
  carrying the key. Live: `--tokens-in 0 --tokens-out 0` → `tokens in/out 0.0k / 0.0k (1 run(s)
  recorded the split)`.
- **Finding 2 (info, no test reaches the range boundary) — PARTIALLY resolved, re-filed.**
  `tests/run.sh:1825` (`test_ledger_refuses_tokens_in_out_that_overflow_the_sum`) reaches the
  boundary, but asserts only `INT64_MAX + 1` — the negative-wrap half. It passes against a guard
  that merely rejects a leading `-`, which is what shipped, and would not have caught §1. A test
  is discrimination-proven only against the wrong implementations it can distinguish.

### 8 · Regression suite

All fifteen new/changed token-split and dispatch tests run individually: **37 assertions passed,
0 failed, 0 skipped** — including `test_ledger_refuses_tokens_in_out_that_overflow_the_sum`,
`test_ledger_accepts_and_keeps_tokens_greater_than_the_split`,
`test_ledger_unknown_subcommand_gives_a_short_stderr_refusal` and
`test_ledger_bare_invocation_still_prints_the_header`. The suite asserts what it claims to; §7
states the one place its discrimination is short.

---

## Round 2 findings

### MINOR — `is_uint "$computed_total"` is a sign check, not an overflow check; an operand at or above 2^64 wraps positive and is written

`tools/ledger.sh:511-514`. The round-1 payload is now correctly refused, but bash wraps modulo
2^64, so any 20+ digit operand — what a shell concatenation accident produces — has roughly even
odds of wrapping into a positive residue that passes `is_uint` and lands in the bare
`"tokens":%s` position. Repro and consumer trace in §1. Consequence: the round-2 `>=` invariant
at `:515-519` is violable by satisfying it (`--tokens 2` accepted against a split of 1.8e19),
and the refusal message at `:516` prints arithmetic that is false. Fix: bound the **operands**
before the addition, or compare in `awk`. Rated `minor` on the same reasoning round 1 used —
`tokens` feeds no verdict (`cmd_compliance` re-confirmed clean), so this is not `blocking`; but
the record is append-only and unwithdrawable, the fix is one line, and the trigger is *more*
reachable than round 1's, so it is not `info`.

### INFO — `04-ledger.md` and the spec still document the `==` rule the code replaced with `>=`

`core/04-ledger.md:22` ("When given, `tokens` is computed as their sum") and
`specs/ledger-token-split/requirements.md:29` ("An explicit `--tokens` that disagrees … is
refused as a contradiction", box ticked) both describe the pre-round-2 behavior, contradicted by
`tools/ledger.sh:515` and `tests/run.sh:1810`. §2. No trust boundary crossed; filed because
`04-ledger.md` is the schema document a downstream token-math author reads.

### INFO — the unknown-subcommand refusal reflects arbitrary caller bytes to stderr

`tools/ledger.sh:1661`. No injection of any kind (sixteen payloads, §4), but `$1` is echoed where
it previously was not, so ANSI/control sequences reach the terminal unfiltered. No repo caller
passes a variable subcommand, so it is unreachable by a hostile party today; filed so that
changing that is visibly a security change.

### INFO — the new overflow test asserts only the negative-wrap half of the boundary

`tests/run.sh:1825`. Passes against a guard that only rejects a leading `-`, which is what
shipped; would not have caught finding 1. §7.

### Not findings — checked and cleared

- The `>=` relaxation itself: no control removed, no consumer derives a value from the
  relationship, `cmd_compliance` does not read `tokens`, no privilege growth (§2).
- `[ … -lt … ]` as a sink: no recursive arithmetic evaluation, no acceptance bypass in any
  operand range; the `integer expected` stderr leak is the same root as finding 1 (§3).
- `--ledger` still strips before dispatch, so the new `*)` arm breaks no existing invocation (§4).
- Card and `project/map.md` additions: no parser reads the changed lines (§5).
- Duplicate-key forgery, `$(( ))` injection, free-text forgery of the new extractors **and** of
  the new unfiltered `split_runs` counter (§6).
- Round-1 finding 3, resolved (§7).

---

## Round 2 T4 boundary check

| Boundary (surfaces.conf) | Crossed? | Checked? |
|---|---|---|
| Untrusted CLI argument → bare JSON position | Yes | Yes — `is_uint`, all payloads refused (§6) |
| Untrusted CLI argument → bash arithmetic evaluation | Yes | Yes — ordering still saves it (§6) |
| **Derived value → bare JSON position** | **Yes** | **Partly — negative wrap closed, positive wrap open (§1)** |
| **Derived value → the new `>=` invariant check** | **Yes — novel to round 2** | **No — the check reads the wrapped value (§1)** |
| Untrusted CLI argument → `echo` on stderr (dispatch) | **Yes — novel to round 2** | Yes — no injection; reflection only (§4) |
| `ledger.jsonl` → `cmd_report`/`cmd_gates` readers | Yes | Yes (§1, §6) |
| `ledger.jsonl` → `dashboard/app.js` | Yes | Yes — reads `tokens` only, no longer goes negative (§1, §2) |
| `ledger.jsonl` → `compliance` verdict path | **No** — `cmd_compliance` has no `tokens` reference | Confirmed by extraction (§2) |
| `core/cards/*` → card parsers (`lib/matrix.sh`, `dashboard.sh`) | Yes | Yes — `logs_with:` prose is not dispatched on (§5) |

**Privilege growth:** none. No new file, network, process or credential reach.

---

## Round 2 verdict

**G7 · Threat (HARD GATE, T4): FAIL**, round 2.

`passes_when: no unresolved finding above low`. One unresolved **minor**
(`tools/ledger.sh:511-514`) is above low.

This is a narrower failure than round 1 and the report should not be read as "nothing improved."
The fix is real: the exact payload round 1 filed is refused, and every downstream harm round 1
traced — a negative `tokens`, two readers disagreeing about one field, the dashboard total going
negative, the "floor" caveat failing to fire, the `integer expected` crash on the split line — is
gone, verified individually. What failed is the *shape* of the guard: `is_uint` on a value that
has already wrapped can only see the sign, and round 1's own suggested fix ("a wrapped sum is
negative and `is_uint` already rejects `-`") was true only for operands inside `int64` and was
implemented verbatim. The residual is fixed by bounding the operands, not the sum.

Per the failure rule: back to Build, then re-run G7 and G5 (the boundary test in §7 needs the
positive-wrap case). **Two consecutive failures of the same gate on one change → escalate the
tier by one** (`02-gates.md`, failure rule 4); this change is already T4, the ceiling, so the
mechanical consequence is the T4 approver seeing both rounds — which is what `escalate_to: T4
approver. NEVER the author alone` requires anyway.

Confidence: **fresh**.

**Premise challenged: yes.** Twice. The change's own claim — `tools/ledger.sh:504-510`, "so it
gets the same is_uint check every other such value gets" — is the source of finding 1: the same
check is not the same protection, because every *other* value is checked before anything
transforms it, and this one is checked after the transformation that destroys the evidence. And
the round-2 design change was not accepted on its stated rationale: §2 tests the `>=` relaxation
against each consumer independently and clears it on evidence, while finding 2 records that the
two documents defining the rule still describe the rule it replaced.

---

## Round 2 structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `minor` | `tools/ledger.sh:511` | `is_uint "$computed_total"` catches only sums wrapping into `[2^63,2^64)`; bash wraps mod 2^64, so an operand at or above 2^64 (a 20-digit concatenation accident, ~50% of them) wraps positive, passes, and writes a fabricated `tokens` — and makes the new `>=` invariant violable by satisfying it |
| 2 | `info` | `core/04-ledger.md:22` | The field table and `specs/ledger-token-split/requirements.md:29` still document the `==` rule ("computed as their sum" / "disagrees … is refused"), contradicted by `tools/ledger.sh:515` and `tests/run.sh:1810` |
| 3 | `info` | `tools/ledger.sh:1661` | The new unknown-subcommand refusal reflects `$1` verbatim to stderr — no injection, but ANSI/control bytes now reach the terminal where previously the argument was never echoed |
| 4 | `info` | `tests/run.sh:1825` | The new overflow test asserts only `INT64_MAX + 1`, so it passes against a guard that merely rejects a leading `-` and would not have caught finding 1 |

## Round 2 ledger line

```
bash tools/ledger.sh add --change ledger-token-split --gate G7 --tier T4 --round 2 \
  --outcome fail --confidence fresh --challenged true --model opus \
  --tokens-in 112000 --tokens-out 14000 \
  --finding "minor::tools/ledger.sh:511::is_uint on computed_total is a sign check not an overflow check; bash wraps mod 2^64 so an operand at or above 2^64 wraps positive, passes, and writes a fabricated tokens, and the new >= invariant at :515 compares against the wrapped value so it can be violated by satisfying it" \
  --finding "info::core/04-ledger.md:22::the field table and specs/ledger-token-split/requirements.md:29 still document the == rule (computed as their sum / disagrees is refused), contradicted by tools/ledger.sh:515 and tests/run.sh:1810" \
  --finding "info::tools/ledger.sh:1661::the new unknown-subcommand refusal echoes the subcommand verbatim to stderr - no injection across 16 payloads, but ANSI/control bytes now reach the terminal where the argument was previously never reflected" \
  --finding "info::tests/run.sh:1825::the new overflow test asserts only INT64_MAX+1, so it passes against a guard that merely rejects a leading minus sign and would not have caught round-2 finding 1"
```

---

## Round 3

**Reviewed:** the **uncommitted working-tree diff on top of `9dd69c4`** ("LEARNINGS.md: remove the
committed NUL byte at offset 100775") — the same base commit rounds 1 and 2 named, still the tip
(`git rev-parse HEAD` → `9dd69c40719c03868f2cce6f7608852a075790b0`); no commit exists for this
change at review time either. Subject: `git diff -- tools/ledger.sh core/04-ledger.md tests/run.sh
core/cards/ specs/ledger-token-split/requirements.md project/map.md`, plus the files as they sit on
disk. Scope unchanged from round 2. Change tier is still **T4** (`tools/ledger.sh`,
`project/surfaces.conf:27` — "Routing and evidence — a wrong answer here is silent and confident").

FRESH context: this session received the cards, `02-gates.md`, `surfaces.conf`, this report's
rounds 1 and 2, and the diff. `INTENT-LOG.md`, `SESSION-HANDOFF.md` and the pending, unrelated
`core/08-models.md` edit were withheld and not opened.

All output below is real, produced against throwaway ledgers in a scratch `git init` repo with
`LEDGER=` pointed at them — never `D:/work/gated-change/ledger.jsonl`. Bash 5.3.9,
GNU Awk 5.4.0.

### What round 3 changes

`is_uint_bounded()` (`tools/ledger.sh:216`) — `is_uint` plus `[ "${#1}" -le 15 ]` — applied at
`:481` (`--tokens`), `:516` (`--tokens-in`) and `:519` (`--tokens-out`), all **before** the
`$((tokens_in + tokens_out))` at `:543` and the `[ "$tokens" -lt "$computed_total" ]` at `:547`.
The `is_uint "$computed_total"` from round 2 stays at `:544`, demoted by its own comment
(`:538-542`) to "defense in depth … not the thing doing the work."

---

### 1 · Is the round-2 finding fixed? — **Yes, and the bound is airtight on the write path.**

**The exact round-2 payload and every neighbour of it is refused, nothing written:**

```
in=2^64+1 out=1                 rc=2 NOTHING-WRITTEN | REFUSED: --tokens-in '18446744073709551617' is not a non-negative integer of a plausible size.
in=2^64 out=1                   rc=2 NOTHING-WRITTEN | REFUSED: --tokens-in '18446744073709551616' …
in=INT64_MAX out=1              rc=2 NOTHING-WRITTEN | REFUSED: --tokens-in '9223372036854775807' …
in=99999999999999999999 out=1   rc=2 NOTHING-WRITTEN | REFUSED …
in=20000000000000000000 out=1   rc=2 NOTHING-WRITTEN | REFUSED …
in=18446744073709551700 out=1   rc=2 NOTHING-WRITTEN | REFUSED …
```

The last three are the values round 2 measured as landing in a **positive** residue and being
silently accepted (`"tokens":1553255926290448384`, `"tokens":84`, `"tokens":7766279631452241919`).
All six now exit 2 and the ledger file is never created.

**The 15/16-digit boundary is exact, on all three flags, in both directions:**

```
in=999999999999999 out=999999999999999   rc=0 WRITTEN "tokens":1999999999999998
in=1000000000000000 out=1                rc=2 NOTHING-WRITTEN | REFUSED: --tokens-in '1000000000000000' …
in=1 out=1000000000000000                rc=2 NOTHING-WRITTEN | REFUSED: --tokens-out '1000000000000000' …
in=0000000000000001 out=1                rc=2 NOTHING-WRITTEN   (16 chars; is_uint's leading-zero rule also rejects it)
--tokens 999999999999999  (no split)     rc=0 WRITTEN "tokens":999999999999999
--tokens 1000000000000000 (no split)     rc=2 NOTHING-WRITTEN | REFUSED: --tokens '1000000000000000' …
```

Note the zero-padding probe: `${#1}` is a **character** count, so a 16-character value is refused
on length even where the numeric value is 1 — and `is_uint`'s own `0*) [ "$1" = 0 ]` arm refuses it
first anyway. There is no padding bypass.

**`--tokens` at extreme magnitude — the round-2 §3 bypass route — is closed.** Round 2 found a
20-digit `--tokens` producing `[: 99999999999999999999: integer expected` on stderr *alongside*
`logged:` and `exit=0`, writing the record. Now:

```
--tokens 99999999999999999999 + split    rc=2 NOTHING-WRITTEN | REFUSED: --tokens '99999999999999999999' is not a non-negative integer of a plausible size.
--tokens 9223372036854775807  + split    rc=2 NOTHING-WRITTEN | REFUSED …
--tokens 2 --tokens-in 18446744073709551617 --tokens-out 1   rc=2 NOTHING-WRITTEN
--tokens 1 --tokens-in 18446744073709551617 --tokens-out 1   rc=2 NOTHING-WRITTEN
```

The `-lt` at `:547` now receives two operands that are each provably in `[0, 10^15)`, so it can
neither error nor compare a wrapped value. Round 2's "a `--tokens` smaller than the REAL split was
accepted" is gone — the payload dies two checks earlier, at `:516`.

**Can `computed_total` be steered near 2^63 or 2^64 from below the cap? — No, and not close.**
This is the load-bearing claim and it is arithmetic, not a sampling result. `computed_total` has
exactly two addends (`:543`), repeated flags overwrite rather than accumulate (`:439-440` are plain
assignments), and nothing else in `cmd_add` adds to `tokens`. So the maximum reachable sum is
`2 × (10^15 − 1)`:

```
max computed_total = 1999999999999998
2^53               = 9007199254740992      (JS exact below this)
2^63               = 9223372036854775808
headroom factor to 2^63 = 4611.7
```

The worst case is **4,611× below** the signed wrap point and — worth stating because
`dashboard/app.js` is a `JSON.parse` consumer — also **below 2^53**, so a single record is still an
exact IEEE-754 double. Live confirmation of the maximum, and that `--tokens` cannot be pushed under
it:

```
in=999999999999999 out=999999999999999   rc=0 WRITTEN "tokens":1999999999999998
--tokens 999999999999999 + that split    rc=2 REFUSED: --tokens 999999999999999 is less than --tokens-in 999999999999999 + --tokens-out 999999999999999 (=1999999999999998).
--tokens 0               + that split    rc=2 REFUSED: … (=1999999999999998).
```

The refusal message now prints arithmetic that is **true** — round 2's "`(=2)`" against a 1.8e19
split is gone.

A consequence the change should own: with both operands capped, `is_uint "$computed_total"` at
`:544` can never fail. It is a **dead branch**. The code comment at `:538-542` concedes this
("defense in depth … not the thing doing the work"), which is the honest framing; §4 below notes
the one place that honesty leaves a gap.

**Verdict on the bound itself: airtight on the write path.** I could not construct any input to
`cmd_add` that reaches bash arithmetic or a numeric test with an operand outside `int64`.

### 2 · Round-1 and round-2 classes, re-verified at this diff — **all still closed**

Re-run rather than assumed, because `cmd_add`'s validation block was restructured again.

**Shape / bare-JSON escape / duplicate-key forgery on the two new flags** — nineteen payloads,
every one `rc=2` with the ledger file never created:

```
[ 5] [5 ] [+5] [-5] [5.0] [0x10] [1e3] [007] [5;echo hi] [$(id)] [backtick id] [5}]
[5,"lane":"hotfix] [٥] [a[$(touch PWNED_ARITH)]] [1,x=$(touch PWNED2)] []
[9223372036854775807] [18446744073709551617]
PWNED files: none
```

`007` still refused (the `2026-08-13-ledger-injection-fix-round2.md` MINOR stays closed on the new
flags), `5,"lane":"hotfix` still refused (the `2026-08-13-587e8e1.md` BLOCKING forge class stays
closed), and **arithmetic-evaluation injection into `$(( ))` at `:543` is still closed by ordering,
not escaping** — `a[$(touch PWNED_ARITH)]` dies at `:516` before the arithmetic context exists.
Recorded again so a future reorder of `:516-519` past `:543` remains visibly a security change.

**Free-text forgery of the report extractors, including the unfiltered `split_runs` counter**
(`:1595`, `grep -c '"tokens_in"'` over the *whole* file, not just `"type":"gate"` lines). A
`--note` of `"tokens_in":999999 "tokens_out":999999`, a `--model` of `m","tokens_in":888888,"x":"`,
and an `escape` record whose note is `"tokens_in":777777` were all written; `json_escape`
(`:313-317`) turned each embedded `"` into `\"`:

```
grep -c tokens_in => 1        (only the one genuine split line)
  tokens spent       0.1k
  tokens in/out      0.1k / 0.1k   (1 run(s) recorded the split)
```

Correct on both the count and the sums. Not reproducible.

**Subcommand-dispatch injection (`:1699`)** — fourteen payloads, all inert, `rc=2`, nothing written:

```
rc=2 | REFUSED: unknown subcommand 'ad'.
rc=2 | REFUSED: unknown subcommand '$(touch PWNED_SUB)'.
rc=2 | REFUSED: unknown subcommand '`touch PWNED_BT`'.
rc=2 | REFUSED: unknown subcommand '*'.
rc=2 | REFUSED: unknown subcommand '../../etc/passwd'.
rc=2 | REFUSED: unknown subcommand '-e'. / '-n'. / '-E'. / '--'.      (not consumed as echo options)
rc=2 | REFUSED: unknown subcommand 'a\tb\nc'.                          (no backslash interpretation)
rc=2 | REFUSED: unknown subcommand 'add; rm -rf /'.
rc=2 | REFUSED: unknown subcommand '%s%s%s'. / '%n'.                   (echo, not printf)
rc=2 | REFUSED: unknown subcommand 'X^[[31mRED^[[0m^G'.                (through cat -v)
PWNED files: none
```

The ANSI/control reflection round 2 filed as `info` is unchanged and still present — re-filed below
as round-3 finding 4. The `--ledger` interaction still holds: `ledger.sh --ledger <path> add …`
reaches `add` (1 record written to the alternate path), and `ledger.sh --ledger <path>` with no
subcommand prints the header to stdout with **0 bytes on stderr**.

### 3 · The cap is per-record, not per-ledger — **the `integer expected` symptom is relocated, not eliminated**

The change's claim (`tools/ledger.sh:210-215`, `specs/…/requirements.md:46-50`) is that 15 digits
keeps "the SUM of two such values … nowhere near 2^63, so **nothing downstream** can wrap." The
first clause is true (§1). The second is scoped to one record. `cmd_report` sums `tokens` across the
**whole ledger** (`:1567`) and then applies a shell numeric test to awk's output at `:1569`, with no
bound anywhere in that path. Synthetic ledgers whose lines are byte-identical in shape to what
`ledger.sh` itself wrote in §1 (`"tokens":1999999999999998`):

```
=== 4611 max-legal records ===
  tokens spent       9221999999999998.0k   (budget metric, not an outcome one)
  tokens in/out      4610999999999999.0k / 4610999999999999.0k   (4611 run(s) recorded the split)

=== 4612 max-legal records ===
tools/ledger.sh: line 1569: [: 9223999999999997952: integer expected
  tokens spent       not recorded. Pass --tokens N; an unmeasured cost is the
  tokens in/out      4611999999999999.0k / 4611999999999999.0k   (4612 run(s) recorded the split)
```

At 4,612 records the aggregate crosses `INT64_MAX`, `[ "$toks" -gt 0 ]` errors, and the `else`
branch prints **"tokens spent not recorded. Pass --tokens N"** directly above a split line reporting
4.6 quadrillion tokens. That is `surfaces.conf:27`'s failure mode again — a confident wrong answer —
but at a trigger cost round 2's did not have.

`gawk` itself neither helps nor hurts here: it prints the full integer form rather than scientific
notation at every magnitude tested (`1e15` … `1e30`), so the break is purely the shell `test`.

The same aggregate reaches `dashboard/app.js:367` (`gates.reduce(… + (+g.tokens || 0) …)`), which
has no `[0-9]*` filter and does not error — it silently loses IEEE-754 precision much earlier. At
the repo ledger's current line count of 277, all max-legal:

```
single record exact in JS Number? true    (2^53 = 9007199254740991)
277 such records sum = 553999999999999940  safe? false
```

**Reachability, stated honestly.** The repo ledger today is 277 lines with a maximum `tokens` of
`200000` (6 digits); real subagent figures are ~10^5. Reaching 9.22e18 needs either 4,612 deliberate
max-value records or ~46 trillion honest ones. This is not a typo path and not a one-command path —
it is a sustained write campaign into an append-only file for a cosmetic report line that feeds no
verdict. Filed `info`, not `minor`, for exactly that reason: round 2's finding earned `minor`
because one plausible shell-concatenation accident triggered it, and that property is gone.

### 4 · The derived `tokens` still gets `is_uint`, not `is_uint_bounded` — **an asymmetry, harmless today**

`computed_total` (`:543-546`) is the one value in the chain the new helper was **not** applied to.
With the operand cap in place the consequence is small but real: the derived `tokens` can be 16
digits, which `--tokens` itself now refuses.

```
derived write        -> "tokens":1999999999999998    (16 digits, accepted)
--tokens 1999999999999998   -> REFUSED: --tokens '1999999999999998' is not a non-negative integer
                               of a plausible size.     (nothing written)
```

So `ledger.jsonl` can hold a `tokens` value that `ledger.sh` would refuse if you tried to re-supply
it — structurally the same front-door-versus-derived-path gap round 1's MINOR was built on. The
difference is that round 1's derived value was *negative* and three consumers disagreed about it;
this one is below 2^53, exact in every reader, and no consumer disagrees. `info`. Named because
`is_uint_bounded "$computed_total"` would make the invariant uniform and would also retire the dead
`is_uint` branch §1 identified, at the cost of one word.

### 5 · Round-2 findings 2 and 4 — **both resolved**

- **Finding 2 (info, stale `==` documentation) — RESOLVED.** `core/04-ledger.md:22` now reads
  "When `--tokens` **is** also given, it must not be *less* than `tokens_in + tokens_out` (refused
  if it is) but **may exceed it**", and `specs/ledger-token-split/requirements.md`'s third
  acceptance criterion now states the `>=` rule and cites the G4 Ripple challenge that produced it.
  Both match `tools/ledger.sh:547` and `tests/run.sh:1810`. Verified by reading the diff.
- **Finding 4 (info, the overflow test asserts only the negative-wrap half) — RESOLVED.**
  `tests/run.sh:1840` (`test_ledger_refuses_an_oversized_single_operand_even_when_the_wrapped_sum_is_positive`,
  the 2^64+1 payload) and `:1852`
  (`test_ledger_refuses_tokens_smaller_than_an_oversized_split_even_via_the_wrap`, the `--tokens 2`
  bypass) both assert the positive-residue half directly, and `:1864`/`:1871` pin the 15/16-digit
  boundary. Round 3 re-files a *different* half of the same gap — see finding 1.

### 6 · Regression suite, and what it can still not distinguish

Ten key token/dispatch tests run individually against the real tree: **27 assertions passed, 0
failed, 0 skipped**, including both new wrap tests, both cap-boundary tests, the `0/0` split report
test and both dispatch tests.

**Mutation check on the one behaviour the suite does not pin.** No test anywhere passes a value
longer than 6 digits to `--tokens` itself:

```
$ grep -o -- '--tokens [0-9]*' tests/run.sh | sort -u
--tokens 0   --tokens 100   --tokens 132376   --tokens 1000   --tokens 1500   --tokens 2   --tokens 500
```

So I reverted `:481` from `is_uint_bounded "$tokens"` back to `is_uint "$tokens"` in a scratch copy
of the kit and ran the fourteen token tests against the mutant:

```
test_ledger_records_tokens_in_and_out_and_computes_the_total                      passed 3 · failed 0
test_ledger_refuses_tokens_in_without_tokens_out                                  passed 3 · failed 0
test_ledger_refuses_tokens_out_without_tokens_in                                  passed 3 · failed 0
test_ledger_refuses_tokens_that_contradicts_the_split                             passed 3 · failed 0
test_ledger_accepts_tokens_that_agrees_with_the_split                             passed 1 · failed 0
test_ledger_accepts_and_keeps_tokens_greater_than_the_split                       passed 2 · failed 0
test_ledger_refuses_an_explicitly_empty_tokens_in / _out                          passed 4 / 3 · failed 0
test_ledger_refuses_tokens_in_out_that_overflow_the_sum                           passed 3 · failed 0
test_ledger_refuses_an_oversized_single_operand_even_when_the_wrapped_sum_is_positive  passed 3 · failed 0
test_ledger_refuses_tokens_smaller_than_an_oversized_split_even_via_the_wrap       passed 3 · failed 0
test_ledger_accepts_tokens_at_the_fifteen_digit_cap                               passed 1 · failed 0
test_ledger_refuses_tokens_past_the_fifteen_digit_cap                             passed 2 · failed 0
test_ledger_refuses_non_integer_tokens_in_and_out                                 passed 6 · failed 0
```

**40 assertions, 0 failures, against a mutant that reopens round 2 §3 verbatim:**

```
MUTANT:  --tokens 99999999999999999999 --tokens-in 1 --tokens-out 1
         tools/ledger.sh: line 547: [: 99999999999999999999: integer expected
         logged: G7 (Threat) on c — round 1, 0 finding(s), pass       rc=0
         -> "tokens":99999999999999999999

REAL:    same payload
         REFUSED: --tokens '99999999999999999999' is not a non-negative integer of a plausible size.
         rc=2      NOTHING WRITTEN
```

`test_ledger_refuses_tokens_past_the_fifteen_digit_cap` tests `--tokens-in`, not `--tokens`. The cap
on `--tokens` — the half of the fix that closes the `integer expected` + `exit 0` leak round 2 filed
— is unasserted, and a revert of it ships green. Same shape as round-2 finding 4, in the sibling
flag.

### 7 · The newly-in-scope files, re-checked

`core/cards/G1..G8` each still gain exactly one `logs_with:` line; `tools/lib/matrix.sh` and
`tools/dashboard.sh` read card metadata and the router table, not `logs_with:` prose — no new key,
no new regex anchor. `project/map.md:85`'s data-inventory row now names the split, accurately
(`ledger.jsonl`, append-only, written only by `tools/ledger.sh`, leaves the process only via a
published `dashboard.html`, not personal) — matches the code. No finding.

---

## Round 3 findings

### INFO — no test pins the 15-digit cap on `--tokens` itself; reverting it ships green

`tests/run.sh:1871`. Mutation-proven in §6: reverting `tools/ledger.sh:481` to plain `is_uint`
leaves all fourteen token tests passing (40 assertions, 0 failures) while restoring round 2 §3
exactly — `[: …: integer expected` at `:547`, `logged:` with `exit=0`, and a 20-digit `tokens`
written. `test_ledger_refuses_tokens_past_the_fifteen_digit_cap` exercises `--tokens-in`; nothing
exercises `--tokens` above 6 digits. A test is discrimination-proven only against the wrong
implementations it can distinguish.

### INFO — the cap bounds each record, not the ledger; `cmd_report`'s aggregate still crosses `INT64_MAX`

`tools/ledger.sh:1569`. `[ "$toks" -gt 0 ]` receives an unbounded ledger-wide sum. At 4,612
max-legal records the report emits `[: 9223999999999997952: integer expected` on stderr and then
prints "tokens spent **not recorded**" above a split line reporting 4.6 quadrillion (§3).
`dashboard/app.js:367` loses IEEE-754 precision on the same aggregate far earlier (277 max-legal
records → `Number.isSafeInteger` false) without erroring. Rated `info`, not `minor`: the trigger is
4,612 deliberate maximum-value writes into an append-only file (the real ledger is 277 lines with a
maximum `tokens` of 200000), not round 2's single plausible concatenation, and the field feeds no
verdict.

### INFO — `computed_total` gets `is_uint`, not `is_uint_bounded`, so the derived `tokens` can exceed what `--tokens` accepts

`tools/ledger.sh:543-546`. The derived write of `1999999999999998` is accepted while the identical
value supplied as `--tokens` is refused (§4). Harmless today — below 2^53, exact in every reader, no
consumer disagreement — but it is the same front-door-versus-derived-path asymmetry round 1's MINOR
was built on, and the operand cap has already made the `is_uint` branch at `:544` dead code, which
the comment at `:538-542` concedes.

### INFO — the unknown-subcommand refusal still reflects arbitrary caller bytes to stderr

`tools/ledger.sh:1699`. Carried forward from round-2 finding 3, unchanged and unfixed. No injection
across fourteen payloads (§2), but `$1` is echoed where it previously was not, so ANSI/control
sequences reach the operator's terminal unfiltered. Still unreachable by a hostile party — no repo
caller passes a variable as the subcommand. Re-filed so that changing that stays visibly a security
change.

### OUT-OF-SCOPE — `--round` is the same class the new helper was written for and did not get it

`tools/ledger.sh:472` (`is_uint "$round"`, plain) and `:1243` (`[ "$passed_at" -lt "$round" ]`),
`:1245` (`$((round - passed_at))`). `is_uint_bounded`'s own comment (`:203-205`) states its scope as
"any value that will be fed to bash arithmetic (`$(( ))`) or a numeric `-lt`/`-eq` test." `round`
meets that description exactly. Live:

```
$ ledger.sh compliance --change c --tier T4 --round 99999999999999999999
Gate compliance — c, tier T4, round 99999999999999999999
tools/ledger.sh: line 1243: [: 99999999999999999999: integer expected
tools/ledger.sh: line 1243: [: 99999999999999999999: integer expected
rc=0

$ ledger.sh add … --round 99999999999999999999
logged: G7 (Threat) on c — round 99999999999999999999, 0 finding(s), pass
-> "round":99999999999999999999
```

**Confirmed pre-existing and untouched by this change** — `git diff -U0 -- tools/ledger.sh` shows no
hunk within 10 lines of `:472`, and none anywhere in `cmd_compliance`. Per `02-gates.md`'s failure
rule ("do not fold an unrelated fix into an already-scoped change"), this is **filed as a separate
follow-up item against `tools/ledger.sh` `--round` validation**, not routed back through Build for
`ledger-token-split`. Recorded here because round 3's whole subject is whether the new bound covers
what it claims, and the honest answer is that it covers the three fields it was applied to and
leaves an identically-shaped sibling open.

### Not findings — checked and cleared

- The 15-digit bound itself on the write path: no reachable input puts an operand outside `int64`
  into `$(( ))` or `-lt`; maximum `computed_total` is 4,611× below 2^63 and below 2^53 (§1).
- The round-2 payload and its whole positive-residue neighbourhood (§1).
- Zero-padding past the cap; `${#1}` is a character count and `is_uint`'s leading-zero arm fires
  first anyway (§1).
- Duplicate-key forgery and bare-JSON escape on both new flags; `$(( ))` injection at `:543`, still
  closed by ordering (§2).
- Free-text forgery of the split extractors and of the unfiltered `split_runs` counter at `:1595`
  (§2).
- Subcommand-dispatch injection, fourteen payloads; `--ledger` still strips before dispatch (§2).
- Round-2 findings 2 and 4, both resolved (§5).
- Card and `project/map.md` additions: no parser reads the changed lines (§7).

---

## Round 3 T4 boundary check

| Boundary (surfaces.conf) | Crossed? | Checked? |
|---|---|---|
| Untrusted CLI argument → bare JSON position | Yes | Yes — 19 payloads refused, file never created (§2) |
| Untrusted CLI argument → bash arithmetic `$(( ))` at `:543` | Yes | Yes — `is_uint_bounded` at `:516`/`:519` runs first; ordering still saves it (§1, §2) |
| Untrusted CLI argument → numeric `-lt` at `:547` | Yes | **Yes — both operands provably in `[0, 10^15)`; round-2 bypass and stderr leak both closed (§1)** |
| **Derived value → bare JSON position** | **Yes** | **Yes — wrap impossible; residual asymmetry is `info` only (§1, §4)** |
| Untrusted CLI argument → `echo` on stderr (dispatch) | Yes | Yes — no injection; reflection unchanged from round 2 (§2) |
| `ledger.jsonl` → `cmd_report`/`cmd_gates` readers | Yes | **Partly — per-record sound, ledger-wide aggregate unbounded at `:1569` (§3)** |
| `ledger.jsonl` → `dashboard/app.js` `JSON.parse` | Yes | Yes — single record exact below 2^53; aggregate loses precision silently (§3) |
| `ledger.jsonl` → `compliance` verdict path | **No** — `cmd_compliance` has no `tokens` reference | Confirmed again by extraction |
| `core/cards/*` → card parsers | Yes | Yes — `logs_with:` prose is not dispatched on (§7) |

**Privilege growth:** none. No new file, network, process or credential reach; `cmd_add` writes the
same single file through the same `emit()`.

---

## Round 3 verdict

**G7 · Threat (HARD GATE, T4): PASS**, round 3.

`passes_when: no unresolved finding above low`. Four `info` findings and one `out-of-scope` finding
routed to a separate item; **no `blocking` and no `minor`**. The gate passes.

The bound is genuinely airtight where it matters, and that conclusion is arithmetic rather than
sampling: `computed_total` has exactly two addends, both capped at 15 characters by a pure string
comparison that cannot itself wrap or crash, so the maximum reachable sum is `1999999999999998` —
4,611× below 2^63 and, usefully, below 2^53 as well, so the `JSON.parse` consumer is exact too. Both
halves of the round-2 finding are closed at the source: the positive-residue wrap dies at `:516`
before any arithmetic exists, and the `>=` comparison at `:547` can no longer be fed an out-of-range
operand in either position, which removes the `integer expected` + `exit 0` leak as well. Round 1's
payload, round 2's payload, the whole neighbourhood of 20-digit values round 2 measured, and every
round-1 injection and forgery class were re-run against this diff and are refused with nothing
written.

What the change does **not** own, and should be read as not owning: the cap is a property of one
record, not of the file. `cmd_report`'s ledger-wide sum is still unbounded, so the same shell error
round 2 found still exists — 4,612 max-legal records away instead of one command. That is a real
relocation rather than an elimination, and it is `info` only because the trigger is now a sustained
deliberate campaign into an append-only file for a field that feeds no verdict.

Confidence: **fresh** — this session received the cards, `02-gates.md`, `surfaces.conf`, rounds 1-2
of this report and the diff. `INTENT-LOG.md`, `SESSION-HANDOFF.md` and the pending
`core/08-models.md` edit were withheld and not opened. All ledger writes were to scratch files in a
throwaway repo.

**Premise challenged: yes.** The change's central claim — `tools/ledger.sh:213-215` and
`specs/…/requirements.md:46-50`, that capping each operand means "nothing downstream can wrap" — was
tested rather than accepted, and it is true per record and false per ledger (§3, finding 2). The
suite's coverage of its own fix was tested by mutation rather than by reading the test names, which
is what produced finding 1: the half of the fix that closes the exact symptom round 2 filed ships
green if reverted. And the fix's stated scope — a helper explicitly written for "any value fed to
bash arithmetic or a numeric test" — was checked against the rest of the file rather than only
against the fields the diff touches, which is what produced the out-of-scope `--round` item.

Per the failure rule, two consecutive failures (rounds 1 and 2) had already escalated this change;
it was at T4, the ceiling, so the standing consequence remains that the **T4 approver sees all three
rounds**, which `escalate_to: T4 approver. NEVER the author alone` requires regardless. Round 3
closes the security gate; the four `info` items are advisory and the `out-of-scope` item belongs to
a different change.

---

## Round 3 structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `info` | `tests/run.sh:1871` | No test passes `--tokens` a value above 6 digits, so reverting the cap at `tools/ledger.sh:481` to plain `is_uint` keeps all 14 token tests green (40 assertions) while restoring round 2 §3 verbatim — `integer expected`, `exit 0`, 20-digit `tokens` written |
| 2 | `info` | `tools/ledger.sh:1569` | The 15-digit cap bounds each record, not the ledger; `[ "$toks" -gt 0 ]` errors once the ledger-wide sum passes `INT64_MAX` (4,612 max-legal records), printing "tokens spent not recorded" above a 4.6-quadrillion split line; `dashboard/app.js:367` loses IEEE-754 precision on the same sum far earlier |
| 3 | `info` | `tools/ledger.sh:543` | `computed_total` gets `is_uint`, not `is_uint_bounded`, so the derived `tokens` can be 16 digits (`1999999999999998`) — a value `--tokens` itself refuses; harmless below 2^53, but the same front-door/derived asymmetry as round 1, and the `is_uint` branch at `:544` is now dead |
| 4 | `info` | `tools/ledger.sh:1699` | Carried forward unchanged from round-2 finding 3: the unknown-subcommand refusal reflects `$1` verbatim to stderr — no injection across 14 payloads, but ANSI/control bytes reach the terminal |
| 5 | `out-of-scope` | `tools/ledger.sh:472` | `--round` uses plain `is_uint` and reaches `[ -lt ]` at `:1243` and `$(( ))` at `:1245` — exactly the class `is_uint_bounded` was written for; `compliance --round <20 digits>` prints `integer expected` twice and exits 0. Confirmed pre-existing (no diff hunk near `:472` or in `cmd_compliance`); filed as a separate follow-up item against `--round` validation, not routed back through Build for `ledger-token-split` |

## Round 3 ledger line

```
bash tools/ledger.sh add --change ledger-token-split --gate G7 --tier T4 --round 3 \
  --outcome pass --confidence fresh --challenged true --model opus \
  --tokens-in 104000 --tokens-out 16000 \
  --finding "info::tests/run.sh:1871::no test passes --tokens a value above 6 digits, so reverting the cap at tools/ledger.sh:481 to plain is_uint keeps all 14 token tests green (40 assertions) while restoring round 2 section 3 verbatim - integer expected, exit 0, 20-digit tokens written" \
  --finding "info::tools/ledger.sh:1569::the 15-digit cap bounds each record not the ledger; the -gt test on cmd_report's ledger-wide tokens sum errors past INT64_MAX (4612 max-legal records), printing 'tokens spent not recorded' above a 4.6-quadrillion split line, and dashboard/app.js:367 loses IEEE-754 precision on the same sum far earlier" \
  --finding "info::tools/ledger.sh:543::computed_total gets is_uint not is_uint_bounded, so the derived tokens can be 16 digits (1999999999999998) - a value --tokens itself refuses; harmless below 2^53 but the same front-door/derived asymmetry as round 1, and the is_uint branch at :544 is now unreachable" \
  --finding "info::tools/ledger.sh:1699::carried forward from round-2 finding 3, unchanged: the unknown-subcommand refusal reflects the subcommand verbatim to stderr - no injection across 14 payloads, but ANSI/control bytes reach the terminal" \
  --finding "out-of-scope::tools/ledger.sh:472::--round uses plain is_uint and reaches a numeric -lt at :1243 and bash arithmetic at :1245, exactly the class is_uint_bounded was written for; compliance --round with 20 digits prints 'integer expected' twice and exits 0. Pre-existing and untouched by this diff, so routed to a separate follow-up rather than back through Build for ledger-token-split. filed:security-reports/2026-09-15-ledger-token-split.md Round-3 out-of-scope section" \
  --note "Round 3, 7c depth, fresh context. …"
```

Run and accepted — `logged: G7 (Threat) on ledger-token-split — round 3, 5 finding(s), pass`, exit 0.
The record carries `"commit":"9dd69c4"` (auto-detected, matching the sha this report names),
`"tokens":120000` computed from the split, `"challenged_premise":true`, and the `out-of-scope`
finding's `"filed":"security-reports/2026-09-15-ledger-token-split.md"`.

A first attempt without the `filed:` token was **refused** (`REFUSED: an 'out-of-scope' finding must
say where it was filed.` … `Nothing was written.`) — the `02-gates.md` rule working as designed, and
incidentally one more live confirmation that `cmd_add`'s refusals are all-or-nothing.

---

## Commit binding (change owner, not a new gate round)

Round 3 reviewed the uncommitted working-tree diff on top of `9dd69c4`. Four small edits landed
after that review, in response to G6 Peer round 3's own (info-level) findings, before this change
was committed as **`e927bf72c0297f9057c8af85527d0a274c5f2b4e`**. This note is the change owner's
own accounting of that gap — not a fourth blind gate round — because every edit is either a comment
or a read-side reporting filter, none touching the write-path validation/arithmetic/comparison
logic rounds 1-3 actually reviewed:

- `tools/ledger.sh`: three comments corrected from "wraps silently at 2^64" to "overflows silently
  past 2^63" (the precise threshold for bash's *signed* 64-bit arithmetic — round 3 finding 3's own
  sibling text already had this right six lines away; this just made the file consistent). Wording
  only, zero runtime effect.
- `tools/ledger.sh` (`cmd_report`): `split_runs=$(grep -c '"tokens_in"' "$LEDGER")` narrowed to
  `grep '"type":"gate"' "$LEDGER" | grep -c '"tokens_in"'`, matching the filter the three sums two
  lines below it already use. Read-side reporting only — not in the write path this report's threat
  model covers — and G6 round 3 itself noted the gap was unreachable today (`json_escape` prevents
  the key surfacing inside a string field), so this narrows an already-safe match, it doesn't change
  what's accepted into the ledger.
- `tests/run.sh`: one stale test comment reworded to match what the test now actually exercises
  (round 3 finding 1, self-inflicted by round 3's own fix), plus one new test
  (`test_ledger_refuses_an_oversized_standalone_tokens_value`, fixing round 3 finding 1's coverage
  gap) and one new test (`test_ledger_report_shows_nonzero_split_at_one_decimal_precision`, a
  `cmd_report` formatting check). Purely additive test coverage; no test was weakened or removed.

`git show e927bf72c0297f9057c8af85527d0a274c5f2b4e -- tools/ledger.sh` is the reviewed logic plus
exactly these four edits. Round 3's **PASS** verdict is judged to still hold for this commit on that
basis. If a maintainer disagrees that a wording/filter/test-only diff doesn't warrant a fresh blind
pass, the right response is to run G7 again against `e927bf7`, not to treat this note as equivalent
to one.
