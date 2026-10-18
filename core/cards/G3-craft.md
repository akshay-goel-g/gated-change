# G3 · Craft

```yaml
id:           G3
name:         Craft
persona:      Designer
question:     "Does this look and behave like the rest of the product?"

owns:         consistency of surface and behaviour with what already exists
does_not_own: whether it works (G8) · keyboard/contrast/screen-reader (Access, library)
responsible:  Change owner            # govern.md

fires:        recommended at T2+ whenever a UI surface changes. Skip for backend-only
trigger:      [ui_surface, user_facing_copy, new_screen, new_state]

input:        the running change · the existing screens it sits beside
withhold:     the rationale for design choices — judge what a user meets, not what you meant
context:      fresh session preferred

output:       design notes · before/after screenshots for changes to existing surfaces
passes_when:  it is indistinguishable in kind from the screens around it
fails_when:   it works but feels foreign · any unreplaced placeholder asset
must_ask:     which surface this is meant to sit beside, when the project has no design
              system and none can be read off existing screens. With nothing to be
              consistent WITH, this gate invents a house style and then certifies the
              change matches it — a verdict about its own invention
overfit_when: consistency is checked against a token list rather than the running screens ·
              a change is passed because it reuses approved components, while the flow it
              creates exists nowhere else in the product
underfit_when: "looks fine" with no named comparison screen · placeholder assets waved
              through as "obviously temporary" · no before/after for a changed surface
budget:       15min
model:        mid                            # 08-models.md: judgment, but recoverable if imperfect
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G3 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--evidence <file:line> | --evidence-cmd EVIDENCE::<name>]   # a fresh T3/T4 pass must cite: an info --finding with a real file:line, or one of these
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  the requester, when consistency and the request genuinely conflict
retire_if:    zero findings across 10 UI changes
```

---

## What "feels foreign" means concretely

Not taste. Four checkable things:

- **Spacing and rhythm** that no other screen uses
- **States** the rest of the product has and this does not — loading, empty, error, partial
- **Vocabulary** that renames an existing concept ("folder" here, "group" everywhere else)
- **Interaction** that breaks an established pattern for no stated reason

---

## Placeholders are findings

An asset the agent could not produce — icon, illustration, sound — is allowed to ship as a
declared placeholder *during* development and is **never allowed to reach a release
candidate**. See `../09-capabilities.md`.

A placeholder that survived to here is not a design problem, it is a **tracking** problem: it
means the capability gap was noticed once and then forgotten, which is exactly what the
declaration rule exists to prevent.

---

## Run it wrong by

**Reviewing the mockup instead of the build.** Craft judges what a user actually meets. A
design that was approved and then implemented approximately is still a Craft failure.

**Confusing consistency with sameness.** The gate asks whether this belongs, not whether it is
identical. A deliberate departure with a stated reason passes; an accidental one does not.
