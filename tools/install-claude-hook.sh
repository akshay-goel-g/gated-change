#!/usr/bin/env bash
#
# install-claude-hook.sh — wire tools/hooks/r0c-post-edit.sh into Claude
# Code's own PostToolUse hooks, without disturbing whatever else already
# lives in .claude/settings.json.
#
# Unlike install-hook.sh (which copies a template to .git/hooks/, a location
# outside the tracked tree that has to have its kit path baked in), the R0c
# hook script itself needs no installing — it lives inside the kit's own
# tracked tools/ tree and self-locates its KIT root from $0, exactly like
# tools/dashboard.sh already does. The only thing to install is the pointer
# to it, in a JSON file this script does not own and must not clobber.
#
# Usage:
#   bash .pipeline/tools/install-claude-hook.sh
#
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$(dirname "$_HERE")}"
CONF="$KIT/project/surfaces.conf"
HOOK_SCRIPT="$KIT/tools/hooks/r0c-post-edit.sh"

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }
REPO_ROOT="$(git rev-parse --show-toplevel)"
SETTINGS_DIR="$REPO_ROOT/.claude"
SETTINGS="$SETTINGS_DIR/settings.json"

[ -f "$HOOK_SCRIPT" ] || { echo "no hook script at $HOOK_SCRIPT" >&2; exit 2; }

if [ ! -f "$CONF" ]; then
  echo "No surfaces file at $CONF." >&2
  echo "  R0c derives its T3/T4 rules from that file, same as the pre-push hook." >&2
  exit 2
fi

# Same "refuse to guard nothing" reasoning as install-hook.sh's T4 check —
# R0c reads T3 *and* T4 rows (01-router.md's own rule), so either is enough
# to make this hook meaningful.
RULES="$(grep -cE '^(T3|T4)::' "$CONF" 2>/dev/null)"
RULES="${RULES:-0}"
if [ "$RULES" -eq 0 ]; then
  echo "$CONF has no T3 or T4 rows, so this hook would have nothing to watch." >&2
  echo "  Answer surfaces.conf's questions first — that is what those rows are." >&2
  exit 2
fi

if grep -q 'EXAMPLE from a browser-extension project' "$CONF" 2>/dev/null; then
  echo "WARNING: $CONF is still the shipped example." >&2
  echo "  This hook will install and will watch a browser extension's trust" >&2
  echo "  boundaries, which are not yours. Replace that file, then run this again." >&2
  echo >&2
fi

# The command Claude Code will run, every session, from wherever it happens
# to have the repo checked out — $CLAUDE_PROJECT_DIR is Claude Code's own
# stand-in for "repo root right now", so this survives a worktree or a
# differently-located clone the same way install-hook.sh's baked-in PREFIX
# survives a hook copied into .git/hooks/. Blank prefix means the kit IS the
# repo, same convention install-hook.sh uses.
KIT_PREFIX="$(git -C "$KIT" rev-parse --show-prefix 2>/dev/null)"
KIT_PREFIX="${KIT_PREFIX%/}"
HOOK_REL="${KIT_PREFIX:+$KIT_PREFIX/}tools/hooks/r0c-post-edit.sh"
COMMAND="bash \"\$CLAUDE_PROJECT_DIR/$HOOK_REL\""

# Merging into a JSON file this script does not own is exactly the kind of
# thing this kit otherwise refuses to do with sed/awk (see tools/ledger.sh's
# own reasoning for why free-text fields go through json_escape() instead of
# being spliced by hand). python is already an optional, skip-loudly
# dependency in tests/run.sh for JSON assertions — same trade here: use it
# when present, refuse and print the exact snippet to add by hand when not,
# never attempt a text-level merge that could silently corrupt someone
# else's settings.
PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

# $COMMAND itself contains literal double quotes (it's a shell command,
# `bash "$CLAUDE_PROJECT_DIR/..."`) — the python merge path escapes those
# correctly via json.dump, but this fallback builds JSON text by hand, so it
# has to escape them itself or the snippet it prints is not valid JSON to
# paste back in.
COMMAND_JSON_ESCAPED="$(printf '%s' "$COMMAND" | sed 's/"/\\"/g')"
SNIPPET_ONE_LINE="{ \"matcher\": \"Edit|Write|MultiEdit\", \"hooks\": [ { \"type\": \"command\", \"command\": \"$COMMAND_JSON_ESCAPED\" } ] }"
STOP_REL_NP="${KIT_PREFIX:+$KIT_PREFIX/}tools/hooks/stop-compliance.sh"
STOP_JSON_NP="$(printf '%s' "bash \"\$CLAUDE_PROJECT_DIR/$STOP_REL_NP\"" | sed 's/"/\\"/g')"
STOP_SNIPPET_ONE_LINE="{ \"hooks\": [ { \"type\": \"command\", \"command\": \"$STOP_JSON_NP\", \"timeout\": 180 } ] }"

if [ -z "$PY" ]; then
  echo "No python3/python found — refusing to hand-edit JSON that isn't mine." >&2
  echo "  Add this entry to $SETTINGS yourself, under \"hooks\".\"PostToolUse\" (create" >&2
  echo "  both if missing) — skip it if a hook with this exact command is already there:" >&2
  echo >&2
  echo "  $SNIPPET_ONE_LINE" >&2
  echo >&2
  echo "  And this one under \"hooks\".\"Stop\" (blocks ending a session while a T3/T4 change fails compliance):" >&2
  echo >&2
  echo "  $STOP_SNIPPET_ONE_LINE" >&2
  echo >&2
  exit 2
fi

mkdir -p "$SETTINGS_DIR"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"

# merge_hook <event> <matcher or ""> <command> <timeout seconds or "">  -- prints INSTALLED, ALREADY_PRESENT
# or PARSE_ERROR:<why>. The PostToolUse entry (R0c) and the Stop entry (stop-compliance.sh) share it.
merge_hook() {
"$PY" - "$SETTINGS" "$1" "$2" "$3" "$4" <<'PYEOF'
import json, sys

path, event, matcher, command, timeout = sys.argv[1:6]

with open(path, "r", encoding="utf-8") as f:
    raw = f.read().strip()
try:
    data = json.loads(raw) if raw else {}
except json.JSONDecodeError as e:
    print("PARSE_ERROR:%s" % e)
    sys.exit(1)

if not isinstance(data, dict):
    print("PARSE_ERROR:top-level JSON is not an object")
    sys.exit(1)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("PARSE_ERROR:\"hooks\" is not an object")
    sys.exit(1)
post = hooks.setdefault(event, [])
if not isinstance(post, list):
    print("PARSE_ERROR:\"hooks.%s\" is not a list" % event)
    sys.exit(1)

already = any(
    isinstance(entry, dict)
    and any(
        isinstance(h, dict) and h.get("command") == command
        for h in entry.get("hooks", [])
    )
    for entry in post
)

if already:
    print("ALREADY_PRESENT")
    sys.exit(0)

entry_hook = {"type": "command", "command": command}
if timeout:
    entry_hook["timeout"] = int(timeout)
entry = {"hooks": [entry_hook]}
if matcher:
    entry["matcher"] = matcher
post.append(entry)

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("INSTALLED")
PYEOF
}

RESULT="$(merge_hook PostToolUse "Edit|Write|MultiEdit" "$COMMAND" "")"
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
  echo "Could not merge into $SETTINGS:" >&2
  echo "  ${RESULT#PARSE_ERROR:}" >&2
  echo "  Fix or remove the existing file, then run this again." >&2
  exit 2
fi

case "$RESULT" in
  ALREADY_PRESENT)
    echo "Already installed: $SETTINGS already runs this exact hook on PostToolUse."
    ;;
  INSTALLED)
    echo "Installed into $SETTINGS"
    echo "  Watching $RULES T3/T4 rule(s) from $CONF on every Edit/Write/MultiEdit:"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      tier="${row%%::*}"; rest="${row#*::}"; rule="${rest%%::*}"; label="${rest#*::}"
      printf "    [%s] %s  → %s\n" "$tier" "$rule" "$label"
    done < <(grep -E '^(T3|T4)::' "$CONF")
    echo
    echo "  A future edit to one of those paths prints a reminder to re-enter R0c"
    echo "  (core/01-router.md) instead of relying on anyone remembering to."
    ;;
esac

# The Stop hook (tools/hooks/stop-compliance.sh): refuse to end a session while the routed T3/T4 change
# fails `ledger.sh compliance`. Registered with a timeout that allows for compliance's 35-95s.
STOP_SCRIPT="$KIT/tools/hooks/stop-compliance.sh"
if [ -f "$STOP_SCRIPT" ]; then
  STOP_REL="${KIT_PREFIX:+$KIT_PREFIX/}tools/hooks/stop-compliance.sh"
  STOP_COMMAND="bash \"\$CLAUDE_PROJECT_DIR/$STOP_REL\""
  STOP_RESULT="$(merge_hook Stop "" "$STOP_COMMAND" 180)"
  case "$STOP_RESULT" in
    ALREADY_PRESENT) echo "Stop hook already installed in $SETTINGS." ;;
    INSTALLED)
      echo
      echo "Stop hook installed: a session will not end while the latest T3/T4 route fails"
      echo "  'ledger.sh compliance' (tools/hooks/stop-compliance.sh). It blocks at most once per stop,"
      echo "  fails open on anything it cannot establish, and PIPELINE_STOP_HOOK=off disables it."
      ;;
    *) echo "Could not install the Stop hook: ${STOP_RESULT#PARSE_ERROR:}" >&2
       echo "  (the R0c reminder above is installed; add the Stop entry by hand: event \"Stop\", no matcher," >&2
       echo "   command ${STOP_COMMAND}, timeout 180)" >&2 ;;
  esac
fi
