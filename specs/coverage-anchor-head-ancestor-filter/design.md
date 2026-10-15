# coverage-anchor-head-ancestor-filter — Design

> Written at the Ripple gate, after requirements are confirmed.
> Stop here and confirm before writing `tasks.md`.

## Approach

One insertion in `coverage_anchor()` (`tools/lib/coverage.sh`), between the candidate-resolve
loop and the `merge-base --independent` call. Nothing else in the kit changes — `status.sh`,
`tools/dashboard.sh`, and `tools/dashboard/app.js` all consume `coverage_anchor()`'s single
output string and do not reimplement any of its logic.

### Current shape (`tools/lib/coverage.sh:91-167`)

```
grep gate lines → distinct commit strings (sort -u)          # bounded by distinct commits
  for each: git rev-parse --verify -q "<sha>^{commit}"       # object EXISTS here?  →  _cov_pairs
_cov_fulls = full shas from _cov_pairs (sort -u)
_cov_independent = git merge-base --independent $_cov_fulls
  count == 1  →  that commit is the anchor
  count  > 1  →  return no anchor (genuine divergence, refuse to guess)
```

### New shape

```
… _cov_fulls = full shas from _cov_pairs (sort -u)
+ if HEAD resolves:
+   _cov_notanc = git rev-list --no-walk $_cov_fulls --not HEAD     # candidates NOT on HEAD's history
+   _cov_fulls  = _cov_fulls with those lines removed (grep -vxF)
+ [ -n "$_cov_fulls" ] || return 0                                  # nothing on HEAD's line → no anchor
_cov_independent = git merge-base --independent $_cov_fulls
  … unchanged from here down
```

### Why a HEAD-ancestor filter, and why here

`git rev-parse --verify -q "<sha>^{commit}"` (line 127) answers *"is this a commit object in
this repo's store"*. It does **not** answer *"is this commit reachable from HEAD"*. Those
diverge exactly when a gate was logged against a branch commit that was later rebased or
squashed on merge: the ledger is append-only and never rewrites the entry (`04-ledger.md`),
and the orphaned object lingers through git's gc grace window (default two weeks; longer
while any worktree reflog holds it). That orphan then enters `merge-base --independent` as a
**legitimate independent tip** — nothing descends from it because it was never merged — so
the `-eq 1` guard fails and the function returns no anchor. One stale entry blanks the whole
coverage signal.

The filter belongs *before* `merge-base --independent`, not as a tie-break after it: the
orphan must never be a candidate in the first place. It is not a rival for "newest reviewed
commit on this branch" — it is on a different branch.

### Filter mechanism: one `git rev-list`, not a loop

```sh
_cov_notanc="$(git rev-list --no-walk $_cov_fulls --not HEAD 2>/dev/null)"
```

`--no-walk` = show only the listed commits, do not traverse parents. `--not HEAD` = drop
anything reachable from HEAD. Output = precisely the candidates that are **not** ancestors
of HEAD (and not HEAD itself). Verified in this repo: over the 67 resolvable gated commits it
returns exactly `6fc2570` — the one orphan.

- `$_cov_fulls` is unquoted on purpose — same as the existing `merge-base --independent
  $_cov_fulls` one line below. Every element is a `rev-parse --verify`-resolved full hex sha
  (40 under SHA-1, 64 under SHA-256), so it can never be option-shaped or contain a glob
  metacharacter. `set -f` is already restored (line 131) by this point.
- **Graceful degradation of `--no-walk`.** git's manual notes `--no-walk` "has no effect if
  a range is specified", and `--not HEAD` may count as one on older git. If `--no-walk` is
  ignored, the command instead lists each non-ancestor candidate *plus its own unmerged
  ancestors* — a superset that still contains every sha we need to remove, and removing a
  sha that was not in `_cov_fulls` is a no-op. So the filter is correct either way; `--no-walk`
  is a cheapness optimization, not a correctness dependency.
- Subtraction is `grep -vxF` (`-x` whole line, `-F` each pattern line literal, `-v` invert) —
  POSIX, no regex exposure from a sha.

### Alternative considered — `git merge-base --is-ancestor` per candidate

One `git merge-base --is-ancestor "$c" HEAD` call per distinct commit (~68 here). Correct and
unambiguous, no `--no-walk` caveat. Rejected as the primary because it is N subprocesses
where the `rev-list` form is one, and `tools/lib/coverage.sh`'s own neighboring comment
(`coverage_scan`, line 183-191) documents a per-commit-subprocess design measured at 61s for
63 commits on Git Bash as the cost class to avoid. Kept documented as the fallback if a G6/G7
round finds the `rev-list` form unreliable on a target git.

### HEAD does not resolve (empty repo, unborn branch)

Guard with `git rev-parse --verify -q HEAD >/dev/null` before the filter. If HEAD has no
commit, there is nothing to be an ancestor *of*, and there are no resolvable gated commits
anyway (the loop above produced none) — so the filter is simply skipped and the existing
`[ -n "$_cov_pairs" ] || return 0` on line 132 already handled it.

## Couplings triggered

From `project/registry.md` (curated registry is **empty** — the `status.sh` "G4 would invent
its input" warning is expected and pre-existing, not introduced here). `project/map.md`'s
silent-failure table is the applicable coupling record.

| Registry entry | Check performed | Result |
|---|---|---|
| `project/map.md:33` — `tools/lib/coverage.sh` is *"shared by `status.sh` and the dashboard so they cannot disagree"* | Traced both consumers: `tools/status.sh:138` (`SINCE_REF="$(coverage_anchor "$LEDGER")"`) and `tools/dashboard.sh:563` (`_cov_anchor="$(coverage_anchor "$_cov_led_abs")"`). Both take the return string verbatim; neither derives or second-guesses the anchor. `tools/dashboard/app.js` never computes an anchor (comment at app.js:1481 — "a browser has no git"). | The fix propagates to both surfaces with zero coordination. No divergence risk. |
| `core/03-registry.md` universal couplings | Scanned: auth/session, migrations/rollback, quotas/enforce-at-write, id-space, load-order. None apply — this is a read-only shell function with no persisted state, no schema, no shared namespace. | None triggered. |
| `project/map.md:33` failure mode is recorded as *"a wrong anchor prints '0 commits since', the best-looking possible answer"* | This bug is the **inverse** of what map.md anticipated — a wrong (absent) anchor prints *everything* as unrouted, the worst-looking answer, not the best. The row's point (coverage failure is silent-until-inspected) still holds; the direction was incomplete. | Header comment calls it out; **G4 Ripple round 1 required more** — `map.md:33` refreshed to name both directions, and **R-007** added to `project/risks.md` for the now-sole merge-divergence no-anchor path (the Ripple card's Part 4: a limitation needs a named decision, not a comment). |

## Edge decisions

| Edge | Decided behavior | Decided by |
|---|---|---|
| Zero gated commits / no ledger | Unchanged — early returns at lines 93, 98, 132 fire before the filter. | existing contract |
| One gated commit, is a HEAD ancestor | Filter removes nothing → `merge-base --independent` → that commit is the anchor. | design |
| One gated commit, NOT a HEAD ancestor (running coverage from a fully divergent branch) | Filtered out → `_cov_fulls` empty → `return 0`, no anchor → callers scan whole history and say so. Correct: no gate has reviewed anything on *this* line. | design |
| Many candidates, one HEAD-ancestor tip | Resolves to that tip (the common case; this repo → `74091df`). | design |
| Many candidates, ≥2 HEAD-ancestor tips mutually non-descending (HEAD history contains merges) | `merge-base --independent` returns >1 → existing `-eq 1` guard → no anchor. **Residual, documented, not solved** — picking one needs a rankable signal, the door rounds 3-4 closed. | requirements / carried from `coverage-anchor-retro-fix` |
| Null / empty: `_cov_notanc` empty (all candidates are ancestors) | `grep -vxF ""` would match-invert nothing sensibly → guard with `[ -n "$_cov_notanc" ]` and skip subtraction entirely when empty. | design |
| Null / empty: `_cov_fulls` empty after subtraction | `[ -n "$_cov_fulls" ] || return 0`. | design |
| Concurrent access: ledger appended, or HEAD moves, mid-read | Pre-existing property. Each `coverage_anchor()` call reads one consistent HEAD; a race yields at worst a one-run-stale anchor that self-corrects next invocation. No write path here. | existing contract |
| Slow / offline / timeout | N/A — all operations are local git object reads. | — |
| Interrupted halfway | N/A — pure function, no side effects, nothing to leave half-done. | — |
| First run vs upgrade | First run = no ledger = early return. "Upgrade" = a longer ledger = more candidates, same algorithm. | design |
| Permission denied (cannot read ledger) | Existing `[ -f "$_cov_ledger" ] || return 0` (line 93). | existing contract |
| Detached HEAD / unborn branch | `git rev-parse --verify -q HEAD` guard → skip filter; no resolvable candidates exist in that state anyway. | design |

## Error contract

| Failure | User | Developer | System |
|---|---|---|---|
| Filter removes every candidate (`_cov_fulls` empty) | Sees `status.sh` / dashboard say "no gated commit to anchor to — counting the whole history" (existing no-anchor copy, `status.sh:150-153`, `app.js:1570`). | Nothing logged — pure read function, by design (matches every other no-anchor path). | Degrades to whole-history scan — identical to today's `count > 1` and unresolvable-sha paths. |
| `git rev-list` errors (corrupt repo, exotic git) | Same as above — `2>/dev/null`, empty `_cov_notanc`, no subtraction, falls through to unchanged `merge-base --independent`. | Silent — consistent with the function's existing `2>/dev/null` on every git call. | No worse than pre-fix behavior for that repo. |
| No *new* user-facing error mode is introduced. | | | |

## Silent failure

> **How would we know if this filter itself broke?**
>
> Two directions:
> - **Too aggressive** (filters out a legitimate anchor): `status.sh` starts reporting
>   "whole history" / a wildly inflated unrouted count on a repo that was fine. That is
>   loud on the one screen this signal lives on — it is exactly the symptom that triggered
>   this investigation. Pinned by the rewritten divergence test + the new "HEAD is newest
>   gate" criterion (anchor must equal HEAD, range empty).
> - **Too lax** (orphan still poisons the set): the original bug returns. Pinned by the new
>   orphan regression test, which must **fail against the pre-fix function** (discrimination
>   proof, run manually this session per the T4 target-coverage rule) and pass after.
>
> The function has no telemetry and should not grow any — it is one of several no-anchor
> paths and they are all deliberately quiet, because `status.sh`/the dashboard are the
> place the absence is surfaced, honestly, every session.

## Independence

- [x] No new shared symbol in a shared scope — new vars are `_cov_notanc` only, same
      `_cov_`-prefixed function-local convention as the rest of the file.
- [x] No storage key added or renamed that another module reads — no persisted state.
- [x] No id/priority consumed from a shared space.
- [x] No dependence on load order — `coverage.sh` is sourced; this changes only the body of
      one already-defined function.
- [x] Tests pass with no other pending change applied — this is the only change in flight.

**Verdict:** independent. Ships alone.
