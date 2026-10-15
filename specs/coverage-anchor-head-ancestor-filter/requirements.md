# coverage-anchor-head-ancestor-filter — Requirements

> Written at the Intent gate, before Build. Bug fix (correctness), not a feature —
> Prior art and Assets sections are marked N/A rather than deleted, so the template's
> shape stays legible.

## User

Anyone reading `tools/status.sh`'s "UNROUTED WORK" section or the dashboard's coverage panel
(`tools/dashboard.sh`, `COVERAGE_JSON`) to decide whether recent work still needs a gate run —
specifically on any project that rebases, squash-merges, or otherwise supersedes branch
commits after a gate has been logged against them (i.e. the mainline GitHub PR workflow).

## Problem

`coverage_anchor()` (`tools/lib/coverage.sh`) picks the newest gate-reviewed commit by
commit-graph ancestry: it resolves every `"type":"gate"` commit in the ledger, then runs
`git merge-base --independent` over the resolved set and takes the result **only when it is
exactly one commit** — otherwise it returns no anchor rather than guess between genuinely
divergent candidates (`tools/lib/coverage.sh:134-155`, and the fresh-G7 rationale in
`ledger.jsonl` change `coverage-anchor-retro-fix`, rounds 3-4).

The resolve step (`tools/lib/coverage.sh:127`) checks `git rev-parse --verify -q
"<sha>^{commit}"` — **"does this object exist"**. It does **not** check that the commit is
reachable from `HEAD`, or on `HEAD`'s line of history at all.

An append-only ledger cannot rewrite a gate entry when its commit is later rebased away or
squashed on merge (this is correct — `04-ledger.md`'s "never backfill" rule). So the orphaned
commit's entry stays. As long as that object survives (git's gc grace window — default two
weeks, and indefinitely while any worktree reflog references it), `rev-parse --verify`
resolves it, and it enters `merge-base --independent` as a **legitimate independent tip**:
nothing descends from it, because it was never merged.

Result: `merge-base --independent` returns two or more commits, the `-eq 1` guard fails, and
`coverage_anchor()` returns **no anchor**. `status.sh` and the dashboard then fall back to
scanning the **entire repository history** as "unrouted" — every commit ever made, tiered and
listed, with the real "since the last gate" signal completely lost.

**Reproduced** in this very repo (2026-09-08). 68 distinct gated commits in `ledger.jsonl`;
67 resolve. One of them, `6fc2570` (`coverage-anchor-retro-fix` G5 round 1,
`ledger.jsonl:249`), is an early commit of that branch, superseded when the branch was
recreated — `refs=[]`, not an ancestor of `HEAD`, kept alive only by one worktree reflog
entry. `git merge-base --independent` over the 67 returns `{6fc2570, 74091df}`.
`coverage_anchor()` returns `""`. `status.sh` reports "209 commit(s) history" and dumps 56
T4 + 24 T3 commits — none of it real drift. Filtering the 67 candidates to
`git merge-base --is-ancestor <sha> HEAD` first yields exactly `{74091df}`, the correct
anchor (the newest reviewed commit on this branch's actual history).

**Why the existing rationale does not cover this.** `coverage.sh`'s header treats divergence
as (a) an *attacker* logging `--commit` for a divergent commit to *suppress* the anchor
(accepted as fail-safe — `ledger.jsonl` `coverage-anchor-retro-fix` r4 finding), and (b)
shallow/grafted clones (named, deferred). Neither names the ordinary case: **a normal
merge/rebase workflow orphans pre-merge commits, and their ledger entries legitimately
remain.** Every adopting project hits this the first time a gated branch commit is superseded,
for the duration of the gc window. It self-heals by luck once `git gc` prunes the object, so
it presents as intermittent and version/timing-dependent — which is why it was not caught.

## Acceptance criteria

- [ ] `coverage_anchor()` filters its resolved candidate set to commits that are **ancestors
      of `HEAD`** (`git merge-base --is-ancestor`, or the one-shot `git rev-list --no-walk
      <candidates> --not HEAD` complement) *before* `git merge-base --independent`. A gated
      commit not reachable from `HEAD` is on a different line of history and cannot bound
      "work landed on this line since the last gate", so it is excluded from anchor
      selection entirely.
- [ ] With the orphan filtered out, the common linear case resolves: a ledger naming the
      real HEAD-side reviewed commit plus one or more superseded/unmerged commits anchors to
      the newest HEAD-ancestor among them, **not** to `""`.
- [ ] When `HEAD` itself is the newest gated commit (nothing landed since), the anchor
      resolves to `HEAD` and the range `HEAD..HEAD` is empty — coverage reads "0 since / all
      routed", not a whole-history scan.
- [ ] The genuine-divergence refusal is **narrowed, not removed**: if after HEAD-ancestor
      filtering `merge-base --independent` still returns more than one commit (two commits
      both ancestors of `HEAD`, neither descending from the other — only reachable when
      `HEAD`'s own history contains merge commits), `coverage_anchor()` still returns no
      anchor rather than guess. This residual is documented in the header comment.
- [ ] Forgery posture is preserved or improved: a forged/retro `--commit` naming a commit
      that is **not** an ancestor of `HEAD` can no longer influence anchor selection at all
      (previously it could suppress the anchor). A `--commit` naming a real HEAD-ancestor is
      reviewed history, not a forgery, and is exactly what the function is meant to find.
- [ ] Existing behavior preserved:
  - A ledger line naming a commit unresolvable in this repo is still skipped
    (`rev-parse --verify` guard, `tools/lib/coverage.sh:127`, unchanged).
  - An empty/missing ledger, or one with no `"type":"gate"` line, still returns empty.
  - `coverage_anchor()` still **exits 0** in every no-anchor path (the explicit-`if`/`fi`
    exit-status contract from `coverage-anchor-retro-fix` r1 G6 — must not regress).
  - `coverage_claimed_anchor()` is untouched.
  - Cost stays bounded by the number of *distinct* gated commits, not gate lines — the
    HEAD-ancestor check is one `git` invocation total (`rev-list --no-walk ... --not HEAD`)
    or one per distinct commit (`--is-ancestor`), never per gate line. `coverage_scan()`'s
    neighboring 61s-for-63-commits measurement is the cost class this must not reintroduce.
- [ ] `tests/run.sh:test_coverage_anchor_returns_no_anchor_for_divergent_branches_rather_than_guess`
      (`tests/run.sh:3683`) is **rewritten**. Its current scenario — `branch-one` never
      merged, `HEAD` on `branch-two`, assert `"anchor":""` — encodes the pre-fix decision
      that an unmerged gated commit is a rival for "newest ancestor". Under this fix
      `branch-one`'s commit is filtered out and the anchor correctly resolves to
      `branch-two`'s tip. The rewritten test asserts that. A *new* test covers the residual
      genuine-divergence case (two commits both ancestors of a merge `HEAD`) still returning
      `""`.
- [ ] A new regression test reproduces the orphan case directly: gate logged on commit X,
      X superseded by a rebase so it is no longer an ancestor of `HEAD`, a later real gate
      logged on a `HEAD`-ancestor commit Y — anchor must be Y. It fails against the pre-fix
      `coverage_anchor()` (returns `""`) and passes after.

## Out of scope

- Surfacing *why* an anchor could not resolve, or flagging stale/orphaned ledger entries
  (a gate entry whose commit is on no branch) in `status.sh` or the dashboard. Real, and
  arguably the next step, but a separate change — this one only makes `coverage_anchor()`
  compute the right answer.
- The separate `LAST_GATE_LINE` / `LAST_COMMIT` inline `grep ... | tail -1` in
  `tools/status.sh` (~lines 100-111). Different question ("what does the ledger tail
  literally say for the LAST GATE display line"), already out of scope in
  `coverage-anchor-retro-fix`, still out of scope here.
- The merge-commit residual (two HEAD-ancestor commits, neither descending from the other)
  is *documented and left returning no anchor*, not solved. Picking one would need a
  rankable signal, which is the door `coverage-anchor-retro-fix` rounds 3-4 deliberately
  closed.
- `git gc` / prune configuration, or any attempt to make the ledger self-clean orphaned
  entries. The capability that creates them (`ledger.sh add --commit`, and rebasing) is
  legitimate; this fix only makes `coverage_anchor()` correct in their presence.
- Shallow/grafted-clone detection — still named-and-deferred, unchanged by this.

## Assets required

N/A — no non-code deliverables.

## Prior art

N/A — Scout (G2) fires only for net-new user-facing capability (`cards/G2-scout.md`); this is
a correctness fix in an internal library function.

## Acceptance (G1b — after Build)

| Criterion | Evidence |
|---|---|
| Candidates filtered to HEAD-ancestors before `merge-base --independent` | `tools/lib/coverage.sh` diff — new block after `_cov_fulls=` (line ~158): `git rev-parse --verify -q HEAD` guard → `git rev-list --no-walk $_cov_fulls --not HEAD` → `grep -vxF` subtraction → `[ -n "$_cov_fulls" ] || return 0`, before the unchanged `git merge-base --independent` line |
| Orphan + real-anchor ledger resolves to the real anchor, not `""` | `tests/run.sh:test_coverage_anchor_ignores_an_orphaned_gated_commit_from_a_deleted_branch` — gate on A, gate on B (branch deleted, object survives), gate on C (trunk); asserts `"anchor":"<C>"`. Discrimination proof run manually this session: `git show HEAD:tools/lib/coverage.sh` (pre-fix) → this scenario returns `""` (exit 0); fix restored → returns `bb27a3f` (= C). Also proven live on this repo's own `ledger.jsonl`: pre-fix `coverage_anchor` → `""`, post-fix → `74091df` |
| `HEAD`-is-newest-gate resolves to `HEAD`, empty range | `test_coverage_anchor_ignores_an_unmerged_gated_commit_and_anchors_to_head_side` asserts `"anchor":"<branch-two tip>"` where that tip is HEAD; manual: scratch repo with a single gate on `HEAD` → `coverage_anchor` returns HEAD's short sha, `status.sh` → "0 since" path |
| Genuine divergence (merge `HEAD`) still returns `""` | `test_coverage_anchor_still_refuses_genuine_head_side_divergence` — real octopus merge of two lines, gate on a commit on each; both ancestors of HEAD, neither descends; asserts `"anchor":""`, run twice for determinism. Manual repro confirmed `anchor=[] exit=0` |
| Non-HEAD-ancestor `--commit` cannot influence the anchor | Same orphan regression test — B is exactly a `--commit`-shaped ledger entry naming a commit not on HEAD's line; it is filtered, cannot become or suppress the anchor |
| Unresolvable commit still skipped; empty ledger still empty; still exits 0 | `bash tests/run.sh coverage_anchor` → **31 passed / 0 failed / 0 skipped** (includes `test_coverage_anchor_exits_zero_even_when_every_candidate_is_unresolvable`, the glob-value test, the retro-log-ordering test, the ancestry-not-date test — all still green); manual: empty / no-gate / missing / all-unresolvable ledgers each → `anchor=[] exit=0` |
| `coverage_claimed_anchor()` untouched | `git diff tools/lib/coverage.sh` touches only the header comment and the body of `coverage_anchor()` — `coverage_claimed_anchor()` (lines ~190-197) not in the diff |
| Cost bounded by distinct commits | The filter is **one** `git rev-list` invocation total (plus one `git rev-parse --verify HEAD` guard), not one per gate line and not one per commit — `$_cov_fulls` is already `sort -u`'d distinct commits |
| Old divergence test rewritten; full suite green | `test_coverage_anchor_returns_no_anchor_for_divergent_branches_rather_than_guess` renamed to `...ignores_an_unmerged_gated_commit_and_anchors_to_head_side`, assertion flipped from `"anchor":""` to `"anchor":"<head-side>"`; full `bash tests/run.sh` — 759 passed / 0 failed / 0 skipped, rebased onto origin/master |

**Target coverage** (reconcile.sh's T3/T4 checklist for this diff):
- Git Bash on Windows — run in this session (repro + discrimination proof + full suite).
- Linux/macOS bash — `.github/workflows/tests.yml` ubuntu/macos legs run `tests/run.sh`
  unmodified. **Note: GitHub Actions is disabled on this repo for non-payment since
  2026-09-08** (pushes fail all legs in ~8s — not a code signal), so the Linux/macOS leg
  cannot be confirmed via CI this session; `git merge-base --is-ancestor` and
  `git rev-list --no-walk --not` are portable git (≥1.8.0, 2012) with no platform branch.
- Installed at `.pipeline/` — `tests/run.sh`'s `newrepo` fixture, the same one the new
  tests use.
- Kit as its own repo (`INCLUDE_KIT=1`) — N/A for this function: `coverage.sh` never reads
  `INCLUDE_KIT` (grep, zero hits); that flag only affects `reconcile.sh` path exclusion.

## Restatement

`coverage_anchor()` should only consider gated commits that are actually on `HEAD`'s history
when choosing the "newest reviewed commit" — a commit that was rebased or squashed away is
not a rival for that title, it is noise, and treating it as a legitimate divergent tip throws
away the entire coverage signal for weeks after every superseded branch.
