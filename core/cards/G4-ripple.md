# G4 · Ripple ★

```yaml
id:           G4
name:         Ripple
persona:      Release engineer
question:     "What breaks if this is wrong, and can it ship alone?"

owns:         non-local consequences · structure · what exists · standing risk
does_not_own: line-level correctness (G6) · adversarial reachability (G7)
responsible:  Change owner            # govern.md

fires:        T1 recommended · T2+ mandatory
trigger:      [shared_module, persisted_state, id_or_priority_space, load_order,
               new_component, new_external_dependency, config_key]

input:        the diff · registry entries whose triggers matched · project/map.md
withhold:     the author's account of what the change does — derive it from the diff
context:      FRESH SESSION REQUIRED

output:       coupling report · updates to project/map.md and project/risks.md in this diff
passes_when:  every triggered registry entry has its check performed, not merely noted
fails_when:   a trigger is hit and unchecked · a new component is absent from the map
must_ask:     who owns a component this change couples to, when map.md names no owner —
              and whether an undocumented coupling found here is real or incidental.
              An empty registry.md does not mean nothing is coupled; it means nothing
              has been written down, and those two are indistinguishable from here
overfit_when: only registry entries whose triggers matched are considered, so a coupling
              nobody has written down yet cannot be found by construction · the report is
              a checklist of matched rules with no consequence traced past the first hop
underfit_when: triggers noted rather than checked (the exact wording of fails_when) ·
              "no impact expected" without naming what was examined to conclude it ·
              map.md left untouched by a change that added a component
budget:       10min
model:        strongest available            # 08-models.md: non-local reasoning, silent failure mode
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G4 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  T4 approver when the change cannot ship independently
retire_if:    never (silent, unbounded failure mode)
```

---

## Five parts

### 1. Structure
Is this the right shape? Where is the state machine? What are the edges?

### 2. Coupling
Which registry entries does this trigger? Each hit needs the check **performed**. A noted
trigger with no check is a failed gate, not a documented one.

### 3. Map accuracy
Did this add a component, an external dependency, or newly persisted data? Then
`project/map.md` is updated **in this diff**.

Documentation kept on a schedule drifts between schedules; documentation kept by a gate drifts
only when the gate is skipped, and the ledger records that. **This coupling is the only reason
the map is worth trusting.**

### 4. Standing risk
If this change *creates* a risk you are choosing to live with rather than fix, it goes in
`project/risks.md` with an owner and a review date. **A risk accepted in a commit message is
not accepted; it is forgotten.**

### 5. Silent failure
*How would we know if this broke in production and nobody reported it?* Mandatory at T3+.

For anything whose failure is invisible — enforcement, sync, scheduled work — **"the user will
tell us" is a failing answer.** They will not. They will assume it works and leave.

---

## The edge decision table

**AI-written code does not skip edge cases — it silently decides them.** Asked to handle a
list, it picks a behavior for the empty list, commits to it, and never mentions a choice was
made. The result looks complete and passes review because the decision is invisible: no TODO,
no question, just an answer nobody chose.

| Edge class | Ask |
|---|---|
| **Cardinality** | Zero, one, many, and the maximum |
| **Absence** | Null vs undefined vs missing vs present-but-empty — four states, not one |
| **Numbers** | Zero, negative, overflow, non-integer, and the valid `0` that `\|\|` discards |
| **Duplicates** | Two identical entries — merge, reject, allow? |
| **Concurrency** | Two tabs, two processes, two devices at once |
| **Time** | Slow, timeout, offline, retried, out of order |
| **Interruption** | Killed halfway. What is left behind, and does it recover? |
| **Lifecycle** | First run vs upgrade vs reinstall vs downgrade |
| **Permission** | The user said no, or revoked it later |
| **Clock** | Timezone boundaries, DST, a clock that moved backwards |

**The escalation rule:** if the correct behavior is a **product decision** rather than a
technical one, it goes to the person who asked — it is not guessed. Guessing produces code that
is confidently wrong in a way no test catches, *because the test asserts the guess*.

Record every answer in `design.md`. An edge decided once and written down is not re-decided
differently six weeks later by someone reading the same ambiguous code.

**A fix disproportionately reproduces the same class of gap as the bug it fixes.** Observed
twice, independently, in one round of re-review on the same change (SampleApp, 2026-08-12):
one fix replaced a broken condition with `schedule.schedules.length > 0` — an enumerated case
("does at least one schedule exist") standing in for the real invariant ("is there more than
one thing to distinguish") — and a second, unrelated fix listed three specific DOM regions a
re-render needed to protect focus in, missing a fourth. Both are the *same shape*: a
hand-enumerated list or heuristic condition, written under the same blind spot that produced
the original bug, checked in by the same author who just finished convincing themselves the
class of defect was closed. **When a fix's condition is a list of cases rather than a computed
property of the data, ask what a NEW case sails through unnoticed — that is where the next bug
in this exact family already is.** Prefer "compute the set and check its size/shape" over
"enumerate every case I can currently think of."

---

## Independence test

Ships alone only if **all** hold:

- [ ] No new shared symbol in a shared scope
- [ ] No storage key added or renamed that another module reads
- [ ] No id or priority consumed from a shared space
- [ ] No dependence on load order
- [ ] Tests pass with no other pending change applied

Any unchecked box makes it **dependent**: it ships with its counterpart or behind a flag, and
Ripple names the counterpart explicitly.

---

## Run it wrong by

**Reading the registry as a checklist.** The entries are triggers, not tasks. Hitting one means
doing the *check* it describes — "noted, this touches the rule builder" is not the check.

**Answering the silent-failure question with a plan.** "We should add monitoring" is not an
answer. Either the detection exists in this diff, or the risk is recorded in `risks.md` with a
review date. A third option does not exist.
