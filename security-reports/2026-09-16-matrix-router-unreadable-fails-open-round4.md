# G7 · Threat review — `matrix-router-unreadable-fails-open` (T4, hard gate, round 4, 7c depth)

**Reviewed:** the diff that is now committed as `eff2e6fe24caa98c8958b11e7b20f75e004aceff` ("wip
baseline before corruption test"), a WIP commit an earlier, rate-limited attempt at this same
round-4 review made on top of `bbcb30d6fa3974ccc8c27b41994f77bc5980dca2` to preserve the uncommitted
working tree it found (per this session's own git-safety rule: commit rather than risk losing
uncommitted work). `git rev-parse HEAD` → `eff2e6fe24caa98c8958b11e7b20f75e004aceff`. Verified this
is not drift: `git diff bbcb30d6fa3974ccc8c27b41994f77bc5980dca2 eff2e6fe -- tools/lib/matrix.sh
tools/ledger.sh tools/reconcile.sh tests/run.sh` and a direct working-tree comparison
(`git diff eff2e6fe -- <same 4 paths>` → 0 lines) both confirm the four files under review are
byte-for-byte identical to the uncommitted diff described in the task and reviewed in rounds 1-3;
the WIP commit additionally picked up unrelated pre-existing untracked/modified files
(`ledger.jsonl`, `experiments/*`, `.claude/settings.json`, the round2/round3 report files,
`specs/matrix-router-unreadable-fails-open/`, etc.) that are **not** in scope for this review and
were not read. Subject of this review is still exactly: round 1's direct `_matrix_load` guards in
`tools/ledger.sh`/`tools/reconcile.sh`, round 2's G1..G8 row-completeness loop, round 3's `NF != 10`
+ blank-cell check, and **round 4's new content allow-list** inside `tools/lib/matrix.sh`'s
`_matrix_load`, plus the accompanying `tests/run.sh` additions. Fresh session; only this prompt,
`project/surfaces.conf`, the diff, `core/06-extending.md`, and the round-1/round-2/round-3 reports
were read. `specs/matrix-router-unreadable-fails-open/requirements.md` was **not** opened, per the
card's `withhold` line. No files were edited.

**Files in scope and their tier** (`project/surfaces.conf`): `tools/ledger.sh` and
`tools/reconcile.sh` — **T4** (`:27`, "Routing and evidence — a wrong answer here is silent and
confident"); `tools/lib/matrix.sh` — **T4** (`:28`, "The gate matrix reader — decides what is
mandatory"); `tests/run.sh` — T3. Change tier = **T4**, hard gate.

---

## What changed since round 3

Round 3 (Build) replaced the shape-only checks with a content allow-list: each of the 5 trimmed,
asterisk-stripped tier cells must match
`cell ~ /^—$|^(M( \(hard\))?|R)(¹|²|³|⁴|⁵)?$/` (`tools/lib/matrix.sh:103`) or the row is dropped
(`next`), caught downstream by round 2's G1..G8 presence loop exactly like a missing row.

This round's brief: determine whether that is architecture-level closure or gap #4. Every test
below was run live, against a fresh scratch copy of this worktree (mirroring `tests/run.sh`'s
`newrepo()` fixture), driving both the library function and the real `ledger.sh
compliance`/`reconcile.sh` CLIs.

---

## The walk — real commands, real output

### 1 · Round 3's own finding (compensating double-edit, net NF unchanged) — closed, live

Reproduced round 3's exact repro against G7's row (drop the persona/budget pipe, insert a stray
pipe inside the T4 cell's `(hard)` text):

```
$ sed -i 's/.../| **G7 · Threat** | Security engineer 20 min | — | — | R⁴ | M | **M (h|ard)** |/' core/01-router.md
$ awk -F'|' '/^\| \*\*G7/ {print NF}' core/01-router.md
10
$ ( . tools/lib/matrix.sh; _matrix_load; echo "load_exit=$?" )
matrix: .../01-router.md is missing a row for: G7
load_exit=2
```

Confirmed through the full CLI as well: `ledger.sh compliance --change c --tier T4` → `REFUSED...
exit=2`; `reconcile.sh T4` → `REFUSED... exit=2`. Round 3's specific finding is closed. (Full
transcripts omitted here for space — same shape as §7 of the round-3 report, now landing on
`REFUSED`/exit 2 instead of a silent clean pass.)

### 2 · Lucky collision — a pure content SWAP inside one row, no pipe-count tricks needed at all

This is the finding the task asked me to hunt for, and it did not need round 3's "shift" mechanism.
The allow-list validates that a cell's content is *some* legal tier value — not that it is the
*correct* value for *that column*. Any permutation of already-legal cell contents within a row (or
even across rows) is therefore invisible to it. No pipe is added or removed; `NF` never leaves 10.

Swapped G7's T1 cell (`R⁴`) and T4 cell (`**M (hard)**`) — both independently legal tokens, just
relocated:

```
$ sed -i 's/| — | — | R⁴ | M | \*\*M (hard)\*\* |/| — | — | **M (hard)** | M | R⁴ |/' core/01-router.md
$ ( . tools/lib/matrix.sh
    _matrix_load; echo "load_exit=$?"
    for t in T0 T1 T2 T3 T4; do echo "$t: [$(matrix_cell G7 $t)]"; done
    matrix_required T4 )
load_exit=0
T0: [—]
T1: [—]
T2: [M (hard)]
T3: [M]
T4: [R⁴]
matrix_required T4:
G1
G4
G5
G6
G8
```

`_matrix_load` returns **success**, no warning anywhere, and `matrix_required T4` is `G1 G4 G5 G6
G8` — **G7, the T4 HARD GATE, is silently absent.** Confirmed through the full CLI:

```
$ bash tools/ledger.sh compliance --change c --tier T4
  PASS       G1   Intent
  NOT RUN    G4   Ripple
  NOT RUN    G5   Proof
  NOT RUN    G6   Peer
  NOT RUN    G8   Dogfood

  Recommended here, mandatory if the footnote applies — your call:
    CHECK  G2   Scout     R¹ ...
    CHECK  G3   Craft     R² ...
    CHECK  G7   Threat    R⁴ **M** whenever the change accepts user input, persists data, or ...

INCOMPLETE — 4 mandated gate(s) without a pass: G4 G5 G6 G8
exit=1
$ BASE=<sha> bash tools/reconcile.sh T4
Gates       : Intent, Ripple, Proof, Peer, Dogfood
Also check  : Scout¹, Craft², Threat⁴  (recommended; the footnote may make it mandatory)

Reconciled — routing matches. This says nothing about whether the
gates above ran.
exit=0
```

`compliance` demotes G7/Threat to the optional "Recommended here, mandatory if the footnote
applies" section — invisible to the `INCOMPLETE` mandate list — and if a real change logged passes
for G1/G4/G5/G6/G8, this would print "All T4-mandated gates satisfied" at **exit 0** with the T4
hard gate never named. `reconcile.sh` moves `Threat` from `Gates:` to `Also check:` (recommended)
and reports **`Reconciled — routing matches.` at exit 0.** This is the identical vulnerability class
rounds 1-3 all exist to close — a T4 hard gate silently missing from the mandated list, confident
success, no warning — reproduced through the real CLI a fourth time, and it needed *less*
sophistication than round 3's finding (no compensating pipe-count math; a straight content swap
within one row).

A second within-row swap confirms this is not specific to the T1/T4 pair — swapping T1↔T3 instead:

```
T1: [—]   T2: [M]   T3: [M]   T4: [R⁴]
required T1: (empty)      required T4: G1 G4 G5 G6 G8
```

Same outcome: G7 vanishes from T4's mandate, and simultaneously would wrongly *appear* mandatory
at T1 if T1's cell had landed on `M` instead of `—` in a different swap — the vulnerability can
move a mandate in either direction (add or remove), not just remove.

### 3 · Cross-row content borrowing — the (hard) marker itself migrates to the wrong gate

Swapped content **across two different rows**: G7's T4 cell (`**M (hard)**`) with G4/Ripple's T4
cell (`M`) — again, both independently legal tokens, no pipe-count change in either row:

```
$ sed -i 's/.../| **G7 · Threat** | Security engineer | 20 min | — | — | R⁴ | M | M |/' core/01-router.md
$ sed -i 's/.../| **G4 · Ripple** | Release engineer | 10 min | — | R | M | M | **M (hard)** |/' core/01-router.md
$ ( . tools/lib/matrix.sh; _matrix_load; echo "load_exit=$?"
    echo "G7 T4: [$(matrix_cell G7 T4)]"; echo "G4 T4: [$(matrix_cell G4 T4)]" )
load_exit=0
G7 T4: [M]
G4 T4: [M (hard)]
```

Both rows still validate (every cell is still a legal token, `matrix_required T4` still lists both
G4 and G7 as mandated, since both cells still contain `M`) — but the **`(hard)` marker has moved
from the real hard gate to the wrong one.** `tools/reconcile.sh:601` reads exactly this substring to
decide its display label:

```awk
*"(hard)"*) GATES="${GATES}${GATES:+, }$(matrix_name "$_g")(HARD GATE)";;
```

Confirmed live through the actual CLI:

```
$ BASE=<sha> bash tools/reconcile.sh T4
Gates       : Intent, Ripple(HARD GATE), Proof, Peer, Threat, Dogfood
```

`Ripple` (G4) — an ordinary mandatory gate — is now labeled `(HARD GATE)`. `Threat` (G7) — the
actual hard gate, whose own card at the top of this review states `escalate_to: T4 approver. NEVER
the author alone` — loses the label entirely and prints as an ordinary mandatory gate. `(HARD
GATE)` in `reconcile.sh`'s output is the only automated, at-a-glance signal in this toolset for
"this one needs an independent T4 approver, not the author clearing it themselves" — this corruption
inverts it without tripping any check. `matrix_required T4` is unaffected here (both gates stay
listed as mandated), so this variant is a quieter, escalation-routing failure rather than a
gate-vanishes failure, but it is the same root cause as §2 and no less real for the toolset's stated
purpose (`does_not_own`/`escalate_to` in this gate's own card exists specifically to keep a hard
gate from being self-cleared).

### 4 · id/persona/budget columns (not content-validated) — no comparable danger found

Corrupted G7's **id** column to read `**G1 · Threat**` (collides with the real G1 row):

```
$ ( . tools/lib/matrix.sh; _matrix_load; echo "load_exit=$?" )
matrix: .../01-router.md is missing a row for: G7
load_exit=2
```

The id column *is* effectively validated: `_matrix_load` requires `$2` to match `/G[0-9]+/`
(`matrix.sh:89`), and reassigning a row's id to an id that already belongs to another row makes the
*original* id (G7) disappear from `cut -f1`'s output, which round 2's G1..G8 presence loop catches
and refuses on — exactly as a genuinely missing row would. (It does *not* protect against the
row overwriting the real G1's *answer* if something read by first-match rather than by presence,
but nothing here does — `matrix_cell`/`matrix_required` both do full-table scans and every consumer
already assumes at most one row per id via the presence loop.)

Persona and budget are not content-validated at all, but neither is used for a gating decision:
persona is display-only (`matrix_name`, used in report text); budget is silently defaulted to `"0"`
on non-numeric content (`matrix.sh:96`, `bud = $4; gsub(/[^0-9]/, "", bud)`) — a known, pre-existing
"silent default" already noted in the round-3 report for a different reason, informational
(estimated review minutes) rather than enforcement, and unchanged by this round. Not filed as
blocking; carried forward as the same MINOR-adjacent observation round 3 already made.

### 5 · Regression — all 8 real rows still parse correctly, no false rejection

```
$ ( . tools/lib/matrix.sh; _matrix_load; echo "load_exit=$?"
    matrix_gates; echo "required T4:"; matrix_required T4 )
load_exit=0
G1 G2 G3 G4 G5 G6 G7 G8
required T4:
G1 G4 G5 G6 G7 G8
```

Also ran the real test harness: `bash tests/run.sh matrix_load` → **`passed 22 · failed 0 · skipped
0`** against this worktree's own `tests/run.sh` and `core/01-router.md`, including round 3's
content-shift regression test. No over-refusal against the shipped router.

### 6 · The regex itself, tested directly on this Windows Git Bash `awk` (GNU Awk 5.4.0)

```
$ awk --version | head -1
GNU Awk 5.4.0, API 4.1, PMA Avon 8-g1 (GNU MPFR 4.2.2, GNU MP 6.3.0)

input "M"            -> MATCH      (plain M)
input "R"             -> MATCH      (plain R)
input real em dash — -> MATCH      (U+2014)
input hyphen "-"      -> NOMATCH    (correctly rejected — not the same codepoint)
input en dash –       -> NOMATCH    (U+2013, correctly rejected — no confusable acceptance)
input "M(hard)"       -> NOMATCH    (missing required space before the paren — correct)
input "MM"            -> NOMATCH
input "M\"            -> NOMATCH    (trailing backslash — no injection/escaping issue found)
input "M " (untrimmed)-> NOMATCH    (this probe skipped the trim step deliberately; the real
                                      code trims before this check, so real rows are unaffected)
input NBSP + "M"       -> NOMATCH   (U+00A0 is not in the trim's [ \t] class, correctly rejected
                                      rather than silently accepted as equivalent to a plain space)
```

The pattern is fully anchored (`^...$` on every alternative), uses no unbounded/nested
quantifiers (no ReDoS surface), and gawk 5.4.0 handles the multibyte superscript/em-dash literals
correctly and consistently with the round-3 report's own reasoning for preferring alternation over
a bracket class. No parsing or portability issue found in the regex itself — the gap in §2/§3 is
architectural (position is unchecked), not a regex bug.

---

## Findings

### BLOCKING — the content allow-list validates vocabulary, not position: any permutation of already-legal cell values (within a row, or across two rows) is fully invisible to `_matrix_load`, and can silently drop a T4 hard gate's mandate or move its `(hard)` escalation marker onto the wrong gate

`tools/lib/matrix.sh:99-106`. §2-§3. Verified live, through the full CLI (`ledger.sh compliance`,
`reconcile.sh`), not just the library function, in three independent constructions (T1↔T4 swap
within G7's row, T1↔T3 swap within G7's row, T4↔T4 swap across G7's and G4's rows). Root cause: the
allow-list (`cell !~ /^—$|^(M( \(hard\))?|R)(¹|²|³|⁴|⁵)?$/`) is column-agnostic — it only asks "is
this a value the table ever legally contains anywhere," never "is this the value this specific
column, for this specific gate, at this specific tier, is supposed to hold." Every one of rounds
1-3's fixes progressively narrowed the *shape* of corruption that goes undetected (whole file →
one dropped row → wrong field count → blank cell → shape-preserving column shift), but every round
including this one has left "the content is exactly the right vocabulary, just relocated" entirely
open, because nothing in `_matrix_load` ever compares a cell's content against what *that* cell is
expected to be for a known-good baseline. This is not a shape defect at all — it needs no pipe
manipulation whatsoever, which makes it a simpler attack (or copy/paste accident) than every prior
round's finding, not a more contrived one.

**Why this is architecturally different from rounds 1-3's gaps, not just "one more shape":** every
prior fix could be (and was) closed by tightening a check on the row's own text. This one cannot be,
by any check confined to a single row's text, because a swap produces a row that is — by every
available internal signal — indistinguishable from a correctly-authored one. Detecting it requires
either (a) a fixed reference table of exactly which of the 9 values is legal in which of the 40
(8 gates × 5 tiers) cells — effectively re-deriving the router's own content and checking equality,
not just "shape" — or (b) an external integrity check (checksum/signature over the known-good table)
that this file's stated design (round 1's own header comment: "used to also be hardcoded... and the
copies disagreed") deliberately avoids by design, since a second copy of the matrix is the exact
failure mode this whole file was written to eliminate. There is no cheap next increment here the way
`NF != 10` or the blank check were cheap increments over what came before.

### INFO — round 3's own finding (compensating double-edit) is closed, confirmed live including through the full CLI

§1. `_matrix_load` now returns exit 2 and names G7 as missing for the exact repro in round 3's §7;
`ledger.sh compliance` and `reconcile.sh` both refuse (exit 2) rather than silently reporting a
clean, T4-hard-gate-free routing.

### INFO — id-column corruption is caught by the existing G1..G8 presence check; persona/budget corruption is informational-only and not a gating vector

§4. Reassigning a row's id to collide with another gate's id makes the original id vanish from the
table and is refused exactly like a missing row. Persona/budget have no content validation but are
not used for any mandate decision; budget's silent "invalid text → 0" default is pre-existing and
already noted in the round-3 report, not a new finding.

### INFO — no false-positive regression against the real router; full test suite (`matrix_load` filter) passes 22/22

§5. All 8 built-in rows parse at exactly `NF=10` with legal content in every tier cell;
`matrix_required T4`/`matrix_gates` unchanged from what rounds 1-3 already established.

### INFO — the allow-list regex itself is sound: no confusable-character acceptance, no ReDoS surface, correct on this Windows Git Bash's GNU Awk 5.4.0

§6. Tested directly against em dash vs. hyphen vs. en dash, missing-space `(hard)` variants,
backslashes, and NBSP — every adversarial input was rejected correctly. The vulnerability in this
round is architectural (§2-§3), not a defect in the regex pattern itself.

---

## T4 boundary check

| Boundary (surfaces.conf) | Crossed by this round's change? | Checked? |
|---|---|---|
| Round 3's own finding: compensating double-edit (net NF unchanged, shape-shifted content) | **No longer** — refused, naming the gate, through the full CLI | Yes, §1 |
| **Content-legal permutation within one row (lucky collision, no pipe tricks)** | **Yes — T4 HARD GATE G7 silently absent from `matrix_required`/`compliance`/`reconcile`, exit 0/clean report** | Yes, §2 — **BLOCKING** |
| **Content-legal permutation across two rows (borrowed `(hard)` marker)** | **Yes — escalation label migrates to the wrong gate in `reconcile.sh`'s own output** | Yes, §3 — **BLOCKING** (same root cause as above) |
| id/persona/budget column corruption | No comparable danger — id collision refused by existing presence check; persona/budget not gating-relevant | Yes, §4 |
| False refusal against the real router | Not observed | Yes, §5 |
| Regex soundness (confusables, ReDoS, portability on this awk) | Sound | Yes, §6 |
| Privilege / new file / network / credential reach | None | Yes |

**Privilege growth:** none directly from this diff's own code; as with round 3, the open finding is
a mandate silently *shrinking* (a hard gate no longer required, or its escalation requirement
silently reassigned to the wrong gate) rather than growing — the specific failure mode this whole
change series targets, still open.

---

## Verdict

**G7 · Threat (HARD GATE, T4): FAIL**, round 4.

The architecture has **not** changed in the way that closes this bug class. Round 4's content
allow-list is a real, useful narrowing — it closes round 3's specific finding (§1), correctly
rejects every adversarial shape probed in §2-§6 that isn't a pure content permutation, and does not
regress against the real router (§5). But "does every cell contain a value from the legal
vocabulary" is a strictly weaker property than "does every cell contain *its own* correct value,"
and the difference between those two properties is exactly what a content-legal swap exploits — with
less effort than round 3's own finding needed, not more. `passes_when: no unresolved finding above
low` — this one is above low, verified live through the actual release-blocking CLI, twice, with two
independent constructions (within-row and cross-row).

Confidence: **fresh** — every live claim in this report, including both BLOCKING findings, is backed
by a command run against a fresh scratch copy of this worktree or the real `tests/run.sh` harness
(`passed 22 · failed 0 · skipped 0`), not by reading the awk and reasoning about what it should do.
`specs/matrix-router-unreadable-fails-open/requirements.md` was not opened. No files were edited.

**Premise challenged: yes.** The task's own framing asked directly whether this is "the terminating
architecture" or "gap #4 waiting to be found," and asked me to try constructing a lucky collision
specifically. I did — twice, with two different mechanisms (within-row swap, cross-row swap), both
reproduced live through the full CLI, and I additionally verified the things that would make a
"no new gap" verdict credible (regex soundness on the actual runtime awk, id-column behavior,
budget/persona non-gating status, and a clean 22/22 regression run) rather than stopping as soon as
the first BLOCKING finding landed. This is not a manufactured finding to extend a streak: a pure
content-legal permutation is a strictly *simpler* corruption than the compensating double-edit round
3 needed, and the fact that four consecutive rounds have each found the vocabulary check for the
*previous* round's fix was necessary-but-not-sufficient is itself the signal that a per-row/shape
check of any kind cannot be the terminating architecture here (see the BLOCKING finding's
architectural-difference paragraph above) — that is an engineering conclusion this round reaches
with evidence, not a reflex to keep failing the gate.

---

## Engineering judgment on the architecture (task item 6)

A hardcoded content allow-list is **not** the right terminal architecture for this check, and I do
not think a fifth round tightening `_matrix_load` further within the same strategy (row-local shape
and vocabulary checks) will close this. The reasoning:

- Rounds 1 through 4 have each closed exactly the shape of corruption the previous round's fresh
  reviewer happened to construct, and each round's fix left a strictly narrower but still-nonempty
  gap for the next reviewer to find by construction rather than by luck — four for four. That
  pattern is itself evidence the strategy (validate more and more about a row's *shape and
  vocabulary* in isolation) is chasing a moving target rather than closing a class.
- The reason is structural: `_matrix_load` parses **one row at a time**, and every check it can
  perform is therefore necessarily a function of that row's own bytes. A content permutation
  (this round's finding) produces a row whose bytes are, by construction, drawn entirely from the
  set of legal substrings — there is no row-local property left to check that distinguishes a
  correctly-authored row from a permuted one, because both are valid strings in the same small
  grammar. Tightening the grammar further (e.g., "M cannot follow M" or similar ad hoc rules) would
  not generalize; it would just be round 5's shape check, closing this specific repro and leaving the
  next permutation (a 3-cell rotation instead of a 2-cell swap, say) open.
- The fix that actually closes the class has to compare against **what the row is supposed to
  contain**, not just what shape/vocabulary it is drawn from — i.e., a reference of the known-good
  40-cell matrix (8 gates × 5 tiers), checked either by value or by a checksum/signature over the
  whole table. This file's own header comment explains why a *duplicate, independently-maintained*
  copy of the matrix was rejected before (`tools/lib/matrix.sh:5-11`, the ledger.sh/reconcile.sh
  hardcoded-copy drift bug this whole file exists to prevent) — so the right shape for this
  reference is almost certainly a generated integrity check (a checksum of `core/01-router.md`'s
  table region, committed alongside it and regenerated by the same process that edits the table,
  the way `dashboard.html` is regenerated by a pre-push hook per this repo's own commit history)
  rather than a second hand-maintained table. That is a materially different, larger change than
  another `_matrix_load` tightening pass, and is a decision for whoever owns this change's design
  (T4 approver / Build), not something I'm positioned to spec unilaterally from a G7 seat — but the
  evidence in §2-§3 above is, I think, enough to justify raising it rather than sending this around
  for a round 5 shape patch that the same reasoning predicts will not be the last one either.
- None of this should be read as "round 4 was wasted effort" — it correctly closed a real bug (§1)
  and is strictly better than round 3. It's a genuine narrowing. It just is not, and structurally
  cannot become through more row-local checks, sufficient on its own.

---

## Structured findings

| # | Severity | Location | Claim |
|---|---|---|---|
| 1 | `blocking` | `tools/lib/matrix.sh:99-106` | The content allow-list validates that each tier cell's content is *some* legal value, never that it is *the correct* value for that specific column — so any permutation of already-legal cell contents (within one row, or copied across two rows) is fully invisible to `_matrix_load`. Reproduced live, through the full CLI, with two independent constructions: (a) within-row swap of G7's T1↔T4 cells — `matrix_required T4` returns `G1 G4 G5 G6 G8` (G7/Threat, the T4 hard gate, silently absent), `ledger.sh compliance --tier T4` demotes G7 to the non-mandatory "Recommended... your call" section (would print "All T4-mandated gates satisfied" at exit 0 if the other 5 were logged), `reconcile.sh T4` moves Threat from `Gates:` to `Also check:` and exits 0 "Reconciled — routing matches"; (b) cross-row swap of G7's and G4's T4 cells — both rows still validate and both stay in `matrix_required T4`, but `reconcile.sh`'s `(hard)`-substring-driven `(HARD GATE)` label (`tools/reconcile.sh:601`) migrates from G7/Threat (whose own card requires `escalate_to: T4 approver, NEVER the author alone`) onto G4/Ripple, an ordinary gate. No pipe is added or removed in either construction; `NF` stays 10 throughout, making this simpler than round 3's compensating-double-edit finding, not more contrived. No row-local check (shape or vocabulary) can close this in general, because a permuted row is, by construction, indistinguishable in isolation from a correctly-authored one; closing the class needs a check against a known-good reference for the full table (value-by-value or a checksum/signature), not another `_matrix_load` tightening pass — detailed in the Engineering judgment section |
| 2 | `info` | `tools/lib/matrix.sh:87-115` | Round 3's own finding (compensating double-edit, net NF unchanged) is closed: reproducing round 3's exact §7 repro now yields `_matrix_load` exit 2 naming G7 missing, and both `ledger.sh compliance` and `reconcile.sh` refuse (exit 2) rather than silently reporting a clean routing |
| 3 | `info` | `tools/lib/matrix.sh:89` | id-column corruption (reassigning a row's id to collide with another gate's real id) is caught by the existing G1..G8 presence check, since the original id then vanishes from the parsed table; persona and budget columns have no content validation but are not used in any gating decision (persona is display-only, budget silently defaults invalid text to "0" — a pre-existing, already-noted-in-round-3 behavior, informational only) |
| 4 | `info` | `core/01-router.md` | No false-positive regression: all 8 built-in rows parse at exactly NF=10 with legal content in every tier cell, `matrix_required T4`/`matrix_gates` unchanged from rounds 1-3; full `tests/run.sh` run filtered to `matrix_load` passes 22/22 |
| 5 | `info` | `tools/lib/matrix.sh:103` | The allow-list regex itself is sound on this worktree's actual runtime (`awk --version` → GNU Awk 5.4.0): correctly distinguishes the real em dash from a hyphen or en dash, rejects a missing-space `(hard)` variant, a trailing backslash, and an NBSP-prefixed cell; fully anchored with no unbounded/nested quantifiers (no ReDoS surface). The vulnerability found this round is architectural (position vs. vocabulary), not a defect in this regex |

## Ledger line

```
cd "D:\work\gated-change\.claude\worktrees\amazing-jones-bf8e9e" && bash tools/ledger.sh add \
  --change matrix-router-unreadable-fails-open --gate G7 --tier T4 --round 4 \
  --outcome fail --confidence fresh --challenged true --model claude-sonnet-5 --tokens 100000 \
  --finding "blocking::tools/lib/matrix.sh:99-106::the content allow-list validates vocabulary not position -- any permutation of already-legal tier-cell content (within one row or across two rows) is fully invisible to _matrix_load; reproduced live through the full CLI with two constructions: within-row T1<->T4 swap on G7 drops the T4 hard gate from matrix_required/compliance/reconcile (exit 0 clean routing), cross-row T4<->T4 swap between G7 and G4 migrates reconcile.sh's (HARD GATE) escalation label onto the wrong gate; needs no pipe-count trick (simpler than round 3's finding); closing the class needs a known-good reference for the full table (value check or checksum), not another row-local shape/vocabulary tightening pass" \
  --finding "info::tools/lib/matrix.sh:87-115::round 3's compensating-double-edit finding is closed -- confirmed live, exit 2, through both the library and the full ledger.sh compliance/reconcile.sh CLI" \
  --finding "info::tools/lib/matrix.sh:89::id-column corruption is caught by the existing G1..G8 presence check; persona/budget have no content validation but are not gating-relevant (display-only / informational silent-default, pre-existing)" \
  --finding "info::core/01-router.md::no false-positive regression -- all 8 rows parse at NF=10 with legal content, matrix_required T4 unchanged, and tests/run.sh filtered to matrix_load passes 22/22" \
  --finding "info::tools/lib/matrix.sh:103::allow-list regex itself is sound on this worktree's actual GNU Awk 5.4.0 -- correct on em-dash/confusable rejection, missing-space variants, backslash, NBSP; no ReDoS surface. This round's vulnerability is architectural, not a regex defect"
```
