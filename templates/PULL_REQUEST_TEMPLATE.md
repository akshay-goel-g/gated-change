<!--
  Copy to .github/PULL_REQUEST_TEMPLATE.md (or your host's equivalent).

  The blanks are deliberate. A checkbox gets ticked without reading; a blank
  gets noticed when it is empty.
-->

## What and why

<!-- One or two sentences. If this needs three paragraphs, it is probably two changes. -->

## Routing

- **Predicted tier (R0a):** `T_`
- **Reconciled tier (R0b):** `T_`  ← `bash tools/reconcile.sh T_`
- If reconciled is higher, **gates re-run:** ___

## Gates

<!-- Delete the ones the router did not select. Do not leave them unchecked and
     ambiguous — nobody can tell later whether a gate was skipped or forgotten. -->

- [ ] Intent — acceptance criteria have evidence
- [ ] Scout
- [ ] Craft
- [ ] Ripple — registry entries triggered: ___
- [ ] Proof — every Axis D target has evidence
- [ ] Peer *(fresh context)*
- [ ] Threat *(fresh context)* — report names this commit sha
- [ ] Dogfood *(fresh context)*

## Probe

**What they did not say that I assumed:** ___

<!-- Checkpoint 1. This is where divergence enters, and it enters silently: an
     underspecified request does not stop an agent, it gets a plausible value and
     every gate below then verifies that invention. Log each one —
     `bash tools/ledger.sh assume --change <name> --assumed '<what>' --resolution asked|verified|defaulted`
     — and expect `compliance` to refuse any still `defaulted` at T3/T4.
     "Nothing was assumed" is available only if the request was complete. -->

**One doubt, named:** ___

<!-- "None" is not an available answer. If you cannot find one, you did not look. -->

## Ledger

- [ ] Runs recorded — `bash tools/ledger.sh add --change <name> --gate <G_> ...`

## Assets

- [ ] No unreplaced placeholder ships (icons, copy, sounds, screenshots)

## Rollback

**If this is wrong in production, what undoes it?** ___
