# 02 — The Gates

> Portable. Do not edit.
>
> **Each gate lives on its own card in `cards/`.** This file holds what is common to all of
> them: the protocols, the failure rule, and the index. There is exactly one description of
> each gate, and it is the card — if this file and a card ever disagree, the card is right.

---

## The index

| Gate | Persona | Asks | Budget | Card |
|---|---|---|:---:|---|
| **G1 · Intent** | Product manager | Who is this for, what does done mean — and did we build that? | 15m | [G1](cards/G1-intent.md) |
| **G2 · Scout** | Analyst | How does the world solve this, and what does everyone get wrong? | 20m | [G2](cards/G2-scout.md) |
| **G3 · Craft** | Designer | Does this look and behave like the rest of the product? | 15m | [G3](cards/G3-craft.md) |
| **G4 · Ripple ★** | Release engineer | What breaks if this is wrong, and can it ship alone? | 10m | [G4](cards/G4-ripple.md) |
| **G5 · Proof** | SDET | Would this bug have been caught, and will the next one be? | 30m | [G5](cards/G5-proof.md) |
| **G6 · Peer** | Staff engineer | Is this correct, simple, and consistent? | 15m | [G6](cards/G6-peer.md) |
| **G7 · Threat** | Security engineer | What can a hostile input or confused user do with this? | 20m | [G7](cards/G7-threat.md) |
| **G8 · Dogfood** | A real user | Forget the code. Use the thing. Does it work? | 15m | [G8](cards/G8-dogfood.md) |

Which of these fire is decided by the router (`01-router.md`), not by preference.

## Why cards

**A card is the unit you hand to a subagent.** The blind review rule below requires running a
gate in a session that did not write the code — which needs an artifact to hand over. Prose
scattered through a chapter is not that artifact; excerpting it by hand every time produces a
different brief on every run, which quietly defeats having a defined protocol at all.

Every card carries the same fields, including two that matter more than they look:

- **`does_not_own`** — the boundary against adjacent gates. If two cards claim the same
  territory, that is the merge signal, visible immediately rather than after ten ledger runs.
- **`withhold`** — what the gate must *not* receive. This is the blind review rule made
  mechanical instead of remembered.

Authored gates use the same schema (`06-extending.md`), so a gate you write is
indistinguishable in shape from one that shipped with the kit.

---

## The protocols

Five here. Two more have their own files: **Probe** (`10-probe.md`), the self-doubt protocol,
and **Grounding** (`12-grounding.md`), the checklist against confident unchecked claims.

**Gates catch problems in the code. Protocols catch problems in the reviewing** — which is why
skipping them quietly voids the gates too.

### The context rule
**Ripple, Peer, Threat, and Dogfood must run in a session that did not produce the code.** A
model reviewing its own work is anchored on its own choices and will defend them wearing any
hat you give it. Fresh context is what makes persona separation real rather than decorative. A
subagent is the mechanism.

If you cannot start a fresh session, the result is marked `low-confidence` in the ledger and
does not count toward promotion or retirement statistics.

### The blind review rule
**A verify gate receives the diff and the registry. It does not receive the author's
explanation of what the change does.**

Telling a reviewer "this fixes the quota race" anchors them on confirming that story; they
will find the race, agree it is fixed, and never notice what you did not mention. If the
reviewer derives a different purpose than you intended, that is itself the most valuable
finding available.

Each card's `withhold` field states exactly what to hold back for that gate.

### The evidence rule
Every claim about behavior — **including agreement** — cites `file:line` or command output. A
finding without a citation is deleted, not softened. "Confirmed, this is correct" needs the
same citation as "this is broken": unsupported agreement is indistinguishable from
verification. Unverifiable claims are labeled `unverified`, not upgraded to conclusions.

### The disagreement quota
**If a gate never contradicts the author across ten runs, the gate is broken.** An AI reviewer
is structurally biased toward agreement — the author supplies the framing, and concurrence is
the path of least resistance. That bias survives any persona label, which is why it needs a
number, not an intention. Each run records `challenged_premise: true|false`.

### The failure rule
When a gate fails:

1. **Record the finding in the ledger** — always, even if fixed in 30 seconds
2. **Return to the phase that produced the defect**, not to the start
3. **Re-run the failed gate, plus any gate whose inputs the fix changed.** A fix touching new
   files re-triggers reconciliation
4. **Two consecutive failures of the same gate on one change → escalate the tier by one.**
   Repeated failure is evidence the change is bigger than you classified it

**A finding can be real and still not be about this change.** G8 Dogfood especially — using
the product surfaces whatever is broken, not only what the diff touched. When a failure is
confirmed via `git diff` to be outside the change under review: log it as a `fail` regardless
(the gate's own binary criterion — something surprised it — is not softened to make the number
look better), but route it to a separate follow-up item instead of back through Build for this
change. Do not fold an unrelated fix into an already-scoped change just because a gate happened
to find it.

---

## Running a gate

```
1. Start a fresh session                    (context rule)
2. Hand it: the card + everything in `input`
3. Hand it nothing in `withhold`
4. It reports against `passes_when` / `fails_when` — with citations
5. Log it:  ledger.sh add --change <name> --gate G_ --outcome pass|fail \
              --confidence fresh --challenged true|false --model <name> --tokens <n> \
              --finding "severity::location::claim"        # once per finding
   A fresh pass at T3/T4 (or with no tier) is refused unless it cites something real: an `info` finding whose
   location is an existing `file:line`, `--evidence file:line`, or `--evidence-cmd EVIDENCE::<name>` (a line of
   `project/commands.conf` that `ledger.sh` runs itself; it records the exit code and sha256 hashes).
```

**Every card carries that invocation on its `logs_with:` line, its expected model tier on
`model:`, and the severity vocabulary on `severities:`.** A card is the unit you hand a
subagent; a subagent handed only its card previously had no way to learn any of the three,
so it guessed — which is how one real run produced invented severities, `model:"unset"` on
every line, and findings recorded as bare counts.

`severity` is one of `blocking | minor | info | out-of-scope` (full definitions in
`04-ledger.md`). Anything else is **refused, and nothing is written** — as is a `blocking` or
`minor` finding with no location, and an `out-of-scope` finding whose claim does not say
where it was filed. There is no bare `--findings N`: the number of `--finding` rows *is* the
count, and `04-ledger.md` explains at length why a count on its own was never worth having.

**The refusals are narrow on purpose.** They cover exactly the cases that make the record
*false or unreadable* — a severity no report can group by, a claim with no evidence behind
it, a follow-up with no destination. Anything merely *incomplete* still warns and still
writes. A check stricter than the rule it enforces does not produce rigour; it produces
entries nobody earned.

Step 5 is not paperwork. Promotion, retirement, the disagreement quota and every metric in
`04-ledger.md` read from it — **a gate with no ledger entry did not run**, whatever anyone
remembers.
