# Session record — Rule ID Range Overflow (whitelist twin)

> Arm A of experiments/001-first-run. Sample build for the benchmark — not
> intended for release. Built on `sampleapp` branch `experiment/arm-a-with-pipeline`,
> commit `c696324ebcf7b902945e01cfbc4ae85bcfb6f562`, never merged to main.

| | |
|---|---|
| **Date** | 2026-08-10 |
| **Change** | Defensively cap whitelist rule build at 1000 entries (`buildWhitelistAllowRules`) |
| **Arm** | pipeline (with-pipeline) |
| **Predicted tier** | T4 |
| **Reconciled tier** | T4 (match — `reconcile.sh`, logged as a `route` record) |

## Cost

| Metric | Value |
|---|---|
| Tokens in / out | Not directly instrumentable from inside the session — no tool exposes per-session token counts to the agent itself. Proxy: 6 gate subagents reported `subagent_tokens` in their completion metadata, totalling **~433,000 tokens** across G1/G4/G5/G6/G7/G8 combined (G4 85,417 + G6 90,318 + G7 81,480 + G8 85,512, plus G1/G5 done inline, not separately metered). This is a lower bound — excludes the primary session's own token use for Triage, Build, doc reads, and orchestration. |
| Wall-clock minutes (start → gates complete) | **~17 min** of primary-session wall-clock (14:08–14:25). The 4 fresh-context gates (G4/G6/G7/G8) ran as **parallel background subagents** — their own wall-clock (71s–170s each, see below) mostly overlapped with Feature B's build rather than serializing onto Feature A's critical path. |
| — per-gate subagent wall-clock | G4: 170s · G6: 85s · G7: 82s · G8: 72s (parallel, not additive) |
| Interventions (times corrected course) | **1** — the user corrected the initial approach after Triage/requirements were presented: I had planned to treat this as a real production fix requiring the user to choose between the literal (redundant) backlog scope and my rescoped fix; the user redirected to "sample test, not integrating, just build it" — after which I proceeded without further pauses. |
| Gates run | 6 of 8 (G1 Intent, G4 Ripple, G5 Proof, G6 Peer, G7 Threat, G8 Dogfood). G2 Scout and G3 Craft correctly skipped per the gate matrix (not net-new capability; no UI surface touched). |

## Findings

| Gate | Findings | Before or after Build? | Challenged your premise? |
|---|---|---|---|
| G1 Intent | 1 — the literal backlog description ("blocklist overflows past 1000") does not reproduce; blocklist is already double-defended (write-time cap + `buildPermanentBlockRules`'s `.slice(0,1000)`). Rescoped to the whitelist twin, which this repo's own `CLAUDE.md` already flags as "reported but NOT fixed." | **Before** Build | **Yes** — this is the headline result: G1a caught a stale premise before any code was written, which a literal build would have missed entirely (a no-op `.slice` on the already-capped blocklist). |
| G4 Ripple | 1 — informational disagreement: would have added a `console.warn` on truncation, matching the file's existing silent-drop-avoidance pattern elsewhere in the same file. Not a blocker. | After Build | Yes |
| G5 Proof | 0 (the deliverable IS the verification: confirmed the new test fails against pre-fix code and passes post-fix, plus full unit suite 2784/2784 green) | After Build | No |
| G6 Peer | 1 — same disclosed minor as G4 (slice-before-security-filter ordering could drop valid entries in an already-corrupted-storage scenario; inherited unchanged from the blocklist twin, not a new defect) | After Build | Yes |
| G7 Threat (hard gate) | 0 — tried id-collision, `isSpecificAllowTarget` bypass via truncation order, adversarial-ordering privilege escalation; none reachable. Fail-closed by construction. | After Build | No |
| G8 Dogfood | 1 — informational: if storage is ever corrupted past 1000 by a non-UI path, the rule-builder now silently drops the tail with no user-facing signal (pre-existing gap, not introduced by this diff, but not closed by it either) | After Build | No |

**Shift-left ratio:** findings before Build ÷ all findings = **1/4 (25%)** — counting only substantive findings (G1's rescope); if every gate's "1 finding" row is counted at face value including informational disagreements, 1/6 (17%). The single most valuable finding (the stale premise) was the one found before Build.

## Outcome (fill in at +14 days)

| | |
|---|---|
| Fix commits to these files within 14 days | Not yet known — sample branch, not merged, not deployed |
| Defects reported by users | N/A — not shipped |
| **Escapes** (found after release) | N/A — this arm's escape-rate data is structurally unavailable: the branch is never released. See `result.md` for why this experiment reports cost + shift-left only, not escape rate. |

## Notes

- The most valuable thing this arm produced wasn't the code — it was G1a Intent catching, before Build, that the literal backlog item as written no longer reproduces. A pipeline-free build of the literal ask would have added a redundant no-op to the blocklist path and reported "fixed" without changing behavior. That is exactly the shift-left claim the pipeline makes, and it held up on this one real trial.
- Nothing tempted skipping a gate. G7 (hard gate) took the least apparent "effort" (0 findings) but that's the intended shape for a well-defended change — a clean Threat pass on a T4 change is evidence, not proof of low value; the gate's own methodology (7.3 promotion/retirement) says a security gate finding nothing across many runs is a sign it's working, not idle, and one run either way says nothing.
- Running G4/G6/G7/G8 as **parallel background subagents** (rather than sequential fresh-context sessions) is what kept this arm's wall-clock close to Feature B's despite doing 6x the review work — this is a genuine implementation choice available to an agentic pipeline that a human-run version of this same process could not exercise. Worth flagging in `result.md`: the cost numbers here are optimistic relative to what a pipeline run by a human review team would cost, because subagent parallelism is free in a way human reviewer time is not.
- Token cost is a real, non-trivial multiplier (~433K tokens just for 4 of 6 gates) that a human-cost model would not show at all. This is the single most important number for "is this worth it" in an agent-run version of the pipeline, and the session-record template (designed for a human/token-metered IDE session) doesn't have a clean home for "per-subagent token cost" — recorded here as a proxy since the primary session's own token count isn't exposed to the agent.
