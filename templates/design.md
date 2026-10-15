# <feature> — Design

> Written at the Ripple gate, after requirements are confirmed.
> Stop here and confirm before writing `tasks.md`.

## Approach

Structure, state machine, data flow. What shape does this take, and why this shape.

## Couplings triggered

From your registry. Every trigger hit needs the check **performed**, not just noted.

| Registry entry | Check performed | Result |
|---|---|---|
| | | |

## Edge decisions

Edges are decided, not assumed. Walk the classes and record an answer for every row that
applies. Anything whose correct behavior is a **product** decision goes to the person who
asked — it is not guessed.

| Edge | Decided behavior | Decided by |
|---|---|---|
| Zero / one / many / max | | |
| Null vs undefined vs missing vs empty | | |
| Concurrent access | | |
| Slow, offline, timeout | | |
| Interrupted halfway | | |
| First run vs upgrade | | |
| Permission denied | | |

## Error contract

For each new failure mode: does the user need to know, is it recorded where we will look,
and does the system recover, degrade, or stop?

| Failure | User | Developer | System |
|---|---|---|---|
| | | | |

## Silent failure

How would we know if this broke in production and nobody reported it? "The user will tell
us" is a failing answer for anything whose failure is invisible.

> …

## Independence

- [ ] No new shared symbol in a shared scope
- [ ] No storage key added or renamed that another module reads
- [ ] No id/priority consumed from a shared space
- [ ] No dependence on load order
- [ ] Tests pass with no other pending change applied

**Verdict:** independent / depends on ______ (must ship together or behind a flag)
