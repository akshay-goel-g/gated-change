#!/usr/bin/env bash
#
# stop-compliance.sh -- a Claude Code Stop hook: do not let a session end while the change it
# was working on is routed T3/T4 and `ledger.sh compliance` still says no.
#
# Why: the R0c PostToolUse hook (r0c-post-edit.sh) can only nudge; a PostToolUse exit 2 cannot block.
# The first real gate was pre-push, after a whole session of ungated T4 work. A Stop hook can refuse to
# let the agent stop, so the gap is reported at the moment the agent would otherwise say "done".
#
# Arming. It acts only when ALL of these hold, and allows the stop otherwise:
#   - the ledger's latest `route` record has actual tier T3 or T4 (that is "the active change");
#   - `ledger.sh compliance` for that change, tier and round exits non-zero;
#   - Claude Code is not already continuing because of a Stop hook (`stop_hook_active`), because a
#     hook that blocks every stop would trap the agent: at most one block per stop;
#   - the same unchanged state (HEAD, working tree, ledger) has not already been blocked
#     MAX_ATTEMPTS times, which is the cap across turns.
# It fails OPEN on everything it cannot establish (no ledger, no route, no git, a missing tool, a
# compliance run that times out): a Stop hook that blocks on its own faults teaches people to remove it.
# PIPELINE_STOP_HOOK=off disables it.
#
# Output: {"decision":"block","reason":"..."} on stdout, exit 0 -- Claude Code's documented Stop-hook
# contract. Claude Code also caps consecutive Stop continuations on its own (8, raisable with
# CLAUDE_CODE_STOP_HOOK_BLOCK_CAP).
#
# `compliance` takes 35-95s on a large ledger. install-claude-hook.sh registers this hook with a
# timeout that allows for it.
set -uo pipefail

[ "${PIPELINE_STOP_HOOK:-}" = "off" ] && exit 0

MAX_ATTEMPTS="${PIPELINE_STOP_MAX_ATTEMPTS:-3}"
case "$MAX_ATTEMPTS" in ''|*[!0-9]*) MAX_ATTEMPTS=3;; esac

_HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$_HERE/../.." && pwd)"
DATA="${PIPELINE_DATA:-$KIT}"
LEDGER="${LEDGER:-$DATA/ledger.jsonl}"

# A PIPELINE_DATA that is not usable (not absolute, missing, or outside this repository) means the ledger cannot be
# trusted to be this project's. Fail open, as every fault here does, but say so where the user can see it.
if [ -n "${PIPELINE_DATA:-}" ]; then
  . "$KIT/tools/lib/data-root.sh" || { printf '{"systemMessage":"gated-change Stop hook: tools/lib/data-root.sh is missing, so PIPELINE_DATA cannot be checked and compliance was NOT checked."}
'; exit 0; }
  if ! data_root_check_from "${CLAUDE_PROJECT_DIR:-.}" "$PIPELINE_DATA"; then
    printf '{"systemMessage":"gated-change Stop hook: PIPELINE_DATA is not usable (%s), so compliance was NOT checked."}\n' \
      "$(data_root_why_safe "$PIPELINE_DATA" | tr -d '\\"\000-\037')"
    exit 0
  fi
fi

INPUT="$(cat)"

# `stop_hook_active` is a bare JSON boolean at the top level of the Stop payload. A glob match on the compact
# form (and the one-space form) rather than a parser: a payload spaced any other way reads as "not active",
# which only costs one extra block, never a trap.
case "$INPUT" in
  *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0;;
esac

[ -f "$LEDGER" ] || exit 0
[ -f "$KIT/tools/ledger.sh" ] || exit 0
# The repository being worked on, not the one that holds the data directory: from a linked worktree that uses the main
# checkout's data, the fingerprint, the state files and the compliance run belong to the tree whose .pipeline/ this hook
# is (a worktree's settings.json runs its own copy), else to the project directory.
# WORK is set here, never inherited: some sites export a WORK of their own (a scratch directory), and it is not this repository.
WORK=""
if . "$KIT/tools/lib/data-root.sh" 2>/dev/null; then
  WORK="$(data_root_work_root "$KIT" "${CLAUDE_PROJECT_DIR:-.}")" || exit 0
else
  WORK="$(git -C "$KIT" rev-parse --show-toplevel 2>/dev/null)" || WORK="$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
fi
[ -n "$WORK" ] || exit 0

ROUTE="$(grep '"type":"route"' "$LEDGER" 2>/dev/null | tail -n 1)"
[ -n "$ROUTE" ] || exit 0

# Read up to the first UNESCAPED quote, then undo the two JSON escapes, so a name with a quote or a backslash is the
# name that was typed (R-021). sed -E: BSD sed has no \| in a basic expression.
RAWCHANGE="$(printf '%s' "$ROUTE" | sed -nE 's/.*"change":"((\\.|[^"\\])*)".*/\1/p')"
# Any other JSON escape (\t \n \r \u00XX) cannot be undone here, so the name read would not be the name recorded and
# compliance would be asked about a change that does not exist: fail open rather than block a stop that cannot be satisfied.
case "$(printf '%s' "$RAWCHANGE" | sed -e 's/\\\\//g' -e 's/\\"//g')" in *\\*) exit 0;; esac
CHANGE="$(printf '%s' "$RAWCHANGE" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')"
TIER="$(printf '%s' "$ROUTE" | sed -n 's/.*"actual":"\(T[0-9]\)".*/\1/p')"
ROUND="$(printf '%s' "$ROUTE" | sed -n 's/.*"round":\([0-9][0-9]*\).*/\1/p')"
case "$TIER" in T3|T4) ;; *) exit 0;; esac
[ -n "$CHANGE" ] && [ -n "$ROUND" ] || exit 0

# Cross-turn cap: the state is HEAD + the working tree + the ledger. Progress changes it and re-arms
# the hook; a stuck state (nothing changed since the last block) is blocked at most MAX_ATTEMPTS times.
GITDIR="$(git -C "$WORK" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
STATE="$GITDIR/gated-change-stop-state"
_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else cksum | awk '{print $1}'; fi
}
FP="$( { git -C "$WORK" rev-parse HEAD 2>/dev/null; git -C "$WORK" status --porcelain 2>/dev/null; wc -c < "$LEDGER" 2>/dev/null; } | _hash)"
PREV_FP=""; PREV_N=0
if [ -f "$STATE" ]; then
  read -r PREV_FP PREV_N < "$STATE" 2>/dev/null || true
  case "$PREV_N" in ''|*[!0-9]*) PREV_N=0;; esac
fi
if [ "$PREV_FP" = "$FP" ] && [ "$PREV_N" -ge "$MAX_ATTEMPTS" ]; then exit 0; fi
# A passing run is remembered for the same unchanged state: compliance takes about a minute, and a session
# unrelated to an old, already-compliant T3/T4 route should not pay it on every stop.
PASSFILE="$GITDIR/gated-change-stop-pass"
if [ -f "$PASSFILE" ] && [ "$(cat "$PASSFILE" 2>/dev/null)" = "$FP" ]; then exit 0; fi

OUT="$(cd "$WORK" && LEDGER="$LEDGER" bash "$KIT/tools/ledger.sh" compliance --change "$CHANGE" --tier "$TIER" --round "$ROUND" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] || { rm -f "$STATE" 2>/dev/null; printf '%s\n' "$FP" > "$PASSFILE" 2>/dev/null || true; exit 0; }
# 2 is a usage error or a tool fault, not a verdict: fail open.
[ "$RC" -eq 1 ] || exit 0

if [ "$PREV_FP" = "$FP" ]; then N=$((PREV_N + 1)); else N=1; fi
printf '%s %s\n' "$FP" "$N" > "$STATE" 2>/dev/null || true

# The change name is ledger content, and this text goes to the model. Show a name only if it is made of
# ordinary characters; otherwise show a fixed "withheld" token and print only a command that names no change (--latest), so a
# hostile name cannot become a shell command or smuggle instructions into the reason.
case "$CHANGE" in
  *[!A-Za-z0-9._/-]*)
    # A fixed token, not a sanitised prefix: a prefix read as "Fix??login???redirect" and said the name was not shown while
    # showing part of it (G8 round 12), and nothing of a hostile name needs to reach the model here. Fixed text only, so the
    # replacement below can hold no &, backslash or ledger content.
    SHOWN="(change name withheld)"
    # The command names no change: --latest reads the newest route row itself, so nothing from the ledger is pasted (R-036).
    CHECKCMD="${PIPELINE_DATA:+PIPELINE_DATA='${PIPELINE_DATA%/}' }bash \"$KIT/tools/ledger.sh\" compliance --latest --tier $TIER --round $ROUND"
    NOTE="(The change name has unusual characters, so it is not shown. --latest checks the newest route, which is this change unless another was routed since; the header names the change it judged.)
";;
  *)
    SHOWN="$CHANGE"; NOTE=""
    CHECKCMD="${PIPELINE_DATA:+PIPELINE_DATA='${PIPELINE_DATA%/}' }bash \"$KIT/tools/ledger.sh\" compliance --change $CHANGE --tier $TIER --round $ROUND";;
esac

# Mask the name in the WHOLE output BEFORE any line is cut: a 300-column cut can truncate a long shell-quoted name so
# it matches neither form below and reaches the model readable (G4 round 2).
QCHANGE="$(printf '%q' "$CHANGE")"
OUT="${OUT//"$QCHANGE"/$SHOWN}"
OUT="${OUT//"$CHANGE"/$SHOWN}"
BODY="$(printf '%s\n' "$OUT" | grep -vE '^[[:space:]]*PASS[[:space:]]' | cut -c1-300)"
if [ "$(printf '%s\n' "$BODY" | wc -l)" -gt 24 ]; then
  BODY="$(printf '%s\n' "$BODY" | head -n 12)
  [...]
$(printf '%s\n' "$BODY" | tail -n 12)"
fi
# The change name was masked above, in the whole output and before the cut (R-023). Here the shown name (the fixed token for an awkward one)
# stands in for it in the header.
REASON="$(printf 'gated-change: %s is routed %s (round %s) and `ledger.sh compliance` does not pass, so it is not done.\n\n%s\n\nRun each missing gate as a FRESH-context review (a subagent or new session handed the card in core/cards/, never the author grading its own work; core/02-gates.md), log each with ledger.sh add, then check again:\n  %s\n%s(Blocked %s of %s times for this state; PIPELINE_STOP_HOOK=off disables this hook.)' \
  "$SHOWN" "$TIER" "$ROUND" "$BODY" "$CHECKCMD" "$NOTE" "$N" "$MAX_ATTEMPTS")"

# JSON string: backslash, quote and newline are escaped, tab becomes a space, every other control character
# (CR included) is dropped.
# A tab becomes a space first: BSD sed reads \t as a literal t, so no sed escape for it.
ESC="$(printf '%s' "$REASON" | LC_ALL=C tr '\011' ' ' | LC_ALL=C tr -d '\000-\010\013-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} {if (NR>1) print "\\n"; print}')"
printf '{"decision":"block","reason":"%s"}\n' "$ESC"
exit 0
