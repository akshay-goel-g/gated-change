# Experiment 001 — first real run

> Pre-registered per `tools/benchmark/README.md`. Written before either feature is
> built. Do not edit after starting — if the design turns out to be wrong, say so
> in `result.md`, do not quietly fix it here.

## What's being tested

Whether the pipeline's cost is worth what it catches, on one real pair of changes.
This is **one paired trial, not a study** — `tools/benchmark/README.md` is explicit
that a single pair is an anecdote. This is the anecdote that decides whether a real
study (6+ pairs) is worth running at all.

## The two features

Picked for similar real-world scope, genuinely independent (not the same feature
built twice — that would let the second build benefit from already knowing the
solution).

| Arm | Feature | Predicted tier | Repo location |
|---|---|---|---|
| **A — with pipeline** | Rule ID Range Overflow for Large Blocklists | T4 | `docs/V2-BACKLOG.md` |
| **B — without pipeline** | Schedule Validation Doesn't Enforce Duration Limits Per Level | T2/T3 | `docs/V2-BACKLOG.md` |

**Assignment was a coin flip, recorded before starting either build.** A is the
harder/higher-tier feature, which cuts against the pipeline looking artificially
good — if anything this is a conservative test.

## What gets measured

Both arms fill `tools/benchmark/session-record.md`: tokens, wall-clock minutes,
interventions, gates/findings (arm A only, arm B has none by design), and — at
+14 days — fix commits and any escapes.

## What would make this a clean result vs. a muddy one

- **Clean:** A finds a real edge case B-style development would have missed
  (there's a strong candidate already: what happens to a user who crosses 1000
  blocked sites on upgrade, vs. hitting the cap live) — cost difference is
  visible and attributable to specific gates, not vague "felt more thorough."
- **Muddy:** either feature turns out to be trivial or far larger than scoped,
  breaking the size match. If that happens mid-build, note it honestly rather
  than re-picking a more favorable pair after the fact.

## Failure modes we're accepting going in

- n=1 pair. Order effects don't apply (different features) but everything else
  in the benchmark README's "read this before designing an experiment" section
  still applies — especially observation effect: both of us know this is a test.
- Escape rate needs +3 months to mean anything. This experiment reports cost and
  shift-left findings only; the escape-rate section of `result.md` gets filled
  in later, not invented now.

---

Fill `result.md` after both arms are done and reconciled. Do not fill it partway.
