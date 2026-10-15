# 08 — Model and context strategy

> Portable. Do not edit.

Running every gate on the strongest model makes the pipeline too expensive to run; running
them all on the cheapest makes it too shallow to trust.

---

## Subagents are how fresh context happens

The blind review rule requires verify gates to run in a session that did not write the code.
**A subagent is the mechanism, not an optimisation.** It starts cold, sees only what you hand
it, and has no memory of defending an earlier decision.

**Hand a subagent:** the diff, the relevant registry section, the acceptance criteria.
**Do not hand it:** your explanation of what the change does, or your conclusion about whether
it is correct.

---

## Model tiers by gate

| Work | Model tier | Why |
|---|---|---|
| Continuous checks, secret scan, dependency audit, lint | **None — scripts** | Deterministic. An LLM here is slower, costlier, and less reliable than a regex |
| Routing, target matching, reconciliation | **Fast/cheap** | Pattern matching against a table |
| **G1 Intent, G2 Scout, G3 Craft** | **Mid** | Judgment, but recoverable if imperfect — and Intent's output is confirmed by the user before Build anyway |
| **G4 Ripple, G5 Proof, G6 Peer, G7 Threat** | **Strongest available** | Multi-step reasoning about non-local consequences. Where a weaker model quietly misses things — and a missing regression test is exactly that kind of miss |
| **G8 Dogfood** | **Whatever drives the interface** | The bottleneck is interaction, not reasoning |

**All eight gates are named here, and the same value is repeated on each card** (`model:`,
next to `budget:`). The chapter is the reasoning; the card is what the dispatcher actually
reads, and `08-models.md` is not a file anyone opens to answer a two-minute dispatch
question — this file says so itself, below. `tests/run.sh` keeps the two in step: a tier
stated in one place and not the other is the shape of defect this kit has already shipped
four times.

**The rule: spend on the gates whose failure mode is silent.** A weak model on Craft produces
an ugly button you will notice. A weak model on Threat produces a clean report and a hole.

**Tier by change tier too.** A T1 change warrants the strongest model on nothing; a T4 change
warrants it on every reasoning gate. Cost scales with what is at risk — the same principle as
the router.

**Record what you picked.** `ledger.sh add --model <name>` (or export `PIPELINE_MODEL`), and
it warns when you do not. Not bookkeeping for its own sake: on the first real end-to-end run
*every* gate including Dogfood was given the strongest model, against this table, and the
ledger read `model:"unset"` on every line — so the violation stayed invisible until someone
added the tokens up by hand afterwards, at which point Dogfood's second round had cost 175k
tokens for zero in-scope findings. **A spec with no field to check it against is a
preference.** Pair it with `--tokens` and the two together turn "which tier should this gate
use" from an argument into a measurement.

---

## When to ask which model

Ask rather than assume when **any** hold:

- The change is T4 and reasoning gates are about to run
- Two models have already disagreed on this change
- The task is ambiguous enough that a wrong answer is expensive to detect
- There is a stated cost ceiling for this work

Otherwise pick from the table and **say which you picked**. Asking about every routine choice
is its own friction.

---

## Re-checking the mapping when a model changes

The table above names **tiers**, not models, on purpose: "strongest available" and "mid" are
relative, so a new release moving a gate from Opus to Sonnet is never a doc edit here — it is
just a different answer to a question this file already asks. But nothing fires when a model
actually ships, so the mapping only gets rechecked when someone happens to remember, which is
the same failure mode `04-ledger.md`'s `model:"unset"` incident describes for a different field.

**Trigger:** a new model version becomes available that could plausibly satisfy a tier this
project uses. Recheck at the next T3+ change that would route to the gate in question, not
mid-flight on one already running — a standing check, not a stop-the-line event.

**What "recheck" means, mechanically:** run the same gate fresh-context on the candidate and
on the current pick, against a change that already needs that gate — not a synthetic
benchmark, which tends to flatter whichever model the benchmark was designed around. Log both
with `--model` naming which is which, and with `--tokens-in`/`--tokens-out`
(`04-ledger.md`) rather than one aggregate number: a cheaper model that needs another
round-trip to reach the same finding has not necessarily gotten cheaper, and the split is what
tells the two apart instead of a single total doing so by coincidence.

**Demote only on evidence, and only in the direction the evidence points.** A gate moves to a
cheaper tier under the same rule `06-extending.md` already uses for retirement: findings match
across fresh-context runs, not "the new one seems fine." A vendor price change alone, with no
capability change, is not grounds to move the tier — cost per finding did, capability
per gate did not, and the table is judging the latter.

---

## Context window discipline

A gate that receives the whole repository has not been focused; it has been buried. Relevance
decays as context grows, and the registry entry that mattered is competing with forty files
that did not.

| Gate | Should receive | Should not receive |
|---|---|---|
| Router | changed file paths, the axis tables | file contents |
| Ripple | the diff, registry sections whose triggers matched | unrelated features |
| Peer | the diff, the house rules | the conversation that produced it |
| Threat | the diff, trust-boundary surfaces, prior findings | the author's threat assessment |
| Dogfood | the running product | the source code |

**Two rules:**

1. **If a gate needs more context than fits comfortably, the change is too big.** Split the
   change, not the review. A diff that cannot be reviewed in one pass cannot be reasoned
   about in one pass either — by a model or a person.
2. **Load documents by purpose.** This is why `core/` is split into numbered files: the router
   needs `01`, Ripple needs `03`. Loading everything to answer a two-minute routing question
   spends the window on text that will not be used.
3. **The same discipline applies to the session driving the pipeline, not only to a single
   gate's input.** A fresh-context subagent gets a clean window by construction; the session
   running Router/Triage/Build across several changes in one sitting does not — its own
   relevance-per-token falls the same way a bloated gate's does, just slower. When it has been
   carrying several changes' worth of history, start the next change (or the next round) in a
   new session rather than pushing through in the old one. This is operator discipline, not a
   gate: it fires on no trigger and produces no artifact, so `06-extending.md`'s criteria
   score it zero — it belongs here, not as an authored gate or a standalone tool.

---

## Scale ceilings

Every resource has a limit, and the undocumented ones are discovered in production. Document
the ceiling wherever a resource accumulates — record yours in `project/ceilings.md`:

| Resource | Ceiling | Where enforced |
|---|---|---|
| Collection sizes with no pagination | | |
| Platform-imposed API limits | | |
| Storage quotas and write-rate limits | | |
| Queue depth, retry backlog | | |

**A ceiling not enforced in code is a ceiling that will be exceeded.** Document it, assert it,
and test the boundary — the interesting bug is always at `limit` and `limit + 1`, which is why
Cardinality is the first row of the edge decision table.
