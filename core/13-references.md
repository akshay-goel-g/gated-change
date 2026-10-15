# 13 — Reference documents

> Portable. Do not edit. Your document index lives in `project/references.md`.

Someone hands you a spec, an API doc, a style guide, a competitor's manual. What should the
pipeline do with it?

---

## The default: read once, extract, discard the dependency

**A reference document's value to the pipeline is not the document. It is the constraints it
imposes.** Retrieving chunks of it at review time is the wrong shape — the document gets read
once, and what matters becomes a rule that fires automatically without anyone remembering the
document exists.

This is the same routing question as `11-evolution.md`, applied to a document instead of a
directive:

| The document says | Extract to | Then fires at |
|---|---|---|
| "Changing X requires also updating Y" | `project/registry.md` | Ripple, automatically |
| "This endpoint is rate-limited / auth-gated" | `project/surfaces.conf` | The router, as a tier bump |
| "Empty list returns 204, not 200" | edge decision table in `design.md` | Ripple, then a test in Proof |
| "Must support these platforms/versions" | Axis D targets | Proof, as required evidence |
| "Never log the token field" | `personas.md` (Threat), or a grep | Continuous checks, mechanically |
| Naming, tone, layout conventions | `personas.md` (Craft) | Craft |
| A hard limit or quota | `project/ceilings.md` | Ripple |
| A known unavoidable constraint | `project/risks.md` | Risk review |

**Extraction is the work.** A document sitting in a folder changes nothing; a registry entry
fires at the exact moment it matters, to someone who never read the document.

## Reference documents are grounding anchors

`12-grounding.md` says check the lockfile, not general knowledge. Same principle here: **if
someone gave you the spec, a claim about that system is `VERIFIED` from the spec rather than
`ASSUMED` from training data.**

That is a real upgrade in claim quality, and it comes from *reading* the document — not from
indexing it. Cite the document and section the same way you would cite `file:line`.

## Do not build retrieval by default

Vector search over provided documents is tempting and usually wrong at this scale. Four
specific costs:

**It returns plausible chunks, not complete ones.** The value of a reference is often a
constraint appearing exactly once. If the query does not match its phrasing, you get an
authoritative-looking snippet missing the caveat two paragraphs down — which is precisely the
fabricated-API and phantom-citation surface `12-grounding.md` exists to shrink.

**It breaks the evidence rule.** Chunks blur provenance. You can cite "the docs" but not the
line, which is the degradation that rule was written to prevent.

**It goes stale silently.** An index built once drifts from its source. Nobody re-indexes,
there is no signal, and the result is a confident wrong answer with no failure mode — the
exact defect shape this whole pipeline is organised against.

**It is infrastructure.** Embeddings, a store, a re-index trigger, in a system whose adoption
argument is thirty minutes.

## When retrieval *is* justified

Reach for it when **all** of these hold — and state them, do not assume them:

- The corpus genuinely does not fit in context (hundreds of pages; a regulatory standard; a
  large legacy documentation set)
- You do not know in advance which document is relevant
- You cannot extract from it — it is external and updates frequently
- You must cite the **source document itself**, not a rule derived from it (compliance)

Under that bar, direct read plus extraction wins on precision, provenance, and setup cost.

**If you do build it**, two non-negotiables so the rest of the pipeline still works:

1. **Every chunk carries document + section**, so a retrieved claim can still be cited
   precisely and checked by hand.
2. **Staleness is detectable** — index the source's hash or modified date and refuse to answer
   from an index older than its document. An index with no staleness signal is worse than no
   index, because it fails silently and confidently.

---

## Recording what arrived

`project/references.md` indexes every document provided: what it is, what was extracted, and
when. It exists to answer one question that comes up constantly and has no other home:

> **"Where did this constraint come from?"**

A registry entry whose *because* is "the vendor's API doc, §4.2, provided 2026-08" can be
re-checked when the vendor changes it. One whose because is "someone said so" cannot.
