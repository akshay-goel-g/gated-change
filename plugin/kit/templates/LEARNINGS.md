# Learnings

> Append-only. Written by the Harvest loop, after any escaped defect and any T3/T4
> change.
>
> **What broke, and what we now know because of it.** Distinct from the intent log
> (what was *asked*) and the handoff (where we *are*).

## Format

```markdown
### <short name>
Date        : YYYY-MM-DD
What broke  : the observable symptom, not the diagnosis
Root cause  : what was actually true
Why we missed it : which gate should have caught this, and why it did not
Now         : the rule, test, or registry entry that exists because of this
```

**"Why we missed it" is the field people skip and the one that pays.** A learning
that records a bug teaches you one bug. A learning that records *which gate was
blind* changes how every future change is reviewed.

## Promotion

Not every learning stays here. Three destinations, and most entries take one:

| If the lesson is… | It goes to |
|---|---|
| A coupling — "touching X means checking Y" | `project/registry.md`, and Ripple picks it up automatically |
| A risk classification — "Z is more dangerous than we thought" | `project/surfaces.conf`, so routing changes |
| A way of thinking — "we consistently assume too much here" | `project/personas.md`, via the evolution process |
| Specific to one incident, generalising to nothing | Stays here. That is fine — most do |

**A learning that keeps recurring across entries is the signal that a gate is
missing.** That is the Adapt trigger.

---

## Platform discoveries

Surprises about the platform, framework, or store you ship to — as opposed to
mistakes you made. Kept as a section here rather than a separate file: a second
learnings document means two places to check and one that rots.

```markdown
### <thing that surprised us>
Expected : …
Actual   : …
Source   : the doc, issue, or experiment that settled it
```

---

## Entries

<!-- Newest at the bottom. Append, do not edit. -->
