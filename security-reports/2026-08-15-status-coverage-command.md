# Security review — tools/status.sh (pipeline coverage / "is it on?" command)

Self-authored fresh-context G7 pass over a new, previously-unreviewed file. Filed before the
commit that carries it, for the same structural reason the two other reports on this branch
give: a report can only name a sha that already exists, and the commit containing the report
produces a new one.

File in scope: `tools/status.sh`.
Trust-boundary basis (`project/surfaces.conf`, row extended by this same change): T4,
`tools/(reconcile|ledger|install-hook|install-claude-hook|status)\.sh$` — "Routing and
evidence — a wrong answer here is silent and confident."

**Why T4 and not lower.** `status.sh` reports whether work has landed with no gate run since.
Its worst failure is not a crash — it is a confident `0 unrouted, exit 0` over real T4 work,
which reads as a clean bill of health and causes gates to be skipped. That is the Q1
definition ("what here, if it broke, would fail SILENTLY?") almost verbatim, and it is
arguably the sharpest instance of it in the kit, because this is the command whose entire job
is to tell you whether everything else ran.

## What it does

Zero-argument. Reads `ledger.jsonl` for the last `"type":"gate"` record, anchors to the commit
that record names, and tiers every commit since it against `surfaces.conf` — the same rows,
parsed the same way, `reconcile.sh` applies to a working tree. Also reports gates that have
never appeared in the ledger at all, and which enforcement points are installed. Exits `0`
clean, `1` unrouted T3/T4 work, `2` cannot answer.

## Trust boundary walk

- **Ledger content reaching a shell/regex sink.** `LAST_COMMIT` is extracted from
  `ledger.jsonl` by `sed` with no shape validation — the same read-then-use pattern that
  produced the one real finding in
  `security-reports/2026-08-14-cli-input-validation-hardening.md` (a `"gate"` value spliced
  into an unanchored BRE `grep`). Traced every use here, because the ledger is explicitly an
  append-only historical file that older tools and hand-merges can write:
  1. `git rev-parse --verify -q "${LAST_COMMIT}^{commit}"` — quoted, and `rev-parse` treats
     its argument as a revision string, not a shell fragment. Live-probed with
     `"commit":"$(touch /tmp/pwned)"` and `"commit":"; rm -rf /"` in a scratch ledger: both
     fail to resolve, the script reports "not found in this repo", and no file was created.
  2. `RANGE="${SINCE_REF}..HEAD"`, passed **quoted** to `git rev-list --count` and `git log`.
     `SINCE_REF` is only ever set *after* `rev-parse --verify` succeeded, so a value that
     reaches this point is by construction a real, resolvable commit in this repository —
     the validation gate the cited prior finding was missing is present here.
  3. Printed into the human report. Display only, no re-interpretation.
  `LAST_COMMIT` never reaches `eval`, a `grep`/`awk` *pattern* position, or a command
  substitution. It is a `grep`/`awk` *subject* nowhere at all.
- **`surfaces.conf` regexes reaching awk as dynamic patterns.** The tiering pass passes each
  rule's regex to awk's dynamic `~` operator. This is the same trust relationship
  `reconcile.sh` already has with the same file (it feeds them to `grep -E`), and
  `surfaces.conf` is project-owned configuration, not attacker-supplied input — the same
  standing this kit's own `TRUST` derivation in `templates/pre-push` already assumes. A
  malformed regex degrades to "matches nothing" in awk rather than the silent `grep`
  exit-non-zero drop the earlier ledger finding documented; that is a strictly better failure
  mode than the tool it mirrors.
- **`git log --format="%x01%h %s"` and commit-subject injection.** A commit subject is fully
  attacker-controlled in a repo with untrusted contributors, and it lands on the marker line
  the awk parser keys on. Checked whether a crafted subject can forge a commit boundary or a
  tier: the marker is `\001` tested via `substr($0,1,1) == M`, and git's `%s` **strips
  newlines** from the subject (a multi-line message's later lines are `%b`, not emitted here),
  so a subject cannot introduce a new line at all, let alone one beginning with `\001`.
  Live-probed with a commit subject containing a literal `\001` byte and one containing
  `../../etc/passwd`: neither created a spurious commit row nor changed any tier. Worst case
  is cosmetic — a weird string printed in the T3/T4 list, which is display-only.
- **Does it fail open or closed, and is that the right way round?** Three distinct exits,
  deliberately not two: `2` for "cannot tell" (not a git repo, no `surfaces.conf`) is separate
  from `0` for "clean". Collapsing them is the actual danger — a caller or CI step that
  treats a missing config as success would report a broken install as a passing pipeline.
  Verified live: both `2` paths refuse with a message and never print a coverage figure, so
  there is no output a reader could mistake for an all-clear.
- **Does it write anything?** No. No file is created, modified, or deleted; no git ref is
  moved; no network call. Confirmed by reading every redirection in the file — all output goes
  to stdout/stderr. Unlike `templates/pre-push` (which commits) this command has no write
  privilege at all, so a wrong answer cannot damage state, only mislead.

## Findings

No findings, blocking or minor.

One **performance** defect was found and fixed during development, recorded here because its
failure mode was availability, not correctness: the first working version spawned ~24
subprocesses per commit (a `git show` plus a `grep -E` per rule) and measured **61 seconds for
this repo's own 63 commits** — extrapolating to over an hour on a 5,000-commit repo, for the
one command meant to be run casually. `surfaces.conf`'s own TARGET rows name this exact class
("Git Bash on Windows... the slow one"; "process spawn is cheap [on Linux], so cost bugs
hide"). Rewritten to one `git log` plus one `awk` pass: **3.6 seconds**, and flat in commit
count rather than linear. Semantic equivalence was proven rather than assumed — the original
per-commit algorithm was re-run independently over all 63 commits and diffed against the awk
output: **zero tier mismatches**, the only difference being 7 additional tier-`0` rows for
commits touching solely `IGNORE` paths, which never enter the T3/T4 lists or affect the exit
code.

## Test evidence

- `bash tests/run.sh test_status` → `passed 22 · failed 0 · skipped 0`, covering: unrouted T4
  reported with exit 1; anchoring to the last gated commit; a T1-only commit exiting 0;
  refusing to lie when the ledger's commit is absent from this repo; never-run gates named;
  `--quiet` printing nothing while preserving the exit code; missing enforcement points
  reported; `IGNORE` paths not raising a tier; truncation stated out loud; exit `2` for both
  "cannot tell" conditions.
- Cross-implementation equivalence check (old bash algorithm vs. new awk pass) over all 63
  commits of this repo: identical tiers, `mismatches: 0`.
- Injection probes against a scratch ledger (`"commit":"$(touch /tmp/pwned)"`, `"; rm -rf /"`)
  and against crafted commit subjects, described in the walk above — run directly, not
  simulated.
- `bash tools/dashboard.sh --check` → still `OK — cards, router matrix and the loop diagrams
  all agree`.

## Outcome

**PASS.** The one input that crosses a boundary (`"commit"` read back from `ledger.jsonl`)
is validated by `git rev-parse --verify` before it is ever used to build a revision range —
closing, by construction, the exact read-then-splice gap this codebase's prior G7 round found
in `ledger.sh`. The command holds no write privilege, distinguishes "cannot tell" from "clean"
so a broken install cannot masquerade as a passing pipeline, and its one real defect (a
61-second first run) was measured rather than assumed and fixed with proven-equivalent output.

Logged: `ledger.sh add --change status-coverage-command --gate G7 --tier T4 --round 1
--outcome pass --confidence high --challenged false --model claude-sonnet-5 --note
"self-authored fresh-context G7 pass on the new T4 tools/status.sh; see
security-reports/2026-08-15-status-coverage-command.md"`.
