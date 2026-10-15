# 07 — Failure posture, error contract, kill switches

> Portable. Do not edit. Your subsystem rows go in `project/`.

Every subsystem fails eventually. The only question is whether it fails the way you chose or
the way it happened to.

---

## Declare the posture per subsystem

"It crashed" is not a design. Each subsystem states, in advance, what it does when it cannot
do its job. Example shape — fill in your own rows:

| Subsystem | On failure | Why this posture |
|---|---|---|
| Core enforcement / the thing users pay for | **Never fail silently open** — if it cannot work, say so | Silent non-function breaks the only promise you made |
| A batch of rules or records | **Fail partial** — keep the good, isolate the bad, notify | One bad entry must never cost the whole set |
| Startup / init | **Safe mode** — boot a minimal known-good config | A degraded system beats a dead one |
| A new non-critical feature | **Fail off** behind its flag | A cosmetic bug must not take down the core |
| Sync / replication | **Fail local** — keep working here, retry later | Local correctness outranks distributed consistency |

**The rule underneath: fail loud where the user's trust depends on it, fail quiet where it
does not.** A tool that stops doing its one job without telling anyone has already broken.

---

## The silent-failure detector

The worst bug class is invisible: the thing stops working, and no one reports it because
nothing *looks* wrong. Users assume it works, then quietly leave.

**A self-check answers "is it still working right now?"** At startup and at key transitions,
compare intended state against actual state:

- What we believe is configured vs. what the platform reports is configured
- What we believe is scheduled vs. what exists
- What we believe is persisted vs. what reads back

A mismatch surfaces **to the user**, in-product. Prefer local self-checks over telemetry: for
privacy-sensitive products, shipping usage data to detect your own bugs is a worse violation
than the bug.

**Invariant tests are their own category in Proof.** They assert not "this function returns
the right value" but "the system's beliefs match reality."

---

## The error contract

The posture table covers *subsystems*. This covers each *change*. Every new failure mode
answers three questions, and "nothing" is valid only when it is chosen:

| Audience | Question | Failure if skipped |
|---|---|---|
| **The user** | Do they need to know, and what can they do? | A silent failure they never report, or a dialog they cannot act on |
| **The developer** | Is it recorded somewhere we will actually look? | A log line in a process nobody has open is not recording |
| **The system** | Does it recover, retry, degrade, or stop? | An unhandled path that leaves state half-written |

**Rules:**

- [ ] **No empty catch blocks.** A caught-and-ignored exception is a decision to discard
      information; write it as one — catch, comment why ignoring is safe, move on. Mechanical
      grep; belongs in continuous checks
- [ ] **No swallowed rejections.** A bare catch around a batch operation is how one bad input
      becomes permanent, invisible, total failure
- [ ] **User-facing messages say what to do**, not what went wrong internally
- [ ] **Errors during initialization get special scrutiny** — a throw there can take down
      everything scheduled after it
- [ ] **Retry has a ceiling and a backoff.** Infinite retry against a permanent failure is a
      battery drain, not resilience

**The notification question is a product decision, not a technical one.** Whether a failure
interrupts, badges, waits in a log, or retries silently changes what the product feels like.
Route it through the escalation rule: product decisions go to the person who asked.

---

## Kill switches

**Kill switches for features, never for the core guarantee.** If your product's value depends
on something being hard to turn off, a switch that turns it off is a hole, and a determined
user will find it at 2am.

| Switch | Scope | Rule |
|---|---|---|
| **Feature flag** | One new feature | Every T2+ feature ships behind one, with a removal date. A flag with no removal date becomes a permanent fork |
| **Safe mode** | Whole system | Repeated init failures → boot minimal known-good config rather than dying |
| **Hotfix lane** | The pipeline itself | Below |

---

## The hotfix lane

When production is broken you cannot run eight gates, and pretending otherwise is how a
pipeline gets abandoned in its first fire. **An escape hatch that is designed gets used
correctly; one that is improvised becomes the new normal.**

1. **Minimum gates: Proof, plus Threat if any trust-boundary surface is touched.** Nothing
   else. A regression test is not optional even in a fire — an untested hotfix is how one
   outage becomes two.
2. **Reconcile still runs.** It is mechanical and takes seconds.
3. **Log the lane** (`lane: "hotfix"`) so these runs never pollute gate-yield statistics.
4. **The deferred gates run within 24 hours**, as a follow-up against the same code. Not
   "when we get to it."
5. **Two hotfixes for the same subsystem in a month escalates that subsystem's baseline tier
   by one.** Repeated emergencies are evidence of misclassification, not bad luck.

The hotfix lane is the pipeline's own kill switch: a documented way to turn it *down* that
leaves a record, rather than an undocumented way to turn it *off* that leaves nothing.

---

## Harvest — the loop that learns

Fires after any escaped defect and after any T3/T4 change. Produces a learnings entry, and —
when the lesson generalises — a new registry entry.

This is what makes the pipeline compound. Every defect that escapes should end here as a rule
that routes future changes more accurately.
