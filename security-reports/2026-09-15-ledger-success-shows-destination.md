# G7 · Threat review — `ledger-success-shows-destination` (T4, hard gate, round 1, 7c depth)

**Reviewed:** the **uncommitted working-tree diff on top of `4fd9929`** ("auto: regenerate
dashboard.html (pre-push)"). **No commit exists for this change at review time**, so this report
cannot name a sha for the thing it reviewed — the subject is
`git diff -- tools/ledger.sh tests/run.sh` plus those two files as they sit on disk. Per the
`ledger-token-split` precedent (`security-reports/2026-09-15-ledger-token-split.md`, "Commit
binding"), this report **needs a post-commit binding addendum** once the change lands, naming the
real sha and itemizing any edits made after this review. That is not a reason to block.

There is also one untracked directory, `specs/ledger-success-shows-destination/`. Its contents were
deliberately **not** opened: the card's `withhold:` line withholds the author's threat assessment and
the change's stated purpose, and that directory is where both live.

**Files in scope and their tier** (`project/surfaces.conf`, which declares `SELF: gated-change` at
line 3 — these are **this repository's own** trust boundaries, not the shipped example, so a clean
or dirty report against them is about real surfaces):

| File | Tier | surfaces.conf rule |
|---|:--:|---|
| `tools/ledger.sh` | **T4** | `:27` — "Routing and evidence — a wrong answer here is silent and confident" |
| `tests/run.sh` | T3 | `:50` — "The suite — if it stops asserting, nothing else here is trustworthy" |
| `specs/ledger-success-shows-destination/` | T0 | no rule matches (untracked, withheld, not read) |

Change tier = **T4** (the max), which is what makes this a hard gate: `passes_when: no unresolved
finding above low`.

**Prior findings inherited** (standing threat model, not re-derived):
`2026-09-15-ledger-token-split.md` (rounds 1-3 + binding addendum — the standing rule that *a value
in a bare, unquoted JSON position is refused, not escaped*; carried-forward info finding at
`tools/ledger.sh:1699`, verbatim reflection of caller bytes to the terminal),
`2026-09-08-confidence-vocabulary-refusal.md`, `2026-09-06-r005-computed-default-branch.md`,
`2026-08-14-cli-input-validation-hardening.md`, `2026-08-13-587e8e1.md` (BLOCKING — `--lane` spliced
a duplicate JSON key and flipped `compliance` from FAIL to PASS).

---

## Threat model — who is untrusted here

`ledger.jsonl` is this repo's **evidence of record**, and it is append-only. The standing threat
model names three parties; this diff re-ranks them, because **the diff writes nothing new into the
ledger — it changes only what is printed on stdout**:

1. **A subagent invoking `ledger.sh` to grade itself or another gate.** It supplies `--change`,
   `--model`, `--note` — and, in the fixture and CI shapes, `--ledger`/`LEDGER`. Critically, the
   kit's own workflow treats this command's **stdout line as the evidence that the gate ran**:
   `templates/agent-instructions.md:51` and `templates/PULL_REQUEST_TEMPLATE.md:49` both instruct
   the caller to run it and report back, and gate-runner prompts in this repo routinely say "paste
   its `logged: …` output line". That makes the success line an **artifact a human approver trusts
   without opening the file**.
2. **A confused user** — the party the card names explicitly, and the one the documented footgun at
   `tools/ledger.sh:29-33` (`LEDGER=path && ledger.sh …`, which does not export) is about.
3. **A reader of the ledger** — harmed, not hostile.

**The novel surface this diff creates:** the success line, on every writing subcommand
(`:704`, `:805`, `:807`, `:829`, `:912`), now **asserts a specific destination file**. Before the
diff, `logged: …` was a vague claim; after it, it is a *specific, checkable* claim — and specific
claims are worth forging and worth being wrong about. Two questions follow: (a) can the claim be
false while the exit code is 0, and (b) can the bytes it now carries be chosen by the caller.
Nothing new is *accepted*, so the injection/forgery classes from rounds 1-3 of the token-split
review are not re-opened by this diff; they were re-tested anyway (§4).

---

## The trust-boundary walk

Setup for everything below: `mktemp -d`, `git init`, a real commit, `bash tools/ledger.sh` invoked
against scratch ledgers. All output pasted is real.

### 1. Can the newly-asserted destination be false while the command reports success? — **Yes. This is the finding.**

`emit()` (`tools/ledger.sh:312`) is a bare
`mkdir -p "$(dirname "$LEDGER")"; printf '%s\n' "$line" >> "$LEDGER"` — **the append's exit status is
never checked**, and the file runs `set -uo pipefail` with no `-e`. `cmd_add` therefore reaches
`:704` unconditionally. Four live shapes, every one of them exit 0:

```
$ ledger.sh add --ledger /nonexistent-root-zz/deep/ledger.jsonl …
mkdir: cannot create directory '/nonexistent-root-zz': Permission denied          [stderr]
ledger.sh: line 312: /nonexistent-root-zz/deep/ledger.jsonl: No such file or directory  [stderr]
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /nonexistent-root-zz/deep/ledger.jsonl
exit=0

$ ledger.sh add --ledger /dev/null …
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /dev/null            exit=0   (no stderr at all)

$ ledger.sh add --ledger "$T/dirledger" …        # path is an existing directory
ledger.sh: line 312: /tmp/…/dirledger: Is a directory                             [stderr]
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /tmp/…/dirledger      exit=0

$ ledger.sh add --ledger '' …
ledger.sh: line 312: : No such file or directory                                  [stderr]
logged: G1 (Intent) on c — round 1, 0 finding(s), pass →                       exit=0
```

In all four the named file does not contain the record. The `/dev/null` case prints **no diagnostic
whatsoever** — a plausible CI or container shape (`LEDGER=/dev/null` to "turn off" logging) that
yields a clean, confident, entirely false success line.

The unchecked write is **pre-existing**; what this diff changes is its *severity*, in the direction
that matters. The old line claimed only "logged". The new line names a file — so a reader who
previously had nothing to check now has something to check, is told it, and is told wrong. The
evidence artifact the kit's own templates instruct callers to paste back is now a falsifiable claim
that is false, on stdout, with exit 0, while the only contradiction sits on stderr where a captured
`$(…)` or a `>/dev/null 2>&1`-style invocation (the shape `tests/run.sh:2009` itself uses) discards
it. This is `surfaces.conf:27` — "a wrong answer here is silent and confident" — reached by the very
line added to prevent it, and `fails_when: a trust boundary is crossed without a check`: the
caller-supplied path crosses into a filesystem write that is never verified.

Fix shape (not prescriptive): make `:312` `|| { echo "REFUSED: could not append to $LEDGER" >&2;
exit 3; }`, so the success line is unreachable when the write failed. The refusal vocabulary and the
"Nothing was written to $LEDGER" idiom already exist ten lines up.

### 2. Does the change work for the footgun it addresses? — **Yes, and that is worth recording.**

The documented non-exporting-assignment footgun (`tools/ledger.sh:29-33`) now announces itself:

```
$ cd /tmp/scratch && LEDGER="$T/wanted.jsonl" && ledger.sh add --change c2 --gate G1 …
logged: G1 (Intent) on c2 — round 1, 0 finding(s), pass → /d/work/gated-change/ledger.jsonl
```

The entry landed in this repo's **real** ledger, exactly as the header warns — and the new suffix is
what made it visible immediately rather than "discovered by going looking for it afterward". The
mechanism does what it claims when the write *succeeds*. (**Disclosure:** that probe wrote one
`"change":"c2"` line into the repo's real `ledger.jsonl`. It was a review artifact, not a record;
`ledger.jsonl` was untouched at session start, so it was restored with `git checkout -- ledger.jsonl`
and `git status` is back to `M tests/run.sh`, `M tools/ledger.sh`, `?? specs/…`. No other write
touched anything outside `mktemp -d` scratch repos.)

### 3. Can the caller choose the bytes the success line now carries? — **Yes, but the class is pre-existing.**

`$LEDGER` reaches **stdout** verbatim for the first time. A newline in the path forges a second,
fully-formed success line for a gate that never ran:

```
$ ledger.sh add --ledger "$(printf '%s/real.jsonl\nlogged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass')" …
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /tmp/…/real.jsonl
logged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass
exit=0
```

A `\r` in the path overwrites the real line instead (`… → /tmp/…/x.jsonl<CR>logged: FAKE pass`).
Against the party that matters — a subagent producing a transcript a human skims — that is evidence
forgery. It is rated `info` and not higher **only** because the identical channel already exists
through `--change`, which has no charset validation at all (only `change_is_branchy`, `:263`):

```
$ ledger.sh add --change "$(printf 'a\nlogged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass')" …
logged: G1 (Intent) on a
logged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass — round 1, 0 finding(s), pass → …
exit=0
```

So the diff adds a **new channel into a known class**, not a new class — the same judgement the
token-split review applied to the `:1699` stderr reflection it carried forward as `info`. Recorded
so that a future "just sanitize the path" fix is visibly incomplete if it leaves `--change` alone.

### 4. Re-tested and unchanged (no regression from this diff)

- **No new input.** The diff adds zero flags and zero accepted values. Every refusal path, the
  bare-JSON position set, `is_uint`/`is_uint_bounded`, the `$(( ))` ordering at `:543`, and the
  paired-flag rules are untouched by both hunks — confirmed by reading the diff, which is purely
  `echo` string edits in `cmd_add`/`cmd_route`/`cmd_escape`/`cmd_assume` plus additive tests.
- **`emit()`'s structural JSON check and the newline refusal** (`:297-311`) are unmodified; a raw
  newline still cannot enter the *record* (it is `json_escape`d into `\n`), only the *message*.
- **No consumer parses the success line.** `grep -rn "logged:"` across `tools/`, `templates/`,
  `core/`, `tests/` finds no parser — `templates/pre-push` does not read it, `reconcile.sh` does not
  capture it, `dashboard/app.js` reads the file. Appending ` → $LEDGER` breaks nothing downstream.
- **Privilege growth: none.** No new file, network, process or credential reach; the same single
  file is written through the same `emit()`.

### 5. Does the suite actually pin the new behaviour? — **Partly.**

All five new tests (`tests/run.sh:3289-3322`) call `led()`, which is defined at `tests/run.sh:239`
as always passing `--ledger "$(ledger_path)"`. They therefore assert only that the tool echoes back a
path it was handed one moment earlier. The case the change exists for — the **resolved default**,
where `$LEDGER` was never supplied and the user's mental model is wrong (§2) — is asserted by no
test, even though the fixture for it already exists (`led_default` / `selfhostrepo`, used by
`test_ledger_default_path_is_self_hosting_aware` at `tests/run.sh:2024`). The suite's own comment at
`:241-244` warns about exactly this blind spot in `led()`. No test covers §1 either.

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed? | Checked? |
|---|---|---|
| Caller-supplied path (`--ledger`/`LEDGER`) → filesystem write | Yes | **No — `:312` never checks the append; success line prints anyway (§1)** |
| Caller-supplied path → stdout treated as gate evidence | Yes | **No — newline/CR forge or overwrite a success line (§3, `info`: channel, not class)** |
| Untrusted CLI argument → bare JSON position | Yes | Yes — untouched by this diff, re-confirmed by inspection (§4) |
| `ledger.jsonl` → `compliance` verdict path | No | No `tokens`/message reference; unaffected |
| Success line → any downstream parser | No | Confirmed: no parser exists (§4) |
| `tests/run.sh` → what the suite still asserts | Yes | Partly — new tests are fixture-tautological (§5) |

**Privilege growth:** none.

---

## Verdict

**G7 · Threat (HARD GATE, T4): FAIL**, round 1.

`passes_when: no unresolved finding above low`. Finding 1 is `minor`, which is above low, so the
hard gate fails and the change goes back to Build. Nothing here is `blocking` — no injection, no
forgery class that did not already exist, no privilege growth, and the record written to the ledger
is byte-for-byte what it was before this diff.

The reason finding 1 is not `info`: this change's entire value is that the destination line is
*trustworthy enough to act on*. A destination claim that is confidently wrong whenever the write
failed is not a smaller version of that value, it is the inverse of it — and it is the single failure
mode `surfaces.conf:27` pins this file at T4 for. The fix is one `||` clause at `:312`.

Confidence: **fresh** — this session received the G7 card, `surfaces.conf`, the diff, `git status`,
prior ledger.sh security reports, and the two files under review. `specs/ledger-success-shows-
destination/requirements.md` was withheld and never opened, and no one was asked what the change was
for; the threat model above is derived from the diff and the surfaces file alone.

**Premise challenged: yes.** The change's implicit premise — that printing the destination makes a
misdirected write visible — was tested in both directions rather than accepted. It holds for a write
that succeeds somewhere surprising (§2, live-confirmed against this repo's own real ledger) and
inverts for a write that fails (§1). The new tests were checked against what they actually exercise
rather than against their names, which produced §5.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `minor` | `tools/ledger.sh:704` | The success line now names `$LEDGER`, but `emit()` at `:312` never checks the append, so a failed write still prints `logged: … pass → <path>` on stdout and exits 0 while that file holds nothing — live-confirmed with an unwritable parent, a directory path, an empty path, and `/dev/null` (which emits no diagnostic at all). Also fires on `route`/`escape`/`assume` (`:805`,`:807`,`:829`,`:912`). The only contradiction is on stderr, which the kit's own capture idioms discard |
| 2 | `info` | `tools/ledger.sh:704` | `$LEDGER` reaches stdout verbatim: a `\n` in the path prints a second fully-formed `logged: G7 (Threat) on sneaky … pass` line, a `\r` overwrites the real one. New channel into a class that already exists via unvalidated `--change` (live-confirmed), so a path-only sanitization fix would be incomplete |
| 3 | `info` | `tests/run.sh:3289` | All five new tests go through `led()` (`:239`), which always passes `--ledger`, so they only prove the tool echoes a path just handed to it; the resolved-default case — the `LEDGER=path &&` footgun at `tools/ledger.sh:29-33` — is asserted by no test, though the `led_default`/`selfhostrepo` fixture already exists (`:2024`). No test covers finding 1 |
| 4 | `info` | `tools/ledger.sh:704` | The absolute local ledger path now travels on stdout into artifacts the kit's templates say to paste — PR bodies (`templates/PULL_REQUEST_TEMPLATE.md:49`), gate reports, ledger `--note` text — disclosing checkout layout and often a username in a repo that ships to buyers |

## Ledger line

```
bash tools/ledger.sh add --change ledger-success-shows-destination --gate G7 --tier T4 --round 1 \
  --outcome fail --confidence fresh --challenged true --model opus --tokens <n> \
  --finding "minor::tools/ledger.sh:704::..." (x4, see table)
```

## Commit binding — OUTSTANDING

This round reviewed an **uncommitted working tree**; no sha exists to name, which the pre-push hook
greps for. When this change is committed (after the round-2 fix for finding 1), a binding addendum
must be appended here naming the real sha and itemizing every edit made after this review, following
`2026-09-15-ledger-token-split.md`'s "Commit binding" section. Until then this report proves things
about a working tree, not about a commit.

---

## Round 2

**Reviewed:** the **uncommitted working-tree diff on top of `4fd9929`** — the same base commit
round 1 named, still the tip. **No commit exists for this change at review time either**, so this
round still cannot name a sha for the thing it reviewed. Subject:
`git diff -- tools/ledger.sh tools/reconcile.sh tests/run.sh`, plus those three files as they sit
on disk. **The post-commit binding addendum round 1 declared OUTSTANDING is still outstanding** —
neither round has reviewed a commit.

Scope widened since round 1 by `tools/reconcile.sh` (**T4**, `surfaces.conf:27` — the same rule that
pins `ledger.sh`). Change tier is therefore still **T4**, and still a hard gate:
`passes_when: no unresolved finding above low`.

FRESH context: this session received the G7 card, `surfaces.conf`, the round-1 report, the diff and
the three files. `specs/ledger-success-shows-destination/requirements.md` was **withheld and never
opened**, and the change owner was not asked what they changed — everything in "What round 2
changes" below is derived from the diff alone.

### What round 2 changes

1. **The round-1 finding's claimed fix.** `emit()` (`tools/ledger.sh:295`) now checks both writes:
   `mkdir -p … || { REFUSED …; exit 3; }` at `:316`, and `printf … >> "$LEDGER" || { REFUSED …;
   exit 3; }` at `:320`. The append refusal explicitly warns that the append is not atomic and a
   truncated line may be sitting in the file.
2. **`emit()` restructured to own the success line.** It takes an optional second argument
   (`summary="${2:-}"`, `:296`) and prints `"$summary → $LEDGER"` itself at `:331`. The four call
   sites (`cmd_add:717`, `cmd_route:820`, `cmd_escape:843`, `cmd_assume:923`) no longer echo their
   own line; `cmd_route`'s two-branch if/else collapses into a `route_summary` variable built at
   `:818-819`.
3. **`tools/reconcile.sh:636`** stops discarding ledger.sh's stdout (`2>&1 >/dev/null` becomes
   `2>&1`) and prints the captured text under `(logged to ledger)` at `:642`.
4. **Three new tests** (`tests/run.sh:1658`, `:1669`, `:2065`).

---

### 1 · Is the round-1 finding fixed? — **Three of its four demonstrated shapes: yes, live-confirmed. The fourth is open.**

Re-run against the current tree, in a `mktemp -d` scratch repo — never this repo's ledger:

```
$ ledger.sh add --ledger /nonexistent-root-zz/deep/ledger.jsonl …
mkdir: cannot create directory '/nonexistent-root-zz': Permission denied
REFUSED: could not create the directory for /nonexistent-root-zz/deep/ledger.jsonl.
  Nothing was written.                                                        exit=3

$ ledger.sh add --ledger "$T/dirledger" …            # path is an existing directory
REFUSED: the write to /tmp/…/dirledger failed (disk full, permission denied, or the …)  exit=3

$ ledger.sh add --ledger '' …
REFUSED: the write to  failed (…)                                             exit=3
```

No `logged:` line on stdout in any of the three, exit 3 in all three, and stdout is **empty** — not
merely contradicted on stderr. That is a stronger fix than round 1 asked for: round 1's suggested
`||` clause would have left the success line reachable through a different ordering; placing the
print *inside* `emit()` after both checks makes it structurally unreachable on a failed write. The
`mkdir` failure gets its own distinct refusal rather than being folded into the append's.
**Round-1 finding 1 is closed for every write that returns an error.**

### 2 · The residue: a write that does not fail and stores nothing — **open, and not inherent**

`/dev/null` accepts the append, so `printf` returns 0 and `:331` prints a fully clean success line:

```
$ ledger.sh add --ledger /dev/null …
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /dev/null            exit=0, no stderr
```

Taken alone this is close to self-refuting — the line names `/dev/null`, and a reader who knows what
that is can see the claim collapse. **The variant that is not self-refuting is a symlink**, and it
was confirmed live:

```
$ ln -s /dev/null "$T/sym.jsonl"
$ ledger.sh add --ledger "$T/sym.jsonl" …
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /tmp/…/sym.jsonl     exit=0, no stderr
$ wc -c < "$T/sym.jsonl"  ->  0
```

A path that looks exactly right, a success line that names it, exit 0, no diagnostic on either
stream, and no record anywhere. Against the party round 1 put first in the threat model — a subagent
invoking `ledger.sh` to grade itself, with write access to the repo it is working in — this converts
evidence suppression from something that leaves a mark into something that leaves a *confirmation*.
This is `surfaces.conf:27` ("a wrong answer here is silent and confident") reached, again, by the
line added to prevent it.

**Is it fixable at this layer, or inherent to pointing a ledger at a null device?** Fixable, and in
one line. The current checks test whether the write *errored*; they never test what the destination
*is*. A regular-file check before the append — refuse when `$LEDGER` exists and is not a regular
file — closes `/dev/null`, a symlink to it, a FIFO, and every character device, and subsumes the
directory case `:320` currently catches by accident of `>>` failing. The refusal vocabulary and the
"Nothing was written" idiom are already on the two lines above it. What *is* inherent is a user who
deliberately types `--ledger /dev/null`; what is not inherent is the tool being unable to tell the
difference between a file and a void.

### 3 · The restructured success line — **no new injection; same class, wider blast radius**

Moving the print from four call sites into `emit()` **removes** three of the four places a future
editor could get the interpolation wrong, and adds no new expansion: `:331` is a double-quoted
argument to the `echo` builtin, exactly as the four call sites were. No word splitting, no globbing,
no format string, no second expansion round. Round 1's finding 2 therefore neither worsens nor
improves as a *class* — re-confirmed live:

```
$ ledger.sh add --ledger "$(printf '%s/real.jsonl\nlogged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass')" …
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /tmp/…/real.jsonl
logged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass                   exit=0
```

**Round 1's reasoning for rating this `info` still holds, and was re-tested rather than assumed:**
the identical forge is still available through `--change`, which this diff does not touch —

```
$ ledger.sh add --change "$(printf 'a\nlogged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass')" …
logged: G1 (Intent) on a
logged: G7 (Threat) on sneaky — round 1, 0 finding(s), pass — round 1, 0 finding(s), pass → …
```

— so this is still a channel into an existing class, not a new class. **What did change is reach.**
Before this diff `reconcile.sh` discarded `ledger.sh`'s stdout entirely, so the forge could not
appear in reconcile's output at all. It now can (`:642`), confirmed live:

```
(logged to ledger)
  logged: route mychange — round 1, predicted T1, actual T0 (over) → /tmp/…/rl.jsonl
RECONCILE: predicted T4, actual T4 (match)          <- injected via a newline in --ledger
```

The forged line lands in the R0b reconciliation artifact, at column 0, directly beneath the
indented real one. Still `info`, on round 1's reasoning; re-filed with the wider surface named.

### 4 · The combined `2>&1` capture in reconcile.sh — **no misattribution. Cleared on evidence, both directions.**

The concern is symmetric and both halves were tested:

- **Can a refusal be printed under `(logged to ledger)`?** Only if `ledger.sh route` printed
  `REFUSED` and exited 0. It cannot: every `>&2` inside `cmd_route` is immediately followed by
  `exit 2`, and `emit()`'s two new refusals `exit 3` *before* reaching `:331`.
- **Can a success line be printed under `RECONCILE NOT RECORDED`?** Only if `ledger.sh route`
  printed `logged:` and exited non-zero. It cannot, for the same structural reason — the print is
  the last thing `emit()` does and every failure path has already exited. Confirmed directly:

```
$ out=$(ledger.sh route --ledger "$T/dirledger" … 2>/dev/null); echo "stdout=[$out] rc=$?"
stdout=[] rc=3
```

  stdout is **empty** on the refusal, so the failure branch cannot carry a forged success even
  though it now captures stdout.

End-to-end through `reconcile.sh`, both branches are clean: success prints `(logged to ledger)` plus
exactly the one `logged: route …` line; the refused-destination run exits 2 with only the `REFUSED`
text under `RECONCILE NOT RECORDED`. `_route_rc` remains the sole branch discriminant and is
unaffected by the stream merge. **No finding.** One caveat recorded, not filed: the success branch
now prints *whatever* is on ledger.sh's stderr indented under `(logged to ledger)`, in the position
a reader will read as the destination. Nothing writes there on the success path today (verified),
but a future non-fatal warning would be displayed as if it were the write confirmation.

### 5 · New: a successful write can return 1 — **latent, unreachable today**

`:331` is `[ -n "$summary" ] && echo "$summary → $LEDGER"`, and it is the **last** command in
`emit()`. With no `set -e`, a caller that passes no summary gets `emit` returning **1 after a
successful append**. Confirmed live against a sourced copy of the functions:

```
$ emit '{"type":"gate"}'                 ->  emit_rc=1     (record written)
$ emit '{"type":"gate"}' 'logged: thing'
logged: thing → /tmp/…/x.jsonl           ->  emit_rc=0     (record written)
$ wc -l < "$LEDGER"  ->  2
```

Unreachable today — all four call sites pass a summary, and in `cmd_add`/`cmd_escape`/`cmd_assume`
`emit` is not the last statement anyway. It matters because `reconcile.sh:640` branches on
`_route_rc`, and `cmd_route`'s last statement **is** the `emit` call: a future subcommand (or a
refactor that drops `cmd_route`'s summary) would make reconcile print
`RECONCILE NOT RECORDED — the ledger write was refused` and `exit 2` for a record that was written.
That is the same false-confidence failure mode as round 1's finding, inverted. A trailing `return 0`,
or an `if` instead of `&&`, removes it. `info` — no hostile party reaches it; filed so a refactor
into it is visibly a regression rather than a tidy-up.

### 6 · Round-1 findings 3 and 4

- **Finding 3 (info, tests were fixture-tautological) — RESOLVED for the default-path half.**
  `tests/run.sh:2065` (`test_ledger_default_path_success_message_names_the_resolved_path`) uses
  `selfhostrepo` + `led_default`, passes no `--ledger` and no `LEDGER`, and asserts the line names
  `$SELFREPO/ledger.jsonl` — exactly the footgun case round 1 said no test reached, using exactly
  the fixture round 1 pointed at. **Re-filed narrower:** `:1658` and `:1669` cover only destinations
  whose write *errors*; nothing covers a destination that accepts the write and stores nothing, so
  the suite passes green against the §2 gap.
- **Finding 4 (info, absolute local path travels on stdout into pasted artifacts) — UNRESOLVED and
  widened.** The same path now also leaves through `reconcile.sh:642`, whose output is the R0b
  artifact the templates say to paste. Carried forward.

### 7 · Regression check

`bash tests/run.sh emit_refuses` → 6 passed, 0 failed, 0 skipped.
`bash tests/run.sh names_the` → 14 passed, 0 failed, 0 skipped. No new input is accepted by this
diff (zero new flags, zero new parsed values), so the refusal set, `json_escape`, the bare-JSON
positions and the structural newline backstop at `:309-310` are untouched — re-confirmed by reading
the diff. **Privilege growth: none.** Same single file, same `emit()`, no new file, network, process
or credential reach.

---

## Round 2 T4 boundary check

| Boundary (surfaces.conf) | Crossed? | Checked? |
|---|---|---|
| Caller-supplied path → filesystem write **errors** | Yes | **Yes — `:316` and `:320` both refuse, exit 3, stdout empty (§1)** |
| Caller-supplied path → filesystem write that **succeeds into a void** | Yes | **No — `/dev/null` and a symlink to it print a clean success line (§2)** |
| Caller-supplied path → stdout treated as gate evidence | Yes | **No — newline still forges (§3, `info`: channel, not class)** |
| Caller-supplied path → **reconcile.sh's R0b output** | **Yes — novel to round 2** | **No — same forge, new consumer (§3)** |
| `ledger.sh` exit status → `reconcile.sh`'s success/refusal branch | **Yes — novel to round 2** | Yes for every reachable path; **latent inversion at `:331` (§5)** |
| ledger.sh stdout+stderr merged → reconcile branch attribution | **Yes — novel to round 2** | Yes — no path prints a success on failure or a refusal on success (§4) |
| Untrusted CLI argument → bare JSON position | Yes | Yes — untouched by this diff (§7) |
| `ledger.jsonl` → `compliance` verdict path | No | Unaffected |
| `tests/run.sh` → what the suite still asserts | Yes | Partly — §6 |

**Privilege growth:** none.

---

## Round 2 verdict

**G7 · Threat (HARD GATE, T4): FAIL**, round 2.

`passes_when: no unresolved finding above low`. One `minor` (`tools/ledger.sh:320`) is above low.

This should not be read as "the fix did not work." It did, and better than round 1 asked: the print
moved *inside* `emit()`, behind both checks, so the success line is structurally unreachable on a
failed write rather than merely guarded — three of the four shapes round 1 demonstrated live are now
exit-3 refusals with an empty stdout. The restructure also **reduces** attack surface by collapsing
four hand-typed interpolations into one, and the `reconcile.sh` stream merge, which was the most
plausible place for this change to introduce a new confusion, is clean in both directions on live
evidence (§4).

What remains is that the fix checks whether the write *failed*, and the one destination class that
does not fail is the one that keeps nothing. `/dev/null` alone would be `info` — the line names it.
A symlink is not `info`: the path reads correctly, both streams are silent, the exit code is 0, and
the record is gone. That is the precise failure this change exists to prevent, still reachable by a
party already in the threat model, and closable by a regular-file test one line above the append.

Back to Build, then re-run G7 and G5 (§6: the suite has no destination-type case). Two consecutive
failures of one gate escalates the tier by one (`02-gates.md`, failure rule 4); this change is
already at T4, the ceiling, so the mechanical consequence is the T4 approver seeing both rounds —
which `escalate_to: T4 approver. NEVER the author alone` requires regardless.

Confidence: **fresh**.

**Premise challenged: yes.** Twice. The premise that round 1's finding was the whole finding was not
accepted: §2 asked what the new checks actually test (an error return, not a destination) and found
the class they cannot see. And the premise embedded in the review request — that `/dev/null` might be
"inherent to pointing a ledger at a null device" — was rejected on evidence: the symlink case shows
the user need not have typed `/dev/null` at all, and a regular-file check closes it at this layer.
The three new tests were read for what they exercise rather than what they are named, which produced
§6; and §5 was found by asking what the restructure does to `emit()`'s *return value*, which no
round-1 finding pointed at.

---

## Round 2 structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `minor` | `tools/ledger.sh:320` | The new checks detect a write that **errors**, never a destination that accepts the write and stores nothing. `--ledger /dev/null`, and — not self-refuting — a symlink named `ledger.jsonl` pointing at it, both print `logged: … pass → <path>` with exit 0, empty stderr, and zero bytes stored (live-confirmed). Fixable here: refuse when `$LEDGER` exists and is not a regular file, which also subsumes the directory case |
| 2 | `info` | `tools/reconcile.sh:642` | `$LEDGER` reaches stdout verbatim (round-1 finding 2, unchanged and still `info` because `--change` offers the same forge — re-verified live), but now also travels into `reconcile.sh`'s R0b output, which previously discarded ledger.sh's stdout entirely. Same class, new consumer |
| 3 | `info` | `tools/ledger.sh:331` | `[ -n "$summary" ] && echo …` is `emit()`'s last command, so a summary-less call returns **1 after a successful append** (live: `emit_rc=1`, record written). Unreachable today; `cmd_route` ends with `emit` and `reconcile.sh:640` branches on its rc, so a refactor lands `RECONCILE NOT RECORDED` on a successful write |
| 4 | `info` | `tests/run.sh:1658` | `:1658`/`:1669` cover only destinations whose write errors; no test covers a destination that accepts the write and keeps nothing, so the suite is green against finding 1. (Round-1 finding 3's default-path half is **resolved** by `:2065`) |
| 5 | `info` | `tools/reconcile.sh:642` | Round-1 finding 4 unresolved and widened: the absolute local ledger path — checkout layout, often a username — now also leaves through reconcile.sh's output, the artifact the templates instruct callers to paste into PR bodies |

## Round 2 ledger line

```
bash tools/ledger.sh add --change ledger-success-shows-destination --gate G7 --tier T4 --round 2 \
  --outcome fail --confidence fresh --challenged true --model opus --tokens <n> \
  --finding "minor::tools/ledger.sh:320::..." (x5, see table)
```

## Commit binding — STILL OUTSTANDING

Round 2 reviewed an **uncommitted working tree** on top of `4fd9929`, exactly as round 1 did. No sha
exists for this change, which is what the pre-push hook greps for. When it lands, a binding addendum
must be appended here naming the real sha and itemizing every edit made after this round, following
`2026-09-15-ledger-token-split.md`'s "Commit binding" section. Until then this report proves things
about a working tree, not about a commit.

---

## Round 3

**Reviewed:** the **uncommitted working tree** on top of `4fd9929` ("auto: regenerate
dashboard.html (pre-push)"), still the tip. **No commit exists for this change at review time**, so
this round, like rounds 1 and 2, **cannot name a sha for the thing it reviewed**. Subject:
`git diff -- tools/ledger.sh tools/reconcile.sh tests/run.sh` plus those three files on disk.
**The post-commit binding addendum declared OUTSTANDING in round 1 and STILL OUTSTANDING in round 2
remains outstanding** — no round has yet reviewed a commit.

Tiers unchanged: `tools/ledger.sh` and `tools/reconcile.sh` are both **T4** (`surfaces.conf:27`),
`tests/run.sh` is T3 (`:50`). Change tier **T4**, hard gate, `passes_when: no unresolved finding
above low`.

FRESH context: this session received the G7 card, `surfaces.conf`, the diff, `git status`, and this
report's rounds 1-2. `specs/ledger-success-shows-destination/requirements.md` was **withheld and
never opened**. All live evidence below comes from a `mktemp -d` scratch repo holding a **copy** of
`tools/` (`git init`, a real commit); this repo's `ledger.jsonl` was not written to by any probe —
only by this round's own final `ledger.sh add`.

### What changed since round 2

1. `tools/ledger.sh:325` — a destination-type check, after the `mkdir` check and before the append:
   `[ -e "$LEDGER" ] && [ ! -f "$LEDGER" ] && { REFUSED …; exit 3; }`.
2. `tools/ledger.sh:347` — `[ -n "$summary" ] && echo …` became `if [ -n "$summary" ]; then echo …; fi`.
3. Two new tests: `tests/run.sh:1685` (`…_ledger_is_not_a_regular_file`) and `:1701`
   (`…no_summary_still_reports_success_after_a_real_write`).

---

### 1 · Round-2 finding 1 (`minor`, destination that succeeds and stores nothing) — **CLOSED, live-confirmed**

Every shape round 2 demonstrated, and the two it named but did not run, now refuse with **exit 3 and
an empty stdout**:

```
$ ledger.sh add --ledger /dev/null …
REFUSED: /dev/null exists and is not a regular file (a device, FIFO, or
  symlink to one would silently discard every record written to it).
  Nothing was written.                                                stdout=[]  rc=3

$ ln -s /dev/null "$S/sym.jsonl"; ledger.sh add --ledger "$S/sym.jsonl" …
REFUSED: /tmp/…/sym.jsonl exists and is not a regular file (…)        stdout=[]  rc=3

$ mkfifo "$S/fifo.jsonl";        ledger.sh add --ledger "$S/fifo.jsonl" …
REFUSED: /tmp/…/fifo.jsonl exists and is not a regular file (…)       stdout=[]  rc=3
```

The symlink case is the one round 2 rated `minor` — the path reads correctly, both streams were
silent, exit was 0, the record was gone. It is now a refusal on the same evidence standard. `-f`
follows symlinks, so the single predicate covers the device, the symlink to it, and the FIFO.

**It does not refuse legitimate everyday use** — checked in both directions rather than assumed,
because a check that refuses valid input is the failure mode `LEARNINGS.md` warns about:

| Everyday shape | Result |
|---|---|
| Fresh path, parent exists (`$S/fresh.jsonl`) | `logged: … pass → /tmp/…/fresh.jsonl`, rc 0, 1 line on disk |
| Fresh path, parent must be created (`$S/deep/er/nested.jsonl`) | rc 0, directory created, 1 line on disk |
| Existing plain regular file, appended twice more | rc 0 each time, file grows 1 → 2 → 3 lines, all three records readable |
| Symlink to a **regular** file | rc 0, write goes through (correctly not refused) |

`[ -e ]` is false for a path that does not exist, so the guard is a no-op on the fresh-file path and
the append creates the file exactly as before.

**The plain-directory case is now caught earlier, by the new check rather than by the append
failing** — same REFUSED, same exit 3, different text:

```
$ ledger.sh add --ledger "$S/dirledger" …
REFUSED: /tmp/…/dirledger exists and is not a regular file (…)        stdout=[]  rc=3
```

Round 2 saw `REFUSED: the write to … failed (disk full, permission denied, …)` here. Both refuse, so
`test_emit_refuses_when_the_ledger_path_is_a_directory` (`tests/run.sh:1658`, which asserts only
exit 3 and the string `REFUSED`) still passes — and that is the seam behind finding 1 below. The
paths that still reach the append guard at `:330` were re-run and still refuse: a read-only regular
file (`Permission denied` → exit 3) and an empty `--ledger ''` (exit 3). The `mkdir` guard at `:316`
still refuses an uncreatable parent (exit 3).

### 2 · Round-2 finding 3 (`info`, a successful write returning 1) — **CLOSED, live-confirmed**

Against a sourced copy of the functions, in the scratch repo:

```
$ emit '{"type":"gate"}'                            -> emit_rc=0   (1 line written)
$ emit '{"type":"gate"}'                            -> emit_rc=0   (2 lines written)
$ emit '{"type":"gate"}' ''                         -> emit_rc=0   (explicit empty summary)
$ emit '{"type":"gate"}' 'logged: thing'
logged: thing → /tmp/…/rc1.jsonl                    -> emit_rc=0
$ ledger.sh route --change r --predicted T1 --actual T1 …
logged: route r — round 1, predicted T1, actual T1 (match) → /tmp/…/rt.jsonl   rc=0
```

`cmd_route`'s own exit code is `emit()`'s, and it is 0 on the reachable path today and on the
summary-less path that was the latent inversion. The round-2 scenario — `reconcile.sh:640`
branching on `_route_rc` and printing `RECONCILE NOT RECORDED` for a record that landed — is gone.

### 3 · Does either fix introduce anything new? — **Three `info`, nothing above low**

**a. The directory test now guards the wrong branch, leaving `:330` unpinned.** Proved by
deleting the append-failure guard at `:330` in a scratch copy and re-running the two shapes:

```
# with the `|| { REFUSED …; exit 3; }` at :330 REMOVED
$ ledger.sh add --ledger "$S/dir2" …          REFUSED: … is not a regular file    rc=3   <- test still green
$ ledger.sh add --ledger "$S/ro2.jsonl" …     (read-only file; stderr: Permission denied)
logged: G1 (Intent) on c — round 1, 0 finding(s), pass → /tmp/…/ro2.jsonl        rc=0   <- round-1 finding, back
```

No test reaches the append guard any more: `grep -n 'test_emit' tests/run.sh` lists five — `:1642`
(non-JSON), `:1658` (directory → now `:325`), `:1669` (mkdir → `:316`), `:1685` (/dev/null → `:325`),
`:1701` (success) — and no test uses `chmod` on a ledger or an empty `--ledger`. So round 2's own
append-failure refusal — the fix for round 1's finding — could be deleted today and the suite would
stay green, while a full disk, a permission denial, or an empty path silently returns to printing a
confident false destination with exit 0. `info`: the guard is present and works (§1); what regressed
is the evidence that it keeps working.

**b. Check-then-write.** `:325` stats the destination and `:330` writes to it; a party with
concurrent write access to the ledger's directory can swap a regular file for a symlink to
`/dev/null` in between and restore the round-2 outcome. `info`, not `minor`: the ledger carries no
hash chain or record integrity (`grep -n 'sha256|checksum|tamper' tools/ledger.sh` → nothing), so
the same party can rewrite or delete the record after it lands, and no check at this layer changes
that. The guard's guarantee is against misconfiguration and accident, which is what round 2 asked
for; it is not, and cannot be, an anti-tamper control.

**c. `LEDGER=/dev/null` is now a hard failure, not a silent no-op.** Round 1 named
"`LEDGER=/dev/null` to turn off logging" as a plausible CI or container shape. That invocation now
exits 3 and refuses. This is the right direction — the whole point is that a ledger pointed at a
void is not logging — but it is a **behavior break for an installed copy**, and it belongs in the
release note, not only in a refusal message. Nothing inside the kit does it (a grep for
`--ledger /dev`, `LEDGER=/dev` and `LEDGER_PATH=/dev` across `tools/ tests/ templates/ core/`
returns no matches), so no internal caller breaks. `info`.

**Recorded, not filed:** the refusal text explains itself with "a device, FIFO, or symlink to one",
which does not describe the plain-directory case it now also catches. Accurate in its first clause
(`exists and is not a regular file`), imprecise in its parenthetical.

### 4 · Carried forward, re-verified live, unchanged

- **Newline forgery through `--ledger`** (round 1 finding 2 / round 2 finding 2) — still open, still
  `info` on the original reasoning, because the identical forge is still available through
  `--change`, which no round has touched. Both re-run this round; both still print a second
  fully-formed `logged: G7 (Threat) on sneaky … pass` line at exit 0. A path-only sanitization would
  still be incomplete.
- **Absolute local ledger path on stdout and through `reconcile.sh:642`** (round 1 finding 4 / round 2
  finding 5) — unresolved, `info`, carried.

### 5 · Regression check

`bash tests/run.sh emit` → 14 passed, 0 failed. `bash tests/run.sh names_the` → 14 passed, 0 failed.
`bash tests/run.sh ledger_default` → 10 passed, 0 failed. `bash tests/run.sh reconcile` → 58 passed,
0 failed. `reconcile.sh` re-run end to end in the scratch repo, both branches:

```
$ CHANGE=mychange reconcile.sh T2 --log --ledger "$S/rl.jsonl"
(logged to ledger)
  logged: route mychange — round 1, predicted T2, actual T4 (under) → /tmp/…/rl.jsonl     (1 line on disk)

$ CHANGE=mychange reconcile.sh T2 --log --ledger /dev/null            rc=2
RECONCILE NOT RECORDED — the ledger write was refused:                                    [stderr]
  REFUSED: /dev/null exists and is not a regular file (…)
```

The stream-merge attribution round 2 cleared still holds with a third refusal source added: the new
`exit 3` happens before `:347`, so stdout is empty on the refusal and the success branch cannot
carry it. `emit()` remains the only writer of `$LEDGER` (a grep for an append redirection into
`$LEDGER` across `tools/` returns exactly one hit, `:330`), and all four call sites pass a summary.
**Privilege growth: none** — the diff only adds a refusal; no new file, network, process, or
credential reach. No new input is accepted: zero new flags, zero new parsed values.

---

## Round 3 T4 boundary check

| Boundary (surfaces.conf) | Crossed? | Checked? |
|---|---|---|
| Caller-supplied path → filesystem write **errors** | Yes | Yes — `:316`/`:330` refuse, exit 3, stdout empty |
| Caller-supplied path → write that **succeeds into a void** | Yes | **Yes — `:325` refuses device, symlink-to-device, FIFO, directory (§1)** |
| Caller-supplied path → ordinary destinations (new path, existing file) | Yes | **Yes — not over-refused; all four everyday shapes still exit 0 and store the record (§1)** |
| `emit()` return value → `cmd_route` → `reconcile.sh`'s branch | Yes | **Yes — summary-less success now returns 0 (§2)** |
| Destination type at check time → destination at write time | Yes | No — check-then-write race; `info`, bounded by the absence of any record integrity (§3b) |
| Append-failure guard → the suite that protects it | Yes | **No — no test reaches `:330` any more (§3a)** |
| Caller-supplied path → stdout treated as gate evidence | Yes | No — newline still forges; `info`, channel not class (§4) |
| Untrusted CLI argument → bare JSON position | Yes | Yes — untouched by this diff (§5) |
| `ledger.jsonl` → `compliance` verdict path | No | Unaffected |

**Privilege growth:** none.

---

## Round 3 verdict

**G7 · Threat (HARD GATE, T4): PASS**, round 3.

`passes_when: no unresolved finding above low`. Nothing `blocking`, nothing `minor` — the two
round-2 findings are closed on live evidence, and the three new observations are all `info`.

Both fixes are the shape round 2 asked for and one step better. The destination check is a single
type predicate rather than a special case for `/dev/null`, so it closed the device, the symlink, the
FIFO and the directory at once; and placing it after the `mkdir` guard and before the append means
the three refusals form an ordered sequence in which no success line is reachable from any failure.
The `if` is a strictly smaller construct than the `&&` it replaced and removes the one way `emit()`
could report a good write as a bad one.

What keeps this from being a clean sweep is §3a: the new check quietly inherited the coverage of
the test written for the old one, so the round-2 append guard is now protected by nothing. That is
`info` because the guard works today — but it is exactly the shape of regression this file is pinned
at T4 for, and the next person to "simplify" `:330` will not be told.

Confidence: **fresh**. **Premise challenged: yes.** The request's framing — verify the two fixes —
was not treated as the whole job: the fixes were tested for **over-refusal** as well as
under-refusal (§1, four everyday shapes), the claim that the directory case is "subsumed" by the new
check was taken literally and traced to what the suite now proves rather than what it is named
(§3a, confirmed by deleting the guard and watching the tests stay green), and the new refusal was
asked what it *breaks* as well as what it closes (§3c).

---

## Round 3 structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `info` | `tests/run.sh:1658` | `:325` now intercepts the directory case, so `test_emit_refuses_when_the_ledger_path_is_a_directory` passes without reaching the append guard at `tools/ledger.sh:330`, and no other test does (no `chmod`ed ledger, no empty `--ledger`). Live-proved: with `:330`'s guard deleted, the directory case still exits 3 while a read-only ledger reprints `logged: … pass → <path>` at exit 0 — round-1's finding, unpinned |
| 2 | `info` | `tools/ledger.sh:325` | Check-then-write: the type test and the append are separate syscalls, so a party with concurrent write access to the ledger's directory can restore the round-2 symlink outcome in between. Not `minor` — the ledger has no record integrity at all, so that party can rewrite the record after it lands; the guard is an anti-misconfiguration control, not anti-tamper |
| 3 | `info` | `tools/ledger.sh:325` | `LEDGER=/dev/null` — named in round 1 as a plausible CI/container "turn logging off" idiom — is now exit 3 rather than a silent no-op. Correct direction, but a behavior break for an installed copy that needs a release note; no in-kit caller does it (grep clean) |
| 4 | `info` | `tools/ledger.sh:347` | Round 1 finding 2 / round 2 finding 2, carried and re-verified live: a newline in `$LEDGER` still prints a second fully-formed `logged: … pass` line at exit 0, as does one in `--change`. Same class, both channels open; a path-only fix would be incomplete |
| 5 | `info` | `tools/reconcile.sh:642` | Round 1 finding 4 / round 2 finding 5, carried: the absolute local ledger path — checkout layout, often a username — travels on stdout and through reconcile.sh's R0b output into artifacts the templates say to paste |

## Round 3 ledger line

```
bash tools/ledger.sh add --change ledger-success-shows-destination --gate G7 --tier T4 --round 3 \
  --outcome pass --confidence fresh --challenged true --model opus --tokens <n> \
  --finding "info::tests/run.sh:1658::..." (x5, see table)
```

## Commit binding — STILL OUTSTANDING

Round 3 reviewed an **uncommitted working tree** on top of `4fd9929`, exactly as rounds 1 and 2 did.
**No commit sha exists for this change**, which is what the pre-push hook greps for. This PASS is a
pass on a working tree, not on a commit. When the change lands, a binding addendum must be appended
here naming the real sha and itemizing every edit made after this round, following
`2026-09-15-ledger-token-split.md`'s "Commit binding" section — and if any edit to
`tools/ledger.sh`, `tools/reconcile.sh` or `tests/run.sh` is made between this round and that
commit, this gate must be re-run, not merely bound.

---

## Round 4 — and the commit binding rounds 1-3 declared OUTSTANDING

**Reviewed: commit `470c3539fb34c12e6a2d87cc2d0409a4fa916438` (`470c353`), on `master`**, whose parent
is `4fd9929` — the base every prior round reviewed a working tree on top of. This is the first round
of this gate to review **a commit rather than an uncommitted working tree**, so this section is also
the binding addendum round 1 opened and rounds 2 and 3 carried. `git status` was clean at review
time; the subject is `git show 470c353 -- tools/ledger.sh tools/reconcile.sh tests/run.sh`, i.e. the
whole change against `4fd9929`, re-walked rather than assumed from rounds 1-3.

Round 3 passed and then stated the condition on its own pass: *"if any edit to `tools/ledger.sh`,
`tools/reconcile.sh` or `tests/run.sh` is made between this round and that commit, this gate must be
re-run, not merely bound."* Edits were made. This round is that re-run, not a binding stamp.

Tiers unchanged (`project/surfaces.conf`, `SELF: gated-change` at `:3` — this repo's own boundaries):
`tools/ledger.sh` and `tools/reconcile.sh` **T4** (`:27`), `tests/run.sh` T3 (`:50`). Change tier
**T4**, hard gate, `passes_when: no unresolved finding above low`.

FRESH context: this session received the G7 card, `surfaces.conf`, this report's rounds 1-3, and the
commit. `specs/ledger-success-shows-destination/requirements.md` was **withheld and never opened**,
and the change owner was not asked what they changed. The commit touches six files; the other three
are `ledger.jsonl` (10 added lines, all well-formed record lines, no code), this report, and the
withheld requirements file. All live evidence below is from `git worktree` / `mktemp -d` scratch
copies; this repo's own `ledger.jsonl` was written only by this round's final `ledger.sh add`.

### What changed since round 3 — each verified to be what it claims, none of it material

Four edits landed after round 3's pass (three from a fresh-context G6 Peer round 2, one from the
change owner). Each was checked against the question this gate asks — *is anything reachable by a
hostile input, a hostile caller, or a confused user different from what round 3 walked?* — rather
than against its description.

| # | Edit | What it actually is | Reachability delta |
|---|---|---|---|
| 1 | `tests/run.sh:1712-1731` — new `test_emit_refuses_when_the_ledger_file_is_not_writable` | Test addition. A `chmod 444` **regular** file as `$LEDGER`, which passes the `-f` guard at `ledger.sh:325` and fails only at the append | **None** — test-only. Closes round-3 finding 1 (§1) |
| 2 | `tools/ledger.sh:326-330` — non-regular-file REFUSED reworded | Message text only. The predicate `[ -e "$LEDGER" ] && [ ! -f "$LEDGER" ]`, the stream (`>&2`) and `exit 3` are byte-identical to round 3; 3 stderr lines became 5 | **None** (§2) |
| 3 | `tools/reconcile.sh:636,642,646` — `_route_err` → `_route_out` | Pure rename, 3 sites, no stale reference anywhere in `tools/ tests/ templates/ core/`. `_route_rc=$?` still on the line after the assignment; the failure branch's `${_route_out:-…}` default is intact | **None** (§3) |
| 4 | `tests/run.sh:3396` — route-with-action assertion strengthened | Test strengthening: adds `assert_contains "action 'store-publish' → $(ledger_path)"`, pinning content **and** ordering | **None** — test-only (§4) |

No edit adds a flag, accepts a value, changes a predicate, changes an exit code, or moves a check
relative to the write. The guard sequence round 3 walked — `mkdir` (`:316`) → non-regular-file
(`:325`) → append (`:332`) → success line (`:349`) — is unchanged in order and in logic.

### 1 · Edit 1 genuinely pins the append guard — round-3 finding 1 **CLOSED** on mutation evidence

Round 3's finding was not "there is no such test", it was "the guard could be deleted and the suite
would stay green", proved by deleting it. The same standard was applied here rather than reading the
new test's name. In a detached `git worktree` at `470c353`, the append-failure guard (now
`:332-337`) was deleted and the `emit` subset re-run:

```
# with the `|| { REFUSED …; exit 3; }` after the printf REMOVED
FAIL  test_emit_refuses_when_the_ledger_file_is_not_writable
      expected exit 3, got 0 (a read-only ledger file must be refused, …)
      …ledger.sh: line 332: …/ledger-readonly.dDh5K4: Permission denied
FAIL  test_emit_refuses_when_the_ledger_file_is_not_writable
      expected output to contain: REFUSED
passed 14 · failed 2 · skipped 0
```

Unmutated, the same subset is `passed 16 · failed 0`. The guard is now pinned by exactly one test,
and that test goes red when it is removed. The premise the test rests on was checked separately
rather than assumed, because it is platform-dependent: on this repo's declared primary TARGET
(`surfaces.conf:74`, Git Bash on Windows/NTFS) `chmod 444` does block the append —
`printf … >> ro.jsonl` gives `Permission denied` and the file stays 1 line — and `[ -f ]` is **true**
for it, so the `:325` guard correctly does not intercept and the test reaches `:332`. That is the
branch round 3 said nothing reached. See finding 1 for where the premise does not hold.

### 2 · Edit 2 is message text, and the message is now accurate — no behavioral delta

Every destination class round 3 walked was re-run against the committed code. Identical outcomes:

| Destination | rc | stdout | vs round 3 |
|---|:--:|---|---|
| `/dev/null` | 3 | empty | same |
| plain directory | 3 | empty | same |
| symlink → `/dev/null` | 3 | empty | same |
| read-only regular file | 3 | empty | same |
| empty `--ledger ''` | 3 | empty | same |
| uncreatable parent | 3 | empty | same |
| fresh path · fresh nested path · existing regular file · symlink → **regular** file | 0 | `logged: … → <path>` | same, record stored (file grew 1 → 2) |

Not over-refused, not under-refused, in either direction. What the reword fixes is the defect round 3
itself recorded-but-did-not-file: the old parenthetical said "a device, FIFO, or symlink to one would
silently discard every record", which did not describe the plain-directory case the same predicate
catches. It now does, and separates the benign case from the dangerous one:

```
REFUSED: …/adir exists and is not a regular file (a directory, a device,
  a FIFO, or a symlink to one). A mistyped --ledger pointing at a directory
  is the common case; a device or FIFO is the dangerous one, because it
  accepts the append and silently discards every record written to it.
  Nothing was written.
```

No new value is interpolated — `$LEDGER` was already in line 1, and every line is a double-quoted
`echo` to stderr, so there is no new expansion and no new reflection channel. No consumer asserts the
old wording (a grep for it across the repo returns only this report's own round-3 quotation), and the
two tests that reach this branch assert `REFUSED`, not the sentence.

### 3 · Edit 3 is semantically inert — both reconcile branches re-verified end to end

The rename is the one edit that could have been quietly load-bearing, because `_route_rc=$?` reads
the exit status of the very command whose assignment was renamed, and the failure branch depends on
the variable's `:-` default. Both were exercised live in a scratch repo rather than reasoned about:

```
$ CHANGE=mychange reconcile.sh T2 --log --ledger "$T/rl.jsonl"
(logged to ledger)
  logged: route mychange — round 1, predicted T2, actual T0 (over) → /tmp/…/rl.jsonl   (1 record on disk)

$ CHANGE=mychange reconcile.sh T2 --log --ledger /dev/null                              rc=2
RECONCILE NOT RECORDED — the ledger write was refused:                                  [stderr]
  REFUSED: /dev/null exists and is not a regular file (a directory, a device,
    a FIFO, or a symlink to one). …
```

Zero `logged:` lines on stdout in the refusal branch; the full five-line reworded refusal is carried
and indented correctly by the `printf | sed 's/^/  /'` path. The stream-merge attribution round 2
cleared and round 3 re-cleared still holds with the longer message: `exit 3` happens before `:349`,
so stdout is empty on every refusal and the success branch cannot carry one. Both shells are
`set -uo pipefail` (no `-e`), and `${_route_out:-…}` is `set -u`-safe regardless.

### 4 · Edit 4 pins a branch that was previously unpinned — also mutation-verified

`cmd_route`'s `[ -n "$action" ] && route_summary="$route_summary, action '$action'"` (`:837`) was
deleted in the worktree:

```
FAIL  test_route_with_action_success_message_names_the_ledger_path
      expected output to contain: action 'store-publish' → …/ledger.jsonl
      output was: logged: route r — round 1, predicted T4, actual T4 (match) → …/ledger.jsonl
passed 43 · failed 1
```

Before this edit both route tests asserted only the path, so that branch could be deleted silently.
This is the same class of gap as round 3's §3a, and it is now closed too. `[ -n "$action" ] && …` is
mid-function, not `emit()`'s last statement, so it cannot invert a return code the way round 2's
finding 3 did — checked, not assumed.

### 5 · Carried forward, re-verified live this round

- **Newline forgery through caller-supplied bytes** (round 1 f2 / round 2 f2 / round 3 f4) — still
  open, still `info` on the original reasoning. Re-run: a `\n` in `--ledger` still prints a second
  fully-formed `logged: G7 (Threat) on sneaky … pass` line at exit 0, and the identical forge through
  unvalidated `--change` still works. **New this round, in the same class:** `--action` is a *third*
  channel — it has no charset validation in `ledger.sh` (only the paired-with-`--evidence` rule at
  `:803-808`) and reaches `route_summary` verbatim. Live-confirmed. The *record* stays well-formed in
  all three (`json_escape` turns the newline into `\n`; `emit()`'s structural newline backstop at
  `:310` is untouched), so this remains terminal-message forgery, not ledger corruption. Reachable
  only by calling `ledger.sh` directly: through `reconcile.sh`, `ACTION_NAME` must match a declared
  `ACTION::` row in `surfaces.conf` (`:274-290`) or the run is refused. Filed so that a future
  "sanitize the path" fix is visibly incomplete if it leaves `--change` and `--action` alone.
- **Check-then-write race at `:325`** (round 3 f2) — unchanged, still `info`, still bounded by the
  ledger having no record integrity at all.
- **`LEDGER=/dev/null` is a behavior break needing a release note** (round 3 f3) — unchanged. The
  reword improves the *discoverability* half (the refusal now explains the directory case too) but
  not the release-note half.
- **Absolute local ledger path on stdout and through `reconcile.sh:642`** (round 1 f4 / round 2 f5 /
  round 3 f5) — unresolved, `info`, carried.

### 6 · Regression check, and 7a continuous checks on the commit

Full suite on the committed tree: **`passed 868 · failed 0 · skipped 0`**. Targeted subsets, covering
every function this commit touches: `emit` 16/0/0 · `names_the` 15/0/0 · `ledger_default` 10/0/0 ·
`reconcile` 58/0/0 · `route_` 44/0/0 · `success_message` 13/0/0.

*Recorded, not filed:* the commit message states "Full suite: 867/0/0"; the committed tree yields
**868**. Almost certainly the count was written before the last test landed (edit 1 is the
after-the-fact addition). Not a security matter, and the suite is green either way — noted only
because the number in a commit message is the kind of evidence a later reader takes at face value.

Secret scan over the whole diff: clean. Dangerous-sink grep over the added lines in `tools/` and
`tests/` (`eval`, `curl`/`wget`, `rm -rf`, `sudo`, `chmod 7xx`, unquoted command substitution): no
hits. **Permission/capability diff: none** — no new file, network, process or credential reach; the
same single file is written through the same `emit()`, which a grep confirms is still the only append
into `$LEDGER`. `ledger.jsonl`'s 10 added lines are all record lines, no code.

---

## Round 4 T4 boundary check

| Boundary (surfaces.conf) | Crossed? | Checked? |
|---|---|---|
| Caller-supplied path → write that **errors** | Yes | Yes — `:316`/`:332` refuse, exit 3, stdout empty; **`:332` now pinned by a test that goes red when it is deleted (§1)** |
| Caller-supplied path → write that **succeeds into a void** | Yes | Yes — `:325` refuses device, symlink-to-device, FIFO, directory; predicate byte-identical to round 3 (§2) |
| Caller-supplied path → ordinary destinations | Yes | Yes — not over-refused; all four everyday shapes exit 0 and store the record (§2) |
| `emit()` return value → `cmd_route` → `reconcile.sh`'s branch | Yes | Yes — unchanged; the renamed variable does not carry it, `_route_rc=$?` does (§3) |
| ledger.sh stdout+stderr → reconcile branch attribution | Yes | Yes — re-verified with the longer refusal; no success on failure, no refusal on success (§3) |
| Caller-supplied bytes → stdout treated as gate evidence | Yes | No — `--ledger`, `--change` and now `--action` all forge; `info`, one class, three channels (§5) |
| Destination type at check time → at write time | Yes | No — check-then-write race; `info`, unchanged (§5) |
| Untrusted CLI argument → bare JSON position | Yes | Yes — untouched by every edit in this commit (§6) |
| `ledger.jsonl` → `compliance` verdict path | No | Unaffected |
| Append-failure guard → the suite that protects it | Yes | **Yes — round-3 finding 1 closed (§1)**, with one environment caveat (finding 1 below) |

**Privilege growth:** none.

---

## Round 4 verdict

**G7 · Threat (HARD GATE, T4): PASS**, round 4, on commit **`470c353`**.

`passes_when: no unresolved finding above low`. Nothing `blocking`, nothing `minor`.

All four post-round-3 edits are exactly what they claim to be, and none is material to this gate: two
are test-only, one is stderr prose, one is a rename with no stale reference and no effect on the exit
status the caller branches on. Nothing reachable by a hostile input, a hostile caller, or a confused
user differs from what round 3 walked — re-established by re-running every destination class rather
than by comparing descriptions.

Two of the four do real work for this gate's own concerns. Edit 1 closes round-3 finding 1, and it
closes it to round 3's own standard: deleting the append guard now turns the suite red, proved by
doing it. Edit 4 closes the same shape of gap on `cmd_route`'s action branch. Edit 2 fixes the
imprecision round 3 recorded but did not file. That is three of round 3's five observations answered
by edits made after it, which is the pattern a gate chain is supposed to produce.

The single new finding is the one place edit 1's premise is environment-dependent: `chmod 444` does
not stop a root process, so on a root CI container the new test fails loudly rather than passing — a
false red, not a false green, which is why it is `info`. It matters only because the obvious response
to a spuriously red test is to weaken it, and weakening this one restores round-3 §3a exactly.

Confidence: **fresh**. **Premise challenged: yes.** The request's framing — that four edits are
"non-material, verify and bind" — was not accepted as the conclusion. Each was re-derived from the
commit: the rename was checked for stale references and for whether `_route_rc` reads the renamed
assignment; the reword was checked against every destination class and against whether any consumer
asserts the old text; and both test edits were **mutation-tested** rather than read, on the principle
round 3 established that a test's name is not evidence it pins anything. That mutation pass is also
what produced finding 1 — asking what makes the new test's `chmod 444` *work* is what exposed where
it does not. The prior rounds' "same class, not a new class" rating for the forgery channel was
re-tested rather than inherited, which turned up `--action` as a third channel nobody had named.

---

## Round 4 structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `info` | `tests/run.sh:1724` | `test_emit_refuses_when_the_ledger_file_is_not_writable` manufactures unwritability with `chmod 444`, which a root process bypasses (POSIX appropriate-privileges; reasoned, not executed — no root available in this session). On a root CI container the append succeeds and the test fails `expected exit 3, got 0` — loud, not silent, hence `info`. But it is the **only** test that reaches the append guard at `tools/ledger.sh:332` (§1), so the likely response to a spurious red — delete or weaken it — restores round-3 §3a. The suite has an established `_skip` idiom with environment guards (15+ uses: python, shasum, cygpath, node); this test has none |
| 2 | `info` | `tools/ledger.sh:837` | Forgery channel, same class as round 1 f2 / round 2 f2 / round 3 f4, **third channel named**: `--action` has no charset validation (only the paired-`--evidence` rule at `:803-808`) and reaches the success line verbatim, so a `\n` in it prints a forged `logged: …` line at exit 0 — live-confirmed, alongside the still-open `--ledger` and `--change` channels. The record stays well-formed (`json_escape`, plus the `:310` backstop); this is terminal-message forgery only. Not reachable through `reconcile.sh`, which requires `ACTION_NAME` to match a declared `ACTION::` row (`:274-290`) |
| 3 | `info` | `tools/ledger.sh:325` | Round 3 finding 2, carried unchanged: check-then-write — `:325` stats the destination and `:332` writes to it, so a party with concurrent write access to the ledger's directory can swap in a symlink between them. Bounded, as round 3 said, by the ledger having no record integrity at all |
| 4 | `info` | `tools/ledger.sh:326` | Round 3 finding 3, carried: `LEDGER=/dev/null` is exit 3 rather than a silent no-op — a behavior break for an installed copy that belongs in the release note. The reword improves the refusal's self-explanation but does not substitute for the note. No in-kit caller does it (grep clean) |
| 5 | `info` | `tools/reconcile.sh:642` | Round 1 f4 / round 2 f5 / round 3 f5, carried: the absolute local ledger path — checkout layout, often a username — travels on stdout and through reconcile.sh's R0b output into artifacts the templates instruct callers to paste into PR bodies |

**Recorded, not filed:** the five `emit` tests that source `ledger.sh`'s function half via
`sed '/^case "${1:-}"/,$d'` print `lib/matrix.sh: No such file or directory` and
`resolve_default_branch: command not found` into every captured output. Pre-existing, unchanged by
this commit, and harmless to what those tests assert (`$LEDGER` is set explicitly and the noise
contains no `REFUSED`), but it is noise in the one place a future reader looks for a real diagnostic.

## Round 4 ledger line

```
bash tools/ledger.sh add --change ledger-success-shows-destination --gate G7 --tier T4 --round 4 \
  --commit 470c353 --outcome pass --confidence fresh --challenged true --model opus --tokens <n> \
  --finding "info::tests/run.sh:1724::..." (x5, see table)
```

## Commit binding — CLOSED

Rounds 1, 2 and 3 each reviewed an uncommitted working tree on top of `4fd9929` and each declared the
binding OUTSTANDING. **This round reviewed commit `470c3539fb34c12e6a2d87cc2d0409a4fa916438`
(`470c353`) on `master`** — the sha the pre-push hook greps for — and re-walked the full change
against its parent rather than binding rounds 1-3 by reference. The four edits made between round 3
and that commit are itemized and individually verified in "What changed since round 3" above. No
binding remains outstanding for this change.
