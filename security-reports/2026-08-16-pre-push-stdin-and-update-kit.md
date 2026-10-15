# G7 Threat — pre-push stdin protocol, ledger tier validation, update-kit.sh

**Commit reviewed:** `da9d27d4a8a01f7b60a5e1fb3cfd007d93e8c65a`
**Diff scope:** `git diff 47544be8b7fea58f2d6a7eef2d2b8ec0881d996f..da9d27d4a8a01f7b60a5e1fb3cfd007d93e8c65a`
**Gate:** G7 Threat · Tier T4 · Round 1 · fresh context (subagent, no author explanation received)

Files in scope: `templates/pre-push`, `tools/status.sh`, `tools/ledger.sh`, `tools/update-kit.sh` (new),
`tests/run.sh`, `project/map.md`, `project/surfaces.conf`, `README.md`, `SESSION-HANDOFF.md`, `ledger.jsonl`.

## Method

Traced every value that originates outside the local reviewer's control to where it is used in a
shell command: the four stdin fields git feeds a pre-push hook (`local_ref local_sha remote_ref
remote_sha`), and the CLI arguments `tools/update-kit.sh` and `tools/ledger.sh` accept.

## `templates/pre-push` — stdin protocol parsing (lines 95–123)

- `local_sha` and `remote_sha` are read from stdin and used in `git merge-base "$ORIGIN_BASE"
  "$local_sha"` (line 110) and `git diff --name-only "$range_base" "$local_sha"` (line 118). Both
  uses are double-quoted, so no word-splitting/globbing injection. `local_ref` / `remote_ref` are
  read but never used in any command — confirmed by reading the full file end to end.
- Reachability of a hostile value in `remote_sha`: git's wire protocol advertises refs as
  `<40/64-hex-sha> <ref-name>`, parsed and validated by the local git client before this hook is
  ever invoked. A remote cannot smuggle a non-hex string (e.g. `-rf` or `--upload-pack=...`)
  through that layer — a malformed advertisement is rejected at the protocol level, not by this
  script. Neither `git merge-base` nor `git diff --name-only` here uses `--` before the revision
  arguments, but given the above I could not construct a realistic path to flag injection or
  argument-position abuse. Noted as defense-in-depth only, not filed as a finding (no evidence of
  actual reachability).
- The logic itself fixes a previously-logged blocking finding
  (`ledger.jsonl`: `status-coverage-command-r2-G8-2`, "the very first push of a repo bypasses the
  trust-boundary guard entirely ... STILL OPEN"): the old code fell back to a local `main`/`master`
  which, on a repo's first push, resolves to the exact branch being pushed, making `BASE...HEAD`
  compare a branch to itself (always empty). The new code diffs per-ref against the real
  `remote_sha` (or a merge-base with `ORIGIN_BASE`, or the empty-tree constant when neither
  resolves), which closes that bypass. `tests/run.sh` (`test_hook_catches_a_trust_boundary_on_a_repos_first_push`,
  `test_hook_stdin_is_a_noop_on_a_branch_deletion`, `test_hook_stdin_normal_push_diffs_from_the_remote_sha`,
  `test_hook_new_branch_diffs_from_merge_base_with_origin_not_empty_tree`,
  `test_hook_new_branch_still_catches_a_trust_boundary_added_on_the_branch`) exercise the real stdin
  path (not just the `BASE=` override), including the case that was previously bypassed. Verdict:
  fix confirmed, no new injection surface found.

## `tools/ledger.sh` — tier validation and awk unescaping

- `looks_like_tier` (line 187) narrows from a loose shape check (`T` + digits) to a closed enum
  (`T0|T1|T2|T3|T4`), matching what `cmd_compliance` already enforced. This closes a real gap: `add
  --tier T44` used to write a record `compliance --tier T44` would then silently refuse to
  evaluate, which reads as coverage while being none — but this is a correctness/consistency fix,
  not a new trust boundary. Tightens rather than expands the input surface.
- The `junesc` awk function's `\n` handling changed from unescaping to a real newline to keeping
  the literal two-character `\n` (line ~750). This is a display-formatting fix (prevents a single
  multi-line `--assume` record from being double-counted/double-bulleted); it does not touch how
  the field reaches the shell, and I found no new injection surface in the awk embedding — the
  single-quote-avoidance comment added around it documents an existing constraint, not a new one.

## `tools/update-kit.sh` — new file, T4-classified (`project/surfaces.conf:41`)

- Correctly scoped: only `core/ tools/ templates/` and `README.md CHANGELOG.md VERSION`
  (`PORTABLE_DIRS`/`PORTABLE_FILES`, lines 98-99) are ever deleted or replaced. `project/`,
  `ledger.jsonl`, `security-reports/`, `dashboard.html`, `specs/`, `.git` are never referenced by
  any delete/write path in the script — confirmed by reading the full 140-line file. Verified live
  by `tests/run.sh:test_update_kit_never_touches_the_projects_own_records`.
- Refuses a source that doesn't structurally look like a kit (`core`, `tools`, `templates` dirs +
  `core/01-router.md`, lines 77-81), refuses updating a kit from itself (line 83-86, resolved via
  `cd ... && pwd` so relative-path tricks and trailing-slash variants normalize to the same
  canonical path before the comparison). Both are exercised by tests
  (`test_update_kit_refuses_a_source_that_is_not_a_kit`, `test_update_kit_refuses_to_update_itself`).
- **Finding (minor):** the replace loop (`tools/update-kit.sh:113-120`) does
  `rm -rf "$KIT/$d"` immediately followed by `cp -r "$SRC/$d" "$KIT/$d"` for each of
  `core tools templates`, with no check on either command's exit status. The script only sets
  `set -uo pipefail` (line 36) — no `set -e`, and no `||` / exit-code check around either
  operation. If `cp -r` fails partway (disk full, permission error, or the source becoming
  unavailable mid-run — a real possibility since `SRC` can be a path on removable/network media,
  nothing pins it), the loop continues to the next directory and the script still prints the
  unconditional success banner ("Updated $OLD → $(_fingerprint "$KIT")", line 128) even though
  `core/`, `tools/`, or `templates/` may now be empty or partially populated. This is exactly the
  "reports success by saying nothing" failure class `templates/pre-push`'s own header calls out by
  name for a different mechanism (line 18-19) — here it is self-inflicted by the update tool
  itself. No test in this diff exercises a failing `cp`/`rm` mid-loop; every `test_update_kit_*`
  case exercises only the all-succeed path. Impact is bounded — `project/`, `ledger.jsonl`, and
  `security-reports/` are architecturally unreachable from this loop regardless of failure, so the
  "records" the tool's own header calls unrecoverable stay safe — but a broken `tools/` (e.g. a
  half-copied `ledger.sh`) can silently disable parts of the enforcement pipeline (gates,
  `compliance`, the pre-push hook's own dashboard regeneration step) while the operator is told
  the update succeeded.
- Argument handling: unknown flags (`-*`) are refused (line 44); the single positional `SRC`
  argument is canonicalized via `cd "$SRC" && pwd` (line 50) after an explicit `[ -d "$SRC" ]`
  check, so a non-existent or non-directory path is refused before use. A `SRC` value of exactly
  `-` would be interpreted by `cd` as "previous directory" rather than a literal path named `-`,
  but this needs a user to literally type `-` as their kit path — filed as a non-issue (confused-user
  edge case with no realistic trigger, not a hostile-input path).
- Symlinks: `rm -rf "$KIT/$d"` where `$KIT/$d` is itself a symlink to a directory removes only the
  symlink (POSIX/GNU `rm` does not recurse into a symlink target passed without a trailing slash),
  so this does not turn into an unbounded delete of whatever the symlink points at. Not a finding.

## Verdict

**PASS.** No trust boundary is crossed without a check, and no privilege grows unremarked. The
one finding (`tools/update-kit.sh:113-120`, minor) is a robustness/error-handling gap — a
partially-failed self-update can silently misreport success — not an attacker-reachable
injection or a bypass of the boundaries `project/surfaces.conf` defines. It does not block: no
unresolved finding above minor.

## Findings

| ID | Severity | Location | Claim |
|---|---|---|---|
| 1 | minor | `tools/update-kit.sh:113-120` | `rm -rf` then `cp -r` in the portable-dirs replace loop has no exit-status check and no `set -e`; a failed `cp` (disk full, permission, vanished source) leaves `core/`/`tools/`/`templates/` partially replaced while the script still prints the unconditional "Updated" success banner (line 128). No test exercises the failure path. `project/`, `ledger.jsonl`, `security-reports/` remain unreachable from this loop regardless, so the tool's own core promise (never destroy project records) still holds. |
