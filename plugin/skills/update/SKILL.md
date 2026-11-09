---
name: update
description: Update an installed .pipeline/ kit to the version shipped in this plugin, without touching the project's own config, ledger or reports. Use after the plugin itself has been updated.
---

# Update the installed kit

This refreshes `.pipeline/core`, `tools` and `templates` from a tagged release of the public
repository `https://github.com/akshay-goel-g/gated-change`, downloaded with `git clone` (needs network
access; the plugin itself holds no kit files). It leaves `project/`, `ledger.jsonl`, `security-reports/`,
`dashboard.html` and `.install-base` untouched.

Never run the real update without the user's yes. Download the release, then preview, from the project root:

```bash
KIT_SRC="$(mktemp -d)"
git -c core.autocrlf=false clone --quiet --depth 1 --branch "${GATED_CHANGE_REF:-v1.0.1}" "${GATED_CHANGE_REPO:-https://github.com/akshay-goel-g/gated-change}" "$KIT_SRC/kit" || { rm -rf "$KIT_SRC"; echo "could not download the kit" >&2; false; }
bash .pipeline/tools/update-kit.sh "$KIT_SRC/kit" --dry-run
```

Show the user what would change. **Local edits to `.pipeline/core/` are overwritten**, so say so if
the preview lists any file the user may have changed. Only after they confirm:

```bash
bash .pipeline/tools/update-kit.sh "$KIT_SRC/kit"
```

Remove the download when the update is done or declined: `rm -rf "$KIT_SRC"`.

Then strip carriage returns from the copied scripts, as the install skill does, so a download made
with Windows line endings does not break them:

```bash
find .pipeline -type f \( -name '*.sh' -o -name 'pre-push' -o -name '*.lock' -o -name 'models.conf' -o -path '*/templates/agents/*.md' \) | while read -r f; do tr -d '\r' < "$f" > "$f.lf" && cat "$f.lf" > "$f" && rm -f "$f.lf"; done
```

Then run `bash .pipeline/tools/status.sh` and report it. The `CHANGELOG.md` in the kit has an
"Action required" section for each release: read it to the user, because a hook you installed earlier
is a **copy** and may need re-installing. Re-installing overwrites `.git/hooks/pre-push`
(`bash .pipeline/tools/install-hook.sh --force`), so ask the user first and say what it replaces.

If `.pipeline/` does not exist, tell the user to run `/gated-change:install`.
