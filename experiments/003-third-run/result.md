# Experiment 003 — result

> Per `design.md`'s pre-registration and `tools/benchmark/README.md`'s reporting
> format. Both arms are **sample builds for this benchmark only** — neither
> branch is merged. `sampleapp` worktrees: `sampleapp-wt-arm-e` (branch
> `experiment/arm-e-with-pipeline`, commits `08e12e8`→`d35b8ec`→`f221e8f`) and
> `sampleapp-wt-arm-f` (branch `experiment/arm-f-without-pipeline`, commit
> `0a7e505`), both off base `0df1b565`.

## TL;DR

**Arm E is the single most substantive with-pipeline arm across all four pairs run so far.** Three full review rounds, 10 fresh-context gate dispatches, 13 findings, and — uniquely in this series — a gate finding a **new bug the previous round's fix itself introduced**, proven algebraically rather than by inspection. This is the clearest demonstration yet of the failure rule working exactly as designed across more than one cycle, and it's a defect class (a live, periodically-recomputed formula silently behaving differently from a one-time computation using the identical expression) that a single-pass human skim would very plausibly have missed. The gates kept finding things until, on the third pass, one didn't.

**Arm F is the cleanest control-arm result in the series** — the backlog matched the code exactly, one clean pass, done in ~15 minutes, and it even surfaced a small latent display-bug fix as a side effect of doing the swap correctly.

## What was pre-registered vs. what happened

`design.md` predicted T3 for both candidates, and both reproduced exactly as pre-verified — no premise surprises. Arm E's own R0a Triage independently re-derived T3 before being told the prediction, then Reconcile mechanically hit T4 on all three commits — arm E judged this a `surfaces.conf` false positive (a filename-substring match on "session" in `02-focus-sessions.md`, not a real trust-boundary touch) and ran the full T4 gate set anyway rather than unilaterally downgrading. That's the correct call per the pipeline's "no cheating" principle, and it's also a real, load-bearing tooling finding — three identical mechanical misfires against one project's *unmodified example* `surfaces.conf` is exactly what `docs/PIPELINE.md`'s own reconcile-miss-rate metric exists to catch.

## Cost

| | Arm E (pipeline) | Arm F (no pipeline) |
|---|---|---|
| Commits | 3 (initial fix + 2 same-day gate-triggered fixes) | 1 |
| Gate dispatches | 10 (5 round 1, 3 round 2, 2 round 3) | 0 |
| Gate-minutes summed | 205 | 0 |
| Gate failures | 4 (G3 ×1, G4 ×1, G6 ×3 across rounds) | n/a |
| Findings | 13 | 0 |
| Tests added | break-pause-timer unit suite + e2e spec, expanded across all 3 rounds | 1 unit file |
| Unit suite | 134/134 relevant suites green (2 pre-existing flakes isolated) | 136/136 suites, 2787/2787, fully green |

Arm E's 205 gate-minutes and 10 dispatches make it the most expensive single arm in the series by a wide margin — and also the one with the most legitimate reason to be. Arm F took roughly 15 minutes end to end.

## Findings — the full arc

Round 1 (`08e12e8`) found the original fix's scope was too narrow: G3, G4, and G6 **independently, blindly** all converged on the same first gap (`popup.js`'s countdown missing the compensation), which is strong evidence the finding was real rather than gate noise — three separate fresh-context reviewers reaching the same conclusion from a cold diff read. G6 alone additionally found the most serious issue of the round: `state-recovery.js`'s resume-vs-completed classification ignored the compensation entirely, which could misclassify a still-legitimately-running layered session as "completed" too early.

Round 2 (`d35b8ec`, the fix for round 1) is the headline result. G3/G4 confirmed the round-1 fixes were genuinely correct — verified live in a real browser and by actually running the tests, not by trusting the commit message. **G6 failed again, but on a bug the fix itself introduced**: it proved algebraically that `blocked.js`'s new in-progress-break term made the displayed remaining time mathematically *constant* — the `now` term cancels exactly out of the formula — freezing the countdown for the entire duration of any break, in precisely the scenario the code's own comment claimed to handle. The arm's own author, who wrote both the original fix and its regression tests, notes candidly that their tests evaluated the formula at one `(state, now)` pair each — sufficient to prove "correct at this instant," structurally incapable of catching "frozen forever after."

Round 3 (`f221e8f`) closed the loop: G6 passed clean, independently re-verifying the fix (not trusting the diff), confirming two now-dead code guards were actually removed, and chasing one more lead (a script-load-order concern) all the way to ground before ruling it harmless. A fresh G8 — redispatched against the final commit after the original round-1 G8 dispatch never resolved through the session's relay path — delivered the single most convincing piece of evidence in the whole arm: real-browser confirmation that the popup and blocked-page timers agree to the second, sampled repeatedly across a live Static session *and* a live scheduled Automatic block, including across a full browser restart. It also surprised on 3 counts, but arm E's own scope triage (verified via `git diff`, matching arm G's precedent from pair 4) found 2 were pre-existing bugs unrelated to this diff (filed separately) and the third wasn't a new finding at all — it was G8, blind to the code, independently rediscovering the exact design tradeoff G6's round-3 review had just validated minutes earlier from the opposite direction (reading code vs. using the product). Two independent reviewers converged on the same conclusion about the same decision from opposite directions — recorded as corroboration, not a defect.

**Shift-left ratio: 0/13.** Every finding across all three rounds landed after Build — not because G1a failed, but because the defective code paths (popup.js, handleCompletedSession, recoverState, and later the freeze bug) simply didn't exist to inspect until Build produced them. Arm E's own record frames this precisely: "the gate ran at the wrong phase for this failure mode," not a critique of G1a. The far more informative number is qualitative — one round found bugs in the *original* code, the next found a bug in the *fix*, and this multi-round structure is something a single-pass review process cannot produce by construction, because there is no "round 2" without a gate that failed round 1 and forced a genuine return to Build.

Arm F, by contrast, needed zero rounds — `docs/V2-BACKLOG.md`'s description matched the code exactly, `GET_STREAK` already existed and was already used the same way elsewhere, and the fix was correct on the first pass. It's the first candidate across three pairs that needed no scope negotiation at all (see arm D's session record from pair 2 for the five-of-six-stale baseline this contrasts against). Notably, arm F's own author checked git history for a "fixed and reverted" pattern out of habit, even though nothing in the no-pipeline arm required it — a small, honest instance of pipeline discipline "leaking" into the control arm from having watched the pattern recur in earlier pairs.

## Escape rate

Not available, same as every prior pair. Arm E's round-2 finding is the most concrete illustration yet of what an escape would have looked like: a fix that visibly worked in every test written for it, shipped with a countdown that silently stops moving for the entire length of any break a user happens to load the blocked page during — the kind of bug that reads as "it's just frozen, huh" rather than an obvious crash, and would very plausibly have shipped past a single-pass review.

## Clean or muddy

**Clean**, same as pair 4 — both candidates reproduced exactly as pre-registered, no size mismatch, no candidate-substitution saga. The cost difference between arms is entirely attributable to named, traced findings, several of them independently corroborated by multiple fresh-context reviewers.

## Process notes (not about the pipeline itself)

- **The notification-routing stall recurred here too** (see pair 4's result for the first instance) — arm E's own record explicitly frames this as a process-tooling gap: a benchmark measuring with-pipeline cost needs a defined fallback for a dispatched gate that never resolves through the relay path, rather than an open-ended wait. Arm E's fallback (redispatch fresh against the latest commit) worked and, in this case, produced a *better* result than the stale dispatch would have.
- **Three separate spend-limit interruptions hit arm E mid-session**, each requiring a manual resume. None cost lost work (the worktree was always clean or fully intact at the interruption point) and none changed scope — but this is a real external cost this benchmark's token/dollar figures don't fully capture, and arm E's gate-minute totals likely undercount actual wall-clock spent recovering from these.

## Honest limitations

- n=6 pairs of arms now across the series (12 arms total). Approaching, not yet at, the 6-*pair* threshold `tools/benchmark/README.md` asks for (this is pair/experiment 3 of an eventual 6).
- Arm E's cost figures are the least comparable to any other single arm in the series — no other arm has gone through 3 full rounds. Averaging it in with lighter arms (pair 1's, pair 2's arm C at 1 round) would understate what a "hard" case actually costs.
- The T4-vs-T3 reconciliation discrepancy is a tooling artifact (unmodified example `surfaces.conf`), not a finding about the method's routing accuracy — noted so it isn't misread as a tier-prediction miss.

## Verdict

The single clearest evidence in this entire benchmark series that the pipeline's multi-round failure-and-reverify loop does something a one-pass review structurally cannot: it caught a bug in its own fix, not just in the original code, and closed it before anything shipped. Arm F shows the same thing pair 2's arm D showed — when a candidate is genuinely simple and well-scoped, the no-pipeline arm needs no rescuing and gets none.
