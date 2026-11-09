# System map

> Yours. **One page.** What exists, who owns it, what it depends on.
>
> Deliberately not an architecture diagram. Diagrams rot faster than anyone maintains
> them, and a diagram that is six months stale is worse than none because people still
> trust it. A component-and-owner list survives because it is cheap to correct.

## Why this exists

The coupling registry is a **behavioral** map: it records what breaks what, mined from
things that already went wrong. It never records what *exists*.

That leaves a specific blind spot: **a component nobody has broken yet is invisible to
Ripple.** The gate asks "what else does this touch?" and answers from incident history, so a
new or quiet component has no entry and gets no attention — right up until it is the thing
that broke.

This file is the structural half. Together they answer "what is there" and "what happens when
you disturb it."

---

## Components

Each row is something that can fail independently.

| Component | Does what | Owner | Fails how | Registry entries |
|---|---|---|---|---|
| | | | loud / silent | |

**"Fails how"** carries most of the value in this table. Anything marked **silent** needs a
self-check (`core/07-failure.md`) and probably belongs in the trust surfaces in
`surfaces.conf` — silent failure is the definition of T4.

## External dependencies

Things you rely on and do not control. Not a package list — the runtime dependencies whose
failure is *your* outage.

| Dependency | Used for | If it fails | Controlled by |
|---|---|---|---|
| | | | vendor / platform / us |

Package inventories belong to your dependency tooling, not here. This table is for the
handful whose failure changes what the product does.

## Data

Only what is persisted or leaves the process. If a row here involves personal data, enable
the **Comply** gate (`core/06-extending.md`) — it produces the detailed data-flow map, and
building that unconditionally is work most projects do not need.

| Data | Where it lives | Leaves the process? | Personal? |
|---|---|---|---|

---

## Keeping it true

**This file is updated by the Ripple gate, not on a schedule.** A change that adds a
component, adds an external dependency, or persists new data updates the map in the same
diff — and Ripple fails if it did not.

That coupling is the entire reason to trust this file. Documentation maintained on a cadence
drifts between cadences; documentation maintained by a gate drifts only if the gate is
skipped, which the ledger already records.

**Cap it at one page.** If it does not fit, you are describing implementation rather than
structure — the detail belongs in the feature docs, and what belongs here is the thing that
can fail on its own.
