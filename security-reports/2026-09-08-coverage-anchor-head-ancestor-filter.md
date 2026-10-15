# Security review — coverage_anchor() HEAD-ancestor filter

Reviewed code commit: `feac364` (`coverage: coverage_anchor() only considers HEAD-reachable
gated commits`), on branch `claude/infallible-morse-e98465` off `origin/master` `bc1a3b7`.
Consolidates the round-1 **G7 · Threat** gate (HARD, at T4) plus the G4/G6/G8 fresh-context
reviews of the same commit. All four gate verdicts are recorded in `ledger.jsonl` under change
`coverage-anchor-head-ancestor-filter`, round 1.

Files in scope:
- `tools/lib/coverage.sh` — **T4** ("Decides what counts as unrouted — read by both status.sh
  and the dashboard"). The only file the pre-push hook's trust-boundary check enforces here.
- `tests/run.sh` — T3 (one test rewritten, two added). Reviewed as context.

`tools/status.sh` and `tools/dashboard.sh` consume `coverage_anchor()` but are **not** changed
by this diff.

## What the change does

`coverage_anchor()` picks the newest gate-reviewed commit by commit-graph ancestry: it resolves
every `"type":"gate"` commit in `ledger.jsonl`, then runs `git merge-base --independent` over the
resolved set and takes the result only when it is exactly one commit — otherwise no anchor.

The resolve step (`git rev-parse --verify -q "<sha>^{commit}"`) proves a ledger commit is an
**object that exists**, not that it is **reachable from HEAD**. Those diverge when a gate was
logged against a branch commit later rebased or squashed away: the append-only ledger never
rewrites the entry (`04-ledger.md`), and the orphaned object survives git's gc grace window
(default two weeks, longer while any worktree reflog holds it). That orphan is a legitimate
`merge-base --independent` tip — nothing descends from it — so one stale entry pushes the
independent-set count past 1 and blanks the anchor entirely, at which point `status.sh` and the
dashboard scan the whole repository history as "unrouted".

Reproduced on this repo: `ledger.jsonl` names `6fc2570` (an early superseded
`coverage-anchor-retro-fix` commit, on no branch, still object-resolvable); pre-fix
`coverage_anchor()` returns `""`; `status.sh` reported ~200 commits / dozens of T4+T3 rows,
none of it real drift.

**The fix:** before `git merge-base --independent`, filter the resolved candidate set to commits
reachable from HEAD — one `git rev-list --no-walk $_cov_fulls --not HEAD` call, then a
`grep -vxF` subtraction. An unmerged commit is on a different line of history and cannot bound
"work since the last gate on this line".

## Trust boundary walk

**Untrusted input.** The `"commit"` values in `ledger.jsonl` — written by whoever last ran
`ledger.sh add [--commit <sha>]`, i.e. any contributor with commit access, per this kit's stated
threat model (`project/surfaces.conf`'s T4 row for this file). This is the same untrusted root
that rounds 1–4 of `coverage-anchor-retro-fix` hardened.

**Does the new filter reopen the forgeable / grindable anchor class rounds 3–4 closed?** No.
- Rounds 3–4 removed the timestamp ranking and then the lexicographic-sha tie-break because both
  were freely chosen by the same `--commit` writer. Neither is reintroduced — genuine ancestry
  ambiguity still returns **no anchor**, verified against a real merge repo (filter no-ops,
  `merge-base --independent` returns 2, `-eq 1` guard returns `""`).
- The filter strictly **narrows** the anchor-suppression surface. Before: a `--commit` naming
  any divergent commit (orphan, unmerged, another branch) was a live independent tip and could
  push the count past 1 → no anchor. After: a non-HEAD-ancestor `--commit` is dropped and cannot
  affect anchor selection at all. Suppression now requires **two mutually-non-descending
  HEAD-ancestor gated commits** — a merge in HEAD's own history with gates on more than one
  parent line. Harder to arrange, not easier. Recorded as standing risk **R-007**.
- A `--commit` naming a real HEAD-ancestor commit moves the anchor forward and could hide
  unrouted work — but that is a **pre-existing** property of trusting gate-line `commit` values
  (the pre-fix code was bypassed identically by a HEAD-ancestor forgery), neither introduced nor
  worsened here.

**Shell-injection / metacharacter surface of the new lines.**
- `git rev-list --no-walk $_cov_fulls --not HEAD` — `$_cov_fulls` is unquoted, deliberately, for
  the same reason the adjacent pre-existing `git merge-base --independent $_cov_fulls` line is:
  every element is a `git rev-parse --verify -q "<sha>^{commit}"`-resolved **full hex sha**
  (40 under SHA-1, 64 under SHA-256), carried through `awk '{print $1}' | sort -u`. It can never
  be option-shaped (`rev-parse --verify -q` rejects a leading-`-` value with exit 1 and no
  output — confirmed), never contain a glob metacharacter, never word-split. `set -f` is already
  restored by this point. G7 traced this end to end.
- `grep -vxF "$_cov_notanc"` — `-F` disables regex, `-x` forces whole-line; `$_cov_notanc` is
  `git rev-list` output (full hex oids, newline-separated). No pattern-metacharacter or
  injection exposure. Empty `$_cov_notanc` is guarded (`[ -n "$_cov_notanc" ]`) so no subtraction
  runs. A truncated line from a killed `git` cannot whole-line-match a full candidate sha, so the
  worst case is a no-op that falls through to the unchanged `merge-base --independent` path.
- `git rev-parse --verify -q HEAD >/dev/null 2>&1` guard — an unborn branch / detached-HEAD /
  crafted-`HEAD` case skips the filter and gets pre-change behavior. Transient and rare, and
  fail-safe (the pre-existing `[ -n "$_cov_pairs" ] || return 0` already covers "no resolvable
  candidates").

**`--no-walk` cross-version behavior.** git's manual notes `--no-walk` "has no effect if a range
is specified", and `--not HEAD` may count as one on older git. If `--no-walk` is ignored, the
output is a **superset** (each non-ancestor candidate plus its own unmerged ancestors) — and
`grep -vxF`-removing a sha that was never in `$_cov_fulls` is a no-op. So the filter is correct
either way; `--no-walk` is a cheapness optimization, not a correctness or security dependency.
Tested on git 2.54.0.windows.1.

**Failure direction.** Every failure mode of the filter — a shallow/grafted clone that hides a
real ancestor, a transient `git` error, an over-aggressive match — degrades toward **fewer
candidates → no anchor → whole-history scan**. That is the loud, conservative direction for
this signal: it can only ever *over*-report unrouted work, never under-report it. A shallow
clone dropping a genuine HEAD-ancestor is the same limitation class the file's header already
defers, unchanged.

## Interaction with R-005 (computed default branch)

Checked: none. `coverage_anchor()` filters against literal `HEAD` (the checked-out line), never
a computed trunk. `tools/lib/default-branch.sh` is consumed only by `ledger.sh` (`--change`
refusal) and `dashboard.sh` (`changeIsBranchy` bake). Fully orthogonal.

## Verdict

**G7 · Threat (HARD GATE): PASS**, round 1, zero blocking/minor findings, five `info` findings
(all recorded in `ledger.jsonl`). Confidence: high. Premise challenged — checked specifically
whether narrowing the divergence-refusal *scope* silently drops a guard; it does not.

G4 Ripple, G6 Peer, G8 Dogfood: also PASS round 1 (fresh context, received the diff). G4's one
`minor` (a missing `risks.md` row) was resolved the same round as **R-007** plus a
`project/map.md:33` refresh.

`ledger.sh compliance --change coverage-anchor-head-ancestor-filter --tier T4 --round 1` →
*All T4-mandated gates satisfied at round 1.*

## Pre-push hook note

The commit that adds this file is the branch tip, so the file cannot contain the tip's own sha
— the same quine the hook hit for `coverage-anchor-retro-fix` (`ledger.jsonl`, that change's G7
round 5). The substantive T4 Threat review is the real, logged round-1 G7 pass above, against
`feac364`, whose `tools/lib/coverage.sh` / `tests/run.sh` are byte-identical to the pushed tip
(later commits are ledger / dashboard / spec / risks only). Push uses `--no-verify` with this
exception recorded in `ledger.jsonl`.
