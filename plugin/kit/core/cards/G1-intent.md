# G1 · Intent

```yaml
id:           G1
name:         Intent
persona:      Product manager
question:     "Who is this for, what does done mean — and did we build that?"

owns:         the ask, and whether it was met
does_not_own: how it is built (G4) · whether the code is right (G6) · how it looks (G3)
responsible:  Change owner            # govern.md

fires:        T2 recommended · T3+ mandatory
trigger:      [net_new_capability, user_visible_behaviour_change]

input:        the request, in the requester's own words · existing feature docs ·
              for a described defect, whether it still reproduces in current code
withhold:     your implementation plan — G1a must not be shaped by how you intend to build it
context:      same session is fine (this is not a review gate)

output:       specs/<feature>/requirements.md · acceptance table appended after Build
passes_when:  every acceptance criterion maps to something demonstrable
fails_when:   a criterion has no evidence, or "done" cannot be stated in two sentences
must_ask:     what "done" means, and who this is for, whenever the request does not say.
              This gate INVENTS the spec every gate below then verifies against, so an
              assumption here is the one that survives the whole pipeline unexamined —
              10-probe.md checkpoint 1, and the reason `ledger.sh assume` exists. Also:
              which of two materially different readings of an ambiguous word was meant
overfit_when: acceptance criteria restate the request in a table · every criterion is
              testable and none is contestable · scope is exactly what was asked with
              nothing questioned, on a request that was plainly a first draft
underfit_when: "done" is a paraphrase of the title · criteria that cannot fail ("works
              correctly", "is performant") · the requester's framing accepted whole,
              with no smaller version considered (10-probe.md checkpoint 1)
budget:       10min define + 5min accept
model:        mid                            # judgment, and the user confirms requirements.md anyway
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G1 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--evidence <file:line> | --evidence-cmd EVIDENCE::<name>]   # a fresh T3/T4 pass must cite: an info --finding with a real file:line, or one of these
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  the requester, when a criterion turns out to be ambiguous
retire_if:    never
```

---

## Runs twice

Defining a requirement and confirming you met it are different acts, and the second is where
AI-assisted work most often fails: the model builds something *adjacent* to the request,
demonstrates it confidently, and nobody compares it back to the ask.

### G1a · Define — before Build

Acceptance criteria are **demonstrable behaviors**. "Fast" is not a criterion; "renders in
under 200ms with 500 rows" is. An adjective cannot be shown to anyone.

**Restate before building.** Write the requirement back in your own words and confirm it
before code exists. If the restatement and the request differ, the request was ambiguous —
**fix the requirement, not the wording.**

*Trial addition (`core/11-evolution.md` Step 7 — not yet backtested against real past changes,
flagged here rather than presented as settled; review after 10 firings or 30 days):* **skim
recent `INTENT-LOG.md` entries for the touched area before writing `requirements.md`.** The log
holds decisions git does not — scope already cut, questions already left open — and a
requirement written without checking it risks re-deriving (or re-litigating) ground a past
session already covered.

**If the request describes a defect or a missing behavior, reproduce it before scoping the
fix.** A backlog is a snapshot; the code has moved since it was written. Read the function the
request names before writing acceptance criteria for it — not after. Two failure modes this
catches, both cheap to check and expensive to discover mid-Build:

- **Already fixed.** The described behavior no longer exists — building "the fix" produces a
  no-op that looks complete and changes nothing.
- **Already reverted.** The described behavior existed once and was deliberately removed
  (`git log -S<value or key name>` on the field the request wants to add). Rebuilding it
  without reading why it was removed can re-break whatever the removal fixed. This is *also* a
  registry entry (03-registry.md) so G4 Ripple gets a second chance at it after Build — but
  catching it here costs a `git log` call instead of a build-test-revert cycle.

This check applies **regardless of Scout's net-new-only trigger** — a bug fix never fires
Scout, but a bug fix is exactly the shape most likely to be describing stale ground.

### G1b · Accept — after Build, alongside reconcile

| Criterion | Evidence |
|---|---|
| … | test name · screenshot · manual step |

**A criterion without evidence was not built — it was discussed.** This is the cheapest gate
in the pipeline and it catches the most expensive failure.

Criteria that turned out to be wrong get struck through with a reason, not silently deleted.
The record of what you stopped wanting is as useful as the record of what you got.

---

## Run it wrong by

**Writing criteria you already know the code satisfies.** If every criterion passes first try,
they were written backwards from the implementation and the gate verified nothing.

**Accepting your own work.** G1b asks whether the *requester's* conditions were met. When you
are both, read the criteria before you look at the code — the order matters more than it
sounds.

**Scoping straight from the backlog text.** Writing acceptance criteria from the ticket
description alone, without opening the file it names, treats the backlog as ground truth
instead of a claim about the code as of whenever it was filed. Restating an inaccurate request
faithfully still produces an inaccurate requirement.
