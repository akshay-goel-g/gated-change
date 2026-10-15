# Session record — <change name>

> One per change, for Study 2 in README.md. Copy, fill, keep. Ten of these answer
> whether the pipeline pays for itself.

| | |
|---|---|
| **Date** | |
| **Change** | |
| **Arm** | pipeline / no-pipeline |
| **Predicted tier** | |
| **Reconciled tier** | |

## Cost

| Metric | Value |
|---|---|
| Tokens in | <!-- If an agent is running this session, it usually cannot read back its own token count — leave this blank rather than guess, and use the subagent row below as the best available proxy. --> |
| Tokens out | |
| Subagent token cost, if gates ran as subagents | <!-- Sum of each gate subagent's reported token usage. This is the number that has no equivalent in a human-run pipeline — record it even when the two rows above are blank. --> |
| Wall-clock minutes (start → merge) | |
| Gate-minutes, summed across gates | <!-- Only differs from wall-clock when gates run as parallel agent subagents rather than serially. If they ran serially (a human review team, or an agent working gate-by-gate), this equals wall-clock and you can delete the row. If they ran in parallel, wall-clock is the honest cost figure and this row is the honest EFFORT figure — report both, they answer different questions. --> |
| Interventions (times you corrected course) | |
| Gates run | |

## Findings

| Gate | Findings | Before or after Build? | Challenged your premise? |
|---|---|---|---|
| | | | |

**Shift-left ratio:** findings before Build ÷ all findings = ____

## Outcome (fill in at +14 days)

| | |
|---|---|
| Fix commits to these files within 14 days | |
| Defects reported by users | |
| **Escapes** (found after release) | |

## Notes

What actually happened. Especially: anything that made you want to skip a gate, and whether
you did. **That is the most valuable line in this file** — a process people route around
under pressure has already failed, and this is the only place that gets recorded.
