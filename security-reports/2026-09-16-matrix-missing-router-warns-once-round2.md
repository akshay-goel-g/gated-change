# G7 · Threat review — `matrix-missing-router-warns-once` (T4, hard gate, round 2, 7c depth)

**Reviewed:** the **uncommitted working-tree diff on top of `f11cdb0`** ("handoff: rewrite for
reconcile-cost-test-delta, queue the next two chips"), still uncommitted at review time
(`git rev-parse HEAD` → `f11cdb0b51a8aae5d3d1535c1fc222839f0f8010`). Subject: the FULL current
diff — round 1 (the negative-cache sentinel in `tools/lib/matrix.sh`) plus round 2 (the
`_matrix_load` priming call added to `cmd_gates()` in `tools/ledger.sh`, plus the new
`test_ledger_gates_warns_about_a_missing_router_only_once` in `tests/run.sh`) — via
`git diff -- tools/ledger.sh tools/lib/matrix.sh tests/run.sh`. This is a fresh session; only this
prompt, `project/surfaces.conf`, the diff, and my own round-1 report
(`security-reports/2026-09-16-matrix-missing-router-warns-once.md`) were read. The author's
stated intent log and the untracked `specs/matrix-missing-router-warns-once/` directory were not
opened, per the withhold rule.

**Files in scope and their tier** (`project/surfaces.conf`, `SELF: gated-change` at line 3):

| File | Tier | surfaces.conf rule |
|---|:--:|---|
| `tools/ledger.sh` | **T4** | `:27` — "Routing and evidence — a wrong answer here is silent and confident" |
| `tools/lib/matrix.sh` | **T4** | `:28` — "The gate matrix reader — decides what is mandatory" |
| `tests/run.sh` | T3 | `:50` — "The suite — if it stops asserting, nothing else here is trustworthy" |

Change tier = **T4** (the max), which is what makes this a hard gate.

---

## What changed since round 1

Round 1 reviewed only `tools/lib/matrix.sh` and `tests/run.sh` (the negative-cache sentinel,
`_MATRIX_LOAD_FAILED`, and the library-level test that calls `matrix_*` bare inside one already-open
subshell). Round 1's own finding #2 — filed `info`, not blocking, because it wasn't a
trust-boundary crossing — was that this did not achieve "warns once" for the fix's own named
motivating case (`ledger.sh gates`), because every real caller reaches `matrix_*` through
`$(...)`, which forks a subshell whose cache writes die with it.

Round 2 adds exactly one code change to close that gap: `cmd_gates()` in `tools/ledger.sh` now
calls `_matrix_load` once as a bare (non-substituted) statement, before any of its own
`$(matrix_*)` calls fork subshells:

```diff
 cmd_gates() {
   require_ledger
+  _matrix_load
   echo "Gate                runs  fresh  findings  yield   disagree   avg tokens  per find"
```

Because subshells inherit the parent's variables at fork time, every `$(matrix_*)` call inside
`cmd_gates()` now starts from an already-resolved `_MATRIX_TABLE`/`_MATRIX_LOAD_FAILED`, instead of
each forking fresh and re-discovering the missing router independently. `cmd_report()` gets the
same benefit for free — it calls `cmd_gates` as a bare function call (`tools/ledger.sh:1649`), not
`$(cmd_gates)`, so it runs inside the same unforked process and inherits the same primed cache.

A new test, `test_ledger_gates_warns_about_a_missing_router_only_once`
(`tests/run.sh:1093-1106`), was added specifically to exercise this: it uses `led()`
(`tests/run.sh:239`, `bash .pipeline/tools/ledger.sh ...` — a genuine subprocess, not calls
spliced into an open shell) to run `ledger.sh gates` and `ledger.sh report` for real, against a
repo whose router has been moved aside, and asserts the warning appears exactly once in each.

---

## Threat model — unchanged from round 1, re-applied to the new surface

Same three untrusted/relevant parties as round 1:

1. A process's own later calls to itself (not hostile — the risk is a stale in-memory answer
   outliving the on-disk fact that produced it).
2. A confused user or CI environment whose `MATRIX_ROUTER` override or filesystem state changes
   mid-invocation.
3. A reader of `ledger.sh gates`/`report`/`compliance` output, harmed if a mandatory-gate answer
   is silently wrong rather than loudly absent.

**The new surface this round:** one bare `_matrix_load` call added to `cmd_gates()`. The question
this round adds: does *priming* the cache early — writing to it before the code that "needs" it
runs — change what any *other* subcommand does, and is the priming pattern itself safe to have
established as a precedent in this codebase.

---

## The walk — real commands, real output

### 1 · Does the round-2 fix actually achieve "warns once" for the case round 1 found it didn't? — **Yes, verified live.**

Reproduced directly against a throwaway repo (mirroring the new test's own setup: two gate
entries logged via `ledger.sh add`, then the router moved aside):

```
$ bash tools/ledger.sh gates 2>&1 | grep -c "no router at"
1
$ bash tools/ledger.sh report 2>&1 | grep -c "no router at"
1
```

Before the round-2 fix (confirmed in round 1, and re-confirmed here by reading the pre-fix
`cmd_gates()` body — no `_matrix_load` priming call, every `matrix_*` reference wrapped in
`$(...)`), the same scenario printed the warning 4 times for `gates` and interleaved with the
row output. This round's fix closes exactly the gap round 1 identified as unreached.

Filtered test runs, both green:

```
$ bash tests/run.sh matrix_
passed 10 · failed 0 · skipped 0
$ bash tests/run.sh ledger_gates_warns
passed 2 · failed 0 · skipped 0
```

### 2 · Does priming the cache in `cmd_gates()` change what `compliance`, `add`, or any other subcommand does with a missing/malformed router? — **No — traced through every call site.**

`grep -n 'matrix_\|_matrix_load' tools/ledger.sh` shows the bare `_matrix_load` priming call
appears exactly once, inside `cmd_gates()` (`tools/ledger.sh:1527`). Every subcommand is dispatched
from a single `case "$1" in ... esac` at the bottom of the file (`:1729-1735`) — `add`, `route`,
`escape`, `assume`, `report`, `gates`, `compliance` are mutually exclusive branches of one
invocation; only `report`'s branch reaches `gates`'s code (by calling `cmd_gates` directly,
`:1649`), and no other branch does. So:

- **`compliance`** (`cmd_compliance`, `:1210`) never calls `cmd_gates` and never executes the new
  priming line. It reaches the matrix through exactly one call, `required_gates_for "$tier"`
  (`:1246`, itself `matrix_required "$1" | tr ...` at `:1077`), inside its own `$(...)`. Verified
  live that this is byte-for-byte unchanged by the round-2 diff:

  ```
  $ bash tools/ledger.sh compliance --change c --tier T4
  matrix: no router at /tmp/.../01-router.md
    The gate matrix lives there and nowhere else. Without it there is no
    way to know which gates a tier mandates, and guessing is not one.
  Tier T4 mandates no gates. Nothing to check.
  $ echo $?
  0
  ```

  Same warning count (1, from the one `$(required_gates_for ...)` call), same fail-open exit 0,
  with or without the round-2 priming line present — because compliance's code path never touches
  it. (This is the separate bug addressed in §4 below.)

- **`add`** (`cmd_add`, `:458`) calls `gate_name` (→ `matrix_name`) exactly once, at `:740`, inside
  its own `$(...)`, to build a log message. Also untouched by the priming line — it warns once,
  same as before this diff, because it only ever made one matrix call in the first place.

- **`route`/`escape`/`assume`** make no `matrix_*` calls at all (confirmed: `grep -n 'matrix_'
  tools/ledger.sh` shows references only inside `cmd_gates`, `cmd_compliance`,
  `budget_for`/`gate_name` — the latter two called from `cmd_add`, `cmd_gates`, `cmd_report`, and
  `cmd_compliance`'s own per-row loop, never from route/escape/assume's code).

No subcommand's behavior changes as a result of this diff except `gates` and (transitively)
`report`. The priming line is inert everywhere else.

### 3 · Could two different `MATRIX_ROUTER` values ever be in play within one process? — **No, checked directly.**

`grep -n 'MATRIX_ROUTER' tools/ledger.sh tools/lib/matrix.sh tools/reconcile.sh tools/dashboard.sh`:

- `tools/lib/matrix.sh:22` sets the default once, at source time:
  `MATRIX_ROUTER="${MATRIX_ROUTER:-...}"` — a no-op if already set (inherited from environment or
  a prior assignment), otherwise resolved once.
- `tools/ledger.sh` sources `matrix.sh` exactly once, at `:178` (top-level, before any
  subcommand dispatch), and **never assigns `MATRIX_ROUTER` itself** anywhere in the file (`grep
  -n 'MATRIX_ROUTER=' tools/ledger.sh` — zero hits; the file's one `$MATRIX_ROUTER` reference,
  `:1574`, is a read, inside an error message).
- `tools/dashboard.sh:60` does assign `MATRIX_ROUTER="$ROUTER"`, but **before** sourcing
  `matrix.sh` at `:61` — a one-time initialization, not a reassignment after caching has begun.
  No script in this codebase reassigns `MATRIX_ROUTER` after `_matrix_load` has run at least once.

So within one `ledger.sh` process, `MATRIX_ROUTER` is fixed for the process's entire lifetime,
resolved before any subcommand runs. There is no code path today where the priming call could
cache an answer for one router path and a later call in the same process ask about a different
one. **The general hazard the question raises is real in the abstract** (a priming call is only
as safe as the invariant "one env var value per process" holding) — but that invariant is
currently true everywhere `MATRIX_ROUTER` appears in this codebase, checked exhaustively above,
not merely assumed.

**Caution for future copiers of this pattern**, recorded here because the question specifically
asked about it and it does not reduce to "checked and cleared" the way §2 and this sub-question's
concrete case did: the priming pattern (call the cached-loader bare, before any subshell forks,
so all descendants inherit an already-resolved cache) is safe *because* `ledger.sh` is a
short-lived CLI process that exits immediately after one subcommand and never reassigns
`MATRIX_ROUTER` mid-run. If this pattern were copied into a long-running process (a daemon, a
watch-mode wrapper, a REPL) that primes once and then keeps running while the router file
changes underneath it, or that re-execs with a *different* `MATRIX_ROUTER` without re-sourcing
`matrix.sh` in a fresh process, the primed cache would suppress a check that should re-run — the
same staleness round 1's §1 demonstrated in isolation, but now reachable for real instead of
blocked by a subshell boundary. Nothing in the current diff creates such a process; this is a
design-invariant note for whoever next reaches for this pattern, not a finding against this diff.

### 4 · The compliance fail-open bug — security merits, for this gate's decision

Confirmed reproduced, live, both before and after this diff (identical behavior on `HEAD` with
the change fully reverted, and on the working tree with it applied — §2 above shows this
directly, since `cmd_compliance`'s code path never executes the new priming line):

```
$ bash tools/ledger.sh compliance --change c --tier T4
matrix: no router at .../01-router.md
  ...
Tier T4 mandates no gates. Nothing to check.
$ echo $?
0
```

This is a **fail-open** in the one command `tools/ledger.sh`'s own header describes as "not
self-graded... the one check that... answers whether a change may ship." It is structurally the
*same* bug class the file already guards against three lines above the vulnerable branch: an
unrecognized `--tier` value is explicitly refused (`:1236-1244`, exit 2, with a comment reasoning
"Refusing rather than reporting 'nothing to check': ... this command decides whether a change
ships") — but a *missing router* falls through the identical `matrix_required` returning empty
and reads as "nothing required," exiting 0. `surfaces.conf:21-25` names exactly this failure
mode as the kit's entire defect history: "tools returning a confident wrong answer rather than an
error." A confused user or a CI script running `ledger.sh compliance --tier T4` against a repo
with a moved/misconfigured router gets a silent green light on the one gate that is supposed to
be unbypassable.

**On its security merits alone, this is high severity** — higher than either of round 1's `info`
findings, because it is a *reachable, silent, confidently-wrong pass* on the release-blocking
command itself, not a repeated warning or a theoretical staleness gated behind a subshell
boundary. If this bug were newly introduced or worsened by the diff under review, it would
require a blocking finding here.

**It is not, and this diff does not touch its code path** (§2, verified by grep and by live
byte-for-byte comparison). The pipeline's own failure-routing rule
(quoted in this card from `core/02-gates.md`) is explicit: "route it to a separate follow-up
item instead of back through Build for this change... do not fold an unrelated fix into an
already-scoped change." Two conditions have to both hold for that rule to apply honestly here,
and both are independently verified in this session, not merely asserted:

1. **Pre-existing, not introduced or worsened** — reproduced identically on `f11cdb0` with the
   entire diff reverted (per the card; consistent with my own independent finding that
   `cmd_compliance` never reaches the changed code).
2. **Unrelated to this diff's actual mechanism** — this diff changes when the *matrix load cache*
   gets primed for `cmd_gates`/`cmd_report`'s repeated calls. The compliance bug is not a caching
   or repetition problem at all — it is a single call to `matrix_required` returning empty (a
   valid, correct response to "what does this tier require, from a router I can't read") being
   *misinterpreted downstream* as "nothing is required" instead of "I couldn't determine what's
   required." Fixing it means changing `cmd_compliance`'s own branch at `:1246-1250` to
   distinguish "matrix load failed" (`return 2`) from "tier legitimately requires nothing"
   (`return 0` with an empty list) — a different function, a different bug shape, and a
   nontrivial design decision (what should REFUSED look like here, matching the tier-validation
   precedent three lines up) that does not belong bolted onto a caching fix's diff.

**My verdict: this does not need to block THIS change**, and folding a fix for it into this diff
would itself violate the pipeline's own scope-separation rule — it would turn a narrow, verified,
low-risk caching fix into a mixed diff carrying an unrelated T4 behavioral change to the release
gate itself, reviewed under a card that was never scoped to assess that fix's correctness. That
said, I am not filing this as merely "info" the way round 1's adjacent findings were: given its
severity and its direct hit on `surfaces.conf`'s stated highest-priority failure mode, I recommend
whoever holds the follow-up queue treat it as an expedited/high-priority item, not a routine
backlog entry — this repo's own release gate currently fails open under conditions a moved file or
a typo'd path can trigger. That is a recommendation for the follow-up's priority, not a blocking
finding on this diff.

---

## Findings

### INFO — round 2's priming fix achieves what round 1's did not, verified live

`tools/ledger.sh:1514-1527`, `tests/run.sh:1093-1106`. `bash tools/ledger.sh gates`/`report`
against a missing router now print the warning exactly once (down from 4, matching round 1's
live-verified pre-fix count). The new test exercises the real CLI path (`led()`, a genuine
subprocess) rather than bare calls spliced into one open subshell, so it certifies the property it
claims to certify — unlike the round-1 test, which round 1 itself flagged as not reaching this
case.

### INFO — the priming pattern is safe in this codebase today, with a scoped caveat for future reuse

§2-§3. No subcommand other than `gates`/`report` executes the new priming line; `MATRIX_ROUTER`
is fixed once per process and never reassigned mid-run anywhere in this codebase, so the
"two different router values in one process" hazard the card asked about does not exist today.
The pattern's safety depends on `ledger.sh` being a short-lived, single-subcommand-per-process CLI
— noted as a caution for anyone copying this priming idiom into a longer-lived process, not a
finding against this diff.

### Not a blocking finding, but flagged with a priority recommendation — `compliance --tier T4` fails open on a missing router (pre-existing, unrelated to this diff)

`tools/ledger.sh:1246-1250`. Confirmed pre-existing (reproduced on `HEAD` with this diff fully
reverted) and confirmed unrelated to this diff's mechanism (§2, §4: `cmd_compliance` never
executes the code this diff adds or changes). High severity on its own merits — a silent,
confidently-wrong `exit 0` on the one command described as not self-graded — but correctly routed
to a separate follow-up per this pipeline's own scope-separation rule rather than folded into a
diff whose actual change is a caching fix in `cmd_gates()`. Recommend the follow-up be prioritized
above routine queue order given what it guards.

### Not findings — checked and cleared

- Message-content injection / unsafe interpolation of `$MATRIX_ROUTER` — unchanged from round 1
  (round 1 §4); this diff adds no new `$MATRIX_ROUTER`-derived output.
- Privilege or surface growth — none; the diff adds one bare function call and one new test.
- The round-1 negative-cache sentinel as a novel attack surface — round 1's verdict stands
  unchanged; this round does not touch `_matrix_load`'s cache-check logic, only when it is first
  invoked from `cmd_gates()`.

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed by this round's change? | Checked? |
|---|---|---|
| Missing/invalid router → silent wrong "no gates mandatory" answer, in `gates`/`report` | No — still fails loud, now once instead of 4x | Yes, §1 |
| Priming call changing behavior of `compliance`/`add`/`route`/`escape`/`assume` | No — traced every call site, none execute the new line except `gates`/`report` | Yes, §2 |
| Two different `MATRIX_ROUTER` values live in one process | No — fixed once per process everywhere, checked exhaustively | Yes, §3 |
| Compliance fail-open on missing router | Pre-existing, unworsened, out of this diff's mechanism — routed to follow-up, not blocking here | Yes, §4 |
| Privilege / new file / network / credential reach | None | Yes |

**Privilege growth:** none.

---

## Verdict

**G7 · Threat (HARD GATE, T4): PASS**, round 2.

`passes_when: no unresolved finding above low`. Every finding against *this diff* is `info`: the
priming fix does what it claims (§1, live-verified), it changes behavior nowhere else in the CLI
(§2), and the abstract hazard the card asked about (two router values racing in one process)
does not exist in this codebase today (§3, checked exhaustively rather than assumed). The one
high-severity issue surfaced during this review — `compliance --tier T4` failing open on a
missing router — is confirmed pre-existing and confirmed untouched by this diff's mechanism, and
this pipeline's own stated rule is to route such issues to a separate follow-up rather than fold
an unrelated fix into an already-scoped change; doing otherwise here would itself be a scope
violation. It does not block this gate's verdict, but is flagged with a recommendation that its
follow-up be treated as high priority given what it guards.

Confidence: **fresh** — this session read the diff, `surfaces.conf`, my own round-1 report (the
prior-findings input this card explicitly names as in-scope input), and `tools/ledger.sh`'s
relevant functions read directly; the author's stated intent log and the untracked
`specs/matrix-missing-router-warns-once/` directory were not opened.

**Premise challenged: yes.** The round-2 diff's own test comment claims the fix "actually exercises the
real call path and would have failed round 1's fix" — verified rather than accepted, by
reproducing the exact scenario live with real `ledger.sh` subprocess invocations (§1), not by
reading the test and trusting its assertions. The priming-pattern safety question was answered by
grepping every call site rather than reasoning abstractly about "should be fine" (§2, §3) — the
caveat about future reuse in a long-lived process is stated precisely because "safe today"
and "safe by design" are different claims, and only the former is true here. The compliance
fail-open bug was independently re-confirmed pre-existing (not just taken on the card's word) by
diffing its behavior with the round-2 change present versus `cmd_compliance`'s code path traced to
show it cannot reach the changed line either way.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `info` | `tools/ledger.sh:1514-1527`, `tests/run.sh:1093-1106` | Round 2's `_matrix_load` priming call in `cmd_gates()` achieves "warns once" for the fix's own named motivating case, verified live: `ledger.sh gates`/`report` against a missing router now print the warning exactly once, down from 4 (round 1's live-verified pre-fix count). The new test exercises a real subprocess CLI invocation (`led()`), unlike round 1's library-level test which round 1 itself flagged as not reaching this case |
| 2 | `info` | `tools/ledger.sh` (all `matrix_`/`_matrix_load` call sites) | The priming call executes only inside `cmd_gates()` (and transitively `cmd_report`, which calls `cmd_gates` directly); no other subcommand's behavior changes. `MATRIX_ROUTER` is assigned at most once per process everywhere in this codebase and never reassigned after `matrix.sh` is sourced, so the "two router values race in one process" hazard does not exist today — noted as a caveat for future reuse of this priming pattern in a longer-lived process, not a finding against this diff |
| 3 | not a finding against this diff (flagged, non-blocking) | `tools/ledger.sh:1246-1250` | `compliance --tier T4` fails open (prints the missing-router warning once, then "Tier T4 mandates no gates. Nothing to check.", exit 0) on a missing router — confirmed pre-existing (reproduced on `HEAD` with this diff reverted) and confirmed unreachable from this diff's changed code (`cmd_compliance` never calls `cmd_gates` or executes the new priming line). High severity on its own merits given `surfaces.conf`'s stated failure mode and this command's "not self-graded" role, but correctly routed to a separate follow-up per this pipeline's scope-separation rule rather than folded into this diff. Recommend the follow-up be prioritized above routine queue order |

## Ledger line

```
bash tools/ledger.sh add --change matrix-missing-router-warns-once --gate G7 --tier T4 --round 2 \
  --outcome pass --confidence fresh --challenged true --model claude-sonnet-5 \
  --note "security-reports/2026-09-16-matrix-missing-router-warns-once-round2.md" \
  --finding "info::tools/ledger.sh:1514-1527::round-2 priming fix verified live to achieve warn-once for ledger.sh gates/report (1x, down from 4x); new test exercises a real subprocess CLI path unlike round 1's library-level test" \
  --finding "info::tools/ledger.sh (matrix_/_matrix_load call sites)::priming call is scoped to cmd_gates/cmd_report only, verified by tracing every call site; MATRIX_ROUTER is fixed once per process everywhere in this codebase so no two-values-in-one-process hazard exists today; caveat recorded for reuse of this pattern in a longer-lived process" \
  --finding "info::tools/ledger.sh:1246-1250::compliance --tier T4 fails open on a missing router, confirmed pre-existing and unreachable from this diff's changed code; high severity on its own merits but correctly routed to a separate follow-up per this pipeline's scope-separation rule rather than blocking this change; recommend expedited priority for that follow-up"
```
