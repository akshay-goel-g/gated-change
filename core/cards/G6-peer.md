# G6 · Peer

```yaml
id:           G6
name:         Peer
persona:      Staff engineer
question:     "Is this correct, simple, and consistent with the codebase?"

owns:         line-level correctness · simplicity · cleanup of what this diff orphaned
does_not_own: non-local consequences (G4) · adversarial reachability (G7)
responsible:  Change owner            # govern.md

fires:        T1 recommended · T2+ mandatory
trigger:      [any_code_change]

input:        the diff · the house rules · project/registry.md
withhold:     the author's explanation of what the change does or why it is correct
context:      FRESH SESSION REQUIRED

output:       findings, and fixes for the ones that survive scrutiny
passes_when:  no correctness-affecting finding remains
fails_when:   any finding is correctness-affecting
must_ask:     which of two defensible conventions this codebase actually follows, when
              the diff is consistent with itself and the codebase is inconsistent — and
              whether an apparent bug is a bug or a deliberate, undocumented choice.
              Guessing turns a review into a style argument the author did not consent to
overfit_when: findings are all house-style nits because the rules file is the only fixed
              reference · the review tracks the diff line by line and never asks whether
              the change should exist in this shape · "consistent with the codebase"
              accepted as sufficient when the codebase is the thing that is wrong
underfit_when: approval with no citation (12-grounding.md: "Looks correct" without a
              file:line is indistinguishable from not having checked) · findings only in
              lines the diff touched, never in what it orphaned · zero challenges across
              runs, which 04-ledger.md's challenge rate exists to make visible
budget:       15min
model:        strongest available            # 08-models.md: non-local reasoning, silent failure mode
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G6 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--evidence <file:line> | --evidence-cmd EVIDENCE::<name>]   # a fresh T3/T4 pass must cite: an info --finding with a real file:line, or one of these
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  T4 approver on disagreement about whether a finding is real
retire_if:    zero findings across 10 fresh-context runs
```

---

## Cleanup checklist

Peer is already reading the diff, so it owns this:

- [ ] Dead code, including the branch this replaced
- [ ] Unused exports, imports, helpers
- [ ] Orphaned tests for behaviour that no longer exists
- [ ] Stale feature flags — is a removal date set, and has one passed?
- [ ] Commented-out code (delete it; git remembers)

**Debt beyond this diff is not Peer's job.** General cleanup runs as a periodic sweep — a
cleanup gate on every change causes scope creep, and scope creep turns a one-line fix into a
T3.

---

## Simplicity checks

DRY, KISS and YAGNI are unfailable as slogans. With thresholds they are checkable.

### DRY — rule of three
Extract on the **third** occurrence. Two similar blocks are often two different things that
look alike today, and the wrong abstraction costs every future caller a workaround while
duplication costs one extra edit.

**Premature DRY is a defect this checklist catches, not a virtue it rewards.** An existing
abstraction that needs a flag to serve its second caller was the wrong abstraction — split it
back apart.

### KISS — measurable proxies
- A function needing a comment to explain *what* (not *why*) it does is too long
- More than three levels of nesting → invert a condition or extract
- A boolean parameter that changes what a function *does* → two functions

### YAGNI — and its exception
No speculative config, no "we might swap this later" indirection, no unrequested options.

> **YAGNI applies to features you imagine a user might want. It does not apply to the error
> paths and edge cases of the feature you are actually building.**

Skipping an unrequested export format is YAGNI. Skipping the empty state, the offline case, or
the failure branch is not — it is an unfinished feature with a slogan attached. **This
substitution is the most common misuse of YAGNI in AI-assisted code**, because the happy path
demos well and the error path does not.

---

## Run it wrong by

**Reviewing with the author's narrative in hand.** Told "this fixes the race", you will find
the race, agree it is fixed, and never look at the three other things the diff touches. The
withhold field is not a formality.

**Reporting only what is wrong.** A run with no findings must still say what was *checked* —
"no findings" with no account of coverage is indistinguishable from not having looked, and the
ledger cannot tell them apart either.
