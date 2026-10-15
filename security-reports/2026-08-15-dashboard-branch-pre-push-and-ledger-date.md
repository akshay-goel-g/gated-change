# Security review — pre-push dashboard auto-regen, ledger date widened to a UTC instant

Reviewed commit: `5ab4df67d6551894a6e7a0d8b15d3d51a3890198` (tip of
`dashboard/timestamps-and-star-narrative` at push time) — self-authored G7 pass, scoped to the
two T4-rated files this branch actually modified, diffed against their last-reviewed state:
`git diff 090fbed..HEAD -- templates/pre-push tools/ledger.sh`, which resolves to `90577df`
(pre-push) and `398fd03` (ledger.sh) — the only two commits on this branch that touch either
file. `core/01-router.md` also matches the T4 pattern list but was not modified anywhere in this
branch (last touched at `05eaa89`, already covered by
`security-reports/2026-08-14-action-tier-router.md` and the `5a6844b` fix-verification note in
that same report); `tools/reconcile.sh` / `tools/lib/matrix.sh` / `install*.sh` /
`<removed-packer>` are untouched by this branch entirely.

Files in scope: `templates/pre-push`, `tools/ledger.sh`.
Trust-boundary basis (`project/surfaces.conf`): `templates/pre-push` is T4 ("Enforcement — its
success is silent, so its failure is too"); `tools/ledger.sh` is T4 ("Routing and evidence — a
wrong answer here is silent and confident").

## What the diff does

1. **`templates/pre-push`** (`90577df`): appends a new block, after the existing trust-boundary
   check's closing `fi`, that regenerates `dashboard.html` from `ledger.jsonl` on every push via
   `tools/dashboard.sh`, and auto-commits the result — scoped to that one file via `git add
   "$DASHBOARD_OUT"` + `git commit -- "$DASHBOARD_OUT"` — only when content differs from what's
   committed after stripping the two known-nondeterministic fields (`generated`, `kitCommit`). A
   `dashboard.sh` failure warns to stderr and falls through to `exit 0` (does not block the push).
2. **`tools/ledger.sh`** (`398fd03`): three `printf` call sites (`cmd_add`, `cmd_route`,
   `cmd_escape`) switch `date -u +%Y-%m-%d` to `date -u +%Y-%m-%dT%H:%M:%SZ`. No new input source,
   no new sink — a fixed shell built-in's output format changes; every value still passes through
   the same `json_escape()` path it always did.

## Trust boundary walk

- **`ledger.sh`'s date widening.** `$(date -u ...)` takes no arguments derived from user input —
  the format string is a literal in the script, not interpolated from `$@` or any ledger content.
  The only question worth asking is whether anything downstream parses `date`'s *length* or
  splits on `-` and would misbehave against a longer value; grepped every consumer
  (`tools/ledger.sh`'s own `compliance`/`report`/`gates`, `tools/reconcile.sh`,
  `tools/dashboard/app.js`) and confirmed (matching the commit message's own claim, independently
  re-checked here rather than taken on trust) that all of them treat `date` as an opaque, sortable
  string. No trust boundary is newly crossed: this is a format change on a value that was already
  attacker-non-influenced.
- **`pre-push`'s new block, unattended execution surface.** This is the substantive question: the
  block now runs `bash tools/dashboard.sh` unattended, with git-commit privilege, on every push —
  previously a human ran `dashboard.sh` by choice and reviewed its output before committing.
  `dashboard.sh` itself is unmodified by this diff and is not itself T4-rated (only the scripts
  named in `surfaces.conf`'s T4 rows are; `dashboard.sh` is not one of them) — but automating its
  invocation from a T4 file changes who's exposed to whatever it does. Traced what it's fed:
  `ledger.jsonl` content, which is *not* itself a T4 surface, meaning a hostile line could reach
  it via a route this same gate doesn't independently check (a manual edit, an older `ledger.sh`,
  a hand-merged team ledger — the exact class this repo's own `LEARNINGS.md` already names).
  Checked `dashboard.sh` for a shell-injection sink reachable from ledger field content: no
  `eval`, no unquoted `$()` built from a ledger value, no ledger field ever reaches a command
  position — every read (`sed -n 's/.../\1/p'`, `awk`) only ever *extracts* a field into a JSON
  string destined for the HTML output, never executes it. So the newly-automated invocation
  extends *reach* (every pusher, every push, unattended) but not *capability* — a malicious ledger
  line was already, before this diff, capable of corrupting the HTML a human chose to generate
  and view; it is not newly capable of running code during the hook.
- **Auto-commit blast radius.** Verified by reading, not assuming: the commit is `git commit -q
  -m "auto: regenerate dashboard.html (pre-push)" -- "$DASHBOARD_OUT"` — the trailing pathspec
  restricts the commit to that one file regardless of what else is staged in the working tree at
  push time, so this cannot fold an unrelated staged file (e.g. something holding a secret) into
  its own commit. The commit message is a fixed literal, not built from any variable — no
  injection surface there either.
- **Fails open, by design, not by accident.** A `dashboard.sh` failure (e.g. a malformed card —
  the documented failure mode) warns and pushes the stale `dashboard.html` as-is rather than
  blocking. This trades staleness for availability, which is the correct trade for a
  non-security gate riding on the back of one that is (the trust-boundary check above it in the
  same file already ran and already can block); the regen block existing at all does not weaken
  that check, and its own failure mode was deliberately chosen not to compound with it.

## Findings

No findings, blocking or minor. The date-widening change introduces no new input source. The
pre-push regen block automates an existing, non-injectable code path (traced above) rather than
adding a new one, restricts its unattended write to a single pathspec, and fails open only on its
own non-security concern (dashboard freshness) without weakening the trust-boundary check that
already runs earlier in the same file.

## Test evidence

Targeted, not the full 20+ minute suite (matching this repo's own established practice for a
fresh-context G7 pass — see `security-reports/2026-08-14-cli-input-validation-hardening.md`):

- `bash tests/run.sh test_hook_regenerates_and_commits_dashboard_when_ledger_present` → pass
- `bash tests/run.sh test_hook_dashboard_regen_is_a_noop_once_settled` → pass (the
  infinite-recommit regression lock)
- `bash tests/run.sh test_hook_warns_but_does_not_block_when_dashboard_sh_fails` → pass
- `bash tests/run.sh date` (ledger date-format tests) → `passed 10 · failed 0 · skipped 0`
- `bash tests/run.sh ledger` → `passed 100 · failed 0 · skipped 0`
- `bash tests/run.sh dashboard` → `passed 18 · failed 0 · skipped 0`

All runs clean against the on-disk `5ab4df6` state, no repo files modified as part of review.

## Outcome

**PASS.** Both changes traced end to end. The ledger.sh change has no injection surface to begin
with. The pre-push change automates an already-non-injectable rendering path, scopes its only
write privilege (a git commit) to a single named file regardless of other working-tree state, and
fails open only on availability, not on the trust-boundary check that already gates this same
file. No privilege grew unremarked.

Logged: `ledger.sh add --change dashboard-timestamps-and-star-narrative --gate G7 --tier T4
--round 1 --outcome pass --confidence high --challenged false --model claude-sonnet-5 --note
"self-authored fresh-context G7 pass, scoped to the two T4 files this branch touches (pre-push
regen block, ledger.sh date widening); see security-reports/2026-08-15-dashboard-branch-pre-push-
and-ledger-date.md"`.
