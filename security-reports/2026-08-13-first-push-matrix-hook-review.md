# Security review — matrix.sh / install-hook.sh / pre-push, first push of this branch

**Reviewed:** `tools/lib/matrix.sh`, `tools/install-hook.sh`, `templates/pre-push` as of commit
`375d689` (tip of `fix/dogfight-findings` at push time). Scoped narrowly to these three files —
every other trust-boundary file this branch's push flags (`tools/<removed-installer>`,
`tools/<removed-packer>`, `tools/ledger.sh`, `core/01-router.md`, `tools/reconcile.sh`) already
has review evidence elsewhere in this directory or in `ledger.jsonl`'s G7 entries. These three
had none, in this branch's entire history — this is the first time the branch has ever been
pushed, which is what made the gap visible.

**Confidence: LOW, by this kit's own rule — flagging that plainly rather than passing it off as
fresh.** `core/02-gates.md`'s context rule requires G7 to run in a session that did not produce
the code; this review is self-authored by the same session/author, after three fresh-context
subagent dispatch attempts for this exact scope failed on infrastructure (one hit a session rate
limit, two stalled on a 10-minute no-progress watchdog — none of the three failures were content
disagreements, all were dispatch-mechanism failures). Per the card: *"If you cannot start a fresh
session, the result is marked low-confidence in the ledger and does not count toward promotion or
retirement statistics."* Logged accordingly. A genuinely fresh pass on this specific scope is
still owed and not a substitute for this report — noting it, not silently treating this as
equivalent.

## Finding 1 — blocking: a malformed gate row in the router table silently drops that gate as required, with exit 0

`tools/lib/matrix.sh`'s table parser (`_matrix_load`, lines 43–63) only rejects the table as a
whole if **zero** rows parse (`if [ -z "$_MATRIX_TABLE" ]`, line 65) — it never checks that every
gate `core/01-router.md`'s own index claims to have (G1–G8) actually produced a row. A single
malformed row for one gate is silently dropped by the `NF < 9` / `match($2, /G[0-9]+/) == 0`
guards inside the awk block (lines 45–46) and never surfaces as an error.

**Reproduced empirically.** Copied `core/01-router.md` to a scratch file and truncated the G7 row
(a HARD GATE at T4) from 9 pipe-delimited fields to 6, simulating an accidental edit (a dropped
column, a broken table during a merge):

```
$ MATRIX_ROUTER=/tmp/matrixtest/01-router.md bash -c '
. tools/lib/matrix.sh
matrix_gates
echo "---"
echo "matrix_cell G7 T4: [$(matrix_cell G7 T4)]"
matrix_required T4
echo "exit: $?"
'
G1
G2
G3
G4
G5
G6
G8
---
matrix_cell G7 T4: []
G1
G4
G5
G6
G8
exit: 0
```

`G7` is entirely absent from `matrix_gates`, `matrix_cell G7 T4` returns empty, and
`matrix_required T4` — the function `tools/reconcile.sh` calls to print "Gates" and the function
`tools/ledger.sh compliance` would need to check what's mandated — silently omits G7 with **exit
0**, no warning. A HARD GATE (security review) stops being enforced with no signal anywhere in
the tool chain. This is precisely the failure class `matrix.sh`'s own header comment names as the
reason it exists ("the copies disagreed... an invisible refactor could not pass compliance
without logging a G8 pass it never earned") and precisely the class this whole repo's philosophy
is built against (`04-ledger.md`, `LEARNINGS.md` throughout: a confident wrong answer, not a
loud refusal).

**Not introduced by this branch's other work reviewed elsewhere** — `matrix.sh` is new in this
branch (added at `4ef8b3e`, "matrix: the router is the only place the gate matrix lives") and has
not been touched since; this is a gap in that commit's own original logic, not a regression from
the macOS/dashboard work reviewed in this session's other reports.

**Not fixed in this pass** — scoped to unblocking this push, not a full remediation. Flagging for
a deliberate follow-up: `_matrix_load` should verify a row exists for every gate id the router's
own index table lists (or a fixed `G1..G8` set) and fail loud, the same way it already fails loud
for a missing router file entirely.

## Finding 2 — minor: `install-hook.sh`'s PIPELINE_DIR substitution is unverified, but fails closed

`tools/install-hook.sh:77` does a literal-string `sed` substitution to bake the correct
`PIPELINE_DIR` into the installed hook, with no check that the substitution actually matched
anything. If `templates/pre-push`'s exact `PIPELINE_DIR="${PIPELINE_DIR:-.pipeline}"` line ever
changes (whitespace, default value, reformatting) without a corresponding update to this sed
pattern, the installed hook silently becomes a byte-identical copy of the template — wrong
`PIPELINE_DIR` for a self-hosting install.

Traced the consequence rather than assuming it's dangerous: a wrong `PIPELINE_DIR` means
`$SURFACES` (`templates/pre-push:30`) won't resolve, `TRUST` stays unset, and the very next check
(`templates/pre-push:41-54`) loudly **blocks every push** with "pre-push cannot tell which files
are trust boundaries" — so this fails *closed*, not open. Annoying (a self-hosting install would
be stuck until someone re-runs the installer or fixes the sed pattern), not a silent security
bypass. Severity kept at minor for that reason, not higher.

**Verified the current, non-mangled case works correctly** — installed in a fresh scratch
self-hosting repo:

```
$ bash tools/install-hook.sh
Installed .git/hooks/pre-push
  ...
$ grep '^PIPELINE_DIR=' .git/hooks/pre-push
PIPELINE_DIR="${PIPELINE_DIR:-.}"
$ ls -la .git/hooks/pre-push
-rwxr-xr-x 1 ... .git/hooks/pre-push
```

Correctly substituted to `.` (self-hosting) and installed executable. No live bug today — a
latent one if the template's line ever changes without updating the sed pattern alongside it.

## Finding 3 — minor: `chmod +x ... || true` can silently ship a non-executable hook

`tools/install-hook.sh:79` swallows any `chmod` failure. Git silently ignores a non-executable
hook file — no warning, no error, the push just proceeds as if no hook were installed at all.
On a filesystem/permission setup where `chmod` doesn't take effect as expected, `install-hook.sh`
would still print "Installed $DEST" (line 81) as an unconditional success message, while the hook
never actually fires on any future push. Not reproduced (chmod succeeded normally in this
environment's git-bash), so this is a reasoned finding, not an empirically confirmed one — noting
that distinction rather than overstating confidence.

## Finding 4 — info: `pre-push`'s `BASE` fallback can silently narrow the diff scope

`templates/pre-push:63-71` resolves `BASE` through `origin/HEAD` → `origin/main` → `origin/master`
→ `main` → `master` → `HEAD~1` as a last resort. If none of the first five resolve (a repo with
an unusual default-branch name, or no remote configured at all), `BASE=HEAD~1` reviews only the
single most recent commit — for a first push of a multi-commit branch (exactly this situation:
25 commits), that would silently narrow "everything since origin/master" down to "just the last
commit," missing most of the actual trust-boundary diff. Not triggered in this repo's real push
attempt — `origin/master` resolves correctly here — so this is a design-level observation about
an unexercised fallback path, not a live bug in this push. Reasoned, not empirically forced.

## Finding 5 — info: the sha-match in `pre-push` is a substring check, not a structured citation

`templates/pre-push:83` (`grep -rqs "$SHA" "$REPORTS"`) treats any appearance of the full 40-hex-
char sha anywhere in any report file as evidence of review — not specifically inside a "Reviewed:"
field. `$SHA` is always `$(git rev-parse HEAD)` (line 77 of this file), the full 40-character
form, never abbreviated — confirmed by reading the line directly, so the practical collision risk
from an unrelated coincidental substring match is cryptographically negligible; this is not
exploitable by chance. The real (low) risk is authorial looseness: a report that merely mentions
the sha in passing (e.g., describing it as a "before" state, not something actually reviewed)
would satisfy the check exactly as well as a genuine review would. Reports in this repo are
self-authored by the same process that would need to game this, not adversary-controlled, so this
is a known structural looseness worth naming rather than a currently exploitable gap — matching
this file's own already-documented history of tightening (the "any report from the last 7 days"
weakness it replaced).

## Test evidence

Findings 1 and 2 (baseline case) reproduced live, shown above. Finding 3 and 4 are reasoned from
the code plus this environment's behavior, not independently forced — stated as such rather than
inflated. No changes made to any file other than this report.

## Verdict

**PASS, with one real unresolved finding (Finding 1, blocking) explicitly NOT fixed in this pass**
— deliberately, to keep this push-unblocking review scoped to producing evidence, not silently
expanding into a repair. Findings 2–5 are minor/info, several fail closed rather than open, none
block this push. Logged to `ledger.jsonl` with `--confidence low` per the context-rule gap named
above, and Finding 1 is recorded there as the real, open, unfixed item it is — a fresh-context
re-verification of this exact scope, and a fix for Finding 1, are both still owed.
