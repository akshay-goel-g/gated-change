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
| the `confidence` vocabulary — `ledger.sh`'s accepted values (incl. the `cmd_add` write-side guard: `fresh\|low` closed set, and **required for a `pass`/`fail` verdict**), a gate card's `logs_with:` line, or `04-ledger.md`'s definition | `tools/dashboard/app.js`'s `isIndependent()` (and `cmd_report` / `cmd_gates`'s literal `grep -c '"confidence":"fresh"'` / `"low"`), plus any tool-emitted `ledger.sh add` command string (`cmd_compliance`'s remediation hints) | `isIndependent()` is a strict `=== "fresh"` allow-list — a value it does not recognise silently renders a real fresh-context review as an author self-check and drops it from the fresh/low/challenge-rate counts. `ci-to-codebuild` G7 round 2 logged `--confidence true` (`pass`, challenged) and it vanished from the disagreement quota until a corrected append (commit `b471896`, 2026-09-08). The vocabulary is duplicated across `ledger.sh` (write guard **and** the `add` hints it prints), all 8 gate cards, `04-ledger.md`, and `app.js`; changing one without the others is the failure. |

---

## Retired entries

Keep them, with the date and the reason. A coupling that stopped being true because the
design changed is useful history; silently deleting it invites someone to re-derive the same
rule from the same old incident.

| Entry | Retired | Why it no longer holds |
|---|---|---|
| | | |
