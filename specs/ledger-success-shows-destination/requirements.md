# ledger-success-shows-destination — Requirements

> Written at the Intent gate (G1a), after the fact — the fix was made reactively while picking
> up a queued chip, then routed back through the pipeline per R0c. Prompted by chip
> `task_f3521d2e`, filed during the `ledger-token-split` session's G8 Dogfood run: the
> `LEDGER=path && ledger.sh ...` footgun (documented in `tools/ledger.sh`'s own header,
> lines 28-33 — that assignment does not export, so the script silently falls back to its
> default path) fired live, and because `ledger.sh`'s self-hosting default now correctly
> resolves to *this repo's real* `ledger.jsonl` (fixed in an earlier session — see
> `tests/run.sh`'s `selfhostrepo`/`led_default` fixture), the entry landed in this repo's own
> real `ledger.jsonl` and had to be hand-removed.

## User

Anyone driving `ledger.sh add|route|escape|assume` from a shell — directly, from a dogfood
session, or from a wrapper script — who intends `--ledger <path>` or an exported `LEDGER=`
override to land the entry somewhere other than the default.

## Problem

`ledger.sh`'s own header already documents the `LEDGER=path && cmd` non-export footgun and
says the entry "lands somewhere other than where you meant." What it does not say, and what
nothing in the tool surfaced, is *that the tool gives no feedback about where it actually
went even on success.* `cmd_add`/`cmd_route`/`cmd_escape`/`cmd_assume` each print a
`"logged: ... $outcome"` confirmation on success (`tools/ledger.sh:704,805,807,829,912`), and
none of them name `$LEDGER`. Every REFUSED path already names `$LEDGER` in its message — only
the success path was silent. A misfired override is therefore invisible until someone goes
looking for the entry and doesn't find it (or, worse, finds it polluting a real ledger) —
exactly what happened live in G8 Dogfood this session, requiring a hand-removed stray entry
from this repo's own `ledger.jsonl`.

This tool cannot detect *that* an override was attempted and silently failed to export — a
non-exported shell variable is invisible to the child process by construction, so there is no
signal inside `ledger.sh` to catch. The only available fix is to make the actually-used
destination visible every time, on success as well as failure, so a mismatch between "where I
meant this to go" and "where it went" is caught by reading the very next line of output
instead of by discovering a missing (or an extra, unwanted) entry later.

## Acceptance criteria

- [x] `cmd_add`'s success line (`tools/ledger.sh:704`) names the resolved `$LEDGER` path.
- [x] `cmd_route`'s two success lines (`tools/ledger.sh:805,807`, the `--action`/no-`--action`
      branches) each name the resolved `$LEDGER` path.
- [x] `cmd_escape`'s success line (`tools/ledger.sh:829`) names the resolved `$LEDGER` path.
- [x] `cmd_assume`'s success line (`tools/ledger.sh:912`) names the resolved `$LEDGER` path.
- [x] No JSON record shape, field, or existing flag changes — this is a human-readable stderr
      confirmation message only, not part of the ledger's on-disk format.
- [x] A regression test demonstrates the destination path appears in a real `add` success
      message and did not before the fix (G5 Proof: fails against the unfixed code).

## Non-goals

- Does not attempt to detect a non-exported `LEDGER=` assignment from inside `ledger.sh` —
  established above as impossible by construction.
- Does not change `KIT_PREFIX`/self-hosting default-resolution logic
  (`tools/ledger.sh:130-154`) — that logic was already fixed and is already covered by the
  `selfhostrepo`/`led_default` fixture in `tests/run.sh`. This change is downstream of that
  fix: it makes the (now-correct) resolved default visible, it does not change what the
  default resolves to.
- Does not touch `status.sh` or the dashboard, which read the ledger file but never call
  these success paths.

## Assumptions

- **Treated as a `bug_fix`/silent-failure-mode fix, not a net-new capability** — no Scout (G2)
  or Craft (G3) run: no UI surface changes (G3's trigger), and this is not "net-new
  user-facing capability" (G2's trigger) but a visibility fix on an existing, already-shipped
  code path. `core/01-router.md` footnotes ¹² gate both on those triggers, neither of which
  this change hits.
- **The fix is a message-only change**, so it inherits `tools/ledger.sh`'s surfaces.conf tier
  (T4, `project/surfaces.conf:27`) rather than being scoped down — surfaces.conf pins the
  whole file, not a diff-size threshold, by design ("a wrong answer here is silent and
  confident").

## Acceptance (G1b)

The gate chain (G4 Ripple, G6 Peer, G7 Threat, G8 Dogfood — all fresh-context) materially
grew the diff beyond the six criteria above, converging on a shared theme none of them stated
independently: **the destination claim has to be true, not merely present.** Rather than strike
the original six, this records what each became.

| Criterion | Evidence |
|---|---|
| `cmd_add`/`cmd_route`(×2)/`cmd_escape`/`cmd_assume` success lines name `$LEDGER` | `tools/ledger.sh` — centralized into `emit()` itself (G4 Ripple finding: five hand-typed call sites is an enumerated list a sixth writer can miss) rather than left at each call site. `tests/run.sh`'s five `*_success_message_names_the_ledger_path` tests, all green. |
| No JSON record shape changed | `git diff` — every `emit "$(printf '{"type":...}')"` template byte-for-byte unchanged; only `emit()`'s signature and the human-readable stderr/stdout lines around it moved. |
| Destination is *actually* where the write landed, not just claimed | `emit()` now refuses (exit 3, no success line printed) when: the parent directory can't be created; the append itself fails (disk full/permission denied — G7 Threat round 1); `$LEDGER` exists and isn't a regular file — `/dev/null`, a device, a FIFO, a symlink to one (G7 Threat round 2). `tests/run.sh`: `test_emit_refuses_when_the_ledger_path_is_a_directory`, `..._directory_cannot_be_created`, `..._is_not_a_regular_file`, `..._file_is_not_writable` (the last added after G7 round 3 showed the directory test no longer reached the append-guard branch — each now pins a distinct code path). |
| `route` through the kit's own primary caller also surfaces the destination | `tools/reconcile.sh`'s `route` invocation used to discard ledger.sh's stdout entirely (G6 Peer round 1 finding); now captures and prints it. Live-verified in `## Round 2`/`## Round 3` of the security report and `test_reconcile_flag_order_independent`. |
| A regression test demonstrates the fix (G5 Proof) | Every test above verified to fail against the pre-fix code and pass against the fix, individually, before being folded into the suite — not merely written after and assumed correct. |
| Nothing regresses | Full suite: **867/0/0**, run clean after the diff stabilized (an earlier 854/1 run's one failure was a pre-existing, unrelated flaky wall-clock test — reproduced failing against a clean `HEAD` worktree with this change entirely absent, filed separately as `task_6776958a`). |

**Not built, by design:** detecting a non-exported `LEDGER=` at the point of failure (still
impossible by construction — see Non-goals). **Deferred, not this change's job:** G8 Dogfood
surfaced a repeated router-warning in `report`/`gates` (new chip `task_0923d53d`) and a
truncated `--help` header (confirms the already-queued chip `task_0d68cd41` from a prior
session) — neither reachable from this diff (`git diff` confirms `report`/`gates`/help-text
code paths untouched) — routed as follow-ups per the failure rule's "route it to a separate
follow-up" clause, not folded into this change.
