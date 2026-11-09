# <feature> — Requirements

> Written at the Intent gate, **before** any design or code.
> Stop here and confirm before writing `design.md`. A misunderstanding corrected at this
> file costs a sentence; the same one corrected after Build costs the whole change.
>
> **Pipeline status:** `bash .pipeline/tools/dashboard.sh` renders every gate run so far as
> `.pipeline/dashboard.html`. Regenerate it from here on — the first artifact, not the last
> thing someone has to ask about.

## User

Who this is for, in one sentence. A role and a situation, not "users".

## Problem

What they cannot do today, and what they currently do instead. If the answer to "what do
they do instead" is "nothing", check that the problem is real before continuing.

## Acceptance criteria

Each one a **demonstrable behavior**. Not an adjective — you cannot demonstrate "intuitive".

- [ ] …
- [ ] …
- [ ] …

## Out of scope

What this deliberately does not do. This section prevents more rework than any other, because
it is where scope creep gets refused in advance.

- …

## Assets required

Non-code deliverables: icons, screenshots, sounds, copy, translations. Any item the agent
cannot produce must be flagged here with its route (see `core/09-capabilities.md`), not
discovered at release.

| Asset | Who/what makes it | Blocking release? |
|---|---|---|
| | | |

## Prior art

From the Scout gate (`core/cards/G2-scout.md`) — net-new user-facing capability only.
**Stop and get this section specifically confirmed before writing `design.md`.** Real
research, not assumptions — if search isn't available, say so instead of guessing.

Organised around the **gap** first. The table below is required too, but it comes after
the gap is named, never instead of it (a section that is only a table failed the gate).

- **What exists:**
- **What they get wrong:**
- **What we do differently, and why:**

Name real, specific products — not a category description.

| Product | Strength | Weakness | Include / Exclude / Improve |
|---|---|---|---|
| | | | |

## Restatement

Write the request back in your own words. If this and the original ask differ, the ask was
ambiguous — fix the requirement, not the wording.

> …
