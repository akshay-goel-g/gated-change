# G7 · Threat review — `matrix-missing-router-warns-once` (T4, hard gate, round 1, 7c depth)

**Reviewed:** the **uncommitted working-tree diff on top of `f11cdb0`** ("handoff: rewrite for
reconcile-cost-test-delta, queue the next two chips"). No commit exists for this change at
review time; the subject is `git diff -- tools/lib/matrix.sh tests/run.sh`, plus the files as
they sit on disk right now (`git rev-parse HEAD` → `f11cdb0b51a8aae5d3d1535c1fc222839f0f8010`).

**Files in scope and their tier** (`project/surfaces.conf`, which declares `SELF: gated-change`
at line 3 — these are **this repository's own** trust boundaries):

| File | Tier | surfaces.conf rule |
|---|:--:|---|
| `tools/lib/matrix.sh` | **T4** | `:28` — "The gate matrix reader — decides what is mandatory" |
| `tests/run.sh` | T3 | `:50` — "The suite — if it stops asserting, nothing else here is trustworthy" |

Change tier = **T4** (the max), which is what makes this a hard gate.

Untracked `specs/matrix-missing-router-warns-once/` sits in the working tree but is not part of
the reviewed diff (`git diff -- tools/lib/matrix.sh tests/run.sh` does not touch it) and was not
opened, per the withhold rule on the author's stated purpose.

---

## Threat model — who is untrusted here

`tools/lib/matrix.sh` is the **sole reader** of `core/01-router.md`, the one place the gate
matrix is written down. `ledger.sh` asks it what a tier mandates before deciding compliance;
`reconcile.sh` asks it what to print as required before a change ships; `dashboard.sh` and
`tools/lib/coverage.sh` ask it too. `surfaces.conf:24-25` states this file's whole reason for
existing: the kit's defect history is tools "returning a confident wrong answer rather than an
error." A cache that answers wrong here is exactly that failure mode.

The untrusted/relevant parties:

1. **A process's own later calls to itself.** Not a hostile actor — the threat is a stale
   in-memory answer outliving the on-disk fact that produced it, inside one script's run.
2. **A confused user or CI environment** whose `MATRIX_ROUTER` override, or filesystem state
   (router deleted, restored, edited mid-run by another process), changes between two questions
   asked of the matrix in the same invocation.
3. **A reader of `ledger.sh gates` / `reconcile.sh` output**, who is harmed if a mandatory-gate
   answer is silently wrong rather than loudly absent.

**The new surface:** `_MATRIX_LOAD_FAILED`, a sentinel that once set makes `_matrix_load()`
return `2` immediately on every later call **without** re-checking `[ -f "$MATRIX_ROUTER" ]` or
re-parsing. The assigned question: can this let a stale "missing" answer be trusted over a fresh
"found" one, and is that new or an existing accepted pattern (the pre-existing `_MATRIX_TABLE`
success-cache already returns fast without re-reading)?

---

## The walk — real commands, real output

All commands below ran against throwaway `mktemp -d` repos with `MATRIX_ROUTER`/`LEDGER`
exported to scratch paths — never against this repo's own `core/01-router.md` or `ledger.jsonl`.
Bash on Git-Bash/Windows, matching this repo's primary `tests/run.sh` target.

### 1 · Within one un-forked shell: does the negative cache suppress recovery of a router created mid-process? — **Yes.**

```
--- call 1 (router missing) ---
matrix: no router at /tmp/tmp.OZE.../core/01-router.md
  The gate matrix lives there and nowhere else. Without it there is no
  way to know which gates a tier mandates, and guessing is not one.
rc=2
--- now creating the router file ---
--- call 2 (router now exists, same process) ---
rc=2          <- silently wrong: the router is now real and valid, matrix_gates still fails
```

Confirmed live, direct (non-substituted) calls in one shell. Once `_MATRIX_LOAD_FAILED=1` is
set, `_matrix_load` never looks at the filesystem again for the rest of that shell's life —
matching the header comment's own framing ("parsed once per process and cached") taken
literally.

### 2 · Is this new, or does the pre-existing success-side cache already behave identically? — **Identical, pre-existing pattern.**

Same experiment, mirrored: load succeeds and caches, then the router is mutated (truncated) in
place, then asked again in the same un-forked shell:

```
--- call 1 (router present, loads+caches) ---
G1 G2 G3 G4 G5 G6 G7 G8  rc=0
--- now truncating the router file to simulate a mid-process change ---
--- call 2 (router now empty, same process, success-side cache) ---
G1 G2 G3 G4 G5 G6 G7 G8  rc=0    <- stale: reports the OLD table, ignores the truncation
```

`_MATRIX_TABLE` was already returning a stale answer under an in-place router edit before this
diff — that is the entire point of `[ -n "$_MATRIX_TABLE" ] && return 0`, documented at
`tools/lib/matrix.sh:19` ("The table is parsed once per process and cached") since before this
change. `_MATRIX_LOAD_FAILED` is the same design applied to the other branch of the same `if`.
**Not a new risk class** — it is the pre-existing, accepted, already-documented caching contract
extended symmetrically to the failure path. A reviewer who would file this against the diff
would have to file it against code that already shipped.

### 3 · Is the theoretical staleness from §1 actually reachable through any real caller? — **No — traced through every consumer.**

`grep -n 'matrix_' tools/ledger.sh tools/reconcile.sh tools/dashboard.sh tools/lib/coverage.sh`
shows every real call site reaches `_matrix_load` (directly or via `matrix_gates`/`matrix_cell`/
`matrix_name`/`matrix_required`) through a **command substitution or a pipe**:
`tools/ledger.sh:1518` (`"$(matrix_gates | tr ...)"`), `:1519` (`"$(matrix_gates)"` again),
`:1551` (`"$(gate_name "$g")"` per row), `:1077` (`matrix_required "$1" | tr ...`);
`tools/reconcile.sh:581` (`$(matrix_required "$ACTUAL")`), `:582` (`$(matrix_cell ...)`), `:592`
(`$(matrix_conditional ...)`); `tools/dashboard.sh:316` (`MATRIX=$(parse_matrix)`, itself looping
over further `$(matrix_gates)`/`$(matrix_cell ...)`). A pipe's left side and a `$( )` both fork a
subshell in bash; a subshell's mutations to `_MATRIX_LOAD_FAILED`/`_MATRIX_TABLE` die with it and
never reach the parent shell that makes the *next* top-level call. So in every real consumer,
each top-level `matrix_*` call starts from the parent's still-empty cache variables and freshly
re-checks the filesystem — which means §1's theoretical staleness **cannot manifest** through any
call path this codebase actually exercises today. Confirmed by grep with no counterexample: no
consumer calls a `matrix_*` function bare, twice, in one un-forked shell, the way the new test
does.

**This cuts the other way too, and is worth stating plainly: verified live against the actual
motivating case.** The diff's own comment says `ledger.sh gates` "calls matrix_gates() twice and
matrix_name() once per gate row" and that this used to scroll the warning "4+ times." Run for
real, against this diff, with a missing router and two logged gates:

```
$ LEDGER=<scratch> MATRIX_ROUTER=<missing> bash tools/ledger.sh gates
...
matrix: no router at .../no-such-router.md      [x4, interleaved with the gate rows]
  The gate matrix lives there and nowhere else. ...
$ | grep -c "no router at"
4
```

Same count the diff's own comment describes as the pre-fix bug. `tools/reconcile.sh`, run
against a real uncommitted diff and a missing router, prints it **twice**
(`matrix_required` + `matrix_conditional`, each its own `$( )`). The new test
(`tests/run.sh:1062`, `test_matrix_missing_router_warns_once_per_process`) passes — 10/10 under
`bash tests/run.sh matrix_` — but only because it calls `matrix_gates`/`matrix_name`/
`matrix_required` as **bare statements inside one already-open subshell**
(`( MATRIX_ROUTER=...; . matrix.sh; matrix_gates; matrix_gates; matrix_name G1; ... )`), a
calling convention no real consumer uses. The fix is real for that synthetic harness and does not
reach the case it was written to fix.

This is a correctness/fitness-for-purpose gap (does the fix do what it says), which is G6's
territory, not a trust-boundary crossing — no wrong answer is produced or trusted; the warning
just still repeats. Recorded here as `info` because it is the direct, verified answer to the
assigned walk, not because G7 is rating the fix's effectiveness.

### 4 · Does the warning message's content change behavior anywhere? — **No, checked.**

`grep -n '\$MATRIX_ROUTER' tools/lib/matrix.sh tools/ledger.sh tools/reconcile.sh
tools/dashboard.sh`: every use is `[ -f "$MATRIX_ROUTER" ]` (quoted test operand), a plain
`echo "...$MATRIX_ROUTER..." >&2` (no `-e`, no `xpg_echo`/`shopt` set anywhere in the file — so no
backslash-escape interpretation), or a quoted trailing filename argument to `awk` (a file
operand, not part of the awk program string). No `eval`, no unquoted expansion, no command
string built from it. A `MATRIX_ROUTER` containing spaces, `$()`, or backticks prints inertly and
cannot be misread as anything but a path in the message. Not reproducible as a finding.

### 5 · Privilege / surface growth — **none.**

No new file, network, process or credential reach. The diff adds one in-memory sentinel variable
and two early-return checks; the read path (`[ -f "$MATRIX_ROUTER" ]`, `awk ... "$MATRIX_ROUTER"`)
is unchanged.

---

## Findings

### INFO — the negative cache is an accepted, pre-existing pattern, not a new hole, and is unreachable through any real call path

`tools/lib/matrix.sh:39-41`. Within one un-forked shell, `_MATRIX_LOAD_FAILED` does suppress
re-detection of a router created after the first failed check (§1) — but the pre-existing
`_MATRIX_TABLE` success-cache has the mirror-image staleness under an in-place router edit (§2),
so this is symmetry with an already-shipped contract, not a new risk class. §3 traces every real
consumer (`ledger.sh`, `reconcile.sh`, `dashboard.sh`, `coverage.sh`) and finds every call site
reaches `_matrix_load` through a command substitution or pipe, which forks a subshell and
discards the cache mutation before the next top-level call — so the theoretical staleness cannot
manifest in production today. No trust boundary is crossed without a check.

### INFO — the fix does not achieve "warns once" for the case it names as motivation (adjacent to G6, not a threat)

`tools/lib/matrix.sh:32-38`, `tests/run.sh:1062`. Verified live: `bash tools/ledger.sh gates`
against a missing router still prints the warning **4 times** (same count the diff's own comment
attributes to the pre-fix bug); `tools/reconcile.sh` prints it **twice**. The reason is exactly
§3's mechanism: real callers invoke `matrix_*` through `$( )`/pipes, so the in-process cache this
diff adds never actually caches across the calls it was written for. The new test passes because
it calls the functions bare inside one subshell, a pattern no real consumer uses. No wrong answer
results — only repeated noise — so this is not filed as a trust-boundary finding; flagged for
routing to G6/Build since it bears directly on whether the change does what it claims.

### Not findings — checked and cleared

- Message-content injection / unsafe interpolation of `$MATRIX_ROUTER` (§4).
- Privilege or surface growth (§5).
- The negative cache as a *novel* attack surface (§1-§2: it is the pre-existing pattern, applied
  symmetrically).

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed by this change? | Checked? |
|---|---|---|
| Missing/invalid router → silent wrong "no gates mandatory" answer | **No** — still fails loud (`return 2`), every real caller | Yes, §3 |
| Stale cached failure → wrongly trusted over a fresh valid router | Theoretically yes in isolation, unreachable in practice | Yes, §1 + §3 |
| Stale cached success → wrongly trusted over a fresh invalid router | Pre-existing, unchanged by this diff | Yes, §2 |
| `$MATRIX_ROUTER` content → unsafe interpolation/eval | No | Yes, §4 |
| Privilege / new file / network / credential reach | None | Yes, §5 |

**Privilege growth:** none.

---

## Verdict

**G7 · Threat (HARD GATE, T4): PASS**, round 1.

`passes_when: no unresolved finding above low`. Both findings are `info`: no trust boundary is
crossed without a check, and no privilege grew. The specific hazard the assignment asked to be
walked for real — a stale cached failure silently suppressing detection of a now-valid router —
is real in isolation (§1) but is the same shape as a pattern this file already shipped and
documented (§2), and is not reachable through any call path this codebase's real consumers
exercise (§3), because every one of them calls through a subshell boundary that discards the
cache between top-level calls. The one thing actually reachable and verified live — the fix not
achieving "warn once" for `ledger.sh gates`, its own named motivating case — produces noise, not
a wrong trusted answer, and is G6/correctness territory rather than a G7 finding; filed `info` for
visibility rather than left unstated.

Confidence: **fresh** — this session received the diff, `surfaces.conf`, and
`tools/lib/matrix.sh`'s own header/comments only; no author intent log or session handoff was
read, and the untracked `specs/matrix-missing-router-warns-once/` directory was not opened.

**Premise challenged: yes.** The diff's stated design — "the failure is cached alongside the
success ... so callers ... [no longer] independently retried the load and reprinted the
three-line warning" — was tested against the exact caller it names (`ledger.sh gates`) rather
than accepted from the comment, and does not hold there (§3, live: 4 warnings, unchanged). The
new test was read as a claim to verify, not evidence to accept: it exercises a calling convention
(bare calls in one subshell) that no production caller uses, so it certifies a property the real
code doesn't have. Neither finding rises above `info` because the gap it exposes is about the
fix's effectiveness, not about a security control being bypassed — the "missing router" case
still fails loud and closed everywhere it was checked.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `info` | `tools/lib/matrix.sh:39-41` | `_MATRIX_LOAD_FAILED` can suppress re-detection of a router created after the first failed check within one un-forked shell (verified), but this mirrors the pre-existing `_MATRIX_TABLE` success-cache's identical staleness under an in-place router edit (also verified) and is unreachable through any real call path — every consumer (`ledger.sh`, `reconcile.sh`, `dashboard.sh`, `coverage.sh`) reaches `_matrix_load` through a command substitution or pipe, which forks a subshell and discards the cache before the next top-level call |
| 2 | `info` | `tools/lib/matrix.sh:32-38`, `tests/run.sh:1062` | The fix does not achieve "warns once per process" for its own named motivating case — `bash tools/ledger.sh gates` against a missing router still prints the warning 4 times, `tools/reconcile.sh` prints it twice, verified live — because real callers invoke `matrix_*` through `$( )`/pipes that fork a fresh subshell per call; the new test passes only because it calls the functions bare inside one subshell, a convention no real consumer uses. Correctness/G6-adjacent, not a trust-boundary finding |

## Ledger line

```
bash tools/ledger.sh add --change matrix-missing-router-warns-once --gate G7 --tier T4 --round 1 \
  --outcome pass --confidence fresh --challenged true --model claude-sonnet-5 \
  --note "security-reports/2026-09-16-matrix-missing-router-warns-once.md" \
  --finding "info::tools/lib/matrix.sh:39-41::negative cache mirrors the pre-existing success-cache's staleness under an in-place file change, verified live; unreachable through any real call path because every consumer reaches _matrix_load through a command substitution or pipe that forks a subshell and discards the cache before the next top-level call" \
  --finding "info::tools/lib/matrix.sh:32-38::the fix does not achieve warn-once for its own named motivating case (ledger.sh gates), verified live at 4 warnings unchanged and reconcile.sh at 2; the new test passes only because it calls the functions bare inside one subshell, a convention no real consumer uses"
```
