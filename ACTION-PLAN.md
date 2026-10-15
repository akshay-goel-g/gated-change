# Action plan: public release, hardening, multi-surface fit

Status: **nothing started.** Written 2026-10-06 from two Opus subagent code reviews plus
the original competitor comparison. Findings marked *inferred* were not tested.
Commit each workstream separately (A, B, C, D) per the scope-separation rule.

Effort: S = under half a day, M = about a day, L = several days.

---

## Decisions needed before starting

1. **Visibility and history.** Publish with fresh history, or rewrite history to drop `releases/` and the download installer?
   Fresh history is simpler and loses the 120+ gate-run ledger story unless `ledger.jsonl` is carried over.
2. **Which tracked files stay public:** `LEARNINGS.md` (113 KB), `INTENT-LOG.md` (50 KB), `SESSION-HANDOFF.md`, `ledger.jsonl` (506 KB), `dashboard.html`, `experiments/`, `security-reports/`, `specs/`.
   Experiments 003/004 name another project (`sampleapp`).
3. **License.** The previous copyleft license stays if the goal is resume and visibility. Revisit only if you sell it. **Reopened 2026-10-13: the download path is being removed completely, so this is now open. See section J.**
4. **Scope of surface support.** Recommendation: Claude Code plus Agent SDK. Messages API optional. Managed Agents deferred (see D).

---

## A. Pre-public cleanup (S-M) - do first

| # | Item | Why |
|---|---|---|
| A1 | ~~Commit the staged deletions of `releases/1.0.0/*`, `tools/<removed-installer>`, `tools/<removed-packer>`~~ **Done in `024c148` (2026-10-07)**; on `origin/master`, tree clean apart from this file | Still in **history**. `SNAPSHOT.md` documents the demo secret `demo-pass`, so the tarball is effectively public. No real secrets found in history. The history decision (A2) is still open |
| A2 | Decide history: fresh vs `git filter-repo` on `releases/` and the installer | Deleting in a new commit does not remove them from history |
| A3 | Add `.claude/settings.local.json` and `.claude/worktrees/` to `.gitignore` | Ignored today only by the user-global ignore file and `.git/info/exclude`, which do not travel with the repo |
| A4 | **DONE 2026-10-14.** Scrub the author's machine paths and the name of the project the experiments ran on (now `sampleapp`) | 28 tracked files edited in one pass; `ledger.jsonl` and `dashboard.html` included; `sampleapp` replaced by `sampleapp`, drive paths by `D:/work`. A later `--freeze` rewrites `tools/lib/matrix.lock` with the current absolute path again |
| A5 | Check commit identity | All commits are `akshay-goel-g <akshay.goel.g@gmail.com>`; committer is sometimes the noreply address. Decide if the real email should be public |
| A6 | Make repo public | Standard GitHub-hosted runners are free for public repos, so CI cost goes away |

Verify: `git grep -n -i -E "<drive-folder>|<username>|<project-name>"` returns nothing (done 2026-10-14).

## B. Quality fixes (S-M)

| # | Item | Effort | Evidence |
|---|---|---|---|
| B1 | **Fix the 20 macOS test failures** (`test_matrix_load_refuses_*`, `test_matrix_freeze_regenerates_a_working_reference`) | S | Latest CI run 37315886418 (2026-10-05): Windows and Ubuntu pass, macOS 893 pass / 20 fail. BSD divergence in `tools/lib/matrix.sh`, which also has uncommitted changes. Check those first, since they may be partly work in progress |
| B2 | `r0c-post-edit.sh` fires on files outside the repo | S | Matches `(^|/)tools/hooks/` on the absolute path (r0c:71, :97). Strip the repo root first and exit 0 for outside paths |
| B3 | `install-hook.sh` idempotency bug | S | :59-63 compares the raw template to the sed-modified copy, so a re-run without `--force` always says "different hook exists" whenever PREFIX is not `.pipeline` |
| B4 | `ledger.sh` change-name regex | S | :1094-1106 puts `$change` unescaped into a regex, so `.` matches any character |
| B5 | Pin `actions/checkout` to a SHA | S | Currently unpinned |
| B6 | Registry/map staleness check in `status.sh` | S | `mine-registry.sh:115` stamps date and commit count but no HEAD sha; nothing warns when the registry is older than HEAD. Use `git log -1 --format=%H -- file` and `git rev-list --count <that>..HEAD`, not the mtime-based WATERMARK in `check-refs.sh:190-222` |

## C. Make the gates real (M each)

| # | Item | Why it is worth doing |
|---|---|---|
| C1 | **Gate evidence is not validated.** `compliance` never reads `evidence` or `action` (ledger.sh:1210-1508). A pass with zero findings and `--confidence fresh` satisfies a mandate with no citation | This undercuts the headline claim, so fix it before leading with that claim. Design below |
| C2 | **Stop hook running `compliance`** for the active T3/T4 change | The Claude hook is advisory (PostToolUse exit 2 cannot block). The first real gate is pre-push, after a whole session of ungated T4 work. Design below |
| C3 | Ledger tamper-evidence: `prev` sha256 per line plus `ledger.sh verify` | `emit()` is a plain append (ledger.sh:295-350); the `kit` field is a CRC32 and does not chain records |

**C1 design.**
- New `commands.conf` parser, since nothing parses or runs it today. Key by `KIND::TARGET`; do not use bare names, because TARGET labels contain spaces and slashes.
- `ledger.sh add --evidence-cmd KIND::TARGET`: refuse the `MANUAL::<why>` sentinel; run via `bash -c "$cmd"` from the project root with no eval; record exit code, output sha256 (sha256sum/shasum/openssl fallback), commit, and the conf-line hash.
- Add a **T4 row in `project/surfaces.conf` for `project/commands.conf`**. Editing what evidence runs currently routes below T3.
- Note the trust boundary: restricting to declared names moves trust into commands.conf, it does not remove it.

**C2 design.**
- Arm it only when a T3/T4 route exists without a compliant result. Allow the stop otherwise.
- Honor `stop_hook_active` (verified in the hooks docs), cap attempts, and expect Claude Code's own cap of 8 consecutive continuations (raisable via `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`).
- Block with `{"decision":"block","reason":...}` on stdout. spec-flow does the same, using phase arming, sha dedupe and `MAX_ATTEMPTS=5` as its guards rather than `stop_hook_active`.

## D. Multi-surface support

### Verdict, from the second subagent review

| Surface | Fit today | Effort to make true | Main limit |
|---|---|---|---|
| Claude Code | **Native** (hook verified live on Windows) | S-M | Default subagents load CLAUDE.md, auto-memory and a git-status snapshot, so the "fresh" reviewer is not clean |
| Agent SDK | **Works with a small adapter** | M | Project `.claude/settings.json` hooks load only from `<cwd>/.claude/`, so cwd must be the repo root. `omitClaudeMd` is TypeScript-only and version-gated |
| Messages API | **Needs an adapter, partial gate coverage** | M | No shell or files. Cannot cover G3 Craft, G5 Proof or G8 Dogfood. Best for G2, and partly G4, G6 and G7 |
| Managed Agents | **Partial** | L | Beta, dated header. No Claude Code-style hooks found *(absence not confirmed)*. `.git/hooks` not in a clone. The tracked ledger will conflict across parallel sessions, and ephemeral sessions can lose unpushed lines |

Independence caveat that applies to every row: "fresh" means fresh context, not a different model. Nothing enforces cross-model review.

### Honest wording today

> Built and tested with Claude Code (subagent-based fresh-session gates, PostToolUse hook). The routing, ledger and compliance tools are plain bash with no agent dependency, so any runner that can execute shell and call `ledger.sh` can record gates. Adapters for the Claude API and Agent SDK are not yet included.

Do **not** write "works with Claude Code, Messages API, Agent SDK and Managed Agents" until D3 and D4 exist and are tested.

### Work items (priority order)

| # | Item | Effort |
|---|---|---|
| D1 | `.claude/agents/pipeline-gate-*.md`: `omitClaudeMd: true`, read-only tools, model from each card's `model:` line; document the CLAUDE.md and memory leak in default subagents | S |
| D2 | `project/models.conf` (tier to model ID) and a findings JSON schema matching `--finding`. Do not hard-code Haiku 4.5; its retirement is "not sooner than 2026-10-15" | S |
| D3 | Agent SDK orchestrator `tools/sdk/run-gates.ts`: `reconcile.sh`, then `ledger.sh compliance` for mandated gates, then one isolated `query()` per gate with `settingSources: []`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, `dontAsk`, then `ledger.sh add` | M |
| D4 | Messages API adapter `tools/gate-api.sh`: structured outputs for findings, prompt caching for the card, token counts passed to `--tokens-in`. Document the gates it cannot cover | M |
| D5 | Path split so a plugin can work: one `PIPELINE_DIR`/`PROJECT_DATA` env for `project/`, ledger and security-reports, separate from `KIT` code. Fix ledger default mismatch (`ledger.sh:153` is CWD-relative, `status.sh:44` is KIT-relative) and `mine-registry.sh:22` | M |
| D6 | PreToolUse hook on the `Agent` tool that rejects gate briefs containing more than the card path and inputs. *Inferred* that `tool_input.prompt` is visible to the hook; test first | M |
| D7 | Ledger single-writer or `ledger.jsonl merge=union` in `.gitattributes`, plus a server-side required check running `compliance` | M |
| D8 | Plugin wrapper: `.claude-plugin/plugin.json`, `marketplace.json`, `hooks/hooks.json` (exec form with `${CLAUDE_PLUGIN_ROOT}`), skills wrapping reconcile / compliance / status / install-hook. The pre-push hook stays a separately installed copy, since git hooks are not a plugin component. **Needs D5 first**, otherwise the hook reads the kit's own `surfaces.conf` in every user project | M-L |
| D9 | Managed Agents: gate cards as `.claude/skills/`, orchestrator-written ledger, ephemeral-state guide | L |

**Reasons not to over-invest (from the review):** the Agent SDK is Claude Code run programmatically and Managed Agents is the hosted version, so Claude Code plus SDK cover most real users. Adapters add API churn and need live API calls that cost money in CI. The kit's value is the process, not the runner. Multi-surface support adds reach, not independence. Suggested stopping point: D1, D2, D3, D5, D8. Treat D4 as optional and D9 as deferred.

---

---

## E. Correctness bugs found by the cold-start dogfood run (do before C and before any public claim)

Source: Opus subagent followed the README in a scratch copy (full report:
the dogfood report (`dogfood-report.md`, in an old session scratchpad),
32 findings; trimmed transcript T1-T17 inside). Reproduced by the subagent, not yet re-run by me.
These matter more than C1: they let `compliance` say "ready" when a change is not, which is the
kit's headline guarantee.

| # | Bug | Effort |
|---|---|---|
| E1 | **DONE** (4375546; reworked after round-1 gates, see Status) · `compliance` lets an earlier-round PASS hide a later blocking FAIL. Reproduced: G7 fails at round 2, still exits 0 at T4. Fix how the outcome is picked across rounds | S |
| E2 | **DONE** (4375546; reworked after round-1 gates, see Status) · `compliance --tier` is taken on trust. A change reconciled as T4 passes with `--tier T1`. Check it against the reconciled tier in the ledger | S |
| E3 | **DONE** (4375546; reworked after round-1 gates, see Status) · Gate records are not tied to the change's commits. Gates logged before the change existed satisfied it. Bind entries to a commit range or sha | M |
| E4 | **PARTIAL** (58abece, reworked; the hook still auto-commits `dashboard.html`: documented, not removed) · Pre-push hook checks `HEAD`, so committing the security report moves `HEAD` and re-blocks the push. It also commits `dashboard.html` on its own | M |
| E5 | **DONE, revised in round 10** (58abece; the conflict on every parallel-branch merge is now intended, see the bracket) · `ledger.jsonl`: uncommitted it blocks `git checkout`; committed it conflicts on every parallel-branch merge. Document "commit the ledger" (`merge=union` was tried and REMOVED in round 10: it made verdicts depend on merge direction, R-008) | S |
| E6 | **DONE** (58abece) · `update-kit.sh` fingerprints only `tools/*.sh`, so upstream `core/` changes (including the gate matrix) are never applied | M |
| E7 | **DONE** (58abece) · `mine-registry.sh` writes to `./project/` at the repo root; Quick start step 3 `cp -r` nests into `project/project/` if it exists | S |
| E8 | **PARTIAL** (58abece; unknown flags, `--round`, `--found-by` done; unregistered gate ids only WARN; free-text `location` not validated) · Input validation: `reconcile.sh` silently accepts unknown flags; `ledger.sh` accepts gate `G9`, any `location` text, any `--found-by`. `ROUND` is an env var and `--round` is silently ignored | S |
| E9 | **DONE** (58abece) · Install step 1's `rm` list omits `ACTION-PLAN.md`, so it would ship into a user's `.pipeline/`. Add it to the list, or keep this file out of the repo | S |
| E10 | **DONE** (58abece; reworked after round-1 gates) · `status.sh` exits 1 right after "You are done", listing all pre-install history as unrouted. Add a baseline/"since install" cutoff | S-M |
| E11 | **DONE** (58abece) · Quick start never says to commit `.pipeline/` or to work on a branch | S |

Note: the C2 Stop hook is only as good as `compliance`, so finish E1-E3 before building it.

**Status 2026-10-07:** E1-E3 landed in `4375546`, E4-E11 in `58abece`. Change
`compliance-e1-e11-correctness` then ran G1/G4/G5/G6/G7/G8 with fresh-context subagents at round 1: **all six failed**
(logged in `ledger.jsonl`; findings were real). Reworked in round 2 (uncommitted until the gates re-run):
- **E3 base is now RECORDED**, not recomputed: `reconcile.sh` passes `--base <merge-base(BASE,HEAD)>` to `ledger.sh route`;
  compliance reads the earliest route entry's `base`. The recomputed merge-base flipped every pass to UNBOUND after a merge
  and on trunk-based work. Old route entries have no `base`, so those changes skip binding with a NOTE. Not strict at the
  base: a pass logged AT the base commit still counts, because pre-build work (G1) lands exactly there and the two cannot
  be told apart (G1 noted this gap; it is accepted, not fixed). An unreachable commit sha now prints a per-gate NOTE.
- **E2 uses the LATEST route entry's tier**, like the dashboard, not the max (the max made a downward correction unreachable).
- **E1** also voids a pass when the latest outcome is `skipped` (the hook's own advice logs `--outcome skipped`); the
  dashboard JS mirrors it. **E4**: a report must name a commit that CONTAINS every trust-touching commit in the push
  (merge commits judged against each parent), not "newest by date". Decision on the hook's dashboard auto-commit: **kept
  and now documented in the README** (G8 hit it unannounced on a first push; G1 asked for sign-off, still open).
- Tests added for the merge/trunk-based/unreachable/skipped/latest-tier cases, the stdin path, merge-resolution edits and
  every `coverage_baseline` branch; E6/E7/E9 tests rewritten (G5 showed all three could not fail). `merge=union` is
  recorded as risk R-008 (loses chronology and the conflict signal; accepted).
- **Round 2 (commit `6d2317c`): all six gates failed again.** Narrowed round 3 (uncommitted): E1 back to fail-only
  (a later `skipped` records the hook override and must not revoke a pass - it re-failed released changes);
  pre-push judges merges with `diff-tree -c` so a `--no-ff` merge of a reviewed branch passes; E10 baseline pinned in
  `<kit>/.install-base` while the kit is uncommitted (it returned the moving HEAD, so later work was never counted) and
  repo roots compared through git (MSYS mount aliases); the tier floor ignores route entries without `--base`
  (reconcile-written only); E3 got an UPPER bound (a pass must sit under HEAD or a recorded route commit, so a sibling
  branch's passes no longer count), the LATEST base governs (reused change names), `--commit` must be hex, and names are
  matched JSON-escaped. Left as known risks, not fixed: pre-push speed with very many sha-like tokens in reports,
  an unknown remote sha failing open, multi-ref pushes reading the
  checked-out tree's reports, `--severity` not validated, `merge=union` ordering (R-008, R-009).
- **Rounds 3-5 (commits `b6e56b9`, `ff3d8b9`, `aee026a`) and round 6 (`60bcd9e`):** each round's six gates still found real defects, narrowing from structural to edge cases. Round 6 closes: tier floor = highest tier among reconcile-written rows of the current lineage (a post-push narrower diff no longer lowers it); pre-push judges a merge by whether it produced what a correct merge of its parents would (closing both merge-revert repros without flagging reviewed `--no-ff` merges), fails CLOSED when git cannot diff, and matches non-ASCII trust paths; `reconcile.sh` refuses an option with no value (exit 2); a second round-1 route says it starts a new lineage. The G4/G5 round-5 reviewers were killed by a usage limit and never reported; no round has yet had all six gates pass. Round 6 (G1 pass; G4-G8 fail) drove round 7 (`d34b58b`): gate results are scoped to the current lineage; pre-push lists renames at both ends and reads paths with `-z`; `reconcile.sh`/`compliance` refuse a flag where a value belongs; the untested merge-check branches are pinned; squash-merge binding is recorded as R-010. Round 7 (G1 pass; G4-G8 fail) drove round 8 (`0f24af0`): a lineage restart is ALWAYS refused without `--restart-lineage` (never guessed from what is on record), the dashboard is lineage-scoped, the router/status see renames, option values that look like the next flag are refused. Round 8 (G1, G6 pass; G4, G5, G7, G8 fail) drives round 9: a restart is an explicit `"restart":true` marker on the route row, so a union merge of two ledgers cannot start one; the dashboard uses the same tier floor as `compliance`; `--round 0` is refused; the value guard only refuses a value that IS an option (`--word`); `report` counts one row per distinct reconciliation; the install commit is counted when it also carries project work; the weak tests G5 found are fixed. Round 9 (G1, G4, G6 pass; G5, G7, G8 fail) drove round 10: every blocking finding was one problem -- `merge=union` interleaves two branches' ledger lines, so a newer FAIL read PASS, a restart marker from one branch lowered another's floor, and a sibling's pass cleared this branch's FAIL -- so the union merge is removed (a conflict is the signal), R-008 records what remains, and the test gaps and doc errors the reviewers found are fixed.
- **Rounds 10-13:** round 10 removed `merge=union` from the ledger (a conflict is now the signal). Rounds 10 and 11
  each failed on blocking findings in the T4 files (round 10: G6, G8; round 11: all six). Rounds 12 and 13 fix them with a
  regression test per fix: declared actions start their own lineage, a fail is "after" a pass by ledger position,
  skipped / n/a rows no longer anchor unrouted work (status, dashboard), the install-commit pin survives the kit
  commit, merged gated branches are both anchors (merge-aware range), the kit's own files are not project work, and the pre-push report-token and pathspec hardening.
  Gating was split by review scope into two changes, `compliance-e1-e11-correctness` and `coverage-anchor-baseline`
  (`coverage.sh`, `status.sh`, `dashboard.sh`, the dashboard coverage panel and their tests).
- E1-E3 DONE labels are accurate only for the mechanisms as described in CHANGELOG: E3 binds only when the change was reconciled with `--log` (it needs the recorded `base`), and passes at the base commit still count.
- Other decisions that differ from the table: E8 *warns* on an unregistered gate id (G9+ is legal per
  `core/06-extending.md`) and leaves free-text `location` alone; E10 is a behaviour change (pre-install history no
  longer counts as unrouted; `BASELINE=none` restores it).

## F. README gaps: dashboard, states and fixes, first-run path

| # | Item | Effort |
|---|---|---|
| F1 | **State glossary** with STATE / meaning / cause / how to fix, for dashboard labels, `status.sh` and `compliance` output. The subagent built all three tables in section B of the report (about 30 states; README documents about 6, such as INCOMPLETE and UNDER-CLASSIFIED). Start from those tables and re-verify each fix command | M |
| F2 | **Dashboard screenshot plus a legend** in the README. Capture from a seeded example project, not this repo (it contains personal paths) | S |
| F3 | Fix dashboard inconsistencies the subagent saw: shows "Fail" for rounds that `compliance` passes; "Fail" and "nothing blocking remains" on one page; a G7 skip with no tier renders as Success; the escape rate counts a "baseline" escape; prints `bash tools/...` paths that are wrong in an installed kit; takes 27-34 s on Windows | M |
| F4 | **60-second demo block** at the top: six commands, about 24 s on Windows: copy `examples/surfaces/web-app.conf`, change `src/auth/login.js` on a branch, `CHANGE=fix-login reconcile.sh T1 --log` (UNDER-CLASSIFIED), then `compliance --tier T4` (INCOMPLETE). Exact block is in report section A | S |
| F5 | "Your first change" section plus a full first-session transcript, ending where Quick start currently stops | M |
| F6 | **Glossary** for R0a-R0d, G1a, "Axis C" (printed by `compliance`), Harvest, Adapt, tiers, gates, matrix, ledger | S |
| F7 | Fix the examples: walkthrough step 5 never creates round 2 (needs `ROUND=2`); `cp ... docs/` fails because `docs/` doesn't exist | S |
| F8 | Time claim: replace "30 minutes" with a measured figure. Scripted run was about 2 minutes; a human reading the 1080-line README and writing surfaces rules is about 45-60 minutes | S |
| F9 | Consider moving reference material out of the 1080-line README into `docs/`, keeping the README as problem, demo, quick start, glossary | M |

## G. Showing the strengths honestly (reliability, effort reduction)

Numbers from the repo's own `ledger.jsonl` as read by the subagent. Re-run `ledger.sh report`
before quoting any of them; they are self-reported by one team of one.

| Candidate headline | Number | What it can support | What it cannot |
|---|---|---|---|
| Gate runs | 352 (252 fresh) across about 45 changes | Real, sustained dogfooding. README says "120+ across a dozen", which is stale | Quality of the gates |
| Blocking findings caught | 88 rated blocking (81 from fresh runs) across 24 changes; 87 failed gate runs | Gates do find things pre-push | That they would have escaped; no escape was ever recorded |
| Routing miss rate | 15% (9 of 59 reconciliations under-classified) | Why re-deriving the tier from the diff is needed | That routing beats reviewing everything |
| Pre-push overrides | 19 of 77 G7 entries, several "bootstrapping deadlock" | Honest limit to publish | |
| Cost per gate run | median about 101k tokens | A cost figure | Effort reduction |
| Tests | local 877 passed, 0 failed; last CI 906 ubuntu / 905 windows; macOS 20 failing | Real test suite. **README says "911", which matches no run** | Reliability of the kit itself |
| Experiments 001-004 | n=4 unblinded pairs, one project, different features per arm | "In all 4 gated arms a verify gate changed the code before merge, at roughly 100-200 gate-minutes or 0.5M tokens per change" | "Reduces defects" or "reduces effort". Both stay "Unproven". `003/result.md` misstates n |

| # | Item | Effort |
|---|---|---|
| G1 | Replace the stale "120+ gate runs" and "911 checks" lines with numbers generated from `ledger.sh report` and a real test run, with the date | S |
| G2 | Add a short "Evidence so far" section using only the rows above and their stated limits. Never call "0% escapes" a result; none were ever recorded | S |
| G3 | Fix `003/result.md` n | S |
| G4 | **Human-effort measurement.** Only 15 of 352 runs recorded `--minutes`, so there is no effort data at all. Smallest test: 10 changes, each run with the routed gates and with all eight gates into separate ledgers, `--tokens` and `--minutes` required, then compare cost and any blocking findings the routed set missed. Use `tools/benchmark/`. Update the Status table only with what it shows | M-L |
| G5 | Make `--minutes` required (or loudly nagged) so future runs build the dataset | S |

---

## H. Audit findings, 2026-10-13 (read-only audit; nothing below is done)

Source: a read-only audit of the working tree plus `git log`. Runtime behavior was read from
code, not executed; the full suite was not re-run.

| # | Finding | Evidence | Action | Effort |
|---|---|---|---|---|
| H1 | **Who made a change is not recorded in the ledger**, and git attribution is split across two identities | 244 commits as `akshay-goel-g`, 107 as `test <test@example.com>` since 2026-09-09. Cause: `user.name=test` in the repo-local `.git/config` (global config says `akshay-goel-g`). Ledger keys carry no actor; `model` is `unset` on 14 of 472 gate records | (a) Fix the local git identity before any publish. (b) Add an auto-detected `actor` field written by `ledger.sh` (same pattern as `commit` and `kit`; old lines are never backfilled). (c) For tamper-evidence use C3 (hash chain) or signed commits; an actor field alone is accountability, not proof | S + M |
| H2 | License review | See section J | Decide, then change in one commit | S |
| H3 | Donation / funding | See section L | **Deferred** until J and K are settled | S |
| H4 | **No dev / test / acceptance / production model.** Only `TARGET` + `DEPLOY` (clean local instance), declared `ACTION` events, the hotfix lane, and the error contract in `07-failure.md`. No `env` on any record; `EVIDENCE` is checked for presence only; post-release signal is only `escape --found-by` | `core/14-phases.md:76`, `core/01-router.md:250`, `core/07-failure.md` | Use the existing R0d mechanism: declare `ACTION::T3::uat-deploy` and `ACTION::T4::prod-deploy`, put per-environment exit criteria in `project/`, add an optional `env` field to route and escape records. Add an acceptance-vs-production error path to `07-failure.md`'s contract. Caveat: R0d fires only when someone invokes it | M |
| H5 | **No environment preflight.** `status.sh` does not report which env vars are set; `PIPELINE_MODEL` unset only warns; `MATRIX_ROUTER` and `MATRIX_LOCK` are env-settable (a forged router + lock pair would bypass the integrity check; read from code, not run) | `tools/ledger.sh:479,799`, `tools/lib/matrix.sh:33-36`, `tools/status.sh` | Add an env/preflight section to `status.sh`; decide whether the two matrix overrides need a test-only guard. Pairs with D5 (single `PIPELINE_DIR`) | S-M |
| H6 | **Stress and concurrency are untested.** One delta-cost test only (`tests/run.sh:863`). The ledger append is documented as not atomic (`tools/ledger.sh:353`) while the design hands gates to parallel subagents (D7 overlaps) | `ledger.jsonl` is 697 KB / 571 lines and read by bash+grep per call; no test for N parallel `ledger.sh add` or a 10k-line ledger | Add (1) a parallel-append test, (2) a ledger-scaling test, (3) fleet-dashboard size test. Classic load testing and the library "Load" gate are not applicable to a CLI | M |
| H7 | **Gates: add works with friction; there is no disable.** Schema in `06-extending.md`, validated by `dashboard.sh --check`; `ledger.sh` warns on `G9+` not in the router table. The matrix is in a "do not edit" core file and hash-locked; `matrix.sh:155` validates only `G1..G8` (whether a `G9` row loads was not run). Disable = edit a cell and re-freeze, or the retirement rule; G7 and G4 at T3+ are exempt | `core/06-extending.md`, `tools/lib/matrix.sh`, `tools/lib/matrix.lock` | Add a `project/gates.conf` overlay (add / disable with required reason and expiry, logged to the ledger, hard gates not disableable). First test whether a `G9` row loads. Keep the lock: it exists so a downgrade cannot be silent | M-L |
| H8 | **Adopting new Claude skills and releases.** A skill is an executor inside a gate, not a replacement for one | Skills visible in session: `cso` (G7), `code-review` / `review` (G6), `qa` / `browse` / `canary` (G8, post-deploy), `benchmark` (Load), `careful` / `guard` / `freeze` (hotfix lane), `schedule` / `loop` (exception-audit cadence in `govern.md`), `context-save` (handoff) | Register each in `project/capabilities.conf` (`09-capabilities.md`); route through `11-evolution.md` (evidence, backtest, budget); compare with `ledger.sh gates` using `--model`; add a `tool`/`skill` field so a run records what executed it. Keep gates fresh-context and blind: a skill run in the author's session is `confidence: low` | S-M |

## I. Retired vendor: remove completely (decided 2026-10-13)

Already removed from the working tree in `024c148` (acquisition path, `releases/`, `tools/<removed-installer>`,
`tools/<removed-packer>`). What remains:

| # | Remaining trace | Where |
|---|---|---|
| I1 | Prose mentions | `INTENT-LOG.md` (lines 13, 59-64, 82-117, 148, 196-252), `LEARNINGS.md:549-590`, `security-reports/2026-08-13-ce255b2.md`, this file |
| I2 | Data mentions | `ledger.jsonl` (append-only by the kit's own rule), `dashboard.html` (regenerated from the ledger) |
| I3 | **Git history** on `origin/master` (up to 2026-10-06 `cdd2e59`; 45 local commits are unpushed): `releases/1.0.0/*` including the encrypted user bundle and `<removed-installer>`, commits `ce255b2`, `9b801d7`, `024c148` | `git log --all -i --grep=<vendor>` |
| I4 | Untracked, ignored | `dist/pipeline-kit-v9.9.9-dogfood.tar.gz.enc` and its SHA file (ignored by `.gitignore`, but still on disk) |
| I5 | Other refs and worktrees (found 2026-10-13) | branches `ci-to-codebuild` (local and `origin`) and `claude/laughing-booth-8f1fe4`; worktree `.claude/worktrees/confident-hawking-50cb3b` (detached at `fc0a726`, still holds `releases/1.0.0`, `<removed-installer>`, `<removed-packer>`); three `agent-*` worktree directories. No tags, no stashes |
| I6 | Counts | 28 commits mention it in diff or message; 7 commits touch `releases/*`, `tools/<removed-installer>`, `tools/<removed-packer>`; 8 `ledger.jsonl` lines; 1 hit in `dashboard.html`; `git filter-repo` is **not installed** (Python 3.14 is, so `pip install git-filter-repo` works) |
| I7 | Outside the repo (the user's, not scriptable here) | the retired vendor product page, any API token or license-key setting, any user list. Unpublish the product and revoke tokens |

### Action plan (run in this order; each numbered step is one commit or one command group)

Preconditions: license (J) decided, so there is exactly **one** rewrite. The same rewrite
should carry A3 (`.gitignore`), A4 (personal paths), A5 / H1 (git identity). Fix
`git config user.name` / `user.email` **before** step 6, otherwise the new history carries the
`test` identity again.

| Step | Action | Check |
|---|---|---|
| I-0 | **Do not push the unpushed commits (about 54 at 2026-10-14) to `origin`.** They sit on top of history that already contains the material | `git rev-list --count origin/master..master` does not change |
| I-1 | **DONE 2026-10-14: `../pipeline-kit-pre-scrub.bundle` (verified); copy it and `dist/` offline yourself.** **Backup, outside the repo and offline:** `git bundle create ../pipeline-kit-pre-scrub.bundle --all`, then copy `dist/` and the bundle to storage you control | `git bundle verify` passes |
| I-2 | **DONE 2026-10-14 (`0641eae`); section I and two SESSION-HANDOFF lines keep the word until the work ends.** **Scrub the working tree text** (one commit, docs only): `INTENT-LOG.md` (13, 59-64, 82-117, 148, 196-252), `LEARNINGS.md:549-590` (keep the lesson, reword as "a third-party verification endpoint"), `security-reports/2026-08-13-ce255b2.md` (same wording), this file's A1 and Housekeeping lines. **Edit only prose.** | `git grep -il <vendor>` lists only `ledger.jsonl` and `dashboard.html` |
| I-3 | **DONE 2026-10-14 (`949d6de`); one hit remains in `ledger.jsonl` and `dashboard.html` (the change name `remove-vendor-sponsor-references`), accepted by the owner.** **Scrub the ledger notes:** 8 lines of `ledger.jsonl`, `note` / `reason` / `claim` text only. Never touch `commit`, `base`, `round`, `outcome`, `tier`, `gate`. Record one superseding note in `CHANGELOG.md` that a one-time text scrub was made for publication (the ledger's own rule is "append-only; supersede, never edit", so state the exception). Then `bash tools/dashboard.sh` to regenerate `dashboard.html` | `grep -ci <vendor> ledger.jsonl dashboard.html` is 0; `bash tools/dashboard.sh --check` passes; `bash tests/run.sh` subset for ledger/dashboard passes |
| I-4 | **Remove local debris:** delete `dist/*.enc` and the SHA file; `git worktree remove` the `confident-hawking-50cb3b` worktree and the three `agent-*` directories; after confirming nothing unmerged is wanted, delete branches `ci-to-codebuild` (local and remote) and `claude/laughing-booth-8f1fe4` | `git worktree list` shows only the main tree; `git branch -a` shows only `master` |
| I-5 | **History route (A2): DECIDED 2026-10-13, fresh history.** Nobody else uses the repo, the repo is private, and it guarantees nothing survives in a commit message or old blob. Cost: the ~400-commit history and sha binding of old ledger records are lost, so keep the bundle from I-1 as the archive. Alternative: `pip install git-filter-repo`, then `git filter-repo --invert-paths --path releases/ --path tools/<removed-installer> --path tools/<removed-packer> --replace-text <rules> --replace-message <rules>`. It also changes every sha and must be checked with I-7 | Decision recorded here |
| I-6 | **Execute (fresh):** from the scrubbed tree run `git checkout --orphan clean`, commit with the corrected identity (license commit, from J, as its own commit), then replace `master`. **Delete and recreate the GitHub repo** (private) rather than force-pushing over it: a force-push leaves old objects reachable by sha and in `refs/pull/*` until GitHub garbage-collects | New repo has exactly one root commit |
| I-7 | **Verify, on a fresh clone:** `git log --all -i --grep=<vendor>`; `git log --all -i -S <vendor>`; `git rev-list --all \| xargs git grep -il <vendor>`; `git ls-files \| xargs grep -il <vendor>`; `git count-objects -v`; GitHub code search on the repo. All must be empty | Zero output on each |
| I-8 | **Re-establish the kit's own state:** re-pin the install base (`.install-base`, `status.sh` says when a pin is unusable), run `bash tests/run.sh` (45-90 min), `bash tools/dashboard.sh --check`, `bash tools/check-refs.sh` | Suite and checks pass; old ledger records report "unreachable commit" NOTEs only |
| I-9 | Do the external steps in I7 | User confirms |

Not part of this workstream: donation (L), marketplace packaging (K). Keep them in separate
commits per the scope-separation rule.

## J. License (discuss first)

Current: the previous copyleft license (`LICENSE`, added 2026-10-05 in `7751fd2`; README lines 3, 170, 1159-1164).
`ACTION-PLAN` decision 3 said "the previous license stays if the goal is resume and visibility; revisit only if
you sell it". The paid path is gone, which removes the stated reason for a
copyleft-for-sale posture.

| # | Item |
|---|---|
| J1 | **Goal stated 2026-10-13: people may use it, may not build new products on it, patents stay with the author.** That is source-available, not open source, so Apache-2.0/MIT no longer fit. Candidates, in order: (1) **PolyForm Shield 1.0.0** (any use, modify and distribute allowed, but not a product that competes with the kit; patent license for use only, ends if the user sues; fits the install model where `.pipeline/` is copied and committed into user repos); (2) PolyForm Internal Use 1.0.0 (no distribution at all, which the quick start's "commit `.pipeline/`" would breach in a public repo); (3) a custom EULA (needs a lawyer). Rejected: PolyForm Noncommercial (bans company use, defeats "people use it"), FSL (converts to Apache/MIT after 2 years). Patents: a license never transfers patent ownership, but PolyForm and Apache both *license* the author's patents for use; no patent filing was found in the tree; see J7 |
| J8 | Whatever is chosen, put a plain-language line next to it: "Using the kit to build your own software is allowed and your software is not covered by this license" |
| J2 | Confirm sole copyright. All 351 commits are the user's two identities; none from outside contributors. AI-assisted portions: record that in `NOTICE` or the README rather than assume |
| J3 | Add an explicit `Copyright (C) <year> <holder>` line (none found in the files grepped) |
| J4 | Files that change on a switch: `LICENSE`, README badge (line 3) and License section (1159-1164), install step that says to keep `LICENSE` (170), `plugin.json` `license` (SPDX, section K), and the SPDX in the marketplace entry |
| J5 | A relicense does not retroactively change copies already distributed under the previous license (the 1.0.0 user bundle recipients). Check what terms they were given before publishing |
| J6 | Content from another project: `experiments/003-004` name `sampleapp` (see decision 2). Do not publish it under the kit's license without owning it |

### J decision and the license commit (decided 2026-10-13)

**Decision: PolyForm Shield 1.0.0.** Stated goal: others may use it in their own projects, may not
copy it and sell it or ship a competing product; patents are out of scope; nobody else uses the
kit today (user statement, not verified), so no existing recipient under the previous license needs a migration.
Compared with the previous copyleft license: Shield forbids competing products (the previous license allowed resale if source is shared),
imposes nothing on a user's own code, and is **not** open source, so never call it that.

**Where it goes:** a separate commit in the fresh history (I-6), *after* the scrubbed-tree
commit, per the scope-separation rule. Nothing below is applied yet; `LICENSE` is still the previous copyleft license.

| # | File | Change |
|---|---|---|
| J9 | `LICENSE` | Replace with the **verbatim** Shield 1.0.0 text from `https://polyformproject.org/licenses/shield/1.0.0.txt`. Download it (do not retype or paraphrase) and record its sha256 in the commit message. The fetch tool used in the audit refuses to reproduce it, so use `curl`/`Invoke-WebRequest` |
| J10 | `NOTICE` (new) | One or more plain-text lines beginning `Required Notice:`, e.g. `Required Notice: Copyright (C) 2026 <legal name>`. The license requires that anyone who receives a copy also receives these lines. **The legal name must come from the user** |
| J11 | `README.md` | Line 3 badge: replace the old license badge with a plain "License: PolyForm Shield 1.0.0" badge (no "open source" wording). Line 170 keep-list: add `NOTICE` next to `LICENSE`. Lines 1159-1165 License section: say source-available, what is allowed (use in your own projects, commercial included, modify, copy `.pipeline/` into your repo), what is not (a product that competes with the kit), the J8 sentence, link to `LICENSE` and `NOTICE` |
| J12 | `plugin.json` (when K-3 creates it) | `"license": "PolyForm-Shield-1.0.0"`. Confirm the identifier against spdx.org/licenses before use; if it is not listed, use `SEE LICENSE IN LICENSE` |
| J13 | `CHANGELOG.md` | Entry: relicensed from the previous copyleft license to PolyForm Shield 1.0.0 on the stated basis that no third party held a copy |
| J14 | Other mentions | **DONE 2026-10-15.** The old-license wording in this file, `INTENT-LOG.md`, `SESSION-HANDOFF.md` and the dogfood report now says "the previous copyleft license"; only `CHANGELOG.md` names it |
| J15 | Install paths | Run `git grep -n "LICENSE" -- tools tests templates` and make sure installers, `update-kit.sh` and the `rm` list in README step 1 also carry `NOTICE`; a test may assert the file list |
| J16 | `experiments/003-004` | Resolve J6 (the `sampleapp` content) before the license is stated to cover them; otherwise exclude them from the public tree |

Checks after the commit: `bash tools/check-refs.sh`, `bash tools/dashboard.sh --check`, then
`CHANGE=relicense-shield bash tools/reconcile.sh T1` to see the tier the router assigns.

## K. Publish to the Claude marketplace (discuss; sources in the session of 2026-10-13)

There are two routes. They are not exclusive.

| Route | What it takes | Constraints found in the docs |
|---|---|---|
| **K-own: your own marketplace** | Add `.claude-plugin/marketplace.json` (`name`, `owner`, `plugins[]`) and `.claude-plugin/plugin.json` to a git repo; users run `claude plugin marketplace add akshay-goel-g/gated-change` then `claude plugin install gated-change@<marketplace>` | No submission or review. A private repo is a private marketplace. Run `claude plugin validate --strict` first. Set `version` (or omit to use the commit sha) |
| **K-dir: Anthropic's directory** | Submit from the developer portal at claude.ai/directory/manage. Needs a paid claude.ai plan, a GitHub repo, a connected GitHub account with push access | Repo may stay private while validating and submitting (source is uploaded to Anthropic) but **must be public before it goes live**. Anthropic reviews each version; a security scan runs on every new commit. The official `claude-plugins-official` marketplace does not take portal submissions |

Facts that shape the work (from the plugin docs and the pre-submission checklist):

| # | Requirement | Effect on this repo |
|---|---|---|
| K1 | A `LICENSE` file or `license` in `plugin.json` is required (blocking). **Checked 2026-10-13:** the Software Directory Policy and Terms say nothing about open source vs proprietary vs source-available licensing, so PolyForm Shield is not excluded by anything I read. The Terms (as summarized by the fetch tool, not read in full by me) have the developer grant Anthropic a license to display descriptions, documentation and branding, let Anthropic review and test the software, and **indemnify Anthropic**; Anthropic may remove a listing at any time and change the terms without notice. Read the Terms yourself, in particular the clause on distributing the plugin code to users | Shield is acceptable as far as the documents show. Policy items that touch this kit: 1E no IP infringement, 2F no pulling behavioral instructions from external sources (check `tools/update-kit.sh`), 2G no hidden or obfuscated instructions (check the minified `dashboard.html`), 4A/4C no money transfer, ads or "sponsorships" (donation link not addressed; ask before adding one). The Terms also require a way to receive and investigate vulnerability reports (add `SECURITY.md`) |
| K12 | Directory logistics: Pro, Max, Team or Enterprise plan; the listing belongs to the organization that submits first, so submit from the right account; a person reviews a new listing and each version gets a scan; no fixed review time; 10 submissions per organization per 24 h | Choose the account before the first submission |
| K2 | README of at least 40 words outside code blocks (blocking) | Met |
| K3 | Plugin folder must be self-contained; every file a hook or script uses is inside it | The kit's `tools/`, `core/`, `templates/` are in the repo root together with the project's own `project/`, ledger and history. This is D5 (path split) and D8 (wrapper) |
| K4 | Non-image, non-font files over 256 KiB, more than 512 files, or binaries are **held for a reviewer** | Tracked files over the limit: `dashboard.html` (737 KB), `ledger.jsonl` (697 KB), `tests/run.sh` (401 KB). Repo has 175 tracked files. A plugin folder should ship only the kit code, not the ledger or generated dashboard |
| K5 | Hook commands must be written as `${CLAUDE_PLUGIN_ROOT}/...`; scripts that source other plugin files, use shell variables or command substitution are held (**Scripts the validator couldn't follow**) | `r0c-post-edit.sh` and the tools resolve siblings through `dirname "$0"`. Keep the plugin at the root of its own repo, or restructure the hook entry points |
| K6 | Git hooks are not a plugin component | `templates/pre-push` stays a separately installed hook (D8 already says this). The plugin must document the install step plainly |
| K7 | Security scan flags undisclosed behavior (data sent elsewhere, hidden code, changes to Claude's permission settings) | `install-claude-hook.sh` merges into `.claude/settings.json` and `install-hook.sh` writes `.git/hooks`. Both must be described in the README, as the scan reads it |
| K8 | A `bin/` directory makes the plugin non-installable on claude.ai and Cowork; hooks are Claude Code-only | Fine for a Claude Code kit; the listing should say Claude Code only |
| K9 | Name: lowercase, hyphens, must not start with `claude-` or `anthropic-`, must not collide with an existing listing or well-known brand | **DECIDED 2026-10-15: `gated-change`**, a full rename (README, tools incl. the `SELF:` sentinel, tests, docs). Direct lookups found no GitHub repo, npm package or PyPI package of that name. The old working name `pipeline-kit` collided in spirit with `pipekit` and Pipekit.io |
| K10 | Data-handling questionnaire and compliance acknowledgements at submit time | Answer from fact: the kit writes only to the user's repo and sends nothing |
| K11 | `version` must be raised on each release if set | Add a release step to the kit |

Work items, in order:

| # | Item | Effort |
|---|---|---|
| K-1 | Settle J (license) and I (history) first; the listing exposes both | S-M |
| K-2 | D5: path split so the plugin folder is self-contained | M |
| K-3 | D8: `plugin.json` + `marketplace.json` + `hooks/hooks.json` + skills wrapping reconcile / compliance / status | M-L |
| K-4 | `claude plugin validate --strict` in CI next to `tests/run.sh` (needs Actions enabled again, or run locally) | S |
| K-5 | Publish via **K-own** first from the private repo and test an install on a clean machine | S |
| K-6 | Then portal **Validate** (K-dir), fix blocking findings, make the repo public (A6), submit | M |
| K-7 | `claude plugin eval` cases for the skills, if the wrapper ships any | M |

## L. Donation (deferred, discuss after J and K)

No `FUNDING.yml` or sponsor reference exists in the tree; they were removed deliberately with
the download path (`024c148`). Do not add one before J and K are decided. When revisited: a passive link
only (GitHub `FUNDING.yml` plus a README line), in its own commit, after the repo is public
(the Sponsor button does not show on a private repo). Open: whether the directory policy or the
chosen license say anything about monetization links (policy page not read).

## M. Start here in the next session (written 2026-10-13)

**Decided:** history = fresh (I-5); license = PolyForm Shield 1.0.0 (J). **Not applied:** the
tree is unchanged, `LICENSE` is the previous copyleft license, the 45 local commits are unpushed, nothing was
rewritten.

Risks found while writing this that the next session must resolve first:

| # | Risk | Why it matters | What to do |
|---|---|---|---|
| M1 | **RESOLVED 2026-10-14: the E1-E11 review was closed by the owner at round 29 (`R-011` in `project/risks.md`), not passed; G7 and G4 FAIL at R29, full suite 1380 passed on `2a3f75e`.** What remains true: no round had all six gates pass. A fresh history discards the shas its ledger records bind to | `compliance` could never again prove those gates for that change; the evidence the kit exists to produce would be orphaned | Either finish round 26 and a clean G7/G4 first, or decide explicitly to publish with that change recorded as "stopped at round N" in `CHANGELOG.md` |
| M2 | **The pre-push hook will block the first push of a fresh root.** It guards T4 paths and wants a security report naming the pushed commit; a new root makes every file "changed". `--no-verify` was refused by the auto-mode classifier earlier | Cannot publish without a report or an explicit user override | Prepare a G7 report naming the new root/tip, or ask the user to run the push themselves |
| M3 | New repo means a new `origin`; the install pin and `.install-base` point at old shas | `status.sh` will say the pin is unusable (I-8) | Re-pin as part of I-8 |
| M4 | CI: GitHub Actions has been disabled since 2026-09-08 for non-payment; macOS has 20 known failures (B1) | A public repo gets free runners (A6), but the new repo starts with no CI history | Re-run the suite locally and on the new repo once public |

Ordered start list for the session:

1. Ask the user for the **legal name** and **year** for the `Required Notice` line (J10). (M1 is settled: R-011.)
2. Run I-0 to I-4 (backup, prose scrub, ledger notes, debris).
3. Fix `git config user.name/email` (H1/A5).
4. Do I-6 (fresh root commit), then the J9-J16 commit as a second commit.
5. I-7 verification on a fresh clone, then I-8.
6. Only then K (marketplace) and L (donation).

## Suggested order

0. **Decided 2026-10-13:** fresh history (I) and PolyForm Shield (J). Do I and the J commit together as one rewrite, after M1 is settled. Then K (marketplace), then L (donation).
1. **A** (cleanup) as its own commit; **B1** (macOS) as its own commit.
2. **E1-E3** first (compliance correctness), then **E4-E11**.
3. **B2-B6** quality fixes.
4. **C1**, then **C2** (after E1-E3).
5. **F** and **G1-G3** (README states, demo, evidence, glossary). Do these after E so the documented states are the fixed ones.
6. **Make the repo public** once A, E1-E3 and F4 are done.
7. **D1, D2, D5, D8**, then **D3**.
8. **G4-G5** measurement runs, then update the Status table.
9. Final README wording per the honest-wording block in section D.

## Housekeeping notes

- Resolved: the concurrent `ledger.jsonl` G7 skip for `remove-vendor-sponsor-references` (commits 024c148, cdd2e59) was the paid-path-removal workstream (the user's own, separate session). Commit `024c148` also swept this file's first version into the repo, so `ACTION-PLAN.md` is now **tracked**, and later edits show as modified. Commit it deliberately, or untrack it; see E9 (it is not in the install `rm` list).
- That commit also touched `README.md`, `tests/run.sh` (-315 lines), `tools/update-kit.sh`, `project/*.conf` and `matrix.sh`. Re-run `bash tests/run.sh` (allow 45-90 min on this machine) before trusting the "877/911" test counts quoted in section G; the paid-path removal may have changed them.
- Run `git fetch` and `git log --oneline -3 origin/master` at session start; peers push to this repo.
- The dogfood run copied the working tree, so it tested the uncommitted README.
- `check-refs.sh` gives 8 false positives on the README; fix or allowlist when touching it.

## Known gaps in the research

- Competitor findings are from cloned READMEs and selected files, not full audits.
- *Inferred, untested:* shallow-clone failure of `reconcile.sh` (needs a merge-base), `$CLAUDE_PROJECT_DIR` under the SDK, visibility of `tool_input.prompt` in a PreToolUse hook on `Agent`, Managed Agents clone depth.
- Managed Agents hook support was "not found in the docs read", not confirmed absent.
- Model IDs, pricing and API features were taken from the docs on 2026-10-06 and will drift.
