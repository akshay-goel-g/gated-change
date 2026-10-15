# 10 — Probe: the self-doubt protocol

> Portable. Do not edit.

Every other gate assumes the agent running it is trying to find problems. **This one assumes
it is not.**

---

## Why this exists

An agent finishing a task is in the worst possible position to evaluate it. It has just spent
its effort constructing a solution, and the same reasoning that produced the solution is what
would have to find the flaw. Add that the author is also the reviewer, the requester is also
the audience, and agreement is the path of least resistance — and "looks good to me" becomes
the default output regardless of what was built.

Probe is a **stress test aimed at the agent, not the code.** It runs at three checkpoints and
its output is deliberately uncomfortable.

**It is a protocol, not a gate.** It has no persona, blocks nothing on its own, and produces
no artifact of its own. What it produces is *escalations* — doubts routed to whoever can
resolve them.

---

## The rule that stops it becoming theater

A checklist an agent answers about itself will come back all-green, every time, in about four
seconds. Three constraints prevent that:

**1. The forced finding.** Every probe run must name **at least one thing that could be
wrong**. "Nothing" is not an available answer. If you cannot find a candidate, you did not
look — the correct response is to look harder, not to record a clean pass.

**2. Confidence with a falsifier.** Every answer states a confidence and *what would prove it
wrong*: "80% sure the migration is reversible — what would prove me wrong is a row written
between the read and the write." A confidence with no falsifier is a feeling.

**3. Rank by consequence, not likelihood.** An unlikely catastrophe outranks a probable
annoyance. Agents reliably invert this, because likelihood is easier to estimate than damage.

---

## Checkpoint 1 — after understanding, before design

### Did I understand what was asked?
- Restate the request in one sentence. Does it match what was said, or what I **expected** to
  be said?
- **What did they not say that I assumed?** List the assumptions explicitly. This is where
  most divergence enters, and it enters silently. **Listing is no longer where this ends:**
  `bash tools/ledger.sh assume --change <name> --assumed '<what>' --resolution
  asked|verified|defaulted` puts each one on the record, because for a long time this was
  the least enforced sentence in the kit — only checkpoint 3 appeared in the PR checklist,
  no gate card mentioned asking anything, and no record type could hold the answer. An
  assumption nobody can count is one nobody can challenge. `defaulted` is legal and
  logged; `compliance` refuses it at T3/T4, where a gate verifying an invented premise
  is exactly what the tier exists to catch. Each gate card's `must_ask:` names what that
  gate in particular may never invent.
- Which words in the request are ambiguous? Did I resolve them, or pick one and move on?
- Am I solving the problem they described, or the problem I find interesting?

### Is it worth it?
- What does this cost, and what does it return?
- **What is the smaller version that gets most of the value?** Why am I not doing that?
- What happens if we do nothing at all?
- Is there an existing thing that already does this?

### Do I need to confirm before proceeding?

Stop and ask when **any** of these hold:

| Stop and ask | Decide yourself |
|---|---|
| It is a product decision, not a technical one | A conventional default exists |
| Irreversible, or expensive to reverse | Cheap to reverse |
| Two reasonable approaches differ **materially in outcome** | They differ only in style |
| I am about to assume something they never said | I can verify it from the code |
| The answer changes **what** gets built, not just how | It changes only the implementation |

When you do ask, give **both sides honestly** — a recommendation, the case against it, and
what would change your mind. A list of options with one obviously dressed to win is not a
question; it is a request for permission.

---

## Checkpoint 2 — after design, before build

### Did I over-engineer?
- What did I add that nobody asked for?
- **Which abstraction has exactly one caller?** Why does it exist?
- If forced to cut 30% right now, what goes? Why is it still in?
- Am I building for a future requirement I invented?
- Is there indirection here whose only justification is "we might need to swap it"?

### Did I under-engineer?
The opposite failure, and the less examined one:
- Which error path did I skip and label YAGNI? (That is not what YAGNI means — see
  `02-gates.md`.)
- Which edge did I decide silently rather than surface?
- What did I mark "good enough for now" without recording where it must be revisited?

### Did I miss something?
- What does this design *not* handle, and is that deliberate or unnoticed?
- What would a hostile reviewer attack first?
- What am I least confident about? **Say the actual thing, not a hedge.**

---

## Checkpoint 3 — after build, before release

### Did I do everything, in order?
- Go criterion by criterion. **Which have evidence, and which have only my assurance?**
- Did I verify each item independently, or check the first two and assume the pattern held?
- Did I check features in the order specified, or in the order that was convenient?
- **What did I silently drop?** Scope quietly shrinks under effort; name what fell out.
- Did I do the boring parts as carefully as the interesting parts?

### Did I cover the edges?
- Every row of the edge decision table: decided, or defaulted?
- Which decisions were **mine to make**, and which should have gone to the user?
- Are the decided edges tested, or only decided?

### Did I check security and permissions?
- What new input do I accept that I did not before?
- **Did any permission, scope, or capability grow?** Even by one.
- What trust boundary does this change cross?
- If this code ran with hostile input, what is the worst reachable outcome?
- Did I add a dependency? Who wrote it, and what does it have access to?

### What am I not seeing?
- What did I never look at during this change? Not "what did I check" — **what did I not
  open?**
- Where did I trust a previous answer instead of re-verifying?
- What would make me wrong about all of this at once?

---

## Output

Probe produces a short block, not a document. Long self-audits are how the practice dies.

```
PROBE — checkpoint 3
  Doubt      : the upgrade path is untested; only fresh install was verified
  Consequence: existing users lose saved state on update — silent, unrecoverable
  Confidence : 60% it is fine. What would prove me wrong: running the migration
               against a pre-change profile
  Action     : escalate — testing this needs a real upgrade, not a unit test

  Also: I did not open the sync path at all. It reads the key I renamed.
```

**The "also" line is the important one.** The first doubt is the one you already knew about.
The second is the one the protocol exists to surface.

---

## When probe finds something

| Kind of doubt | Route |
|---|---|
| Technical, and I can resolve it | Resolve it, then note it in the ledger |
| Product decision | **Escalate.** Pros, cons, recommendation, what would change your mind |
| A gate I skipped that now looks load-bearing | Run the gate |
| Something I never examined | Examine it before claiming completion |
| Uncertainty I cannot close | **Say so in the handoff.** An unresolved doubt that is named costs a follow-up; one that is buried costs an incident |

---

## Honesty clause

The purpose of this protocol is to make it **cheaper to admit a problem than to hide one**.
That only holds if surfacing a doubt is treated as the protocol working rather than as the
work being deficient.

An agent that reports "I am not confident this is correct, here is why" has done its job. An
agent that reports "all checks passed" on every change has not been checking — and the ledger
will eventually show it, because a reviewer that never disagrees is measurably broken.
