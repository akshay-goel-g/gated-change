# G7 · Threat

```yaml
id:           G7
name:         Threat
persona:      Security engineer
question:     "What can a hostile input, a hostile caller, or a confused user do with this?"

owns:         adversarial reachability — what an attacker gets to
does_not_own: correctness and simplicity (G6) · coupling (G4)
responsible:  T4 approver             # govern.md

fires:        T2 when input/persistence/network is touched · T3+ HARD GATE
trigger:      [auth, credential, permission, external_endpoint, user_input,
               persisted_state, manifest, quota, migration]

input:        the diff · trust-boundary surfaces from surfaces.conf · prior findings
withhold:     the author's threat assessment · the change's stated purpose
context:      FRESH SESSION REQUIRED

output:       .pipeline/security-reports/<date>.md — NAMES THE COMMIT SHA IT REVIEWED
passes_when:  no unresolved finding above low
fails_when:   a trust boundary is crossed without a check · privilege grew unremarked
must_ask:     where the trust boundary actually is, when surfaces.conf is still the
              shipped example — those are somebody else's boundaries, and a clean report
              against them is worse than no report. Also: who the untrusted party is
              meant to be, when the request implies a threat model it never states
overfit_when: only paths matching a T4 regex are examined, so a boundary nobody has
              written down cannot be found · the walk follows the diff and never asks
              what the diff makes REACHABLE · a checklist of known categories (injection,
              authz, secrets) completed while the change's own novel surface goes unnamed
underfit_when: "no security impact" without naming the boundaries examined to conclude it ·
              a finding rated low because fixing it is inconvenient · the report names
              the change but not the commit sha it reviewed (the hook exists for this)
budget:       20min (7c only — 7a costs nothing, 7b is 5min)
model:        strongest available            # 08-models.md: non-local reasoning, silent failure mode
severities:   blocking | minor | info | out-of-scope   # 04-ledger.md
logs_with:    ledger.sh add --change <name> --gate G7 --tier <T> --round <n> --outcome pass|fail
              --confidence fresh|low --challenged true|false --model <name> --tokens <n>
              --finding "<severity>::<file:line>::<claim>"      # 02-gates.md "Running a gate"
              [--withhold-breached true|false]      # optional, trial — core/11-evolution.md Step 7
              [--tokens-in <n> --tokens-out <n>]    # optional, paired — 04-ledger.md; computes --tokens
escalate_to:  T4 approver. NEVER the author alone
retire_if:    never — silent, unbounded failure mode
```

---

## Three depths

Security is not one gate at the end. A single late checkpoint finds implementation flaws and
misses design flaws, because by then the design is built.

### 7a · Continuous — every commit, automated, zero human minutes

| Check | Catches |
|---|---|
| Secret scan on the diff | A key or token committed to history |
| Dependency audit | A compromised or vulnerable package |
| **Permission/capability diff vs last release** | Privilege growing silently — usually the highest-signal security event available |
| Dangerous-sink grep (`innerHTML`, dynamic code evaluation, shell interpolation) | Injection surfaces added without escaping |
| Empty-catch grep | Swallowed errors |

Run these in CI or a pre-commit hook. They have no budget because they cost no attention —
and that is precisely why they cannot be skipped by a tired person on a Friday.

### 7b · Design-time — inside Intent/Ripple at T3+, 5 minutes

One question, asked before the code exists, while the answer is still cheap:

> **If an attacker controlled this input, what would they reach?**

A design flaw found here costs a conversation. The same flaw found in 7c costs a rewrite.

### 7c · Deep review — 20 minutes

The full adversarial pass. The report **names the commit sha it reviewed** — a report that does
not name its sha proves nothing about this change, which is why the pre-push hook greps for it.

---

## On the overlap with Peer

These two are the most likely pair to collapse into one pass, and `does_not_own` states the
boundary: Peer asks whether the code is *right*, Threat asks what an attacker *reaches*.

The ledger settles whether the split earns its cost. If Threat's findings are consistently a
subset of Peer's across ten fresh-context runs, merge them. Until measured, keep them
separate — **the failure mode of a missed security finding is silent and unbounded**, and that
asymmetry justifies the duplication.

---

## Run it wrong by

**Accepting "no new attack surface" without tracing an input.** The gate is a walk from an
untrusted value to what it reaches, not an opinion about the change.

**Skipping 7a because 7c is scheduled.** The continuous checks catch a different class
entirely — a committed secret is not something a human review reliably notices, and it is
already public by the time anyone reads the diff.

**Letting the author clear their own T4.** The escalate field is a hard rule. Someone who has
been reasoning about a design for two hours is the worst available judge of what it exposes.
