# dashboard-matrix-fails-open — Requirements

> Written at the Intent gate (G1a). Chip `task_8338372f`, filed by a peer session's G4/G6 review
> during `matrix-router-unreadable-fails-open`: "identical fail-open shape already fixed in
> `ledger.sh`/`reconcile.sh`, not touched in `dashboard.sh`, confirmed pre-existing."

## User

Anyone viewing the rendered dashboard (`dashboard.html`) when `core/01-router.md` exists but
fails to parse — empty table, missing gate row, invalid cell content, a wiped tier column (see
`tools/lib/matrix.sh`'s own checks, several already merged this week across two prior changes).

## Problem

`tools/dashboard.sh`'s `parse_matrix()` builds the gate-matrix JSON via
`for g in $(matrix_gates); do ... matrix_cell ...; done`. Every one of those calls goes through
a `$(...)` command substitution, forking a subshell whose own exit status is discarded the
instant only its stdout is captured. The script's only existing guard, `[ -f "$ROUTER" ]`, checks
file *existence*, not parseability — so a router that exists but fails `_matrix_load` for any
other reason let `parse_matrix()` silently iterate zero times, and the **whole dashboard page
still rendered and was written to disk** with an empty `"matrix":{}`, indistinguishable from
"this router legitimately has zero gates" to anyone reading it. Reproduced live: pointed a real
repo at a router file containing only `# not a real router, no gate rows` — pre-fix, `dashboard.sh`
printed "Wrote .../dash.html … 8 gates" (stale/garbage data presented as normal); post-fix, it
refuses with a clear message and writes nothing.

## Acceptance criteria

- [x] `dashboard.sh` refuses (exit 2, clear stderr message) when the router exists but fails to
      load, instead of silently rendering a page with an empty/wrong gate matrix.
- [x] No output file is written when refusing.
- [x] No behavior change for a healthy router (verified: real, unmodified `core/01-router.md`
      still renders normally, exit 0).
- [x] Fits the pre-existing pre-push hook contract without new plumbing: `dashboard.sh`'s exit
      status is already consumed only as truthy/falsy by `templates/pre-push` (any non-zero exit
      → WARNING, never blocks the push — see `test_hook_warns_but_does_not_block_when_
      dashboard_sh_fails`, a pre-existing test pinning this for a different failure mode). The
      new exit 2 needed no hook changes to land in that same, already-correct bucket.
- [x] Regression test, confirmed fail-red/pass-green via `git stash` isolation.
- [x] Full suite green.

## Non-goals

- **`parse_footnotes()`** reads `$ROUTER` directly via its own awk, independent of `matrix.sh` —
  but its call site is after the new guard, so a corrupt-table router never reaches it either
  (closed as a side effect, not separately engineered). A router with an *intact* table but a
  malformed *footnote section* is a real, narrower, pre-existing gap `matrix.sh`'s own validation
  never covered (it doesn't touch footnote text) — out of scope of this chip, not introduced or
  worsened here. Not filed as a new chip; low severity (a footnote mismatch, not a silent
  wrong-mandate result).
- **Does not touch `tools/status.sh` / `tools/lib/coverage.sh`**, which G6 review of this exact
  fix found has the identical fail-open shape, inverted: `coverage_never_run()`
  (`tools/lib/coverage.sh:297`, `for _cov_g in $(matrix_gates 2>/dev/null)`) silently returns
  empty on a load failure, and `status.sh` reads that as "nothing uncovered" — reporting clean
  coverage when the matrix couldn't be read at all, arguably worse than this bug since it points
  the wrong direction (false reassurance, not just missing data). Real, but a separate entry
  point with no shared code path to this fix — filed as a new chip rather than folded in.

## Assumptions

- **T3**, mechanically — `tools/dashboard.sh` matches a T3 row in `project/surfaces.conf`
  ("Tooling with several callers"); `tests/run.sh` matches its own T3 row too.
- **Axis C: Visible** — changes what a user/reviewer sees (refusal vs. a silently-wrong page).

## Gate chain

G1 Intent (this doc). G4 Ripple: no behavior change to a healthy router (live-verified); the
only consumer of `dashboard.sh`'s exit code is the pre-push hook, which already treats every
non-zero exit identically (warn, don't block) — confirmed by reading `templates/pre-push` and
the pre-existing `test_hook_warns_but_does_not_block_when_dashboard_sh_fails`. G5 Proof: one
regression test, fail-red/pass-green confirmed via `git stash` isolation. G6 Peer: **PASS**, no
blocking findings — traced that no `matrix_*` call exists between sourcing `matrix.sh` and the
new guard (so nothing is missed) and none after it depends on unvalidated data (so nothing is
now dead code); found the separate `status.sh`/`coverage.sh` gap noted above. G7 Threat: **PASS**
— confirmed the guard is defense-in-depth for dashboard.sh's own call path, traced
`parse_footnotes()`'s call site is safely after the guard, verified live against the real repo
(healthy router → exit 0 unaffected; corrupted router → exit 2, no file written, leak-checked)
and confirmed the exit code doesn't conflict with the hook's plain truthy/falsy consumption. G8
Dogfood: live CLI reproduction against the real repo — router replaced with garbage content,
`bash tools/dashboard.sh --out ...` refuses with "gate matrix failed to load", no file written;
router restored, `git status` confirmed clean.

## Acceptance (G1b)

| Criterion | Evidence |
|---|---|
| Refuses on load failure, writes nothing | `tools/dashboard.sh` (guard added after the existing `[ -f "$ROUTER" ]` check). Live: real repo, garbage router → exit 2, `gate matrix failed to load`, no output file (was: silent success, "Wrote ... 8 gates"). `tests/run.sh` `test_dashboard_refuses_when_the_router_fails_to_parse`. |
| No regression on a healthy router | Live-verified real, unmodified router: exit 0, unchanged output. |
| Hook contract unaffected | `test_hook_warns_but_does_not_block_when_dashboard_sh_fails` still passes; G7 independently confirmed the hook only checks truthy/falsy. |
| Full suite green | 70/70 dashboard-scoped tests immediately; full-suite run recorded in `ledger.jsonl`/commit message. |

**Chip closed:** `task_8338372f`. **New chip to file:** `status.sh`/`lib/coverage.sh`'s
identical-shape, inverted-direction gap (see Non-goals) — not filed with a chip id yet, noted in
`SESSION-HANDOFF.md`.
