# 04 — The Ledger

> Portable. Do not edit.

Promotion, retirement, and every claim about a gate's value are unmeasurable without a
record. One line per gate run, appended to `.pipeline/ledger.jsonl`:

```json
{"date":"2026-08-09T14:32:07Z","change":"quota-daily-limit","tier":"T4","gate":"G7","round":1,"commit":"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678","kit":"1.0.0+3f9c21ab","findings":2,"outcome":"fail","confidence":"fresh","challenged_premise":true,"minutes":18,"tokens":110774,"model":"opus"}
```

| Field | Why it exists |
|---|---|
| `date` | A full UTC instant (`date -u +%Y-%m-%dT%H:%M:%SZ`), auto-written on every `add`/`route`/`escape` call. Lines written before this field was widened stay a bare day (`2026-08-09`) forever — **never backfilled** with a fabricated time, per "Keeping it honest" below — so a mixed ledger of both shapes is the permanent, ordinary state, not a migration to finish. Every reader treats it as an opaque, sortable string; string comparison and sort order hold across the mix because a full-instant value is just a bare-day value with more characters appended in the same left-to-right order |
| `tier` | Detects systematic under-classification when compared against reconcile results |
| `gate` + `findings` | Powers promotion and retirement |
| `outcome` | `pass` · `fail` · `skipped` (ran nothing, and said so) · `n/a` (the card does not fire here — accepted by `compliance` only where the router's cell carries a footnote, and only with a `--note` saying why) |
| `confidence` | `fresh` or `low` — a gate run in the authoring session does not count toward statistics. **Required for a `pass`/`fail`**: `ledger.sh add` refuses a verdict logged with an out-of-vocab value or none at all, because such a record reads as non-independent and silently drops out of every stat. `skipped`/`n/a` are exempt and default to `low`. (A value like that can still reach a hand-edited `ledger.jsonl`; the dashboard's strict `fresh` allow-list is the read-side backstop.) |
| `citation` / `evidence_cmd` / `evidence_exit` / `evidence_sha256` / `evidence_line_sha256` | **Optional, on a `gate` record.** What a pass cited: `--evidence file:line` (stored as `citation`; the file and line must exist) or an `EVIDENCE::<name>` line of `project/commands.conf` that `ledger.sh` ran itself (key, exit code, sha256 of the output, sha256 of the conf line). A fresh T3/T4 or untiered `pass` needs one of those or an `info` finding with a real `file:line`. Write-time only: older lines are not re-judged. Not to be confused with `evidence` on a `route` record |
| `challenged_premise` | Did this run contradict the author? Powers the disagreement quota |
| `model` | Which model graded this gate — the tier on the card's `model:` line. Warns when unset, because `08-models.md` specifies tiers that one real run ignored entirely while the ledger recorded nothing about it |
| `tokens` | What the run **cost**, total. See "Cost is a constraint, not an outcome" below |
| `tokens_in` / `tokens_out` | The same cost, split by direction. **Optional and paired** — `ledger.sh add` refuses one without the other, because the pair computes `tokens` (below), not because a lone value is meaningless on its own. When `--tokens` is not also given, `tokens` is computed as their sum, so a report or dashboard that only ever knew the aggregate field keeps working without a code change. When `--tokens` **is** also given, it must not be *less* than `tokens_in + tokens_out` (refused if it is) but **may exceed it** — a true billed total can legitimately include cost the split doesn't categorize, such as cache-read/cache-creation tokens |
| `minutes` | Wall clock. Kept for runs a human actually sat through; it is **not** a metric — no subagent run has ever populated it, and a check that cannot fire is worse than none |
| `lane` | `normal` or `hotfix` — emergency runs must not pollute yield statistics |
| `round` | Which pass this was. The failure rule sends a failed gate back to Build and re-runs it; without this, three rounds of one change are three indistinguishable lines |
| `commit` | What was actually reviewed. Auto-detected from `git HEAD` (the full sha; rows from before round 26 hold 7 characters), so it cannot be forgotten. An explicit `--commit` must name exactly one commit and is stored in full |
| `kit` | Which build of the kit produced this line — version plus a hash of `tools/`, auto-detected for the same reason `commit` is. An installed copy that had gone stale against the kit source once reported gates as `SKIPPED` that had actually **failed**, and the only thing that caught it was a human noticing the output disagreed with their memory. `compliance` now prints `KIT DRIFT` instead. It **shows** the drift and stops there — see below |

**Why `kit` never causes a skip.** The obvious next step is to key idempotency on it: same
diff, same tooling, don't re-run. Refuse that. On the first real end-to-end run, round 2 of a
change re-ran three gates that had already passed on round 1's fixes, and two of them found
new, real bugs *in those fixes*. A content hash is a better staleness signal than a round
number; it is not a licence for the tool to decide. Same call `gate_passed_round` already
made: an older verdict counts, its age is visible, and judging whether the age invalidates it
is the reviewer's job.

---

## Findings are objects, not a number

`findings: 2` says two things were found. It does not say what, where, or whether
either still matters — and a count cannot be read back, argued with, or shown to
anyone. Pass `--finding` once per finding and the substance survives as data:

```bash
bash tools/ledger.sh add --change quota-daily-limit --gate G7 --tier T4 --round 1 \
  --outcome fail --confidence fresh --challenged true \
  --finding "blocking::src/quota.js:88::read-time check passes for parallel requests; the ledger write is not atomic" \
  --finding "out-of-scope::src/billing.js:12::same pattern here, verified via git diff to be outside this diff; filed:ISSUE-412"
```

Each is `severity::location::claim`. The claim is greedy — it takes everything
after the second separator, so a claim containing `::` survives intact. Each row
also gets a **stable id**, `<change>-r<round>-<gate>-<n>`, computed when it is
written — so a later conversation can name a finding instead of re-describing it.

**An id is not a state.** Nothing here tracks whether a finding was fixed, and
that is a decision rather than an omission. The resolution record would be
written by the author, about the author's own fix, and would then be the obvious
thing to hand the next reviewer — which is exactly the anchoring the blind review
rule exists to stop. On the one run where this was measured, two fresh re-runs
found bugs *in the previous round's fixes* with zero overlap between rounds,
because neither was told what the previous round had found. "What is still open?"
is a real question and it has a home already: the handoff, and `project/risks.md`.

| Severity | Means |
|---|---|
| `blocking` | Forces a fix cycle. The gate fails and Build is returned to |
| `minor` | Real, non-blocking. Fix now or record why not |
| `info` | A disclosed observation. No action, but it was seen |
| `out-of-scope` | Real, and confirmed via `git diff` to be outside this change. Logs as a `fail`, routes to a separate follow-up — see the failure rule in `02-gates.md`. The claim **must** name where it went (`filed:<ref>`) or the entry is refused |

These four are the whole vocabulary, and they are on every gate card's
`severities:` line as well as here — a card is what a subagent is handed, and one
that had to infer the vocabulary invented `medium` and `low`, which no report can
group by. Anything outside the four is now **refused**, not stored.

**`location` is the evidence rule made mechanical.** Every claim about behavior
cites `file:line` or command output, including agreement — so a `blocking` or
`minor` finding with an empty location is **refused**, because `02-gates.md` says
a finding without a citation is *deleted, not softened*, and for a long time only
the doc said so. The same move as `withhold` on a gate card: a principle you have
to remember is one you will eventually skip.

**And `filed:` is the failure rule made mechanical.** `02-gates.md` sends an
out-of-scope finding "to a separate follow-up item"; nothing implemented that, so
they accumulated in the ledger and nowhere else. The gate that produces most of
them is the one this kit calls the most undervalued.

---

## Three record types

| Type | Written by | Holds |
|---|---|---|
| `gate` | every gate run | findings, confidence, minutes, whether it challenged you |
| `route` | `reconcile.sh --log` | predicted vs actual tier, and the verdict — plus `base` (the commit the change started from, which `compliance` binds gate records to; absent on older lines, which skip binding with a note) and `"restart":true` (on a round-1 route written with `--restart-lineage`, and on every later firing of a declared action on a change that already fired one, whatever its name, provided the route carries a base (recorded as round 1; the first firing on a change with only diff routes keeps its round unless it is given `--restart-lineage`, which is always round 1; a route with no base is advisory and starts nothing): each starts a new lineage, see README step 6 and the declared-events section; `base` is stored as the full sha, whatever spelling was given) and `action`/`evidence` when the route came from a declared event, not a diff |
| `escape` | you, when a defect surfaces post-release | the change that **introduced** it, and who found it |

**`action` and `evidence` on a `route` record** (`01-router.md`'s R0d): a diff-based
reconciliation and a declared-action one produce the same record type and the same
`predicted`/`actual`/`verdict` fields — a report reading the ledger should not need two code
paths to tell "this T4 verdict came from a diff" from "this T4 verdict came from a declared
event." The two extra fields are what make that distinction legible after the fact, and they
are present only together: `evidence` with no `action` names is evidence of nothing, and an
`action` with no `evidence` is exactly the unmeasured claim this file's whole design argues
against — `ledger.sh route` refuses either alone, the same shape as a `blocking` finding with
no `location` above.

```bash
bash tools/ledger.sh add    --change auth-refresh --gate G7 --tier T4 --outcome fail \
  --confidence fresh --model <name> --tokens 110774 --finding "blocking::src/auth.js:31::refresh token is not rotated"
CHANGE=auth-refresh bash tools/reconcile.sh T2 --log   # writes the route record for you
bash tools/reconcile.sh --action store-publish --evidence "https://play.google.com/console/…" --log
                                                   # a declared event, no diff — also a route record
bash tools/ledger.sh escape --change auth-refresh --found-by user --severity high
```

Every record above shares one `--change` name, and that is the only thing tying a route
record to the gate records for the same work. `reconcile.sh` takes the change name from the
`CHANGE=` environment variable (there is no `--change` flag there) and defaults it to the
current branch when `CHANGE=` is not set; on a **trunk** branch that default is a name
like `master`, which would collect reconciles from every change and correlate with none, so
`ledger.sh` refuses it. Set `CHANGE=<the-change>` (an `--action` run defaults to the action
name instead, which is already a real identifier).

`--change` on an escape names the change that **caused** the defect, not the fix. That link
is what makes the metric mean anything, and no git heuristic can infer it — nothing in
history distinguishes "escaped a gate" from "pre-existing bug newly discovered."

---

## The metrics, in two tiers

Everything here divides into *leading* (available now, tells you if the machinery is
working) and *lagging* (tells you if it is worth running).

### Leading — from day one

| Metric | Formula | What it tells you |
|---|---|---|
| **Reconcile miss rate** | under-classified ÷ all reconciliations | **The metric to watch in month one.** Above ~30% means routing is misfiring — surfaces are missing rules, or you tier low by habit |
| **Gate yield** | findings ÷ fresh-context runs, per gate | Which gates earn their budget. Drives retirement |
| **Challenge rate** | runs that contradicted the author ÷ fresh runs | 0% across ten runs means the gate is confirming, not reviewing |
| **Tokens per finding** | tokens ÷ findings, per gate | Which gates are expensive for what they return. The input to a model-tier argument (`08-models.md`) that is otherwise pure assertion |
| **Rounds per change** | max `round`, per change | Where the failure rule actually engaged. More than one round means a gate sent the change back and re-verified it — an arc a single-pass review cannot produce by construction |

### Lagging — the headline, and it takes months

**Escape rate** = defects found after release ÷ all defects.

Everything else in this kit is a means of moving it. If it does not fall, nothing else
matters — not token savings, not yield, not how good the process feels.

### Cost is a constraint, not an outcome

That last sentence is about what counts as **success**, and it stands: a cheaper pipeline
that ships the same defects has achieved nothing. It has been read as something else, though
— as licence not to *measure* cost at all — and it was written before anyone had.

Someone has now. One T2 change, three gates, two rounds: **≈1.04M tokens**, reconstructed by
hand from a terminal afterwards because no field held it. Within that, one gate's second
round cost 175k tokens for zero in-scope findings, on a model tier its own card did not ask
for.

**The aggregate hides which direction grew.** A provider prices input and output differently,
and the ratio between them is not a constant — a gate handed a large diff and asked for a
short verdict spends mostly on input; a gate handed a short prompt and asked for a full report
(Threat's `.pipeline/security-reports/<date>.md`, Ripple's coupling report) spends mostly on
output. Two runs with the same `tokens` total can be opposite in shape, and only one of them is
"the gate over-explained itself." `--tokens-in`/`--tokens-out` (optional, paired) record the
split when it is available; `tokens` keeps holding the total either way, so nothing that reads
the aggregate needs to change to keep working. This is the same kind of widening as `date`
above — a mixed ledger of total-only and split lines is the permanent, ordinary state, not a
migration to finish.

So: `tokens` is a **leading/budget** metric and never an outcome metric. It does not compete
with escape rate, it does not appear in any judgment of whether a gate is worth running, and
a cheaper number is not a better one. What it does is make the trade visible. `07-failure.md`
already concedes the shape of the risk for emergencies — "you cannot run eight gates, and
pretending otherwise is how a pipeline gets abandoned in its first fire" — and cost is the
same failure on a slower clock. **An unmeasured constraint is not a constraint you have
escaped; it is one you will hit without warning, and abandon the process over rather than
tune.**

`minutes` used to carry this job and could not. No subagent run has ever set it, so the
budget-overrun check hung off a field that was always zero — a check that cannot fire, which
this repo has elsewhere called worse than no check at all.

Two properties to be honest about:

**It lags.** You ship, users find things, you attribute them back. Expect ~3 months before
the number says anything.

**It cannot be computed retroactively.** An escape only means something relative to a gate
that *should have caught it*. A defect in code that never went through the pipeline is
baseline, not an escape — which is why `ledger.sh escape` warns when the named change has no
gate runs recorded. A pre-adoption rework rate (`tools/benchmark/`) is a different
measurement and does not convert into this one.

**So watch miss rate first.** If routing is wrong, every gate is running on the wrong
changes and escape rate will confirm that in a quarter — for free, three months early.

---

## What the ledger settles

None of these are knowable by argument:

- Which gates find things, and which are ceremony
- Whether Threat's findings are a subset of Peer's (the merge question)
- Whether predicted tiers match reality, and in which direction you err
- Whether a newly authored gate has earned mandatory status
- **Whether any gate has stopped disagreeing with you**

**A gate with no ledger entries did not run.** If this file is empty after a month, the
pipeline is not being used, whatever the documentation says — and that is a finding, not a
formatting problem.

---

## Keeping it honest

The ledger is self-reported, which means it is gameable. Two habits keep it useful:

**Record failures immediately**, before fixing them. A finding you fix in 30 seconds and never
write down is a finding the metrics never see, and those are exactly the ones that reveal
which gate is pulling its weight.

**Never backfill.** An entry written from memory a week later is fiction with a timestamp. A
missing entry is better than an invented one: missing data is visible, invented data is not.
