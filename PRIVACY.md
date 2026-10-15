# Privacy

gated-change does not collect, transmit or store any data about you or your projects anywhere
except on your own machine.

- **No network requests.** None of the scripts, hooks, templates or skills in the kit contact a
  server. There is no telemetry, no analytics, no update check and no account.
- **Everything stays in your repository.** The ledger, the dashboard, the security reports and
  your project configuration are plain files under `.pipeline/` in the repository you installed
  the kit into. You own them and can delete them at any time.
- **What the installers write.** `install-hook.sh` writes `.git/hooks/pre-push`, and
  `install-claude-hook.sh` merges a reminder hook into `.claude/settings.json`. Both say so when
  they run, and the plugin's install skill asks before running either.
- **The model you use.** The review gates are run by whichever AI agent or person you point at
  them. What that agent receives is governed by that provider's terms and your own settings, not
  by this kit.

Questions or concerns: open an issue at
<https://github.com/akshay-goel-g/gated-change/issues>.
