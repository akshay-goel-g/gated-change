# G2 · Scout

```yaml
id:           G2
name:         Scout
persona:      Analyst
question:     "How does the world already solve this, and what does everyone get wrong?"

owns:         prior art, and where the opening is
does_not_own: whether we should build it (G1) · how it looks (G3)
responsible:  Change owner            # govern.md

fires:        recommended for net-new user-facing capability. Never blocks a release
trigger:      [net_new_capability]

input:        the problem statement · public information about existing solutions
withhold:     your intended design — knowing it turns research into confirmation
context:      fresh session preferred

output:       "Prior art" section in specs/<feature>/requirements.md — gap note + comparison table
passes_when:  the gap is named, not just the alternatives
fails_when:   the gap note is missing, or the whole section IS a feature comparison table
              (the table is a required supplement below the gap note, never a replacement)
must_ask:     who the competitor set actually is, when the request names no market and
              none is inferable from the code — researching the wrong five products
              produces a confident gap note about a market nobody is in
overfit_when: the output is the comparison table with a sentence on top · every product
              is scored on the same axes the request happened to mention · the "gap" is
              a feature absent from a table rather than something users work around
underfit_when: prior art is listed without a position · "everyone does X, we could do X
              better" · no product examined closely enough to say what it gets WRONG
budget:       20min
model:        mid                            # 08-models.md: judgment, but recoverable if imperfect
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G2 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  G1, if prior art reveals the problem is already solved well
retire_if:    zero influence on scope across 10 net-new features
```

---

## The note has three parts

- **What existing solutions get right** — match it, do not re-litigate it
- **What they get wrong** — this is the entire point of the gate
- **What we do differently, and why**

**Then the comparison table.** Name real, specific competing products — not "generic
scraper extensions." For each: strength, weakness, and an explicit **include / exclude /
improve** call against our scope. The table is required, but it is downstream of the gap
note, not a substitute for it — see `fails_when` above.

| Product | Strength | Weakness | Include / Exclude / Improve |
|---|---|---|---|
| … | … | … | … |

## Confirm before continuing

Scout has no authority to block a *release* (see `fires` above) — but its output lives
inside `requirements.md`, and that file is not confirmed until Scout's part of it is too.
When Scout fires, stop and get the user to explicitly check the gap note and the comparison
table — same approval boundary as the rest of Intent's output, before `design.md` gets
written. "I did the research" is not the same event as "the user looked at it."

---

## Run it wrong by

**Comparing features as the whole note.** The failure mode of market research is feature
parity. A note that is *only* "what does the competitor have" produces a checklist that
erases whatever made the idea worth building — every gap becomes a to-do, and the result is
a worse copy of something that already exists.

Scout asks first: **where are the incumbents weak?** The comparison table exists to make
inclusion/exclusion decisions concrete once that gap is already named — never as a
replacement for naming it. A table with no gap note above it was run wrong; delete it and
start from the weakness.

**Skipping the confirm step because Scout "never blocks."** Non-blocking means the *release*
doesn't wait on Scout's verdict about the market. It does not mean the *user* can skip
reading what Scout found — that's still a stop-and-confirm point, same as requirements,
design, and tasks.

**Researching from memory instead of actually looking.** Naming plausible-sounding
competitors without checking they're real, current, and actually do what's claimed produces
a note that reads like research and isn't. If real search isn't available, say so in the
note rather than presenting assumptions as findings.
