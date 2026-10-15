# Coupling registry

> Yours. The curated registry — the one gates actually read.
>
> `tools/mine-registry.sh` writes **candidates** to `registry-draft.md`. This file holds
> only what survived. The draft is disposable; this is not.

Universal couplings (auth → session invalidation, migrations → rollback, quotas →
enforce-at-write, and the rest) live in `core/03-registry.md` and apply automatically. Do
not copy them here — record only what is true of *this* codebase.

---

## The shape of an entry

> **If you touch X, you must also check Y — because Z happened.**

The **because** is the whole value. "They are related" gets skimmed past; "the allow rule is
evaluated above the block rule" gets checked.

## The bar for inclusion

1. Could this have been caught by asking one question before the change?
2. Is that question **non-obvious** to someone competent reading the code?
3. Can you name the incident that proves it?

Three yeses, it is an entry. Fewer, it is a code comment.

**Delete anything you cannot explain.** One unexplained rule teaches everyone to skim, and a
skimmed registry is worse than no registry — it costs the same attention and returns nothing.

---

## Entries

| If you touch… | You must also check… | Because |
|---|---|---|
| | | |

---

## Retired entries

Keep them, with the date and the reason. A coupling that stopped being true because the
design changed is useful history; silently deleting it invites someone to re-derive the same
rule from the same old incident.

| Entry | Retired | Why it no longer holds |
|---|---|---|
| | | |
