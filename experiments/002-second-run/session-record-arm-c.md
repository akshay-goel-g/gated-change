# Session record — Auto-Resume After Static Ends During a Scheduled Block

> Arm C of experiments/002-second-run. Sample build — not intended for release.
> `sampleapp` branch `experiment/arm-c-with-pipeline`, commits `2c0170b` then
> `7a04dc5` (same-day follow-up fix), off base `0df1b565`, never merged.

| | |
|---|---|
| **Date** | 2026-08-10 |
| **Change** | `stopFocusSession()` resumes Automatic via `reconcileScheduleState()`; manual stops of a layered session correctly suppress (follow-up fix) |
| **Arm** | pipeline (with-pipeline) |
| **Predicted tier** | T3 |
| **Reconciled tier** | T3 (match, re-run after the follow-up commit — still match) |

## Cost

| Metric | Value |
|---|---|
| Tokens in / out | Not exposed to the primary session (same limitation as pair 1). |
| Subagent token cost | 7 gate subagents this round (4 first pass + 3 re-run after the G8 fail): G4 83,727 + 165,916 (2 runs) + G6 84,759 + 92,379 (2 runs) + G8 72,797 + 88,232 (2 runs) + G4 second-run/G6 second-run counted above ≈ **~588,000 tokens total** across all gate subagent calls this arm. Materially higher than pair 1's arm A (~433K) because a gate failure triggered a real re-run cycle, not just more gates. |
| Wall-clock minutes | ~25 min (15:02–15:27), but this includes time spent investigating Arm D candidates while Arm C's gates ran in the background — the two arms' timelines overlap and aren't cleanly separable this round. |
| Gate-minutes, summed | G1 6 + G4 17+15 + G5 12 + G6 14+18 + G7 (not required at T3, skipped) + G8 12+15 = **109 min** of gate effort, mostly parallelized against wall-clock via background subagents. |
| Interventions | 0 from the user. 1 real mid-pipeline correction: G8 found a genuine bug the first version of the fix introduced (see Findings) — this is the pipeline catching its own author's incomplete first pass, exactly as designed, not an intervention from outside the process. |
| Gates run | 6 of 8 required-or-checked: G1, G4 (x2), G5, G6 (x2), G8 (x2). G7 correctly not required (T3, no new trust boundary/input/persistence path). G2/G3 correctly skipped. |

## Findings

| Gate | Findings | Before/after Build | Challenged premise? |
|---|---|---|---|
| G1 Intent | 0 — requirement verified reproducible before Build (confirmed `stopFocusSession` never called the reconciler) | Before | No |
| G4 Ripple (1st) | 0 correctness, 1 disagreement (badge-ordering nit) | After | No |
| G6 Peer (1st) | 0 correctness, 1 disagreement (would prefer explicit over implicit safety guard) | After | No |
| G5 Proof | 0 — e2e verified both ways against the real service worker | After | No |
| **G8 Dogfood (1st) — FAILED** | **1 critical UX/logic bug: manual Stop of a layered session didn't suppress, silently overriding the user's own click within ~1 minute** | After | **Yes — the headline finding of this arm** |
| G4 Ripple (re-run) | 0 — re-verified against final 2-commit diff, all 4 callers audited individually | After | No |
| G6 Peer (re-run) | 0 correctness, 1 real-but-out-of-scope finding (`handleCompletedSession`'s away-completion path has the same gap, untouched by this diff) | After | Yes |
| G8 Dogfood (re-run) | 0 correctness, 1 disclosed UX gap (suppression has no user-facing feedback — pre-existing, not introduced here) | After | No |

**Shift-left ratio:** 0/4 substantive findings landed before Build this arm (G1 found nothing to catch, unlike pair 1's arm A). **But the more important number is downstream:** G8 caught a real bug in the FIX ITSELF before it ever reached the "done" state — the fix that shipped is materially different (and correct) because of a gate, not despite skipping one. This is a different flavor of value than pair 1 showed (catching a stale premise) — catching an incomplete fix.

## Outcome (fill in at +14 days)
Not applicable — sample branch, not merged, not deployed.

## Notes

- **This is the clearest "the gate earned its budget" result across both pairs so far.** Without G8, `experiment/arm-c-with-pipeline` would have shipped (as a real feature) a Stop button that silently didn't work for the specific, very plausible case of a user layering a manual session over an automatic schedule — worse than the original bug, in a different way, and the kind of thing that reads great in a demo (natural-end resume) and breaks in real use (manual stop doesn't).
- Correcting my own process note: I made a real operational mistake mid-arm — applying the G8 fix to the wrong git branch (`arm-d-without-pipeline` instead of `arm-c-with-pipeline`) because I'd switched branches to investigate Arm D candidates while Arm C's gates were running in the background, and lost track of which branch was checked out. Caught by inspecting the diff before committing, not by any gate. Worth a tooling note: running two arms with interleaved background work on the same working tree (rather than two worktrees) is a real source of this class of mistake — see `result.md`.
- A second, separate mistake of the same shape happened later: Arm D's actual commit landed on `main` instead of `experiment/arm-d-without-pipeline`, for the same root cause (branch tracking across interleaved work). Fixed by cherry-picking onto the correct branch and hard-resetting `main` back to its exact prior commit, verified via `git rev-list origin/main..HEAD`. No data was lost, but this happened twice in one session, which is a pattern, not a one-off — see `result.md`'s recommendation.
