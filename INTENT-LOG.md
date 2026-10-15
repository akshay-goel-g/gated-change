# Intent log — gated-change

> Append-only. Never edited, never reordered, never pruned.
> Format and rationale: `templates/INTENT-LOG.md`.
>
> This file starts on 2026-08-12, at the first session where the kit ran its own
> pipeline. Sessions before that are in git history only — which is precisely
> the gap this file exists to close, and it cannot be closed retroactively
> without inventing the decisions.

- 2026-08-12 · Asked: review the kit as user / PM / developer / tester, then fix all ten findings in sequence
  Decided: one commit per finding, tests first so every later fix lands against a green baseline. Kept the kit's own surfaces in `project/` and moved the user-facing example to `templates/`, because "project/ is yours" has to mean the kit too — with reconcile refusing the kit's file inside an installed copy, since inheriting it fails open.
  Deferred: the live test against the verification service (needs a real product link and key) · Open: whether <removed-packer> should stamp its secret into the <removed-installer> it bundles, which changes the seller's release process

- 2026-08-12/13 · Asked: install the kit into a real project (SampleApp) and run it for real on a real change, twice — then, separately, review the dashboard, "stages forget what's intended," and auto-pickup, with explicit authority to reject any proposal (including the orchestrator's own and the human's) that violated the kit's stated principles
  Decided: 7 of a first 7-item proposal set accepted or modified, 4 rejected outright (idempotent gate-skipping, findings-lifecycle state machine, checkpointing verify gates, an input-sandbox for the blind-review rule) — each rejection cited the specific kit doc it would have violated, not just "seems risky." From the second review: fixed two real bugs in `dashboard/app.js`'s status computation rather than just the ledger-side fix; deferred a dashboard staleness indicator (judged decorative, not load-bearing, for a static offline snapshot); named the findings-as-attack-surface risk in `LEARNINGS.md` without building a control for it (anecdote-tier, not incident-backed); treated the auto-pickup complaint as a documentation gap in `agent-instructions.md`, not a new enforcement mechanism, because `05-enforcement.md`'s own closing rule argues against mechanising judgment calls.
  Deferred: dispatching the fresh-context verify gates (G4/G6/G7/G8) on both new changes — router/ledger context rule forbids the author running them on their own work, and every dispatch this session that tried anyway would have defeated the point of the review.
  Open: whether `withhold_breached` and the G1a intent-log-skim line (both explicitly trial-tagged, `11-evolution.md` Step 7) should be promoted or retired — no real evidence yet, deliberately not decided on one session's data. Also open: a stopping heuristic for how many fresh-context review rounds are worth running on one change — this session ran two rounds on the SampleApp test change and both found new, non-overlapping real bugs, so "diminishing returns" could not be established from the data available; named as a gap, not solved.

- 2026-08-13 · Asked: dogfight-review the kit as developer/tester/PM/business lead/front-end/
  back-end/devops — covering extension development phases, invocation points, the
  download-does-not-overwrite question, and fraud/abuse resistance — discuss only, no
  changes; then, once the extension-phases finding landed, implement a "narrow pass" fix
  (agreed after a round of scoping) rather than the full router mechanism
  Decided: the review surfaced that T4 ("anything a user cannot undo") cannot be expressed for
  store-side events (publish, permission-warning delta, signing-key loss) because
  `reconcile.sh`'s only input is a path diff — recorded as a LEARNINGS.md entry rather than
  built, because closing it for real means an `ACTION::` row kind that changes the router
  itself (T4 on this kit's own surfaces) and this branch already has three un-gated T4/T3
  changes waiting on fresh-context gates. Did the narrow, non-router pass instead: rewrote
  `templates/project/surfaces.conf` from a blocker-shaped (SampleApp) example to a genuine
  any-Chrome-extension profile — kept the three test-pinned rows (auth/session/token → Trust
  boundary, ledger → Quota accounting, lib → Shared module) byte-identical, replaced the
  SampleApp-specific enforcement row with an explicit fill-in-the-blank placeholder, added
  extension-universal T4 rows (.pem signing key, update.xml) and a T3 messaging row, and added
  a "WHAT THIS FILE CANNOT ROUTE" section naming the gap instead of implying false coverage.
  Documented `BASE=<last-release-tag>` on `reconcile.sh` (`01-router.md`) as the one mitigation
  that needed no new code. Named the five phases (`00-start.md`) and added an honest
  "not covered here" section to `14-phases.md` for Release, which has no chapter and no
  executor. Caught and fixed a self-inflicted bug before it shipped: an early draft of the
  surfaces rewrite used wrapped multi-line labels, which the parser silently truncates to
  their first physical line — corrected to single-line rules with comments carrying the
  elaboration, verified against `reconcile.sh` directly and against the full suite.
  Deferred: the fraud/abuse and download-overwrite findings from the same review — not
  started; discussed and recorded in conversation only. The `sha256sum`-vs-`shasum` macOS
  install blocker, flagged during the same review as higher-priority than any of this, is also
  still open.
  Open: whether to also fix the README's stale "145 assertions" count (now 244) — deliberately
  left out of this pass rather than bundled into an unrelated docs/config change.

- 2026-08-13 · Asked: dispatch the outstanding fresh-context gates for the branch's un-gated T4
  changes; then, once the ledger.sh injection finding landed, fix it; then re-verify both fixes
  with fresh context; then split the accumulated uncommitted work into separate commits.
  Decided: dispatched 8 fresh-context subagent reviews (G4+G6+G7 combined per change — a
  documented compromise against dispatch-volume cost, still genuinely fresh relative to the
  author, just not cross-gate-isolated — plus G8 kept strictly separate and diff-blind per its
  own withhold field, since G4/G6/G7 review the diff and G8 must not see it). Real findings
  surfaced, not clean passes: a live JSON-injection in `ledger.sh`'s own `emit()` templates that
  let a crafted `--lane` value forge `compliance`'s verdict; a TOCTOU race the license
  use-ordering fix's own reorder introduced; a raw Python traceback shown to a user on
  a malformed license-server response; a deeper recurrence, on the dashboard, of the exact
  banner/detail contradiction an earlier commit was meant to fix; and, on this session's own
  extension-phases work, a missing content-scripts row (converged on by 4 independent gates).
  Fixed the ledger.sh injection and the content-scripts gap; left the use-count race, the
  <removed-installer> traceback, and the dashboard contradiction as recorded-but-unfixed findings —
  explicitly not expanded into unrequested scope. Both fixes were re-verified by a genuinely
  fresh second round (not a self-report): the ledger.sh fix's round 2 independently
  reproduced the original exploit as resolved, then threw ~15 new payloads at it and found one
  more real gap (`is_uint` accepted leading zeros, invalid JSON) which was also fixed and
  re-tested; the content-scripts fix's round 2 found the regex missed camelCase/single-file
  layouts, which was also fixed and re-verified against both the positive and the original
  negative test cases. A round-2 reviewer flagged that the ledger.sh fix and the
  extension-phases fix were sitting together in one uncommitted working tree — a real process
  finding matching the user's own standing preference for scope separation — so the tree was
  split into 3 commits: extension-phases work, the ledger.sh fix, and a shared "records" commit
  for `LEARNINGS.md`/`INTENT-LOG.md`/`SESSION-HANDOFF.md`/`ledger.jsonl` (files that narrate
  both fixes interleaved and cannot be cleanly split without interactive patch staging, which
  was not available). A stray `ledger.jsonl:20` entry, discovered mid-session as the live
  reproduction of a separate real bug (a G8 reviewer's scratch QA session silently wrote into
  this repo's own real ledger), was deliberately left in place rather than edited, per this
  repo's own established never-backfill precedent — documented in `LEARNINGS.md` instead.
  Deferred: the use-count TOCTOU race, the <removed-installer> traceback, the dashboard banner
  contradiction, macOS `sha256sum`/`shasum`, the `ACTION::` router mechanism, and the
  fraud/abuse findings — all real, all open, none started this session.
  Open: whether `project/map.md`/`project/registry.md`/`project/govern.md` (all still empty
  templates, flagged repeatedly by G4 across multiple changes this session) should be filled in
  as their own change, or continue accumulating flags until enough real content exists to
  justify one.

- 2026-08-13 · Asked: fix the macOS `sha256sum`/`shasum` install break and the dashboard
  headline/detail contradiction from the prior entry's deferred list; park the use-count TOCTOU
  race for now.
  Decided: `tools/<removed-installer>` and `tools/<removed-packer>` each got a `sha256_of`/`sha256_line`
  helper trying `sha256sum` → `shasum -a 256` → `openssl dgst -sha256` (openssl already a hard
  dependency of both, so the fallback always succeeds) — verified with a real
  `<removed-packer>` → `<removed-installer>` round trip against a stubbed verification response, not just unit
  tests. For the dashboard, traced the contradiction one level deeper than the prior fix
  (86f548e, which resolved a same-round fail-then-pass tripping the top-level status): the
  Overview headline's "nothing blocking was found" was computed from `failN` (gates whose
  *current* governing outcome is "fail"), never from finding *severity* — `ledger.sh` does not
  force `outcome=fail` just because a finding is logged `blocking` (a documented convention in
  `core/04-ledger.md`, not code-enforced), so a gate that found and fixed a blocking issue
  within one run can log `outcome: pass` while `finding_details` still carries the blocking
  entry, and the headline said "nothing blocking was found" one clause before "Show the
  numbers" contradicted it. Fixed by keying the headline off `bySev.blocking` instead, and — since
  the fix required reading `renderOutput`'s near-identical bySeverity computation anyway —
  extracted both into one `changeSummary(cg)` rather than leaving two copies of the same
  calculation to drift again. Two new tests in `tests/dashboard-logic.test.js` pin both
  directions (a same-run blocking-then-fixed finding must not read as clean; a genuinely clean
  change must still get the reassuring headline). Two commits, kept separate per the user's
  standing scope-separation preference even though both came from the same request. 270/270
  tests green after each.
  Deferred: fresh-context re-verification of both fixes — this session authored and tested them
  itself, unlike the three commits immediately before it in the branch, which went through
  independent G4/G6/G7/G8 dispatch. Recorded in `SESSION-HANDOFF.md` as a gap for whoever picks
  this up next, not silently treated as equivalent to a gated fix.
  Parked, explicitly, at the user's direction: the use-count TOCTOU race, the
  <removed-installer> raw-traceback-on-malformed-response gap, and the un-`risks.md`-recorded
  "not live-tested" risk that travels with it — all still open, none started.

- 2026-08-13 · Asked: fresh-context re-verify the macOS and dashboard fixes from the prior
  entry, in subagents — closing the gap that entry's own "Deferred" line named.
  Decided: dispatched 4 fresh-context subagents (G4+G6+G7 combined per change, G8 dogfood
  kept separate and diff-blind, mirroring the prior round's own protocol exactly) — 2 changes
  × 2 dispatches. The first attempt at all 4 stalled on a background-agent watchdog (10min, no
  progress) simultaneously; traced to `isolation: worktree` overhead plus asking them to run
  the full, silent, multi-minute test suite. Relaunched without worktree isolation and with
  fast/targeted verification instructions instead of the full suite; the dashboard G4+G6+G7
  dispatch alone needed a third attempt (its second also stalled, mid-suite-run). Real findings
  surfaced on BOTH changes, not clean passes: (macOS) G8 found a hash tool present-but-
  failing-at-runtime killed `<removed-installer>` SILENTLY under `set -e`/`pipefail` — reproduced against
  the pre-fix parent commit too, so pre-existing rather than a regression, but this fix's own
  `sha256_of`/`sha256_line` functions are the code a user would hit it through; G4 and G7
  independently flagged the new fallback branches had zero test coverage; G7 flagged a
  theoretical (unreproduced) double-empty-match gap in the checksum comparison. (dashboard) G8
  found the IDENTICAL headline/severity contradiction recurring one function down, in
  `friendlyGateLine()` (the per-reviewer row) — a function the prior fix never touched —
  reproduced live on this repo's own `ledger.jsonl`, not just a synthetic fixture; G6 found the
  new headline's "fixed before the last round" wording was itself inaccurate for a same-round
  fix, an echo of the exact class of bug being fixed. All six real findings fixed and verified
  same-session: writing the new fallback tests caught, while writing them, that output
  equality alone doesn't prove which tool ran (all three hash identically) — every test was
  redesigned to check an invocation marker, not just the final number. 7 new regression tests
  total (4 macOS, 3 dashboard). 5 commits: macOS gate-driven fixes, dashboard gate-driven fix,
  ledger entries (8, one per gate per change), plus this pair of session-record updates.
  280/280 tests green throughout.
  Open: same two items as the prior entry — `project/map.md`/`registry.md`/`govern.md` still
  empty (G4 flagged again, 3rd+ occurrence now), and the use-count TOCTOU race remains the
  highest-value unstarted item across two sessions running.

- 2026-08-14 · Asked: build the `ACTION::TIER::NAME::EVIDENCE` router mechanism
  `LEARNINGS.md` and `SESSION-HANDOFF.md` had deferred as its own T4, fresh-gated change on
  `router/action-tier-mechanism` — a new `surfaces.conf` row kind, no path regex, for the T4
  release events (store publish, permission-warning delta, staged-rollout ramp, signing-key
  rotation, listing edit) a diff-based router can never see. Answer the numbered design
  questions the task explicitly posed (row format/parsing, invocation shape, ledger schema,
  where in the pipeline this fires, whether it closes the gap fully) and document the
  reasoning, not just the code.
  Decided: `ACTION::TIER::NAME::EVIDENCE` rows, parsed via one `_action_parse()` helper and
  explicitly excluded from the path-tiering loop (never grepped as a path regex — the
  specific failure class this task named as a real risk, and the one G6's fresh review
  actually found a smaller instance of, see below). New `--action NAME --evidence
  "<citation>"` flags on `reconcile.sh`, composing with a normal diff-based reconcile in the
  same call (ACTUAL becomes the max of both), predicted defaulting to the action's own tier
  when omitted (nothing to guess about a declared fact). Documented as its own step, R0d, in
  `01-router.md` — not folded into R0b, because R0b assumes a diff/Build already happened and
  an ACTION has neither; `14-phases.md` already said Release has no chapter or executor, and
  R0d is the piece that exists without one. `ledger.sh route` gained `action`/`evidence`
  fields, paired-presence refused independently of `reconcile.sh`'s own check. Named honestly,
  not silently closed: nothing forces `--action` to be invoked, EVIDENCE is presence-checked
  only, no retraction mechanism, no compliance check that an ACTION was ever exercised.
  Gate story: fresh-context combined G4+G6+G7 FAILED G6 with 4 real, live-reproduced findings
  on the ACTION-row parser (empty EVIDENCE not checked, a `::`-containing NAME silently
  reinterpreted instead of refused, duplicate-NAME rows silently letting the first win, and
  the terminal output undercutting R0d's own "not R0b" rationale by printing "R0b" for a pure
  action run). G4 filed one real finding too (`templates/agent-instructions.md` never
  mentioned the mechanism). All fixed same-session, pinned by fail-before/pass-after tests. G1
  and G5 self-graded pass (their own cards permit same-session). G8 ran twice: round 1 (full
  scope) failed on 3 findings, all confirmed pre-existing and unrelated once traced against
  `d628c0f`; round 2, re-scoped to the mechanism only, passed clean.
  A real process incident, caught mid-session: the first fresh-context dispatch attempt used
  `isolation: "worktree"`, which silently checked out `origin/master`'s tip instead of this
  branch's actual HEAD — G8 correctly failed against code genuinely missing the feature. Not
  a code defect; a dispatch-mechanics gap with no `ref`/`base` parameter to pin it. Caught by
  cross-checking the worktree's commit from outside the dispatch, before anything was logged.
  Redone directly in the main checkout with the session's own narrative files (`LEARNINGS.md`,
  `SESSION-HANDOFF.md`) `git stash`ed out of the working tree for the blind-review duration,
  and a `git log -1` self-check added as the first action of every subsequent dispatch.
  Recorded in full in `LEARNINGS.md`.
  Deferred: the four named R0d gaps (most valuable: a compliance check that an ACTION was
  actually exercised), plus three pre-existing CLI-hardening findings two independent G8 runs
  converged on in `reconcile.sh`/`ledger.sh` (predicted-tier not validated, gate-name shape
  vs. enum divergence in reporting, compliance not enforcing its own n/a-reason requirement) —
  spawned as a background task rather than folded into this change's scope.
  Open: same items as before — `project/map.md`/`registry.md`/`govern.md` still empty, the
  use-count TOCTOU race still unstarted.

- 2026-09-01 · Asked: check gated-change's status and readiness to ship as a download, then fix
  the record drift that check surfaced.
  Decided: fixed the pre-push hook (drifted behind `templates/pre-push`), the README Status
  counts ("145 assertions" → 598, the stale "INCOMPLETE / gates have not run" line), and
  SESSION-HANDOFF.md (still described the pre-merge "44 commits ahead, never pushed" state).
  Decided NOT to backfill this log for 2026-08-15 to 2026-08-30. The sessions in that window
  (Coverage panel, `status.sh`, the R0c Claude hook, the round-3 re-verification, the
  macOS/first-push fixes, the `compliance` recorded-reason refusal and its G7 review, the
  2026-08-30 dashboard fix) left code in git (`267e3fc..0183706`), SESSION-HANDOFF rewrites
  through `267e3fc`, and gate rounds in the ledger — but their Decided/Deferred/Open is not
  recoverable now, and `04-ledger.md`'s "fiction with a timestamp" rule applies to invented
  deliberation as much as to invented gate runs. The log resumes here.
  Deferred: the four release blockers, unchanged — no real product reference, release
  secret still the repo default, the live acquisition→install flow never run for real, the
  use TOCTOU race never started. · Open: whether this log stays current from here —
  the gap it just acknowledged is the failure mode, and only the next session writing to it
  fixes that.

- 2026-09-02 · Asked: check the product-intelligence dashboard, run an Opus subagent to
  four-persona review it (user / PM / DevOps / web designer), then fix the P0 items, commit on
  master, and set up the fresh-context gates.
  Decided: ran the review, then the change `dashboard-p0-review-fixes` — 9 P0 fixes, then all
  five gates (G1/G5 same-session, G4/G6/G7/G8 fresh-context) over multiple rounds, each round's
  fixes cherry-picked back onto master as their own commit. G4/G6/G7 converged to a pass in 2–3
  rounds. G8 did not: rounds 3–6 each surfaced exactly one non-blocking display inconsistency
  (rounds 5–6 introduced by the fix for 4–5) — the asymptote of an absolute "nothing surprised
  me" bar on 144 records of real ledger data. Logged G8 round 7 as `--outcome skipped` with a
  documented rationale rather than chase it further; the change owner accepts the residual and
  it is subject to the exception audit. Ran gate rounds 3+ on Sonnet 5 because Opus was
  rate-limited for the whole session (≈10 opus agent deaths mid-run); noted the model in each
  ledger row. Did NOT reorder the ledger to fix an out-of-order retry-logged G8 entry
  (`04-ledger.md`: never reorder) — fixed the consumer (`renderOutput`) instead, and left the
  `coverage.sh` `tail -1` anchor assumption it also exposed alone (T4, out of scope).
  Deferred: the 375px responsive collapse — G8 flagged it every round; it is P1-11, its own
  change. A clean full `tests/run.sh` before merging `dashboard-p0-review-fixes` (Windows Git
  Bash contended out late in the session). · Open: whether `compliance` reporting INCOMPLETE
  on a documented, owned G8 skip is the right shape, or whether a `skipped`-with-rationale
  should count differently from a bare skip — named, not decided.

- 2026-09-03 · Asked: check the session handover; check whether CI passed; on finding it had
  not, fix it and gate it, then work the handoff backlog one item at a time.
  Decided: CI had been red on `macos-latest` for 14 days (every run since 2026-08-19) on ONE
  test — `test_emit_refuses_a_line_that_is_not_a_json_object` exited 127 not 3 because it
  sourced `ledger.sh`'s function prefix via `. <(sed …)`, and process-substitution sourcing
  silently loads nothing on the bash 3.2 macOS ships. Not R-004 (the `_relpath` drive-letter
  branch `_skip`ped cleanly). Ran it as change `emit-backstop-test-macos-bash32`, T3
  (`tests/run.sh`), full normal lane. Round 1 = the fix (`507071b`, stage to a `mktemp` file):
  G1 same-session + G4/G5/G6/G7 fresh-context subagents, all pass; G8 `n/a` (Axis C invisible).
  Round 2 = G5's recommended portability guard `test_no_kit_shell_file_sources_a_process_substitution`
  (`9375ec0`); fresh G5/G6 round 2 both pass with two converging minor findings (unanchored
  comment-exclusion, silent-on-scan-failure), fixed the same round (`4a8ef61`). G1/G4/G7
  round 2 logged inline — a source-grep meta-test opens no coupling or attack surface, so the
  round-1 fresh conclusions stand. Installed `gh` via winget to read Actions (no browser
  session or gh was available). Harvested to LEARNINGS + narrowed R-003.
  Deferred: the four release blockers (unchanged). · Open: whether `macos-latest` CI
  actually goes green on the push of these commits — the one G1 acceptance criterion that
  cannot have evidence before the push. It replaces "confirm CI passed" as the top handoff item.

- 2026-09-03 · Asked: after the CI fix, work the handoff backlog one item at a time; hold the
  push, do P1-11 next.
  Decided: change `dashboard-responsive-narrow`, T1 (`tools/dashboard/app.css`). Did the
  CSS-only version — one `@media (max-width:820px)` block: columns stack, page scrolls as one,
  rail becomes a capped scrollable strip, drawer becomes a bottom sheet. Chose NOT to do the
  handoff's fuller sketch (rail→collapsible drawer with a toggle, legend→`?` popover, Technical
  tab→"wider screen" notice) because a toggle/popover needs `app.js` + `dashboard.sh` markup =
  T3, and the CSS-only stack already fixes the actual breakage (the ~34px graph pane). The
  "wider screen" notice is deferred as its own T3 change; the SVG scales to ~319px, small but
  not broken. Gated G3 Craft + G6 Peer fresh-context (T1 mandates none; change owner chose to
  run them anyway) + G4/G8 inline — all pass. G6 caught a closed-drawer box-shadow band, fixed
  in a follow-up commit. reconcile needed `BASE=<parent>` because the 4 unpushed CI-fix commits
  were otherwise in the diff and pushed the tier to T3.
  Deferred: Technical-tab "wider screen" notice (T3, app.js); the 821–1000px layout band
  (pre-existing, G3-flagged). · Open: same as above — the macOS CI green, still unpushed.

- 2026-09-03 · Asked: push the 8 commits, watch CI, confirm `macos-latest` goes green.
  Decided: pushed (`966e46d..7dc9eb4`; the pre-push hook's dashboard regen needed a second
  `git push` to sync, as its own header warns). CI run 33716224479 — **all three OS legs
  green**; macos-latest: `bash 3.2.57`, `passed 613 · failed 0 · skipped 1`. The two open
  items above are now closed: the macOS CI fix is proven on the platform it targets, and R-003
  updated to reflect first-proof on all three platforms (residue is now regression, not
  first-proof). Backlog top item is now P1-5.
  Deferred: nothing new. · Open: nothing — clean handoff into P1-5.

- 2026-09-03 · Asked: start P1-5 (branch-name pseudo-changes).
  Decided: change `branch-name-pseudo-changes`, T4 (`tools/ledger.sh`, `tools/reconcile.sh`,
  `core/01-router.md`). Root cause: `reconcile.sh` defaults `--change` to the branch name, so
  trunk-based work with no `CHANGE=` writes route records named `master` that correlate with
  no gates. Fixed at the write side (`ledger.sh` refuses trunk names on route/add/escape/
  assume; `feat/x` still passes) and the read side (`app.js` renders such records as muted
  routing artifacts). Asked the user drop-vs-mute for the dashboard → **mute**. Chose NOT to
  make `change_is_branchy` a computed "resolve the default branch from git" check — it adds a
  git dependency to `ledger.sh` for an edge case — and recorded the residue as **R-005** with
  that as the deferred next step. An `--action` reconcile now names its record for the action,
  not the branch, so R0d's documented CHANGE-less flow is untouched. Full T4 gate lane:
  G1/G8 same-session, G3 inline (a UI surface changed — one muted rail row), G4/G5/G6/G7
  fresh-context subagents. All pass; G7 challenged the premise (no override for a trunk-based
  team — accepted, tracked in R-005). Three rounds: r1 the fix, r2 widened the guard + covered
  escape/assume (G4/G7), r3 trimmed the list back to unambiguous names + genericised the
  refusal message + added a list-parity test (G5/G6). Learned: four gate subagents on one
  working tree contaminate each other when Proof mutation-tests in place (LEARNINGS 2026-09-03).
  Deferred: the computed default-branch check (R-005). · Open: nothing — P1-5 pushed
  (`6af0fde..2fccf06`, `--no-verify` with a logged G7 exception since the report can't name
  its own commit), CI run 33745116502 green on all three legs (macos `bash 3.2.57`,
  `passed 656 · failed 0 · skipped 1`).

- 2026-09-03 · Asked: start on the rest of P1 (the dashboard backlog).
  Decided: recovered the "gone" 2026-09-01 four-persona review from an old session scratchpad
  (§7 is the authoritative P0/P1/P2 spec — noted in auto-memory). Change
  `dashboard-p1-readability`, **T1** (`tools/dashboard/app.js` + `app.css` only — the P1-2
  summary bar was built in JS rather than a `dashboard.sh` container specifically to stay off
  the T3 surface). Shipped P1-1 (metrics panel in the single-project rail), P1-2 (summary bar
  **with** interactive rail filtering — owner chose the full version over counts-only when
  asked; G6 challenged it as YAGNI twice, owner's call stands), P1-3 (escape + assumption
  record sections + a rail badge), P1-6 (`isIndependent`/`isVerdict`/`isSelfCheck` — a
  non-`fresh` verdict is a self-check, a skip is not), P1-7 (deleted the three dead
  minutes-budget checks, show `tokens`), P1-8 (`friendlyDate` + `staleClass` on the generated
  stamp), P1-9 (`changeSpanText` elapsed-time). Gate lane: G3 Craft pass r1 (6 minors, all
  addressed), G4 Ripple + G8 Dogfood inline pass, G5 Proof fail r1 → **pass r3**, G6 Peer
  fail r1 → fail r2 → **pass r3**. Four commits (r1–r4), each round's fixes their own commit.
  G5 round 2 never reached the ledger — opus 529'd three times before delivering anything, so
  it was re-spawned fresh on Sonnet as round 3 (LEARNINGS 2026-09-03). Each fresh gate got its
  own `git worktree`. Reconcile T1==T1; compliance: T1 mandates no gates. Harvested 5 LEARNINGS
  (blind-review leak via `git show`; `!isIndependent` ≠ self-check; ledger-keyed `{}` is a
  prototype-pollution surface; `load()` `global.document` cascade; opus 529 → Sonnet) and
  risk **R-006** (`buildExecutions`'s pre-existing `{}`-keyed-by-change map).
  Deferred: `dashboard.sh` still bakes now-dead `budgetMin` into the model (T3); the legend
  wording is narrow after P1-6 (`dashboard.sh`, P2-7); the pre-existing R-006 one-liner;
  `stateLines`/drawer self-check-text test coverage (G5 called it incidental). · Open: the
  full `tests/run.sh` suite green against the final commit `abe820d` (running); the push and
  CI — the one G5 acceptance criterion (Linux/macOS evidence) that cannot exist before it.

- 2026-09-03 · Asked: push the P1 commits, watch CI (same message, "push and watch CI").
  Decided: pushed `05ce371..bca127e` (8 commits + the pre-push hook's own dashboard regen,
  which synced without the usual second push this time). CI run 33769323843 — **all three
  legs green**: ubuntu `passed 656 · failed 0 · skipped 1`, macos `passed 656 · failed 0 ·
  skipped 1`, windows green (30m). Both open items above are now closed: full suite proven on
  the final commit across all three platforms, and G5's Linux/macOS acceptance criterion has
  its evidence (`test_dashboard_logic_js_unit_tests` ran all 105 JS assertions on the ubuntu
  and macos legs). `dashboard-p1-readability` is done; all of P1 from the 2026-09-01 review
  is shipped and CI-green. Backlog top item is now the rest of P2.
  Deferred: nothing new. · Open: nothing — clean handoff into P2.

- 2026-09-04 · Asked: start on the rest of P2 (dashboard backlog).
  Decided: split — Change A `dashboard-p2-polish` now, Change B `dashboard-keyboard-a11y`
  (P2-5) next. Change A = P2-2 (drawer inner width), P2-3 (disclosure prefix → bare
  `▸`/`▾` + stacked reviewer-row disclosures), P2-4 (drop the two ~4px SVG lines, re-space +
  enlarge the 3 that stay), P2-6 (`<nav>`/`<main>`/`<aside>`/`<footer>` landmarks + `.section-title`
  etc. → `<h2>`), P2-7 (legend rewritten to the actual box vocabulary, split in two), plus the
  budgetMin cleanup G6 flagged in P1. **T3** (touches `dashboard.sh` + `tests/run.sh`).
  Reconcile T3==T3 — but the "gate depth" I asked up front ("G3+G6 fresh, G4/G8 inline") was
  set under a light-polish framing; the reconcile then showed **G1/G5/G7 are also mandatory**
  at T3. Owner chose to run them: G1 Intent + G7 Threat inline, G5 fresh. Gate lane: G3 Craft
  **fail r1** (the h2 promotion leaked the UA `<h2>` size — coverage headline rendered at
  18px, bigger than the `<h1>`) → **pass r2**; G6 Peer **pass r1** (caught the same h2 leak) →
  **pass r4**; G5 Proof **fail r4** (the one logic change — `parse_matrix`'s comma placement —
  was undiscriminated: a missing comma keeps the substring suite green while breaking the
  page's `const PIPELINE`) → **pass r5** after adding G5's own mutation-verified tests. G4/G8
  inline, re-affirmed r4. 5 code commits (`457f170..42d09c8`). Each fresh gate its own worktree.
  Compliance: all T3-mandated gates satisfied (KIT DRIFT noted — the change edits `dashboard.sh`,
  which is hashed into the kit fingerprint, so entries logged mid-change carry an older hash).
  Harvested: gate-scoping should follow the reconcile, not precede it; the blind-review `git show`
  leak recurred (G3 r2) — a squashed patch is the only reliable fix; hand-built JSON in a
  generator needs a parse assertion, not substring checks.
  Deferred: P2-5 (Change B, next); P2-8 rail virtualisation (scale). · Open: full `tests/run.sh`
  green against `42d09c8` (running); push + CI.

- 2026-09-04 · Asked: once CI is green, create a session handover.
  Decided: full `tests/run.sh` green against `42d09c8` locally (`passed 666`). Pushed
  `bca127e..9a11cab` — github.com had a ~10-min connectivity outage, so the push took 15
  retries via a background `until git push` loop, plus the usual second push for the pre-push
  hook's dashboard regen. CI run 33830208570 — **all three legs green** (ubuntu/macos
  `passed 661 · failed 0 · skipped 1`, windows green). Both open items above closed. All of
  P1 and P2-2/3/4/6/7 from the 2026-09-01 dashboard review are shipped and CI-green; only P2-5
  (`dashboard-keyboard-a11y`) and the deferred P2-8 remain of that review. Handover rewritten.
  Deferred: nothing new. · Open: nothing — clean handoff into P2-5.

- 2026-09-04 · Asked: start on P2-5 (dashboard-keyboard-a11y), the last item of the
  2026-09-01 dashboard review; then (mid-session) "if any gate fails don't start
  [the next], we might hit token limit, start one by one".
  Decided: change `dashboard-keyboard-a11y`, **T1** (`tools/dashboard/app.js` + `app.css`
  only — the skip link was injected from `app.js` in round 5 rather than added to
  `dashboard.sh`'s `<body>`, deliberately, to hold the change off the T3 surface, same
  call the P1 pass made). Reconcile T1==T1; compliance: T1 mandates no gates. Full-
  template requirements/design/tasks (owner's choice), kept in the session scratchpad.
  Shipped: `role="button"`+`tabindex`+Enter/Space on the ~57 `.exec-row` rows, the 13
  `g.state` graph nodes and (G6) the fleet `.project-card`s; a `:focus-visible` ring
  (rows, nodes, tabs, filter chips, skip link, close button); the drawer close
  `<span>`→`<button>`; Esc-to-close with focus returned to the opening node; a generic
  `captureFocus()`/`restoreFocus()` that preserves keyboard focus across every one of
  the ~9 full re-renders (`renderAll` + `wireRailFilters`); `role="dialog"`+`aria-modal`
  on the open drawer with `trapDrawerTab`; a "Skip to content" link as the first tab
  stop; selected-row-shown-on-load. **7 rounds, one commit each** (`76e778e..bb8e1e7`
  + two `auto: regenerate` commits). Gate lane (all fresh-context subagents except G4):
  G6 Peer **pass r1** → **pass final r7** (2 minors each round, all folded forward);
  G4 Ripple **fail r1** (the enumerated `applyPendingFocus` — the "list of cases not a
  computed property" shape, R-004/R-005) → **pass r2** (generic capture/restore);
  G5 Proof **fail r2** (drawer-transition wiring untested; design.md overstated the
  coverage) → **pass r3**, discrimination proof clean; G3 Craft **fail r3** (the SVG
  focus ring rendered dashed on status-dashed nodes and doubled on the selected node)
  → **pass r4**; G8 Dogfood **fail r4** (blocking: ~60 sequential Tab stops past the
  rail, no bypass — WCAG 2.4.1) → **pass r5**. Owner's call on the G8 blocker: mitigate
  with a skip link now, move roving-tabindex / arrow-key rail navigation into **P2-8**'s
  scope (recorded in requirements.md Out-of-scope so it is inherited). Each fresh gate
  ran against a squashed patch file / the running product, never named commits. Harvested
  5 LEARNINGS (captureFocus is still an enumerated recogniser; `\0` separators are a
  test-tooling trap and NUL bytes make a `.js` file read as binary to git; the browser
  pane's focus model diverges from a real browser for automation; a gate FAIL on a
  scope-deferred symptom stands — the resolution is the owner's; ...).
  Deferred: P2-8 (rail virtualisation + text filter + the roving-tabindex now folded
  into it); the fleet-overview `.project-card`→single-project focus landing is a
  best-effort "first rail row" (multi-project installs only, untested in-browser here).
  · Open: full `tests/run.sh` green against `dee88d6` (running — the local Windows leg);
  push + CI on all three legs.

- 2026-09-04 · Asked: start on P2-8 (the last item of the 2026-09-01 dashboard review).
  Decided: change `dashboard-rail-filter-and-scale`, **T1** (`tools/dashboard/app.js` +
  `app.css` only — the `dashboard.sh` payload-inlining concern, review §4, is T3 and a
  different fix location, left out). Owner chose **paginate/"show all"** over true
  virtualisation, and **roving-tabindex + arrow keys keeping `role="button"`** over a
  `role="listbox"` upgrade. Full-template requirements/design/tasks (scratchpad).
  Shipped: a `type="search"` change-name filter (`railQuery`, matched separator-stripped
  on BOTH the slug and the displayed title-cased name, AND with the status chips); a
  default cap of `RAIL_CAP=25` **real** change groups + a "Show all N changes (M more)"
  button (`railShowAll`); the selected change's group always rendered even past the cap
  (pinned, sorted position); **roving tabindex** — the rail is ONE Tab stop, one
  `.exec-row` at `tabindex="0"`, `handleRailArrows` (bound once in `boot()` on the static
  `#rail-list`) does ArrowUp/Down/Home/End via the pure `railArrowTarget` (no wrap,
  `preventDefault` at the boundary), `resetRailView()` clears the trio at every view-reset
  site, `restoreFocus`/show-all/`scrollRailSelectionIntoView` keep focus and the tab stop
  synced. **7 rounds**, one commit each (`904e5e1`..`cdc3663`) + `8b8acfe` test-only.
  Gate lane (fresh subagents except G4): **G6 fail r1** (delegated arrow listener
  re-attached to the static node every render — an unbounded leak; `railQuery`/`railShowAll`
  not cleared on the paths that clear `railFilter`) → **pass r2**; **G4 fail r1** (show-all
  tab stop not moved; artifacts counted toward the cap) → **pass r2**; **G5 pass r3**
  (full suite 666/0/0, real discrimination, +4 edge tests handed back, recommended the
  leak-fix regression test); **G3 pass r4** ("indistinguishable in kind from the rail
  around them"; 2 minors — the artifact count mismatch, the missing `.rail-clear:hover`);
  **G8 fail r5** (blocking: filter to a tail change past the cap → select → clear the
  filter → the centre panel shows a review with NO row in the rail; but "the keyboard-
  access work itself — 7 tab stops, was ~60 — solid, I'd happily sign off") → **fail r6**
  (fix confirmed closed, but the re-walk solidified the spaced-filter bug) → **pass r7**
  ("nothing surprised me this pass"). Reconcile T1==T1; compliance: T1 mandates no gates.
  9 gate entries + the route in `ledger.jsonl`. 4 LEARNINGS harvested (Windows `open(p,'w')`
  → CRLF; a filter must match what the user sees not the key; roving tabindex ⇄ focus is
  a per-seam sync; a re-verify gate FAILs on a new surprise even when the original is
  closed). **All of the 2026-09-01 dashboard review is now shipped.**
  Deferred: the `dashboard.sh` payload problem (review §4, T3); group-collapse; a
  `role="listbox"` semantic upgrade; the clear-filter scroll-to-selection (G8 could not
  verify it in-tool — needs a trusted keypress; benign, one Tab scrolls it anyway).
  · Open: full `tests/run.sh` green against `cdc3663` (running); push + CI + merge.

- 2026-09-06 · Asked: fix R-005 (`project/risks.md`) — `change_is_branchy()` (`tools/ledger.sh`,
  mirrored in `tools/dashboard/app.js`) is a hand-enumerated trunk-name list, not a computed
  property; a repo whose real trunk is `prod`/a team convention writes route records that
  correlate with no gates. Full T4 pipeline (G1/G4/G5/G6/G7-hard/G8), land like
  coverage-anchor-retro-fix.
  Decided: change `r005-computed-default-branch`, **T4**. Resolve the default branch from git
  — `git symbolic-ref refs/remotes/origin/HEAD`, then `git config init.defaultBranch`, then
  empty — and refuse THAT; hand-list stays as the git-absent fallback. Confirmed the git
  dependency was already there (`ledger.sh` shells out at load + per write; `reconcile.sh:312`
  makes the identical `symbolic-ref` call). The JS side has no git, so `dashboard.sh` bakes
  the resolved name into the model as `"defaultBranch"` and `changeIsBranchy()` reads it.
  Chose a repo-wide computed answer over widening the list (`release`/`stable`/`mainline` are
  real change names) and over a `CHANGE=` opt-in (deferred as the next step if it recurs).
  Gate lane (fresh subagents, squashed patch, blind for G4/G6/G7/G8): **G8 fail r1** (the
  computed-default-branch refusal message was byte-identical to the hardcoded-name one — a
  user on a `prod` trunk had no way to learn the tool consulted *their* git config) → **G4
  fail r1** (retiring R-005 over-claimed — a second residue, non-standard trunk + no
  `origin/HEAD` + no `init.defaultBranch`, still writes on the *write* side; and the computed
  resolution was left as two hand-kept copies, flagged by G4+G5+G6). **Round 2**: shared
  `tools/lib/default-branch.sh` (new T4 surface), self-explaining refusal message, R-005 kept
  as `mitigate` with all three residues stated + review 2026-11-06 → **G4/G6/G7/G8 pass**.
  **Round 3** (test strengthening + one risk-doc word + a `</script>` regression test for the
  new model field; no production-code change) → **G5 pass** (authoritative — its round-2 run
  was cut short by a mid-session process exit under fork-exhaustion load), G1/G4/G6/G7/G8
  carry forward as PASS*. Reconcile T4==T4 all three rounds; `ledger.sh compliance --round 3`
  clean. 2 LEARNINGS harvested (a computed-property fix must have one home for the computed
  part; a file-mutating verify gate must not share the working tree with blind gates + the
  suite, and Windows `fork()` is the constraint).
  Deferred: R-005's three residues (recorded on the still-live row); a `CHANGE=`/`project/`
  opt-in for a team that genuinely names a change after its trunk. Also spun a chip: a
  committed NUL byte in `LEARNINGS.md` (git sees it as binary) — unrelated to R-005.
  · Open: full `tests/run.sh` green against the round-3 tip (running); merge to master + push
  + CI green on all three legs.

- 2026-09-08/09 · Asked: `tools/ledger.sh` `cmd_add` refuses a bad value for every closed-set
  field (`--outcome`, `--tier`, `--round/minutes/tokens`, `--challenged`) except `--confidence`,
  which it spliced in as free text despite `04-ledger.md` and all 8 gate cards giving the
  vocabulary as exactly `fresh|low` and `app.js`'s `isIndependent()` trusting only `"fresh"`;
  a real `--confidence true` typo (`ci-to-codebuild` G7 r2, `b471896`) had to be superseded by
  a corrected append. Refuse it like `--outcome`, add a regression test, land the full T4
  gated pipeline.
  Decided: **refuse**, not warn/normalise — verified against `04-ledger.md:18`, every card's
  `logs_with:` line, and `app.js:182`'s allow-list design; a third accepted spelling carries
  no information the `low` bucket doesn't. Inline `case` after the `--outcome` one (its closest
  sibling), before the skipped/n-a→`low` downgrade (which only ever emits in-vocab). Historical
  `high`/`same-session` records (5/19 in `ledger.jsonl`) left untouched per never-backfill;
  `app.js` renders them non-independent already. Gate lane (fresh blind subagents for
  G4/G6/G7/G8, `3971a7f`): **G6 fail r1 + G8 fail r1 + G4/G7 minor** — all four converged on
  the same defect and it was in the *rationale prose*, not the guard: the new comment / the
  operator-facing REFUSED string / the test comment all said the dashboard fails *open* on a
  bad value ("renders as a clean independent pass") when `isIndependent()` is an allow-list
  that fails *closed* — a typo'd `--confidence` on a real fresh review renders it as an author
  self-check and drops it from `ledger.sh report`'s fresh/low/challenge counts. **Round 1 fix**
  (`63da3c4`): reworded all three; added a "no `--confidence` recorded" warning on `pass`/`fail`
  (G8 — the refusal is hollow if the protected value has an unspoken default), matching
  `--model`/`--tokens`; corrected the `emit()` comment that wrongly called `--lane` "free text
  by design" (it is `normal|hotfix` per `04-ledger.md`, the identical latent gap); added a
  `project/registry.md` row for the 4-way `confidence`-vocabulary coupling. **Round 2**: G6 pass,
  G8 fail (a warning still let an omitted `--confidence` default to the stat-feeding `fresh`).
  **User decision 2026-09-09**: make `--confidence` *required* for a `pass`/`fail` verdict — not
  warn, not default-to-`low` (that re-creates the silent-under-credit harm). **Round 3** (`8746e6c`
  code, `780c570` fix): `--confidence` required for a verdict, `skipped`/`n/a` exempt → `low`;
  ~63 fixture invocations + `core/04-ledger.md`. Fresh gates re-run: **G1/G4/G5/G7(hard)/G8 pass**,
  **G6 fail** — `cmd_compliance`'s no-reason remediation hint printed an `add` command with no
  `--confidence`, i.e. a command the tool's own new check rejects; r3-fix `780c570` added it +
  refreshed 3 stale comments. **Round 4**: fresh G6 **fail** — the r3-fix *reshaped* the defect
  (`--confidence fresh|low` in the hint is a shell pipe when pasted, `low: command not found`
  exit 127). r4-fix `3aba417`: one `echo` string, concrete `--confidence fresh`. **Round 5**:
  fresh blind G6 **pass** — reproduced both the break and the fix; all r1/r3/r4 findings verified
  resolved; 3 `info`/`out-of-scope`, none correctness-affecting; `challenged_premise: false`.
  Full suite **789/0/0**; `compliance --round 5` clean (G1/G4/G5/G7/G8 PASS\* from r3 — the r4/r5
  delta is one echo string + comments, no gate input moved). Reconcile T4==T4 every round.
  Landed on `claude/zealous-hertz-d586e8`; merge to `master` + push owed (CI billing-blocked —
  pre-push `--no-verify` + G7 `skipped` exception, same pattern as coverage-anchor-head-ancestor).
  Deferred: guarding `--lane` / `--model` in `cmd_add` like `--confidence` (chip `task_f3d8c045` —
  `--lane` needs the 2026-08-13 forge regression test rewritten); the two pre-existing
  `cmd_add` asymmetries G8 surfaced (`--outcome` with no value → silent `pass`; `--confidence`
  with no value → raw `$2: unbound variable`); `app.js:176`'s stale `high`/`same-session` count
  comment (`5 and 11` → `5 and 19`).

- 2026-09-15 · Asked: three items to check — (1) whether a new skill outside the pipeline
  could tell the user to start a new session to save tokens, (2) separate input/output token
  tracking, (3) a trigger to re-evaluate which model satisfies a tier when a new version
  ships. All three approved to implement ("start all three").
  Decided: (1) and (3) are T1 doc additions to `core/08-models.md` — no new gate, no new
  file; (2) is a real T4 change to `tools/ledger.sh` (`project/surfaces.conf:27`) and got
  the repo's own full gate treatment by explicit user choice ("Full pipeline") over two
  lighter options offered. `--tokens-in`/`--tokens-out` compute the aggregate `tokens` field
  as their sum so no existing reader needs a code change; an explicit `--tokens` may not be
  less than the split (refused) but may exceed it, reversed from an original exact-equality
  design after G4 Ripple round 1 challenged it (this kit's own subagent gates bill cache
  tokens outside the split). Gate lane: G1/G4/G5 pass round 1 (G4 with the challenge above).
  **G6 Peer and G7 Threat (hard gate) each failed twice**, independently converging on one
  defect both rounds: `is_uint` validated shape (digits) but not magnitude, so a 20+ digit
  operand silently wrapped bash's signed 64-bit arithmetic into an arbitrary in-range value
  that then passed a sign-only check — closed with a 15-digit `is_uint_bounded()` cap on all
  three fields, verified airtight via live mutation testing (reverting the cap reopens the
  exact reported payloads). Both **pass round 3** (info/out-of-scope only). G8 Dogfood found
  and closed 4 real CLI UX bugs across two rounds (`--tokens-in ""` misread as omitted rather
  than invalid; a genuine `--tokens 0` triggering a false "not recorded" note; `report`'s
  token lines rounding independently so a total and its split didn't visibly reconcile; an
  unrecognized subcommand silently dumping the full header to stdout instead of a short
  stderr refusal) — all four confirmed fixed on its second pass, but that pass still logged
  `fail` because it deliberately re-triggered the header comment's own documented `LEDGER=`
  footgun from outside the kit and it wrote into *this repo's own live ledger*, which had to
  be hand-removed; routed out as a separate, pre-existing issue per the failure rule
  (`02-gates.md`: "a finding can be real and still not be about this change") rather than
  re-run a third time for no new information. All 8 gate cards updated to document the new
  flags on `logs_with:` after G6 round 1 found none of them did — a subagent handed only its
  card had no way to learn the flags existed. Suite **845/0/0**.
  Pushed `--no-verify` + a logged G7 `skipped` exception (round 4) — the security report was
  necessarily written against the pre-commit working tree and cannot contain its own final
  commit's sha (content-addressing is self-referential); a commit-binding addendum itemizes
  the four wording/grep-filter/test-only edits made after round 3's review and argues none
  touch the reviewed write-path logic. Same override pattern as
  `confidence-vocabulary-refusal`.
  Deferred: two chips filed and left open — `task_f3521d2e` (the default-`LEDGER`-path
  footgun itself: resolves to the kit's own repo ledger regardless of caller cwd when the
  override silently fails), `task_0d68cd41` (the unknown-subcommand refusal's "see examples"
  pointer is one line short of any actual example). `cmd_compliance`'s own `--round` shares
  the unbounded-`is_uint` pattern (G7 round 3, out-of-scope, confirmed pre-existing) — not
  filed as a separate chip, noted in the report only. · Open: whether `cmd_gates`'s per-gate
  table should also split avg tokens by direction (explicitly out of scope for this change).

- 2026-10-14 · Asked: a read-only audit of the kit (who made each change and whether the ledger can record it; the license;
  donation; dev/test/acceptance criteria and error handling, including an acceptance and production error path; environment
  variables; stress and load testing; whether a user can add, remove or disable a gate; how to use new Claude skills and
  releases), each answered with a strong reason for or against; then: settle the license and how to publish to the Claude
  marketplace before donation, remove the retired paid vendor completely, and finish the E1-E11 review before any of that.
  Decided: (1) license is PolyForm Shield 1.0.0 instead of the previous copyleft license (people may use it in their own projects; nobody may copy it
  and sell it or ship a competing product; patents are out of scope; nobody else uses the kit today), applied as a separate
  commit after the fresh root; Anthropic's directory documents say nothing about licence type. (2) History is fresh: an orphan
  root commit in a recreated private GitHub repo, the old history kept only as an offline bundle (the previous license and the vendor path never
  reach the new repo). (3) Marketplace: our own marketplace first, Anthropic's directory second (paid plan, public repo before
  listing, indemnity clause, human review). (4) Donation is deferred until the license and marketplace are settled. (5) The
  retired vendor is removed completely, (the change name was renamed to `remove-vendor-sponsor-references` on 2026-10-14, before the fresh root).
  (6) The E1-E11 review is closed at round 29 without a clean G7 or G4; the residue is accepted as R-011 and the push stays
  blocked. (7) Scratch space in D:\WinTemp may be deleted (a 74 GB dead task output and ~340 review clones were removed).
  Deferred: audit items H1-H8 (actor field, environment model, preflight, concurrency tests, gate overlay, skills adoption);
  marketplace work K-1..K-7 (needs the path split D5 and the plugin wrapper D8); the plan's A, B, C, F, G workstreams. ·
  Open: the owner's legal name and year for the license notice; whether to see a patent attorney before going public (public
  release can end patent rights in most countries); whether the directory accepts a source-available license in practice
  (untested); how a fresh history affects the gate rows that bind to old shas; why this clone's local git identity keeps
  being rewritten (`t <t@e>`, earlier `test`).
