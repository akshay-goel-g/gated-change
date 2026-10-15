# Gated Change — cold-start dogfood report

Date: 2026-10-06. Platform: Windows 11, Git Bash, git 2.x, node 24. Kit: working tree of
`D:\work\gated-change` (README 1080 lines, kit fingerprint `1.0.0+ecd8dc91`), copied
(not git-cloned, see note) into `scratchpad/dogfood/gated-change`, installed into a throwaway
project `scratchpad/dogfood/app` (10 commits: `manifest.json`, `src/auth/login.js`,
`src/lib/util.js`, `styles/main.css`, README; 4 "fix:" commits). Nothing in the real repo was
modified. No push was made anywhere; the pre-push hook was exercised by invoking
`.git/hooks/pre-push` directly with git's stdin format.

Note on "fresh clone": I copied the working tree because the README under test is the
uncommitted working-tree README. A `git clone` today would give HEAD (`cdd2e59`), which still
contains `releases/` and `tools/<removed-installer>` (deleted in the working tree) and lacks
`ACTION-PLAN.md`. `ACTION-PLAN.md` is not in step 1's `rm` list, so a copy of the working tree
ships it into the user's `.pipeline/`.

Severity legend for findings: **BUG** (code), **DOC** (README wrong/missing), **UX** (works but
painful), **WINDOWS** (platform).

---

## Executive summary (blunt)

1. **The install works.** Following Quick start literally, a scripted run went from copy to the
   first green `compliance` in ~2 minutes and 13 kit commands. For a human reading the README
   first, 30 minutes is realistic only if they skim; 45-60 minutes is more honest.
2. **Two correctness holes in the release check itself** (the one command the README says
   "decides release"):
   - **A blocking FAIL at round N is masked by a PASS at round N-1.** `compliance --round 2`
     prints `PASS* G7 Threat passed at round 1` and exits 0 even though G7 *failed* at round 2
     with a blocking finding (reproduced, transcript §T9). The dashboard shows the same round as
     **Fail**, so the two disagree.
   - **`--tier` is self-declared and never cross-checked against the reconciled tier.** A change
     the ledger records as reconciled T4 passes `compliance --tier T1` ("Tier T1 mandates no
     gates. Nothing to check.", exit 0).
3. **The pre-push hook has a sha bootstrapping deadlock.** It requires a report naming
   `git rev-parse HEAD`; committing that report moves HEAD, so the push is blocked again. The
   kit's own ledger shows this: **19 of 77 G7 entries are `skipped` pre-push overrides**, several
   with notes reading "bootstrapping deadlock". The hook also silently makes commits
   (auto-regenerates `dashboard.html` and commits it) — not mentioned in the README.
4. **The ledger is a tracked file that every branch appends to**, and the README never says
   whether to commit it. Committed: parallel branches always merge-conflict on it (reproduced).
   Uncommitted: it blocks `git checkout` (reproduced; it made me log a gate on the wrong
   change).
5. **No dashboard screenshot, no output-label glossary.** The README documents 6 of ~30 output
   states. The dashboard's own footer legend is good; the README says nothing about it.
6. **Strength evidence exists but is mis-stated in the README.** The README says "120+ gate
   runs across a dozen changes"; the ledger holds **352 gate runs across ~45 changes**, 88
   blocking findings, 87 failed gate runs. CI has not passed since 2026-09-06 (last real run:
   ubuntu and windows green, macOS 20 failures). "911 checks" matches no recorded run.
   Defect-reduction and effort-reduction remain **Unproven**; experiments 001-004 do not change
   that (n=4 unblinded pairs, different features per arm, control arms never re-reviewed,
   nothing shipped).

---

## A. Time-to-first-value

### Measured timeline (wall-clock, scripted by an agent that had already read the README)

| Step | Clock | Result |
|---|---|---|
| Create project, 10 commits | 23:35:28 | ok |
| Step 1 copy + `rm -rf` | 23:35:40 | ok, 1 s |
| Step 2 `mine-registry.sh` | 23:36:03 | "No co-occurring file pairs survived filtering." Retry with `HUB_PCT=100` wrote the draft **to `./project/registry-draft.md` at the repo root, not `.pipeline/project/`** |
| Step 3 copy template, write surfaces.conf | 23:36:22-23:36:39 | ok (I wrote 7 rows; a human answering 5 questions will take 10-20 min) |
| Step 4 hooks + PR template | 23:37:00 | ok |
| Step 5 ledger + `status.sh` | 23:37:13 | exit **1**: lists all 6 pre-install T4 commits as "trust boundary, never re-gated" right after the README says "You are done" |
| First green `compliance` (T1 CSS change) | 23:37:34 | "Tier T1 mandates no gates. Nothing to check." exit 0 — vacuous |
| First green T4 `compliance` | 23:41:22 (round 3), honest at 23:42:26 (round 4) | exit 0 |

**Commands from zero to first green `compliance`: 13 kit commands** (cp, rm, mine-registry,
mine-registry retry, cp templates/project, edit surfaces.conf, install-hook,
install-claude-hook, mkdir+cp PR template, touch ledger, export PIPELINE_MODEL, status,
reconcile, compliance) **plus 4 git commands** (commit the install, branch, edit, commit). The
README never tells you to commit `.pipeline/` or to work on a branch, both of which are needed
before `reconcile` produces anything (on `main` with a clean tree it exits 2 "No changes
against main").

Tool latency on Windows (Git Bash): `reconcile` 1-7 s, `compliance` 2-10 s, `status` 4.5-20 s
(20 s on an install still carrying the kit's 423-line ledger), **`dashboard.sh` 27-34 s** per
run (also run inside every pre-push), `tests/run.sh` ~26 min on CI windows-latest, 47 min locally (877 passed, 0 failed).

### Is "30 minutes" realistic?

For the mechanical steps, yes — they take minutes. What eats time:

1. **Reading.** The README is 1080 lines; Quick start sends you to `surfaces.conf`, whose
   shipped template is ~200 lines of commentary. Expect 20-30 min of reading before step 3.
2. **Step 3 (writing surfaces.conf).** The only step requiring thought; 10-20 min.
3. **Step 2 on a young or small repo** gives a message the README does not show (see E9), so
   the user does not know whether it worked.
4. **Step 5's `status.sh` exits 1** with every historical commit listed as unrouted T3/T4 work,
   immediately after "You are done". Nothing says how to baseline existing history (what clears
   it is logging any gate on a later commit, which re-anchors the scan).
5. **The first real T3/T4 change** requires knowing that ROUND is an env var, that `compliance`
   needs the same `--change` name, and what to do with `UNCONFIRMED` / `UNRESOLVED` — about
   20-30 min the first time.

Honest estimate: **45-60 min to a meaningful (T3/T4) green compliance**; ~5 min for a vacuous
T1 one.

### Smallest path to a 60-second demo (measured: 24 s on Windows)

```bash
git init demo && cd demo && git commit --allow-empty -m init
mkdir -p .pipeline && cp -r ../gated-change/{core,tools,templates,examples,VERSION} .pipeline/
mkdir -p .pipeline/project && cp .pipeline/examples/surfaces/web-app.conf .pipeline/project/surfaces.conf
git checkout -b fix-login && mkdir -p src/auth && echo x > src/auth/login.js && git add src && git commit -m fix
CHANGE=fix-login bash .pipeline/tools/reconcile.sh T1 --log        # -> UNDER-CLASSIFIED: predicted T1, actual T4 (exit 1)
bash .pipeline/tools/ledger.sh compliance --change fix-login --tier T4   # -> INCOMPLETE, 6 gates NOT RUN (exit 1)
```

This shows the two ideas that matter (diff-derived tier; mechanical "not ready") in ~6
commands. It should be the first code block in the README, ideally as a `tools/demo.sh`.

---

## B. Dashboard and output-state catalogue

**Does the README show what the dashboard looks like?** No. No screenshot, no sample, no
description of its labels. "Reading the results → The dashboard" is one prose paragraph. The
dashboard itself has a good footer legend for graph-box styles.

Screens observed (Claude Browser, served over `http://127.0.0.1` from the scratch project):
left rail of changes per round with a verdict pill; project metrics (miss rate, challenge
rate, escape rate, self-check count, tokens); a Coverage banner; per-round **Overview** tab
(plain-language "who reviewed it") and **Technical details** tab (gate state-machine graph).

Things the dashboard got wrong or inconsistent in this run:
- Round 3 of `login-redirect`: dashboard **Fail**, `compliance --round 3` **All satisfied**
  (exit 0). Same disagreement on the `probe` ledger (round 2: dashboard Fail, compliance
  exit 0). README: "If the dashboard and status.sh ever disagree, status.sh is right" — but
  this is `compliance` vs dashboard, and here the dashboard is the correct one.
- The same Overview shows "❌ Fail ... Staff engineer found 1 blocking problem" and, at the
  bottom, "5 blocking findings found and resolved along the way — nothing blocking remains."
- A G7 `skipped` record with no tier (exactly what the pre-push hook tells you to log) renders
  as **✅ Success** ("Main Push").
- Technical tab: "No G1 record for this change" although G1 passed at rounds 1, 3 and 4 (it
  reads only a round-1 note).
- "Escape rate: 10% (2 escaped)" counts an escape on a change that never ran a gate, which
  `ledger.sh escape` itself labels "baseline, not an escape".
- Header says "25 self-check run(s)"; `ledger.sh report` says "low-confidence 32" for the same
  ledger.
- Every command it prints is `bash tools/...`, which is wrong for an installed kit
  (`.pipeline/tools/...`).
- An empty ledger renders "No gate or route records found ... Select an execution on the left"
  plus "Coverage not computed" — no next step for a brand-new user.

### Deliverable table 1 — Dashboard states

| STATE (as shown) | Meaning | Cause | How to fix | In README? |
|---|---|---|---|---|
| ✅ **Success** (rail pill) | All gates the tier mandates have a verdict at this round, none failed | Every required gate's governing entry is pass (or reasoned n/a on a footnoted cell) | — | No |
| ❌ **Fail** | Some gate's governing entry is `fail` | `ledger.sh add ... --outcome fail` | Fix, re-run the gate at a new round (`ROUND=n reconcile.sh`, then `ledger.sh add --round n`) | No |
| 🔄 **In progress** | Latest round is missing required verdicts | Mandated gate not run, skipped, or n/a not honoured | Run the missing gates; log them | No |
| ⚠️ **Incomplete** | An *earlier* round was left with missing verdicts | Superseded round never finished | Usually nothing; it is history | No |
| ⚠ **escaped defect** (badge) | An `escape` record exists for this change | `ledger.sh escape --change X` | Write the LEARNINGS entry; add a registry coupling | Partly (escape command only) |
| PASS (self-check) / hatched green | Pass logged `--confidence low` | Same session reviewed its own work | Re-run in a fresh session, log `--confidence fresh` | No ("low" explained, label not) |
| **PASS\*** / dashed green | Pass carried forward from an earlier round | No re-run at the current round | Re-run if what it examined changed | No |
| **FAIL** / red box | Gate failed | `--outcome fail` | as Fail | No |
| **SKIPPED** / amber dashed | Required gate logged `skipped` | `--outcome skipped` (incl. pre-push overrides) | Run the gate | No |
| **NO RECORD** / grey dashed | Required, never logged | Nothing logged | Run it; "don't backfill" | No |
| **N/A** / faint grey | Logged n/a | `--outcome n/a` | If required and no footnote, run it instead | Partly (compliance REFUSED) |
| **—** / faded | Gate's card does not fire at this tier | Matrix cell `—` | — | Matrix only |
| **R¹ · not run** / faded | Recommended; footnote may make it mandatory | Matrix cell R + footnote | Decide; run or ignore | Matrix only |
| Coverage banner "N commits since the last gate run — nothing above T2" | Git-derived coverage baked at generation | commits after last gated commit | `status.sh` for live view | Prose only |
| "⚠️ Gate coverage incomplete" | Unrouted T3/T4 commits at generation time | T3/T4 work with no gate run | `reconcile.sh <tier> --log` then the gates | Prose only |
| "Coverage not computed" | Ledger is not from this repo / fleet / empty | Fleet view or foreign ledger | Run `status.sh` in the owning repo | No |
| ● Live — updated Ns ago / ○ Snapshot | Served over http (re-fetches ledger) vs file:// snapshot | How you opened it | Regenerate, or serve over http | No (README says "snapshot" only) |
| "Escape rate" amber with ⚠ | Escapes > 0 | escape records | — | Metric explained, badge not |

### Deliverable table 2 — `ledger.sh compliance` labels

| Label | Meaning | Cause | How to fix | In README? |
|---|---|---|---|---|
| `PASS` | Gate has a pass at this round (or any later round) | pass logged | — | Implied (Example B end) |
| `PASS*` | Last pass is from an earlier round; still counts, exit 0 | No re-run after re-entry | Re-run if the code it saw changed | **No** — and README claims a pass "at the current round" is needed |
| `NOT RUN` | Mandated, nothing logged | — | Run the gate | Yes (Example B) |
| `FAIL` "re-run required" | Latest round's latest entry is fail and no pass at any round ≥ ... | fail logged | Fix, re-run at new round | Yes |
| `SKIPPED` | Mandated, latest is `skipped` | `--outcome skipped` | Run it | **No** (only "skipped is never a pass" prose) |
| `REFUSED` (n/a, no condition) | n/a on a cell without footnote | n/a on e.g. G7/G8 at T4 | Run the gate | Yes |
| `REFUSED` (n/a with no reason) | n/a on a footnoted cell but no `--note` | `--outcome n/a` without note | Re-log with `--note` | **No** |
| `UNRESOLVED` + "M⁵ says: Skip only when Axis C is *Invisible*" | Conditional mandate; tool cannot evaluate | Footnoted M cell, nothing logged | Run, or `n/a --note` | Yes, but "Axis C" is never defined in README |
| `N/A` "does not fire here — <note>" | Honoured n/a | n/a + note on footnoted cell | — | Partly |
| `CHECK` (recommended block) | Recommended gate not logged | R cell | Your call | **No**; footnote text is truncated mid-sentence ("...capability on") |
| `LOGGED` (recommended block) | Recommended gate has an entry | — | — | **No** |
| `KIT DRIFT` | Entries written by a different tool build | Tools changed since logging | Decide per gate | **No** |
| `INCOMPLETE — N mandated gate(s) without a pass` | Not releasable, exit 1 | Any of the above | Run gates | Yes |
| `UNCONFIRMED — N assumption(s)...` | `defaulted` assumption at T3/T4; exit 1 (replaces the INCOMPLETE line) | `assume --resolution defaulted` | Re-log as asked/verified | Partly (FAQ) |
| `REFUSED — every mandated gate passed, but no reason recorded` | T3/T4 with no route `REASON` and no G1 note | Forgot `REASON=` | `REASON='..' reconcile.sh --log` or G1 `--note` at round 1 | **No** |
| `REFUSED: tier 't3' is not one of T0..T4` | Case-sensitive tier | typo | Use `T3` | No |
| `Tier T1 mandates no gates. Nothing to check.` | exit 0 | T0/T1 (or any tier you choose to type) | — | No |
| `All Tn-mandated gates satisfied at round N.` | exit 0 | — | — | Yes |
| `All ... satisfied, but K passed at an earlier round (PASS*)` | exit 0 with stale passes | — | — | No |

### Deliverable table 3 — `status.sh` labels

| Label | Meaning | Cause | How to fix | In README? |
|---|---|---|---|---|
| `LEDGER none at <path>` | No ledger file | Step 5 skipped | `touch .pipeline/ledger.jsonl` | Implied |
| `LEDGER exists, but holds no gate records` | Only routes/escapes/assumptions | No gate logged yet | Log a gate | No |
| `LAST GATE <date> — <change> (commit X)` | Anchor for the unrouted scan | — | — | Prose |
| `NEVER RUN G..` | Gate ids no ledger entry has named | New install; G2 is never mandatory so stays forever | Ignore G2/G3 if not needed | Prose |
| `UNROUTED WORK ... T4 — trust boundary, never re-gated` / `T3 — shared surface` | Commits since last gated commit touching T3/T4 surfaces; exit 1 | Work landed without gates, **incl. all pre-install history** | `reconcile.sh <tier> --log` + gates; for pre-install history: undocumented (log any gate on HEAD) | Partly; baseline case missing |
| `Nothing above T2 — no gate is mandated` | exit 0 | — | — | No |
| `ledger names commit 'X', not found in this repo` | Anchor commit absent | Copied someone else's ledger | Delete ledger | No |
| `GATES THAT WOULD INVENT THEIR INPUT` (G7 example surfaces; G4 empty registry) | Gate has nothing real to check | Unedited surfaces.conf / empty registry.md | Edit them, or `assume --resolution defaulted` | Prose only |
| `GOVERNANCE STALE` (no Owner / review was due) | govern.md cadence rows unowned, risks.md overdue | Template not filled | Put a name in each Owner cell | No (Config table hints) |
| `KIT 1.0.0+<hash>` | Version + checksum of tools/*.sh only | — | `update-kit.sh` | Yes (fingerprint) |
| `[x]/[ ] pre-push hook`, `[x]/[ ] R0c re-entry hook`, `[x]/[ ] dashboard.html` | Enforcement installed or not | — | Command printed | Prose |
| `[!] pre-push hook installed but DIFFERS from templates/pre-push` | Stale or customised hook | Kit updated / hook edited | `install-hook.sh --force` | Yes (Enforcement) |
| `[~] dashboard.html is older than the ledger` | Snapshot stale | New ledger lines | `dashboard.sh` | No |
| `[!] surfaces.conf is still the shipped EXAMPLE` | Template not edited | Step 3 skipped | Edit surfaces.conf | Yes (FAQ) |
| `[!] THIS INSTALL IS CARRYING THE KIT'S OWN RECORDS` | Kit's project/ledger copied | Step 1 `rm` skipped | Commands printed | No — and status still exits 0 |
| Exit 0 / 1 / 2 | ok / unrouted T3-T4 / cannot answer | — | — | Yes |

---

## C. Strength evidence — what exists, and what it can honestly support

All numbers below were extracted read-only (ledger copied to scratch and parsed with Python
and `ledger.sh report`).

| Candidate headline | Number | Source | Strength | Can support | Cannot support |
|---|---|---|---|---|---|
| Gate runs recorded on the kit itself | **352** gate runs, 59 routes, 12 assumptions; 2026-08-12 → 2026-10-06 | `ledger.jsonl` (423 lines); `ledger.sh report` | Strong as an activity count (machine-written, append-only) | "The kit has run its own pipeline on ~45 changes over 8 weeks" | Anything about outcomes. Note README still says "120+ gate runs across a dozen changes" — **understated and stale** |
| Fresh-context share | 252 of 352 runs `fresh`; 76 `low` | ledger `confidence` | Medium (self-declared) | "72% of gate runs were by a session that did not write the code (self-reported)" | Independence beyond the author's own labelling |
| Defects caught before push | **88 blocking** findings (81 in fresh runs) across **24 changes**; 205 minor, 304 info, 20 out-of-scope; **87 failed gate runs** (78 fresh) | `finding_details[].severity`, `outcome` | Medium: real, citable (each has file:line), but self-graded severity by the same agent family that wrote the code, no external audit | "Gates returned 88 findings their reviewer rated blocking, each fixed and re-verified before push" | "Defects prevented" (no counterfactual), "would have escaped" |
| Failure rule engages | 24 of ~45 changes needed >1 round | `report` ROUNDS section | Medium | "Half of changes were sent back at least once" | Quality improvement |
| Reconcile miss rate | **15%** (59 routes: 49 match, 9 under, 1 over) | `report` LEADING | Strong mechanically | "Routing re-derived a higher tier than predicted in 9 of 59 reconciliations" (e.g. predicted T0 actual T4 for `extension-phases-narrow-pass`) | That those under-classifications were dangerous |
| Escape rate | `0% = 0 / 617` | `report` LAGGING | **None.** No `escape` record has ever been written; the kit has no external users | Nothing. Should be printed as "no escapes recorded", not 0% |
| Disagreement (challenge) | 44% overall; per gate G4 60%, G6 53%, G7 70%, G1 0% | `report` | Medium (self-reported `--challenged`) | "Reviewers contradicted the author in 44% of fresh runs; G1 never did (0/20 fresh) — by the kit's own rule G1 is 'confirming, not reviewing'" | Reviewer quality |
| Cost | 15.07M tokens over 166 runs that recorded it (186 runs unrecorded); median fresh gate ≈ **101k tokens** | `tokens` field | Medium (floor) | "A gate run costs ~100k tokens median" | Human time: only **15 of 352** runs recorded `--minutes` (118 min total) — no human-effort data |
| Hard-gate overrides | **19 of 77** G7 entries are `skipped` pre-push overrides | `outcome=skipped`, notes | Strong | Honest weakness: the hook was bypassed on ~25% of G7 events, several citing the sha "bootstrapping deadlock" | — |
| Security reports | 32 files in `security-reports/`, 24 mention "blocking" | dir listing | Medium | "32 Threat reports, each naming the reviewed sha" | — |
| Test suite | README "911 checks". **Local run of the working tree in scratch (Windows, Git Bash): `passed 877 · failed 0 · skipped 0`, exit 0, 2800 s (47 min, under concurrent load)**. Last real CI run (2026-10-05, `37315886418`): ubuntu **906 pass / 0 fail / 1 skip**, windows **905 / 0 / 2**, macOS **893 / 20 fail / 1** (matrix-lock tests) | `gh run view --log` | Strong | "~880-907 automated checks (877 in the current working tree), green on Linux and Windows" | "911"; "green on macOS" |
| CI history | Last 57 runs: 20 success, 36 failure, 1 in progress; **last success 2026-09-06**; most failures run 5-7 s (Actions disabled for billing since 2026-09-08 — not code) | `gh run list --limit 100` | Strong | Must not show a CI badge today | "CI green" |
| Governance self-check | The kit's own `project/risks.md` has R-001/R-003/R-004 reviews overdue and `govern.md` has no owners | `status.sh` on an unstripped install | — | Honest-weakness line | — |
| Ledger hygiene | Junk change names (`c`, `my-first-feature`, `footgun-test`, slash/dash duplicates), model names `m`, `Claude`, `unset` ×14 | ledger | — | Shows the ledger accepts junk | — |
| Experiments 001-004 | 4 pairs. Gated arms: wall 17 min vs 11.5 (001); gate-minutes 109 / 205 / 106 (002-004); tokens ~433k (A), ~588k (C). Gated arms caught: a stale premise pre-build (001, G1), a regression in the fix (002, G8), a bug introduced by the round-1 fix (003, G6 frozen countdown), a test that proved nothing plus an unverified claim (004, G6). Control arms: 1/0/0/0 findings (they ran no gates, so this is tautological) | `experiments/00x/result.md`, `data.csv` | **Weak/anecdotal**: n=4, one operator, unblinded, different features per arm, control arms never re-reviewed by gates, nothing shipped (no escapes possible). `003/result.md` misstates n ("n=6 pairs ... 12 arms"; it is 3 pairs / 6 arms). `001/data.csv` says tests_added 3 for arm A, result.md says 2 | "In 4 of 4 gated arms, a verify gate produced a finding that changed the code before merge, at roughly 100-200 gate-minutes or ~0.5M tokens per change" | Defect reduction, effort reduction, any rate |

### Do experiments 001-004 change "Unproven"?

No. The README's "Unproven" is correct for both rows. The experiments show the gates *find
things*, not that the routed pipeline yields fewer escaped defects than the alternative —
the ungated arms' latent defects were never measured, the features differ between arms, and
nothing shipped. On effort, every experiment shows the gated arm cost *more* (by design: the
control is "no review", not "review everything").

Justified wording for the Status table:

> | The routed pipeline reduces defects | **Unproven.** Preliminary: in 4 unblinded paired trials on one project, verify gates changed the code before merge in all 4 gated arms (a stale premise, a regression in a fix, a bug introduced by a fix, a test that proved nothing). Ungated arms were not re-reviewed, so no defect rate can be compared. |
> | The routing reduces effort vs. reviewing everything | **Unproven, and not yet measured.** No experiment has compared routed gates against all-gates. |
> | The kit runs its own pipeline | Since 2026-08-12: 352 gate runs on ~45 changes; 88 findings rated blocking were fixed before push; 9 of 59 reconciliations caught an under-predicted tier. 19 of 77 Threat entries are logged pre-push overrides. |

### Smallest measurement that would support an effort claim (uses existing harness)

The effort claim is "routing reduces effort vs reviewing everything". The counterfactual is
*all eight gates on every change*, not *no gates*. Smallest credible design:

1. Take the next **10 changes** (mixed tiers; at least 4 at T0-T2) in one repo.
2. For each, run the **routed** gate set and log to `ledger.jsonl` as normal; separately run
   the **full G1-G8 set** in fresh sessions and log to `--ledger experiments/005/full.jsonl`.
   Same model, `--tokens` and **`--minutes` mandatory** (minutes = human attention spent
   reading the gate output and acting on it, not agent wall-clock).
3. Compare per change: tokens and human-minutes (routed vs full), and **blocking findings
   present in full but absent in routed** (the cost of routing).
4. Report: "Routing saved X% tokens / Y% human-minutes and missed Z blocking findings across
   10 changes." With `ledger.sh report --ledger` this needs no new code.

Cheaper retrospective proxy available today: count commits in the kit's history that routed
T0-T2 (no gate mandated) vs T3/T4, and multiply by the median ~101k tokens per gate run ×
gates avoided. That gives a "gate-runs avoided" number, but says nothing about what they would
have found — label it as such.

---

## D. README structure and clarity

### Where a first-time reader gets lost

1. **Jargon before definition.** `R0b` first appears inside example output (line 499); `R0c`
   (line 427) and `R0d` (439) are section titles with no definition of the R0 numbering;
   `R0a` and `G1a` appear only in the walkthrough and tool output. "Axis C" is printed by
   `compliance` but never appears in the README. "Harvest"/"Adapt" (line 101/129) are never
   explained. "Probe", "Grounding", "ceilings", "personas" are named in tables before they
   mean anything. There is **no glossary**.
2. **"How it works" lists 8 gates but tiers come later.** The matrix (the thing that actually
   decides what you must do) is in Core concepts, after Quick start; Quick start never says
   what will be demanded of you per change.
3. **Quick start ends at "You are done"** but the user has not routed a single change. The
   loop (reconcile → gates → compliance) is in "Using it day to day", 150 lines later.
4. **No "what you will see" blocks** for steps 2, 3, 5. Step 2's documented message ("Not enough
   history to mine") is not the one a small repo gets. Step 5 shows no `status.sh` output — the
   real one exits 1 and looks alarming.
5. **No dashboard image or description**; no glossary of output labels (Section B: the README
   covers ~6 of ~30 states).
6. **Missing practical facts:** commit `.pipeline/`? commit `ledger.jsonl`? work on a branch?
   how to baseline pre-existing history? `mkdir docs` before the records copy? `ROUND` is env,
   not a flag. What "log an explicit exception and own it" means (it is `--outcome skipped`
   with a note, per the hook's text).
7. **Too long where it does not matter to a new user**: the "five kinds of thing" table,
   protocols, four records, two maps, versioning policy, the license paragraph — all before the
   Command reference a user needs on day one. "Status" (the honesty section) is at the end.
8. **Contradictions with the tools** (see E): "every change routes T0" with the shipped
   example; "a pass at the current round" required; blocking findings "need a file:line"; the
   walkthrough's re-entry command does not create round 2.

**Before/after or transcript?** Partly: Examples A, B, E and `examples/walkthrough.md` are
real transcripts and are the best part of the docs. Missing: a full first-session transcript
(install → status → first change → compliance → dashboard), and a before/after (the same
change without the kit).

### Links and paths

All 15 relative links and 18 anchors in README resolve, both in the repo and in an installed
`.pipeline/`. Every backticked path the README names exists (checked against repo,
`tools/`, `templates/project/`). `tools/check-refs.sh --file README.md` reports 8 "MISSING
PATH" — all false positives (regexes like `(^|/)services/billing/`, placeholders like
`specs/<n>/requirements.md`, paths relative to the user's project such as
`src/auth/login.js`, and `benchmark/measure.sh` written relative to `tools/`). It is too noisy
to use as a docs link checker as-is.

### Do the examples work if followed?

- `cp .pipeline/examples/surfaces/web-app.conf .pipeline/project/surfaces.conf` — works; all
  5 example confs parse and route (`chrome-extension`, `rest-api`, `web-app` → T4 on my diff;
  `data-pipeline`, `library-cli` → T2). `web-app.conf` uses a `T0::` row the README's format
  section does not list.
- `examples/walkthrough.md` — commands run, outputs match, **except step 5**: it runs
  `reconcile.sh T4 --log` without `ROUND=2`, which logs another **round 1** route; the text says
  "at a new round". Combined with `reconcile.sh` silently ignoring an unknown `--round 2` flag
  and the R0c hook saying "(a new --round, not a new change)", a user following the docs will
  never create round 2 routes.
- Records copy (`cp ... docs/`) fails: `cp: target 'docs/' is not a directory`.

---

## E. Dogfood gaps (everything that broke, confused or surprised me)

| # | Class | Finding | Evidence |
|---|---|---|---|
| E1 | **BUG** | **`compliance` lets an earlier-round PASS mask a later-round FAIL.** `gate_passed_round` takes the max pass round; if it is < current round it prints `PASS*` and counts it. A blocking G7 fail at round 2 after a round-1 pass → exit 0 at T4 (the "hard gate"). Same-round: pass then fail → still PASS. The dashboard (latest-entry) says Fail. | T9 |
| E2 | **BUG** | **`compliance --tier` is trusted blindly.** No cross-check against the ledger's reconciled `actual` tier. `login-redirect` (reconciled T4) passes `--tier T1` and `--tier T2` with exit 0. Not listed in Known limits. | T10 |
| E3 | **BUG** | **Gate records are not tied to the change's commits.** Gates logged at commit `12b26d0` (before `util-trim` existed, on the wrong branch) satisfied `util-trim`'s compliance. The `commit` field is written but never checked. | T7 |
| E4 | **BUG/UX** | **Pre-push hook sha deadlock.** Hook requires a report naming `git rev-parse HEAD` (not the pushed `local_sha`); committing the report moves HEAD → blocked again. The kit's own ledger: 19/77 G7 entries are overrides, notes cite "bootstrapping deadlock". Also uses HEAD rather than the pushed ref's sha (wrong when pushing a non-checked-out branch). | T11 |
| E5 | **DOC/UX** | **Pre-push hook auto-commits `dashboard.html`** ("regenerated and committed ... Push once more") and runs the 30 s dashboard build on every push. README never mentions it. | T11 |
| E6 | **UX/DOC** | **Ledger and branches.** README never says whether to commit `ledger.jsonl`. Uncommitted: `git checkout main` aborts ("Your local changes ... ledger.jsonl"), and my next `reconcile` silently logged against the old branch's change name. Committed: two branches that each log a line **always** conflict on merge. Fix: ship `.pipeline/ledger.jsonl merge=union` in a project `.gitattributes`, and document. | T6, T12 |
| E7 | **BUG** | `mine-registry.sh` default output is cwd-relative `project/registry-draft.md`; run from the project root as documented, it creates `./project/` in the **user's repo root**. | T2 |
| E8 | **BUG/DOC** | Step 3 `cp -r .pipeline/templates/project .pipeline/project` nests into `.pipeline/project/project/` if `project/` already exists (re-running step 3, or running the miner from inside `.pipeline`). Tools then read the old/absent `surfaces.conf`. | T3 |
| E9 | **DOC** | On a small repo the miner's default `HUB_PCT=25` drops every file, printing "No co-occurring file pairs survived filtering." — not the README's documented message; the user cannot tell success from failure. | T2 |
| E10 | **DOC** | README/FAQ: "Nothing of yours matches the shipped example, so every change routes T0". False: the shipped example has `auth`, `lib`, `manifest.json`, `.css` rows, and routed my commits T4/T3. | T4 |
| E11 | **DOC/UX** | "You are done" → `status.sh` exits 1 listing all pre-install T3/T4 history as "never re-gated". No documented way to baseline. | T5 |
| E12 | **BUG** | `reconcile.sh` silently ignores unknown flags (`--round 2`, `--bogus`), logging round 1. The R0c hook text says "a new --round". | T8 |
| E13 | **DOC** | Walkthrough step 5 and checklist row 4 omit `ROUND=2` for re-entry. | T8 |
| E14 | **BUG** | `ledger.sh add --gate G9` accepted and written forever ("G9 (G9)"); `report` then lists it as an "authored extension". Gate id should be validated against the router/cards. | T6 |
| E15 | **BUG/DOC** | `blocking`/`minor` findings: README says they "need a file:line (or a command) location"; the tool only rejects an empty location (`blocking::somewhere::x` accepted). | T6 |
| E16 | **BUG** | `ledger.sh escape --found-by alien` accepted (vocab not validated). An escape on a change with no gate runs is counted in the escape rate although the tool says it is "baseline, not an escape". | T13 |
| E17 | **BUG (metric)** | Escape-rate denominator = all findings incl. `info` ("6 passed", "checked") → "2 escaped / 20 total defects". Info findings are not defects. | T13 |
| E18 | **UX** | `compliance` truncates footnote text mid-sentence: "R¹ Never blocks a *release*. For net-new user-facing capability on". | T6 |
| E19 | **UX** | Help text inside tool output uses kit-relative paths: `bash tools/ledger.sh assume ...`, `CHANGE=probe ... bash tools/reconcile.sh`, dashboard "bash tools/status.sh". In an install these are `.pipeline/tools/...`. | T6, T9 |
| E20 | **DOC** | `INCOMPLETE ... Run them, or log an explicit exception and own it.` — the README never says what an "explicit exception" is. | T6 |
| E21 | **UX** | `reconcile.sh --action prod-deploy` creates a change named `prod-deploy` that then shows forever as "🔄 In progress" in the dashboard and is told to run T4 compliance (6 gates) for a deploy declaration. Every deploy reuses the same change name and round 1. | T13 |
| E22 | **BUG** | `update-kit.sh` decides "Already current — nothing to do" from a fingerprint that hashes **only `tools/*.sh`**. An upstream change to `core/` (including the gate matrix in `core/01-router.md` that `compliance` reads) or `templates/` is never applied. | T14 |
| E23 | **UX** | `status.sh` prints "[!] THIS INSTALL IS CARRYING THE KIT'S OWN RECORDS" but exits 0, so `--quiet` and CI never see it. | T15 |
| E24 | **DOC** | `cp .pipeline/templates/{SESSION-HANDOFF,INTENT-LOG,LEARNINGS}.md docs/` fails without `mkdir -p docs`. | T16 |
| E25 | **UX** | `templates/agent-instructions.md` says "Keep it short" but the paste block is 70 lines. | T5 |
| E26 | **UX** | A `compliance` run with an unconfirmed assumption prints `UNCONFIRMED` but drops the `INCOMPLETE — N gates` summary line, so you fix the assumption and discover 4 more missing gates. | T6 |
| E27 | **UX** | `reconcile.sh` says "(logged to ledger) ... log the miss in the ledger" on UNDER-CLASSIFIED — it was just logged. | T6 |
| E28 | **WINDOWS** | Every tool is slow under Git Bash: `dashboard.sh` 27-34 s, `status.sh` 4.5-20 s, `compliance` 2-10 s; the pre-push hook adds the dashboard build to every push. CI windows-latest suite: 26 min vs ubuntu 1.5 min. | T5, CI |
| E29 | **WINDOWS** (ok) | CRLF ledger and CRLF `matrix.lock` are tolerated (tested). `.pipeline/.gitattributes` does not cover `*.jsonl` or `matrix.lock`; harmless today. `matrix.lock` embeds the author's absolute path `/d/work/gated-change`. | T17 |
| E30 | **DOC** | README "911 checks" matches no run (CI 906/905/893+20; local working tree 877). README "120+ gate runs across a dozen changes" — actual 352 across ~45. | C |
| E31 | **UX (honest-limit)** | The kit accepted my self-reported `G5 pass` for a test file that **did not parse** and `G6/G7 pass` for a `login.js` with a syntax error (my mistake via shell escaping). Caught only because I ran `node`. This is the README's "a gate is only as good as its reviewer" — worth showing as a concrete example, and a cheap mitigation is a `--evidence-cmd` that is executed and its exit code recorded. | T7 |
| E32 | **UX** | Dashboard "reason" for a change is the *last* route's reason, so one mistaken route ("Refactor") relabelled `login-redirect` everywhere. | B |

Claims I exercised and found **TRUE**: install refuses a hook with no T4 rows; `--confidence`
required on pass/fail (exit 2, nothing written); bad severity refused; out-of-scope needs
`filed:`; n/a at G8/T4 → REFUSED; UNRESOLVED for G8 at T3 with footnote printed; `defaulted`
assumption refused at T4; trunk branch name refused with clear message; `--action` refuses
unknown action and missing evidence; R0c Claude hook fires on T3/T4 paths (POSIX and Windows
paths) and is silent on CSS; status detects stale/customised hook, missing hooks, stale
dashboard, shipped example surfaces, kit's own records; reconcile's under-classification
(exit 1) and empty-diff refusal (exit 2); `measure.sh` rework ratio; all 5 example surfaces
parse.

---

## Prioritized backlog

| # | Change | Effort | Evidence |
|---|---|---|---|
| 1 | **Fix compliance round resolution**: a gate's governing outcome is the latest entry at the highest round ≤ `--round`; a later fail must override an earlier pass; `PASS*` only when no entry exists at a later round. Align with dashboard `computeStatus`. Add tests for pass(r1)→fail(r2) and pass→fail same round. | S | E1, T9 |
| 2 | **Cross-check `--tier`** against the highest `actual` tier among the change's route records; refuse (exit 1) when lower, print the reconciled tier. | S | E2, T10 |
| 3 | **Pre-push hook**: check the pushed `local_sha` (and accept a report naming any commit in the pushed range whose diff touches T4 paths, or the merge-base of the T4 change), so committing the report doesn't re-block. Document the workflow. | M | E4, 19/77 G7 overrides |
| 4 | **Ledger + git**: document "commit `ledger.jsonl` with the change"; ship `ledger.jsonl merge=union` via install-hook (or a `.gitattributes` line in Quick start). | S | E6, T12 |
| 5 | **README: Output glossary** — the three tables in section B (dashboard / compliance / status), each with cause and fix command. Link from every tool's output footer. | M | B |
| 6 | **README: dashboard screenshot + 5-line tour** (rail pills, Overview vs Technical, legend, Live vs Snapshot). | S | B |
| 7 | **README: 60-second demo block** at the top (section A) or `tools/demo.sh`. | S | A |
| 8 | **README: "Your first change" section** right after Quick start: branch, commit `.pipeline/`, `CHANGE=... REASON=... reconcile.sh`, gates, `ROUND=2` for re-entry, compliance — with real output. Add "Existing history" note (how status anchors; how to baseline). | M | A, E11, E13 |
| 9 | **README: Glossary** (tier, gate, card, matrix, footnote cell, round, R0a-R0d, G1a, Axis A-C, fresh/low, challenged, PASS*, escape, yield, disagreement, Harvest, Adapt, probe, grounding, ceilings, personas). | S | D1 |
| 10 | **README: headline-metrics section** replacing the stale "120+ gate runs" line with the section C wording (352 runs, 88 blocking findings, 15% miss rate, 19 overrides, no escapes recorded, CI status). Generate it from `ledger.sh report` so it cannot go stale. | S | C, E30 |
| 11 | `reconcile.sh` and `ledger.sh`: reject unknown flags; accept `--round N` on reconcile. | S | E12 |
| 12 | `mine-registry.sh`: default output to `$KIT_ROOT/project/registry-draft.md`; when every file is a hub, say so and suggest `HUB_PCT=100`; document both messages. Reorder Quick start so step 3 (create project/) precedes step 2. | S | E7, E8, E9 |
| 13 | Quick start step 3: `cp -rn` guard or `[ -d .pipeline/project ] || cp -r ...`. | S | E8 |
| 14 | `update-kit.sh`: fingerprint (or diff) `core/` and `templates/` too; at minimum compare file hashes before declaring "Already current". | S | E22 |
| 15 | Validate `--gate` against the router table, `--found-by` vocab; exclude `info` findings from the escape-rate denominator; exclude no-gate escapes from the rate. | S | E14, E16, E17 |
| 16 | Make README's `file:line` claim true (require `:\d+` or a leading command word) or soften the README. | S | E15 |
| 17 | Fix tool-printed paths to use the resolved kit path (`.pipeline/tools/...`), including dashboard strings. | S | E19 |
| 18 | `compliance`: print INCOMPLETE summary alongside UNCONFIRMED; don't truncate footnotes; name the exception command. | S | E18, E20, E26 |
| 19 | Fix FAQ "every change routes T0"; fix records copy (`mkdir -p docs`); list `T0::` rows in format; mention the hook's auto-commit. | S | E10, E24, E5 |
| 20 | `status.sh`: exit non-zero (or 2) for "carrying the kit's own records". | S | E23 |
| 21 | Fix `experiments/003/result.md` n statement; reconcile `001` tests_added. | S | C |
| 22 | Run the 10-change routed-vs-full experiment (section C) to make the effort row measurable; make `--minutes` part of every gate log in the kit's own use. | M | C |
| 23 | Windows performance: profile `dashboard.sh` (27-34 s) and make the pre-push regeneration optional. | M | E28 |
| 24 | Optional evidence execution: `--evidence-cmd '<cmd>'` that runs and records exit code, so a "pass" on a non-parsing test is caught mechanically. | M | E31 |

---

## Appendix — Transcript of commands run and key outputs (trimmed)

Paths: `S=.../scratchpad/dogfood`; project `$S/app`; `L=.pipeline/tools/ledger.sh`.

**T1 Step 1** — `cp -r gated-change/ app/.pipeline/ && cd app/.pipeline && rm -rf .git ledger.jsonl dashboard.html security-reports project SESSION-HANDOFF.md INTENT-LOG.md LEARNINGS.md dist releases tests experiments specs .claude .github` → ok; left `ACTION-PLAN.md`, `.gitattributes`, `.gitignore`.

**T2 Step 2**
```
$ bash .pipeline/tools/mine-registry.sh
  3 fix-shaped commits, 3 usable (2..15 files)
  dropped 2 hub file(s) present in >25% of commits: src/auth/login.js src/lib/util.js
No co-occurring file pairs survived filtering.
$ HUB_PCT=100 bash .pipeline/tools/mine-registry.sh
Wrote project/registry-draft.md            # -> $S/app/project/registry-draft.md (repo root!)
$ ls .pipeline/project  -> No such file or directory
```

**T3 nesting** — with `.pipeline/project/` pre-existing, `cp -r .pipeline/templates/project .pipeline/project` → `./.pipeline/project/project/surfaces.conf`.

**T4 status before editing surfaces** — exit 1; "T4 — trust boundary, never re-gated: e8bad49 bump version ... 41ce7ed init manifest" and "[!] surfaces.conf is still the shipped EXAMPLE".

**T5 Step 4/5** — `install-hook.sh` → "Guarding 2 T4 rule(s)"; `install-claude-hook.sh` → "Watching 3 T3/T4 rule(s)"; `status.sh` → exit 1, same 6 historical T4 commits. `reconcile.sh T4 --log` on main → "No changes against main — nothing to reconcile ... This is NOT a pass" exit 2.

**T6 T4 change** (`login-redirect`, predicted T2)
```
$ REASON="Bug fix: redirect after login" bash .pipeline/tools/reconcile.sh T2 --log
  T4  src/auth/login.js   Authentication — silent account takeover
  T3  src/lib/util.js     Shared module — many callers
UNDER-CLASSIFIED: predicted T2, actual T4.                         (exit 1)
$ bash $L add ... --gate G6 --outcome pass                 -> REFUSED: --outcome pass needs --confidence fresh|low. (exit 2)
$ bash $L add ... --finding "critical::..."                -> REFUSED: severity 'critical' ... Nothing was written. (exit 2)
$ bash $L add ... --finding "blocking::somewhere::x"       -> logged (exit 0)
$ bash $L add ... --finding "out-of-scope::README.md:1::typo" -> REFUSED: must say where it was filed (exit 2)
$ bash $L add ... --gate G9 --outcome pass --confidence low -> logged: G9 (G9) (exit 0)
$ bash $L compliance --change login-redirect --tier T4 --round 1
  PASS G1 · PASS G4 · NOT RUN G5 · SKIPPED G6 · FAIL G7 "1 finding(s) logged — re-run required"
  REFUSED G8 "logged n/a, but G8 is mandatory at T4 with no condition"
  CHECK G2 Scout R¹ Never blocks a *release*. For net-new user-facing capability on
  LOGGED G3 Craft n/a — no reason recorded
UNCONFIRMED — 1 assumption(s) ... bash tools/ledger.sh assume ...       (exit 1)
```

**T7 honest rounds** — round 2 G7 fail (`/\evil.com` bypass); round 3: all gates logged pass including G5 for a test that failed to parse (`SyntaxError: Invalid regular expression: missing /`) and G6/G7 for a `login.js` that did not parse; superseding G6 fail logged; round 4 after fixing, `node test/redirect.test.js` → "redirect tests: 6 passed"; `compliance --round 4` → "All T4-mandated gates satisfied at round 4." exit 0. Meanwhile `compliance --round 3` still printed "PASS G6 Peer ... All T4-mandated gates satisfied at round 3." after the superseding fail. `util-trim` gates logged at commit `12b26d0` (before the change existed) satisfied its compliance.

**T8 re-entry rounds**
```
$ REASON=... bash .pipeline/tools/reconcile.sh T4 --log --round 2
  logged: route login-redirect — round 1, predicted T4, actual T4 (match)   # --round ignored
$ bash .pipeline/tools/reconcile.sh T4 --bogus   -> runs normally, exit 0
$ ROUND=2 REASON=... bash .pipeline/tools/reconcile.sh T4 --log -> round 2
```

**T9 PASS masks later FAIL** (`--ledger ../probe.jsonl`)
```
6x add --round 1 --outcome pass --confidence fresh ; add --gate G7 --round 2 --outcome fail --finding "blocking::src/auth/login.js:3::regression introduced in round 2"
$ bash $L compliance --change probe --tier T4 --round 2
  PASS*  G7  Threat  passed at round 1 — 1 round(s) of changes since
All T4-mandated gates are satisfied, but 6 passed at an earlier round (PASS*).   (exit 0)
Dashboard for the same ledger: "Probe, Fail, round 2 of 2".
```
Also `compliance --change util-trim --tier T3 --round 5` (nothing logged at rounds 2-5) → exit 0 via PASS*.

**T10 self-declared tier**
```
$ bash $L compliance --change login-redirect --tier T1 --round 1
Tier T1 mandates no gates. Nothing to check.          (exit 0)   # ledger: reconciled T4
$ ... --tier T2 --round 1 -> All T2-mandated gates satisfied at round 1. (exit 0)
```

**T11 pre-push hook** (invoked directly: `echo "refs/heads/main $H refs/heads/main $B" | bash .git/hooks/pre-push origin x`)
```
BLOCKED — trust-boundary files changed and no report in .pipeline/security-reports names 806803f...
  Run the Threat gate against this commit, or: git push --no-verify
  and record the exception: bash .pipeline/tools/ledger.sh add --change <name> --gate G7 --outcome skipped --note 'why'
# with an uncommitted report naming HEAD:
pre-push: ledger had moved since .pipeline/dashboard.html was last generated -- regenerated and committed.
  ... Push once more to sync it                                  (exit 0)
# after committing the report (HEAD moved):
BLOCKED — ... names 639609d...                                   (exit 1)
```

**T12 ledger vs git** — `git checkout -q main` → "error: Your local changes to the following files would be overwritten by checkout: .pipeline/ledger.jsonl"; the following `reconcile` logged `route login-redirect — round 1, predicted T3, actual T4 (under), reason Refactor`. Two branches each appending one line → `CONFLICT (content): Merge conflict in .pipeline/ledger.jsonl`.

**T13 report / escape / action**
```
$ bash $L escape --change nosuch --found-by alien  -> logged (note: no gate runs ... baseline, not an escape)
$ bash $L report
  gate runs 33 · fresh-context 1 · low-confidence 32 · total findings 18
  G9 G9 1 run ... Not in core/01-router.md's table ... : G9
  MISS RATE 22% (match 7 · under 2) · ESCAPE RATE 10% = 2 escaped / 20 total defects
$ bash .pipeline/tools/reconcile.sh --action prod-deploy --evidence "yes I did it" --log -> logged (match); suggests T4 compliance for change "prod-deploy"
```

**T14 update-kit** — scratch `kit-v2` with `core/01-router.md` edited → `update-kit.sh ../kit-v2 --dry-run` → "installed: 1.0.0+ecd8dc91 / source: 1.0.0+ecd8dc91 / Already current — nothing to do."

**T15 un-stripped install** — `cp -r gated-change/ .pipeline/` only → status shows kit's LAST GATE, overdue `risks.md` reviews, "[!] THIS INSTALL IS CARRYING THE KIT'S OWN RECORDS" → exit 0.

**T16 records copy** — `cp ... docs/` → `cp: target 'docs/' is not a directory`.

**T17 Windows** — CRLF copies of `ledger.jsonl` and `matrix.lock`: compliance/report results identical. Dashboard: 27 s / 31 s / 34 s.

**Evidence commands (read-only)** — `ledger.sh report --ledger <copy of kit ledger>`; Python over the copy for severity/outcome counts; `gh run list --limit 100 --json conclusion,createdAt` → 20 success / 36 failure / 1 in progress, last success 2026-09-06; `gh run view 37315886418 --log` → ubuntu "passed 906 · failed 0 · skipped 1", windows "passed 905 · failed 0 · skipped 2", macOS "passed 893 · failed 20 · skipped 1" (`test_matrix_load_refuses_*`, `test_matrix_freeze_regenerates_a_working_reference`).
