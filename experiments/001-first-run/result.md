# Experiment 001 — result

> Per `design.md`'s pre-registration and `tools/benchmark/README.md`'s reporting
> format. Both arms are **sample builds for this benchmark only** — neither
> branch was merged, and neither is intended for release. `sampleapp` branches:
> `experiment/arm-a-with-pipeline` (commit `c696324`) and
> `experiment/arm-b-without-pipeline` (commit `8e560aa`), both off the same
> base commit `0df1b565`.

## TL;DR

Both features' backlog descriptions were **stale or wrong** in a way that mattered — this wasn't planned, it's what the trial actually surfaced. The one thing that differed cleanly between arms was *when* that got caught:

- **Arm A (with pipeline):** caught before Build, in ~8 minutes, by G1 Intent, at zero code cost.
- **Arm B (without pipeline):** caught only after Build, when 4 pre-existing tests failed — after the fix, two new tests, and a doc update already existed.

That is the pipeline's central shift-left claim, and on this one trial it held. It is **one paired trial** — per `design.md` and the benchmark README, that's an anecdote, not evidence. Six pairs would be evidence.

## What was pre-registered vs. what happened

`design.md` predicted Arm A would be T4 (rule-id overflow) and Arm B would be T2/T3 (schedule validation). That held — R0b reconciled Arm A at T4==T4 (match). Arm B, having no Triage, has no tier to check against.

**Not predicted:** that *both* backlog items would turn out to misdescribe the current codebase. `design.md`'s "clean vs. muddy" criteria didn't anticipate this — it expected either a clean shift-left win or a "turned out trivial/oversized" muddiness. What actually happened is closer to clean than muddy: the size match held (both were real, bounded, single-function changes once correctly scoped), and the cost difference is directly attributable to one identifiable gate (G1), not vague "felt more thorough."

## Cost

| | Arm A (pipeline) | Arm B (no pipeline) |
|---|---|---|
| Wall-clock | ~17 min | ~11.5 min |
| Gates run | 6 of 8 (G2/G3 correctly skipped — not net-new capability, no UI surface) | 0 (by design) |
| Tests added | 2 unit | 5 unit + 1 e2e (+ 2 existing tests reconciled) |
| Interventions | 1 (user redirected scope after Triage) | 0 from user; 1 self-correction mid-build |
| Unit suite | 2784/2784 green | 2787/2787 green |

Arm A cost about **50% more wall-clock** for **6x the review surface** (6 gates vs. 0) and found 4 findings to arm B's 1. That ratio looks better for the pipeline than it should honestly read, for one reason:

**The wall-clock numbers are not directly comparable, and this is the single biggest caveat in this result.** Arm A's four fresh-context gates (G4/G6/G7/G8) ran as **parallel background subagents**, so their ~72–170s each mostly overlapped with Arm B's build rather than adding serially to Arm A's timeline. A pipeline run by a human review team — the setup `docs/PIPELINE.md` and `tools/benchmark/README.md` were actually written for — cannot parallelize four people's attention for free the way an agent session can. The *token* cost is the more honest proxy for what this pipeline actually costs in an agent-run context: the four subagents alone consumed **~433,000 tokens**, a number with no equivalent in a human-run version of this same process, and one the session-record template (built for human/IDE-metered sessions) has no field for.

**Net:** on wall-clock alone, this trial *undersells* the pipeline's real cost. On token cost, it's the opposite — a number a human-run pipeline would never show at all. Neither arm's cost figure should be read as "the" cost of the method; they're both artifacts of running this specific comparison with an agent.

## Findings — the shift-left result

| | Arm A | Arm B |
|---|---|---|
| Findings before Build | 1 | 0 |
| Findings after Build | 3 | 1 |
| **Shift-left ratio** | **25%** (1/4) | **0%** (0/1) |

The single most valuable finding in either arm was Arm A's: G1 Intent, run before any code existed, discovered that the literal backlog text ("blocklist overflows past 1000 entries") does not reproduce — `buildPermanentBlockRules()` has been double-defended (write-time cap + build-time `.slice(0,1000)`) since the file was created. A literal build would have added a **no-op** — a second, redundant slice on an already-capped array — and reported "fixed" with nothing having changed. G1 rescoped to the real, currently-undefended analog (the whitelist twin, already flagged in this repo's own `CLAUDE.md` as "reported but NOT fixed") before writing a line of code.

Arm B hit a structurally identical problem — the backlog item asked for a per-level focus-duration cap that had been **built once, and then deliberately removed** (commit `f24aee1`), with two tests explicitly pinning "no level cap" as intentional. Arm B has no gate that reads the backlog against the codebase before Build, so this surfaced only when 4 pre-existing tests failed at the ordinary "run the full suite" step in CLAUDE.md's house rules — after the fix, 6 new tests, and a doc update already existed. The fix that landed **silently reconciled** the conflict (updated the two pinned tests) rather than routing it to a product decision, which is the exact failure `docs/PIPELINE.md`'s Ripple edge-decision table names: *"if the correct behavior is a product decision rather than a technical one, it goes to the person who asked — it is not guessed."* That happened here specifically because this is a non-shipping sample; in a real build, silently overriding two tests that document a considered decision would itself be a defect, pipeline or not.

**Tier accuracy:** 1/1 reconciliations matched (100%) — too small an n to say anything about routing accuracy generally; recorded for the ledger's sake.

**Challenge rate:** Arm A's fresh-context gates disagreed with the author (in some form) in 3 of 4 fresh runs (75%) — G4 and G6 both independently proposed the same additional line (a `console.warn` on truncation) that wasn't in the original diff, and G1 rescoped the entire premise. G7, the hard security gate, agreed cleanly (0 findings) — expected and correct for a well-defended change, not evidence the gate is idle.

## Escape rate

**Not available, and cannot be made available from this trial.** Per `tools/benchmark/README.md`, escape rate requires the change to actually ship and ~3 months to elapse. Neither branch shipped — that was explicit going in ("we are not going to integrate this feature, this is for pure testing"). If Arm B *had* shipped as built, the two overridden "no cap" tests describe a plausible real regression: users on lower levels who could previously schedule long focus blocks would suddenly be refused, with no changelog entry and no product decision on record reconciling it with the original removal. That is exactly the class of defect this pipeline's Threat/Ripple gates are built to catch before release — but it's a informed guess, not a measurement, and is reported as such.

## Clean or muddy, per design.md's own bar

**Mostly clean.** The cost difference is attributable to a named gate (G1), not vague thoroughness. Both features stayed at their expected size once correctly scoped — no re-scoping mid-build inflated either arm. The one thing `design.md` didn't anticipate and should be named honestly: **the comparison ended up testing "does the pipeline catch a bad premise" rather than "does the pipeline catch bugs in a correctly-scoped feature."** That's a real and valuable result, but a different question than the one `design.md` set out to answer, and it happened by discovery, not design — both backlog items turned out to be stale for reasons unrelated to which arm they were assigned to (assignment was a coin flip recorded before either build started, per `design.md`).

## Honest limitations

- **n = 1 pair.** Nothing here is a claim about the method generally — see `tools/benchmark/README.md`'s own warning against over-trusting a single paired trial.
- **Agent-run, not human-run.** Both the wall-clock advantage (parallel subagents) and the token cost (no human equivalent) mean this trial measures "the pipeline as run by one AI session," not "the pipeline as designed" — which assumes a human review team and a different cost model entirely.
- **Observation effect.** Both of us knew this was a benchmark. Arm A's process may have been more careful than a routine T4 change would get in practice; arm B's "self-correction" (silently overriding two pinned tests) might have gone differently under real shipping pressure with a real stakeholder to ask.
- **The two findings aren't the same size.** Arm A's finding fully resolved before Build cost nothing. Arm B's finding cost a full build-test-fail-reconcile cycle. That asymmetry is the headline number, but it rests on two different bugs in two different files, not a controlled apples-to-apples defect.
- **Escape rate, the actual headline metric this whole benchmark exists to move, has zero data points** and will continue to have zero for as long as neither arm ships.

## Verdict

On this one trial: the pipeline's shift-left claim held, at a cost this trial cannot cleanly price (wall-clock understates it, tokens overstate it relative to a human-run process). Worth running five more pairs, alternating which arm gets the pipeline, before concluding anything about the method rather than about these two bugs.

## Harvest

Per `docs/PIPELINE.md` Part 3, a T3/T4-shaped finding feeds back into the method, not just
into a report. Three changes landed in `gated-change` as a direct result of this trial —
full detail in `../../LEARNINGS.md`:

- A new universal coupling entry (`core/03-registry.md`) and a G1a Intent requirement
  (`core/cards/G1-intent.md`) — a described defect gets checked against current code, and a
  requested behavior gets `git log -S` checked against removal history, before scoping.
  Directly addresses this trial's headline finding.
- `tools/reconcile.sh` had a real bug (found by using it, not by reviewing it) that silently
  dropped uncommitted and untracked changes under exactly the conditions R0b normally runs in.
  Fixed and verified.
- `tools/benchmark/session-record.md` and this file's own README gained fields/notes for
  subagent token cost and gate-minutes-vs-wall-clock, since neither existed anywhere before
  this was the first trial actually run by an agent.
