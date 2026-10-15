# Security review — coverage_anchor() retro-log ordering fix

Reviewed commit: `b9e9d3bd61cbc4382b9506b32777585f43c5e634` (HEAD of `master` after fast-forward
merging `coverage-anchor-retro-fix`) — consolidating four fresh G7 (Threat) rounds run across
the change's five commits (`ced1d7b`, `ae38f38`, `be4c6c6`, `a52a054`, `4045538`, `b9e9d3b`).

Files in scope: `tools/lib/coverage.sh` (T4 — "Decides what counts as unrouted — read by both
status.sh and the dashboard"), `tools/status.sh` (T4 — "Routing and evidence — a wrong answer
here is silent and confident"). `tools/dashboard/app.js` (T1) and `tests/run.sh` (T3) also
changed in this range but are below the T4 threshold this hook enforces and are reviewed only
incidentally, as context, below.

## What the change does

`coverage_anchor()` answers "what is the newest commit any gate has reviewed?" for `status.sh`'s
"UNROUTED WORK" section and the dashboard's coverage panel. It took the physically-LAST
`"type":"gate"` line in `ledger.jsonl` as the answer, trusting that ledger append-order tracks
commit recency. It does not: `ledger.sh add --commit <sha>` is a real, documented option letting
a gate be logged against a commit other than current HEAD (a retro/backfilled review), so a
gate line for an older commit can be appended after a real, later gate run already recorded a
newer one — displacing the true anchor and re-flagging already-reviewed work as unrouted.

Four rounds, driven by four real, independently-confirmed findings:

1. **Round 1** (`ced1d7b`): ranked ledger-named candidates by commit TIMESTAMP (`git log
   --format=%ct`) instead of file order.
2. **Round 3** (`ae38f38`): round 1/2's timestamp ranking was found forgeable — a committer date
   is self-reported and the same untrusted `ledger.sh add --commit <sha>` writer can set it to
   anything. Replaced with commit-graph ANCESTRY (`git merge-base --independent` — "which
   candidate is nobody's ancestor"), which cannot be forged without actually being a real
   descendant. A lexicographic-full-sha tie-break was added for the case ancestry can't order:
   two candidates on genuinely divergent history.
3. **Round 4** (`be4c6c6`): the tie-break itself was found forgeable — winning a greater-than
   string comparison against a known target is cheap (closer to a coin flip per attempt than a
   hash collision), and the same writer who can push one divergent commit can grind a handful of
   trivial variants of it first. Removed entirely: genuine ancestry ambiguity now returns NO
   anchor rather than guess.

## Trust boundary walk

**Untrusted input.** `_cov_sha`, one line per distinct `"commit"` value in `ledger.jsonl`,
written by whoever last ran `ledger.sh add --commit <sha>` — any contributor with commit access,
per this kit's stated threat model (`project/surfaces.conf`'s T4 row for this file).

**Option-injection into `git log` (round-1/2 finding, closed in round 3).** The intermediate
`git log -1 --format=%ct "${_cov_sha}^{commit}" --` form treated a ledger value shaped like
`--output=/some/path` as a `git log` OPTION, not a revision — reproduced directly outside the
suite: it really created the file `<path>^{commit}`. Closed by verifying FIRST with `git
rev-parse --verify -q "${_cov_sha}^{commit}"` (which restricts itself to a single revision
argument — confirmed by the same repro, it correctly rejected the identical value with exit 1
and created nothing) and using only the resolved, always-hex, never-`-`-leading FULL sha
(`tools/lib/coverage.sh:96-107`) for the `merge-base --independent` call that replaced `git log`.
Re-verified in round 4 against a sample of other option-shaped values (`--glob=`, `--branches=`,
`--sq`, `--parseopt`, bare `-`) — all rejected the same way.

**Pathname expansion of ledger data (found in round-2 G6, security-adjacent).** The candidate
loop's unquoted `for _cov_sha in $_cov_shas` needs word-splitting (a newline-delimited list) but
that also exposes it to glob expansion — a ledger value of literally `*` would otherwise iterate
this repo's real filenames instead of the literal string. Closed with `set -f` around the loop
(`tools/lib/coverage.sh:98,114`), restored before any `return` could skip it.

**Forgeable ranking signal — the actual subject of this whole fix (rounds 1/3/4).** Both
attempted signals (commit timestamp, then a lexicographic sha tie-break) were forgeable by the
same untrusted writer who can name a `--commit` at all, and both were closed by removing them
rather than patching around them further. The final design (`tools/lib/coverage.sh:120-133`)
uses ONLY commit-graph ancestry, which is derived from the immutable parent-hash chain, and
refuses to answer (no anchor) rather than invent a ranking for genuinely incomparable
candidates. Traced precisely in round 4: the `[ "$(... | grep -c .)" -eq 1 ] || return 0` guard
means no code path reaches the final `printf` for a divergent pair — confirmed, not assumed.

**Residual, accepted (not closed, not new).**
- An untrusted `ledger.sh add --commit <real-HEAD-sha> --outcome pass` — no forged git metadata
  needed at all — still achieves instant "clearance" of a real commit nobody actually reviewed.
  This is the ledger system's own pre-existing, documented trust baseline (a self-reported audit
  log), unchanged by this fix, which was never scoped to detect "the review didn't happen," only
  "which named commit is genuinely newest." Ancestry ranking correctly identifies that commit as
  newest — because it is.
- A shallow or grafted clone can make a commit look ancestor-free when a real ancestor exists
  past the fetch/graft boundary, misclassifying an old commit as "independent." Environment-
  dependent (matters only for a shallow-cloned coverage run), not exploitable purely from a
  ledger write, and the same class of limitation this file's own pre-existing comments already
  accept for "a squashed or rewritten history." Left for a follow-up, documented inline
  (`tools/lib/coverage.sh:63-67`).
- Removing the tie-break shifts the cheapest available attack from "forge a wrong-but-plausible
  anchor" to "suppress the anchor entirely" (log `--commit` for any real, genuinely-divergent
  existing commit — an old branch tip, an abandoned PR — no grinding required). This is not a
  forgery: it can never make the function assert a false anchor as true, only fail safe to "no
  anchor," which `status.sh`/the dashboard already handle honestly (count from full history, say
  so) — the exact trade-off this file's design explicitly favors over a confident wrong answer.

No privilege grew unremarked across the four rounds: each fix closed exactly the finding that
motivated it, verified by a regression test proven to fail pre-fix and pass post-fix, not just a
plausible-looking patch. `coverage_claimed_anchor()` (the sibling function serving a distinct,
already-correct purpose) was never touched.

## Findings

None outstanding. All findings from all four G7 rounds were closed within this same change (see
`ledger.jsonl`, `change:"coverage-anchor-retro-fix"`, gate `G7`, rounds 1/3/4 for the full
record) except the two residual items named above, both explicitly accepted design trade-offs,
not defects.

Full suite: `bash tests/run.sh` → `passed 689 · failed 0 · skipped 0`.

Fresh G7 round 4 (final, against this exact ancestry-plus-no-tie-break design): PASS. Fresh G4
(Ripple, round 1) and G6 (Peer, rounds 1-2) and G8 (Dogfood, rounds 1-2) also passed across the
change. `ledger.sh compliance --change coverage-anchor-retro-fix --tier T4` reports all
T4-mandated gates satisfied.

Logged: see `ledger.jsonl` entries for `change:"coverage-anchor-retro-fix"` — `G7` rounds 1
(fail), 2 (fail), 3 (fail), 4 (pass); `G6` rounds 1 (fail), 2 (pass); `G4` round 1 (pass); `G8`
rounds 1 (fail), 2 (pass); `G1`/`G5` self-run.
