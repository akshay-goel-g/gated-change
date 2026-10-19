#!/usr/bin/env bash
#
# stop-hook-e2e.sh -- tests for tools/hooks/stop-compliance.sh (ACTION-PLAN C2) and its installer wiring.
# Standalone, like plugin-e2e.sh: it builds throwaway repos and drives the hook with real Stop payloads.
#
#   bash tests/stop-hook-e2e.sh
#
# Each `ledger.sh` call takes 5-30s on Git Bash for Windows; the whole script is a few minutes.
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2-}" ] && printf '        %s\n' "$2"; }
check() { # check <name> <expected rc> <rc> [detail]
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $2, got $3 ${4-}"; fi
}

PY=""; for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

newrepo() { # a self-hosting layout: the kit IS the repo
  R="$(mktemp -d "$TMPROOT/r.XXXXXX")"
  git -C "$R" init -q . && git -C "$R" config user.email t@e && git -C "$R" config user.name t
  git -C "$R" config commit.gpgsign false
  cp -r "$KIT/tools" "$KIT/core" "$KIT/project" "$KIT/templates" "$R/"
  printf 'one\ntwo\nthree\n' > "$R/f.txt"
  git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm base >/dev/null 2>&1
}
hook() {
  local payload="${1-}"; [ -n "$payload" ] || payload='{"hook_event_name":"Stop"}'
  ( cd "$R" && printf '%s' "$payload" | env ${2:+"${@:2}"} bash tools/hooks/stop-compliance.sh )
}
led()  { ( cd "$R" && bash tools/ledger.sh "$@" ) >/dev/null 2>&1; }

echo "stop-hook tests"; echo "==============="

# 1. nothing to check: no ledger, then no route
newrepo
OUT="$(hook)"; check "no ledger: allows the stop, prints nothing" 0 $? ; [ -z "$OUT" ] && ok "  ...and nothing on stdout" || bad "  ...and nothing on stdout" "$OUT"
: > "$R/ledger.jsonl"
OUT="$(hook)"; [ -z "$OUT" ] && ok "empty ledger: allows" || bad "empty ledger: allows" "$OUT"

# 2. a T2 route does not arm it
led route --change low-risk --predicted T2 --actual T2 --reason "docs"
OUT="$(hook)"; [ -z "$OUT" ] && ok "T2 route: not armed" || bad "T2 route: not armed" "$OUT"

# 3. a T4 route with no gates blocks, with valid JSON naming the change
led route --change risky-change --predicted T4 --actual T4 --reason "trust boundary"
OUT="$(hook)"; RC=$?
check "T4 route with no gates: exits 0 (the block is in the JSON)" 0 $RC
case "$OUT" in *'"decision":"block"'*risky-change*) ok "T4 route with no gates: blocks and names the change";; *) bad "T4 route with no gates: blocks" "$OUT";; esac
if [ -n "$PY" ]; then
  printf '%s' "$OUT" | "$PY" -c "import json,sys; d=json.load(sys.stdin); assert d['decision']=='block' and 'INCOMPLETE' in d['reason']" 2>/dev/null \
    && ok "the block is valid JSON and carries the compliance verdict" || bad "the block is valid JSON" "$OUT"
else echo "  SKIP  no python: JSON validity not checked"; fi

# 4. stop_hook_active: never blocks a second time in a row
OUT="$(hook '{"hook_event_name":"Stop","stop_hook_active":true}')"; [ -z "$OUT" ] && ok "stop_hook_active: allows" || bad "stop_hook_active: allows" "$OUT"

# 5. the off switch
OUT="$(hook '{"hook_event_name":"Stop"}' PIPELINE_STOP_HOOK=off)"; [ -z "$OUT" ] && ok "PIPELINE_STOP_HOOK=off: allows" || bad "PIPELINE_STOP_HOOK=off: allows" "$OUT"

# 6. the cross-turn cap: the same state is blocked at most N times
rm -f "$(git -C "$R" rev-parse --absolute-git-dir)/gated-change-stop-state"
O1="$(hook '{"hook_event_name":"Stop"}' PIPELINE_STOP_MAX_ATTEMPTS=2)"
O2="$(hook '{"hook_event_name":"Stop"}' PIPELINE_STOP_MAX_ATTEMPTS=2)"
O3="$(hook '{"hook_event_name":"Stop"}' PIPELINE_STOP_MAX_ATTEMPTS=2)"
if [ -n "$O1" ] && [ -n "$O2" ] && [ -z "$O3" ]; then ok "cap: blocks twice for an unchanged state, then allows"; else bad "cap" "1:${#O1} 2:${#O2} 3:${#O3} chars"; fi
# ...and progress re-arms it
printf 'four\n' >> "$R/f.txt"
O4="$(hook '{"hook_event_name":"Stop"}' PIPELINE_STOP_MAX_ATTEMPTS=2)"
[ -n "$O4" ] && ok "cap: a changed working tree re-arms the hook" || bad "cap: re-arm"

# 7. a compliant change is allowed
for g in G1 G4 G5 G6 G7 G8; do
  led add --change risky-change --gate $g --tier T4 --round 1 --outcome pass --confidence fresh --model m --evidence f.txt:1
done
OUT="$(hook)"; [ -z "$OUT" ] && ok "all mandated gates passed: allows" || bad "all mandated gates passed: allows" "$OUT"

# 8. an unusable ledger path fails open
OUT="$(hook '{"hook_event_name":"Stop"}' LEDGER=/nonexistent/ledger.jsonl)"; [ -z "$OUT" ] && ok "missing ledger path: fails open" || bad "missing ledger path: fails open" "$OUT"

# 9. the installer registers it once, with a timeout, and keeps the R0c entry
if [ -n "$PY" ]; then
  newrepo
  printf 'T4::(^|/)auth/::auth\n' > "$R/project/surfaces.conf"
  ( cd "$R" && bash tools/install-claude-hook.sh ) >/dev/null 2>&1; RC=$?
  check "installer exits 0" 0 $RC
  ( cd "$R" && bash tools/install-claude-hook.sh ) >/dev/null 2>&1
  "$PY" - "$R/.claude/settings.json" <<'PYEOF' && ok "settings.json: one PostToolUse entry, one Stop entry with a timeout" || bad "settings.json shape"
import json, sys
d = json.load(open(sys.argv[1]))
post = [h for e in d["hooks"]["PostToolUse"] for h in e["hooks"] if "r0c-post-edit.sh" in h["command"]]
stop = [h for e in d["hooks"]["Stop"] for h in e["hooks"] if "stop-compliance.sh" in h["command"]]
assert len(post) == 1 and len(stop) == 1 and stop[0].get("timeout", 0) >= 120
PYEOF
else echo "  SKIP  no python: installer wiring not checked"; fi

# 10. a hostile change name in the ledger never becomes a pasteable shell command in the block reason
newrepo
led route --change 'a$(touch PWNED)b`id`' --predicted T4 --actual T4 --reason "hostile name"
OUT="$(hook)"
case "$OUT" in *'"decision":"block"'*) ok "hostile change name: still blocks";; *) bad "hostile change name: still blocks" "$OUT";; esac
case "$OUT" in *'$(touch'*|*'`id`'*) bad "hostile change name: no shell syntax reaches the reason" "$OUT";; *) ok "hostile change name: no shell syntax reaches the reason";; esac
case "$OUT" in *'compliance --change'*) bad "hostile change name: no pasteable command for it" "$OUT";; *) ok "hostile change name: no pasteable command for it";; esac
[ ! -e "$R/PWNED" ] && ok "hostile change name: nothing was executed" || bad "hostile change name: nothing was executed"

# 11. installer: a malformed Stop section is reported with a reason, not swallowed
if [ -n "$PY" ]; then
  newrepo
  printf 'T4::(^|/)auth/::auth\n' > "$R/project/surfaces.conf"
  mkdir -p "$R/.claude"; printf '{"hooks":{"Stop":{"a":1}}}\n' > "$R/.claude/settings.json"
  ERR="$( cd "$R" && bash tools/install-claude-hook.sh 2>&1 >/dev/null )"
  case "$ERR" in *"Could not install the Stop hook"*"not a list"*) ok "installer: malformed Stop section is reported with its reason";; *) bad "installer: malformed Stop section" "$ERR";; esac
fi

# 12. the block tells the agent the verify gates need a fresh review (no self-grading)
newrepo
led route --change selfgrade --predicted T4 --actual T4 --reason "x"
OUT="$(hook)"
case "$OUT" in *"FRESH-context"*"core/cards"*) ok "block reason points at fresh-context gate runs and the cards";; *) bad "block reason names fresh-context runs and the cards" "$OUT";; esac

# 13. a carriage return (or other control character) in compliance's output still yields valid JSON
newrepo
led route --change crtest --predicted T4 --actual T4 --reason "x"
printf '#!/usr/bin/env bash\nprintf "INCOMPLETE a\\rb\\r\\n\\ttab \\"q\\" back\\\\slash\\001ctl\\n"\nexit 1\n' > "$R/tools/ledger.sh"
OUT="$(hook)"
if [ -n "$PY" ]; then
  printf '%s' "$OUT" | "$PY" -c "import json,sys; d=json.load(sys.stdin); assert d['decision']=='block' and 'back' in d['reason']" 2>/dev/null \
    && ok "CR, tab, quote, backslash and control characters: valid JSON" || bad "control characters: valid JSON" "$OUT"
else echo "  SKIP  no python"; fi

# 14. a T3 route arms it too, and a name with a space is shown without a pasteable command
newrepo
led route --change "has space" --predicted T3 --actual T3 --reason "x"
OUT="$(hook)"
case "$OUT" in *'"decision":"block"'*"T3"*) ok "T3 route: blocks";; *) bad "T3 route: blocks" "$OUT";; esac

echo; printf 'passed %s . failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
