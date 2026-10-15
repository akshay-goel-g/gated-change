# 03 — The Coupling Registry

> Portable. Do not edit. **Your** couplings go in `project/registry.md`.

An entry is always the same shape:

> **If you touch X, you must also check Y — because Z happened.**

The **because** is the whole value. "They are related" is not a reason and will be skimmed
past; "the allow rule is evaluated above the block rule" is a reason and will be checked.

---

## Universal couplings

True in nearly every codebase. Adopt these on day one; they cost nothing.

| If you touch… | You must also check… | Because |
|---|---|---|
| Auth, roles, or session logic | Existing sessions are invalidated | Users keep elevated access after a permission downgrade |
| A persisted schema | Backfill for existing rows **and** a rollback path | Forward-only migrations strand old records |
| A new config key or env var | Every deploy target and the local default | Works locally, missing in production at 3am |
| Any day or date bucketing | Local time vs UTC at the boundary | Day logic silently shifts for users in other timezones |
| An id, priority, or port space | The allocation range of every other producer | Two systems allocate the same value; the later write wins |
| A shared namespace or load order | Every other module sharing that scope | A redeclaration takes down the whole page or module |
| A cache key | Every reader's expected shape, and invalidation | Readers receive a shape they were never written for |
| An external API contract | Every consumer and version negotiation | Silent break for older clients |
| A default value | Records that relied on the previous default | Changing a default rewrites history for absent fields |
| A quota or rate limit | Where the ledger is **written**, not only read | Parallel requests all pass a read-time check and all proceed |
| Anything awaited during init | What fails to initialize if it throws | One throw in startup silently disables everything after it |
| A feature flag | The off path, and the removal plan | Dead flags become permanent forks |
| A behavior or limit a backlog item asks you to add | Whether it was already built and deliberately removed — `git log -S<the value or key name>` | A reverted decision is invisible to a diff-based reviewer; re-adding it can re-break whatever the removal fixed, and a pinned test asserting the old behavior will tell you *that* it conflicts but not *why* |

---

## Mining your own

A registry written from memory stays empty. Your git history already holds your incidents:
every hotfix, revert, and follow-up fix is a coupling failure with a paper trail.

```bash
bash tools/mine-registry.sh
```

**What it does:** finds fix-shaped commits, drops the ones touching too many files (a refactor
pairs everything with everything), removes **hub files** that appear in most commits and are
therefore coupled to nothing, then ranks the surviving file pairs by how often they were
fixed together. Each pair comes with the commits that produced it.

**What it cannot do:** tell you *why*. That is your job, and it is the part that matters. Open
the commits, read what broke, and write the because. **Delete anything you cannot explain** —
one unexplained rule teaches everyone to skim, and a skimmed registry is worse than none.

### Reading the output honestly

Co-occurrence is correlation. Two files fixed together may be coupled, or may both belong to
the feature that needed the most work. The commit list exists so you can tell those apart. If
you find yourself keeping a pair because the number is high rather than because you remember
why — delete it.

### No history yet

Then you start with the universal table above, and the registry grows from your first real
incident. **Do not invent couplings you have not experienced.** A brand-new project has no
scars; that is a state to grow out of, not a gap to fill with speculation.

---

## Adding an entry by hand

Every escaped defect should end here. The trigger is Harvest (`07-failure.md` for the loop
mechanics), and the test for whether an entry belongs is simple:

1. Could this have been caught by asking one question before the change?
2. Is that question **non-obvious** to someone competent reading the code?
3. Can you name the incident that proves it?

Three yeses, it is an entry. Fewer, it is a code comment.
