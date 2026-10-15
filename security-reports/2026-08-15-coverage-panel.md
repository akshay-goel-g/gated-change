# Security review — coverage library and dashboard Coverage panel

Self-authored fresh-context G7 pass. Filed before the commit that carries it, for the same
structural reason the other reports on this branch give: a report can only name a sha that
already exists, and the commit containing the report produces a new one.

Files in scope, and why each is here:
- **`tools/lib/coverage.sh`** — new. T4 by a row added in this same change
  ("Decides what counts as unrouted — read by both status.sh and the dashboard").
- **`templates/pre-push`** — T4 ("Enforcement — its success is silent, so its failure is
  too"). One line changed (the regen no-op comparison).
- **`tools/dashboard.sh`** — T3 ("Tooling with several callers"). New coverage block.
- **`tools/dashboard/app.js`**, **`app.css`** — T1 ("Dashboard assets"). New render path;
  reviewed here anyway because it is where untrusted text reaches the DOM.
- **`tools/status.sh`** — T4, refactored to call the new library rather than its own inlined
  copy. Behaviour-equivalence checked by diffing full output before and after: identical.

## What the change does

`coverage_scan` / `coverage_anchor` / `coverage_claimed_anchor` / `coverage_never_run` move
out of `status.sh` into a shared library, and `dashboard.sh` now calls the same functions to
bake a `"coverage"` object into the page model, which `app.js` renders as a panel. The point
of the library is that two readers of "what is unrouted" cannot disagree — the failure
`tools/lib/matrix.sh` already exists to prevent one level down.

## Trust boundary walk

- **A commit subject is attacker-controlled, and it now reaches a browser DOM.** This is the
  genuinely new exposure: in a repo with untrusted contributors, `%s` is whatever they wrote,
  and it travels `git log` → awk → JSON → inlined `<script>` → `JSON.parse` → `innerHTML`.
  Traced every hop and tested the whole chain end to end with a commit crafted to break each
  one (`pwn </script><script>alert(1)</script> "quotes" \back`, on a commit that genuinely
  enters the coverage list — an earlier probe used an empty commit, which touches no files and
  so never reaches the panel at all, proving nothing; that probe was redone rather than
  reported):
  1. **awk JSON escaping** (`gsub(/\\/,"")`, `gsub(/"/,"\\\"")`) — the same idiom `WARN_JSON`
     already uses. The embedded `"quotes"` survive as `\"quotes\"`, and the result parses.
  2. **`escape_payload()`** — dashboard.sh already rewrites `</script` → `<\/script` and
     `<!--` for the whole MODEL, precisely because "a ledger note quoting real code CAN
     contain `</script>`". Coverage rides inside MODEL, so it inherits this. Verified in the
     generated file: **0** occurrences of the raw breakout, **1** of the neutralised form, and
     `JSON.parse` of the baked model succeeds with the subject round-tripping intact.
  3. **`escapeHtml()`** in `renderCoverage` — every interpolated value (`c.anchor`,
     `c.anchorClaimed`, `u.text`, each `neverRun` entry, `PIPELINE.generated`) goes through
     it. Pinned by `coverage panel escapes a commit subject rather than injecting it as
     markup`, which asserts `<img` never appears and `&lt;img` does.
  No hop relies on the one before it having been sufficient.
- **Ledger content reaching a revision position.** `coverage_anchor` reads `"commit"` out of
  `ledger.jsonl` with `sed` and no shape validation — the same read-then-splice shape that
  produced the one real finding in the `cli-input-validation-hardening` round. It is passed
  **quoted** to `git rev-parse --verify -q "${sha}^{commit}"`, which treats it as a revision
  string, not a shell fragment; and — the control that matters — the value is only ever
  returned, and therefore only ever used to build `<anchor>..HEAD`, **after** that
  verification succeeds. A value that reaches the range by construction resolves to a real
  commit here. Probed directly in the previous round with `$(touch /tmp/pwned)` and
  `; rm -rf /` in the commit field: neither executed, both correctly reported as unresolvable.
- **`surfaces.conf` regexes as dynamic awk patterns.** Same trust relationship `reconcile.sh`
  already has with the same file (it feeds them to `grep -E`); project-owned configuration,
  not attacker input. A malformed regex degrades to "matches nothing" in awk rather than the
  silent non-zero-exit drop the earlier `ledger.sh` finding documented — a better failure mode
  than the tool it mirrors.
- **Boundary-marker forgery in the awk parser.** The scan keys commit boundaries on a leading
  `\001`. git's `%s` strips newlines (later lines of a message are `%b`, not emitted), so a
  subject cannot introduce a line at all, let alone one starting with `\001`. Probed in the
  previous round with a literal `\001` in a subject: commit count still matched
  `git rev-list --count` exactly, no forged rows.
- **Reading another project's history as if it were yours.** Coverage is git-derived while
  `--ledger`/`--project` can point anywhere, so a fleet view would answer with *this* repo's
  commits against *another* project's gate records — a confident wrong answer of exactly the
  kind the panel exists to remove. Guarded: coverage computes only for a single ledger whose
  own directory resolves, via git, to this same toplevel; anything else emits `null` and the
  panel says why. Both refusals are pinned by tests.
- **`templates/pre-push`'s one-line change.** The regen no-op comparison now also blanks the
  `"coverage"` line. This does not weaken the trust-boundary check above it (untouched, and it
  runs first), and it does not hide a real kit change: gates/matrix/spine remain compared. It
  fixes a live defect — see Findings.

## Findings

No unresolved findings. One real defect was found *by the existing suite* during development
and fixed before commit, recorded here because of what it is:

**Unbounded auto-recommit, reintroduced.** Baking `"coverage"` into the model immediately
broke `test_hook_dashboard_regen_is_a_noop_once_settled`. Coverage is a function of git HEAD,
not of the ledger, so it changes on every commit — *including the auto-commit the pre-push
block itself makes* — which is precisely the unbounded-recommit shape `"kitCommit"` produced
once already (`LEARNINGS.md`). The regression lock written for that bug caught its recurrence
through a different field on the first run. Fixed by adding `"coverage"` to the no-op
comparison's exclusions, matched as a whole line because the value contains nested braces that
a sed character class cannot balance.

That fix creates an honesty obligation, which is discharged rather than left implicit: the
hook regenerates when the *ledger* moves, so commits landing with no gate logged leave the
baked panel behind — it can **undercount**, in exactly the scenario the panel is for. The
panel therefore always states that its counts were taken at generation time and points at
`status.sh` for a current answer, pinned by a test that asserts this appears *even when the
panel looks clean*.

Also fixed during development: the in-repo check originally compared path strings, and on Git
Bash for Windows `git rev-parse --show-toplevel` yields `D:/x` while `pwd` yields `/d/x` — the
mismatch `tools/ledger.sh`'s own header already documents. Coverage silently computed to
`null` forever on this kit's primary listed TARGET, failing closed (blank panel) rather than
loudly. Now both sides of the comparison are produced by git. Pinned by
`test_dashboard_coverage_survives_the_pwd_vs_git_toplevel_path_form`.

## Test evidence

- `node tests/dashboard-logic.test.js` → all pass, 9 new coverage tests executing the real
  render against crafted models: unrouted T4 reported; clean state; **not-computed
  distinguished from clean**; unresolvable anchor never reported as clean; never-run gates
  named; staleness detected when the loaded ledger moves past the baked anchor, and *not*
  claimed when it has not; generation basis always stated; commit-subject escaping.
- `bash tests/run.sh "coverage\|agree_on_the_unrouted"` → `passed 11 · failed 0`, including
  `test_status_and_dashboard_agree_on_the_unrouted_count`, which asserts the two tools produce
  the same number against a live fixture rather than trusting a comment that says they share a
  library.
- `bash tests/run.sh test_hook_dashboard_regen` → `passed 3 · failed 0` after the fix.
- `status.sh` output diffed before/after the refactor: **identical**.
- End-to-end breakout probe described above, run against a real generated page.

## Outcome

**PASS.** The one genuinely new exposure — attacker-controlled commit subjects reaching a
browser DOM — is defended at three independent hops, each verified against a payload built to
defeat it, on a commit that actually reaches the panel. The one ledger value used in a
revision position is verified before use by construction. The feature declines to answer
rather than guess whenever it cannot tell whose history it is looking at, and the panel
distinguishes "not computed" from "clean" so absence can never read as an all-clear. The two
defects found during development were both caught by measurement or by the existing suite, not
by inspection, and both are now pinned.

Logged: `ledger.sh add --change coverage-panel --gate G7 --tier T4 --round 1 --outcome pass
--confidence high --challenged false --model claude-sonnet-5 --note "self-authored
fresh-context G7 pass on tools/lib/coverage.sh, the pre-push no-op fix, and the dashboard
Coverage panel; see security-reports/2026-08-15-coverage-panel.md"`.
