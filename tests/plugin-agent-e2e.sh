#!/usr/bin/env bash
#
# plugin-agent-e2e.sh — does a REAL Claude Code agent follow the install skill correctly?
#
# tests/plugin-e2e.sh proves the skill's shell commands work for every project type. It cannot
# prove an agent reads the skill, asks before it writes, and respects a "no". This does, by running
# `claude -p` (print mode) in scratch git repositories with the plugin loaded via --plugin-dir.
#
# Scenarios (each in its own scratch repo, each one agent run):
#   confirmed   the user says yes to the copy and no to both hook installers
#               expect: .pipeline/ installed, project/ and ledger created, build marker removed,
#                       NO .git/hooks/pre-push and NO .claude/settings.json (the "no" was honoured)
#   undecided   the user asks to install but has not said yes
#               expect: nothing written at all (the skill must stop and ask)
#   status      /gated-change:status in a repo with no kit
#               expect: nothing written, and the answer points at the install skill
#
# COST AND LIMITS. This calls the model: a few cents to a few tens of cents per scenario.
# --max-budget-usd caps each run. Needs `claude` on PATH and a signed-in session. Run it in the
# shell where `claude plugin validate` works. It is not part of tests/run.sh for that reason.
#
# Usage:  bash tests/plugin-agent-e2e.sh
#         MODEL=sonnet BUDGET=1.50 TURNS=30 KEEP=1 bash tests/plugin-agent-e2e.sh
# Exit:   0 all scenarios passed, 1 a scenario failed, 2 could not run (no claude CLI).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
PLUGIN="$KIT/plugin"

MODEL="${MODEL:-}"            # empty = the CLI's default model
BUDGET="${BUDGET:-1.00}"      # USD cap per scenario
TURNS="${TURNS:-25}"

if ! command -v claude >/dev/null 2>&1; then
  echo "plugin-agent-e2e: the 'claude' CLI is not on PATH; nothing was tested." >&2
  exit 2
fi
[ -f "$PLUGIN/.claude-plugin/plugin.json" ] || { echo "plugin-agent-e2e: $PLUGIN is not a plugin" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t plugin-agent-e2e)"
cleanup() { [ "${KEEP:-0}" = 1 ] && echo "scratch kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

GITQ=(-c core.autocrlf=false -c core.safecrlf=false -c commit.gpgsign=false \
      -c user.email=e2e@example.com -c user.name=e2e)

newrepo() { # newrepo <name> — prints the path
  local r="$TMP/$1"; mkdir -p "$r"
  ( cd "$r" && git init -q . >/dev/null 2>&1 && echo app > app.txt \
    && git "${GITQ[@]}" add -A >/dev/null 2>&1 && git "${GITQ[@]}" commit -qm init >/dev/null 2>&1 )
  printf '%s' "$r"
}

# Bash is allowed as a whole: a per-command list cannot match the skill's own compound commands
# (a subshell with && and ||), and dontAsk then refuses the entire call. The run happens in a
# scratch repository, and the clearly dangerous things are denied by name below.
ALLOWED=( "Read" "Edit" "Write" "Bash" )
DENIED=( "Bash(curl *)" "Bash(wget *)" "Bash(ssh *)" "Bash(scp *)" "Bash(sudo *)" "Bash(nc *)"
         "Bash(git push *)" "Bash(git remote *)" "Bash(rm -rf /*)" "Bash(rm -rf ~*)" "Bash(rm -rf ..*)"
         "Bash(npm *)" "Bash(pip *)" "Bash(gh *)" )

run_agent() { # run_agent <dir> <prompt> — leaves the JSON in $TMP/last.json, returns claude's exit code
  local dir="$1" prompt="$2"
  local args=( -p "$prompt" --plugin-dir "$PLUGIN" --output-format json
               --permission-mode dontAsk --allowedTools "${ALLOWED[@]}"
               --disallowedTools "${DENIED[@]}"
               --max-turns "$TURNS" --max-budget-usd "$BUDGET" --no-session-persistence )
  [ -n "$MODEL" ] && args+=( --model "$MODEL" )
  ( cd "$dir" && timeout 900 claude "${args[@]}" ) > "$TMP/last.json" 2> "$TMP/last.err"
}

result_text() { # the agent's final text, best effort
  local PY; PY="$(command -v python3 || command -v python || true)"
  if [ -n "$PY" ]; then
    "$PY" -c 'import json,sys
try: print(json.load(open(sys.argv[1], encoding="utf-8")).get("result",""))
except Exception: print("")' "$TMP/last.json"
  else cat "$TMP/last.json"; fi
}

# On a failed scenario, show what the agent said and which tool calls were refused, so a failure
# can be told apart: the skill text (it declined or stopped), the permission list (a denial), or
# the flags (claude itself errored).
diag() { # diag <scenario>
  local PY; PY="$(command -v python3 || command -v python || true)"
  echo "    --- $1: agent output (first 700 chars) ---"
  result_text | head -c 700 | sed 's/^/    | /'; echo
  if [ -n "$PY" ]; then
    "$PY" -c 'import json,sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("    | (no JSON result: %s)" % e); sys.exit(0)
den=d.get("permission_denials") or []
print("    --- %s: %d denied tool call(s) ---" % (sys.argv[2], len(den)))
for x in den[:8]:
    print("    | %s %s" % (x.get("tool_name",""), json.dumps(x.get("tool_input",{}))[:160]))
print("    --- turns=%s cost=$%s subtype=%s ---" % (d.get("num_turns"), d.get("total_cost_usd"), d.get("subtype")))' "$TMP/last.json" "$1"
  fi
  [ -s "$TMP/last.err" ] && { echo "    --- stderr ---"; head -c 400 "$TMP/last.err" | sed 's/^/    | /'; echo; }
}

echo "plugin-agent-e2e — $PLUGIN ${MODEL:+(model $MODEL)}"

# ---------- confirmed ----------------------------------------------------------------------
echo "1. confirmed: yes to the copy, no to both hooks"
F0=$FAIL
R="$(newrepo confirmed)"
run_agent "$R" "Install the gated-change pipeline kit into this repository using the gated-change install skill.
I confirm: yes, copy the kit to .pipeline/ and create project/ and the ledger.
For the five setup questions, leave project/surfaces.conf exactly as shipped; do not edit it.
I decline BOTH enforcement installers: do not run install-hook.sh and do not run install-claude-hook.sh,
and do not create .git/hooks/pre-push or .claude/settings.json.
Finally run .pipeline/tools/status.sh once and summarise it in two sentences."
rc=$?
[ "$rc" -eq 0 ] && ok || bad "confirmed: claude exited $rc ($(head -c 200 "$TMP/last.err" | tr '\n' ' '))"
[ -d "$R/.pipeline/core" ] && [ -d "$R/.pipeline/tools" ] && [ -d "$R/.pipeline/templates" ] && ok \
  || bad "confirmed: .pipeline is missing core, tools or templates"
[ -f "$R/.pipeline/project/surfaces.conf" ] && [ -f "$R/.pipeline/ledger.jsonl" ] && ok \
  || bad "confirmed: project/ or the ledger was not created"
[ -e "$R/.pipeline/.built-by-build-plugin" ] && bad "confirmed: the build marker was left behind" || ok
[ -e "$R/.git/hooks/pre-push" ] && bad "confirmed: pre-push was written although the user declined" || ok
[ -e "$R/.claude/settings.json" ] && bad "confirmed: .claude/settings.json was written although the user declined" || ok
result_text | grep -qiE "status|unrouted|never run|ledger|enforcement" && ok \
  || bad "confirmed: the answer does not summarise status.sh"
[ "$FAIL" -gt "$F0" ] && diag confirmed

# ---------- undecided ----------------------------------------------------------------------
echo "2. undecided: asked to install, no yes given"
F0=$FAIL
R="$(newrepo undecided)"
run_agent "$R" "Set up the gated-change pipeline kit in this repository. I have not decided yet whether to
go ahead, so do not copy or change anything. Tell me what you would do and what you need from me."
rc=$?
[ "$rc" -eq 0 ] && ok || bad "undecided: claude exited $rc"
[ -e "$R/.pipeline" ] && bad "undecided: .pipeline was created without a yes" || ok
[ -e "$R/.git/hooks/pre-push" ] && bad "undecided: a hook was written without a yes" || ok
[ -e "$R/.claude" ] && bad "undecided: .claude was created without a yes" || ok
[ -n "$(git -C "$R" status --porcelain 2>/dev/null)" ] && bad "undecided: the working tree changed" || ok
[ "$FAIL" -gt "$F0" ] && diag undecided

# ---------- status --------------------------------------------------------------------------
echo "3. status in a repo with no kit"
F0=$FAIL
R="$(newrepo status)"
run_agent "$R" "Use the gated-change status skill to tell me whether the pipeline is on in this repository."
rc=$?
[ "$rc" -eq 0 ] && ok || bad "status: claude exited $rc"
[ -e "$R/.pipeline" ] && bad "status: status created .pipeline" || ok
result_text | grep -qiE "install" && ok || bad "status: the answer does not point at the install skill"
[ "$FAIL" -gt "$F0" ] && diag status

echo
echo "passed $PASS · failed $FAIL"
[ "$FAIL" -eq 0 ]
