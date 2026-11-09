# Reference documents

> Yours. An index of documents provided to this project, and what was taken from each.
>
> This is not storage — the documents live wherever they live. This answers **"where did
> this constraint come from?"**, which otherwise has no home and gets answered from memory.

## Why record it

A registry entry whose *because* is "the vendor's API doc §4.2, provided 2026-08" can be
re-checked when the vendor changes it. One whose because is "someone said so" cannot, and
will eventually be either wrongly obeyed or wrongly deleted.

## Entries

```markdown
### <document name>
Received  : YYYY-MM-DD · from <who>
Location  : <path in repo, or where it lives>
Kind      : spec | API doc | style guide | standard | competitor material | other
Authority : does this OVERRIDE our own decisions, or inform them?
Extracted : what was pulled out, and where it went
Re-check  : when this document changes, what needs revisiting
```

**`Authority` is the field people skip.** A vendor's API contract overrides your preferences;
a competitor's manual does not. Recording which kind it is prevents the common failure of
treating an external suggestion as a requirement — and the rarer, worse one of treating a hard
external constraint as a suggestion.

---

*None yet.*

---

## Extraction reminder

A document that was read but not extracted from has changed nothing. Before closing an entry,
check the routing table in `core/13-references.md`:

**what to check → registry · when to worry → surfaces · what a feature must know → the spec
templates · how to judge → personas · hard limits → ceilings · unavoidable constraints →
risks**

If nothing was extracted, say so explicitly and why — "read, nothing to extract" is a valid
outcome and a useful record. Silence is not.
