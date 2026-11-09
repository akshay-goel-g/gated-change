# 00 — Starting from zero

> Portable. Do not edit.

Be running in **30 minutes**. Do not read the rest of `core/` first — most of it is reference
you will consult when a specific situation arises, not material to study up front.

---

## What this is

A routed review pipeline. Gates fire based on what a change actually touches, a coupling
registry remembers what already broke you, and a ledger tells you whether any of it works.

**"Why not just ask the AI to review my code?"** Review quality was never the problem.
Routing and memory are. An AI reviews whatever you point it at; it will not remember,
unprompted, that touching the rule builder means checking the priority space because a bug
three months ago says so.

## The shape

Five kinds of thing. Only one kind can fail.

| Kind | What it is | Can it fail? | Count |
|---|---|:--:|:--:|
| **Router** | Decides which gates run | It can misroute | 1 |
| **Gates** | A persona asking a question that can stop the change | **Yes** | 8 |
| **Phases** | Work that always happens | No | 5 — Build, Package, Deploy, Record, Release¹ |
| **Loops** | Fire on a trigger, not in sequence | No | 2 |
| **Protocols** | Rules that apply to every gate | No | 7 |

¹ Only Package and Deploy have their own chapter (`14-phases.md`) — Build, Record, and
  Release are named in the loop below and nowhere else. Release in particular is where an
  installable artifact's real irreversibility lives (a store publish, a permission-warning
  delta, a signing-key rotation) and R0a/R0b cannot see any of it — both tier a *diff*, and
  none of those events change a file. `01-router.md`'s R0d is the mechanism that closes the
  event-shaped half of that gap (a declared `ACTION::TIER::NAME::EVIDENCE` row, fired at
  Release, not at R0b) — see `LEARNINGS.md` for what it still leaves open.

```
  R0a TRIAGE · PREDICT
        ▼
  PLAN GATES              Intent · Scout · Craft
        ▼
  BUILD
        ▼
  PACKAGE                 produce the artifact          ← project/commands.conf
        ▼
  DEPLOY                  get it RUNNING                ← project/commands.conf
        ▼
  VERIFY GATES            Ripple · Proof · Peer · Threat · Dogfood
        ▼
  R0b TRIAGE · RECONCILE  + compliance check   (hard gate)
        ▼
  RECORD ──> RELEASE
        ▼
  LOOPS: HARVEST (a rule) · ADAPT (a gate)

  R0c RE-ENTRY: a gate finding that makes you edit a T3/T4 surface
                goes back to the top, at a new round.

  R0d ACTION: a declared no-diff event (store publish, key rotation…) —
              fires AT Release, not between Build and Release like R0b.
```

**The seven protocols** are the part people skip and should not. Five live in `02-gates.md`
and shape how every gate runs — *context* (verify gates run in a fresh session), *blind
review* (the reviewer gets the diff, not your explanation), *evidence* (every claim cites a
location, including agreement), *disagreement quota* (a gate that never contradicts you is
broken), and *failure* (what happens when a gate fails). Two more have their own files:
**Probe** (`10-probe.md`) runs at three checkpoints and forces a named doubt, and
**Grounding** (`12-grounding.md`) is the checklist against confident unchecked claims.

Gates catch problems in the code. Protocols catch problems in the reviewing.

---

## Install

**1. Copy the kit** into `.pipeline/` in your repo.

**2. Mine your registry.** This is the step that pays for the other four.

```bash
bash .pipeline/tools/mine-registry.sh
```

Your git history already contains your incidents: files repeatedly fixed together are
coupled whether or not anyone wrote that down. The script drafts candidates; you keep the
ones you can explain and delete the rest.

> **No history yet?** You get nothing, and that is correct. Start with the universal registry
> in `03-registry.md` and grow yours from the first real incident. **Do not invent couplings
> you have not experienced** — a registry of imagined failures is worse than an empty one,
> because it teaches you to skim.

**3. Answer five questions** into `project/surfaces.conf`, starting from the example:

```bash
cp .pipeline/templates/project/surfaces.conf .pipeline/project/surfaces.conf
```


| # | Question | Configures |
|---|---|---|
| 1 | What here, if it broke, would fail **silently**? | Trust surfaces (T4) |
| 2 | What platforms must every change work on? | Targets |
| 3 | What can a user do that they can never undo? | The T4 boundary |
| 4 | Where do secrets and credentials live? | Continuous security checks |
| 5 | What accumulates without a documented limit? | Scale ceilings |

**4. Wire enforcement** (`05-enforcement.md`): a pointer line in your agent's instructions
file, the pre-push hook, the PR checklist.

**5. Create the ledger and the records.**

```bash
touch .pipeline/ledger.jsonl
cp .pipeline/templates/SESSION-HANDOFF.md .pipeline/templates/INTENT-LOG.md \
   .pipeline/templates/LEARNINGS.md docs/
```

The ledger stays empty until the first gate runs — which is how you will know whether the
pipeline is real.

---

## The four records

Four files, separated by **write pattern**. That is the honest reason they are not one
document: mixing an append-only record into a rewritten one loses the record.

| Record | Write pattern | Holds | Discipline |
|---|---|---|---|
| **Handoff** | Rewritten in place | Where we are *now* | **~100 line cap.** Over it, content is done (delete) or a decision (move to the intent log) |
| **Intent log** | Append-only, never edited | What was asked, and why | Three lines per session |
| **Learnings** | Append-only | What broke, what we now know | "Why we missed it" is the field that pays |
| **Ledger** | Append-only, machine-written | What the gates did | Never backfilled |

**The intent log earns its place by holding what git cannot: decisions that left no code
behind.** Git records what was done; it has no record of what was considered and rejected,
what scope was cut, or what is still open. That is precisely what a later session needs in
order to say "we already looked at that."

**The handoff cap is not cosmetic.** A handoff left uncapped accretes until it is an archive
pretending to be a status, and an unread handoff is worse than none — the next session trusts
it and skips ahead.

---

## Your first feature

```
"I want to build X"
   ├─ Triage              2 min    tier, surfaces, targets, gate list
   ├─ requirements.md     confirm
   ├─ design.md           confirm
   ├─ tasks.md            confirm
   ├─ Build
   ├─ Package + Deploy    seconds  produce the artifact, get it RUNNING
   ├─ The gates the tier requires
   ├─ reconcile.sh        seconds  did the diff match the prediction?
   ├─ ledger.sh compliance         did the gates that decide this actually pass?
   └─ Release → Harvest
```

A trivial change is five steps, most of them seconds. **If your first change feels heavy you
probably tiered it too high** — which is the safe direction to be wrong in.

**Deploy comes before the gates** because G8 Dogfood's input is the RUNNING product
(`14-phases.md`), and **compliance comes after reconcile** because they answer different
questions: reconcile asks *is this the tier I predicted*, compliance asks *did the gates that
tier mandates actually pass*. Only the second can tell you the change is not ready.

---

## What to ignore at first

Adoption fails from starting with all of it. Defer, in this order:

- **The gate library** (`06-extending.md`) — enable nothing until a change touches that surface
- **Adapt** — you cannot know which gates you lack before running any
- **Promotion and retirement** — needs ten runs of ledger data to say anything
- **The metrics** (`04-ledger.md`) — compute after a month, not a week

**Start with:** the router, eight gates at default tiers, the universal registry, the ledger,
and the probe protocol. That is the whole system. Everything else is what it grows into.

---

## Two maps, and why you need both

The **coupling registry** (`project/registry.md`) is a *behavioural* map: what breaks what,
mined from things that already went wrong. The **system map** (`project/map.md`) is a
*structural* one: what exists at all.

The gap between them matters. Ripple asks "what else does this touch?" and answers from
incident history — which means **a component nobody has broken yet is invisible to it**, right
up until it is the thing that broke. The registry is necessarily backward-looking; the map is
what covers the parts that have been quiet.

Both are maintained by Ripple, in the diff, not on a schedule.

## Governance, if there is more than one of you

The rest of this kit is written as though one person and one agent do everything. That works
solo and stops working the moment there are two humans: "escalate to the person who asked"
stops being a name, and a logged bypass with no reviewer is just a file.

`project/govern.md` is one page — roles, escalation, the exception audit, and the review
cadence. **Solo? Write your own name in every row.** The point is not delegation; it is that
the function is named, so adding a second person is a one-line edit rather than an
archaeology exercise.
