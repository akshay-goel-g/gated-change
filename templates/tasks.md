# <feature> — Tasks

> Written at Triage, after design is confirmed. This is the plan and the record.

## Routing

| | |
|---|---|
| **Predicted tier** | T_ |
| **Surfaces touched** | |
| **Visibility** | invisible / visible / behavior-changing |
| **Targets** | |

## Gates to run

From the tier. Delete the ones the router did not select — do not leave them unchecked and
ambiguous, or nobody can tell later whether a gate was skipped or forgotten.

- [ ] Intent · Define — 10 min
- [ ] Scout — 20 min
- [ ] Craft — 15 min
- [ ] Ripple — 10 min
- [ ] Proof — 30 min
- [ ] Peer — 15 min *(fresh context)*
- [ ] Threat — 20 min *(fresh context)*
- [ ] Dogfood — 15 min *(fresh context)*

## Steps

Ordered, each independently verifiable. A step you cannot verify on its own is two steps.

- [ ] …
- [ ] …

## Reconciliation

Run after Build, before release:

```bash
bash tools/reconcile.sh T_    # your predicted tier
```

| | |
|---|---|
| **Actual tier** | |
| **Verdict** | reconciled / under-classified |
| **Gates re-run** | |

## Acceptance

Filled in at Intent · Accept, after Build. **A criterion without evidence was not built —
it was discussed.**

| Criterion | Evidence |
|---|---|
| | |

## Ledger

One line per gate run appended to `.pipeline/ledger.jsonl`:

```json
{"date":"","change":"","tier":"","gate":"","findings":0,"outcome":"pass","confidence":"fresh","challenged_premise":false,"minutes":0}
```
