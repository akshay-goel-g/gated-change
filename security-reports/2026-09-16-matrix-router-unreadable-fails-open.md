# G7 · Threat review — `matrix-router-unreadable-fails-open` (T4, hard gate, round 1, 7c depth)

**Reviewed:** the **uncommitted working-tree diff** on top of `bbcb30d6fa3974ccc8c27b41994f77bc5980dca2`
("auto: regenerate dashboard.html (pre-push)") — `git rev-parse HEAD` → `bbcb30d6fa3974ccc8c27b41994f77bc5980dca2`.
Diff obtained via `git diff -- tools/ledger.sh tools/reconcile.sh tests/run.sh`, unchanged and
still uncommitted at review time. This is a fresh session: only this prompt, `project/surfaces.conf`,
the diff itself, `tools/lib/matrix.sh` (read because the diff's new checks call into it, though the
diff does not modify it), and the prior report `security-reports/2026-09-16-matrix-missing-router-warns-once-round2.md`
(read for trust-boundary context on a *different*, already-fixed bug in the same files) were read.
`specs/matrix-router-unreadable-fails-open/requirements.md` was **not** opened, per the card's
`withhold` line — the threat model below is derived from the diff and from `tools/lib/matrix.sh`'s
own code and comments, not from the author's stated intent.

**Files in scope and their tier** (`project/surfaces.conf`, `SELF: gated-change` at line 3):

| File | Tier | surfaces.conf rule |
|---|:--:|---|
| `tools/ledger.sh` | **T4** | `:27` — "Routing and evidence — a wrong answer here is silent and confident" |
| `tools/reconcile.sh` | **T4** | `:27` — same rule, same file family |
| `tools/lib/matrix.sh` (read, not modified by this diff) | **T4** | `:28` — "The gate matrix reader — decides what is mandatory" |
| `tests/run.sh` | T3 | `:50` — "The suite — if it stops asserting, nothing else here is trustworthy" |

Change tier = **T4** (the max), which is what makes this a hard gate.

---

## Threat model, derived from the diff

The diff adds one identical guard to `cmd_compliance()` (`tools/ledger.sh:1252-1259`) and to
`reconcile.sh`'s gate-listing section (`tools/reconcile.sh:584-591`): call `_matrix_load` directly
(not through `$(...)`) and, if it returns non-zero, print `REFUSED` and `exit 2` instead of falling
through to `required_gates_for`/`matrix_required`/`matrix_conditional`, whose *empty* output is
otherwise indistinguishable from "this tier legitimately mandates nothing."

Untrusted/relevant parties, read off the diff's own comments and `surfaces.conf:21-25` ("the kit's
entire defect history is tools returning a confident wrong answer rather than an error"):

1. **A confused user or CI environment** whose `core/01-router.md` gets moved, deleted, emptied, or
   corrupted — by accident, by a bad merge, by a tool that touches the wrong path.
2. **A hostile PR author** who wants unreviewed T4 code to ship. `core/01-router.md` is itself listed
   as a T4 surface (`surfaces.conf:31`, "every tool derives from it"), so an edit to it is visible in
   the diff — but *how much* of an edit is needed to defeat the gate matters: a one-line reformat
   buried in a 291-line markdown table reads, to a reviewer skimming a diff, as a typo fix, not as an
   attack.
3. **A reader of `ledger.sh compliance` / `reconcile.sh` output** who trusts an `INCOMPLETE`/`Reconciled`
   report to be a complete account of what is mandated.

**What the diff makes reachable:** the fix closes the case where `_matrix_load` itself fails — file
missing, or the whole table unparseable. It does **not** change `_matrix_load`'s own semantics for a
table that partially parses. `tools/lib/matrix.sh:57` (`if (NF < 9) next`) silently drops any row that
doesn't split into at least 9 tab/pipe fields, and a dropped row simply isn't in `$_MATRIX_TABLE`, no
error, no warning — `_matrix_load` returns 0 either way, because `$_MATRIX_TABLE` is non-empty as long
as *any* row parsed. `01-router.md:198-200` names this exact failure class from an earlier bug
("a malformed gate-table row silently dropped a HARD GATE with exit 0" —
`security-reports/2026-08-13-first-push-matrix-hook-review.md`, Finding 1), in the file the diff under
review is supposed to be hardening against.

---

## The walk — real commands, real output, against a scratch copy

Built a fresh scratch repo mirroring `tests/run.sh`'s `newrepo()` fixture (full `.pipeline/` copy of
this worktree, `git init`, `ledger.sh add` a `G1` pass) under
`C:\Users\<user>\AppData\Local\Temp\claude\...\scratchpad\g7review\repo1`, then exercised
`tools/ledger.sh compliance` and `tools/reconcile.sh` against several router states.

### 1 · Missing router and fully-empty router — the fix works exactly as designed

```
$ mv core/01-router.md core/01-router.md.bak
$ bash tools/ledger.sh compliance --change c --tier T4
matrix: no router at .../core/01-router.md
  ...
REFUSED: the gate matrix could not be read — see the error above.
$ echo $?
2
```

```
$ : > core/01-router.md        # 0 bytes
$ bash tools/ledger.sh compliance --change c --tier T4
matrix: .../core/01-router.md has no gate rows — is the table intact?
REFUSED: the gate matrix could not be read — see the error above.
$ echo $?
2
```

Both match the new tests (`tests/run.sh:1121-1129`, `test_ledger_compliance_refuses_when_router_missing`;
`tests/run.sh:1148-1163`, `test_reconcile_refuses_when_router_missing`) and both are genuinely fixed —
`REFUSED`, exit 2, no "mandates no gates" / "none mandatory" fall-through. Confirmed also that the
tier-legitimately-empty path (T0 against an intact router) still reports cleanly
(`test_ledger_compliance_reports_nothing_to_check_when_tier_legitimately_empty`, `tests/run.sh:1131-1138`)
— the fix does not over-refuse.

### 2 · A single row removed from an otherwise-intact table — **the fix does not catch this**

Removed only the `G7` row from an otherwise-intact `core/01-router.md` (`grep -vF '**G7 '`), leaving 7
of 8 gate rows parseable. `_matrix_load` returns **0** (table is non-empty), so the new guard in both
`cmd_compliance` and `reconcile.sh` never fires:

```
$ bash tools/ledger.sh compliance --change c --tier T4
Gate compliance — c, tier T4, round 1
-------------------------------------------------------
  PASS       G1   Intent
  NOT RUN    G4   Ripple
  NOT RUN    G5   Proof
  NOT RUN    G6   Peer
  NOT RUN    G8   Dogfood
  ...
INCOMPLETE — 4 mandated gate(s) without a pass: G4 G5 G6 G8
$ echo $?
1
```

`G7` is not in the `NOT RUN` list, not in the `INCOMPLETE` summary, and no warning of any kind is
printed. A change with only `G1` logged reads as "4 gates outstanding" — never "5", never a hint that
the matrix itself lost a row. This is a **silent, confident wrong answer**, not the loud refusal the
diff exists to guarantee.

`reconcile.sh` shows the identical gap against the same corrupted router:

```
$ BASE=<sha> bash tools/reconcile.sh T4
...
Actual tier : T4
Predicted   : T4
Gates       : Intent, Ripple, Proof, Peer, Dogfood
Also check  : Scout¹, Craft²  (recommended; the footnote may make it mandatory)

Reconciled — routing matches. This says nothing about whether the
gates above ran.
$ echo $?
0
```

`Gates :` lists five names — **Threat is not one of them** — and the run ends in `Reconciled —
routing matches`, exit 0, with no `REFUSED`, no warning, nothing distinguishing this from a router
that genuinely never mandated G7 at T4.

### 3 · A malformed (not removed) row reaches the same bypass

Rather than deleting the `G7` line, collapsed its cell separators (` | ` → ` `) so it still contains
the literal text `**G7 · Threat**` but no longer splits into ≥9 fields — reproducing
`tools/lib/matrix.sh:57`'s `NF < 9` skip condition, i.e. the "malformed table row" case the task asked
about directly, as distinct from "row missing." Same result as §2, byte for byte:

```
$ bash tools/ledger.sh compliance --change c --tier T4
...
INCOMPLETE — 4 mandated gate(s) without a pass: G4 G5 G6 G8
$ echo $?
1
```

No `REFUSED`. `_matrix_load` still returns 0 because the other 7 rows parsed fine.

### 4 · Why this is the sharper version of the exact exploit the diff claims to close

The pre-fix bug (round-2 report, §4) was: delete/rename the *whole* router, get
`Tier T4 mandates no gates. Nothing to check.` at exit 0. That is a large, conspicuous diff — deleting
or renaming `core/01-router.md` is hard to miss in a PR review, and this diff correctly closes it
(§1). §2–§3 show a strictly quieter version of the same attack surface survives: corrupt **one row**
of an otherwise-untouched 291-line table — plausible as an honest reformatting mistake, or as a
one-line deliberate edit hidden in the file the diff's own new comments (`tools/ledger.sh:1246-1251`,
`tools/reconcile.sh:577-583`) say a caller must trust completely — and the exact gate that row names
(here, `G7`, the **hard gate** itself, `01-router.md:279`: `**M (hard)**` at T4) silently stops being
counted as mandated, with the output still looking like a normal, if incomplete, compliance run. This
is precisely the failure `surfaces.conf:21-25` names as the kit's defect history and precisely the
class `01-router.md:198-200` already documents happening once before in this same file family. The
diff's own new tests (`tests/run.sh:1113-1163`) only exercise the "router moved aside entirely" case
in both `ledger.sh` and `reconcile.sh` — neither exercises a partially-corrupted table, so the test
suite does not catch this gap either.

### 5 · `MATRIX_ROUTER` override / symlink / race — not a distinct new vector

`tools/lib/matrix.sh:22` resolves `MATRIX_ROUTER` once, from the environment, before any subcommand
dispatch; grepping `tools/ledger.sh` and `tools/reconcile.sh` shows neither script reassigns it after
sourcing `matrix.sh`. A hostile `MATRIX_ROUTER` pointed at an attacker-controlled file reaches the same
`_matrix_load` code path as the real router — so it can produce the §2/§3 bypass (a crafted file with
one gate's row malformed) but does not open any *additional* bypass beyond what a direct edit to
`core/01-router.md` already reaches. A symlink resolves transparently through the `-f` test with no
special handling either way. A TOCTOU race between the `-f` check (`matrix.sh:41`) and the awk read
two lines later would, at worst, degrade to the same "file vanished mid-read" shape already covered by
§1 (awk on a since-deleted file yields empty output, `_MATRIX_TABLE` stays empty, `_MATRIX_LOAD_FAILED`
is set, `REFUSED` fires) — not a fail-open. Not filed as a finding; noted as checked.

### 6 · Exit code 2 — where it's actually enforced

`grep` across `templates/pre-push` and `tools/hooks/` shows neither invokes `ledger.sh compliance` or
`reconcile.sh` as part of the git pre-push flow — the hook instead checks that a trust-boundary push
has a matching dated `security-reports/*.md` file naming the commit sha (see this report's own
requirement). `.github/workflows/tests.yml` runs `tests/run.sh`, whose `assert_exit 2` calls
(`tests/run.sh:1122`, `:1150`) are what actually pins this exit code to a CI-visible failure — i.e.
exit 2 is enforced by the test suite failing, and by whichever human/agent runs `compliance`/`reconcile`
directly as part of a gate (as this review does). It is not wired into an automatic per-push
recomputation against live repo state. Per this session's own memory of this repo, GitHub Actions is
currently disabled for non-payment, so today `tests.yml` does not actually run on push — an
operational fact about this repo, not a defect introduced by this diff, and outside this diff's
mechanism to fix. Not filed as a blocking finding against this diff; noted because the card's question
asked directly whether exit 2 could be silently swallowed, and the honest answer is "not by design, but
CI is not currently running to enforce it."

---

## Findings

### BLOCKING — the fix catches whole-file/whole-table failure but not row-level corruption, including of the row that names this very hard gate

`tools/ledger.sh:1252-1259`, `tools/reconcile.sh:584-591`, root cause `tools/lib/matrix.sh:40-81`
(specifically `:57`, `if (NF < 9) next`, and `:78`, the "no gate rows" check that only fires when
*every* row failed to parse). Verified live (§2, §3): removing or malforming a single gate row —
demonstrated against `G7`'s own row, the `M (hard)` cell at T4 — leaves `_matrix_load` returning 0
(success), so neither new guard fires. `ledger.sh compliance --tier T4` reports `INCOMPLETE` naming
only the gates whose rows survived, silently omitting the corrupted gate from both the `NOT RUN` list
and the summary count; `reconcile.sh` prints `Gates :` without the corrupted gate and ends in
`Reconciled — routing matches`, exit 0. No warning, no `REFUSED`, in either tool. This is a trust
boundary (which gates a T4 change must pass before shipping) crossed without a check — the exact
`fails_when` this gate exists to catch — and it is reachable by a change no more conspicuous than a
one-line edit to `core/01-router.md`, a file whose 291 lines make a single malformed row easy to miss
in review and whose own comments (`:198-200`) already document this class of bug happening once
before. The diff's spec name (`matrix-router-unreadable-fails-open`) and its own in-code comments
(`tools/ledger.sh:1246-1248`, `tools/reconcile.sh:577-579`) describe the failure it closes as "the
router could not be read at all" — true of the cases it does close, but the task's own framing (and
`01-router.md`'s cited history) makes clear "unreadable" was meant to include "unreadable in part,"
which this diff does not achieve.

**Recommended fix shape** (described, not applied, per instructions): either (a) have `_matrix_load`
validate that the parsed table contains a row for every `G[1-8]` gate id it expects (a fixed, known
set, not derived from the file itself) and treat a missing expected id the same as "no gate rows," or
(b) have `_matrix_load` count awk's skip events (e.g. emit a sentinel on `next` for a line that matched
the row-start pattern `/^\| \*\*G[0-9]/` but failed the `NF < 9` check) and fail loudly when any row
that looked like a gate row didn't fully parse, rather than only when the whole table came back empty.
Either closes the gap this diff's own two new call sites are already positioned to make use of, since
both already treat "`_matrix_load` failed" as `REFUSED`/exit 2 — the missing piece is entirely inside
`tools/lib/matrix.sh`, a file this diff reads from but does not modify.

### INFO — the whole-file/whole-table cases the fix targets are genuinely closed, verified live

`tools/ledger.sh:1252-1259`, `tools/reconcile.sh:584-591`, `tests/run.sh:1121-1163`. Missing router and
zero-byte router both now produce `REFUSED`, exit 2, in both `compliance` and `reconcile.sh` (§1),
matching the new tests. The tier-legitimately-empty path (T0, intact router) is unaffected — no
over-refusal. The guard is correctly placed as a **direct** (non-subshelled) call in both files, with
comments explaining why (`tools/ledger.sh:1249-1251`, `tools/reconcile.sh:581-583`) — verified this
matters: `_matrix_load`'s cache-write must land in the calling process, not a forked `$(...)` subshell,
for the exit-status check to see a real failure rather than a stale/default success.

### INFO — no new trust boundary from the diff itself; `MATRIX_ROUTER`/symlink/race checked and cleared

§5. The new guard reads state (`_matrix_load`'s return code) that already existed; it introduces no
new input, no new file write, no new privilege. `MATRIX_ROUTER` is resolved once per process
everywhere in this codebase (consistent with the round-2 report's independent finding on the same
point) and neither script under review reassigns it. A hostile override reaches the same §2/§3 gap,
not a distinct one.

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed by this diff? | Checked? |
|---|---|---|
| Router entirely missing/unreadable → silent "no gates mandatory" | No — now `REFUSED`, exit 2, verified live | Yes, §1 |
| Router present but empty/no rows → silent "no gates mandatory" | No — now `REFUSED`, exit 2, verified live | Yes, §1 |
| **Router present, one gate row removed or malformed → silent omission of that gate from what's mandated** | **Yes — verified live against `compliance` and `reconcile.sh`, both exit 0/1 with no warning, naming G7's own row** | **Yes, §2–§4 — BLOCKING** |
| Hostile `MATRIX_ROUTER` / symlink / TOCTOU race opening a distinct bypass | No new distinct vector beyond the row-corruption gap above | Yes, §5 |
| Exit 2 silently swallowed by pre-push/CI | Not by design; CI is not currently running for this repo (operational, not a diff defect) | Yes, §6 |
| Privilege / new file / network / credential reach | None | Yes |

**Privilege growth:** none.

---

## Verdict

**G7 · Threat (HARD GATE, T4): FAIL**, round 1.

`fails_when: a trust boundary is crossed without a check` — confirmed, live, twice, against both
`tools/ledger.sh compliance` and `tools/reconcile.sh`, using the least conspicuous form of exactly the
attack this diff's spec name says it closes: a single malformed or missing row in `core/01-router.md`,
demonstrated against the row for this very gate (`G7`, `M (hard)` at T4), leaves both tools reporting a
plausible-looking, silently-incomplete result at exit 0/1 rather than the `REFUSED`/exit 2 the diff's
own new tests certify for the whole-file case. The whole-file/whole-table case genuinely is fixed
(§1, INFO) and the fix's own design (direct, non-subshelled `_matrix_load` call, correctly placed in
both files) is sound as far as it reaches — the gap is entirely inside `tools/lib/matrix.sh`'s row
parser, which this diff reads from but does not touch, and which already has one documented prior
incident of exactly this shape (`01-router.md:198-200`).

Confidence: **fresh** — every claim in this report is backed by a command run against a fresh scratch
copy of this worktree (`.../scratchpad/g7review/repo1`), not by reading the code and reasoning about
what it should do. The author's stated intent (`specs/matrix-router-unreadable-fails-open/requirements.md`)
was not opened.

**Premise challenged: yes.** The task's framing asked explicitly whether the new check "actually
catches every one of those cases, or only the outright-missing-file case" — rather than accepting the
diff's own comments and tests (which describe and exercise only the whole-file/whole-table cases) as a
complete account, this review constructed the two cases the task named but the diff's tests do not
cover (truncated/partial table, malformed individual row) and ran them live against both tools,
finding the gap the framing anticipated. The "does exit 2 get treated as a hard failure by CI"
sub-question was also verified by tracing actual call sites (`templates/pre-push`, `tools/hooks/`,
`.github/workflows/tests.yml`) rather than assumed.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `blocking` | `tools/ledger.sh:1252-1259`, `tools/reconcile.sh:584-591`, root cause `tools/lib/matrix.sh:40-81` (`:57` `NF < 9` skip, `:78` empty-table check) | `_matrix_load` returns success (0) whenever at least one gate row parses, so a single removed or malformed row (verified against `G7`'s own row, the hard-gate cell at T4) is silently dropped from what `matrix_required`/`matrix_conditional` report. Neither new guard fires. `ledger.sh compliance --tier T4` reports `INCOMPLETE` omitting the corrupted gate entirely (no warning, exit 1); `reconcile.sh` prints a `Gates :` line omitting it and ends `Reconciled — routing matches` at exit 0. This is the same fail-open failure class the diff's own spec name and tests target, reachable via a one-line, easy-to-miss edit rather than the whole-file deletion the diff's tests cover |
| 2 | `info` | `tools/ledger.sh:1252-1259`, `tools/reconcile.sh:584-591`, `tests/run.sh:1121-1163` | The whole-file-missing and whole-table-empty cases are genuinely fixed, verified live: `REFUSED`, exit 2, in both `compliance` and `reconcile.sh`; the tier-legitimately-empty path is unaffected. Guard is correctly placed as a direct (non-subshelled) call in both call sites |
| 3 | `info` | `tools/lib/matrix.sh:22`, `tools/ledger.sh`, `tools/reconcile.sh` | `MATRIX_ROUTER` is resolved once per process and never reassigned by either script under review; a hostile override or symlink reaches the same row-corruption gap (finding 1) rather than a distinct new bypass. TOCTOU race between the file-exists check and the awk read degrades to the already-covered "file vanished" case, not a new fail-open |
| 4 | `info` | `templates/pre-push`, `tools/hooks/`, `.github/workflows/tests.yml` | Exit 2 is enforced by the test suite's `assert_exit 2` and by direct human/agent invocation as part of a gate — not by an automatic per-push recomputation against live repo state. GitHub Actions is currently disabled for this repo (non-payment, per session context), so `tests.yml` does not run on push today; an operational fact, not a defect this diff introduces or could fix |

## Ledger line

```
cd "D:\work\gated-change\.claude\worktrees\amazing-jones-bf8e9e" && bash tools/ledger.sh add \
  --change matrix-router-unreadable-fails-open --gate G7 --tier T4 --round 1 \
  --outcome fail --confidence fresh --challenged true --model claude-sonnet-5 --tokens 55000 \
  --finding "blocking::tools/lib/matrix.sh:40-81::_matrix_load returns success whenever at least one gate row parses; a single removed/malformed row (verified against G7's own hard-gate row at T4) is silently dropped from matrix_required/matrix_conditional with no warning, reproducing the router-unreadable fail-open this diff's guards in ledger.sh:1252-1259 and reconcile.sh:584-591 do not catch because _matrix_load itself reports success" \
  --finding "info::tools/ledger.sh:1252-1259,tools/reconcile.sh:584-591::whole-file-missing and whole-table-empty cases genuinely fixed, verified live via REFUSED/exit 2 in both tools; tier-legitimately-empty path unaffected" \
  --finding "info::tools/lib/matrix.sh:22::MATRIX_ROUTER resolved once per process, never reassigned by either script; hostile override/symlink reaches the same row-corruption gap, not a distinct bypass" \
  --finding "info::templates/pre-push,.github/workflows/tests.yml::exit 2 enforced by test suite assertions and direct gate invocation, not automatic per-push recomputation; GitHub Actions currently disabled for this repo for non-payment, an operational fact not a diff defect"
```
