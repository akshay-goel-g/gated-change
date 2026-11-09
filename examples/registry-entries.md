# Example registry entries

What good entries in `project/registry.md` look like. Every one has the same shape:

> **If you touch X, you must also check Y — because Z happened.**

These are **fictional illustrations of the form**, not entries to copy. The kit's own advice is that a
registry of imagined failures is worse than an empty one — copy the shape, then write down
only couplings you have actually been bitten by. Delete any row you cannot explain.

## Good — specific, checkable, names its incident

| If you touch… | You must also check… | Because |
|---|---|---|
| `lib/pricing.js` `roundCents()` | `invoices/pdf.js` and the Stripe webhook handler both round independently | A one-cent drift between the invoice and the charge caused ~40 support tickets in March |
| `jobs/send-digest.js` schedule | The `users.timezone` null case — it falls back to UTC, not the account's region | EU users received the 08:00 digest at 03:00 for a week |
| The `session` cookie name | `middleware/csrf.js`, which reads the same name by string | Renaming it logged everyone out *and* silently disabled CSRF checks for a deploy |
| `config/features.yml` defaults | Records created before the key existed, which inherit the new default | Turning `export_enabled` on by default exposed the export to accounts created before the paywall |

## Weak — and why

| Entry | What is wrong |
|---|---|
| "auth and users are related" | No *because*. It will be skimmed past |
| "be careful with the database" | Not checkable — there is no answer that would stop a change |
| "touching `utils/` may affect things" | A trigger so wide that it fires on everything, so it is read as nothing |
| A row you cannot explain a month later | Delete it. One unexplained rule teaches everyone to skim |

## The bar (from `templates/project/registry.md`)

1. Could this have been caught by asking one question before the change?
2. Is that question **non-obvious** to someone competent reading the code?
3. Can you name the incident that proves it?

Three yeses is an entry. Fewer is a code comment.
