#!/usr/bin/env bash
#
# install-hook.sh — install the pre-push hook, and refuse to install one that
# would enforce nothing.
#
# The README used to say `cp templates/pre-push .git/hooks/pre-push`, and a raw
# cp succeeds against a template whose TRUST regex is still a placeholder. You
# then have a hook that runs on every push, matches nothing you own, and reports
# success by staying quiet. This checks the two things a cp cannot: that the
# rules resolve to something, and that they are yours.
#
# Usage:
#   bash .pipeline/tools/install-hook.sh [--force]
#
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$(dirname "$_HERE")}"
SRC="$KIT/templates/pre-push"
. "$KIT/tools/lib/data-root.sh"
data_root_require install-hook.sh
CONF="${PIPELINE_DATA:-$KIT}/project/surfaces.conf"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }
HOOKS="$(git rev-parse --git-path hooks)"
DEST="$HOOKS/pre-push"

[ -f "$SRC" ] || { echo "no template at $SRC" >&2; exit 2; }

if [ ! -f "$CONF" ]; then
  echo "No surfaces file at $CONF." >&2
  echo "  The hook derives its trust-boundary rules from that file's T4 rows." >&2
  exit 2
fi

# `grep -c` prints 0 and exits 1 when it matches nothing, so `|| echo 0` appends
# a second zero and the count becomes the two-line string "0\n0" — which then
# fails an integer test and falls through to installing a hook that guards
# nothing. The count is already correct; only the exit code needed absorbing.
RULES="$(grep -c '^T4::' "$CONF" 2>/dev/null)"
RULES="${RULES:-0}"
if [ "$RULES" -eq 0 ]; then
  echo "$CONF has no T4 rows, so the hook would have nothing to guard." >&2
  echo "  Answer questions 1, 3 and 4 first — that is what a T4 row is." >&2
  exit 2
fi

if grep -q 'EXAMPLE from a browser-extension project' "$CONF" 2>/dev/null; then
  echo "WARNING: $CONF is still the shipped example." >&2
  echo "  The hook will install and will guard a browser extension's trust boundaries," >&2
  echo "  which are not yours. Replace that file, then run this again." >&2
  echo >&2
fi

# Point the installed copy at wherever the kit actually is. A hook runs with
# the repo root as its cwd and inherits no environment from whoever pushes, so
# this has to be baked in at install time — and the installed hook is local
# config rather than a shipped artifact, so baking it in is the right place. An
# empty prefix means the kit IS the repository, which is how this repo runs the
# hook on itself.
PREFIX="$(git -C "$KIT" rev-parse --show-prefix 2>/dev/null)"
PREFIX="${PREFIX%/}"
[ -n "$PREFIX" ] || PREFIX="."
RENDERED="$(mktemp 2>/dev/null)" || { echo "cannot create a temp file" >&2; exit 2; }
trap 'rm -f "$RENDERED"' EXIT
# The data directory is baked in the same way when one is set now (data_root_require above has vetted it): the hook
# must enforce the surfaces file this installer just validated, not whatever the pusher's environment holds.
DATA_BAKE="${PIPELINE_DATA:-}"
sed -e "s|^PIPELINE_DIR=\"\${PIPELINE_DIR:-.pipeline}\"|PIPELINE_DIR=\"\${PIPELINE_DIR:-$PREFIX}\"|" \
    -e "s|^PIPELINE_DATA=\"\${PIPELINE_DATA:-}\"|PIPELINE_DATA=\"\${PIPELINE_DATA:-$DATA_BAKE}\"|" "$SRC" > "$RENDERED"

if [ -e "$DEST" ] && [ "$FORCE" -eq 0 ]; then
  # Compare what WOULD be installed, not the raw template: the installed copy has its PIPELINE_DIR rewritten to this
  # kit's prefix, so comparing the template reported "a different hook exists" for every kit not at .pipeline/.
  if cmp -s "$RENDERED" "$DEST"; then
    echo "Already installed and identical: $DEST"
    exit 0
  fi
  echo "A different pre-push hook already exists at $DEST." >&2
  echo "  Refusing to overwrite it — someone put it there on purpose. Merge the two," >&2
  echo "  or re-run with --force if you are sure." >&2
  exit 2
fi

mkdir -p "$HOOKS"

cat "$RENDERED" > "$DEST"

chmod +x "$DEST" 2>/dev/null || true

echo "Installed $DEST"
echo "  Guarding $RULES T4 rule(s) from $CONF:"
grep '^T4::' "$CONF" | sed -e 's/^T4:://' -e 's/\(.*\)::/  \1  → /' | sed 's/^/    /'
echo
echo "  It blocks a push touching those paths unless a report in"
echo "  ${PIPELINE_DATA:-.pipeline}/security-reports names a commit that contains every one of those changes."
