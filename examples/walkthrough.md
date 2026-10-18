# Worked example — one change, start to finish

A small web app. The task: *"fix the redirect after login."* Every command and every block
of output below is from a real run of this kit's tools in a throwaway repo (paths trimmed).
Nothing here is mocked — if a command looks surprising, that is what it printed.

The project's `.pipeline/project/surfaces.conf` contains:

```
T4::(^|/)auth/::Authentication — a bug here is a silent account takeover
T3::(^|/)lib/::Shared module — many callers
T2::(^|/)components/::Feature code
T1::\.(css|scss)$::Styling
ACTION::T4::prod-deploy::Deploy log URL or the CI run that shipped to production
```

---

## 1 · Predict (R0a)

It sounds like a one-liner, so the prediction is **T1**. Before writing code, name what was
assumed rather than asked:

```bash
bash .pipeline/tools/ledger.sh assume --change fix-login-redirect \
  --assumed "Redirect target is same-origin only" \
  --resolution asked --basis "confirmed with requester"
```
```
logged: assumption on fix-login-redirect (round 1) — asked → .pipeline/ledger.jsonl
```

`--resolution` is `asked`, `verified` or `defaulted`. `defaulted` is legal and logged — but
`compliance` will refuse it at T3/T4, because a gate that verifies an invented premise
passes while checking the wrong thing.

## 2 · Build, then reconcile (R0b)

The fix edits `src/auth/login.js`. Now compare the prediction to what actually happened:

```bash
git checkout -b fix-login-redirect
# ...edit src/auth/login.js, commit...
REASON="Bug fix: redirect after login" bash .pipeline/tools/reconcile.sh T1 --log
```
```
R0b Reconcile — 1 file(s) vs main

Surfaces hit
------------
  T4  src/auth/login.js        Authentication — a bug here is a silent account takeover

Targets to verify (every one needs evidence in the test gate)
-------------------------------------------------------------
  [ ] Chrome                         Playwright e2e
  [ ] Safari                         manual pass on a real device

Actual tier : T4
Predicted   : T1
Gates       : Intent, Ripple, Proof, Peer, Threat(HARD GATE), Dogfood
Also check  : Scout¹, Craft²  (recommended; the footnote may make it mandatory)

  logged: route fix-login-redirect — round 1, predicted T1, actual T4 (under) → .pipeline/ledger.jsonl

UNDER-CLASSIFIED: predicted T1, actual T4.
Run the gates T4 requires before release, and log the miss in the ledger.
```

Exit code **1**. The "one-line fix" is a trust boundary, which is exactly the mistake this
step exists to catch — and the miss is now in the ledger, where it feeds the miss-rate
metric.

## 3 · Ask the question that decides release

```bash
bash .pipeline/tools/ledger.sh compliance --change fix-login-redirect --tier T4 --round 1
```
```
Gate compliance — fix-login-redirect, tier T4, round 1
-------------------------------------------------------
  NOT RUN    G1   Intent
  NOT RUN    G4   Ripple
  NOT RUN    G5   Proof
  NOT RUN    G6   Peer
  NOT RUN    G7   Threat
  NOT RUN    G8   Dogfood

INCOMPLETE — 6 mandated gate(s) without a pass: G1 G4 G5 G6 G7 G8
```

Exit code 1 again. Six gates have not decided this change.

## 4 · Run the gates

Each verify gate runs in a **fresh session** (a subagent works) that is handed the gate's card
from `core/cards/`, the diff, and the registry — and *not* your explanation of the change.
Here the Threat gate finds a real problem and the result is logged, with its finding:

```bash
bash .pipeline/tools/ledger.sh add --change fix-login-redirect --gate G7 --tier T4 --round 1 \
  --outcome fail --confidence fresh --challenged true --tokens 9000 \
  --finding "blocking::src/auth/login.js:1::redirect target taken from query string — open redirect"
```
```
logged: G7 (Threat) on fix-login-redirect — round 1, 1 finding(s), fail → .pipeline/ledger.jsonl
```

The temptation at this point is to log G8 as `skipped` or `n/a` and move on. Try it:

```bash
bash .pipeline/tools/ledger.sh add --change fix-login-redirect --gate G8 --tier T4 --round 1 \
  --outcome n/a --note "no browser available"
bash .pipeline/tools/ledger.sh compliance --change fix-login-redirect --tier T4 --round 1
```
```
  FAIL       G7   Threat    1 finding(s) logged — re-run required before release
  REFUSED    G8   Dogfood   logged n/a, but G8 is mandatory at T4 with no condition
```

The ledger accepts the line (honest bookkeeping is always allowed) but `compliance` does
not count it. `n/a` is only valid where the router's matrix cell carries a footnote
condition; `skipped` is never a pass.

## 5 · Fix, then re-enter (R0c) at round 2

The fix edits `src/auth/login.js` again — a T4 file, edited *after* routing ran. That is the
highest-risk edit in a session, so it goes back through reconcile at a new round:

```bash
REASON="Bug fix: redirect after login" bash .pipeline/tools/reconcile.sh T4 --log
```

(On Claude Code, `tools/install-claude-hook.sh` makes the edit itself print a reminder, so
this step no longer depends on anyone remembering.)

Re-run the gates against the new commit and log each one as round 2:

```bash
for g in G1 G4 G5 G6 G7 G8; do
  bash .pipeline/tools/ledger.sh add --change fix-login-redirect --gate $g --tier T4 --round 2 \
    --outcome pass --confidence fresh --challenged true --tokens 5000 \
    --finding "info::src/auth/login.js:1::redirect target is now checked against an allow-list" \
    --note "Bug fix: users land on a blank page after login"
done
```

*(In real use each of those is a separate fresh review whose findings you log — a loop that
writes six passes is only here to keep the example short. `04-ledger.md` calls an entry
written without the work "fiction with a timestamp".)*

## 6 · Check release readiness

```bash
bash .pipeline/tools/ledger.sh compliance --change fix-login-redirect --tier T4 --round 2
```
```
Gate compliance — fix-login-redirect, tier T4, round 2
-------------------------------------------------------
  PASS       G1   Intent
  PASS       G4   Ripple
  PASS       G5   Proof
  PASS       G6   Peer
  PASS       G7   Threat
  PASS       G8   Dogfood

All T4-mandated gates satisfied at round 2.
```

Exit code **0**. Now it can ship.

## 7 · Declare the release event

Deploying to production changes no file, so no diff can see it. Declare it:

```bash
bash .pipeline/tools/reconcile.sh --action prod-deploy --evidence "https://ci.example.com/run/4821" --log
```
```
Actual tier : T4
Gates       : Intent, Ripple, Proof, Peer, Threat(HARD GATE), Dogfood
No predicted tier given for a declared action — using T4, the action's own tier.
Reconciled — routing matches.
```

## 8 · Look at the numbers

```bash
bash .pipeline/tools/ledger.sh report
bash .pipeline/tools/dashboard.sh        # writes .pipeline/dashboard.html — open it in a browser
bash .pipeline/tools/status.sh           # compares the ledger to git history
```

An excerpt of `report` after the run above:

```
LEADING — reconcile miss rate
-----------------------------
  reconciliations    1   (match 0 · under 1 · over 0)
  MISS RATE          100%  ← under-classified
  Routing is misfiring now. Your surfaces file is missing rules, or
  you are systematically tiering low. Fix this before trusting any gate.
```

With one data point that is a statement of fact, not a trend — but it is the metric to watch
in month one.

## 9 · If a bug escapes anyway

A month later a user reports the redirect still misbehaves on Safari:

```bash
bash .pipeline/tools/ledger.sh escape --change fix-login-redirect --found-by user --severity high
```

This is the lagging metric that matters. The record links the defect back to the change and
the gates that passed it — so you can ask which gate should have caught it, and write the
answer into `LEARNINGS.md` and (if it was a coupling) `project/registry.md`.

---

## What to take from this

| Moment | What the kit did that memory would not have |
|---|---|
| Step 2 | Caught a "one-line fix" that was a trust boundary, by reading the diff |
| Step 3 | Refused to call a change ready because nothing had decided it |
| Step 4 | Would not let `n/a` stand in for a gate the router says is mandatory |
| Step 5 | Re-routed a fix made *after* routing — the edit most likely to skip review |
| Step 7 | Recorded an irreversible event that no diff contains |
