---
name: install
description: Install the gated-change kit into the current git repository as .pipeline/, then walk through the five setup questions. Use when the user wants to set up gated-change in a project.
---

# Install gated-change into this repository

You are installing the kit into the user's **current git repository**. The kit ships inside this
plugin at `${CLAUDE_PLUGIN_ROOT}/kit`. Installing copies it to `.pipeline/` in the project, which is
exactly what step 1 of the project README describes. Nothing is sent anywhere.

Work through these in order and stop at the first failure.

## 1. Check the preconditions

Run, from the project root:

```bash
git rev-parse --show-toplevel
test -e .pipeline && echo "EXISTS" || echo "absent"
```

- If this is not a git repository, stop and tell the user: the kit reads git history.
- If `.pipeline` already exists, stop. Tell the user to run `/gated-change:update` instead.

## 2. Say what will be written, then ask

This skill may be started from a plain request such as "install the pipeline kit". Whatever started it,
**do not copy or write anything until the user has said yes to this step.** Tell them plainly what the next
steps do, then wait:

- Copies the kit to `.pipeline/` (about 70 files).
- Creates `.pipeline/project/` from the templates and an empty `.pipeline/ledger.jsonl`.

Two later steps change files **outside** `.pipeline/`. Ask separately for each, and only run it on a yes:

- `bash .pipeline/tools/install-hook.sh` writes `.git/hooks/pre-push`.
- `bash .pipeline/tools/install-claude-hook.sh` merges a reminder hook into `.claude/settings.json`.

## 3. Copy the kit

```bash
cp -R "${CLAUDE_PLUGIN_ROOT}/kit" .pipeline
rm -f .pipeline/.built-by-build-plugin
find .pipeline -type f \( -name '*.sh' -o -name 'pre-push' -o -name '*.lock' \) | while read -r f; do tr -d '\r' < "$f" > "$f.lf" && cat "$f.lf" > "$f" && rm -f "$f.lf"; done
mkdir -p .pipeline/project && cp -R .pipeline/templates/project/. .pipeline/project/
touch .pipeline/ledger.jsonl
```

The `find` line strips carriage returns from the scripts. A plugin cached on a machine whose Git
converts line endings would otherwise hand bash scripts with CRLF, which fail with
`$'\r': command not found`. It changes nothing on a machine where they are already LF.

## 4. Answer the five questions

The shipped `.pipeline/project/surfaces.conf` describes a browser extension. **Until it describes the
user's project, every change routes T0 and no gate is ever required.** Ask the user these, then edit the
file with their answers (one line per answer, format `T4::(^|/)auth/::Authentication, silent when wrong`):

1. What here, if it broke, would fail **silently**? (trust surfaces, T4)
2. What platforms must every change work on? (targets)
3. What can a user do that they can never undo? (the T4 boundary)
4. Where do secrets and credentials live? (continuous security checks)
5. What accumulates without a documented limit? (scale ceilings)

`.pipeline/examples/surfaces/` has ready-made files for a web app, a REST API, a Chrome extension, a
library or CLI, and a data pipeline. Offer the closest one as a starting point.

## 5. Check it is on

```bash
bash .pipeline/tools/status.sh
```

Read the output to the user. Then, with their yes, run the two enforcement installers from step 2.

## 6. Commit the kit on its own

Suggest `git add .pipeline && git commit -m "Add gated-change"` **before** any real work, so `status.sh`
counts unrouted work from that commit. Do not commit for the user unless they ask.
