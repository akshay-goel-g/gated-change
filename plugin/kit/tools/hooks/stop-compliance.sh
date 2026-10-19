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
LEDGER="${LEDGER:-$KIT/ledger.jsonl}"

INPUT="$(cat)"

# `stop_hook_active` is a bare JSON boolean at the top level of the Stop payload. A glob match on the compact
# form (and the one-space form) rather than a parser: a payload spaced any other way reads as "not active",
# which only costs one extra block, never a trap.
case "$INPUT" in
  *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0;;
esac

[ -f "$LEDGER" ] || exit 0
[ -f "$KIT/tools/ledger.sh" ] || exit 0
git -C "$KIT" rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

ROUTE="$(grep '"type":"route"' "$LEDGER" 2>/dev/null | tail -n 1)"
[ -n "$ROUTE" ] || exit 0

CHANGE="$(printf '%s' "$ROUTE" | sed -n 's/.*"change":"\([^"]*\)".*/\1/p')"
TIER="$(printf '%s' "$ROUTE" | sed -n 's/.*"actual":"\(T[0-9]\)".*/\1/p')"
ROUND="$(printf '%s' "$ROUTE" | sed -n 's/.*"round":\([0-9][0-9]*\).*/\1/p')"
case "$TIER" in T3|T4) ;; *) exit 0;; esac
[ -n "$CHANGE" ] && [ -n "$ROUND" ] || exit 0
# A change name with a quote or backslash was escaped on write; do not guess at it.
case "$CHANGE" in *\\*|*\"*) exit 0;; esac

# Cross-turn cap: the state is HEAD + the working tree + the ledger. Progress changes it and re-arms
# the hook; a stuck state (nothing changed since the last block) is blocked at most MAX_ATTEMPTS times.
GITDIR="$(git -C "$KIT" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
STATE="$GITDIR/gated-change-stop-state"
_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else cksum | awk '{print $1}'; fi
}
FP="$( { git -C "$KIT" rev-parse HEAD 2>/dev/null; git -C "$KIT" status --porcelain 2>/dev/null; wc -c < "$LEDGER" 2>/dev/null; } | _hash)"
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

OUT="$(cd "$(git -C "$KIT" rev-parse --show-toplevel)" && LEDGER="$LEDGER" bash "$KIT/tools/ledger.sh" compliance --change "$CHANGE" --tier "$TIER" --round "$ROUND" 2>&1)"
RC=$?
[ "$RC" -ne 0 ] || { rm -f "$STATE" 2>/dev/null; printf '%s\n' "$FP" > "$PASSFILE" 2>/dev/null || true; exit 0; }
# 2 is a usage error or a tool fault, not a verdict: fail open.
[ "$RC" -eq 1 ] || exit 0

if [ "$PREV_FP" = "$FP" ]; then N=$((PREV_N + 1)); else N=1; fi
printf '%s %s\n' "$FP" "$N" > "$STATE" 2>/dev/null || true

# The change name is ledger content, and this text goes to the model. Show a name only if it is made of
# ordinary characters; otherwise show a sanitised one and give NO pasteable command, so a hostile name cannot
# become a shell command or smuggle instructions into the reason.
case "$CHANGE" in
  *[!A-Za-z0-9._/-]*)
    SHOWN="$(printf '%s' "$CHANGE" | tr -c 'A-Za-z0-9._/-' '?' | cut -c1-80)"
    CHECKCMD="(the change name contains unusual characters; run ledger.sh compliance for it by hand)";;
  *)
    SHOWN="$CHANGE"
    CHECKCMD="bash \"$KIT/tools/ledger.sh\" compliance --change $CHANGE --tier $TIER --round $ROUND";;
esac

BODY="$(printf '%s\n' "$OUT" | grep -vE '^[[:space:]]*PASS[[:space:]]' | cut -c1-300)"
if [ "$(printf '%s\n' "$BODY" | wc -l)" -gt 24 ]; then
  BODY="$(printf '%s\n' "$BODY" | head -n 12)
  [...]
$(printf '%s\n' "$BODY" | tail -n 12)"
fi
# The raw change name appears in compliance's own text; show the sanitised one there too.
BODY="${BODY//"$CHANGE"/$SHOWN}"
REASON="$(printf 'gated-change: %s is routed %s (round %s) and `ledger.sh compliance` does not pass, so it is not done.\n\n%s\n\nRun each missing gate as a FRESH-context review (a subagent or new session handed the card in core/cards/, never the author grading its own work; core/02-gates.md), log each with ledger.sh add, then check again:\n  %s\n(Blocked %s of %s times for this state; PIPELINE_STOP_HOOK=off disables this hook.)' \
  "$SHOWN" "$TIER" "$ROUND" "$BODY" "$CHECKCMD" "$N" "$MAX_ATTEMPTS")"

# JSON string: backslash, quote and newline are escaped, tab becomes a space, every other control character
# (CR included) is dropped.
# A tab becomes a space first: BSD sed reads \t as a literal t, so no sed escape for it.
ESC="$(printf '%s' "$REASON" | LC_ALL=C tr '\011' ' ' | LC_ALL=C tr -d '\000-\010\013-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} {if (NR>1) print "\\n"; print}')"
printf '{"decision":"block","reason":"%s"}\n' "$ESC"
exit 0
