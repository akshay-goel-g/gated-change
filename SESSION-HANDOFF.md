# Session handoff — gated-change

<!-- Where we are RIGHT NOW. Rewritten in place, ~100 line cap. Over it:
     done → delete · decision → INTENT-LOG.md · what broke → LEARNINGS.md -->

**Last updated:** 2026-10-15 · **Branch:** `master` = `12db3f7`, PUSHED to the private repo `akshay-goel-g/gated-change` (3 commits:
`c8994f3` root, `b62617e` license, `12db3f7` the G7 skip record). Code = round 29 plus the mechanical rename (see item 5); full
suite **1380 passed, 0 failed** on the renamed tree (`/d/WinTemp/full-suite-rename.log`). `origin` points at gated-change.
**One writer at a time**: run `git status` and `git log -3` first. **Start at item 5.**
Decisions and the reasons behind them are in `INTENT-LOG.md` (entry 2026-10-14); the working plan is `ACTION-PLAN.md`.

0. **The E1-E11 review is CLOSED by the owner (2026-10-14), not passed.** One change `compliance-e1-e11-correctness`
   (`BASE=cdd2e59`). Residue accepted as **R-011** (`project/risks.md`) plus R-009 (13), (14): do not re-report or fix it
   without a decision. The review loop found a new instance of one class every round since R19.
1. **Gate record** (`ledger.jsonl`): G1 pass R22; G5 pass R19; G6, G8 not re-run since R19 (both FAIL); **G7 FAIL at every round
   it ran (R19, R23-R29)**; G4 failed R20-R26, passed R27, FAILED R28 and R29 (2 blocking each). `ledger.sh compliance --tier T4
   --round 29` = INCOMPLETE, exit 1 (G4 G6 G7 G8). Rounds 26-29 detail: CHANGELOG "Unreleased".
2. **R-011 residue, in one line each:** hook base from `origin` whatever remote is pushed to (`templates/pre-push:215`);
   operator `BASE`/`BASELINE` resolved by name; a truncated or NUL-ended ledger is read by `compliance`, dropped by the
   dashboard; whitespace-only `n/a` note (`ledger.sh:1536` vs `app.js:616`); CR in a commit subject breaks the dashboard;
   `diff.relative=true`; ledger default path depends on cwd; sha1-only hook constants; missing-library exit codes.
3. **The first push is DONE (2026-10-15).** The pre-push hook blocked it (13 trust files, no G7 report names the tip); the owner
   overrode it with `--no-verify` after the ledger row `public-release-fresh-root` G7 `skipped` (`12db3f7`). **No threat-gate round
   was run on those files**; G7 stays FAIL/skipped on record. The installed hook now matches `templates/pre-push` (`--force` done).
4. **Git identity is correct** (`akshay-goel-g <akshay.goel.g@gmail.com>` on all 3 commits). It was `t`/`t@e` in this clone's
   `.git/config` earlier; re-check with `git config user.name` before committing, something rewrote it before (suspect the suite).
5. **NEXT.** DONE: I-0 to I-8, J9-J16 (Shield `LICENSE`, `NOTICE` "Akshey Goel, 2026"), A3 (`.gitignore`), A4 (personal paths and
   the sample project name scrubbed), the paid-path trace scrub (stubbed `security-reports/2026-08-13-ce255b2.md`, ledger notes,
   two LEARNINGS entries, two 1.0.0 CHANGELOG bullets), and a **full rename `pipeline-kit` -> `gated-change`** including the
   `SELF:` sentinel in `project/surfaces.conf`, `tools/reconcile.sh`, `tools/status.sh` (a T4 change with no gate round).
   NOT done: **I-9 vendor side (owner only): unpublish the product page, revoke tokens, handle the buyer list**; rename the
   local folder (still named `pipeline-kit`) when no session uses it; **K** marketplace (needs D5 path split, D8 wrapper); **L**
   donation (deferred). Offline bundles (copy them yourself, never push): `../pipeline-kit-pre-scrub.bundle`,
   `../pipeline-kit-master-6c748c4.bundle`, `../pipeline-kit-ci-to-codebuild.bundle`.
   The OLD repo `akshay-goel-g/pipeline-kit` still exists by the owner's choice: private, old history; keep private, never push
   the new master there. Experiments 003/004 still describe another project, the name replaced by `sampleapp` (ownership of
   the content itself, J6, was not settled).
6. **Decided 2026-10-13/14 (reasons in INTENT-LOG):**
   - **History: fresh** (orphan commit, new private GitHub repo `gated-change`; old history only as the offline bundles). Drops the
     shas the gate rows bind to (old rows read "unreachable commit"). Done 2026-10-15.
   - **License: PolyForm Shield 1.0.0**, replacing the previous copyleft license. Goal: use freely in own projects; no copy-and-sell or competing
     product. Source-available, never "open source". Patent is out of scope (a licence only grants use; filing is separate and
     public release can end patent rights; the owner dropped that question 2026-10-14). Nobody else uses the kit. Applied as a separate second commit after the root (`b62617e`).
   - **Marketplace (K): own marketplace first, Anthropic directory second.** Directory facts: paid claude.ai plan; repo public
     before the listing goes live; each version scanned, a person reviews a new listing; Terms make the developer indemnify
     Anthropic and let it delist at any time; Policy and Terms say nothing about licence type (untested in practice). Plugin
     folder must be self-contained: files over 256 KiB are held (`dashboard.html`, `ledger.jsonl`, `tests/run.sh`), hook
     scripts must use `${CLAUDE_PLUGIN_ROOT}`, git hooks are not a plugin component, README must disclose that the installers
     edit `.claude/settings.json` and `.git/hooks`. Needs D5 (path split) and D8 (wrapper).
   - **Donation (L): deferred** until J and K settle. Policy bans ads and "sponsorships" (4C); ask before adding a link.
   - **Audit H1-H8 (read-only, nothing done):** H1 attribution: 2 git identities and no `actor` field in the ledger; H4 no
     dev/test/acceptance/prod model: use declared actions `uat-deploy`/`prod-deploy` plus an `env` field; H5 no env preflight,
     `MATRIX_ROUTER`/`MATRIX_LOCK` env-settable, `PIPELINE_MODEL` unset on 14 rows; H6 no stress or concurrency test, ledger
     append is not atomic; H7 own gates can be added (`06-extending.md`), disabling means editing the hash-locked matrix:
     propose a `project/gates.conf` overlay; H8 new Claude skills are executors inside gates, register in `capabilities.conf`.
7. **Review protocol (only if the loop is reopened):** fresh opus `general-purpose` background agents, scratch clone
   `/d/WinTemp/g<N>r<round>`, filtered tests, no `pkill`; G7 and G4 first, then G5, G6, G8; G6/G7/G8 BLIND (not the handoff,
   `INTENT-LOG.md`, `LEARNINGS.md`, `ledger.jsonl`, `dashboard.html`, `security-reports/`, `specs/`, commit messages); G7 =
   grep-driven sweep of every git call taking a variable. Log: `ledger.sh add --change compliance-e1-e11-correctness --tier T4
   --round N --commit <full sha> --confidence fresh --model claude-opus-5-5 --gate G? --outcome pass|fail --finding
   "sev::file:line::claim" ... --withhold-breached true|false` (severity `blocking|minor|info|out-of-scope`; no backslashes in
   a claim, put the command in a script file).
8. **Disk:** D: filled on 2026-10-14 (a 74 GB `.output` of a dead background Python session under `D:\WinTemp\claude\...\tasks\`,
   plus ~340 scratch clones); cleaned, 77 GB free. "No space left on device" in a suite log is not a code failure.
9. **Accepted gaps, do not re-report:** `project/risks.md` R-008, R-009 (1)-(14), R-010, R-011; dashboard has no recorded-reason
   check; `update-kit` overwrites local `core/` edits; `test_surfaces_do_not_fire_on_words_inside_filenames` flakes when the
   temp path contains "T4".
10. **Design facts a reviewer will probe:** a lineage starts at a change's first round-1 route WITH a base and at every round-1
    route with a base marked `"restart":true`; a route with no base never starts one; a repeat firing of a declared action is
    round 1 and marked; "after" = ledger position; a fail is cleared only by a later pass that is bound; `skipped`/`n/a` never
    clear a fail; `tests/dash-gate-states.js` cross-checks the dashboard against `compliance`.

## Deferred / queued
1. **CI**: Actions disabled for non-payment since 2026-09-08 (pushes fail in ~8s, not a code failure). Last run 2026-10-05:
   ubuntu and windows green, macOS 20 failures in `tools/lib/matrix.sh` (B1). `gh run list` to re-check.
2. `cmd_add`: `--lane`/`--model` closed-set guard; missing `--outcome` defaults to `pass`; `--severity` unvalidated; R-006
   (review by 2026-11-03). Unfiled: `gates`/`report` exit code on an empty ledger; `ledger.sh --help`; stray gate id accepted
   as mandatory; `coverage_never_run()` fails open on a router load failure.
3. Tools are slow here (compliance 35-95s, status.sh 45-60s, dashboard.sh ~3-4 min, a push ~5 min, the suite 1-4h), no progress output.

## Working notes
- **Editing:** use the Edit tool; a heredoc with backslashes is mangled by the tool layer (write script files). Do not edit
  files while the full suite runs; stop only your own stale runs. Mutation checks: Edit, run the filtered test, restore.
- **Tests:** `bash tests/run.sh '<pattern>'` (`\|` alternation; a broad filter needs `run_in_background`); drive the real tool
  (`rec`, `led`, `status_run`, `hook_stdin`); `newrepo` installs the kit in its OWN commit.
- **R0c hook:** editing a T3/T4 file prints "re-enter the pipeline": expected while a round is written; route on commit.
- **Commit hygiene:** code/docs/tests in one commit with the suite result in the message; ledger rows in their own commit;
  this file only when asked; one workstream per commit. `origin/master` can move: `git fetch` first.
- **Clone-checking history:** use `git clone --no-local`; a plain local clone copies unreachable old objects too.

## Known concerns (pre-existing)
- Dashboard 821-1000px band: `max-width:820px` crushes `#center` with an open drawer (P1-11 residue).
- `ledger.jsonl` is CRLF on this checkout. `dist/` is empty (the stale dogfood artifact was deleted).

---

<!-- Not here: what was asked -> INTENT-LOG.md · what broke -> LEARNINGS.md · gate results -> ledger.jsonl -->
