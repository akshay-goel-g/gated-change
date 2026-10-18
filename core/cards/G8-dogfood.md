# G8 · Dogfood

```yaml
id:           G8
name:         Dogfood
persona:      A real user
question:     "Forget the code. Use the thing. Does it work?"

owns:         the lived experience of the change
does_not_own: the code (G6) · the tests (G5) · visual consistency (G3)
responsible:  Change owner            # govern.md

fires:        T2+ mandatory unless the change is invisible to users
trigger:      [user_visible_behaviour_change, new_screen, changed_flow]

input:        the RUNNING product
withhold:     the source code · the diff · the list of what changed
context:      FRESH SESSION REQUIRED

output:       QA report · screenshots for visible changes
passes_when:  nothing surprised you
fails_when:   anything surprised you
must_ask:     what this is supposed to DO, when nothing states it in the requester's
              own words. This gate is handed the running product and withheld the diff
              on purpose; if it also has to infer the intent, "nothing surprised me"
              only means the product matched a story this gate wrote for itself
overfit_when: the acceptance criteria are followed as a script, so only the paths
              someone already thought of are walked · a surprise is discounted because
              the code explains it (the code is withheld here precisely to prevent that)
underfit_when: "works as expected" with no route through the product described · only
              the happy path exercised · a real surprise downgraded to a note because
              the change was otherwise fine — fails_when is deliberately absolute
budget:       15min
model:        whatever drives the interface  # 08-models.md: the bottleneck is interaction, not reasoning
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G8 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--evidence <file:line> | --evidence-cmd EVIDENCE::<name>]   # a fresh T3/T4 pass must cite: an info --finding with a real file:line, or one of these
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  G1, when the surprise is that the feature is not what was wanted
retire_if:    never
```

---

## When the running product isn't reachable

`input: the RUNNING product` assumes the agent's own tools can launch it. They cannot
always: a browser extension needs `chrome://extensions` and a native "load unpacked"
directory picker, a mobile app needs a device, some CLIs need a real interactive terminal —
none of that is guaranteed to exist in an agent's sandbox.

**Do not silently substitute and call it Dogfood.** A same-session logic check is real
verification and belongs at Proof (G5) — for a browser extension specifically, injecting
the actual content-script source into a plain fixture page and calling its functions
directly is a legitimate way to verify detection/extraction logic without the extension
runtime. But it never exercises the parts that make an extension an extension: the
`chrome.*` orchestration (service worker lifecycle, message passing, storage), the popup
UI, a second tab, the tenth use. Declare that gap the same way `09-capabilities.md` requires
for any other unreachable capability — name what was actually verified, name what still
needs a human on the real runtime, and do not let the fixture check quietly stand in for
Dogfood in the record.

---

## Why the withhold list is unusually strict

Every other gate gets the diff. This one must not have it.

**Knowing what changed tells you where to look, and a user does not know where to look.** Given
the diff, you will exercise the new path carefully and the surrounding paths not at all — which
is exactly backwards, because the new path is the one that was just tested by its author.

Use the product the way someone would who never read the changelog.

---

## What this catches that tests do not

Tests verify what you thought to assert. Dogfood catches what you never thought about:

- The tab that was **already open** when the change took effect
- An operation **mid-flight** across the change
- The **second window**, the second device, the second account
- What happens when you do the steps **out of order**
- What it feels like on the **tenth** use, not the first

**The most undervalued gate here**, and the one most likely to find the defect a user would
otherwise have reported.

---

## Run it wrong by

**Demonstrating instead of using.** Walking the happy path to confirm it works is a demo. The
gate asks you to *use* the thing, including the parts that have nothing to do with this change.

**Explaining away a surprise.** "That is expected, because…" is a failing answer. If it
surprised you — someone who built it — it will surprise a user who did not. The explanation is
a finding, not a dismissal.

**Skipping because the change is small.** Small changes are the ones nobody dogfoods, which is
why they are disproportionately represented in defects users report.
