# Experiment 004 — result

> Per `design.md`'s pre-registration and `tools/benchmark/README.md`'s reporting
> format. Both arms are **sample builds for this benchmark only** — neither
> branch is merged. `sampleapp` worktrees: `sampleapp-wt-arm-g` (branch
> `experiment/arm-g-with-pipeline`, commits `6f675d7`→`6ad521e`→`88afd49`) and
> `sampleapp-wt-arm-h` (branch `experiment/arm-h-without-pipeline`, commit
> `88e5a66`), both off base `0df1b565`. New this pair: each arm was built
> end-to-end by its own subagent in a dedicated git worktree, rather than by
> the orchestrating session directly.

## TL;DR

**Arm G is the richest single data point this whole benchmark series has produced.** One T4 change went through three real correction cycles — a hard-gate security review that corrected the fix's own claimed severity, a peer review that caught a test proving nothing, and a second peer review that caught an *unverified claim inside the fix's own test* and got it settled empirically rather than re-argued from inspection. Zero of that happened before Build; all of it happened because verify gates ran and were taken seriously when they disagreed.

**Arm H is the cleanest "no-drama" result in the series** — the backlog description matched the code exactly, the one flagged trap didn't materialize, and a single competent pass produced a correct, tested, documented fix with zero back-and-forth. This is what "the no-pipeline arm doesn't need saving" looks like, as a contrast to arm B (pair 1) and arm D-vs-stale-candidates (pair 2).

## What was pre-registered vs. what happened

Both candidates held up exactly as pre-verified — no premise surprises this pair, unlike pairs 1 and 2. `design.md` predicted T4 (arm G, forced by touching `blocker.js`) and T3 (arm H). Arm G reconciled T4 three times in a row (once per commit) — reconciliation never drifted even as the diff grew across three rounds of fixes.

## Cost

| | Arm G (pipeline) | Arm H (no pipeline) |
|---|---|---|
| Commits | 3 (initial fix, gate-response round 1, gate-response round 2) | 1 |
| Gates run | 7 of 8 (G4, G5, G6 ×2, G7, G8, G1 inline) | 0 |
| Gate-minutes summed | 106 | 0 |
| Gate findings | 34 total across all runs | 0 |
| Gate failures requiring a fix cycle | 1 (G8 — but see scope note below; G4/G6's *first-round* findings were all non-blocking and addressed proactively, not as failures) | n/a |
| Tests added | 1 unit file rewritten + a diagnostic script + an e2e test rewrite | 1 unit file (new) |
| Unit suite | 135/135 suites, 2782/2787 (isolated a pre-existing, unrelated 5-test flake — confirmed via a clean worktree at the true base commit) | 136/136 suites, 2787/2787, fully green |

Arm G's cost is the highest of any single arm across all four pairs so far (106 gate-minutes, 3 commits, 34 findings) — but it's cost spent on a T4, forced-hard-gate change that went through genuine, substantive correction, not ceremony. Arm H's near-zero cost is not an artifact this time (unlike pair 2's arm D) — it's a real reflection of a small, well-scoped, single-pass fix.

## Findings — three correction cycles, not one

Unlike every prior with-pipeline arm in this series, arm G's value wasn't one gate catching one thing — it was a **sequence**, each round changing what the next gate had to review:

1. **G7 (hard gate) corrected the fix's own claimed severity.** The code comments and doc language called the bug "effectively unmanageable." G7 traced the actual DNR rule-building path and proved the built rule set is byte-identical whether an entry's category is an orphan id or `'custom'` — the real defect is labeling/manageability, not enforcement. This is a different flavor of value than any prior pair: not "the premise is wrong" (pair 1) and not "the fix has a gap" (pair 2, pair 3's arm E) — the *author's own understanding of what the bug was* was overstated, and it would have shipped into the permanent doc trail unchallenged.
2. **G6 caught a test that proved nothing** — an assertion true identically before and after the fix, because the thing it claimed to demonstrate (the entry becomes unmuteable) was never actually gated by the code path the fix touches. Same failure mode pair 2's arm C flagged as a risk, now directly observed: a test written from the *intended narrative* of a bug rather than from what actually discriminates the fix.
3. **G6's re-run caught an unverified claim buried in the fix's own new e2e test** — a comment asserting a storage-listener self-heal fires before a stale category can reach the write path, which the test's own assertions couldn't actually distinguish from the write-time coercion doing the work instead. Arm G's own response to this is the most interesting methodological note in the series: rather than re-read the code and argue from inspection again (exactly how the original wrong hypothesis had been formed), it wrote a throwaway diagnostic script to settle the question empirically. **This is a concrete instance of a lesson worth generalizing: a claim about runtime timing/ordering can't be settled by reading code a second time, only by instrumenting a real run.**

**G8's finding is its own case study in scope discipline.** Real-browser testing found three genuine bugs in the Allow Sites tab (group-rename corruption on acronyms, delete not live-syncing across tabs, a modal freezing a second tab) — verified, via `git diff`, to be entirely outside the two functions this arm's commits touch. Logged honestly as a gate `fail` (per the gate's own binary criterion — something surprised it) rather than reclassified to make the number look better, and filed as a separate follow-up task rather than fixed inline. This is the second time in this series (after pair 2's arm C) that an out-of-scope finding got this treatment, which is now a real, repeated pattern worth formalizing (see Harvest note below).

**Shift-left ratio: 0/34.** Every substantive finding across three rounds landed after Build. Combined with pair 3's arm E (also 0 before Build, but 3 real fail cycles after), a pattern is forming across this series: **premise-checking (G1a) is catching fewer things as candidates get pre-verified more carefully going in** (this pair had zero premise surprises, unlike pairs 1-2), **but the verify gates are catching more, and more substantively**, the deeper this benchmark goes. That may just mean later pairs' authors (increasingly capable subagents) write more complete-looking first passes that need real scrutiny to unravel — worth watching over more pairs.

## Escape rate

Not available, same as every prior pair — neither arm shipped. Arm G's G8 finding is the closest concrete illustration yet: had this shipped without Dogfood, three real, unrelated bugs in the same tab would have stayed unrecorded and unfixed, discovered only when a user reported them — not because this diff caused them, but because nothing else in the normal flow would have surfaced them either.

## Clean or muddy

**Clean**, genuinely, for the first time in this series without qualification. Both candidates reproduced exactly as pre-registered, sizes stayed roughly matched, and the cost difference (106 gate-minutes vs. 0) is entirely attributable to named, verifiable findings — no vague "felt more thorough," no candidate substitution saga, no size mismatch excuse needed.

## Harvest — a pattern worth formalizing

Two independent pairs now (pair 2's arm C, this pair's arm G) show the same shape: **a gate fails on a finding the author agrees is real but is definitively outside the diff under review**, and the right response — verified by `git diff`, not assumed — is to log the honest `fail`, file a separate follow-up, and not force an unrelated fix into an already-reviewed change. This is common enough now to deserve an explicit line in `docs/PIPELINE.md`'s failure rule (Part 2) rather than being independently reinvented per arm. Recommend for the next Harvest pass on `gated-change` itself.

## Process note

This pair also surfaced a real orchestration gap, not a pipeline-methodology one: nested subagent completions (an arm's own dispatched gate subagents) notified the top-level orchestrating session instead of the arm subagent that spawned them, stalling both arm G and arm E mid-flight until the orchestrator manually relayed every gate result back. Both arms explicitly logged this in their session records and treated relayed results as equivalent to direct ones (correctly — the fresh-context requirement is about who reviews, not how the report physically arrives) but it cost real wall-clock time waiting on a stall neither arm could see was happening. Worth its own note in a future Harvest pass, separate from anything about the pipeline itself.

## Honest limitations

- n=4 pairs now (8 arms total across the series). Still below the 6-pair threshold `tools/benchmark/README.md` asks for, but past it in arm-count.
- Arm G's cost figures aren't directly comparable to earlier with-pipeline arms — this is the first arm to go through 3 full correction cycles, which pair 1/2/3's single-or-zero-cycle arms didn't.
- The notification-routing stall (see Process note) inflated wall-clock for both arm G and arm E in ways unrelated to the pipeline's actual cost — noted so it isn't mistaken for the method being slow.

## Verdict

The strongest evidence yet that the pipeline's verify gates earn their cost on a real, non-trivial change: three substantive, independently-reasoned corrections on one T4 fix, escalating in subtlety (severity framing → test validity → claim verification), each one a defect a shipped version would have carried silently. Arm H shows the control arm isn't a strawman either — a well-scoped small fix needs none of this and correctly got none of it.
