# Scale ceilings

> Yours. Every resource that accumulates has a limit. The undocumented ones are the
> ones you discover in production.

**A ceiling not enforced in code is a ceiling that will be exceeded.** Document it,
assert it, and test the boundary — the interesting bug is always at `limit` and
`limit + 1`.

| Resource | Ceiling | Enforced where | Tested where |
|---|---|---|---|
| | | | |
| | | | |

## Prompts for filling this in

- What collection grows without bound? Lists, queues, logs, caches, history
- What platform limit applies that you did not choose? API quotas, rule counts,
  storage size, request rates
- What breaks at 10× your current usage? At 100×?
- What has no pagination?
- What retries without a backlog cap?

## Unknown ceilings

A limit you have not measured is still a limit. List the ones you suspect but have
not confirmed — an acknowledged unknown gets tested eventually; an unexamined one
gets discovered by a user.

- …
