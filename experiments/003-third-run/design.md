# Experiment 003 — third paired trial (delegated to subagents)

> Pre-registered per `tools/benchmark/README.md`. Sample builds only, not for release.
> New this round: each arm is built by a dedicated subagent in its own git worktree
> (per pair 2's `result.md` recommendation), not by the orchestrating session directly.

## The two features

| Arm | Feature | Predicted tier | Where | Files |
|---|---|---|---|---|
| **E** | Blocked Page Timer Doesn't Account for Break Pauses — remaining time is computed as `startTime + duration - now`, so a forced break's pause time isn't excluded and the countdown reads less time than actually remains | T3 | `docs/V2-BACKLOG.md` "Blocked Page Timer Doesn't Account for Break Pauses" | `focus-guard/background.js` (break start/end), `focus-guard/blocked/blocked.js` |
| **F** | Popup Reads Storage Directly in `updateFooter` — bypasses the `FG_STORAGE` abstraction (and its corruption recovery) via a bare `chrome.storage.local.get('stats', ...)` call | T2 | `docs/V2-BACKLOG.md` "Popup Reads Storage Directly in updateFooter" | `focus-guard/popup/popup.js` |

Both confirmed to still reproduce against current `main` (`0df1b565`) before this document
was written. Two prior candidates for this pair — "No Real-Time DST/Timezone
Recalculation" and the original "Full Mode Stacking" from pair 1 — were rejected after
verification: the timezone item is already fully implemented by `handleTimezoneCheck()`
in `background.js` (a working reimplementation that supersedes the dead
`detectTimezoneChange` the backlog names), and mode-stacking remains oversized for a
matched pair. This repo's `V2-BACKLOG.md` continues to run well ahead of what's actually
still open — see `experiments/002-second-run/result.md` for the same finding on a
different section of the same file.

**Independence:** different files, different subsystems (break-pause session state vs.
a popup storage read). Neither overlaps arm C/D from pair 2 or arm A/B from pair 1.

## Assignment

**E (T3, cross-cutting background.js + blocked.js) → with pipeline.**
**F (T2, single-file popup fix) → without pipeline.**

Continuing the alternation pattern loosely rather than strictly — pair 1 gave the harder
tier the pipeline, pair 2 inverted it, this pair returns to giving the harder tier the
pipeline, chosen before either build started.

## What's different this round

Each arm is built end-to-end by a subagent working in its own git worktree
(`sampleapp-wt-arm-e`, `sampleapp-wt-arm-f`), not by the orchestrating session. The
with-pipeline subagent is instructed to dispatch its own fresh-context gate subagents
for G4/G6/G7/G8, exactly as the orchestrating session did in pairs 1-2 — the mechanism
is the same, only the outer layer of who's driving it changes. This is itself a variable
worth watching: does delegating the *entire* arm (not just individual gates) change cost
or quality, separate from the with/without-pipeline question the experiment exists to
answer?

## What gets measured

Same as prior pairs — `session-record-arm-{e,f}.md`, cost, findings, gates. Additionally:
whether the delegated subagent stayed within the pipeline's actual rules (right gates for
the tier, ledger entries logged, blind review actually blind) without direct supervision.

---

Fill `result.md` after both arms are done and reconciled.
