# 12 — Grounding: guardrails against hallucination

> Portable. Do not edit. Your recurring false-claim patterns go in `project/grounding.md`.

`02-gates.md`'s evidence rule says every claim cites `file:line`. `10-probe.md` says every
confidence needs a falsifier. Neither stops the moment *before* those — where a claim gets
asserted because it sounds plausible, not because anything was checked. This file is that
moment.

**A hallucination is not a lie.** The agent is not aware it is doing it, which is exactly
why a rule that only says "don't lie" does nothing. The failure is confident output that was
never checked against anything real — and it looks identical to correct output until someone
checks.

---

## The taxonomy

Coding agents fail in the same handful of shapes, repeatedly. Naming them is most of the
defense, because a named pattern is one you can grep your own output for.

| Pattern | What it looks like | Why it happens |
|---|---|---|
| **Fabricated API** | Calling a function, flag, or config key that does not exist in this codebase or this library version | The name is plausible — it exists in a *similar* library, or an *earlier* version |
| **Phantom citation** | `file:line` that does not point at what is claimed, or a file that was never opened | The citation format is produced without the lookup that should back it |
| **Unverified execution** | "Tests pass" / "this fixes it" without having run anything | Narrating the expected outcome is easier than producing it |
| **Cross-codebase bleed** | "In [framework] this works like X" applied to a codebase that does something else | Training data from many codebases collapses into one confident default |
| **Version drift** | Assuming current API shape from general knowledge instead of the installed version | The lockfile was never checked |
| **Invented precision** | "This improves performance by 40%" with no measurement behind it | A specific number reads as more credible than a vague one, so specificity substitutes for evidence |
| **Stale memory as fact** | Restating something from an earlier session or a summary as current, unverified | Memory is a snapshot; the code may have moved |
| **Silent scope narrowing** | Claiming "done" while quietly having handled only the common case | The happy path was verified; the rest was assumed to follow |
| **Authority by adjective** | "Obviously," "as expected," "standard practice," "clearly" | These words replace a citation instead of introducing one |

---

## The pre-claim checklist

Before any factual statement about the codebase, a library, or a result — run this. It is
fast because most claims clear it instantly; it exists for the ones that do not.

1. **Did I open this, or do I remember something like it?** If memory, that is a hypothesis,
   not a fact, until checked.
2. **Can I name the tool call that produced this?** A `Read`, a `Grep`, a command that ran.
   No tool call, no claim.
3. **Am I citing the version actually in this repo?** Check the lockfile or manifest, not
   general knowledge of the package.
4. **If I claim something ran, did it actually run, in this session, and did I read the
   output?** Narrating an expected result is not running it.
5. **Am I stating a number?** Numbers need a measurement behind them or they do not appear.
   "Faster" without a benchmark is honest; "40% faster" without one is fabrication with extra
   steps.
6. **Would this claim survive someone re-running the exact check I just described?** If you
   are not sure, that is the answer.

---

## Three-tier labeling

Every non-trivial claim carries one of three labels, stated or implied by how it is phrased.
This is not bureaucracy — it is the difference between a claim someone can act on and one
they cannot.

| Label | Means | Example |
|---|---|---|
| **VERIFIED** | Backed by a tool call in this session | "`bypass-logic.js:142` reads the quota before writing it — confirmed by reading the file just now" |
| **ASSUMED** | A reasonable default, not checked in this session | "This likely follows the same pattern as the sibling module — not yet confirmed" |
| **UNVERIFIED** | Stated but not checked, and the gap matters | "I have not run this test suite; I do not know if it passes" |

**The failure is not having ASSUMED or UNVERIFIED claims — it is not labeling them.** A
codebase has too much surface to verify everything before speaking. The defect is presenting
an assumption with the confidence of a verification.

---

## Mechanical checks

Some of this is cheap enough to automate rather than rely on discipline for.

| Check | Catches |
|---|---|
| Grep for the symbol before claiming it exists | Fabricated API, wrong function name |
| Diff the citation against the actual file content | Phantom citation — a `file:line` that does not say what was claimed |
| Require a captured command output before "tests pass" | Unverified execution |
| Check the lockfile/manifest before citing library behavior | Version drift |
| Grep own output for `\d+%|\d+x faster|\d+ms` with no adjacent command output | Invented precision |
| Grep own output for "obviously\|clearly\|as expected\|standard practice\|typically" | Authority by adjective — nearly always marks an unchecked claim |

That last one is the highest-value single check in this file. These words almost never
appear next to a citation, because they exist specifically to stand in for one.

---

## Where this runs

| Stage | What it does |
|---|---|
| **Peer, Threat** | Apply the pre-claim checklist to every finding they report, not just the code under review — a review is also a set of claims |
| **Proof** | "Tests pass" requires the actual run output in the same turn, not a restatement |
| **Probe checkpoint 3** | "What am I least confident about?" is where UNVERIFIED claims should surface if they have not already |
| **Ledger** | `grounding_violations: N` — a claim caught unlabeled after the fact. Not shameful; the field exists so patterns become visible over time |

---

## Self-check, before sending any substantial response

- [ ] Every file path or line number was opened in this session, not recalled
- [ ] Every "this works" or "this passes" is backed by output in this same turn
- [ ] Every number has a measurement behind it, or is phrased as an estimate
- [ ] No claim rests on "obviously," "clearly," "as expected," or "standard practice" — if one
      does, either replace it with a citation or replace the confidence with a label
- [ ] Anything ASSUMED or UNVERIFIED is marked as such, not phrased as settled

---

## Why this is not the same file as Probe

Probe asks "am I confident, and what would prove me wrong" — it operates on **conclusions**,
after reasoning has happened. Grounding operates earlier, on **individual factual claims**,
before they are assembled into a conclusion at all. A change can pass every probe checkpoint
and still be built on three ungrounded assumptions that never got flagged, because probe was
never pointed at them specifically. This file is what points it there.
