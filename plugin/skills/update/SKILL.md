---
name: update
description: Update an installed .pipeline/ kit to the version shipped in this plugin, without touching the project's own config, ledger or reports. Use after the plugin itself has been updated.
---

# Update the installed kit

This refreshes `.pipeline/core`, `tools` and `templates` from the copy inside this plugin
(`${CLAUDE_PLUGIN_ROOT}/kit`). It leaves `project/`, `ledger.jsonl`, `security-reports/`,
`dashboard.html` and `.install-base` untouched.

Never run the real update without the user's yes. Always preview first, from the project root:

```bash
bash .pipeline/tools/update-kit.sh "${CLAUDE_PLUGIN_ROOT}/kit" --dry-run
```

Show the user what would change. **Local edits to `.pipeline/core/` are overwritten**, so say so if
the preview lists any file the user may have changed. Only after they confirm:

```bash
bash .pipeline/tools/update-kit.sh "${CLAUDE_PLUGIN_ROOT}/kit"
```

Then run `bash .pipeline/tools/status.sh` and report it. The `CHANGELOG.md` in the kit has an
"Action required" section for each release: read it to the user, because a hook you installed earlier
is a **copy** and may need re-installing. Re-installing overwrites `.git/hooks/pre-push`
(`bash .pipeline/tools/install-hook.sh --force`), so ask the user first and say what it replaces.

If `.pipeline/` does not exist, tell the user to run `/gated-change:install`.
