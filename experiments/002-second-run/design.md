# Experiment 002 — second paired trial

> Pre-registered per `tools/benchmark/README.md`. Written before either build starts.
> Sample builds only, same as 001 — neither branch is intended for release or merge.

## What's being tested

Same question as 001: is the pipeline's cost worth what it catches. This is pair 2 of the
6 Study 3 calls for. Per 001's `result.md`, applying today's lesson: both candidates below
were checked against current code **before** being locked in, not taken from the backlog
at face value.

## The two features

| Arm | Feature | Predicted tier | Where | Files |
|---|---|---|---|---|
| **C** | Auto-Resume After Static Mode Ends During a Scheduled Block — `stopFocusSession()` never re-checks whether the current moment falls inside a scheduled auto-focus block, so Automatic doesn't resume until the next incidental SW wake | T3 | `docs/V2-BACKLOG.md` "Auto-Resume After Static Mode Ends…" | `focus-guard/background.js`, `focus-guard/utils/scheduler.js` |
| **D** | Subdomain Variants Can Bypass Permanent Blocks — `isPermanentlyBlocked()` exact-matches domains only, so a bypass token is wrongly issued (and quota consumed) for a subdomain of a bare blocklisted domain, even though the permanent block rule (priority 8) already covers it structurally and would refuse the resulting allow rule (priority 7) anyway | T4 | `docs/V2-BACKLOG.md` "Subdomain Variants Can Bypass…" | `focus-guard/utils/bypass-logic.js` |

Both confirmed to still reproduce against current `main` (`0df1b565` + pair-1's Harvest
commits are unrelated to either file) before this document was written — see the two
"Confirmed" notes in the conversation this design was drafted from. Arm D's backlog text
overstates the consequence (claims a real block bypass; actual effect is a wasted bypass
slot, since bypass priority 7 < permanent block priority 8) — noted here as found, not
corrected in the backlog file itself, since that's out of scope for a sample build.

**Independence:** different files, different subsystems (session/scheduler state machine vs.
bypass eligibility check). Neither is the same feature as 001's arms A/B.

## Assignment — alternated, not re-coin-flipped

001 gave the harder-tier feature (T4) the pipeline. Per the benchmark README's Study 3 step 3
("alternate on every subsequent pair, so ordering and learning average out"), this pair
deliberately inverts that: **C (T3, the easier tier) → with pipeline. D (T4, the harder,
security-adjacent tier) → without pipeline.**

This is the less comfortable assignment for the pipeline's thesis — skipping the mandatory
G7 Threat hard gate on a bypass/trust-boundary change is exactly the case the gate matrix
calls non-negotiable at T4. Assigned this way on purpose, decided before either build started,
not after seeing how one goes.

## What gets measured

Both arms fill a `session-record-arm-{c,d}.md` per 001's (now-updated) template: tokens,
subagent token cost, wall-clock, gate-minutes vs. wall-clock, interventions, gates/findings
(arm C only), and — at +14 days — fix commits and any escapes.

## What would make this a clean result vs. a muddy one

- **Clean:** cost difference stays attributable to specific gates, not vague thoroughness;
  neither feature turns out to be a different size than scoped once building starts.
- **Muddy:** either feature is trivial or oversized once building starts (001's original risk);
  **or** — the new failure mode named in 001's Harvest — a candidate turns out stale in a way
  not caught by the pre-check above.
- **A specific thing to watch, because of this pair's assignment:** if arm D (no pipeline,
  T4, security-adjacent) ships something a fresh-context G7 Threat run would have caught, that
  is the single most informative outcome two pairs could produce — it is exactly the
  asymmetric-cost case the pipeline's design assumes exists. Report it whether or not it
  happens.

## Failure modes accepted going in

n=2 pairs after this. Same caveats as 001's README section apply — order effects don't apply
here either (still different features), but observation effect does, and six pairs are still
needed before any trend claim. Escape-rate section of `result.md` still deferred, same as 001.

---

Fill `result.md` after both arms are done and reconciled. Do not fill it partway.
