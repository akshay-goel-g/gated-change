# confidence-vocabulary-refusal — Tasks

> Written at Triage, after design is confirmed. This is the plan and the record.

## Routing

| | |
|---|---|
| **Predicted tier** | T4 |
| **Surfaces touched** | `tools/ledger.sh` (T4 — `project/surfaces.conf:27`, *"Routing and evidence — a wrong answer here is silent and confident"*); `tests/run.sh` (T3 — the suite) |
| **Visibility** | behavior-changing — `ledger.sh add --confidence <x>` now exits 2 for `x` outside `fresh\|low` where it previously wrote the line |
| **Targets** | Git Bash on Windows (this session — full suite + targeted); Linux/macOS bash (CI legs — **GitHub Actions disabled for non-payment since 2026-09-08**, unconfirmable this session; the change is a pure bash `case`, no new command, no platform branch); Installed at `.pipeline/` (`newrepo` fixture); Kit as its own repo (N/A — `cmd_add` validation never reads `INCLUDE_KIT`) |

## Gates to run

From T4 (`core/01-router.md`): G1, G4, G5, G6 **M**; G7 **M (hard)**; G8 **M**.
G2 Scout — **not selected** (R¹, net-new capability only; internal validator fix).
G3 Craft — **not selected** (R², UI surface only; no UI).

- [x] G1 · Intent — requirements/design/tasks confirmed; assumptions logged (r1 ×3 `verified`, r3 ×1 `asked` — the mandatory-on-verdict decision). **pass** r1, **pass** r3.
- [x] G4 · Ripple — fresh, blind; all 4 `confidence` consumers walked; independence 5/5, ships alone. **pass** r1 (2 minor resolved same round + 1 info → registry row). **pass** r3 (making it required is enforcement not coupling — no ripple change; 3 info).
- [x] G5 · Proof — regression tests discriminate against every prior round; full suite **789/0/0**. **pass** r1, **pass** r3.
- [x] G6 · Peer — **fail r1** (comment/REFUSED string/test comment stated the failure mode backwards). r1-fix reworded all three. **pass r2** (fresh, verified line-by-line; 1 cosmetic info fixed). **fail r3** — `cmd_compliance`'s G1 remediation hint printed a `--outcome pass` command with no `--confidence` (a command the tool's own new check rejects); 3 info (stale comments). r3-fix `780c570`. **fail r4** — the r3-fix reshaped the defect: the hint printed `--confidence fresh|low`, which a shell parses as a pipe (`low: command not found`, exit 127) when pasted. r4-fix `3aba417`: concrete `--confidence fresh`. **pass r5** — two independent fresh blind reviews, both PASS: reproduced the r4 shell-pipe break (exit 127) and the fix (exit 0); all r1/r3/r4 findings verified resolved; guard logic re-exercised end-to-end. One review `challenged_premise: true` (the change is a *stricter* contract than "validate `--confidence` like `--outcome`" — it makes `--confidence` **required** on a verdict; deliberate, documented). Findings all `info`/`out-of-scope`, none correctness-affecting.
- [x] G7 · Threat — fresh, blind, **HARD GATE**. **pass r1** (refusal *shrinks* write-side surface; historical records parse unchanged; 1 minor inverted-narrative resolved same round + 3 info). **pass r3** ("making `--confidence` required is a net security improvement — removes the path by which an unflagged `add` silently wrote the privileged `fresh`"; 2 info). Report: `security-reports/2026-09-08-confidence-vocabulary-refusal.md` (round-1 + round-3 sections).
- [~] G8 · Dogfood — **fail r1** (omitted `--confidence` silently records `fresh`). r1-fix: warning. **fail r2** (warning insufficient; wants it required/moved). **User decision 2026-09-09: make `--confidence` REQUIRED for `pass`/`fail`.** **pass r3** ("the round-2 resolution is correctly and consistently implemented"; 2 info — both pre-existing, out of scope, filed).

**Round history:**
- **r1** code + tests (`3971a7f`) → G1/G4/G5/G7 pass, G6/G8 fail — every finding on the *rationale prose*, not the guard; 4 fresh gates converged on the inverted failure-mode narrative. r1-fix (`63da3c4`): reworded narrative ×3, added omitted-`--confidence` warning, corrected `--lane` claim, added registry row.
- **r2** G6 + G8 re-run fresh → **G6 pass** (narrative fixed; 1 cosmetic info), **G8 fail** (warning insufficient — default still favours `fresh`).
- **r3** user decision 2026-09-09 → `--confidence` **required** for a verdict (not warned, not defaulted; `8746e6c`). ~63 `tests/run.sh` fixture invocations + `core/04-ledger.md` (2 examples + the field row). Full suite **789/0/0** (fixtures on D: — C: temp volume full). Gates re-run fresh: **G1 pass** (in-context), **G4 pass** (independence 5/5 unchanged — enforcement not coupling), **G5 pass** (in-context — new test fails 6/10 vs r1 & r2, 10/0 vs r3), **G7 pass** (hard — "making `--confidence` required is a net security improvement"), **G8 pass** ("correctly and consistently implemented"). **G6 fail** — `cmd_compliance`'s G1 remediation hint printed a `--outcome pass` command with no `--confidence` (the tool printed a command its own new check rejects). r3-fix (`780c570`): `--confidence fresh|low` added to the hint; 3 stale comments refreshed (`tests/run.sh`, `app.js` ×2 — comment-only); `04-ledger.md` row qualified; registry row expanded.
- **r4** G6 re-run fresh on the r3-fix (`780c570`) → **fail**: the fix reshaped rather than closed the defect — the hint now printed `--confidence fresh|low`, a shell pipe when pasted (`low: command not found`, exit 127). r4-fix (`3aba417`): one `echo` string, concrete `--confidence fresh` (matches the adjacent `--outcome pass` and `core/02-gates.md:113`); no runtime path touched.
- **r5** G6 re-run fresh + blind on `3aba417` → **pass**, two independent subagent reviews. Both reproduced the `fresh|low` break (exit 127) and the concrete-`fresh` fix (exit 0, writes `confidence:fresh`); both grepped every emitted `ledger.sh add` hint in `tools/`/`core/`/`project/` (the others use `--outcome n/a`, confidence-exempt — no same-class defect); both re-exercised the `cmd_add` guard end-to-end and confirmed all r1/r3/r4 findings resolved. Review 1: `challenged_premise: true` (change is stricter than "validate like `--outcome`" — `--confidence` is **required** on a verdict, default removed; deliberate + documented). Review 2: `challenged_premise: false`. Findings across both: 4 `info` + 1 `out-of-scope` (the pre-existing `--lane` gap, chip `task_f3d8c045`; a `registry.md:38` wording imprecision). No correctness-affecting finding. Full suite **789/0/0**; `bash tests/run.sh confidence` **31/0/0**, `ledger` **228/0/0**.
- **compliance r5**: all T4 gates satisfied (exit 0). G1/G4/G5/G7/G8 carry as **PASS\*** from r3 — the r4/r5 delta is one `echo` string plus comment refreshes, touching no gate's input: G5's suite is unchanged (789/0/0), G7's security surface is untouched (the r3 report binds to the landed tip), G4 adds no coupling, G1's intent is unchanged. KIT DRIFT note is the embedded-kit commit hash moving, not a tooling change.

Also filed 2 background chips: guard `--lane`/`--model` in `cmd_add` (G4 r1, `task_f3d8c045`); and a `tests/run.sh` isolation bug — a full temp disk makes `mktemp` fail, `REPO` becomes `""`, and `git -C "" commit` hits the real repo (surfaced during the G5 discrimination proof; 3 stray "base" commits were `reset --soft` out).

**Compliance (after r5):** `bash tools/ledger.sh compliance --change confidence-vocabulary-refusal --tier T4 --round 5` → all satisfied.

## Steps

Ordered, each independently verifiable.

- [ ] **1. Reproduce first (G1a discipline).** `newrepo`; `led add --change c --gate G7
      --tier T4 --outcome pass --confidence true`. Confirm pre-fix: exit 0, line written,
      `jsonl_last_field confidence` = `true`. Load that one-line ledger in
      `tests/dashboard-logic.test.js`-style and confirm `isSelfCheck` is true / `freshRuns`
      does not count it. **Verify:** the bad line exists and reads as a self-check.
- [ ] **2. Implement the `case`** in `tools/ledger.sh` `cmd_add`, immediately after the
      `--outcome` `case` (`ledger.sh:477`): `case "$confidence" in fresh|low) ;; *) echo
      REFUSED … ; exit 2;; esac`. **Verify:** step-1 command now exits 2, nothing written;
      `--confidence fresh` / `low` still exit 0.
- [ ] **3. Correct the stale comment** at the pre-`emit()` block (`ledger.sh:~513`):
      "tier/gate/outcome/confidence reach here only after a closed-set check … `lane` has no
      such check (free text by design)". **Verify:** reads coherently against the code; no
      apostrophe hazards.
- [ ] **4. Add `test_ledger_refuses_an_unknown_confidence`** to `tests/run.sh` (next to
      `test_ledger_refuses_an_unknown_outcome`, `run.sh:~1216`): loop
      `true tru freshh high same-session self medium ""`, each → exit 2 + `REFUSED`; then
      assert the ledger has no `"gate":"G7"` line. **Verify:** passes post-fix; fails against
      `git show HEAD:tools/ledger.sh` swapped in (discrimination proof).
- [ ] **5. Add `test_ledger_still_accepts_fresh_and_low_confidence`** — `fresh` exit 0;
      `low` exit 0 and reads back `low`; no-flag reads back `fresh`; `--outcome skipped`
      no-flag reads back `low`. **Verify:** green; this is the "guard rejects only what is
      outside the vocabulary" control.
- [ ] **6. Full suite** — `bash tests/run.sh`. **Verify:** 0 failed, 0 skipped beyond the
      pre-existing platform skips; record pass count vs the pre-change baseline (759).
- [ ] **7. `node tests/dashboard-logic.test.js`** — confirms the historical `high` /
      `self` / `same-session` fixtures still parse. **Verify:** "all dashboard logic tests
      passed".
- [ ] **8. Regenerate the dashboard** (`bash tools/dashboard.sh`). **Verify:** renders; the
      new gate rows for this change appear once logged.

## Reconciliation

Run after Build, before release:

```bash
CHANGE=confidence-vocabulary-refusal REASON="Bug fix: cmd_add validated every closed-set field except --confidence, so a typo wrote a record the dashboard reads as a self-check that actually ran fresh" bash tools/reconcile.sh T4 --log
```

| | |
|---|---|
| **Actual tier** | T4 (`tools/ledger.sh` T4, `tests/run.sh` T3 — max T4) |
| **Verdict** | expect `match` — predicted T4 == actual T4, round 1 |
| **Gates re-run** | n/a expected — single round; R0c hook fired on each planned edit (expected, this IS the routed change) |

## Acceptance

Filled at Intent · Accept, after Build. Mirrors `requirements.md`'s G1b table.

| Criterion | Evidence |
|---|---|
| `--confidence` outside `fresh\|low` → exit 2, nothing written | `git show 3971a7f` — the new `case` in `cmd_add`; `test_ledger_refuses_an_unknown_confidence` green + discrimination proof |
| `--confidence` required for a `pass`/`fail` verdict, exempt for `skipped`/`n/a` | `git show 8746e6c` — the `elif` after the `case`; `test_ledger_requires_confidence_on_a_verdict` green |
| `fresh` / `low` / default / skipped-downgrade still write | `test_ledger_still_accepts_fresh_and_low_confidence` green |
| Stale comment corrected | `git show 3971a7f` — pre-`emit()` comment block ("`lane` has no such check") |
| `cmd_compliance`'s own emitted `add` hint runs against the new guard | `git show 3aba417` — concrete `--confidence fresh`; G6 r5 reproduced it verbatim → exit 0 |
| Historical out-of-vocab records still parse | `node tests/dashboard-logic.test.js` green; `bash tests/run.sh confidence` → 31/0/0 |
| Full suite green | **789 / 0 / 0** at tip `020000c` (`bash tests/run.sh`, TMPDIR on D:), + `node tests/dashboard-logic.test.js` all green; baseline before this change ≈ 759 |

## Ledger

One line per gate run appended to `ledger.jsonl`, `--change confidence-vocabulary-refusal`
`--tier T4` `--model claude-sonnet-5` `--tokens N`. Route record via the reconcile command
above. Assumptions logged round 1: refuse-vs-warn (verified against `04-ledger.md` + cards),
historical records left as-is (verified against the never-backfill rule).
