# coverage-anchor-retro-fix — Requirements

> Written at the Intent gate, before Build. Bug fix, not a feature — Prior art and Assets
> sections are marked N/A rather than deleted, so the template's shape stays legible.

## User

Anyone reading `tools/status.sh`'s "UNROUTED WORK" section or the dashboard's coverage panel
(`tools/dashboard.sh`, `COVERAGE_JSON`) to decide whether recent work still needs a gate run.

## Problem

`coverage_anchor()` (`tools/lib/coverage.sh`) answers "what is the last commit any gate has
reviewed?" by taking the **physically last** `"type":"gate"` line in `ledger.jsonl`
(`grep ... | tail -1`). That assumes append order is commit-recency order.

It is not, always. `ledger.sh add --commit <sha>` (`tools/ledger.sh:59`, a real, documented
option, not misuse) lets a gate be logged against a commit other than current HEAD — gate
lines are appended when the REVIEW happens, not in commit-graph order. A gate run backfilled
or retro-logged against an older commit can land, in the file, after a real, later gate run
already recorded a newer commit.

**Reproduced** (scratch repo, not this kit's own history): commit A, then commit B, gate
logged on B (real, timely). Then a gate entry naming commit A is appended (simulating a
retro/backfilled log call). `coverage_anchor()` on the unfixed function returns commit A —
older than B, which really was the last-reviewed commit. Any work between A and B, already
gated, is then reported as unrouted again: a false positive on `status.sh`'s "UNROUTED WORK"
count and the dashboard's coverage panel.

Today: the answer is silently wrong in this specific ordering, and nothing in `status.sh` or
the dashboard flags it — it just prints a plausible, wrong commit count. Named in
`SESSION-HANDOFF.md` (item 1, T4, "latent; named by G8 r6 (old)").

## Acceptance criteria

- [ ] `coverage_anchor()` returns the gate-verified commit that is newest by commit-graph
      ANCESTRY among ALL `"type":"gate"` lines in the ledger — not the physically-last line's
      commit, and (after three rounds of fresh G7/Threat review) not by commit TIMESTAMP or any
      lexicographic tie-break on the sha either, since both are exactly as forgeable/grindable by
      the same untrusted `--commit` writer as the ledger line itself. `git merge-base
      --independent` finds the candidate(s) nobody else is an ancestor of; when that set has more
      than one member (genuinely divergent, mutually non-descending candidates — rare), the
      function returns NO anchor rather than guess. There is no available signal for breaking
      that tie which is both decisive and outside the same writer's control.
- [ ] A ledger line naming a commit unresolvable in this repo is still skipped (existing
      behavior — "verified to exist HERE" — must not regress).
- [ ] An empty/missing ledger, or a ledger with no `"type":"gate"` line, still returns empty
      (existing "no anchor" behavior unchanged).
- [ ] A regression test proves this: it fails against the pre-fix `coverage_anchor()` and
      passes after — a gate line for an older commit appended physically after a gate line
      for a newer commit must still anchor to the newer one.
- [ ] `coverage_claimed_anchor()` is untouched — it is deliberately "whatever the last line
      claims, verified or not" for a different, already-correct purpose (disambiguating "no
      gate ever ran" from "a gate ran on a commit I cannot see" — `status.sh:137-138`).
- [ ] No material regression in lookup cost: still bounded by the number of *distinct*
      commits ever gated, not by the number of gate lines (many rounds commonly share one
      commit) — `coverage_scan()`'s neighboring comment in the same file measured a
      per-commit-subprocess design at 61s for 63 commits, which is exactly the class of cost
      bug this must not reintroduce.

## Out of scope

- The separate, duplicated `LAST_GATE_LINE` / `LAST_COMMIT` computation inline in
  `tools/status.sh` (lines ~88-98) that also does `grep ... | tail -1`. It answers a
  genuinely different question — "what did the ledger's tail literally say, for the LAST
  GATE display line" — not "what is the newest verified anchor for computing an unrouted
  range." Not touched here.
- Any change to `ledger.sh add`'s `--commit` flag or to when/how retro-logging happens.
  That capability is legitimate and documented; this fix only makes `coverage_anchor()`
  correct in its presence.
- The other three items already queued behind this one in `SESSION-HANDOFF.md`
  (R-005, R-006, the deferred P2-8 items) — separate changes.

## Assets required

N/A — no non-code deliverables.

## Prior art

N/A — Scout (G2) fires only for net-new user-facing capability (`cards/G2-scout.md`); this is
a bug fix in an internal library function.

## Acceptance (G1b — after Build)

| Criterion | Evidence |
|---|---|
| Returns the gate-verified commit with the latest timestamp, not the physically-last line | `tests/run.sh:test_coverage_anchor_ignores_a_retro_logged_older_commit_appended_last` — fails against `master`'s `coverage_anchor()`, passes against the fix |
| An unresolvable commit is still skipped | unchanged code path (`git log -1 --format=%ct "<sha>^{commit}" --` empty on failure), still exercised by `test_status_says_so_when_the_ledger_commit_is_not_in_this_repo` and the fleet/outside-repo `coverage_*` tests (all still green) |
| Empty/no-gate ledger still returns empty | unchanged early returns (`[ -f ] ||`, `[ -n "$_cov_shas" ] ||`); `test_status_reports_unrouted_t4_work_when_nothing_was_ever_gated` still green |
| Regression test fails pre-fix, passes post-fix | confirmed manually: `git show master:tools/lib/coverage.sh` swapped in, same test run, failed; fix restored, same test run, passed |
| `coverage_claimed_anchor()` untouched | not edited — `tools/lib/coverage.sh` diff touches only `coverage_anchor()` |
| Cost bounded by distinct commits, not gate lines | `sort -u` on extracted shas before the per-candidate `git log` call — one call per distinct commit, however many rounds/gates reference it |

**Target coverage** (reconcile.sh's T3/T4 checklist for this diff): Git Bash on Windows —
manually run in this session (discrimination proof + full 668-test suite). Linux/macOS bash —
not run manually here; relies on `.github/workflows/tests.yml`'s ubuntu/macos legs, which run
the same `tests/run.sh` unmodified. Installed at `.pipeline/` — this IS the new test's fixture
(`newrepo`). Kit as its own repo (`INCLUDE_KIT=1`) — N/A for this function: `coverage.sh` never
reads `INCLUDE_KIT` (grepped, zero hits); that flag only affects `reconcile.sh`'s own path
exclusion, not `coverage_anchor()`'s logic.

## Restatement

Fix `coverage_anchor()` so the physical order gate lines are appended in `ledger.jsonl` cannot
override which reviewed commit is actually the most recent one, since a legitimate retro/
backfilled `--commit` entry can be appended after a later, real one.
