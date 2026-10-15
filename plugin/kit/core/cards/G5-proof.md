# G5 · Proof

```yaml
id:           G5
name:         Proof
persona:      SDET
question:     "Would this bug have been caught, and will the next one be?"

owns:         evidence that behaviour is verified, on every target
does_not_own: whether the behaviour is right (G1) · whether the code is good (G6)
responsible:  Change owner            # govern.md

fires:        T1 for any bug fix · T2+ mandatory
trigger:      [bug_fix, new_behaviour, edge_decision_recorded, new_target]

input:        the diff · the edge decision table from design.md · the target list
withhold:     nothing — Proof is not a review gate
context:      same session is fine

output:       tests, plus a registry entry mapping the bug category to its test
passes_when:  the new test FAILS against the unfixed code, and every target has evidence
fails_when:   the test passes before the fix · any target has no evidence
must_ask:     what the real targets are, when surfaces.conf declares none — and which
              behaviour is the CONTRACT versus incidental current behaviour, when the
              request does not say. A test written against invented intent passes
              forever and pins the wrong thing in place
overfit_when: tests assert the implementation's current output rather than the required
              behaviour, so any refactor fails them · coverage of the diff is complete
              and the edge decisions in design.md have none · the discrimination proof
              (fails before the fix) is skipped because the test "obviously" covers it
underfit_when: one happy-path test per change regardless of what changed · a target
              marked covered by a test that never ran on it · "existing tests pass"
              offered as evidence for new behaviour
budget:       30min
model:        strongest available            # a missing regression test fails silently — 08-models.md's rule
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G5 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  Ripple, if a target cannot be tested at all
retire_if:    never
```

---

## What must exist

**Bug fix** → a regression test that **fails before the fix**. Run it against the unfixed code
and watch it fail. A test written after the fix, never run against the bug, asserts the fix
rather than the requirement — and it will keep passing when the fix is later broken.

**Feature** → unit tests for happy path, edges, and failures, plus an end-to-end test for
anything user-visible.

**One test per row of the edge decision table.** An edge that was decided but not tested is an
edge that will be re-decided by the next person who reads the code.

**Invariant tests** — assertions that the system's *beliefs match reality*, not just that a
function returns the right value. "The rules we think are applied are the rules that are
registered." These are what make silent failure detectable.

---

## Target coverage

Every target in the router's Axis D needs evidence here. **"It should behave the same on the
other platform" is a hypothesis; a test run there is a result.**

This is the classic escape: every gate ran, and none of them ran *there*.

---

## Run it wrong by

**Writing the test after the fix and never running it against the bug.** The most common
failure in this gate, and the one that produces the most confident false safety.

**Testing the implementation instead of the behaviour.** A test that breaks whenever the code
is refactored, without the behaviour changing, is a maintenance cost pretending to be
coverage.

**Counting tests.** Coverage of the edge table matters; the number does not. Ten tests of the
happy path is one test.
