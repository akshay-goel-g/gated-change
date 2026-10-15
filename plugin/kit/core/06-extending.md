# 06 — Extending the pipeline

> Portable. Do not edit.

Eight gates cover any software change. They do **not** cover every *domain* — a project that
provisions infrastructure asks questions a local library never does.

---

## The gate definition schema

Eleven fields. Anything that cannot fill them in is a checklist item, not a gate.

```yaml
id:        G9
name:      Perimeter                # a role or a question. Never a tool name.
persona:   Cloud security engineer  # WHO asks
question:  "Are credentials scoped, stored, and rotated correctly?"
trigger:   [credentials, iam_policy, external_endpoint, network_boundary]
tiers:     { T0: "-", T1: "-", T2: "R", T3: "M", T4: "M" }
budget:    20min
model:     strongest available       # the tier from 08-models.md, ON the card
produces:  ".pipeline/perimeter/<date>.md"
gate:      "Blocks release on any unresolved high finding"
fails_when:"A credential is broader than the operation requires"
retire_if: "Zero findings across 10 consecutive fresh-context runs"
```

**`trigger` is what makes routing automatic.** No trigger means the gate never fires on its
own, which means it will be forgotten. **A gate without a trigger is not finished.**

**The eight built-in gates satisfy this same schema** — see `cards/`. That is deliberate: a
gate you author should be indistinguishable in shape from one that shipped with the kit, and a
schema the core gates did not themselves meet would be a rule for other people.

The cards carry more fields beyond the schema above, all of which an authored gate
must also fill in — `tools/dashboard.sh --check` fails a card missing any of them:

| Field | Why |
|---|---|
| `owns` / `does_not_own` | The boundary against adjacent gates. Two gates claiming the same territory is the merge signal, visible immediately rather than after ten ledger runs |
| `input` / `withhold` | The blind review rule made mechanical. `withhold` is what makes a gate handable to a subagent without re-deciding each time what to hold back |
| `responsible` | A role from `project/govern.md`. "Escalate to whoever asked" is not a name |
| `severities` / `logs_with` | The four legal severities and the exact `ledger.sh` invocation. Step 5 of running a gate is not paperwork, and a subagent handed only its card had no way to know either one |
| `must_ask` | What this gate may **never invent**. An agent handed an underspecified request does not stop — it supplies a plausible value and reviews against it, and every gate below then verifies the same invention. `10-probe.md`'s checkpoint 1 asks the question; this is where each gate's own answer lives, and `ledger.sh assume` is where the answer goes on the record |
| `overfit_when` / `underfit_when` | The two ways a gate stops doing its job **without failing**. `passes_when`/`fails_when` decide one run; these describe the gate drifting — overfit into checking only what is already written down, underfit into ceremony. Required because a card that cannot state its own two failure modes is one whose author has not decided what the gate is for |

**Why calibration is per-card and not a global setting.** A gate's correct tightness is a
property of its *persona and task*, not of the pipeline. `G5 Proof` is maximally strict on
purpose — "the new test FAILS against the unfixed code" is mechanical and admits no judgment —
while `G8 Dogfood` is deliberately loose about method ("use the thing") and absolute about
honesty ("anything surprised you"). Both are right. What was missing was any way to tell an
intended looseness from a gate that has quietly decayed, which is what `underfit_when` names.
The evidence this was a real gap: `G2 Scout`'s `fails_when` already carried an anti-overfit
clause — *"the whole section IS a feature comparison table"* — bolted onto one card after
someone watched a Scout collapse into filling in a template. One card had the lesson; the
other seven had no way to express it.

**Why `model`, `severities` and `logs_with` are on the card and not only in the chapter that
owns them.** `02-gates.md` says a card is *the unit you hand to a subagent*. It was not: the
severity vocabulary lived only in `04-ledger.md`, the model tier only in `08-models.md`, and
**no card mentioned `ledger.sh` at all**. The first real run produced guessed severities,
`model:"unset"` on every line, and findings recorded as bare counts — three defects, one
cause. The test for an authored card is not "is it complete" but **could someone run this
gate correctly having read nothing else?** Anything that fails that test gets supplied from
memory, or not at all.

---

## Extend, or author a new gate?

The default is **extend**. Every new gate is permanent overhead on every future change that
trips its trigger.

Criteria 1–3 are heavily correlated — claim a different persona and you will naturally claim a
different question and artifact too — so they count as **one point between them**:

| Point | Test |
|---|---|
| **1 point total** | A different persona asks it · **and/or** the question is not a sub-case of an existing gate · **and/or** it produces its own artifact |
| **1 point** | It needs authority to block a release on its own |
| **required** | **It fires on a trigger no current gate watches** |

**Author only when the trigger criterion holds AND total points ≥ 2.**

Otherwise: extend the closest gate — but **extending is not free**, and it is not the
casual path it looks like. A checklist line is permanent cost on every future run of that
gate, it never appears in the matrix, and nothing retires it. See `11-evolution.md` for the
required evidence, the backtest, and the seven-item budget before adding one.

**The asymmetry to watch:** authoring a gate is scrutinised and visible; editing one is a
one-line change made mid-conversation. That makes the *cheap* path the *risky* one, and it is
where uncontrolled growth actually happens.

**Worked example — "always compare against the market."** Trigger criterion holds
(`net_new_capability` was unwatched); different persona and own artifact = 1 point; blocking
authority = no. **Total 1 + trigger → author, barely.** That is how the Scout gate exists.

**Counter-example — "check competitor pricing when we change the pricing page."** Same
persona, sub-case of Scout's question, no separate artifact, no new trigger. **0 points, no
trigger → one line added to Scout's checklist.**

---

## Promotion and retirement

Both read from the ledger. Without it, neither is real.

**Promotion.** A new gate enters as `R`. It is promoted to `M` only after a fresh-context run
produces a finding no later gate caught.

**Retirement.** Zero findings across 10 consecutive fresh-context runs → demote one level
(`M` → `R` → removed), with a dated note recording what it protected against and why that
risk is gone.

**Exempt:** hard gates whose failure mode is silent and unbounded (Threat at T3+, Ripple at
T3+). A security gate finding nothing across ten releases is evidence it is working.

---

## The gate library

Pre-authored, disabled by default. Enable one when your project grows the surface.

| Gate | Enable when the project… | Persona | Asks |
|---|---|---|---|
| **Provision** | creates or deploys infrastructure | Platform engineer | Is the target environment correct, reproducible, rollback-able? |
| **Perimeter** | handles credentials, IAM, network boundaries | Cloud security engineer | Are secrets scoped and rotated? Is the **right** resource targeted? Is the network closed by default? |
| **Migrate** | changes a persisted schema | Data engineer | Is it reversible? What happens to in-flight and legacy records? |
| **Load** | has latency-sensitive paths | Performance engineer | p95 under realistic load? Timeout, retry, backpressure? |
| **Spend** | consumes metered resources | FinOps | What does this cost at 1× and 100×? What caps it? |
| **Access** | ships user-facing UI | Accessibility specialist | Keyboard path, contrast, screen reader, focus order |
| **Comply** | handles personal or regulated data | Privacy officer | Collected on what basis, retained how long, deletable how? |
| **Observe** | has failure modes a user will not report | SRE | How would we know this broke? What proves it works right now? |

**Worked example — "connect this to a cloud database."** Triage finds surfaces
`[credentials, external_endpoint, data_schema]` that no gate's trigger watches. Trigger
criterion holds; different persona (cloud security ≠ application security) = 1 point; blocking
authority (wrong resource targeted is stop-ship) = 1 point. **2 + trigger → author** — and
pull **Perimeter**, **Provision**, **Migrate**, **Load** from the library rather than writing
them. Register their triggers, and every future database change routes automatically.

---

## Adapt — the loop that does this

Adapt fires when Triage finds an uncovered surface, or when someone states a standing
requirement nothing enforces. It produces either a checklist extension or a new gate
definition plus its router entry.

**Adapt changes the pipeline's *structure*. Harvest changes its *content*.** They share a
trigger and nothing else: Harvest answers "what do we now know?" and writes a rule; Adapt
answers "what must we now always check?" and writes a routable object. A rule that keeps
recurring across Harvest entries is the signal that a gate is missing.
