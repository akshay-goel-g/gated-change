# Agent instructions snippet

Paste into whichever file your agent reads automatically every session —
`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, or your tool's equivalent.

**This is the weakest of the three enforcement points and the only one that acts
before work starts, when routing is still cheap.** Keep it short: a long block gets
skimmed, and this needs to be read every single time.

---

```markdown
## Pipeline

At session start:
0. `bash .pipeline/tools/status.sh` — what has landed since the last gate run, which
   gates have never run, what is not installed. Takes no arguments and needs no prior
   knowledge of what I am working on. If it reports unrouted T3/T4 work, route that
   before starting anything new; a pipeline that quietly stopped running is the failure
   this catches, and nothing else in the kit can see it.

Before any change:
1. Run Triage (`.pipeline/core/01-router.md`) — tier, surfaces, visibility, targets.
   Then, before writing requirements: **what did they not say that I assumed?**
   (`10-probe.md` checkpoint 1). Every gap I filled in rather than asked about gets
   logged, not just thought about:
   `bash .pipeline/tools/ledger.sh assume --change <name> --assumed '<what>' --resolution asked|verified|defaulted [--basis '<why>']`
   Ask when the answer changes WHAT gets built, when it is a product decision, or when
   two readings differ materially — decide myself when a conventional default exists.
   `defaulted` is allowed and recorded; `compliance` REFUSES it at T3/T4, because a gate
   verifying an invented premise passes while checking the wrong thing. Each gate card's
   `must_ask:` line names what that gate specifically may never invent.
   "Before any change" is not only a ticket labeled as one — recognize it in whatever
   shape it actually arrives: a user pasting a bug report or stack trace, a
   mid-discussion "okay, just build it," or any other point where I am about to write
   code without a preceding, explicit "run Triage first." If code is about to change,
   Triage applies, regardless of how the request was phrased.
2. Write `specs/<feature>/requirements.md`, confirm, then `design.md`, confirm,
   then `tasks.md`, confirm. Do not write all three in one pass — the file
   boundary is the approval boundary.
   - Net-new capability: `requirements.md`'s "Prior art" section is Scout's real output —
     actual competing products researched, not assumptions, gap named AND a comparison
     table with an include/exclude/improve call per product. Confirm this section
     specifically before moving on, same as the rest of the file.

Before any release:
3. `CHANGE=<name> bash .pipeline/tools/reconcile.sh <predicted-tier> --log` — a change
   may not ship without a reconciliation result. Set `CHANGE=` so the route record
   joins up with the gate records for the same work; on a trunk branch the tool
   refuses the branch-name default.
4. Log every gate run: `bash .pipeline/tools/ledger.sh add --change <name> ...`
5. `bash .pipeline/tools/ledger.sh compliance --change <name> --tier <T> --round <N>`
   — must exit 0. "Reconciled" is a routing verdict; this is the release one.
   An `UNRESOLVED` gate is a footnote in the matrix I have to answer: run it, or
   `--outcome n/a --note "<why it does not fire here>"`. Never `skipped` to clear it.

**Re-entry (R0c).** If a gate finding makes me edit a T3/T4 surface mid-session,
that edit re-enters at R0a — re-run reconcile at a new `--round`. A fix found by a
gate is still a change, and it is the one most likely to skip routing.

**Declared events (R0d).** If this release includes a store-side event that changes
no file — pressing Publish, a permission-warning delta, a staged-rollout ramp, a
signing-key rotation, a listing/privacy-disclosure edit — step 3's diff cannot see
it, no matter how correctly `surfaces.conf` is filled in. Declare it explicitly:
`bash .pipeline/tools/reconcile.sh --action <name> --evidence "<citation>"`
(composes with step 3 in the same call when there is also a diff). This fires only
when I remember to invoke it — nothing detects the event on its own — so treat a
release with one of these events and no `--action` call as an incomplete step 3,
not an optional extra.

Always:
- Surface `.pipeline/dashboard.html` (`bash .pipeline/tools/dashboard.sh`) starting at
  `requirements.md`, not just before release — a reviewer should not have to ask where
  pipeline status lives.
- Verify gates (Ripple, Peer, Threat, Dogfood) run in a FRESH session, and receive
  the diff — not my explanation of what it does.
- Every claim about the code cites file:line, including agreement
  (`.pipeline/core/12-grounding.md`).
- Name at least one doubt before claiming done (`.pipeline/core/10-probe.md`).
  "Nothing" is not an available answer.
- Flag any asset you cannot produce at Triage, not at release
  (`.pipeline/core/09-capabilities.md`).
```

---

## Why this wording

**"Do not write all three in one pass"** — without it, an agent writes requirements,
design, and tasks in a single response, and the confirmation points that make the
sequence worth anything never happen.

**"receive the diff — not my explanation"** — the blind review rule. Telling a
reviewer what a change does guarantees they confirm that story and miss what you
did not mention.

**"including agreement"** — unsupported agreement is the expensive failure. "Looks
correct" without a citation is indistinguishable from not having checked.

**'"Nothing" is not an available answer'** — a self-audit with an available
all-clear returns all-clear, every time, in four seconds.

**The "recognize it" phrasing under step 1** is documentation, not a new enforcement
point — `05-enforcement.md`'s closing rule mechanises binary, checkable answers only
("did a report exist, did permissions grow") and leaves judgment calls to judgment,
because a shape-based classifier for "was this really a change request" is exactly the
kind of rule people route around. Naming the scenarios in plain language, inside the
existing weakest-but-earliest enforcement point (session load), is the cheapest fix
that does not add a fourth mechanism. Fresh-project routing (no git history yet) is
already handled by the README / `00-start.md` and is untouched here.
