# Security review — closed-set `--confidence` refusal in `cmd_add` (confidence-vocabulary-refusal)

Reviewed commit: **`3971a7f8cdb2025b54cf81108386b29c61693594`** — G7 · Threat, fresh context,
blind (author's threat assessment and stated purpose withheld; `specs/confidence-vocabulary-refusal/**`,
the tail of `INTENT-LOG.md`, and `SESSION-HANDOFF.md` not read). Intent derived from the diff:
`cmd_add` validated every closed-set field before `emit()` except `--confidence`, which was
spliced in as free text; this adds the same `case` refusal `--outcome` already has, restricting
`--confidence` to `fresh|low`, and rewrites two now-stale comments.

Model: `claude-sonnet-5` (strongest available for this account).

## Files in scope

- **`tools/ledger.sh`** — **T4** (`project/surfaces.conf:27` —
  `tools/(reconcile|ledger|install-hook|install-claude-hook|status)\.sh$`, *"Routing and
  evidence — a wrong answer here is silent and confident"*). New `case "$confidence"` closed-set
  check (`:494-503`), inserted between the `--outcome` check (`:470-477`) and the `n/a`-warning /
  skipped-downgrade block (`:509-519`). Rewritten comment block above the check (`:479-493`) and
  above `emit()` (`:539-547`).
- **`tests/run.sh`** — **T3** (`project/surfaces.conf:50` — *"The suite — if it stops asserting,
  nothing else here is trustworthy"*). Two new tests + a preceding comment block
  (`:1223-1263`).

Highest tier in the change: **T4** → G7 is a **HARD GATE**.

`project/surfaces.conf` here carries `SELF: gated-change`, so these are this repo's own trust
boundaries, not a shipped example. The standing threat model for `tools/ledger.sh` is set by
`security-reports/2026-08-13-587e8e1.md` (scalar-field forge via unescaped/unvalidated
splice), `2026-08-14-cli-input-validation-hardening.md` (closed-set refusals for CLI fields),
and `2026-09-06-r005-computed-default-branch.md` (write-path refusal decisions).

## Threat model — who is the untrusted party

`ledger.sh add` is invoked by a subagent grading a gate run (sometimes with text derived from a
diff or PR body in scope) or by a human at a terminal. The untrusted inputs are the **argument
values** to `add`. The relevant one here is `--confidence`. Per `2026-08-13-587e8e1.md` the
standing concern is a caller — hostile or careless — getting a value into a JSON position it
should not control, or getting a false verdict recorded in the one file `04-ledger.md` calls
*"not self-graded."*

`$confidence` is assigned in exactly one place — `--confidence) confidence="$2"` (`:397`);
`grep -n 'confidence=' tools/ledger.sh` confirms no other writer. It is **not** reachable from
git state, environment (`PIPELINE_MODEL` sets `model`, not `confidence`), the diff, or
`ledger.jsonl` content. So the only party who can steer `$confidence` is whoever composes the
`add` command line.

## Trust-boundary walk

### 1 · Does the refusal grow or shrink attack surface — SHRINKS

Before `3971a7f`, `$confidence` was one of the free-text scalars spliced into the `emit()`
template. After, only `fresh` or `low` reaches `emit()`. That is one fewer caller-influenced
value in a quoted JSON position, and the two survivors are `[a-z]+` with no metacharacter.
Nothing new is parsed, sourced, `eval`'d, or shelled out. The new code is a `case` (scrutinee
quoted, patterns literal), an `echo … >&2`, and `exit 2` — the exact shape of the `--outcome`
check 24 lines above and the `--tier` / `--resolution` checks elsewhere in the file.

### 2 · Can a hostile caller induce a refusal for a LEGAL value (`fresh`/`low`) — NO

`case "$confidence" in fresh|low) ;;` — `$confidence` is the `case` subject, not re-parsed as
a pattern; both operands of the match are literal. A value of exactly `fresh` or exactly `low`
always takes the pass arm. Live-verified at this sha (scratch ledger):

```
confidence=[freshh]          exit=2   (nothing written)
confidence=[true]            exit=2   (nothing written)
confidence=[]                exit=2   (nothing written)
confidence=[fresh","x":"y]   exit=2   (nothing written)
confidence=[low]             exit=0   "confidence":"low"
confidence=[fresh]           exit=0   "confidence":"fresh"
```

A caller who controls `--confidence` can of course *provoke* a refusal by passing garbage —
that is the intended fail-closed behaviour, identical to `--outcome`/`--tier`. It does not
amplify: the refusal aborts only the current `add`, writes nothing, cannot touch a record
already in the ledger, and — unlike the `2026-09-06` `--change` finding — carries no value that
equals some *other* legitimate input, so it cannot be aimed at a third party's writes.
`$confidence` is not attacker-reachable except through the operator's own arg (walk above).

### 3 · Injection posture vs the `--lane` forge (`2026-08-13-587e8e1.md`) — BETTER

The `--lane` finding was `lane` being **both** unvalidated **and** (at that sha) unescaped, so
`--lane 'normal","outcome":"pass","confidence":"fresh'` forged a duplicate `"outcome"` key and
`compliance` read the gate as PASS. The remediation for that report escaped every scalar,
including `confidence` — `emit()` at `:551` already calls `$(json_escape "$confidence")`, and
`json_escape` (`:300`) neutralises `\` and `"`. So confidence's forge vector was **already
closed by escaping** before this change. `3971a7f` adds a closed-set gate *in front of* that
escape: the only values that now reach `json_escape` are `fresh`/`low`, so even a future
regression of `json_escape` could not let `confidence` carry a `"` or `:`. Belt on top of
suspenders. Verified: the `fresh","x":"y` payload above is refused outright.

The rewritten `emit()` comment (`:539-547`) correctly narrows the old *"confidence and lane
are free text by design"* to `lane` only, and correctly states `lane` now relies on escaping
alone while `tier/gate/outcome/confidence` are closed-set + escaped. Accurate.

### 4 · Append-only history / compliance's reading of it — UNTOUCHED

The check is in the **write path only** (`cmd_add`, before `emit()`). No read path is in the
diff. `ledger.jsonl` on this branch carries out-of-vocab historical records —
`grep -oE '"confidence":"[^"]*"' ledger.jsonl | sort | uniq -c`: **5× `high`, 19× `same-session`**,
plus 157 `fresh` / 61 `low`. Refusing *new* out-of-vocab writes does not rewrite or re-read
those:

- `ledger.sh` report totals (`:1392-1393`): `fresh=$(grep -c '"confidence":"fresh"')`,
  `low=$(grep -c '"confidence":"low"')` — a `high`/`same-session` record matches neither and is
  excluded from both counts, exactly as before this change.
- `cmd_gates` per-gate table (`:1353,1357`): same `grep` semantics, unchanged.
- Dashboard `isIndependent(conf){ return conf === "fresh" }` (`app.js:182`) — strict equality,
  keyed on the one safe value, so every non-`fresh` value (historical or hypothetical) reads as
  **not independent**. `app.js:173-181` documents this deliberately for the `high`/`same-session`
  records. Node-verified against the shipped `app.js`:
  `isSelfCheck({outcome:"pass",confidence:c})` is `true` for `c ∈ {low, high, freshh, true,
  same-session, ""}` and `false` only for `fresh`.

So historical records parse identically pre- and post-change; nothing about `report` or the
dashboard breaks. This matches the `04-ledger.md` *"Never backfill … a mixed ledger … is the
permanent, ordinary state"* principle.

### 5 · `--confidence ""` (empty) and `set -u`

`tools/ledger.sh:103` is `set -uo pipefail` (no `set -e`). `confidence` is initialised to
`fresh` at `:384` and `confidence_set` to `0`, so neither is ever unbound. `--confidence ""`
sets `confidence=""`, `confidence_set=1`; the `case` falls to `*)` → `exit 2`, nothing written
(verified above). This is a behaviour change from before (`""` used to write
`"confidence":""`), and it is the correct direction — an empty confidence was already
non-`fresh` everywhere downstream. The missing-`$2` case (`--confidence` as the final arg) trips
`set -u` and aborts loudly; that is pre-existing for every two-token flag and not introduced
here.

### 6 · Ordering vs the skipped/n-a downgrade — SAFE, mild DiD gap

The new check (`:494`) runs **before** the `skipped`/`n/a` → `low` auto-downgrade (`:517-519`).
The downgrade only ever assigns the literal `low`, which is in-vocab, so its output is never
re-validated but is provably safe today. `--outcome skipped` with no `--confidence`: default
`fresh` passes the check, then downgrades to `low` — correct. `--outcome skipped --confidence
high`: now refused at `:494` (previously written as `high`) — strictly better. Noted as `info`
only: a future edit that made the downgrade emit something other than `low` would not be caught
by this check's position.

## Findings

### MINOR — the rationale comment inverts the dashboard's actual failure direction

`tools/ledger.sh:485-488` (and the mirrored comment at `tests/run.sh:1229-1233`).

The comment justifying the new check states:

> *"tools/dashboard/app.js's isIndependent() trusts ONLY `=== "fresh"` … so an out-of-vocab
> value does not read as 'not independent' and get hatched as a self-check — it is a value the
> dashboard has no case for, and a `pass` carrying it renders as a clean independent gate that
> never happened."*

`app.js` does the **opposite**. `isIndependent(conf){ return conf === "fresh"; }` (`app.js:182`)
returns `false` for every non-`fresh` value, and `isSelfCheck(r){ return isVerdict(r.outcome)
&& !isIndependent(r.confidence); }` (`app.js:197`) therefore returns `true` for a `pass`
carrying `freshh` / `true` / `high` / `""`. `app.js:180-181` says so explicitly: *"Keyed on the
ONE value that is safe to trust rather than a blocklist, so an unrecognised value fails toward
'not independent'."* Node-verified against the shipped file (§4 above): an out-of-vocab
`--confidence` on a `pass` renders as a **self-check** — muted/`low` CSS class (`app.js:658`),
`"(self-check)"` label (`app.js:693,1090`), excluded from the fresh-run count (`app.js:347`).
That is the **fail-closed / safe** direction, not "a clean independent gate that never
happened."

The real pre-change harm — correctly described by the *commit message body* but not by the
code comment — is the inverse: a genuinely independent, fresh-context review that gets a
typo'd `--confidence` is **silently downgraded to a self-check** and dropped from both the
`fresh` and `low` report counts, so the reviewer loses credit for an independent run and the
disagreement-quota / yield statistics under-count. That is a real evidence-integrity problem
and a good reason for the check. But the comment as written tells the next person that the
failure mode is fail-*open* ("renders as independent"), which is exactly the wrong thing to
believe when deciding whether this check may later be relaxed on a T4 surface whose whole risk
category is *"a wrong answer here is silent and confident."*

Rated `minor`, not `info`: no runtime behaviour is wrong (the code is correct and strictly
safer than before), but a load-bearing security rationale on a T4 file asserts the opposite of
what the consumer it names actually does. Fix: reword `:485-488` / `run.sh:1229-1233` to match
`app.js:180-181` — an out-of-vocab value fails *closed* to self-check; the check exists to stop
a real fresh review being silently demoted and vanishing from both report counts, not to stop
a fake independent pass.

### INFO — the motivating anecdote is not traceable in this branch's `ledger.jsonl`

The commit message says *"a G7 round-2 entry logged `--confidence true` (ledger.jsonl,
2026-09-08) had to be superseded by a corrected append."* `grep '"confidence":"true"'
ledger.jsonl` and `git log -S'"confidence":"true"' -- ledger.jsonl` on this branch both return
nothing; no `ci-to-codebuild` gate records exist either. The anecdote may have lived on an
un-merged branch or been corrected before landing. It does not affect the security posture —
the check's justification (`04-ledger.md` closed vocabulary, `app.js:182` strict key, append-
only) stands without it — but a T4 change citing a specific ledger event that the ledger does
not contain is worth a note.

### INFO — closed-set check precedes the skipped/n-a downgrade

`tools/ledger.sh:494` vs `:517-519` — see trust-boundary walk §6. Safe today (downgrade only
emits the in-vocab literal `low`); flagged so a future change to the downgrade is not assumed
covered by this check.

### INFO — `app.js` count comment is stale (observed, not in scope)

`tools/dashboard/app.js:176` says the ledger carries *"5 and 11 records"* of `high` /
`same-session`; it is now 5 and **19**. `app.js` is not touched by this diff — noted only
because this review counted them.

## T4 boundary check

`tools/ledger.sh` matched the `project/surfaces.conf:27` T4 row. Walked: one new closed-set
`case` on a single caller-supplied scalar, placed among the file's existing identical checks,
before the sole append point `emit()`. **No trust boundary is crossed without a check** — the
change *adds* a check. Privilege did not grow; the set of inputs that reach a quoted JSON
position *shrank* by one free-text field. The one finding is a comment that misdescribes a
downstream consumer's failure direction — a documentation defect on a T4 surface, not a
runtime boundary breach.

`tests/run.sh` (T3): the two new tests assert exit 2 + `REFUSED` + nothing-written for eight
bad values (incl. `""`), and exit 0 + correct field for `fresh` / `low` / default /
skipped-downgrade. `bash tests/run.sh 'test_ledger_..._confidence'` → **24 passed, 0 failed**.
No test feeds an untrusted fixture into a sink.

## 7a continuous checks (on the diff)

- **Secret scan:** none. Shell + comments only.
- **Dangerous-sink grep** (`eval`, `innerHTML`, backticks, unquoted expansion into a command):
  none added. New sinks are `echo … >&2` and `exit 2`; `case` scrutinee is quoted.
- **Empty-catch:** none. The `*)` arm emits a 6-line diagnostic and `exit 2` — it acts, it does
  not swallow.

## Verdict

**PASS** (hard gate, T4). The change strictly shrinks the write-side attack surface: one fewer
caller-influenced free-text scalar reaches the `emit()` JSON template, and the two permitted
values are metacharacter-free. It cannot be induced to refuse a legal `fresh`/`low`, `$confidence`
is not attacker-reachable beyond the operator's own arg, `--confidence ""` is handled
(refused), there is no `set -u` regression, and no read path or historical record is affected —
the 5 `high` / 19 `same-session` legacy entries parse exactly as before. Injection posture for
`confidence` is better than the `--lane` forge baseline (closed-set *and* escaped, vs escaped
alone). One **minor** finding: the check's rationale comment (`ledger.sh:485-488`, mirrored in
`tests/run.sh`) states the dashboard fails *open* on an out-of-vocab confidence when
`app.js:182` demonstrably fails *closed* — a T4 documentation defect that should be corrected,
but no unresolved finding above `minor` and no runtime boundary is crossed.

**challenged_premise: true** — the change's own stated security rationale (out-of-vocab
confidence "renders as a clean independent gate that never happened") is contradicted by the
consumer it cites; `app.js` renders it as a self-check (fail-closed). The check is still
worth having, for the *inverse* reason the commit-message body gives.

## Findings (structured)

| severity | location | claim |
|---|---|---|
| minor | `tools/ledger.sh:485-488` (mirrored `tests/run.sh:1229-1233`) | rationale comment says an out-of-vocab `--confidence` "does not read as 'not independent'" and "renders as a clean independent gate that never happened"; `tools/dashboard/app.js:182` `isIndependent` is strict `=== "fresh"` and `:197` `isSelfCheck` therefore renders it as a **self-check** (fail-closed) — Node-verified for `freshh`/`true`/`high`/`""`. The real harm is the inverse (a genuine fresh review silently demoted to self-check and dropped from both `fresh` and `low` report counts). Comment inverts the failure direction on a T4 "silent and confident" surface; no runtime impact. Fix: reword to match `app.js:180-181`. |
| info | commit message / `ledger.jsonl` | commit message cites *"a G7 round-2 entry logged `--confidence true` (ledger.jsonl, 2026-09-08)"*; `grep '"confidence":"true"' ledger.jsonl` and `git log -S` on this branch find no such record and no `ci-to-codebuild` gate rows. Motivating anecdote untraceable here; check's justification stands without it. |
| info | `tools/ledger.sh:494` vs `:517-519` | closed-set confidence check runs before the `skipped`/`n/a`→`low` auto-downgrade; safe today (downgrade only emits the in-vocab literal `low`) but the downgrade's output is not itself re-validated. |
| info | `tools/dashboard/app.js:176` | count comment ("5 and 11 records" of `high`/`same-session`) is stale — now 5 and 19. `app.js` not in this diff; noted in passing. |

## Ledger line

```
ledger.sh add --change confidence-vocabulary-refusal --gate G7 --tier T4 --round 1 \
  --outcome pass --confidence fresh --challenged true --model claude-sonnet-5 --tokens 49000 \
  --finding "minor::tools/ledger.sh:485::rationale comment claims an out-of-vocab --confidence renders as a clean independent pass; app.js:182 isIndependent is strict === \"fresh\" so app.js:197 isSelfCheck renders it as a self-check (fail-closed, Node-verified for freshh/true/high/empty). Real harm is the inverse: a genuine fresh review silently demoted to self-check and dropped from both fresh and low report counts. Comment inverts the failure direction on a T4 surface; no runtime impact. Also mirrored in tests/run.sh:1229" \
  --finding "info::ledger.jsonl::commit message cites a G7 round-2 --confidence true entry (2026-09-08) that grep and git log -S do not find on this branch; check justification stands without the anecdote" \
  --finding "info::tools/ledger.sh:494::closed-set confidence check precedes the skipped/n-a to low downgrade; safe today (downgrade only emits in-vocab low) but downgrade output is not re-validated" \
  --finding "info::tools/dashboard/app.js:176::high/same-session count comment stale (5 and 11, now 5 and 19); app.js not in this diff"
```

---

## Round 1 follow-up (post-review fixes)

The round-1 **PASS** stands for the landed change. The one `minor` and one `info`
were resolved in the same round; nothing re-opens the threat review:

- **`minor` (inverted rationale):** the comment at `tools/ledger.sh` and the
  `REFUSED` stderr text were reworded to state the *actual* (fail-closed)
  behaviour — an out-of-vocab value renders as an author self-check and drops
  from `ledger.sh report`'s fresh/low/challenge counts. Also fixed in the
  `tests/run.sh` comment. G6 Peer and G4 Ripple independently raised the same
  finding. **No security-relevant code changed** — the `case` guard is
  byte-identical.
- **`info` (untraceable anecdote):** confirmed real. The `--confidence true`
  record is `ci-to-codebuild` G7 round 2, committed on another branch as
  **`b471896`** (*"G7 r2 first line was mis-typed --confidence true … superseded
  by a corrected line"*); it is not on this branch's `ledger.jsonl` because
  that branch has not merged. The comment/commit now cite `b471896`.
- **`info` (downgrade ordering):** left as-is (documented); the downgrade only
  ever emits the in-vocab literal `low`.
- **`info` (`app.js:176` stale count):** left for a separate change — `app.js`
  is not in this diff.

Two round-1 gate additions (G6/G8, not security-driven): a "no `--confidence`
recorded" **warning** on `pass`/`fail` (stderr only, no attack surface — matches
the existing `--model`/`--tokens` warnings), and a corrected `emit()` comment
noting `--lane`/`--model` are escaped-but-unguarded (a `--lane` guard is a
filed follow-up; it would require rewriting the 2026-08-13 forge regression
test). The security-relevant surface — one caller scalar reaching the `emit()`
JSON position, now closed-set — is unchanged from the reviewed commit.

The trust-boundary files this report reviews (`tools/ledger.sh` `cmd_add`) are
re-reviewed by G6 at round 2; the G7 round-1 verdict carries to the landed tip.

---

## Round 3

**Reviewed:** `8746e6c` ("ledger: --confidence is REQUIRED for a pass/fail verdict").
The header of this report names `3971a7f` (round 1); round 3 reviews `8746e6c`.
At the time of writing the branch tip was `c07321c`; it was afterward
`git reset --soft` back past three stray fixture-authored "base" commits (a
`tests/run.sh` isolation bug triggered by a full C: temp volume — chip filed),
so the tip is now **`ea29280`**. `git diff 8746e6c..ea29280 -- tools/ledger.sh
tests/run.sh` is **empty** — the two in-scope files are byte-identical to the
reviewed `8746e6c`, so this review binds to the landed tip. FRESH context, blind
(`specs/confidence-vocabulary-refusal/**` not read).
Cumulative diff basis: `git diff c4161b5..8746e6c -- tools/ledger.sh` (round-3
change is the last hunk: `confidence` default `fresh` → `""`, and a new `elif`
refusal branch making `--confidence` required for a `pass`/`fail` verdict).

### What round 3 changes

1. `cmd_add` local init: `confidence="fresh"` → `confidence=""` (`tools/ledger.sh:387`).
   The defaulted code path (an unflagged `add` silently writing `"confidence":"fresh"`)
   is **removed**.
2. New branch after the `confidence_set` `case` (`tools/ledger.sh:516-524`):
   `elif [ "$outcome" = "pass" ] || [ "$outcome" = "fail" ]; then echo …>&2; exit 2`.
   `skipped`/`n/a` fall through to the existing `low` downgrade (`:540-542`).
3. ~63 test-fixture invocations gain a literal `--confidence fresh`; three new tests.

### 1 · Does making `--confidence` required change the security posture — YES, IT IMPROVES IT

Before `8746e6c`, a `pass` logged with **no** `--confidence` flag wrote
`"confidence":"fresh"` from the local default. `app.js:182 isIndependent` then read
that record as an independent fresh-context review and `cmd_report` (`:1420`) counted
it in the `fresh` bucket and the challenge-rate denominator — an **unearned
independence claim minted by omission**, on the T4 surface whose whole risk category
is "a wrong answer here is silent and confident." Round 3 removes that: the only way
`"confidence":"fresh"` now reaches `emit()` is an explicit `--confidence fresh`
argument. The write path can no longer hand out the privileged value for free. This
is a straight reduction of the write-side evidence-integrity surface, on top of the
round-1 reduction (free-text scalar → closed set).

The removed default path carried no injection risk itself (it assigned the literal
`fresh`); the added branch is `echo … >&2` + `exit 2`, the exact shape of the
`--outcome` / `--tier` / round-1 `--confidence` refusals. Nothing is parsed, sourced,
`eval`'d or shelled. `$outcome` is interpolated into the `elif`'s `echo` string
(`:517`) but it is closed-set-validated 40 lines above (`:473-480`) — only the
literals `pass`/`fail` can reach that `echo`. `$LEDGER` is echoed (a path, operator-
controlled via `--ledger`, never a value a hostile arg can steer). No new sink.

### 2 · Can a caller reach `emit()` with an out-of-vocab or empty `confidence` — NO

Walked, with `outcome` already constrained to `pass|fail|skipped|n/a` by `:473`:

| `confidence_set` | `outcome` | path | reaches `emit()` as |
|---|---|---|---|
| 1 | any | `case` `:506` — `fresh\|low` pass arm, else `*) exit 2` | `fresh` or `low` only |
| 0 | `pass`/`fail` | `elif` `:516` → `exit 2` | (nothing — refused) |
| 0 | `skipped`/`n/a` | neither branch; `:540` downgrade stamps `low` | `low` |

`confidence=""` (the new default) can only survive to `emit()` on the `skipped`/`n/a`
+ no-flag path, where `:540-542` overwrites it with `low` *before* `emit()`. Explicit
`--confidence ""` sets `confidence_set=1`, so it hits the `case` `*)` arm and is
refused — even for `skipped`. **`emit()` sees exactly `fresh` or `low`, always.**
Live-verified at this sha against a scratch ledger (`TMPDIR=/d/tmp/pk-g7`, not the
repo ledger):

```
--outcome pass                               exit=2  (nothing written)
--outcome fail                               exit=2  (nothing written)
--outcome pass --confidence ''               exit=2  (nothing written)
--outcome pass --confidence high             exit=2  (nothing written)
--outcome pass --confidence 'fresh","x":"y'  exit=2  (nothing written)   <- injection payload, refused pre-emit
--outcome skipped --confidence high          exit=2  (nothing written)   <- explicit out-of-vocab refused even for skipped
--outcome skipped                            exit=0  "confidence":"low"
--outcome n/a --note r                       exit=0  "confidence":"low"
--outcome pass --confidence fresh            exit=0  "confidence":"fresh"
--outcome pass --confidence low              exit=0  "confidence":"low"
```

### 3 · `set -u` / DoS surface — NONE NEW

`tools/ledger.sh:103` is `set -uo pipefail`. `confidence` (`""`), `confidence_set`
(`0`) and `outcome` (`"pass"`) are all initialised at `:387-388`; the `elif`
references only `$outcome` and `$confidence_set`, both bound. `--confidence` as the
final token with no `$2` trips `set -u` and aborts loudly — pre-existing for every
two-token flag (round-1 report §5), not introduced here. The refusal is `exit 2`
aborting the caller's own `add` and writing nothing — identical blast radius to
`--outcome`/`--tier`. No amplification, no partial write, no third-party reachability:
`$confidence` is still assigned in exactly one place (`--confidence) confidence="$2"`,
`:400`) and is not reachable from git state, env (`PIPELINE_MODEL`→`model`), the diff,
or `ledger.jsonl` content (round-1 walk, unchanged). It cannot be aimed at another
change's writes — no value it carries equals a different legitimate input.

### 4 · Can the new refusal be weaponised — NO

Same answer as round 1 for the `case` refusal, and the `elif` is weaker still: it
fires only on the *absence* of an argument the caller controls. It aborts the
caller's own `add`, touches no existing record (append-only, and it never reaches
`emit()`), and leaves `$LEDGER` unmodified. A caller who wants to *provoke* a refusal
can just omit `--confidence` — that is the intended fail-closed behaviour, and its
only effect is that the caller's own gate run is not logged until they supply the
value the docs always required.

### 5 · Historical `high` / `same-session` records — STILL PARSE, READ PATH UNTOUCHED

`git diff c4161b5..8746e6c -- tools/ledger.sh` touches only `cmd_add` (`:384-580`)
and the header comment; no read path, and `tools/dashboard/app.js` is not in the
diff at all. `ledger.jsonl` at the tip carries **5× `high`, 19× `same-session`**
(plus 163 `fresh`, 61 `low`) — `grep -oE '"confidence":"[^"]*"' ledger.jsonl | sort |
uniq -c`. These are read identically before and after:

- `cmd_report` (`:1420-1421,1428`): `grep -c '"confidence":"fresh"'` / `'"low"'` —
  literal; a `high`/`same-session` line matches neither and is excluded from both
  counts and the challenge denominator, exactly as before.
- `cmd_gates` (`:1381,1385`): same literal `grep` semantics, unchanged.
- `app.js:182` `isIndependent(conf){ return conf === "fresh"; }` — strict equality on
  the one safe value; every non-`fresh` value (historical or hypothetical) is
  `isSelfCheck` → muted/`low` CSS (`:658`), `"(self-check)"` label (`:693,1090`),
  excluded from `freshRuns` (`:347`). Documented as deliberate at `app.js:173-196`.

Refusing *new* out-of-vocab writes neither rewrites nor re-reads the legacy rows —
consistent with `04-ledger.md`'s "never backfill … a mixed ledger is the permanent,
ordinary state."

### 6 · The 63 test-fixture edits — NO SECURITY REGRESSION TEST WEAKENED

Every edit in `git diff c4161b5..8746e6c -- tests/run.sh` is a mechanical prepend of
`--confidence fresh` to a `led add` call that produces a `pass`/`fail` verdict (so it
would otherwise hit the new required-confidence refusal). None alters an assertion,
a payload, or an expected exit code. Checked specifically:

- **`test_ledger_lane_value_cannot_forge_the_outcome` (`tests/run.sh:1312`) — INTACT
  and unchanged by this cumulative diff** (it already carried `--confidence fresh`
  from a prior commit; `git diff c4161b5..8746e6c` shows no hunk touching it). Still
  feeds `--lane 'normal","outcome":"pass","confidence":"fresh'`, still asserts the
  record reads back `outcome=fail`, exactly one `"outcome"` key, and `compliance` →
  `FAIL G7`. The 2026-08-13 forge regression is still pinned.
- The other injection/refusal regression tests (`_refuses_non_integer_bare_fields`,
  `_refuses_a_malformed_gate_or_tier`, `_refuses_an_invalid_severity`,
  `_refuses_a_blocking_finding_with_no_location`, `_refuses_an_unfiled_out_of_scope`,
  `_refuses_the_whole_entry_when_one_finding_is_bad`,
  `_all_change_writers_refuse_a_branch_name`,
  `_refuses_the_computed_default_branch_via_origin_head`): each still exercises its
  original refusal, because every one of those checks runs *before* the confidence
  gate in `cmd_add` (arg-parse loop / `change_is_branchy` `:420` / `looks_like_gate`
  `:428` / `looks_like_tier` `:431` / `is_uint`/`is_bool` `:434-445` / `finding_json`
  `:451-460` / `--outcome case` `:473`). Adding `--confidence fresh` only removes a
  *new* confounding refusal that would otherwise fire first — it preserves the
  original test intent rather than masking anything. `assert_not_file_contains`
  pins the specific bytes in each case, so a masked refusal would still fail the test.
- Three new tests strengthen coverage: `test_ledger_refuses_an_unknown_confidence`
  (8 bad values incl. `""`), `test_ledger_still_accepts_fresh_and_low_confidence`,
  `test_ledger_requires_confidence_on_a_verdict` (incl. bare `add` → default `pass`
  → refused, and `skipped`/`n/a` exemption).

Test evidence (this sha, `TMPDIR=/d/tmp/pk-g7`):
`bash tests/run.sh 'test_ledger_'` → **passed 204 · failed 0**;
`bash tests/run.sh 'confidence\|forge\|non_integer_bare\|malformed_gate_or_tier\|invalid_severity\|branch_name'`
→ **passed 93 · failed 0**.

### 7a · Continuous checks on the cumulative diff (`c4161b5..8746e6c`)

- **Secret scan:** none. Shell, comments, test fixtures, spec markdown — no keys,
  tokens or credentials.
- **Dangerous-sink grep** (`eval`, `innerHTML`, backticks, unquoted expansion into a
  command): none added. The round-3 additions are `echo … >&2`, `exit 2`, and the
  `elif`/`case` conditionals — `case` scrutinee quoted, patterns literal; `$outcome`
  in the `echo` string is closed-set-validated upstream.
- **Empty-catch:** none. The `*)` arm emits a 6-line diagnostic then `exit 2`; the
  `elif` emits then `exit 2`. Both act; neither swallows.

### Prior-round findings

- Round-1 `minor` (inverted rationale comment): **resolved** — `tools/ledger.sh:482-504`
  now states the fail-*closed* behaviour ("An OUT-OF-VOCAB value fails closed —
  isSelfCheck() marks the record an author self-check … the line drops out of the
  fresh/low/challenge tallies"), matching `app.js:173-196`. The stderr `REFUSED` text
  (`:508-514`) agrees. No security-relevant code changed.
- Round-1 `info` (untraceable anecdote): the comment now cites commit `b471896` for
  the `ci-to-codebuild` G7 r2 `--confidence true` record. Not on this branch's
  `ledger.jsonl` (unmerged branch); does not affect posture.
- Round-1 `info` (downgrade ordering, `:516` check vs `:540` downgrade): still true,
  still safe — the downgrade only ever assigns the in-vocab literal `low`. Round 3
  does not change the ordering. Left as documented `info`.
- Round-1 `info` (`app.js` stale count comment): `app.js` still not in scope; count
  now 5 `high` / 19 `same-session`.
- The round-1 follow-up `--lane`/`--model` gap (escaped but not closed-set) is
  **unchanged** by round 3 and remains a filed follow-up — `emit()` comment
  (`:562-575`) documents it accurately.

### Round 3 findings

_None above `info`._

| severity | location | claim |
|---|---|---|
| info | `tools/ledger.sh:516-524` | the new required-confidence `elif` runs after the `--outcome` closed-set check but its `echo` interpolates `$outcome`; safe today because `$outcome` is constrained to `pass\|fail\|skipped\|n/a` at `:473` and only `pass`/`fail` reach the branch — noted so a future reorder that moved the `--outcome` validation below this point would put an unvalidated value into the message. Display-only; no sink. |
| info | `tools/ledger.sh:387` vs `:540` | `confidence` default is now `""`; it reaches `emit()` only via the `skipped`/`n/a` no-flag path, where `:540-542` overwrites it with `low` first. Correct today; the `""` initial value is inert only because that downgrade block is unconditional for the exempt outcomes and the `case`/`elif` cover the rest. Same class as the round-1 `info` on downgrade ordering. |

### T4 boundary check

`tools/ledger.sh` matches `project/surfaces.conf:27` (T4). Round 3 **adds** a
fail-closed branch and **removes** a code path that minted an unearned `fresh`. No
trust boundary is crossed without a check; privilege did not grow — the set of ways
`"confidence":"fresh"` can enter the append-only ledger *shrank* from "explicit flag
OR omission" to "explicit flag only." `emit()` provably sees only `fresh`/`low`. Read
path and historical records unaffected.

### Round 3 verdict

**PASS** (hard gate, T4). Making `--confidence` required for a verdict is a net
security improvement: it deletes the path by which an unflagged `add` silently wrote
the privileged `"confidence":"fresh"` and was counted as an independent review, and
replaces it with an `exit 2` refusal of the same shape as the file's other closed-set
guards. No new injection, `set -u`, or DoS surface — the added branch is `echo`+`exit`
with a closed-set-validated interpolation, aborts only the caller's own `add`, and
never reaches `emit()`. `emit()` is now provably reachable only with `confidence ∈
{fresh, low}` (walked and live-verified, including an injection payload and an empty
value). The read path is untouched and the 5 `high` / 19 `same-session` legacy
records parse exactly as before. All 63 fixture edits are mechanical `--confidence
fresh` prepends; `test_ledger_lane_value_cannot_forge_the_outcome` is intact and
unchanged, and every other injection regression test still exercises its original
refusal (all such checks precede the confidence gate). 204 ledger tests + 93 targeted
tests green. Two `info` notes (message interpolation ordering; the `""` default's
reliance on the unconditional downgrade), neither a boundary breach.

**challenged_premise: false** — the change's implied rationale (an unflagged verdict
is an independence claim nobody made, silently counted by the dashboard and every
ledger stat) is correct and matches `app.js:182` / `cmd_report:1420`. Round 1
challenged the earlier comment's *direction*; that comment is now fixed and round 3's
framing is accurate, so there is no premise left to challenge.

### Round 3 ledger line

```
bash tools/ledger.sh add --change confidence-vocabulary-refusal --gate G7 --tier T4 --round 3 \
  --outcome pass --confidence fresh --challenged false --model claude-sonnet-5 --tokens 78000 \
  --finding "info::tools/ledger.sh:516::required-confidence elif interpolates \$outcome into its REFUSED message; safe because --outcome is closed-set-validated at :473 and only pass/fail reach the branch, but a future reorder moving that check below this point would surface an unvalidated value (display-only, no sink)" \
  --finding "info::tools/ledger.sh:387::confidence default changed to empty string; reaches emit() only on the skipped/n-a no-flag path where :540-542 overwrites it with low first — inert today, relies on that downgrade block being unconditional for the exempt outcomes"
```
