# Experiment 004 — fourth paired trial (delegated to subagents)

> Pre-registered per `tools/benchmark/README.md`. Sample builds only, not for release.
> Same delegation model as experiment 003 — each arm built by a subagent in its own
> git worktree.

## The two features

| Arm | Feature | Predicted tier | Where | Files |
|---|---|---|---|---|
| **G** | Whitelist Add Accepts an Orphan Group Id — `addToWhitelist(pattern, category)` never validates `category` against `settings.allowCategories`; the import path warns about unknown groups but the add form doesn't, so an entry can reference a group id that doesn't exist in the group store | T4 (forced — touches `blocker.js`, this repo's Axis B enforcement trigger) | `docs/CLAUDE.md` "Reported but NOT fixed" note under the Session 47 Tab 6 log, and `docs/features/13-whitelist.md` | `focus-guard/utils/blocker.js` |
| **H** | Whitelist Has No Corruption Guard On Read — `storage.js`'s `getSync`/`getLocal` scrub malformed entries (missing `.pattern`) for `KEYS.BLOCKLIST` only; the identical check was never added for `KEYS.WHITELIST`, so a corrupt whitelist entry can reach the filter/render path unguarded | T3 (shared storage utility, `utils/`) | `docs/CLAUDE.md` "Whitelist has no corruption guard on read" note under Session 47 Tab 6 | `focus-guard/utils/storage.js` |

Both confirmed to still reproduce against current `main` (`0df1b565`) before this
document was written: `addToWhitelist`'s body has no `allowCategories` check (grepped),
and `storage.js`'s corruption-guard block explicitly special-cases
`key === KEYS.BLOCKLIST` in both `getSync` and `getLocal`, with no equivalent for
`KEYS.WHITELIST`.

**Independence:** different functions in adjacent-but-distinct files (write-time
category validation in `blocker.js` vs. read-time corruption healing in `storage.js`).
Weaker independence than prior pairs — both are whitelist-adjacent defensive-coding
gaps from the same historical audit note — but they exercise different code paths and
different failure mechanisms (a bad category id vs. a malformed stored entry), and
this is the closest genuinely-fresh pair left after several rejected candidates this
session (see `experiments/003-third-run/design.md` and
`experiments/002-second-run/result.md` for the pattern). Noted honestly rather than
hidden.

## Assignment

**G (T4, forced by touching `blocker.js`) → with pipeline** — deliberately the harder
tier again, since arm E in experiment 003 already tested giving the pipeline the T3
slot; this pair goes back to the T4/hard-gate case to get another G7 Threat data point.
**H (T3) → without pipeline.**

## What's different this round

Same subagent-per-arm-in-its-own-worktree delegation as experiment 003
(`sampleapp-wt-arm-g`, `sampleapp-wt-arm-h`).

## What gets measured

Same as experiment 003.

---

Fill `result.md` after both arms are done and reconciled.
