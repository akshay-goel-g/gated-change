# Governance

> Yours. One page. Who decides, who reviews, and how often.
>
> The rest of the kit is written as though one person and one agent do everything. That
> works solo and falls apart the moment there are two humans: "escalate to the person who
> asked" stops being a name, and an audit trail with no auditor is just a file.

## Roles

Fill in names, not job titles. A title cannot be asked a question.

| Role | Who | What they decide |
|---|---|---|
| **Change owner** | *(per change)* | Tier prediction, which gates run, whether a doubt is resolved |
| **T4 approver** | | Signs off irreversible changes. Should not be the same person who wrote it |
| **Registry owner** | | Curates `registry.md` — what gets added, what gets deleted |
| **Exception auditor** | | Reviews every logged bypass. See below |
| **Risk owner** | *(per risk)* | Named in `risks.md`. Owns the review date, not the code |

**Solo project?** Write your own name in every row. The point is not delegation — it is that
the *function* is named, so when a second person arrives the handover is a one-line edit
rather than an archaeology exercise.

## Escalation

Probe and the edge-decision rule both say "escalate to the person who asked." Concretely:

| Decision | Goes to |
|---|---|
| A product decision surfaced by an edge case | Change owner, then the requester if they disagree |
| Shipping with an unresolved doubt | T4 approver if T3+; change owner otherwise |
| Accepting a new standing risk | Risk owner + T4 approver, recorded in `risks.md` |
| Overriding a hard gate | T4 approver. **Never the author alone** |

## Exception audit

`--no-verify` is allowed and expected. What is not allowed is using it without a ledger
entry. **The entry only means something if someone reads it.**

```bash
grep '"outcome":"skipped"' .pipeline/ledger.jsonl
```

The exception auditor runs this on the cadence below and asks one question per row: *was
this a real emergency, or is a gate being routed around?* Three skips of the same gate in a
month is not an emergency pattern — it is a gate that does not fit the work, and it should be
fixed or retired rather than repeatedly bypassed.

## Cadence

Nothing here is continuous. Each item has an owner and a frequency, or it will not happen.

| What | How often | Owner | Reads |
|---|---|---|---|
| Exception audit | Monthly | | `ledger.sh` skipped entries |
| Metrics review | Monthly | | `ledger.sh report` |
| Risk review | Quarterly | | `risks.md` — still true? accept again? |
| Registry curation | Quarterly | | `registry.md` — anything unexplained gets deleted |
| Persona rule review | After 10 firings | | `personas.md` — promote, revise, drop |
| Gate retirement check | Quarterly | | `ledger.sh gates` — zero yield over 10+ runs |
| Map accuracy | On any new component | | `map.md` |

**A cadence with no owner is a wish.** If a row has no name, delete the row rather than
pretend it happens — an unkept schedule teaches people the whole file is decorative.

## Model and tooling record

Gates are graded by an AI model, and models change. The ledger records which one ran each
gate (`--model`), so that when results shift you can tell a process change from a model
change. Record here which models are approved for which tier of work — the table in
`core/08-models.md` is the guidance; this is your commitment.

| Work | Model | Since |
|---|---|---|
| Reasoning gates (Ripple, Peer, Threat) | | |
| Judgment gates (Craft, Scout) | | |
| Routing and mechanical checks | | |
