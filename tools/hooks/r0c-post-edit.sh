#!/usr/bin/env bash
#
# r0c-post-edit.sh — makes core/01-router.md's R0c mechanical instead of
# memory-dependent.
#
# R0c's rule: any edit to a T3/T4 surface, made after Triage (R0a) has
# already run for the session, re-enters the pipeline at R0a for that edit —
# it does not feel like a change, so nothing about it prompts a human or an
# agent to remember routing exists. This is a Claude Code PostToolUse hook
# that fires after every Edit/Write/MultiEdit and reminds, mechanically,
# instead of relying on that memory. It is the same "cannot judge quality,
# can refuse silence" shape as templates/pre-push — it cannot tell whether
# the edit actually needed a new round, only that the surface it touched is
# one where a wrong answer is silent (surfaces.conf's own Q1).
#
# It cannot re-run reconcile.sh for you: a PostToolUse hook sees one tool
# call at a time, not "is this the same logical change as the last five
# edits" — mechanically re-running on every keystroke-sized edit would just
# teach everyone to ignore the reminder, the same failure mode
# core/05-enforcement.md already names for over-eager checks.
#
# Wired in via tools/install-claude-hook.sh, which writes the matching
# .claude/settings.json PostToolUse entry — see that script for the exact
# shape.
#
# Exit 2 + a message on stderr is PostToolUse's "nudge, don't block" idiom:
# the edit already landed (a PostToolUse hook cannot undo it), but Claude
# Code shows the message back to the agent as something to act on before
# calling the edit finished. Exit 0 otherwise — MultiEdit is included
# because it is an Edit in every way that matters here (same trust-boundary
# question, same T3/T4 surfaces), and excluding it would leave exactly the
# memory-dependent gap this hook exists to close.
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$_HERE/../.." && pwd)"
SURFACES="$KIT/project/surfaces.conf"

INPUT="$(cat)"

# Same idiom every JSON-reading tool in this kit already uses (tools/dashboard.sh,
# tools/ledger.sh): sed extraction of one known top-level key, not a parser. Safe
# here because tool_input.file_path is always the FIRST "file_path" key in an
# Edit/Write/MultiEdit payload, and Claude Code never puts a literal `"` in it
# (it is a filesystem path, not free text).
TOOL_NAME="$(printf '%s' "$INPUT" | sed -n 's/.*"tool_name":"\([^"]*\)".*/\1/p')"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(printf '%s' "$INPUT" | sed -n 's/.*"file_path":"\([^"]*\)".*/\1/p')"
[ -n "$FILE_PATH" ] || exit 0

# `file_path` is a JSON string VALUE, and on Windows it arrives both
# backslash-separated and backslash-escaped:
#   "file_path":"D:\\work\\gated-change\\tools\\ledger.sh"
# Every rule in surfaces.conf is `/`-anchored (`(^|/)tools/...`), because every
# OTHER consumer of those rules is fed paths by git, which always emits `/`.
# This is the only consumer taking an OS path from an external payload, and
# without normalising it nothing ever matched: the hook exited 0 on every edit
# and the R0c enforcement point was silently dead on Git Bash for Windows —
# the platform project/surfaces.conf names as this kit's primary TARGET, and
# the platform it was written on. Found by a fresh-context review, not by the
# suite, which only ever built `/`-separated fixtures.
#
# Unescape first, then translate separators. Order matters: doing it the other
# way turns the `\\` pair into `//` and leaves a stray escape behind. A literal
# backslash inside a filename is vanishingly rare on the platform that uses it
# as a separator, and treating it as one is the safer failure here — a false
# reminder costs a sentence, a missed one costs the gate.
FILE_PATH="$(printf '%s' "$FILE_PATH" | sed -e 's/\\\\/\\/g' -e 's/\\/\//g')"

# No surfaces file, nothing to check against — fail open, not closed. The
# pre-push hook fails CLOSED on this same condition because it is the last
# mechanical check before code leaves the machine; this one is a reminder
# mid-session, and a hook that blocks every edit in a repo that has not
# answered surfaces.conf's questions yet teaches people to disable it.
[ -f "$SURFACES" ] || exit 0

# One row at a time, first match wins — not a combined alternation — so the
# message below can name which specific row fired and why, the same reason
# a `blocking` finding with no location is refused in core/04-ledger.md: a
# reminder that cannot say what it is about trains people to skim past it.
MATCH_TIER=""
MATCH_LABEL=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  tier="${row%%::*}"
  rest="${row#*::}"
  rule="${rest%%::*}"
  label="${rest#*::}"
  if printf '%s' "$FILE_PATH" | grep -qE "$rule" 2>/dev/null; then
    MATCH_TIER="$tier"
    MATCH_LABEL="$label"
    break
  fi
done < <(grep -E '^(T3|T4)::' "$SURFACES" 2>/dev/null)

[ -n "$MATCH_TIER" ] || exit 0

cat >&2 <<EOF

R0c — mid-session re-entry (core/01-router.md)

  $FILE_PATH just changed and matches a $MATCH_TIER row in surfaces.conf:
    "$MATCH_LABEL"

  This edit did not go through Triage on its own — it happened while
  attention was on something else, which is exactly what R0c exists for.
  Before treating it as done, re-enter the pipeline for this edit:
    bash $KIT/tools/reconcile.sh <predicted-tier> --log
  (a new --round, not a new change) and run whatever gates the reconciled
  tier mandates.

EOF
exit 2
