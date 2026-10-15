# coverage-anchor-head-ancestor-filter — Tasks

> Written at Triage, after design is confirmed. This is the plan and the record.

## Routing

| | |
|---|---|
| **Predicted tier** | T4 |
| **Surfaces touched** | `tools/lib/coverage.sh` (T4 — "decides what counts as unrouted"), `tests/run.sh` (T3 — the suite) |
| **Visibility** | behavior-changing — `coverage_anchor()` resolves an anchor in a state where it previously returned none, changing `status.sh` / dashboard output |
| **Targets** | Git Bash on Windows (this session — repro + discrimination proof + full suite); Linux/macOS bash (CI legs — **GitHub Actions disabled for non-payment since 2026-09-08**, so unconfirmable this session; the two new git calls are portable ≥1.8.0 with no platform branch); Installed at `.pipeline/` (`newrepo` fixture); Kit as its own repo (N/A — `coverage.sh` never reads `INCLUDE_KIT`) |

## Gates to run

From T4 (`core/01-router.md`): G1, G4, G5, G7 all **M**; G6 **M**; G7 **M (hard)**; G8 **M**.
G2 Scout — **not selected** (R¹, net-new capability only; this is an internal fix). G3 Craft —
**not selected** (R², UI surface only; no UI).

- [x] G1 · Intent — requirements + design + tasks confirmed; acceptance table filled post-Build. **pass**, round 1
- [x] G4 · Ripple — fresh subagent; couplings walked and performed; independence 5/5, ships alone. **pass**, round 1 (1 minor: missing risks.md row → resolved same round as R-007 + map.md:33 refresh)
- [x] G5 · Proof — regression tests written; discrimination proof (returns `""` pre-fix, HEAD-side sha post); suite 759/0/0 on rebased base. **pass**, round 1
- [x] G6 · Peer — fresh subagent, received the diff; walked all 8 no-anchor paths + filter block; exit-status contract intact; discrimination confirmed (all 3 tests fail on `feac364^`). **pass**, round 1
- [x] G7 · Threat — fresh subagent, **HARD GATE** — attacked unquoted `$_cov_fulls`, `grep -vxF` surface, `--no-walk` cross-version, and whether narrowing the divergence-refusal scope drops a guard (it does not). Every failure mode degrades to "no anchor / whole-history scan". **pass**, round 1
- [x] G8 · Dogfood — fresh subagent; live repo + 3 isolated scratch repros (orphan / only-HEAD / real-merge) all correct + deterministic; dashboard JSON matches `status.sh`. **pass**, round 1 (1 out-of-scope: "not found in this repo" text wrong on the merge-divergence path → filed to requirements out-of-scope / R-007)

**Compliance:** `bash tools/ledger.sh compliance --change coverage-anchor-head-ancestor-filter --tier T4 --round 1` → *All T4-mandated gates satisfied at round 1.* G2 Scout / G3 Craft footnotes do not fire (no net-new capability, no UI).

## Steps

Ordered, each independently verifiable.

- [ ] **1. Reproduce first (G1a discipline).** In a scratch repo (`newrepo`-style, or a throwaway
      git repo): commit A on `main`, log a gate on A; branch off, commit B on the branch, log a
      gate on B; `git checkout main`, `git branch -D` the branch so B is orphaned but its object
      survives; commit C on `main`, log a gate on C. Confirm pre-fix `coverage_anchor()` returns
      `""` (B and C are `merge-base --independent` tips). **Verify:** `coverage_anchor` prints
      nothing, exit 0.
- [ ] **2. Implement the filter** in `tools/lib/coverage.sh`, between `_cov_fulls=` (line ~138)
      and `_cov_independent=` (line ~139): HEAD-resolves guard → `git rev-list --no-walk
      $_cov_fulls --not HEAD` → `grep -vxF` subtraction (only when non-empty) → `[ -n "$_cov_fulls" ]
      || return 0`. **Verify:** on the step-1 repro, `coverage_anchor` now prints C's short sha,
      exit 0.
- [ ] **3. Write the header-comment paragraph** in `coverage.sh` explaining: object-exists ≠
      HEAD-reachable; append-only ledger + rebase/squash = legitimate orphans; the filter runs
      before `merge-base --independent` so an orphan is never a candidate; the divergence
      refusal is now scoped to genuine HEAD-side merge ambiguity; note that `map.md:33`
      anticipated the inverse symptom. **Verify:** comment reads coherently against the code;
      no apostrophe-in-single-quoted-awk hazards (not awk here, but house discipline).
- [ ] **4. Rewrite** `tests/run.sh:test_coverage_anchor_returns_no_anchor_for_divergent_branches_rather_than_guess`
      (line ~3683): keep the two-divergent-commits setup, but since `branch-one`'s commit is not
      an ancestor of HEAD (`branch-two`), assert the anchor now resolves to **`branch-two`'s tip**,
      not `""`. Rename to reflect the new meaning (e.g.
      `test_coverage_anchor_ignores_an_unmerged_gated_commit_and_anchors_to_head_side`).
      Update its comment block. **Verify:** test passes post-fix; run it in isolation.
- [ ] **5. Add** `test_coverage_anchor_ignores_an_orphaned_gated_commit_from_a_deleted_branch`
      — the step-1 scenario as a `newrepo` test. Must **fail against `git show <base>:tools/lib/coverage.sh`**
      swapped in, pass against the fix (discrimination proof, done manually + encoded).
      **Verify:** both directions, recorded in the G5 ledger note.
- [ ] **6. Add** `test_coverage_anchor_still_refuses_genuine_head_side_divergence` — a repo where
      HEAD is a real merge commit of two branches, a gate logged on a commit on each pre-merge
      line; both are ancestors of HEAD, neither descends from the other; assert `"anchor":""`.
      This pins that the fix **narrowed** rather than removed the refusal. **Verify:** passes;
      run twice for determinism (matching the existing divergence test's own re-run assertion).
- [ ] **7. Full suite** — `bash tests/run.sh`. **Verify:** 0 failed, 0 skipped beyond the
      pre-existing platform skips; note pass count vs. the pre-change baseline (currently 689).
- [ ] **8. Regenerate the dashboard** (`bash tools/dashboard.sh`) so its Coverage panel reflects
      the now-resolvable anchor — `status.sh` flagged it stale independently of this change, but
      this change is what makes the panel correct. **Verify:** `status.sh` no longer prints the
      whole-history fallback; the unrouted list is real (this change's own commits, pre-route).

## Reconciliation

Run after Build, before release:

```bash
CHANGE=coverage-anchor-head-ancestor-filter bash tools/reconcile.sh T4 --log
```

| | |
|---|---|
| **Actual tier** | T4 (`tools/lib/coverage.sh` T4, `tests/run.sh` T3 — max T4) |
| **Verdict** | reconciled — predicted T4 == actual T4, `match`, logged round 1 |
| **Gates re-run** | n/a — single round; R0c hook fired on each planned edit (expected, this IS the routed change), covered by the round-1 reconcile |

Route: `{"type":"route",...,"predicted":"T4","actual":"T4","verdict":"match","reason":"Bug fix: coverage_anchor() treated an object-exists check as reachability, so one orphaned gate entry blanked the whole coverage signal"}`

## Acceptance

Filled in at Intent · Accept, after Build. **A criterion without evidence was not built.**
Mirrors `requirements.md`'s G1b table — copy final evidence there.

| Criterion | Evidence |
|---|---|
| Candidates filtered to HEAD-ancestors before `merge-base --independent` | `git show feac364` — `tools/lib/coverage.sh` block after `_cov_fulls=` |
| Orphan + real anchor → resolves to the real anchor, not `""` | `test_coverage_anchor_ignores_an_orphaned_gated_commit_from_a_deleted_branch` (green); live on this repo: pre-fix `""` → post-fix `74091df` |
| HEAD-is-newest-gate → anchor == HEAD, empty range | `test_coverage_anchor_ignores_an_unmerged_gated_commit_and_anchors_to_head_side` (branch-two tip = HEAD); manual scratch-repo single-gate-on-HEAD → HEAD sha |
| Genuine merge divergence → still `""` | `test_coverage_anchor_still_refuses_genuine_head_side_divergence` (green, run twice); manual octopus-merge repro `anchor=[] exit=0` |
| Non-HEAD-ancestor `--commit` cannot influence the anchor | same orphan test — B is a `--commit`-shaped entry off HEAD's line, filtered |
| Unresolvable commit still skipped; empty ledger still empty; exits 0 on every no-anchor path | `bash tests/run.sh coverage_anchor` → 31/0/0 (incl. exits-zero, glob-value, retro-order, ancestry-not-date tests); manual empty/no-gate/missing/all-bad ledgers → `[] exit 0` |
| `coverage_claimed_anchor()` untouched | `git show feac364` — not in the diff |
| Cost bounded by distinct commits | one `git rev-list --no-walk` + one `git rev-parse --verify HEAD`, total — not per gate line, not per commit |
| Old divergence test rewritten; full suite green | rename + assertion flip in `feac364`; `bash tests/run.sh` → **759 passed / 0 failed / 0 skipped** (rebased onto origin/master) |

## Ledger

One line per gate run appended to `ledger.jsonl`, `--change coverage-anchor-head-ancestor-filter`
`--tier T4` `--model claude-sonnet-5` `--tokens N`. Route record via the reconcile command above.
Assumptions already logged (round 1): approach (asked), test rewrite (asked), scope (verified).
