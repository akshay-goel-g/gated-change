# Session record — Arm G (with pipeline)

> Arm G of experiments/004-fourth-run. Sample build — not intended for release.
> `sampleapp` worktree `D:\work\sampleapp-wt-arm-g`, branch
> `experiment/arm-g-with-pipeline`, commits `6f675d7` → `6ad521e` → `88afd49`
> (three commits: initial fix, then two gate-response follow-ups), off base
> `0df1b565`, never merged.

| | |
|---|---|
| **Date** | 2026-08-10 / 2026-08-11 (session crossed midnight IST) |
| **Change** | `addToWhitelist(pattern, category)` in `focus-guard/utils/blocker.js` now validates `category` against `settings.allowCategories`, coercing an unrecognized id to `'custom'` (write-time) plus a matching render-time healing fallback in `loadWhitelistEntries` (`focus-guard/options/options.js`) for already-stored orphan entries |
| **Arm** | pipeline (with-pipeline), T4 |
| **Predicted tier** | T4 (forced — touches `blocker.js`, this repo's Axis B enforcement trigger) |
| **Reconciled tier** | T4 (match, re-run twice more after each follow-up commit — still match all three times) |

## Cost

| Metric | Value |
|---|---|
| Tokens in / out | Not exposed to the primary session. |
| Subagent token cost | Not directly instrumented this round (metadata not surfaced to this session the way it was in earlier arms). 6 gate subagent runs total: G4 ×1, G6 ×2 (initial + re-run), G7 ×1, G8 ×1, all `claude-opus` except G8 (`claude-sonnet-5`, browser-interaction bound per Part 9.2's model-tier guidance). |
| Wall-clock minutes | Not cleanly separable — this session was interrupted three times by spend-limit errors and resumed by a coordinator relaying subagent results (a notification-routing quirk meant completions reached the coordinator, not this session, directly). Excluding those interruptions, gate-subagent work ran in parallel in the background while primary-session work (fix, tests, docs, e2e verification, a diagnostic script) proceeded serially. |
| Gate-minutes, summed | G5 20 + G4 12 + G6 15 + G6(re-run) 14 + G7 20 + G8 25 = **106 min** of gate effort, plus G1a/R0a/R0b done inline. |
| Interventions | 0 from the user (fully automated/coordinator-relayed). 3 real correction cycles from the pipeline itself — see Findings. |
| Gates run | 7 of 8 required: G1 (inline), G4, G5 (inline), G6 (×2), G7, G8. G2/G3 correctly skipped (bug fix, no UI surface change beyond an existing form/toast). |

## Findings

| Gate | Findings | Before/after Build | Challenged premise? |
|---|---|---|---|
| G1a Intent | 0 — reproduced the bug with a throwaway Jest repro before scoping (`addToWhitelist('example.com', 'ghostGroup')` stored the orphan id verbatim) | Before | No |
| G5 Proof | 1 (the confirmed defect) — regression test added, verified both ways | After | No |
| G4 Ripple (1st) | 6, none blocking — 2 medium (write-path-only, no healing for already-orphaned entries; weak silent-failure signal) | After | **Yes** |
| G6 Peer (1st) | 7, none correctness-affecting — but flagged a **vacuous unit test** as highest priority (passed identically pre/post fix) | After | **Yes** |
| G7 Threat (hard gate) | 10 (0 crit/high/med, 4 low, 6 informational) — PASS, clears the bar | After | **Yes — 3 disagreements, including correcting the fix's own framing** |
| G8 Dogfood | 3 real bugs in the Allow Sites tab, **all confirmed pre-existing**, none caused by this diff | After | **Yes** |
| G6 Peer (re-run) | 7 — 6 of the 1st round's findings confirmed fixed, 1 not, 4 new (1 medium: the e2e test's own claim was unproven) | After | **Yes** |

**Shift-left ratio:** 0/34 substantive findings landed before Build (G1a found the premise sound — the bug reproduced exactly as reported). Every finding of substance came from the verify gates, after Build. This arm's story is downstream catches, not upstream ones — closer to arm C's pair-2 pattern than arm A's.

## The three correction cycles (the actual content of this arm)

1. **G7 corrected the fix's own claimed severity.** The original code comments and feature-doc language claimed an orphan-category entry became "effectively unmanageable." G7 traced this precisely: `getDisabledCategoryIds()` can never match an id that isn't in `settings.allowCategories`, and `'custom'` is *also* permanently exempt from that same disabled-set — so the built DNR allow-rule set is **byte-identical** whether an entry's category is an orphan id or `'custom'`. The real defect was **labeling and manageability**, not **enforcement**. This is the most valuable single finding in the arm: it didn't just find a bug, it found that the author's own mental model of what the bug *was* had overclaimed impact, in text that would otherwise have shipped into the permanent doc trail. Rewrote `docs/features/13-whitelist.md` and `docs/SESSION_HANDOFF.md` to match.

2. **G6 caught a test that proved nothing.** `'an orphan id never resolves as muted once coerced — the actual defect'` asserted that a whitelist entry still produced an allow rule after being added with an unregistered category. That assertion is true **identically before and after the fix** (an orphan id and `'custom'` were both always exempt from the disabled-group filter) — the test was written from the *intended* narrative of the bug rather than from what actually discriminates the fix, exactly the failure mode `core/cards/G1-intent.md` and `G5-proof.md` warn about ("writing criteria you already know the code satisfies"). Deleted it; replaced it with a test on the new `categoryFallback` response field, which does discriminate.

3. **The re-run G6 questioned my own e2e test's discriminating power, and I settled it empirically rather than argue from re-reading the code.** After round 1, an e2e test claimed (in a comment) that `options.js`'s live `chrome.storage.onChanged` listener re-syncs the group dropdown before a stale category can reach `addToWhitelist` — meaning that specific test exercised a pre-existing self-heal, not this fix's write-time coercion. The G6 re-run correctly pointed out the comment was **asserted, not proven** — the test's own assertions (toast text, list contents) would pass identically whether the self-heal or the coercion produced the result. Rather than re-read `handleSettingsChange` and argue from inspection again (which is exactly how the original, wrong hypothesis — "the dropdown stays focused, so the guard blocks the resync" — had been formed), I wrote a throwaway Node/Playwright script that intercepts the actual `chrome.runtime.sendMessage` payload and checked `document.activeElement` at each step. It settled the question with a concrete artifact: the dropdown already read `'custom'` before the click, and `ADD_TO_WHITELIST` was sent with `category: 'custom'` already — the original claim was correct, but only by luck of not having verified it. Rewrote the e2e test to assert `toHaveValue('custom')` on the dropdown directly, so a future run proves the claim instead of narrating it.

## The G8 scope decision

G8, run with real browser automation (Playwright via the **PowerShell tool**, not Bash — Bash cannot spawn a browser process in this sandbox, matching `CLAUDE.md`'s own documented limitation; PowerShell works fine and this arm used it throughout for all e2e evidence) and given no source, diff, or docs, found three real bugs while exercising the Allow Sites tab and its group-management UI:

1. Renaming a group with adjacent capital letters mangles the stored name ("USA Trip Planning" → "U S A Trip Planning") — confirmed corrupted in storage, not just display.
2. Deleting a group in one open tab doesn't live-sync to a second open tab (rename and pause do).
3. A native `prompt()`/`confirm()` dialog open in one tab freezes click handling in another tab.

**Verified none are caused by this diff**: `git diff 0df1b56..88afd49 -- focus-guard/options/options.js` touches exactly two functions, `addSiteToWhitelist` and `loadWhitelistEntries` — not `renameAllowGroup`, `removeAllowGroup`, or any dialog-handling code. **Judgment call: recorded as an out-of-scope follow-up** (`mcp__ccd_session__spawn_task`, task `task_46ac1ba3`) rather than fixed inline in this arm, matching `experiments/002-second-run` arm-C's precedent for an out-of-scope G6 finding. Logged the ledger outcome as `fail` — honestly, per the gate's own binary pass/fail rule (something surprised it) — rather than reclassifying it as `pass` to make the number look better. The gate did exactly its job: it found real defects by using the whole feature the way a person would, not just the lines this diff touched, which is the entire stated point of G8 (`core/cards/G8-dogfood.md`: "the most undervalued gate here, and the one most likely to find the defect a user would otherwise have reported").

## Pre-existing environmental flake, not this diff's

The final full-suite runs showed 5 failures in `bypass-quota-enforcement.test.js` / `bypass-flow.test.js`. Investigated rather than dismissed: this session's wall-clock crossed midnight IST partway through (`date` showed `Tue Aug 11 00:29:59 IST 2026` mid-session against an initial context of `2026-08-11`), and these tests exercise daily-quota day-bucketing. Confirmed pre-existing and unrelated to this diff two ways: (1) `git diff` touches neither `bypass-logic.js` nor either test file; (2) reproduced identically in a clean, isolated **detached git worktree at the true original base commit `0df1b565`** (before any change in this arm), via `git worktree add --detach`, with `node_modules` symlinked in from the main repo. Full unit suite otherwise green: **135/135 suites, 2782/2787 tests**, isolating exactly this pre-existing 5.

## Outcome (fill in at +14 days)
Not applicable — sample branch, not merged, not deployed.

## Notes

**Judgment call, documented per the task's explicit requirement:** an unrecognized `category` id is **coerced to `'custom'`** rather than rejected outright or mirrored to `importList()`'s "warn but keep the id as sent" behavior. Reasoning, and the alternatives considered, are recorded in `docs/features/13-whitelist.md`'s "Orphan/unknown category id" section and in the commit messages — not repeated in full here. Corrected mid-arm (see above): the fix's actual effect is labeling/manageability, not enforcement, which changes how defensible "coerce vs. reject" reads (coercing is a much lower-stakes call once you know the DNR rule set is unaffected either way).

**A second, smaller judgment call:** G6's re-run correctly identified that the "known allow-group id" check now exists in three places (rule-of-three met) but I chose **not** to extract it into a shared module, and documented why in the commit message — the three implementations differ enough in shape (sync Set-of-keys vs. an async helper that already strips `'custom'` vs. a differently-built Set for a shared blocklist/whitelist import path) that forcing one primitive risks exactly the "wrong abstraction" failure `core/cards/G6-peer.md` itself warns about, and extracting would require new shared-file wiring (background.js `importScripts`, `options.html` script tag, Firefox-manifest sync) for what the gate itself rated a low-severity finding.

**Verify-both-ways was applied at three different layers this arm, not just the usual one:** (1) the standard unit-test revert/restore cycle for the core fix (G5); (2) a `git stash` of the code alone to confirm the two `res.category`/`wl[0].category` assertions fail pre-fix and pass post-fix; (3) a purpose-built diagnostic script to settle an *empirical claim about runtime behavior* (the self-heal timing) that neither reading the code nor an existing test assertion could resolve on its own. That third layer is the one worth generalizing: when a claim is about *timing/ordering* in a real browser rather than pure logic, a unit test's mock storage can't settle it — only an instrumented real run can, and this session's earlier confident-but-wrong hypothesis (about `selectOption` leaving the dropdown focused) is a concrete example of what skipping that step costs.

**Coordinator-relayed notifications:** subagent completions this session consistently reached an external coordinator rather than this session directly (a routing quirk noted explicitly in three separate mid-task messages). Each relay was treated as authoritative gate output and acted on the same as a direct notification would have been — the pipeline's fresh-context requirement doesn't depend on *how* the report arrives, only on the reviewing session having started cold, which all four gate subagents genuinely did.
