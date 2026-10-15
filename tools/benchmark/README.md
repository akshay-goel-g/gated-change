# Benchmark — does the pipeline actually help?

The pipeline's central claim is that routed gates catch more defects per unit of effort than
either reviewing everything or reviewing nothing. **That claim is currently unproven.** This
harness exists to test it, including the possibility that it is false.

---

## Read this before designing an experiment

A clean randomised trial is not available to you, and pretending otherwise produces numbers
that look rigorous and mean nothing. The specific problems:

| Problem | Why it breaks a naive A/B |
|---|---|
| **Order effects** | Build the same feature twice and the second run is faster because you already solved it. This alone can swamp the effect you are measuring |
| **n = 1** | One feature per arm tells you about that feature, not about the method |
| **Context contamination** | The "no pipeline" arm still runs with a model that read your house rules. It is not a clean control |
| **Lagging outcome** | The metric that matters — escapes — only appears weeks after release. Everything measurable on day one is a proxy |
| **Observation effect** | You work differently when you know you are the experiment |

**What follows from that:** measure cost precisely, measure outcomes honestly but slowly, and
never report a single paired trial as evidence of anything.

---

## Three studies, cheapest first

### Study 1 — Retrospective (free, run it today)

Your existing history already contains the data. No experiment, no waiting.

```bash
bash measure.sh --since "18 months ago" --paths "src/auth"
```

For each feature area, `measure.sh` computes the **rework ratio**: what fraction of commits
touching that area were fixes to it rather than additions. High rework means defects escaped
the process that was in place at the time.

Then compare eras: if you adopt the pipeline in March, compare rework rates for features
shipped before and after. **This is correlational, not causal** — your skill also improved,
the codebase changed, the easy features may have come first. It is still the highest
information-per-minute measurement available, and it costs nothing.

### Study 2 — Cost measurement (one week)

Cost is objective and immediate. For every change, record what it took:

| Field | Source |
|---|---|
| `tokens_in` / `tokens_out` | Session totals |
| `wall_minutes` | Start to merge |
| `gates_run` | The ledger |
| `findings` | The ledger |
| `interventions` | Times you had to correct course |
| `rework_14d` | Fix commits to the same files within 14 days |

Use `session-record.md` per change. After ~10 changes you can answer the question that
actually decides adoption: **cost per finding, and whether findings came before or after
release.** A pipeline that costs 30% more and moves defects from "found by users" to "found
by Threat" is a good trade. One that costs 30% more and finds the same things later is not.

### Study 3 — Paired features (weeks, weak but real)

If you insist on a controlled comparison, do it properly:

1. Pick **two different features of similar size** — never the same feature twice
2. **Randomise** which one gets the pipeline (coin flip, before you start)
3. Alternate on every subsequent pair, so ordering and learning average out
4. Run at least **six pairs** before drawing a conclusion
5. Pre-register the outcome you will measure, in writing, before you start

With six pairs you have a weak signal. With one pair you have an anecdote you will
over-trust because you built it.

**A third failure mode, beyond trivial/oversized:** the backlog item itself may be stale — the
bug it describes may already be fixed, or may describe re-adding something that was already
built and deliberately removed. Pre-register what you'll do if this happens (rescope and
proceed vs. pick a different pair) rather than deciding after you've seen which arm it landed
in — the whole point of pre-registration is that the decision doesn't get to know the outcome
yet. If it happens to only one arm, that itself is data (see the parallelism note below for why
even that needs a careful read), but do not silently reclassify the trial as "not really about
the pipeline" after the fact just because the finding is more interesting than the plan.

**Give every arm its own git worktree (`git worktree add`), never branch-switch a shared
working tree mid-trial.** Checking out one arm's branch to investigate it while another arm's
gate subagents are still dispatched against their own checked-out branch is how "which branch
am I on" silently goes stale — it produced two self-caught but real mistakes in pair 2
(experiment 002), including a build briefly landing on `main`. A worktree per arm makes branch
identity impossible to lose track of, at the cost of one extra `git worktree add` per arm.

**A nested gate dispatch (an arm's subagent dispatching its own gate subagents) needs a defined
timeout and fallback, not an open-ended wait.** Completions from a second level of dispatch can
surface at the top-level orchestrating session instead of the arm subagent that actually
spawned them, stalling the arm until someone manually relays the result back down — this hit
both arms in the experiment 003/004 pair, and cost one dispatched gate (pair 3's arm E's G8)
entirely, resolved only by redispatching fresh against the latest commit. If a nested dispatch
has not resolved through the relay path within a reasonable wait, redispatch it fresh rather
than continuing to wait — a relayed result is equivalent to a direct one (fresh context is
about who reviews, not how the report physically arrives), so redispatching costs a duplicate
run, not a validity problem.

**If an agent is running one or both arms, gate parallelism breaks wall-clock comparability.**
A human review team cannot run four reviewers in parallel for free; an agent dispatching four
gates as background subagents effectively can. That makes the with-pipeline arm's wall-clock
look better than the method this document was written for (a human running the checklist)
would actually cost. Record **gate-minutes summed** (the effort figure) alongside **wall-clock**
(the latency figure) — see `session-record.md` — and read wall-clock savings from an agent-run
trial as an upper bound on the method's real speed advantage, not a measurement of it. Token
cost is the closer analogue to human review-hours in this setting, despite not being what
either `tokens_in`/`tokens_out` in Study 2 was originally written to capture.

---

## The metrics

| Metric | Formula | Reading it |
|---|---|---|
| **Escape rate** | defects found after release ÷ all defects | The headline. Everything else is a means to lowering it |
| **Cost per finding** | (tokens + minutes) ÷ findings | Is the ceremony paying for itself? |
| **Shift-left ratio** | findings before Build ÷ all findings | Cheap findings vs expensive ones |
| **Rework ratio** | fix commits ÷ all commits, per area | Computable from history alone |
| **Tier accuracy** | reconciled == predicted, as a rate | Whether routing is even working |

**Escape rate is the only one that can falsify the whole design.** If it does not fall,
nothing else matters — not token savings, not gate yield, not how good the process feels.

---

## Reporting

Results go in `experiments/NNN-<name>/`, each with:

- `design.md` — what you pre-registered, written *before* collecting data
- `data.csv` — the raw records
- `result.md` — what happened, including the ways it might be wrong

**Publish negative results.** A kit whose own benchmark says "no measurable effect on a
sample of six" is more trustworthy than one that reports only wins — and if the effect really
is absent, you want to know before you have built a year of process on top of it.
