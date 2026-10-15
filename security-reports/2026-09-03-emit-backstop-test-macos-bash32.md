# Security review — emit() backstop test: stage functions in a real file instead of `. <(sed …)`

Reviewed commit: `507071b` — G7 · Threat, fresh context, single commit
(`git diff 966e46d..507071b`), against the files as they exist at that sha.

Files in scope, and why:

- **`tests/run.sh`** — T3 by `project/surfaces.conf:49` ("The suite — if it stops asserting,
  nothing else here is trustworthy"). One test body changed:
  `test_emit_refuses_a_line_that_is_not_a_json_object` (`tests/run.sh:1373-1381`).

Highest tier in the change: **T3**, so G7 runs as a hard gate. No T4 row is touched — confirmed
below.

## What the diff does (derived from the diff, not the narrative)

The test loads `ledger.sh`'s function definitions *without* its bottom `case "${1:-}"` dispatch
block, then calls `emit 'not json at all'` in a child shell and asserts it exits 3 and writes
nothing. Previously the stripped source was fed via process substitution:
`. <(sed '/^case "${1:-}"/,$d' "$REPO/.pipeline/tools/ledger.sh")`. The change instead:

1. `fns="$(mktemp "$TMPROOT/ledger-fns.XXXXXX")"` — creates a temp file,
2. `sed '…' "$REPO/.pipeline/tools/ledger.sh" > "$fns"` — writes the stripped source into it,
3. `run bash -c "LEDGER='…'; . '$fns'; emit 'not json at all'"` — sources the file and calls `emit`,
4. `rm -f "$fns"` — deletes it.

The added comment attributes this to bash 3.2 (macOS) unreliably sourcing process substitutions.
Nothing else changes: same `sed` program, same `emit` call, same assertions.

## Threat model — who is the untrusted party?

**There is no meaningful untrusted party for this change.** `tests/run.sh` is the kit's own test
suite, run by a developer on their own machine or in CI. Tracing every value the new lines
consume:

- **`$REPO/.pipeline/tools/ledger.sh`** — the file `sed` reads. Populated by
  `newrepo()` via `cp -r "$KIT/tools" … "$REPO/.pipeline/"` (`tests/run.sh:224`). It is a copy
  of the repository's own tool — i.e. the code under test. Whoever controls its contents already
  controls the checkout and the suite itself; not a trust boundary.
- **`$TMPROOT`** — `mktemp -d` output (`tests/run.sh:31`). `mktemp -d` creates the directory
  mode **0700** on GNU, BSD and macOS. No other local UID can traverse into it or create entries
  inside it.
- **`$fns`** — `mktemp "$TMPROOT/ledger-fns.XXXXXX"` output: a regular file created atomically
  (`O_EXCL`) mode **0600**, with a random suffix, inside the 0700 directory. The path is not
  predictable and the name is chosen by `mktemp`, not by the test.
- **`'not json at all'`** — a string literal in the test source.

`emit` writes only to `$LEDGER` = `$REPO/.pipeline/ledger.jsonl`, a path under the same
per-run `mktemp -d` tree. No network, no external input, no persisted state outside `$TMPROOT`,
no credential or permission surface.

## Adversarial reachability of the new mechanism

**Does a real on-disk file + `. '$fns'` expose anything `. <(…)` did not?**

Marginally, and not meaningfully. Process substitution on bash is normally an anonymous pipe
(`/dev/fd/N`) with no filesystem name at all; on platforms lacking `/dev/fd` it falls back to a
mode-0600 named FIFO in `$TMPDIR`. The new code replaces that with a named, mode-0600 **regular
file** that persists on disk for the duration of the `sed` write, the `bash -c` source, and
until `rm -f`. That is a slightly longer-lived, named artifact — but:

- **Predictability:** the name is `mktemp`'s `XXXXXX` random suffix, not derivable.
- **Symlink / TOCTOU on the write (`sed > "$fns"`) or the source (`. '$fns'`):** replacing
  `$fns` with a symlink between `mktemp` and either use requires a process able to create
  entries in `$TMPROOT`. `$TMPROOT` is mode 0700, so that process must run as the **same UID**
  running the suite — a party that can already edit `run.sh` and `ledger.sh` directly and
  needs no race. Not a privilege boundary.
- **`rm -f "$fns"` with an attacker-controlled `$fns`:** `$fns` is `mktemp` output, always
  quoted, always a path directly inside the 0700 dir. It is never influenced by any value from
  outside the test. No path-traversal or glob content reaches `rm`.
- **Swapping the file's *content* between write and source:** same-UID-only, same as above.

The classic `/tmp` symlink/TOCTOU attack needs a world- or group-writable temp directory or a
predictable filename in a shared directory. Neither condition holds here: 0700 parent,
unpredictable name, single-UID reach.

**In the test's own threat model** (a developer or CI runner executing the suite as itself),
the race is not real — the only actor who can win it is the actor who owns the process.

## T4 boundary check

The change edits `tests/run.sh` only. `project/surfaces.conf` matches that path at **line 49**,
`T3::(^|/)tests/run\.sh$`. No T4 row is matched:
`tools/(reconcile|ledger|install-hook|install-claude-hook|status)\.sh$` (line 27) is not touched
— `ledger.sh` is only *read by* `sed` as test input, not modified. No routing file, matrix,
hook, pre-push, install, <removed-packer> or update-kit path is in the diff. **Confirmed T3, no
trust boundary crossed, no privilege grown.**

`surfaces.conf` here is this repo's own answers (`SELF: gated-change`), so these are the correct
boundaries to review against.

## Verdict

**PASS.** No unresolved finding above low. The change is a portability fix for the test harness
with no attacker-reachable surface: every value it consumes is either a test literal, a copy of
the code under test, or `mktemp` output inside a mode-0700 directory. It does not expand the
attack surface relative to the `. <(…)` form it replaces.

## Findings

| Severity | Location | Claim |
|---|---|---|
| info | `tests/run.sh:1375` | Temp-file-and-source replaces process substitution. New named on-disk artifact, but created by `mktemp` inside a mode-0700 `mktemp -d` directory with an unpredictable name — the write/source window is reachable only by the same UID running the suite, which already has full control of `run.sh` and `ledger.sh`. No TOCTOU/symlink exposure beyond what a same-user actor trivially has anyway. |
| info | `tests/run.sh:1378` | `rm -f "$fns"` is untrapped and runs only on the happy path; on an abort between `mktemp` and `rm` the file leaks — but `$fns` is `mktemp` output under `$TMPROOT`, which `trap cleanup EXIT` (`tests/run.sh:32-39`) removes with `rm -rf`. No leak past the suite run; no attacker-controlled path reaches `rm`. |
| info | `project/surfaces.conf:49` | Change touches only `tests/run.sh` (T3). No T4 trust boundary is crossed; `ledger.sh` (T4) is read as `sed` input, not modified. G7 still runs as a T3+ hard gate. |

Full suite not re-run as part of this review (blind, diff-only). The change is inert with
respect to production tool behavior.
