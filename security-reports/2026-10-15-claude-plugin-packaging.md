# Security review — Claude Code plugin packaging

Reviewed commit: `a638229dd38e82f06e36abf2e00012f285673224`
Range: `bfefd74..a638229dd38e82f06e36abf2e00012f285673224`
Date: 2026-10-15
Reviewer: a fresh-context subagent, blind to the handoff, intent log, learnings, ledger and earlier
security reports. Claude model: the session's own (sonnet 5.5). Confidence: fresh.

## What changed

A Claude Code plugin packaging of the kit: `.claude-plugin/marketplace.json`,
`plugin/.claude-plugin/plugin.json`, five skills under `plugin/skills/`, `plugin/README.md`,
`tools/build-plugin.sh`, and a generated copy `plugin/kit/` of the repository's `core/`, `tools/`,
`templates/`, `examples/` and top-level docs. README and `tests/run.sh` edits.

## Why the pre-push hook flagged 13 files

The 13 trust-boundary files the hook listed are all under `plugin/kit/`. They are copies, not new
logic. Verified by running `diff -r` of each source directory against its copy, and `diff` of each
top-level file: no differences. `plugin/kit/` holds only the nine kit entries plus the generated
marker file, and `tests/run.sh` has a test that fails if the copy drifts from the sources or carries
the ledger, tests, history, `project/` or `docs/`.

## Threat model walked

| Question | Result |
|---|---|
| Is `plugin/kit/` new logic or a duplicate? | Duplicate, byte-identical (command run) |
| Can `tools/build-plugin.sh` delete something it should not? | Only a directory that already carries its own marker file, or an empty one; an unmarked non-empty target is refused; empty, `.`, `/` and paths with spaces were reasoned through. Not executed by the reviewer |
| Can the skills be steered by repository content into running something unintended? | Tier and round were interpolated into a command with no stated format check. Fixed after the review (see below) |
| Do the skills write outside `.pipeline/` without asking? | No. The copy, the pre-push hook and the `.claude/settings.json` merge each wait for a yes; the install skill refuses if `.pipeline` exists |
| Undisclosed behaviour or network use | None found. No curl, wget or nc in `tools/` or `templates/pre-push`, no `eval` of repository content. The plugin README discloses the hook, the settings merge and dashboard regeneration |
| Manifests | Static JSON. The only URL is the repository URL. The marketplace source `./plugin` is inside the repository. Nothing is fetched or executed at install |

## Findings

- minor::tools/build-plugin.sh:35-40::the delete guard trusts any directory containing the marker file, so a user directory named kit under the argument that holds the marker plus other work would be wiped. Hard to hit by accident; not changed.
- minor::tools/build-plugin.sh:42::LICENSE and NOTICE are copied into whatever directory the argument names, overwriting files of those two names. Limited to two filenames; not changed.
- minor::plugin/skills/reconcile/SKILL.md:10-14::the predicted tier, or one read from a plan document, was interpolated into a shell command with no format check. Fixed: the skill now accepts only T0 to T4 and the compliance skill only T0 to T4 and a whole-number round.
- minor::plugin/skills/update/SKILL.md:25-27::it advised install-hook.sh with the force flag, which overwrites an existing pre-push hook, without saying to ask first. Fixed: it now says to ask and what is replaced.
- info::plugin/skills/install/SKILL.md::the skill gates the copy and each outside write on an explicit yes, and refuses if `.pipeline` exists.
- info::plugin/README.md::the described behaviour matches what the installers do.

## Outcome

Pass. The reviewed kit copy is byte-identical to the sources, the skills gate every write outside
`.pipeline/` on a yes, and nothing is fetched or sent. The two hardening findings on the skills were
fixed in a later commit that changes no trust-boundary file; the two on `tools/build-plugin.sh` are
accepted as low severity.

Not verified by execution: the build script's edge cases, and the installers beyond reading them.
