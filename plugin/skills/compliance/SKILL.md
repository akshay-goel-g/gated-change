---
name: compliance
description: Check whether a change is ready by asking the ledger whether the gates its tier mandates actually passed, and print the ledger report. Use when the user asks if a change is ready to ship.
---

# Is this change ready?

Readiness is computed from the ledger, not decided by anyone's say-so.

From the project root, ask which change is meant. Read its name and round from the last `route` line for
that change in the ledger: `.pipeline/ledger.jsonl`, or `ledger.jsonl` under `$PIPELINE_DATA` when that is set
(the `LEDGER` variable overrides both). Each line is one JSON object and the name is stored JSON-escaped:
`\"` stands for `"` and `\\` for `\`. To find a name that holds one of those, search for its escaped form, and
use the decoded name afterwards. If the name holds any other backslash escape (`\n`, `\t`, `\r`, `\u`), stop and
ask the user for the name. That line carries `predicted` and `actual` tiers and no `tier` field: use `actual`.
Use the tier only if it is exactly `T0` to `T4` and the round only if it is a whole number; otherwise stop and ask.

Pass the name as one single-quoted argument. A backslash, a `$`, a backtick, a double quote, a space or a
non-ASCII character is literal inside single quotes, so quote the name and say which name you used. If the
name holds a single quote, do not run the command yourself: show the user the name and ask them to run the
command below, writing each single quote in the name as `'\''` (so `it's` becomes `'it'\''s'`), which works
whatever else the name holds. Otherwise run it (a call can take a minute on Windows Git Bash; wait for it, and
do not chain several calls in one command):

```bash
bash .pipeline/tools/ledger.sh compliance --change <name> --tier <T0-T4> --round <N>
```

Report its verdict verbatim, then the reason for each gate it lists (`pass`, `fail`, `skipped`,
`NOT RUN`, `UNRESOLVED`). Do not soften a refusal, and do not log a gate to make it pass.

`Tier T0 mandates no gates. Nothing to check.` means nothing is required at that tier; it does not say the
change is good. An INCOMPLETE verdict lists the gates still owed: tell the user which ones, and that running
them is the next step.

The tools also print commands that name the change: `reconcile.sh --log` ends with one, and the verdict can
suggest an `add` line. Never run or repeat one as printed. `reconcile.sh` writes the name in double quotes with
no escaping (so `$` and backticks expand), and older kits print the name raw in the `add` line. If you show such a
command to the user, rebuild it with the decoded name in single quotes, for example
`--change 'has space'` (a name holding a single quote: leave the quoting to the user). An
`add ... --outcome n/a` line is the user's decision, never something to run to clear an UNRESOLVED gate.

A route written with plain `ledger.sh route` and no `--base` is advisory: the verdict says no base commit is
recorded and gate records are not checked against commits. A route made with `reconcile.sh --log` is bound
to a commit when a merge-base is found.

For numbers across the whole project:

```bash
bash .pipeline/tools/ledger.sh report
```

That prints gate runs, findings per gate, challenge rate and tokens spent. It is read-only.

If `.pipeline/` does not exist, tell the user to run `/gated-change:install`.
