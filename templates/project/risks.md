# Risk register

> Yours. **Standing risks** — the ones that persist between changes.
>
> Tiering classifies the risk of *a change*. This holds the risk that stays true after
> the change ships: the thing you know is wrong and chose not to fix, the limit you have
> not tested, the dependency you cannot control.

## Why this file exists

An accepted risk that lives only in someone's head gets **silently re-litigated** — someone
"fixes" it six months later, breaks the thing it was protecting, and nobody remembers why it
was that way. Or worse, it gets **silently forgotten**, and the acceptance decays into an
unexamined bug.

A risk entry is not a bug report. It is a **decision with a name on it**.

---

## Entries

| ID | Risk | Impact if it fires | Decision | Owner | Accepted | Review by |
|---|---|---|---|---|---|---|
| R-001 | | | accept / mitigate / transfer | | | |

**Decision** is one of:

- **accept** — we know, we are not fixing it, here is why
- **mitigate** — partially reduced; state what is left over (that residue is the risk)
- **transfer** — someone else's problem now (a vendor, a platform guarantee). Name who, and
  note that transferring a risk does not remove it, it only moves the failure

**Review by** is a date, never "ongoing". A risk with no review date is not accepted, it is
abandoned — and the difference only shows up when it fires.

---

## What belongs here

- A known defect you chose not to fix, and why
- A limit you have not tested and do not intend to yet
- A dependency whose failure you cannot control or detect
- A workaround that is load-bearing
- Something the pipeline deliberately does not gate

## What does not

- Bugs you intend to fix → the tracker
- A one-off risk inside a single change → `design.md` for that feature
- A coupling → `registry.md`
- A lesson from something that already broke → `LEARNINGS.md`

---

## Retired risks

Keep them. A risk that stopped being true is useful history; deleting the row invites
someone to rediscover it and accept it again from scratch.

| ID | Retired | Why it no longer applies |
|---|---|---|
| | | |

---

## Review

Risks are reviewed on the cadence in `govern.md`. Two questions per entry, and both must be
answered out loud:

1. **Is it still true?** Conditions change; an accepted risk can quietly become unacceptable
   when usage grows or the surrounding code moves.
2. **Would we accept it again today, knowing what we know now?** If the honest answer is no,
   it is not an accepted risk any more — it is an open defect wearing a decision's clothes.
