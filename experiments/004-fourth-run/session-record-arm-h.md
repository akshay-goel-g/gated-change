# Session record — Arm H (without pipeline)

> Arm H of experiments/004-fourth-run. Sample build — not intended for release.
> `sampleapp` worktree `D:\work\sampleapp-wt-arm-h`, branch
> `experiment/arm-h-without-pipeline`, commit `88e5a66`, off base `0df1b565`,
> never merged.

| | |
|---|---|
| **Date** | 2026-08-10 |
| **Change** | Added corruption guard on read for `KEYS.WHITELIST` in `focus-guard/utils/storage.js` (`getSync`/`getLocal`), mirroring the existing `KEYS.BLOCKLIST` guard |
| **Arm** | no-pipeline (CLAUDE.md house rules only) |
| **Predicted tier** | T3 (per `experiments/004-fourth-run/design.md`) — N/A in-arm, no Triage in this arm |
| **Reconciled tier** | N/A — no Reconcile in this arm |

## Cost

| Metric | Value |
|---|---|
| Tokens in / out | Not exposed to the primary session. |
| Subagent token cost | 0 — no gates, no subagents (by design; single agent did the whole build). |
| Wall-clock minutes | Not separately instrumented; single continuous session covering: read CLAUDE.md + feature doc + storage.js reference blocks, implement fix, write test, revert-and-confirm-fails, restore, run full suite, update docs, commit. |
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

**The bug reproduced exactly as pre-registered, and the "obvious trap" the task
flagged did not materialize.** The task instructions explicitly warned against
blindly widening `key === KEYS.BLOCKLIST` to an `||` condition without first
checking whether whitelist entries actually require `.pattern` the same way
blocklist entries do — the two lists could in principle have diverged shapes.
I read `docs/features/13-whitelist.md`'s documented schema (`{ id, pattern,
label, category, addedAt, scope }`) and the `addToWhitelist` workflow section
before touching code: whitelist entries require `.pattern` exactly as
blocklist entries do — `pattern` is the field validated at add-time
(`validate: non-empty pattern`), used for mutual-exclusion checks and DNR rule
building. So the direct mirror (same filter predicate, same log/re-persist
shape, separate `if` block rather than an `||` to keep the two log messages
distinct) was correct as-is — no adjustment needed. I kept them as two
separate `if` blocks (not merged into one condition) so the "N corrupted
blocklist entries" vs "N corrupted whitelist entries" log messages stay
distinct, matching the existing pattern's granularity.

**One genuine surprise: there was no pre-existing unit test for this exact
behavior to mirror.** The task instructions predicted "there's likely an
existing pattern for the blocklist version of this — search dev/tests/unit/
for a test asserting corrupted blocklist entries get filtered on read." I
searched (`grep -r "corrupt|Removed" dev/tests/unit`) and found no test
actually exercising `storage.js`'s `getSync`/`getLocal` corruption-filter
behavior for either key — the closest hit,
`dev/tests/unit/list-page-clamp.test.js`, tests a *different* defense
(`searchablePattern()` tolerating a missing `.pattern` at render/search time,
a downstream mitigation for exactly this gap, per `docs/features/13-whitelist.md`'s
"List rendering" section), not the storage-layer filter itself. So instead of
mirroring an existing test, I wrote a new file,
`dev/tests/unit/storage-corruption-guard.test.js`, covering both `getLocal`
and `getSync` (which auto-routes to `getLocal` for both these keys, since
both are `LOCAL_KEYS` members) for both `KEYS.BLOCKLIST` (as a reference/
regression pin on the pre-existing behavior) and `KEYS.WHITELIST` (the fix).

**Verified both ways per CLAUDE.md's own stated bar** (see
`docs/SESSION_HANDOFF.md`'s "A test that passes against the unfixed code is
not a regression test" lesson from a past session): stashed
`focus-guard/utils/storage.js` back to its pre-fix state, re-ran the new test
file — the two whitelist-specific assertions failed as expected (corrupted
entries survived the read), the blocklist and "already-clean" assertions
still passed (they don't depend on the fix). Restored the fix (`git stash
pop`) and reconfirmed all 5 tests green before running the full suite.

**Full unit suite: 136 suites / 2787 tests, all green**, no new failures,
`npx jest --runInBand` per CLAUDE.md step 3.

**Docs updated in two places**, both required for a clean write-up:
`docs/features/13-whitelist.md`'s "List rendering" section (which explicitly
called out the asymmetry as a known gap) and `docs/SESSION_HANDOFF.md`'s
"Reported but NOT fixed" bullet from the session-47 Tab 6 audit that
originally logged this bug — struck through and marked fixed with a pointer
to this benchmark commit, rather than silently deleted, so the audit trail
stays intact for anyone reading the handoff history later.

**No e2e test added.** CLAUDE.md's "after every bug fix" checklist calls for
an e2e spec for every user-visible behavior change, but this fix has no
user-visible surface — it's a read-time healing path inside a storage utility
that never throws or renders differently to the user in the non-corrupted
case, and the corrupted case is already covered by `searchablePattern`'s
tolerance at the UI layer (which has its own e2e coverage via
`whitelist-options.spec.js` per the feature doc's "Tests to Run" list). Judged
this out of scope for a unit-test-only storage fix rather than manufacturing
an e2e scenario for a change no user click can trigger or observe.

**No CLAUDE.md code-rule entry added.** Unlike several entries in
`docs/SESSION_HANDOFF.md`'s historical audit log, this fix didn't surface a
new class of bug worth a standing rule — it closes an asymmetry between two
already-documented, already-ruled entries (`BLOCKLIST` vs `WHITELIST` treated
identically almost everywhere except this one spot). Added no new rule to
CLAUDE.md's "Code rules" section; judged the existing rule
"`storage.js` scrubs malformed entries" description in `13-whitelist.md`
sufficient once corrected to describe both keys.
