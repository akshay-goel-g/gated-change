# gated-change (Claude Code plugin)

A routed review pipeline for AI-assisted software work. This plugin installs the kit into a git
repository and gives Claude Code five skills to drive it.

The kit tiers each change from its **real diff** (T0 to T4), sends it through the review gates that
tier requires, and records every gate run in an append-only ledger that computes whether the
change is ready. It is a folder of markdown, a few bash scripts and one config file. It needs
only `bash` and `git`, and nothing leaves your machine.

## Skills

| Skill | What it does |
|---|---|
| `/gated-change:install` | Copies the kit to `.pipeline/` in the current repository and walks through the five setup questions |
| `/gated-change:status` | Says whether the pipeline is actually on, and what has landed without a gate run |
| `/gated-change:reconcile` | Recomputes a change's tier from the real diff and records it |
| `/gated-change:compliance` | Asks the ledger whether the mandated gates passed; prints the ledger report |
| `/gated-change:update` | Refreshes an installed kit from this plugin's copy, leaving your config and ledger alone |

## What it changes on your machine

The plugin itself only supplies files. Installing the kit does the following, and the install skill
asks before each step that is outside `.pipeline/`:

- **Copies the kit into your repository** as `.pipeline/` (about 70 files, under 1 MB).
- **Optionally writes `.git/hooks/pre-push`** (`install-hook.sh`): a pre-push check that blocks a
  push touching your trust-boundary files until a security review on record names the commit.
- **Optionally merges a reminder hook into `.claude/settings.json`** (`install-claude-hook.sh`): a
  Claude Code `PostToolUse` hook that reminds you to re-enter the pipeline after an edit to a
  trust-boundary file.
- **Regenerates `dashboard.html`** in your repository when the pre-push hook runs.

It makes no network requests and sends no data anywhere. Claude Code only: the hooks and skills are
Claude Code features.

## License

[PolyForm Shield License 1.0.0](LICENSE): source-available, free to use in your own projects
including commercial ones, not for building a competing product. See `NOTICE`.

Full documentation: [`kit/README.md`](kit/README.md).
