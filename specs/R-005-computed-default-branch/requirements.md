# R-005-computed-default-branch — Requirements

> Written at the Intent gate (G1a), before Build. Resolves risk **R-005** in
> `project/risks.md` (review-by 2026-10-03). Bug-shaped hardening, not a feature —
> Prior art and Assets are N/A rather than deleted, so the template's shape stays legible.

## User

Anyone running `tools/ledger.sh` (`route`/`add`/`escape`/`assume`) or `tools/reconcile.sh
--log` **from a repository whose real trunk branch is not one of `master`/`main`/`develop`/
`development`/`dev`/`trunk`** — e.g. `prod`, or a team naming convention. Also anyone reading
that repo's dashboard, where the read-side guard (`changeIsBranchy` in
`tools/dashboard/app.js`) decides whether a branch-named record renders as a muted routing
artifact or as a real change.

## Problem

`change_is_branchy()` (`tools/ledger.sh:211`), mirrored as `changeIsBranchy()`
(`tools/dashboard/app.js:161`), decides whether a `--change` value is a long-lived branch
name (a stray reconcile that correlates with no gates — P1-5) via a **hand-enumerated list**:

```
master main develop development dev trunk HEAD unknown
```

This is deliberately conservative — it lists only unambiguous trunk names, because `release`,
`stable`, `mainline` are plausible real change names and must NOT be refused. But it is the
exact "**condition is a list of cases, not a computed property**" shape that G4 Ripple's own
card warns against (`core/cards/G4-ripple.md:104-115`), and the risk entry names it as such.

**Consequence, unfixed:** a repo whose actual default branch is `prod` (or any non-listed
name), reconciling on that branch with no `CHANGE=` set, still writes a `route` record named
`prod`. `reconcile.sh` defaults `--change` to `git rev-parse --abbrev-ref HEAD`, so `prod` is
exactly the value it writes. That record joins with no gates, pollutes the reconcile
miss-rate metric, and renders on the dashboard as a `master`-style pseudo-change — and the
read-side guard, sharing the same hand-list, does not flag it either. Silent and confident,
which is why `tools/ledger.sh` is a T4 surface.

**Deferred originally because** the computed check adds a `git` dependency to `ledger.sh`.
Reproduced this session that this is not a new dependency: `ledger.sh` already shells out to
git at module load (`git -C "$KIT_ROOT" rev-parse --show-prefix/--show-toplevel`, lines
126-127) and on every `add`/`route`/`assume` via `detect_commit()` (`git rev-parse --short
HEAD`, line 355). `reconcile.sh` already resolves `git symbolic-ref --quiet --short
refs/remotes/origin/HEAD` for its BASE chain (line 312). The dependency is confirmed
acceptable — see the Assumptions section.

## Acceptance criteria

> All met — landed on `master`, all T4 gates passed (3 rounds). Evidence per row in the
> **Acceptance (G1b)** table below. Note: round 2 relocated `resolve_default_branch()` out of
> an inline block in `ledger.sh` into the shared, sourced `tools/lib/default-branch.sh` (new
> T4 surface) — `ledger.sh` still resolves `DEFAULT_BRANCH` once at module load.

- [x] `tools/ledger.sh` gains `resolve_default_branch()`: returns the target of
      `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` with the `origin/` prefix
      stripped; failing that, `git config --get init.defaultBranch`; failing that, empty.
      Computed **once** at module load into `DEFAULT_BRANCH`, not per call (matches how
      `KIT_ROOT` and the `LEDGER` default are resolved), against the cwd repo (matches
      `detect_commit()` and how `reconcile.sh` derives the `--change` default).
- [x] `change_is_branchy()` refuses `"$1"` when it equals a non-empty `DEFAULT_BRANCH`
      **first**, then falls through to the existing hand-enumerated `case` list unchanged.
      The hand-list is the fallback for "git resolved nothing" (bare local repo, no
      `origin/HEAD`, unset `init.defaultBranch`) — the behaviour this check had before.
- [x] `tools/dashboard.sh` computes the same value (same two git lookups, same fallback
      order) against the repo it runs in, and bakes it into the emitted model as
      `"defaultBranch":"<name>"` (`""` when unresolved). It is `json_escape`d like every
      other model string. `--print-model` shows it.
- [x] `tools/dashboard/app.js`'s `changeIsBranchy(name)` returns `true` when
      `PIPELINE.defaultBranch` is a non-empty string equal to `name`, **before** the
      existing hand-list check. Undefined/empty `PIPELINE.defaultBranch` (the JS unit-test
      harness, an older generated page) changes nothing — hand-list only, as today.
- [x] The two hand-enumerated fallback lists stay byte-identical between `ledger.sh` and
      `app.js` (`test_branchy_change_list_matches_between_ledger_and_dashboard` still passes
      — its extraction regexes still resolve).
- [x] Regression tests in `tests/run.sh`:
      - **(a)** a repo whose resolved default branch is `prod` refuses a `route`/`add`
        record named `prod`, and — discrimination proof — the *same* name `prod` is
        **accepted** in a repo where it is not the resolved default (plain `newrepo`),
        proving the hand-list alone never caught it and the computed check is the only
        thing refusing it in (a). Both the `origin/HEAD` path and the `init.defaultBranch`
        path are exercised.
      - **(b)** the hand-enumerated names (`master`, `trunk`, `unknown`, …) are still
        refused when git resolves **no** default branch (repo with no remote and
        `init.defaultBranch` set empty), proving the fallback is intact.
- [x] JS regression test in `tests/dashboard-logic.test.js`: `changeIsBranchy('prod')` is
      `true` when `PIPELINE.defaultBranch === 'prod'`, `false` when it is unset; `master`
      stays `true` in both.
- [x] A `tools/dashboard.sh` integration test: a dashboard generated in a repo with
      `origin/HEAD → prod` carries `"defaultBranch":"prod"` in the page.
- [x] Full suite (`bash tests/run.sh`) green before commit and again before landing.
- [x] `project/risks.md`'s R-005 row is updated: the fix **narrows** the risk, it does not
      close it, so the row stays `mitigate` with a fresh review date and the remaining
      residues stated explicitly (git-can't-resolve config on the write side too; fleet
      view; the module-load subprocess race). Retiring it outright would be an over-claim
      (G4 Ripple, round 1).

## Out of scope

- **Closing every residue.** The fix narrows R-005; it does not close it. Residues that
  stay recorded on the (still `mitigate`) R-005 row: (1) *git resolves nothing* — no
  `origin/HEAD` ref **and** no `init.defaultBranch` — falls back to the hand-list on the
  write side too, not just the dashboard; (2) a `--project` fleet dashboard bakes one
  `defaultBranch` (the repo `dashboard.sh` ran in), so a foreign project on a non-standard
  trunk keeps the hand-list for its rows; (3) the module-load `git` subprocess can fail
  transiently and resolve empty (degrades safe). Each still needs a non-standard trunk name
  AND a missing `CHANGE=`.
- **Widening the hand-list** (`release`, `stable`, `mainline`, …): explicitly rejected by
  the risk entry — those are plausible real change names.
- **`reconcile.sh`'s BASE resolution**: already computes `origin/HEAD`; not touched.
- **A `CHANGE=` override / opt-out for a team that genuinely names a change after its trunk
  branch**: G7 challenged this premise during P1-5 and it was accepted as residue in R-005.
  Not re-opened here — the computed check makes the *default* correct; an operator who
  deliberately wants a trunk-named change still sets `CHANGE=` and hits the refusal, same as
  today for `master`.
- **R-006** and the other queued items — separate changes.

## Assets required

N/A — no non-code deliverables.

## Prior art

N/A — Scout (G2) fires only for net-new user-facing capability (`core/cards/G2-scout.md`);
this is internal hardening of an existing guard.

## Assumptions (10-probe.md checkpoint 1 — logged via `ledger.sh assume`)

1. **The `git` dependency in `ledger.sh` is acceptable** — the risk entry says to "confirm
   this dependency is acceptable before implementing". `resolution: verified`, basis:
   `tools/ledger.sh:126-127,355` (already shells out to git at load and per-write) and
   `tools/reconcile.sh:312` (already does the identical `symbolic-ref` lookup).
2. **`origin/HEAD` then `init.defaultBranch` is the right resolution order**, matching the
   risk entry's own stated "known next step" and `reconcile.sh`'s BASE chain. `resolution:
   verified`, basis: `project/risks.md` R-005 row + `tools/reconcile.sh:298-321`.
3. **The JS side gets the name baked into the model by `dashboard.sh`**, not computed
   client-side — `app.js` has no git access. `resolution: verified`, basis:
   `tools/dashboard/app.js:159-160` (the existing comment already says the list is
   hand-enumerated *because* the JS side cannot resolve it) and `tools/dashboard.sh`'s
   existing git-derived `coverage` / `kitCommit` model fields.

## Acceptance (G1b — after Build)

| Criterion | Evidence |
|---|---|
| `resolve_default_branch()` added, `origin/HEAD` → `init.defaultBranch` → empty | `tools/ledger.sh` diff (function + `DEFAULT_BRANCH=` at module load) |
| `change_is_branchy()` refuses `DEFAULT_BRANCH` first, then the unchanged `case` list | `tools/ledger.sh` diff; `tests/run.sh:test_ledger_refuses_the_computed_default_branch_via_origin_head` + `_via_init_defaultbranch` |
| Discrimination: `prod` accepted when NOT the resolved default | `tests/run.sh:test_ledger_accepts_a_non_default_branch_name_as_the_change` — same name, opposite verdict, proves the hand-list never caught it |
| Hand-list fallback intact when git resolves nothing | `tests/run.sh:test_ledger_hand_enumerated_fallback_still_refuses_when_git_resolves_nothing` (master/main/…/unknown, `init.defaultBranch` pinned empty) |
| `dashboard.sh` bakes `"defaultBranch":"<name>"` (`""` unresolved), `json_escape`d, in `--print-model` | `tools/dashboard.sh` diff; `tests/run.sh:test_dashboard_model_carries_the_computed_default_branch` + `_default_branch_is_empty_when_git_resolves_nothing` + `_page_carries_*` |
| `app.js` `changeIsBranchy` checks `PIPELINE.defaultBranch` first, safe when absent/empty | `tools/dashboard/app.js` diff; `tests/dashboard-logic.test.js` — `changeIsBranchy refuses the computed PIPELINE.defaultBranch, before the hand-list` + `falls back to the hand-list only when … absent or empty` |
| Two hand-lists stay byte-identical + both keep the computed check | `tests/run.sh:test_branchy_change_list_matches_between_ledger_and_dashboard` (extended) |
| Routing-artifact tagging follows the computed name | `tests/dashboard-logic.test.js:buildExecutions tags a default-branch route group as a routing artifact when the model names that branch` |
| Full suite green | `bash tests/run.sh` → `passed 730 · failed 0 · skipped 0` (Git Bash on Windows, 2026-09-06, pre-gate) |
| R-005 updated in `project/risks.md` | done in this diff — stays a live `mitigate` row (the fix narrows, does not close it), three residues stated, review date bumped to 2026-11-06. Retiring it was tried in round 1 and reverted after G4 Ripple flagged the over-claim. |

## Restatement

`change_is_branchy()` / `changeIsBranchy()` must refuse the repository's **actual** default
branch name — resolved from git (`origin/HEAD`, then `init.defaultBranch`) — not only the
names on a hand-written list, so a repo whose trunk is `prod` (or any team convention) cannot
silently write a route record that correlates with no gates. The hand-list stays as the
fallback for when git can resolve nothing.
