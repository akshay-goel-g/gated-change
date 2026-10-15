# Experiment 002 — result

> Per `design.md`'s pre-registration and `tools/benchmark/README.md`'s reporting
> format. Both arms are **sample builds for this benchmark only** — neither
> branch is merged. `sampleapp` branches: `experiment/arm-c-with-pipeline`
> (commits `2c0170b`, `7a04dc5`) and `experiment/arm-d-without-pipeline`
> (commit `6e27f5c`), both off base `0df1b565`.

## TL;DR

Two different things happened, and both are useful:

1. **Arm C's G8 Dogfood gate caught a real bug the fix itself introduced** — not a stale premise this time, but an incomplete first pass. The shipped version of Arm C is materially different (and correct) because a gate ran, not because the process was skipped.
2. **Arm D's candidate never got assigned as pre-registered** — the designated feature, and three backup candidates after it, all turned out already fixed on inspection. This happened in the *no-pipeline* arm, using the exact discipline pair 1's Harvest pass added to G1a — proving that discipline doesn't require the pipeline to apply, just the habit of checking. What actually shipped in Arm D (dead-code removal) is much smaller than pre-registered, a real size mismatch `design.md`'s own "muddy" criteria anticipated.

Also: two branch-tracking mistakes happened mid-session (Arm D's build briefly landed on `main`), both self-caught and fixed. Recorded honestly below, with a process recommendation.

## What was pre-registered vs. what happened

`design.md` predicted Arm C (T3) and Arm D (T4, subdomain bypass). Arm C reconciled exactly as predicted (T3==T3, twice — once per commit). **Arm D's premise did not survive contact with the code**: the designated candidate, "Subdomain Variants Can Bypass Permanent Blocks," was already fixed — `isPermanentlyBlocked()` already does subdomain matching, its own docstring is simply stale. Two more backlog items checked as replacements were *also* already fixed, and a fourth was oversized. The fifth candidate (Grace Period Alarm Dead Code) was the first to reproduce as described, and even that turned out to be an *incomplete* prior cleanup rather than the exact shape described.

This was not predicted by `design.md`, which expected the size-mismatch failure mode (already seen in pair 1) but not five-of-six-candidates-stale in one backlog section. That's now confirmed as a property of `docs/V2-BACKLOG.md`'s Security Hardening section specifically, independent of anything about the pipeline.

## Cost

| | Arm C (pipeline) | Arm D (no pipeline) |
|---|---|---|
| Wall-clock | ~25 min (overlapping with candidate search) | ~5 min build, once a candidate was locked in |
| Gate-minutes summed | 109 | 0 |
| Gates run | 8 (4 first pass + 4 re-run after a failure) | 0 |
| Subagent tokens | ~588,000 | 0 |
| Tests added | 9 (unit + e2e, across two commits) | 0 (dead-code removal, no behavior to test) |
| Unit suite | 2786/2786 green | 2782/2782 green |
| Gate failures | 1 (G8, fixed same session) | n/a |

Arm C's cost is real and roughly 35% higher in subagent tokens than pair 1's with-pipeline arm — because a gate found a genuine defect and triggered a full fix-and-re-verify cycle, not just more review volume. That's the cost structure the pipeline's design assumes exists: most changes cost the base gate budget, some cost more because a gate actually did its job.

Arm D's near-zero cost this pair is not representative of "no-pipeline cost" generally — it's representative of a change that ended up trivial after four rounds of premise-checking that happened *outside* any formal process, which itself has an uncounted cost this record doesn't capture cleanly (see Limitations).

## Findings — a different flavor of shift-left

Pair 1's headline was catching a bad premise *before* Build (arm A, G1, 100% shift-left). Pair 2's headline is different: **G8 Dogfood caught a real regression in the fix itself, after Build, and the fix was corrected same-session.** Zero of Arm C's substantive findings landed before Build this time (G1 found the premise sound), but the single after-Build finding was higher-stakes than any single finding in pair 1 — it was a case where the fix, as first written, would have shipped a *worse* version of the exact bug it was supposed to solve (Stop silently not working, instead of Automatic silently not resuming).

**Challenge rate this pair:** 3 of 8 gate runs disagreed with something (G4 twice with minor notes, G6 twice — once minor, once a real out-of-scope finding, G8 once with a FAIL). That's a healthy rate, and importantly includes one genuine FAIL, which pair 1 never produced — this is the first data point in either experiment that a gate's stop authority isn't just theoretical.

**Tier accuracy:** 2/2 reconciliations across this pair matched prediction (T3==T3, checked twice as the diff grew). Combined with pair 1's 1/1, that's 3/3 across both experiments — still far too small an n to say anything about routing accuracy, but zero misses so far.

## Escape rate

Not available, same reasons as pair 1 — neither arm shipped. Arm C's G8-caught bug is the closest thing either experiment has produced to a concrete "what an escape would have looked like": had this shipped without Dogfood, a user layering a manual session over an automatic schedule would have found their Stop button didn't work, discovered it by watching blocking silently resume, and had no error message or log to explain why.

## Clean or muddy

**Muddy, honestly** — for reasons `design.md` mostly anticipated. Arm D ended up far smaller than the matched pair intended, for the new reason pair 1's Harvest pass named (stale backlog) rather than the original reason (oversized scope). The comparison this pair actually supports is narrower than "pipeline vs. no-pipeline cost for a matched pair" — it's closer to two separate, still-useful data points: "what does a gate catch when the premise IS sound" (Arm C) and "what does careful premise-checking cost outside a formal process" (Arm D, partially).

## Process mistakes — a pipeline-tooling lesson, not just a session note

Two branch-tracking errors happened this pair, both from the same root cause: running two arms' work interleaved in one working tree (switching branches to investigate Arm D while Arm C's background gate subagents were still running against a *different* checked-out branch), and losing track of which branch was current before an edit or commit. Both were self-caught by inspecting `git diff`/`git log` before trusting a commit, not by any gate — this is exactly the kind of mechanical mistake a gate doesn't cover and a git hook could.

**Recommendation for gated-change, not yet implemented:** when running paired-trial arms with background gate subagents in flight, use a separate git worktree per arm (`git worktree add`) rather than branch-switching in one working tree. This was pair 1's implicit approach (each arm was built and gated to completion before switching), but pair 2's overlapping gate-wait time made checking out other branches mid-flight tempting, and that's exactly when the mistake happened twice. Worth a line in `tools/benchmark/README.md`'s Study 3 section.

## Honest limitations

- n=2 pairs now. Still far below the 6 `tools/benchmark/README.md` asks for.
- Arm D's near-zero cost this round is an artifact of the candidate hunt landing on a trivial fix, not evidence that no-pipeline builds are generally cheap.
- The G8 failure-and-fix cycle in Arm C is a genuinely different kind of data point than anything in pair 1 — good, but it means pairs 1 and 2 aren't measuring quite the same thing, which limits how much a "trend across pairs" claim can say yet.
- Observation effect still applies to both arms, as always.

## Verdict

Two real, different lessons this pair: a gate catching a real defect in its own fix (Arm C), and a discipline (check the premise before committing to scope) proving valuable even without formal gates around it (Arm D). Neither is the clean cost comparison `design.md` set out to run — that comparison needs a pair where both candidates hold up as pre-registered, which hasn't happened yet in 2 tries. Worth trying again with candidates pre-verified even more carefully before pre-registration, and worth adopting the worktree-per-arm recommendation before pair 3.
