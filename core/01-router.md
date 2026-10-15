# 01 — The Router

> Portable. Do not edit. Your surfaces and targets live in `project/surfaces.conf`.

Routing happens **twice**. This is the most important structural rule here: you classify a
change when you know least about it, and the error is always biased toward
*under*-classification.

---

## R0a · Triage · Predict (before work)

A two-minute guess on four axes, producing a provisional gate set.

### Axis A — Change tier

| Tier | Name | Definition |
|---|---|---|
| **T0** | Cosmetic | Copy, comments, docs, non-shipping assets. Zero behavior change |
| **T1** | Local | One module. No shared state, no new public surface, trivially revertable |
| **T2** | Feature-scoped | One feature end to end. May own new storage and UI |
| **T3** | Cross-cutting | Shared modules, persisted schema, message handlers, 2+ features |
| **T4** | Irreversible | Trust boundaries, permissions, migrations — **or anything a user cannot undo, and anything touching money** |

**When torn between two tiers, take the higher one.** This is a request, and requests are
weak — which is exactly why R0b exists.

### Axis B — Surface touched

Defined per project in `project/surfaces.conf`. Any hit on a trust surface forces **T4**.
This part is mechanical, not a judgment call — that is the point of putting it in a config
file rather than in someone's memory.

The general rule for what belongs there: **if breaking it would be silent, it is T4.** Visible
breakage gets reported by users; silent breakage does not.

### Axis C — User visibility

- **Invisible** — internal refactor → Dogfood may be skipped
- **Visible** — user sees something new → Dogfood mandatory, end-to-end test mandatory
- **Behavior-changing** — an existing workflow changes → Dogfood mandatory, plus "what breaks
  for someone mid-operation?" asked explicitly in Ripple

### Axis D — Targets affected

A change that passes on one platform and breaks another is the classic escape: every gate
ran, and none of them ran *there*. Targets are listed in `project/surfaces.conf`.

**Every target listed must appear in Proof's evidence.** "It should work the same" is a
prediction, not a test.

---

## R0b · Triage · Reconcile (after Build, before Release) — hard gate

Predictions are wrong. This step is mechanical and non-negotiable.

```bash
bash tools/reconcile.sh T2      # your predicted tier
```

It recomputes the tier from the diff that actually happened and compares.

**Set `REASON=<text>` to record why this change exists** — e.g. `REASON="Bug fix"
bash tools/reconcile.sh T2 --log`. Recorded on the route record, read back by
`ledger.sh compliance` at T3/T4 and by the dashboard's "Why this happened" —
optional, and `reconcile.sh`'s own header has the full flag list. G1's own note
(`cards/G1-intent.md`) answers the same question and is read the same way;
either is enough, so relying on G1 alone is fine too.

**Set `CHANGE=<name>` when `--log`ging from a trunk branch.** `--change` defaults to
the current branch, and a route record named `master` collects reconciles from every
change and correlates with none — `ledger.sh` refuses that name, and `--log` fails
loudly rather than recording a reconciliation that will not join up with its gates.
A branch named for the change (or an `--action` run, which uses the action name) needs
nothing extra.

| Outcome | Action |
|---|---|
| actual == predicted | Proceed |
| **actual > predicted** | **Stop.** Run every gate the higher tier requires. Log the miss |
| actual < predicted | Proceed. Over-classification is free; note it so predictions improve |

**A change may not reach Release without a reconciliation result recorded.** Without this
step, tiering is an honor system operated by the person who benefits from cheating.

**Reconciled is a routing verdict, not a release verdict.** It answers "is this the tier I
thought it was", never "did the gates that decide this actually run". That second question
is mechanical too, and it is the one that gets skipped:

```bash
bash tools/ledger.sh compliance --change <name> --tier T4 --round 1
```

It reads the ledger and exits non-zero when a tier-mandated gate has no **pass** — treating
`skipped` as what it is. Log a skip honestly and the report still counts it against you,
which is the point: honest bookkeeping is not the same as having done the work.

**The footnotes below are conditions this check cannot evaluate.** `M⁵` means G8 is
mandatory *unless the change is invisible*, and nothing in the ledger records visibility. So
a footnoted mandate with no verdict reports `UNRESOLVED` and prints the footnote — the
question, not just the refusal. Answer it by running the gate, or by recording that it does
not fire here:

```bash
bash tools/ledger.sh add --change <name> --gate G8 --tier T3 --outcome n/a \
  --note "Axis C invisible: internal storage rename, no user-facing surface"
```

`n/a` is accepted **only** where the matrix cell carries a footnote. G7 at T4 is `M (hard)`
with no condition attached, so an `n/a` against it is `REFUSED` — the escape hatch is exactly
as wide as the router says it is, and no wider. The reason is required because a judgment
call with no reason on the record is indistinguishable from a gap in the record.

**R0b routes one change against one base — nothing here catches drift across several.** A
permission set can widen one file at a time across six separately-reconciled, separately-passed
PRs, with no single diff ever crossing a T4 rule. `BASE` is a plain env var, so pointing it at
the last shipped release rather than the branch point costs nothing new to build:

```bash
BASE=v1.2.0 bash tools/reconcile.sh T4   # everything since the last thing users actually got
```

This is a release-time habit, not a per-PR one — run it once before Release, in addition to,
not instead of, the per-change R0b that already ran on each PR.

---

## R0c · Re-entry — the rule that stops mid-session drift

R0a fires "before any change." The failure that rule does not cover is the **second** change:
you are mid-session, a gate turns up a defect, you fix it, and the fix never passes through
routing at all — because it does not feel like a change, it feels like finishing the current
step.

That is the highest-risk edit in the session. It is reactive, it is unplanned, it lands
while attention is on something else, and it is disproportionately likely to touch exactly
the surface the gate was inspecting.

**The rule:** any edit to a file matching a **T3 or T4** row in `surfaces.conf`, made after
R0a has already run, re-enters the pipeline at R0a for *that edit*. Not the whole change —
just the new edit, which is usually seconds of work.

| Signal | What it means |
|---|---|
| A gate finding leads to an edit | Re-enter. The edit was never routed |
| The edit touches a T3/T4 surface | Re-run R0b, and the gates the tier mandates, at a new `--round` |
| The edit touches T1/T2 only | Note it; no re-entry required |

**Mechanically:** run reconcile again. It reads the working tree, not your memory of it, so
a surface you did not notice touching shows up anyway. The round number is what keeps the
two passes distinguishable in the ledger — same change, different commit, different verdict.

**On Claude Code, this no longer has to rely on remembering.** `tools/install-claude-hook.sh`
wires a `PostToolUse` hook that fires on every `Edit`/`Write`/`MultiEdit`, checks the file
against these same T3/T4 rows, and reminds when it matches — see `05-enforcement.md` §4.

---

## R0d · Reconcile · Action — declared events, at Release, not after Build

R0a and R0b both tier a **diff**. `git diff --name-only` is R0b's only input, and every
`TIER::REGEX::LABEL` row in `surfaces.conf` matches a PATH. For an installable artifact
distributed through a store, the events that concentrate the most real-world irreversibility
change **zero files**: pressing Publish (a version that can never be reused or recalled), a
permission-warning delta a reviewer approved, ramping a staged rollout, rotating or losing the
signing key, editing the store listing or privacy disclosure. Each is T4 by this file's own
Axis A definition — "anything a user cannot undo" — and none of them are diffs, so no row,
however well written, can ever route them through R0a/R0b. `LEARNINGS.md` names this gap in
full ("The router can only tier a diff…"); this section is the mechanism that closes it.

**Why this is not just another clause in R0b.** R0b's whole shape assumes a Build already
happened and a diff already exists — "after Build, before Release" is in its own heading. An
`ACTION` has neither: `14-phases.md` already says out loud that **Release has no chapter and
no executor** in this kit, and a store publish IS a Release event, not a Build one. Folding
`--action` into R0b's existing flow rather than giving it a distinct name would have hidden
that timing mismatch instead of stating it — so this gets its own letter, R0d, even though
today it lives in the same script (`reconcile.sh`) and the same file (`surfaces.conf`) as R0b.
If this kit ever grows a real Release phase with its own executor, R0d is what that phase
should call.

### The row

```
ACTION::TIER::NAME::EVIDENCE
```

| Field | Meaning |
|---|---|
| `TIER` | T1..T4, same meaning as a `TIER::REGEX::LABEL` row |
| `NAME` | What `--action` names on the invocation. Free text, matched exactly |
| `EVIDENCE` | What a citation for *this* action should look like — a screen, a URL, a response body. The role `TARGET`'s `HOW_VERIFIED` plays for targets |

`ACTION` rows share the file with `TIER`/`IGNORE`/`TARGET` rows and must never be treated as
one. An `ACTION` row has **four** `::`-separated fields, not three — `reconcile.sh`'s
path-tiering loop explicitly excludes `ACTION::` before it ever reaches the `*::*::*` shape
check, because a NAME like `store-publish` grepped against a file list matches nothing,
silently, forever: exactly the failure class a fresh-context review of this same branch's
`tools/lib/matrix.sh` found once already (a malformed gate-table row silently dropped a HARD
GATE with exit 0 — `security-reports/2026-08-13-first-push-matrix-hook-review.md`, Finding 1).
`reconcile.sh` validates every `ACTION` row's shape on **every** run, not only when `--action`
is used, and refuses loudly (exit 2) if one is malformed — a silently-dropped `ACTION` row
would otherwise surface later as "NAME not found," which reads like a typo in the invocation
rather than the broken config file it actually is.

### The invocation

```bash
bash tools/reconcile.sh --action store-publish --evidence "https://play.google.com/console/…"
```

- **Both flags are required together.** An action with no evidence is exactly the unmeasured
  claim `04-ledger.md`'s evidence rule refuses everywhere else; evidence naming no action is
  evidence of nothing. Either alone is refused before any git or file work happens.
- **NAME must match a declared `ACTION` row.** An unknown name is refused, and the refusal
  lists every `ACTION` row it *did* find — not a bare "not found."
- **Composes with a diff-based reconcile in the same call.** `bash reconcile.sh T2 --action
  store-publish --evidence "…"` is valid: `ACTUAL` becomes the higher of whatever the diff hit
  and whatever the `ACTION` row declares, the same max-of-hits computation path rules already
  use when two of them hit one file. A release commonly has both a version-bump diff and a
  publish action, and folding them into one reconciliation means a human who predicts a low
  tier for "just the version bump" still gets caught by `UNDER-CLASSIFIED` if the action
  underneath it is T4 — a separate call could not do that.
- **With no `[predicted-tier]`, prediction defaults to the action's own tier.** There is
  nothing to *guess* about a fact being declared — the tier is read out of `surfaces.conf`,
  not estimated before the work is understood, the way R0a's guess is. `PREDICTED = ACTUAL`
  makes the verdict `match` by construction and reuses the same `--log`/exit path every other
  reconcile takes, rather than a second one that could drift from it.
- **A pure `--action` run with no file changes at all is not an empty diff.** Publishing an
  artifact that was built and committed days earlier, with nothing new in the working tree
  today, must not trip the "nothing to reconcile" refusal that a genuine empty diff earns —
  the action itself is the reconciliation event.

### The ledger

`ledger.sh route` gains two optional fields, present only on an action-based route:
`"action":"<name>"` and `"evidence":"<citation>"` — see `04-ledger.md`. Both are required
together at the ledger layer too, independently of `reconcile.sh`'s own check: `ledger.sh` is
the one piece of this kit `04-ledger.md` calls "not self-graded," so it holds the pairing rule
itself rather than trusting whatever called it.

### What this does not close

Named here rather than left implicit, matching this file's own standard for every other
partial mitigation:

- **Nothing detects the event, or forces it to be declared.** `--action` is a declaration, not
  a sensor. A human or agent who forgets to run it at the moment of publishing leaves the
  pipeline exactly as blind as before this section existed.
- **`EVIDENCE` is checked for presence only**, not shape or content — the same bar G7's
  `finding` citations hold today. Whether that should require a URL, a screenshot path, or
  stays "non-empty, human-readable" is open.
- **No retraction.** An `ACTION` declared by mistake stays in the ledger, append-only, and is
  corrected the way every other bad ledger line is corrected: a superseding entry, never an
  edit to the original.
- **No compliance check that an `ACTION` was ever exercised.** `ledger.sh compliance` checks
  whether a *mandated gate* ran; it does not check whether a release-shaped change ever
  exercised the `ACTION` row it should have, the way it already checks the former. That would
  be the natural next mechanical check. Not built in this pass.

`BASE=<last-release-tag> bash tools/reconcile.sh T4` (R0b, above) remains the other half of
this gap's mitigation — it catches diff-shaped drift accumulated across several already-merged
PRs. It is unaffected by any of the above; the two do not substitute for each other.

---

## The gate matrix

`M` mandatory · `R` recommended · `—` skip

| Gate | Persona | Budget | T0 | T1 | T2 | T3 | T4 |
|---|---|:---:|:--:|:--:|:--:|:--:|:--:|
| **G1 · Intent** | Product manager | 15 min | — | — | R | M | M |
| **G2 · Scout** | Analyst | 20 min | — | — | R¹ | R¹ | R¹ |
| **G3 · Craft** | Designer | 15 min | — | — | R² | R² | R² |
| **G4 · Ripple** | Release engineer | 10 min | — | R | M | M | M |
| **G5 · Proof** | SDET | 30 min | — | R³ | M | M | M |
| **G6 · Peer** | Staff engineer | 15 min | — | R | M | M | M |
| **G7 · Threat** | Security engineer | 20 min | — | — | R⁴ | M | **M (hard)** |
| **G8 · Dogfood** | Real user | 15 min | — | — | M⁵ | M⁵ | M |

¹ Never blocks a *release*. For net-new user-facing capability only. Its output still lives
  in `requirements.md` and is confirmed like the rest of that file before `design.md` —
  "non-blocking" is about the release decision, not about whether the user reviews it.
² Only when a UI surface changes.
³ **M** for any bug fix — a fix without a regression test is not a fix.
⁴ **M** whenever the change accepts user input, persists data, or makes a network request.
⁵ Skip only when Axis C is *Invisible*.

**Budgets are limits, not targets.** A gate that routinely overruns is mis-scoped: split it
or narrow its question.
