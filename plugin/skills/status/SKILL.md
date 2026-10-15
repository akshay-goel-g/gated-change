---
name: status
description: Report whether the gated-change pipeline is actually on in this repository, what has landed since the last gate run, and which gates have never run. Use when the user asks if the pipeline is working or what is unrouted.
---

# Is the pipeline on?

Run this from the project root:

```bash
bash .pipeline/tools/status.sh
```

If `.pipeline/` does not exist, the kit is not installed. Tell the user to run `/gated-change:install`.

`status.sh` compares the ledger against git history and can take a minute on a large repo. It is
read-only. Report back, in this order:

1. Whether the **enforcement points** (pre-push hook, Claude Code reminder hook, dashboard) are installed.
2. How many commits have **landed without a gate run**, and at which tier.
3. Which gates have **never run**.

Quote its own recommendation line if it prints one. Do not run the suggested command without asking.
