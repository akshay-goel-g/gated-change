---
name: reconcile
description: Recompute the risk tier of the current change from the real git diff and record it in the ledger. Use before running review gates, or after the change turned out bigger than planned.
---

# Re-derive the tier from the real diff

The predicted tier is a guess. This recomputes it from what the diff actually touches.

Ask the user for their **predicted tier** (`T0` to `T4`), or read it from their plan. Then, from the
project root:

```bash
bash .pipeline/tools/reconcile.sh <predicted-tier>
```

That form only prints. Show the user the result: the tier the diff implies, the surfaces that
triggered it, and the gates that tier requires. If the actual tier is **higher** than predicted, say so
plainly, because that is the case the tool exists to catch.

Only when the user confirms, record it in the ledger:

```bash
bash .pipeline/tools/reconcile.sh <predicted-tier> --log
```

Follow-up rounds on the same change use `--round N` (or `ROUND=N`). Do not pass `--restart-lineage`
unless the user explicitly asks for it: it makes every earlier gate result stop counting.

If `.pipeline/` does not exist, tell the user to run `/gated-change:install`.
