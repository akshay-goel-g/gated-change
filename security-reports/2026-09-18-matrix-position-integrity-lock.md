# G7 · Threat review — `matrix-position-integrity-lock` (T4, hard gate, round 1)

**Reviewed:** the working-tree diff to `tools/lib/matrix.sh` (adding `_matrix_verify_lock`,
`_matrix_hash`, and the `--freeze` direct-execution mode) and the new `tools/lib/matrix.lock`
reference file, before either was committed. Landed as commit `31cfa50` (`git show --stat 31cfa50`
confirms `tools/lib/matrix.sh`, `tools/lib/matrix.lock`, `tests/run.sh`,
`specs/matrix-position-integrity-lock/requirements.md`, `ledger.jsonl` — the same file set
reviewed here, no drift). Same content-addressing paradox this repo's own precedent already
documents (`matrix-missing-router-warns-once`, `matrix-router-unreadable-fails-open` round 4): a
report cannot name the sha of a commit that includes itself, and the actual review happened
against the pre-commit diff. Logged as a `skipped` G7 push-mechanics exception in `ledger.jsonl`
(this file's existence is the paper trail; the ledger's own `pass` entry for G7, logged separately
against the `matrix-position-integrity-lock` change name, records the actual verdict).

**Files in scope and their tier** (`project/surfaces.conf`): `tools/lib/matrix.sh` — **T4** ("The
gate matrix reader — decides what is mandatory"). `tools/lib/matrix.lock` is new, not yet a named
row in `surfaces.conf`, but travels with `matrix.sh` and is in scope by the same reasoning.
`tests/run.sh` — T3, reviewed but not the focus (it exercises `matrix.sh`, doesn't decide anything
itself).

---

## What changed

`_matrix_load` gained a final check, `_matrix_verify_lock`, run after the existing shape/
vocabulary/per-tier-aggregate checks all pass: the parsed table's sha256 is compared against a
checked-in reference (`tools/lib/matrix.lock`). A new direct-execution mode,
`bash tools/lib/matrix.sh --freeze`, regenerates that reference — reachable only when the file is
executed directly (`[ "${BASH_SOURCE[0]:-$0}" = "$0" ]`), never when sourced, which is how every
real caller (`ledger.sh`, `reconcile.sh`, `dashboard.sh`, `lib/coverage.sh`) reaches it.

## Threat model walked

### 1 · Does the check actually catch the two demonstrated shapes? — closed, live

```
$ cp core/01-router.md /tmp/router.orig
$ sed -i 's/| \*\*G7 · Threat\*\* | Security engineer | 20 min | — | — | R⁴ | M | \*\*M (hard)\*\* |/| **G7 · Threat** | Security engineer | 20 min | — | **M (hard)** | R⁴ | M | — |/' core/01-router.md
$ bash -c '. tools/lib/matrix.sh; matrix_required T4'
matrix: .../core/01-router.md's table does not match its known-good reference ...
exit=2
$ cp /tmp/router.orig core/01-router.md
```

Cell swap (G7's T1/T4 cells traded, T4's own M-count unchanged) → refused. Repeated for the
simpler single-cell downgrade (G7's T4 cell `**M (hard)**` → `R`, no swap, column still has other
M's) → same refusal. Both restored, `git diff core/01-router.md` empty after each.

### 2 · Env-var bypass of the new check — found, fixed before send-off

First draft: `_MATRIX_SKIP_LOCK="${_MATRIX_SKIP_LOCK:-}"`, matching the pattern used for the
*public* overrides `MATRIX_ROUTER`/`MATRIX_LOCK`. But `_MATRIX_SKIP_LOCK` is internal-only (used
solely by `--freeze`'s own code path to parse the table without asking the not-yet-written
reference to already agree with it) — every sibling internal var (`_MATRIX_TABLE`,
`_MATRIX_LOAD_FAILED`) is a plain reset, never environment-sourced. As drafted, anyone able to set
an environment variable ahead of `ledger.sh`/`reconcile.sh`/`dashboard.sh` invocation — a CI
misconfiguration, a sourced profile script, a compromised wrapper — could silently disable the
entire lock check for that process, with no error, no log line, nothing. Fixed: plain
`_MATRIX_SKIP_LOCK=""`, no environment fallback; only `--freeze`'s own block sets it to `1`,
immediately before its own internal `_matrix_load` call. Re-verified: 35/35 matrix-prefixed tests
pass after the fix; sourcing the file with `_MATRIX_SKIP_LOCK=1` already set in the environment no
longer has any effect (confirmed by hand — the lock check still fires).

### 3 · Injection / format-string surface in the new read and write paths — reviewed, clean

The lock file is written with `printf '%s ... %s ... %s\n' "$_hash" "$MATRIX_ROUTER" "$0" >
"$MATRIX_LOCK"` — three `%s` placeholders, no interpolation into an `eval`, no shell metacharacter
expansion of file contents. It is read back with `awk '{print $1; exit}' "$MATRIX_LOCK"` — a plain
first-whitespace-field extraction, then a `[ "$_actual" != "$_expected" ]` string comparison. An
attacker-controlled `MATRIX_LOCK` (already an existing, pre-change attack surface via env override,
same as `MATRIX_ROUTER` always was) can only make the comparison fail or pass differently — it
cannot execute code through either the write or the read path.

### 4 · Hash algorithm trust — reviewed, standard assumption, not a new concern

sha256 collision/preimage resistance is the same trust level as any lockfile scheme (npm's
`package-lock.json` integrity hashes, pip's `--hash` requirement). Not a practical concern for
this threat model. Fallback chain (`sha256sum` → `shasum -a 256` → `openssl dgst -sha256`, no tool
found → refuse) reuses `tools/<removed-installer>`'s own `sha256_of()` pattern exactly — one portability
answer already trusted elsewhere in this codebase, not a new one introduced here.

### 5 · The explicitly out-of-scope case — documented, not a gap in this review

A single commit that edits `core/01-router.md` and `tools/lib/matrix.lock` together, with intent,
defeats this check entirely — the reference would simply agree with the tampered table. This is
named as a non-goal in `specs/matrix-position-integrity-lock/requirements.md`: closing it would
require something outside this file's reach (commit signing, a second reviewer's independent
`--freeze`, external CI attestation) — the same review-dependency every other file in this repo
already has for a coordinated malicious commit. Nothing here claims otherwise; the refusal
messages themselves say "if this change was deliberate and reviewed, regenerate the reference,"
naming the human step this cannot replace.

## Verdict

**PASS.** One real finding (§2), fixed and re-verified before this commit landed. No blocking
findings remain. §5 is a named, accepted non-goal, not an open gap.
