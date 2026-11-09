# Session handoff

<!--
  Where we are RIGHT NOW. Rewritten in place every session — this file is a
  status, not an archive.

  HARD CAP: ~100 lines. Over the cap, every line is one of two things:
    · done          → delete it
    · a decision    → move it to INTENT-LOG.md
  Nothing else. A handoff that grows past a few screens stops being read, and an
  unread handoff is worse than none — the next session trusts it and skips ahead.

  Update at the END of every session, not the start.
-->

**Last updated:** <date> · **Branch:** <branch>

## Where we are

<!-- Two or three sentences. What state is the work in, right now? -->

## Uncommitted

<!-- File count, diff stats, key paths. Delete this section when the tree is clean. -->

## Next, in order

1.
2.
3.

<!-- Ordered, not a bag. If everything is priority one, nothing is. -->

## Blocked on

<!-- Only things genuinely waiting on someone else or something external.
     A decision waiting on the user goes here with the options stated, so it can
     be answered in one line rather than re-derived. -->

## Known concerns

<!-- Things future-you should be suspicious of. Not a bug list — a list of
     "this looked fine but I am not sure". Delete each one when it is resolved
     or confirmed. -->

---

<!--
  Not in this file:
    · what was asked and why        → INTENT-LOG.md (append-only)
    · what broke and what we learnt → LEARNINGS.md  (append-only)
    · what the gates found          → ledger.jsonl

  Those three are append-only; this one is rewritten. Mixing an immutable record
  into a mutable document loses the record — that is the whole reason for four
  files instead of one.
-->
