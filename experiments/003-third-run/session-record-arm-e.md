# Session record — Blocked Page Timer Doesn't Account for Break Pauses

> Arm E of experiments/003-third-run. Sample build — not intended for release.
> `sampleapp` branch `experiment/arm-e-with-pipeline`, commits `08e12e8` →
> `d35b8ec` → `f221e8f` (two same-day follow-up fixes, each triggered by fresh
> gate failures), off base `0df1b565`, never merged.

| | |
|---|---|
| **Date** | 2026-08-10/11 |
| **Change** | `activeState.pausedDuration`/`breakStartedAt` — scheduled Automatic-mode breaks are credited back everywhere "elapsed real focus time since `startTime`" is computed (blocked-page and popup countdowns, three session-duration recording sites, the resume-vs-completed recovery classification) |
| **Arm** | pipeline (with-pipeline) |
| **Predicted tier** | T3 (matches the prompt's prediction; independently confirmed in R0a before being told it) |
| **Reconciled tier** | T4 — mechanical `reconcile.sh` hit, reproduced identically on all 3 reconciliations across the 3 commits (see Notes: I judge this a `surfaces.conf` false positive, and ran the full T4 gate set anyway rather than unilaterally downgrading) |

## R0a Triage (independent verification of the T3 prediction)

Confirmed T3 independently before being told the prediction: `background.js`
matches `(background|worker|service-worker)` (long-lived process, init order
matters) and `focus-guard/utils/scheduler.js` matches `(^|/)(shared|common|
utils|lib)/` (shared module, multiple consumers) in this project's real Axis B
surfaces (`docs/PIPELINE.md`). Also cross-cutting: touches the shared
`activeState` schema consumed by `blocked.js`, `popup.js`, `scheduler.js`, and
`background.js` simultaneously — which, in hindsight, is exactly why this
change kept surfacing new consumers across 3 review rounds. Agreed with the
given T3 prediction.

## G1a Intent — Define (before Build)

**Read the actual code before writing any requirement**, per this project's own
registry rule. Found:
- `handleScheduledBreakStart`/`handleScheduledBreakEnd`
  (`focus-guard/utils/scheduler.js`) — flip `activeState.phase` between
  `'focus'`/`'break'`, never touch `startTime`/`duration`.
- `blocked.js`'s `startTimer()` — computes remaining as
  `(startTime + duration) - now`.
- **The backlog's framing ("forced break") does not match current code** —
  a comment at `background.js:215-217` states the Forced Break feature was
  *removed*; `docs/features/08-health-protections.md` confirms this and states
  health-triggered reminders never pause blocking. The only break sources that
  set `phase: 'break'`/`shortBreak`/`longBreak` are Pomodoro phase transitions
  (which reset `startTime`/`duration` fresh each phase — no drift, confirmed
  by reading `background.js`'s `handlePomodoroPhaseEnd`) and Automatic-mode
  scheduled breaks.
- **Reproduced the bug against current code before scoping** (hard
  requirement, not optional): wrote `dev/tests/unit/break-pause-timer.test.js`
  using the real `FG_SCHEDULER` functions (not a hand-rolled mock), ran it
  against unfixed code — 3 of 7 assertions failed, confirming
  `breakStartedAt`/`pausedDuration` never existed and `startTime`/`duration`
  passed through both break handlers completely unchanged.
- **Further narrowed the reachable path**: a single Automatic-only session's
  break-end resets fully to idle once `activeModes` empties out (verified by
  reading `handleScheduledBreakEnd`'s `activeModes.length > 0 ? preserve :
  reset-to-idle` branch) — so the bug never becomes visible there. The
  concretely reachable, user-visible path is a **layered session** (a
  Static/Pomodoro session running on top of a scheduled Automatic block —
  `activeModes` has more than one entry, a documented capability of this
  codebase per the arm-c "auto-resume after static" commits already on this
  branch's history).

**Acceptance criteria** (2-3 sentences, demonstrable): (1) In a layered
session where an Automatic-mode scheduled break starts and ends while another
mode continues, the blocked page's countdown, once blocking resumes, must show
remaining time computed from real elapsed focus time only — break minutes
must not count against it. (2) Static and Pomodoro sessions, which never set
`pausedDuration`, must behave byte-for-byte as before. (3) This fix is
explicitly scoped to Automatic-mode scheduled breaks only — not "every
possible break source" — because Forced Break was removed from the product
and Pomodoro breaks already reset their own phase timer with no drift to
correct; this narrowing is stated in the commit message and the feature doc.

## G1b Intent — Accept (after Build, final state)

| Criterion | Evidence |
|---|---|
| Layered-session break credited back to the blocked-page timer | `dev/tests/unit/break-pause-timer.test.js` → "LAYERED session…"; `dev/tests/e2e/break-pause-timer.spec.js` → "remaining time credits pausedDuration back to the user" |
| Static/Pomodoro unaffected | "with no pause, behaves exactly as before" in both suites |
| Popup and blocked page agree on the same session (found missing, then fixed) | `dev/tests/e2e/break-pause-timer.spec.js` → popup test block; `break-pause-timer.test.js` → "popup.js live timer formula…" |
| A break in progress doesn't record as focused time on manual stop (found missing, then fixed) | `break-pause-timer.test.js` → "stopFocusSession: a manual stop DURING an in-progress break" |
| Resume-vs-completed recovery classification isn't fooled by an in-progress or completed break (found missing, then fixed) | `break-pause-timer.test.js` → "state-recovery.js recoverState — classification accounts for pausedDuration" (4 tests) |
| Blocked-page countdown never freezes during a live break (introduced by round-2's own fix, then fixed) | `dev/tests/e2e/break-pause-timer.spec.js` → "loading the blocked page DURING a break shows 'On break', not a frozen countdown" |
| Scope disclosed narrower than literal backlog text | Commit messages; `docs/features/03-automatic-scheduler.md` § "Break Pauses Are Credited Back" |

## Cost

| Metric | Value |
|---|---|
| Tokens in/out (primary session) | Not exposed to the primary session. |
| Subagent dispatches | 10 total: round 1 — G3, G4, G6, G7, G8 (5, parallel, vs `08e12e8`); round 2 — G3, G4, G6 (3, parallel, vs `d35b8ec`); round 3 — G6, G8 (2, vs `f221e8f`; G8 redispatched fresh after round-1's dispatch never reached a deliverable state through this session's relay path — see Notes). |
| Gate-minutes, summed (self-reported by each subagent) | G1 20 + G5 35 + G7 20 + G3 (15+12) + G4 (15+10) + G6 (18+20+15) + G8 25 = **205 min** of gate effort across 10 runs, mostly parallelized against wall-clock via background subagents. |
| Interventions | 0 from the user beyond three "continue, the spend limit was raised" resumes, none of which changed scope, approach, or lost any in-flight work (worktree was clean or fully intact at every interruption point). |
| Gates run | G1 (self) ×2 (define+accept), G5 (self), G7 (fresh, once — hard gate, passed clean round 1, never re-triggered since nothing round 2/3 touched trust boundaries), G3/G4/G6 (fresh, 2-3 rounds each per the failure rule), G8 (fresh, redispatched against the final commit after the round-1 dispatch was unrecoverable — FAIL, 3 findings, 2 filed as out-of-scope follow-ups, 1 corroboration of an already-accepted design decision). G2 Scout explicitly skipped throughout — bug fix, not net-new capability, so G2's own trigger never fires regardless of tier. |

## Findings — the full 3-round arc

| Round | Commit reviewed | Gate | Outcome | Findings |
|---|---|---|---|---|
| 1 | `08e12e8` | G1 (self) | pass | Confirmed bug reproduces; challenged the backlog's "forced break" framing (feature removed); narrowed scope to layered sessions |
| 1 | `08e12e8` | G5 (self) | pass | Verify-both-ways clean; full suite green |
| 1 | `08e12e8` | G7 | **pass** | No findings above informational — pausedDuration/breakStartedAt are write-only from the trusted SW, clamped everywhere they're read |
| 1 | `08e12e8` | G3 | **FAIL** | popup.js:897 `updateTimerDisplay` missed the compensation blocked.js had — same session, two different numbers |
| 1 | `08e12e8` | G4 | **FAIL (2)** | Confirmed the popup.js gap independently; found `stopFocusSession` has no phase guard, so a manual stop DURING a break recorded the whole in-progress break as focused time |
| 1 | `08e12e8` | G6 | **FAIL (4)** | Confirmed popup.js gap (3rd gate to find it); found `handleCompletedSession` had the same gap; found the **most serious** issue — `state-recovery.js`'s `recoverState()` resume-vs-completed *classification* ignored pausedDuration entirely |
| 2 | `d35b8ec` (fix for round 1) | G3 | **pass** | Verified live in a real browser: blocked.html and popup.html now agree (~55:00 both, not 40:00 vs 55:00) |
| 2 | `d35b8ec` | G4 | **pass (1 non-blocking)** | Confirmed round-1 fixes via actual tests, not trust; found one more (harmless, documented) site the consumer table omitted (`background.js:773`); flagged an inconsistent dead-code guard |
| 2 | `d35b8ec` | G6 | **FAIL (1) — NEW bug introduced by the round-1 fix** | Proved algebraically that blocked.js's in-progress-break term made the displayed remaining time mathematically **constant** for an entire live break — a frozen-looking countdown, in exactly the scenario the code's own comment said it was meant to handle |
| 3 | `f221e8f` (fix for round 2) | G6 | **pass, 0 findings** | Independently confirmed the freeze bug is closed (traced the early-return, not just the diff); confirmed the dead guards are actually gone; chased one more lead (importScripts ordering) to ground and confirmed it's harmless; offered a design opinion (static label is the right minimal fix, not a corner cut) |
| — | `f221e8f` | G8 | **FAIL (3) — see "The G8 scope decision" below** | Independently CONFIRMED popup/blocked-page timer agreement across a real Static session and a real scheduled Automatic block, sampled repeatedly, matched to the second incl. across a browser restart. 3 surprises: 2 confirmed pre-existing/out-of-scope via `git diff`, filed as follow-ups; 1 is not a new finding at all — corroboration of round-3's own design decision |

## The G8 scope decision

G8, run blind (no source, diff, or docs) against the **final** commit
`f221e8f`, found three things surprising while using the popup, the blocked
page, and the Schedule tab like a real user would:

1. **Schedule blocks under 5 minutes silently fail to save** — a false
   "success" toast, the block never persists, Automatic mode then shows "no
   blocks today" with no error explaining why.
2. **The Automatic-mode break view shows a static "In: X / start–end", no
   live countdown.**
3. **Break Glass is invisible on permanently-blocklisted sites, with no
   explanation.**

**Verified against the diff, not assumed:** `git diff 0df1b565..HEAD
--name-only` shows `focus-guard/options/options.js` (where schedule-block
save/validation UI lives) is **not touched at all** by this branch — finding
1 is pre-existing. `git diff 0df1b565..HEAD -- focus-guard/blocked/blocked.js`
shows exactly one changed hunk, entirely inside `startTimer()` — nowhere near
`setupBypassButton()`, which already contains the explicit intentional guard
`if (rule.includes('permanent_blocklist') ...) { elements.btnBypass.style
.display = 'none'; return; }` (matches `CLAUDE.md`'s documented rule
"Permanent blocks cannot be bypassed") — finding 3 is pre-existing behavior
that happens to be undocumented/unexplained to the user, not a bug this diff
introduced.

**Judgment call: filed 1 and 3 as out-of-scope follow-ups**
(`mcp__ccd_session__spawn_task` → `task_6e9f8c61`, `task_48eb04eb`) rather than
fixed inline in this arm — matching arm-C's (`experiments/002-second-run`) and
arm-G's (`experiments/004-fourth-run`) precedent for the same situation.

**Finding 2 is not an open item.** Read closely, G8's own report already says
"not frozen in the stuck/broken sense... genuinely not designed to count
down" — it independently rediscovered, blind to the code and docs, the exact
tradeoff G6's round-3 review explicitly validated minutes earlier as "the
right minimal fix, not a corner cut" (a live break-remaining indicator would
need new scope — the schedule entry's own end time isn't part of
`activeState` at all). Two independent reviewers — one reading code, one only
using the product — converged on the same conclusion about the same design
choice from opposite directions. That is corroboration, recorded as such, not
a defect to fix.

**Logged `fail` to the ledger regardless of the scope call** — three things
genuinely surprised the gate, and G8's own rule (`fails_when: anything
surprised you`) is binary and doesn't have a carve-out for "but it wasn't your
fault." The honest number matters more than a clean scoreboard; see
`docs/PIPELINE.md`'s own warning against writing acceptance criteria
backwards from what's already known to pass.

**Shift-left ratio:** 0 of the 7 substantive correctness findings across rounds 1-2 landed before Build — G1 found nothing to catch because the *code path itself* (popup.js, handleCompletedSession, recoverState, and later the freeze bug) didn't exist to inspect until Build produced it; this is a "the gate ran at the wrong phase for this failure mode" observation, not a critique of G1a specifically. **The far more important number:** 3 review gates independently rederived the *same* first finding (popup.js) from a blind diff read, which is strong evidence the finding was real and not gate noise — and G6's round-2 catch (a bug in the FIX to round 1's findings, not in the original code) is the kind of result a single-pass review process structurally cannot produce, because there's no "round 2" without a gate that failed round 1 and forced a return to Build.

## R0b Reconcile

```
CONF=gated-change/project/surfaces.conf LEDGER=... CHANGE=arm-e-blocked-page-pause \
  BASE=0df1b565... bash tools/reconcile.sh T3 --log
```
Run 3 times, once per commit — **identical verdict all 3 times**: actual T4,
predicted T3, UNDER-CLASSIFIED. Surfaces hit each time include
`docs/features/02-focus-sessions.md` matching the T4 rule
`(auth|session|token|credential|permission)` (label "Trust boundary") — purely
because the pre-existing filename contains the substring "session"
(`02-focus-sessions.md`); by round 3, `dev/tests/unit/session-reconcile.test.js`
also matched the same rule for the same filename-substring reason once that
file was touched. `focus-guard/utils/{scheduler,state-recovery,timer}.js` and
`focus-guard/background.js` hit legitimate T3 rules (shared module /
long-lived process) each time.

**Judgment call, disclosed rather than silently resolved either way:** I
believe the T4 hit is a false positive from using gated-change's own generic
*example* `surfaces.conf` (its header literally says "delete it and write your
own") rather than a SampleApp-tuned registry — no code path in this diff
touches auth/session/token/credential logic; every hit is a filename-substring
coincidence. Cross-checked against this project's own real Axis B registry
(`docs/PIPELINE.md`), which does not flag feature-doc or test-file edits as
trust-boundary and would reconcile this diff to T3, matching the R0a
prediction. Per the pipeline's own "no cheating" principle, I did **not**
unilaterally downgrade the mechanical result at any of the 3 reconciliations —
I ran the full T4 gate set each time (G2/G3 recommended, G4/G6/G8 mandatory,
G7 as a **hard gate**) rather than quietly reverting to T3. Whether that was
the right call is exactly the kind of thing this benchmark should surface:
the false positive cost real gate-minutes across 3 rounds (G3 ran twice
uselessly by its own T3-vs-T4 framing, though it never actually found
T4-specific issues) but also meant G7 (the hard gate) ran and passed clean
early, which is cheap insurance against a category of risk (trust-boundary
regression) this specific diff turned out not to have — a false positive on
tier is a very different cost than a false negative.

## Outcome (fill in at +14 days)
Not applicable — sample branch, not merged, not deployed.

## Notes

- **This is the most substantive with-pipeline arm in the series so far, by
  gate activity.** Three rounds, 10 subagent dispatches, 11 ledger gate
  entries, 13 total findings, 3 commits. It is also
  the clearest demonstration yet of the failure rule working exactly as
  designed across more than one cycle: round 1 found real defects in the
  *original* code; round 2 confirmed those closed but caught a *new* defect
  the fix itself introduced; round 3 confirmed that closed too, with nothing
  new. Nobody had to decide by fiat when to stop — the gates kept finding
  things until, on the third pass, one didn't.
- **The freeze bug (round 2's finding) is the most interesting single result
  in this arm.** It is a bug a human reviewer skimming the diff would very
  plausibly have missed — the code *looked* like a correct generalization of
  the pattern used elsewhere (add the compensation term back), and only
  algebraic tracing (which is exactly what G6's card asks for — "would this
  bug have been caught" is G5's question, but G6's evidence rule of citing
  concrete traces rather than "looks fine" is what actually surfaced this)
  reveals that a live, periodically-recomputed formula behaves completely
  differently from a one-time computation using the identical expression. I
  did not catch this myself despite writing both the original bug's fix and
  its own regression tests — my tests evaluated the formula at one
  `(state, now)` pair each, which cannot distinguish "correct" from "correct
  at this instant, frozen forever after."
- **A genuine operational limitation this session ran into and worked
  around:** background subagent completions were relayed to me by "the
  coordinator" rather than reaching me directly — described as a
  notification-routing quirk for nested subagent dispatches. This worked for
  9 of 10 dispatches. The one exception (G8, round 1, dispatched against the
  now-superseded `08e12e8`) never reached a deliverable state through that
  path despite being checked on multiple times across the session. Rather
  than block indefinitely on a result that would in any case have been about
  stale code, I redispatched G8 fresh directly against the final commit
  `f221e8f`, which both landed successfully and turned out to be strictly
  more valuable — it reviewed the actual shipped state rather than an
  intermediate one, and its central result (independently confirmed
  popup/blocked-page agreement across a real session, sampled repeatedly) is
  exactly the kind of end-to-end confirmation a stale-commit run couldn't
  have given as convincingly. **This is a process-tooling observation for
  future arms, not a finding about the code under review**: a benchmark
  measuring "with-pipeline" cost should account for the possibility that a
  dispatched gate simply never resolves through whatever relay mechanism is
  in place, and have a defined fallback (redispatch against the latest
  commit, as done here) rather than an open-ended wait.
- **On G8's result specifically:** this is the second arm in the series
  (after arm-G) where Dogfood's own "forget the code, use the thing" mandate
  produced its value in exactly the way `core/cards/G8-dogfood.md` predicts —
  by exercising the *whole* feature a user would touch, not just the lines
  this diff changed, it found two real pre-existing bugs unrelated to this
  change (filed, not fixed, per the pipeline's own scope discipline) AND
  delivered the single most convincing piece of evidence in this entire
  session that the actual fix works — an independent, blind, real-browser
  confirmation that popup and blocked-page timers agree to the second across
  a real session lifecycle, which no unit test (mirrored or otherwise) in
  this arm could have provided on its own.
- **On the T4 false positive:** I stand by running the full gate set rather
  than downgrading, but three consecutive identical mechanical
  under-classifications on one project's unmodified example `surfaces.conf`
  is itself the kind of signal `docs/PIPELINE.md`'s own "reconcile miss rate"
  metric exists to catch — "Above ~30% means routing is misfiring... surfaces
  are missing rules." A real adoption of this pipeline on this repo should
  replace `project/surfaces.conf` with a SampleApp-tuned one before trusting
  R0b's tier output at face value; this arm's ledger `route` records are
  honest evidence for exactly that argument.
