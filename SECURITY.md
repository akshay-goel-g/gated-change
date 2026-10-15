# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not as a public issue.

Use GitHub's private vulnerability reporting: on the repository page choose **Security**, then
**Report a vulnerability**. That opens a private advisory only the maintainer can see.

Include what you found, how to reproduce it (a minimal repository or command sequence is ideal),
and which version you tested (`VERSION`, or the `kit` field in `.pipeline/ledger.jsonl`).

This is a one-person project. Expect an acknowledgement, not a service level. Reports are looked
at as time allows, and a fix is released with a note under "Fixed" in `CHANGELOG.md`.

## What counts

The kit is a set of bash scripts and markdown that run in your repository, plus the Claude Code
plugin that installs them. These are in scope:

- A way for repository content (a ledger line, a `surfaces.conf`, a commit message, a file name)
  to make a tool run something it should not, or write outside the project.
- A guard that fails open: the pre-push hook, `reconcile.sh`, `status.sh` or `compliance`
  reporting "ready" when the evidence says otherwise.
- The installers (`install-hook.sh`, `install-claude-hook.sh`, the plugin's install skill) changing
  files they did not say they would.
- Anything that sends data off the machine. The kit makes no network requests; a report that it
  does is a high-priority finding.

## What does not

- The kit being **a process, not a scanner**: it does not find vulnerabilities in your code, and
  it records that a review was run, not that the review was right.
- A review gate the author chose to override. Overrides are recorded in the ledger on purpose.
- Behaviour documented under "Known limits" in the README and in `project/risks.md`.

## Supported versions

Only the latest release on the default branch is supported.
