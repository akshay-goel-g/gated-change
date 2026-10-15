# 05 — Enforcement

> Portable. Do not edit. Your paths go in `project/surfaces.conf`.

A document nobody loads is a document nobody follows. Whatever file your agent reads
automatically each session survives; everything else decays into decoration by session three.

Four enforcement points, weakest to strongest. **Use all four** — they fail in different
situations.

---

## 1. Session load (weak, necessary)

Your agent instructions file (`CLAUDE.md`, `AGENTS.md`, `.cursorrules` — whatever yours reads
automatically) points here, so the router is in context from the first message:

> Before any change, run Triage from `.pipeline/core/01-router.md`.
> Before any release, run `bash .pipeline/tools/reconcile.sh <predicted-tier>`.

Weak because it relies on the agent choosing to follow it. Necessary because it is the only
one that operates *before* work starts, when routing is still cheap.

---

## 2. PR checklist (medium)

Carries the reconciliation result where a reviewer can see it, so skipping is visible rather
than silent:

```markdown
- [ ] Predicted tier: ___
- [ ] Reconciled tier: ___   (if higher, gates re-run: ___)
- [ ] Gates run: ___
- [ ] Probe checkpoint 1 — what they did not say that I assumed: ___
      (logged with `ledger.sh assume`; any left `defaulted` at T3/T4 will refuse)
- [ ] Probe checkpoint 3 completed — one doubt named: ___
- [ ] Ledger updated
```

The probe line is deliberately phrased to require an answer, not a tick. A checkbox gets
ticked; a blank gets noticed.

---

## 3. Pre-push hook (strong)

Mechanical, and the only one that survives a tired Friday. It cannot judge quality — it can
refuse to let a trust-boundary diff leave the machine without evidence a review happened.

```bash
bash .pipeline/tools/install-hook.sh
```

The shape of it, with the parts that matter:

```sh
TRUST=$(grep '^T4::' .pipeline/project/surfaces.conf | ...)   # derived, not restated
if echo "$CHANGED" | grep -qE "$TRUST"; then
  SHA=$(git rev-parse HEAD)
  if ! grep -rqs "$SHA" .pipeline/security-reports/; then
    echo "BLOCKED: trust-boundary files changed, no security report names commit $SHA."
    exit 1
  fi
fi
```

**The rules are derived from `surfaces.conf`, not written into the hook.** The template used
to carry a placeholder regex to fill in, and `<your|trust|boundary|paths>` is a *valid*
extended regex — so a hook copied unedited installed cleanly, ran on every push, matched
nothing anyone owns, and reported success by staying silent. A hook that prints only on
failure cannot tell you it is asleep. Both the hook and its installer now refuse to run
rather than guard nothing, and the installer prints the rules it is guarding so the answer
to "is this working" is visible at install time rather than inferred from silence.

**The check is commit-scoped on purpose.** An earlier version of this hook accepted any report
from the last seven days — which a report about a completely different change satisfies
trivially. It proved a file existed, not that this diff was reviewed. **A time window is not
evidence; a sha is.**

**Note the escape hatch.** A hook with no override gets disabled entirely within a month; a
hook whose override is *logged* keeps its teeth. `--no-verify` is allowed and expected — what
is not allowed is using it without a ledger entry saying why.

---

## 4. R0c re-entry hook (mechanical, Claude Code only)

Session load (§1) asks the agent to *remember* Triage exists. That covers the first change in
a session. It does not cover the second — the reactive edit made mid-fix, in response to a
gate finding, that never feels like "a change" (`01-router.md`'s R0c). This makes that
re-entry mechanical instead of memory-dependent, the same trade §3 makes for the push itself.

```bash
bash .pipeline/tools/install-claude-hook.sh
```

A Claude Code `PostToolUse` hook, fired after every `Edit`/`Write`/`MultiEdit`. It reads the
same T3/T4 rows `surfaces.conf` already answers — no separate rule list to keep in sync with
the pre-push hook's. When the edited file matches one, it prints a reminder to re-enter R0c
and exits non-zero; Claude Code shows that back to the agent as something to act on. It cannot
block what already happened — a `PostToolUse` hook fires after the edit lands — only refuse to
let it pass in silence, the same "cannot judge quality, can refuse silence" shape as §3.

Installs by merging into `.claude/settings.json`, never overwriting it — the file may already
hold hooks or permissions this kit knows nothing about. Idempotent: running it again once
installed reports that and changes nothing.

---

## 5. The exception audit (the part everyone forgets)

**A logged bypass that nobody reads is not an audit trail, it is a file.** The override above
only constrains behaviour if someone looks at it.

```bash
grep '"outcome":"skipped"' .pipeline/ledger.jsonl
```

An owner and a cadence for this live in `project/govern.md`. One question per row: *was this a
real emergency, or is a gate being routed around?*

**Three skips of the same gate in a month is not an emergency pattern.** It is a gate that does
not fit the work, and the correct response is to fix or retire it — not to keep bypassing it
and keep logging that you did.

---

## What to enforce, and what to leave to judgment

Mechanise anything with a **binary, checkable answer**: did a report exist, did permissions
grow, is there a secret in the diff, did the tier change. Leave to judgment anything
requiring taste: is this simple, does it belong, is it worth building.

Trying to mechanise judgment produces rules people route around. Failing to mechanise the
binary checks produces rules people simply forget.
