# 11 — Evolution: changing how a persona thinks

> Portable. Do not edit. Your persona rules live in `project/personas.md`.

`06-extending.md` covers adding a **gate**. This covers changing an existing one — what a
persona asks, how it judges, what it refuses to pass.

---

## Why this is the dangerous one

Authoring a gate is scrutinised: a five-part test, a schema, a budget, promotion, retirement.
Editing a gate is a one-line change someone makes mid-conversation.

That asymmetry is backwards.

| | New gate | New persona rule |
|---|---|---|
| Visible in the matrix | Yes | **No** |
| Has a budget | Yes | No — it borrows the gate's |
| Can be retired | Yes, by rule | **Never audited again** |
| Scrutiny before adding | Five-part test | Historically: none |

**A new gate announces itself. A checklist line disappears into an existing gate and is
never looked at again.** The system will not fail from too few gates. It will fail from
gates too long to read — skimmed rather than run, at which point every item in them is
worthless, including the good ones.

Persona changes therefore need *more* discipline than gate creation, not less.

---

## Step 1 — Is it even a persona change?

Most directives are not. Route before you edit:

| What was said | Feels like | Actually belongs in |
|---|---|---|
| "Always check that X breaks Y" | persona | **registry** — it is a coupling |
| "Anything touching Z is risky" | persona | **surfaces.conf** — it is a tier rule |
| "I always want to know the cost/impact" | persona | **requirements template** — it is an information need |
| "Compare against what else exists" | persona | **a gate** — it is a new capability with its own trigger |
| "This needs legal/design/native-speaker sign-off" | persona | **gate library** — enable the existing one |
| "Don't build things I didn't ask for" | persona | **probe checkpoint 2** — it is a doubt, not a check |
| "Push back on me more" | persona | **persona** — genuinely |
| "Assume my first framing is wrong" | persona | **persona** — genuinely |

The test:

> **What to check → registry. When to worry → surfaces. What to know → template.
> How to think → persona.**

Only the last one edits a persona. Misfiling the other three is what turns a persona into a
junk drawer, because they *sound* like instructions to a role and they are actually facts
about a codebase.

---

## Step 2 — What evidence do you have?

Not all directives earn the same permanence.

| Evidence | What it is | What it permits |
|---|---|---|
| **Anecdote** | Said once, in one context, no incident behind it | Apply **now**, to this change. Do **not** persist. Note it in the intent log |
| **Pattern** | Said twice, or traceable to a near-miss | Persist as **trial** at the project layer |
| **Incident** | A real escape this would have caught, with a commit or a report | Persist, and it is eligible for promotion |
| **Universal** | Would hold in any project, in any language | Candidate for `core/` — the highest bar, and rarely met |

**The most common error is treating an anecdote as a pattern.** Someone says something once,
in the specific context of one feature, and it becomes a question asked forever. Ask for the
incident. If there isn't one, apply it now and write it down — do not enshrine it.

**A directive is a hypothesis, not a fact.** The person giving it may be generalising from a
single bad experience, or describing something true of one feature and false of the next.
That is not a reason to ignore it; it is a reason to test it.

---

## Step 3 — The five questions

Before any persona edit is persisted, answer these in writing:

1. **Is this always true, or true for this change?** If you cannot state the condition under
   which it does *not* apply, you have not understood it yet.
2. **What would this have changed on the last thing we shipped?** If the honest answer is
   "nothing", that is data.
3. **What does it cost to ask this every single time?** Every question has a false-positive
   rate. A question that fires constantly and changes nothing trains people to skip the whole
   gate.
4. **What does failing this look like?** If you cannot describe a failure, it is not a check.
5. **Does this contradict something the persona already does?** Contradictions do not announce
   themselves — they surface as inconsistent judgments months later.

---

## Step 4 — The backtest

**This is the only real proof available.** Everything else is opinion, including the opinion
of whoever proposed it.

1. Take the **last 5–10 changes** — from the ledger, or just from git history.
2. Apply the proposed question to each. Would it have fired?
3. Where it fired, **would it have changed the outcome** — a decision, a finding, a scope cut?

Read the result honestly:

| Result | Verdict |
|---|---|
| Fires **0 of 10** | Not a rule. It describes a situation that does not arise here |
| Fires **10 of 10**, changes nothing | **Ritual.** The most dangerous outcome, because it looks like diligence. Reject |
| Fires **10 of 10**, changes something each time | Not a persona rule — this is a **default**. Change the code, the template, or the tooling instead |
| Fires **2–5 of 10**, changes at least one outcome | **Keep it.** This is what a useful rule looks like |

A rule that fires selectively and changes something when it fires is the only shape worth
adding. Everything else is either noise or a setting.

---

## Step 5 — Falsifiability

The question must be able to come back **no**.

| Unfalsifiable — reject | Falsifiable — accept |
|---|---|
| "Consider the user experience" | "Name the user segment that is worse off after this ships" |
| "Think about performance" | "State the p95 target and whether this meets it" |
| "Make sure it's secure" | "Name the input that is now trusted and was not before" |
| "Be thorough" | "List what you did not open during this change" |

Left column cannot fail, so it cannot fire, so it is decoration. **If there is no answer that
would stop the change, it is not a check — it is a sentiment.**

---

## Step 6 — The budget

**Seven items per persona.** Beyond that, humans and models both skim, and a skimmed
checklist is worse than a short one because it produces the *feeling* of coverage.

**One in, one out.** At the budget, adding item eight requires naming which existing item
earns its place *more* — and if the honest answer is "they are all important", that is
evidence the gate is doing two jobs and should be split (see `06-extending.md`).

This constraint does more work than any other rule here. It forces the comparison that "is
this a good idea?" never does, because every proposed rule is a good idea in isolation.

---

## Step 7 — Trial, then review

A persisted persona rule enters as **trial**, exactly like a new gate enters as `R`.

- Tag it: `trial`, with the date and the evidence tier
- When it fires, log `persona_rule: <id>` on that ledger line
- **Review after 10 firings**, or 30 days, whichever comes first

At review: **promote** (it changed outcomes), **revise** (right instinct, wrong question), or
**drop** (fired but never mattered). Dropping is the expected outcome for most rules, and
recording the drop is what stops the same idea being re-proposed every quarter.

---

## The record

`project/personas.md`, one block per rule:

```markdown
### PM-03 · Name who is worse off
Gate      : Intent
Added     : 2026-08-09
Evidence  : incident — the sync change broke offline users, nobody asked who lost
Question  : "Which user segment is worse off after this ships?"
Fails when: a segment is named and the trade was never acknowledged
Backtest  : fired 3/10 · changed 1 outcome (the batch-delete scope cut)
Status    : trial (0/10 firings)
Replaced  : —
```

**`Backtest` and `Evidence` are not optional fields.** A rule without them is somebody's
preference wearing the clothes of a process, and preferences do not survive contact with a
tired Friday — they get skipped, and they take the credibility of the surrounding checklist
with them.

---

## When the directive comes mid-session

The common case: you are inside a gate, and the person you are working with says something
that clearly should apply beyond this change.

**Do this, in order:**

1. **Apply it now.** The immediate value is not in dispute.
2. **Say which layer it belongs in** — registry, surfaces, template, gate, or persona. Out
   loud, in one line. This is where misfiling gets caught.
3. **Ask for the incident**, if it is not obvious. "Has this bitten us before, or is this the
   first time?" The answer sets the evidence tier.
4. **Offer the backtest before persisting**, not after: "I can check whether this would have
   fired on our last ten changes — worth two minutes?"
5. **Persist only what survives.** Everything else goes in the intent log, which is where
   ideas wait to become patterns.

**What not to do:** silently add it to a checklist because it sounded right. That is how a
gate grows from seven items to forty without anyone deciding to let it.
