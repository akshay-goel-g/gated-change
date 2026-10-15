---
name: compliance
description: Check whether a change is ready by asking the ledger whether the gates its tier mandates actually passed, and print the ledger report. Use when the user asks if a change is ready to ship.
---

# Is this change ready?

Readiness is computed from the ledger, not decided by anyone's say-so.

From the project root, ask for the tier and round of the change (they are in the ledger's last
`route` line for it), then run:

```bash
bash .pipeline/tools/ledger.sh compliance --tier <T0-T4> --round <N>
```

Report its verdict verbatim, then the reason for each gate it lists (`pass`, `fail`, `skipped`,
`NO RECORD`, `UNRESOLVED`). Do not soften a refusal, and do not log a gate to make it pass.

For numbers across the whole project:

```bash
bash .pipeline/tools/ledger.sh report
```

That prints gate runs, findings per gate, challenge rate and tokens spent. It is read-only.

If `.pipeline/` does not exist, tell the user to run `/gated-change:install`.
