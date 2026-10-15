#!/usr/bin/env bash
#
# default-branch.sh — resolve the repository's ACTUAL default branch, computed
# rather than guessed.
#
# `tools/ledger.sh` refuses a `--change` name that is really a long-lived branch
# name (P1-5): a route record named for a permanent branch collects reconciles
# from many changes and correlates with none. That refusal used to be a
# hand-enumerated list only (`master main develop …`), which is both too narrow
# — a repo whose real trunk is `prod` or a team convention sailed through — and,
# if widened, starts refusing plausible real change names (`release`, `stable`).
# That was risk R-005. The fix: resolve the repo's real default branch from git
# and refuse THAT, keeping the hand-list only as the git-absent fallback.
#
# It lives here, sourced by BOTH `tools/ledger.sh` (the write side, which refuses
# the name) and `tools/dashboard.sh` (the read side, which bakes the resolved
# name into the model for `tools/dashboard/app.js`'s `changeIsBranchy()`, since a
# browser has no git). One copy, not two — the same reason `matrix.sh` and
# `coverage.sh` exist one level down: two readers of one fact is two chances to
# resolve it differently, and G4 Ripple / G5 Proof / G6 Peer all flagged the
# first version's duplicated copies.
#
# Sourced, not executed:
#   . "$(dirname "$0")/lib/default-branch.sh"
#
# No new dependency: `ledger.sh` already shells out to git at load and on every
# write (`detect_commit`), and `reconcile.sh` already makes this same
# `symbolic-ref` call for its BASE chain.

# The repo's default branch, or empty when git cannot answer.
#
#   1. `git symbolic-ref refs/remotes/origin/HEAD` — the repository's OWN answer,
#      set by `git clone` and by `git remote set-head origin -a`. Returned short
#      (`origin/main`); the `origin/` prefix is stripped to the bare branch name,
#      which is what the write side compares against `--change`. (reconcile.sh's
#      BASE chain makes the identical call but KEEPS the prefix — it wants a diff
#      ref, not a branch name.)
#   2. `git config init.defaultBranch` — the fallback for a repo with a remote
#      that has no origin/HEAD ref (`git remote add` without `set-head`, some CI
#      checkouts), or no remote at all.
#   3. empty — a bare local repo, detached with nothing configured, not a repo.
#      The caller then falls back to its hand-enumerated trunk-name list, i.e.
#      the behaviour before R-005. This residue is recorded in project/risks.md
#      (R-005, still `mitigate`): the fix NARROWS the gap, it does not close it.
#
# Resolved against the current directory (no `-C`), matching `detect_commit()`
# and the repo `reconcile.sh` derives its `--change` default from — those are the
# values that must agree for the refusal to match what actually gets written.
#
# NOTE: this runs a `git` subprocess. Callers resolve it ONCE (at load), not per
# call. Under heavy I/O contention a subprocess can fail transiently and this
# returns empty — the caller degrades to the hand-list (safe: a real trunk name
# is still caught; a wrongly-refused real change name would fail loudly). Same
# shape as every other git call in these tools; noted in R-005.
resolve_default_branch() {
  local ref
  ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  case "$ref" in
    origin/?*) printf '%s\n' "${ref#origin/}"; return 0;;
  esac
  git config --get init.defaultBranch 2>/dev/null || true
}
