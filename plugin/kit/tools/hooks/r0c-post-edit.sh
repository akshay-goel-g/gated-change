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
SURFACES="${PIPELINE_DATA:-$KIT}/project/surfaces.conf"

INPUT="$(cat)"

# Same idiom every JSON-reading tool in this kit already uses (tools/dashboard.sh,
# tools/ledger.sh): sed extraction of one known top-level key, not a parser. Safe
# here because an Edit/Write/MultiEdit payload carries one "file_path" key, in compact
# JSON, and Claude Code never puts a literal `"` in a path. The greedy `.*` takes the
# LAST such key if a payload ever had two; pretty-printed JSON (a space after the
# colon) or a quote inside a path fails OPEN, silently, which this hook accepts as a nudge.
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
SHOWN_PATH="$FILE_PATH"

# Rules are repo-relative (`(^|/)tools/hooks/`, `(^|/)core/`), and git hands every other consumer repo-relative paths.
# This payload is ABSOLUTE, so matching it as it stands made any file anywhere trip a rule: a file in some other
# project's tools/hooks/, or ANY file of a repository that happens to live under a directory called core/. So: find
# out whether the file is inside THIS repository, and match its path relative to the repository root.
#
# Membership is decided by directory identity (`-ef`: same device and inode), not by comparing strings, because the
# payload's spelling (`D:/work/x`, `/d/work/x`, a different drive-letter case, the repo ROOT reached through a symlink or junction) need not match
# the spelling git gives for the root, and a mismatch here would turn the hook silently off, the failure this file
# already had once. Walk up from the file to the first ancestor that IS the root, collecting the names passed on the
# way (the file's own directories may not exist yet: a Write can create them). Not found = outside the repository.
# Limits, all fail-open: only the ROOT is compared by identity, so a symlink or junction INSIDE the repository that
# points at a guarded directory is not resolved; the rule match is case-sensitive; the walk stops after 100 segments;
# and `-e` on every ancestor means a path on an unreachable network share (UNC) can stall the hook until the OS gives up.
case "$FILE_PATH" in
  /*|[A-Za-z]:*)
    REPO_ROOT="$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$REPO_ROOT" ]; then
      # Parameter expansion only, no dirname/basename: those fork once per segment, and a very deep path made one edit
      # stall for minutes. The depth is capped too (a path deeper than 100 segments is not a source file).
      _rel=""; _p="${FILE_PATH%/}"; _found=0; _depth=0
      while [ "$_depth" -lt 100 ]; do
        _depth=$((_depth + 1))
        if [ -n "$_p" ] && [ -e "$_p" ] && [ "$_p" -ef "$REPO_ROOT" ]; then _found=1; break; fi
        case "$_p" in */*) ;; *) break;; esac
        _seg="${_p##*/}"; _parent="${_p%/*}"
        [ -n "$_parent" ] || _parent="/"
        [ "$_parent" != "$_p" ] || break
        _rel="${_seg}${_rel:+/$_rel}"; _p="$_parent"
      done
      [ "$_found" = 1 ] || exit 0          # outside this repository: not our surfaces
      [ -n "$_rel" ] || exit 0             # the root itself
      # Collapse `.` and `x/..` so a spelling like tools/./ledger.sh or tools/x/../ledger.sh still meets its rule.
      _norm=""; _old_ifs="$IFS"; IFS=/
      set -f
      for _seg in $_rel; do
        case "$_seg" in
          ""|".") ;;
          "..") case "$_norm" in */*) _norm="${_norm%/*}";; *) _norm="";; esac ;;
          *) _norm="${_norm:+$_norm/}$_seg" ;;
        esac
      done
      set +f; IFS="$_old_ifs"
      [ -n "$_norm" ] || exit 0
      FILE_PATH="$_norm"
    fi
    ;;
esac

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

  $SHOWN_PATH just changed and matches a $MATCH_TIER row in surfaces.conf:
    "$MATCH_LABEL"

  This edit did not go through Triage on its own — it happened while
  attention was on something else, which is exactly what R0c exists for.
  Before treating it as done, re-enter the pipeline for this edit:
    bash $KIT/tools/reconcile.sh <predicted-tier> --log
  (a new --round, not a new change) and run whatever gates the reconciled
  tier mandates.

EOF
exit 2
