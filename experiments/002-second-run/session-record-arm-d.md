# Session record — Arm D (without pipeline)

> Arm D of experiments/002-second-run. Sample build — not intended for release.
> `sampleapp` branch `experiment/arm-d-without-pipeline`, commit `6e27f5c`
> (cherry-picked there after an initial misplacement — see notes), off base
> `0df1b565`, never merged.

| | |
|---|---|
| **Date** | 2026-08-10 |
| **Change** | Removed dead grace-period alarm code (`setGracePeriodAlarm`, its clear call, two orphaned constants) |
| **Arm** | no-pipeline (CLAUDE.md house rules only) |
| **Predicted tier** | N/A — no Triage in this arm |
| **Reconciled tier** | N/A — no Reconcile in this arm |

## Cost

| Metric | Value |
|---|---|
| Tokens in / out | Not exposed to the primary session. |
| Subagent token cost | 0 — no gates, no subagents (by design). |
| Wall-clock minutes | Not cleanly separable from candidate-selection time — see Notes. The actual build (remove function, remove constants, grep for other references, run suite, commit) was under 5 minutes once a candidate was locked in. |
| Gate-minutes, summed | 0 |
| Interventions | 0 |
| Gates run | 0 (by design) |

## Findings

| Gate | Findings | Before/after Build | Challenged premise? |
|---|---|---|---|
| (none — no gates in this arm) | — | — | — |

**Shift-left ratio:** N/A — no gates to shift left from.

## Outcome (fill in at +14 days)
Not applicable — sample branch, not merged, not deployed.

## Notes

**This arm's real story is candidate selection, not the fix itself — and it's the most important finding of pair 2.** The originally pre-registered candidate (`design.md`: "Subdomain Variants Can Bypass Permanent Blocks") was checked against current code before Build, per the Harvest-pass discipline from pair 1, and found already fixed: `isPermanentlyBlocked()` already does subdomain matching (`urlDomain.endsWith('.' + patternDomain)`) directly contradicting its own docstring ("Uses EXACT domain matching only"). Three more candidates from the same `V2-BACKLOG.md` "Security Hardening" section were checked in sequence and ALL were also already resolved:

1. Subdomain bypass — already fixed (subdomain-match branch exists, docstring is stale)
2. Bypass Token Expiry — already fixed (`getToken()` already has a 5-minute TTL check)
3. Category Rules Cached But Never Invalidated — the described cache (`cachedCategories`) no longer exists under that name anywhere in the codebase
4. Full Calendar View for Task Assignment — genuinely not built, but oversized for a matched pair (same problem pair 1 hit with "Full Mode Stacking")
5. Task Completion Time Not Validated Server-Side — `completeTask()`'s current signature is `completeTask(taskId)`, one parameter; the described `(taskId, note, focusMinutes)` trust issue doesn't apply to current code

Only the 6th candidate checked — Grace Period Alarm Dead Code — reproduced exactly as described, and even then with a twist: `dev/tests/REGRESSION-TESTS.md`'s own BUG-038 entry claims this was already removed ("GRACE_PERIOD alarm handler in background.js" — removed), but the function that *creates* the alarm was left behind, so the cleanup was real but incomplete.

**Five of six candidates checked in one backlog section were stale.** That is not "the pipeline found a stale premise" (this arm ran with no pipeline) — it's evidence that `docs/V2-BACKLOG.md`'s Security Hardening section specifically is comprehensively out of date, most likely because the intensive session 46-48 audit work documented in `docs/SESSION_HANDOFF.md` fixed most of it without the backlog file being updated to match. This is a real, standalone, useful finding about the *target* repository, independent of anything about the pipeline benchmark, and probably worth a note to whoever maintains that file.

**Process note (also recorded in session-record-arm-c.md):** two branch-tracking mistakes happened during this pair, both while investigating Arm D's replacement candidates on `main` while Arm C's background gates were still running on a different branch in the same working tree. Arm D's own commit landed on `main` before being caught and moved. Both were caught and fixed before this write-up, but happening twice in one session while doing exactly this kind of interleaved multi-branch work is a process risk worth naming plainly, not just a one-off slip — see `result.md`.
