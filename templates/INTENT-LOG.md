# Intent log

> Append-only. Never edited, never reordered, never pruned.
>
> **What this holds that git does not: decisions that left no code behind.**
> Git records what was done. It has no record of what was considered and rejected,
> what scope was cut, or what question is still open — which is exactly what a
> future session needs in order to say "we already looked at that" instead of
> re-deriving it from scratch.

## Format

One entry per session. **Three lines.** If an entry produced code, git already has
the detail and the entry should be short. If it produced a *decision*, that is the
part worth writing.

```markdown
- YYYY-MM-DD · Asked: <what was requested, in the requester's terms>
  Decided: <what we chose, and the reason if it was not obvious>
  Deferred: <what we consciously did not do> · Open: <what is still unanswered>
```

Anything longer than three lines belongs in a design doc, with a link from here.

## Why append-only

An entry that turns out to be wrong stays. **The record of a decision that did not
work out is as useful as one that did** — it is what stops the same idea being
re-proposed every quarter with the same enthusiasm and the same outcome. Correct it
with a *new* entry that references the old one; never edit the original.

---

## Entries

<!-- Newest at the bottom. Append, do not insert. -->

- YYYY-MM-DD · Asked: …
  Decided: …
  Deferred: … · Open: …
