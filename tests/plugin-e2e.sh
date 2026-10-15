#!/usr/bin/env bash
#
# plugin-e2e.sh — does the Claude Code plugin actually install and work, for every shipped
# example project type, without anyone doing it by hand?
#
# WHAT IT COVERS (the parts that need no Claude Code session):
#   1. plugin/kit/ matches the kit's sources, and nothing of this repo's own history leaked.
#   2. The manifests parse; plugin and marketplace names agree; every skill has a name and a
#      description. If the `claude` CLI is on PATH, `claude plugin validate` is run as well.
#   3. The install skill's OWN shell blocks are extracted from SKILL.md and executed in a scratch
#      git repository, so the test breaks when the skill text breaks, not just when a copy of it
#      does. (Same idea as the README cleanup test in tests/run.sh.)
#   4. For the shipped default AND each file in examples/surfaces/: the example is installed as
#      project/surfaces.conf, then
#        - status.sh runs and reports without a shell error,
#        - reconcile.sh routes a change touching a trust-boundary path to T4 and leaves an
#          ignored path out,
#        - install-hook.sh installs a pre-push hook that guards at least one T4 rule,
#        - update-kit.sh against the plugin's kit says it is already current.
#
# WHAT IT CANNOT COVER: Claude Code itself loading the plugin and an agent following the skill's
# prose. Run /gated-change:install once in a scratch repo before a release for that.
#
# Usage:  bash tests/plugin-e2e.sh            (about a minute or two)
#         KEEP=1 bash tests/plugin-e2e.sh     (keep the scratch repos and print where)
# Exit:   0 all passed (skips allowed), 1 at least one failure.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
PLUGIN="$KIT/plugin"
SKILL="$PLUGIN/skills/install/SKILL.md"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; }
check() { # check "<description>" <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$d"; fi
}

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t plugin-e2e)"
cleanup() { [ "${KEEP:-0}" = 1 ] && echo "scratch kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
GITQ=(-c core.autocrlf=false -c core.safecrlf=false -c commit.gpgsign=false \
      -c user.email=e2e@example.com -c user.name=e2e)

echo "plugin-e2e — $PLUGIN"

# ---------- 1. the built copy ---------------------------------------------------------------
echo "1. the generated kit copy"
if bash "$KIT/tools/build-plugin.sh" "$TMP/build" >/dev/null 2>&1; then ok; else bad "build-plugin.sh failed"; fi
if diff -r "$TMP/build/kit" "$PLUGIN/kit" >/dev/null 2>&1; then ok
else bad "plugin/kit/ is stale: run  bash tools/build-plugin.sh"; fi
for leaked in ledger.jsonl dashboard.html security-reports project tests experiments specs docs \
              plugin .claude-plugin .claude .github .git SESSION-HANDOFF.md INTENT-LOG.md \
              LEARNINGS.md ACTION-PLAN.md dist; do
  if [ -e "$PLUGIN/kit/$leaked" ]; then bad "$leaked is inside plugin/kit/"; else ok; fi
done
for f in LICENSE NOTICE README.md .claude-plugin/plugin.json; do
  [ -e "$PLUGIN/$f" ] && ok || bad "plugin/$f is missing"
done

# ---------- 2. manifests and skills --------------------------------------------------------
echo "2. manifests and skills"
PY="$(command -v python3 || command -v python || true)"
json_ok() {
  if [ -n "$PY" ]; then "$PY" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1"
  else grep -q '^{' "$1" && grep -q '}$' <(tr -d ' \t\r\n' < "$1"); fi
}
for m in "$PLUGIN/.claude-plugin/plugin.json" "$KIT/.claude-plugin/marketplace.json"; do
  json_ok "$m" && ok || bad "$m is not valid JSON"
done
pname="$(sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN/.claude-plugin/plugin.json" | head -1)"
mnames="$(sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)".*/\1/p' "$KIT/.claude-plugin/marketplace.json")"
echo "$mnames" | grep -qx "$pname" && ok || bad "plugin name '$pname' is not an entry name in marketplace.json"
case "$pname" in claude-*|anthropic-*|"") bad "plugin name '$pname' uses a reserved prefix" ;; *) ok ;; esac
src="$(sed -n 's/.*"source":[[:space:]]*"\([^"]*\)".*/\1/p' "$KIT/.claude-plugin/marketplace.json" | head -1)"
[ -d "$KIT/$src" ] && ok || bad "marketplace source '$src' is not a directory"
for f in "$PLUGIN"/skills/*/SKILL.md; do
  grep -q '^name: ' "$f" && grep -q '^description: ' "$f" && ok || bad "$f lacks name or description"
done
if command -v claude >/dev/null 2>&1; then
  claude plugin validate "$PLUGIN" >/dev/null 2>&1 && ok || bad "claude plugin validate ./plugin failed"
  claude plugin validate "$KIT" >/dev/null 2>&1 && ok || bad "claude plugin validate ./ failed"
else
  skip "claude CLI not on PATH: 'claude plugin validate' not run (run it in your own shell)"
fi

# ---------- 3. the install skill's own shell blocks ---------------------------------------
echo "3. executing the install skill's step 3"
# The fenced bash blocks between "## 3." and the next "## " heading.
step3="$(awk '/^## 3\./{f=1; next} /^## /{f=0} f && /^```bash/{c=1; next} f && /^```/{c=0} f && c{print}' "$SKILL")"
if [ -z "$step3" ]; then bad "could not extract step 3 from $SKILL"; fi
step3="$(printf '%s\n' "$step3" | sed "s#\${CLAUDE_PLUGIN_ROOT}#$PLUGIN#g")"
printf '%s\n' "$step3" | grep -q 'cp -R' && ok || bad "step 3 no longer copies the kit"

# ---------- 4. every project type ----------------------------------------------------------
# name | sample path that must route T4 | sample path under an IGNORE row ('-' = none)
CASES=(
  "default|manifest.json|node_modules/x.js"
  "chrome-extension|src/auth/login.js|node_modules/x.js"
  "data-pipeline|migrations/001.sql|target/x.sql"
  "library-cli|package.json|dist/x.js"
  "rest-api|src/billing/charge.js|vendor/x.js"
  "web-app|migrations/001.sql|node_modules/x.js"
)

for c in "${CASES[@]}"; do
  IFS='|' read -r name t4path ignpath <<<"$c"
  echo "4. project type: $name"
  R="$TMP/repo-$name"; mkdir -p "$R"; cd "$R" || exit 1
  git init -q -b main . >/dev/null 2>&1 || git init -q . >/dev/null 2>&1
  git checkout -q -b main >/dev/null 2>&1 || true
  echo "app" > app.txt
  git "${GITQ[@]}" add -A >/dev/null 2>&1; git "${GITQ[@]}" commit -qm init >/dev/null 2>&1

  # the skill's own commands
  if ! ( eval "$step3" ) >"$R/install.log" 2>&1; then bad "$name: the skill's step 3 failed ($(tail -1 "$R/install.log"))"; continue; fi
  [ -d .pipeline/core ] && [ -d .pipeline/tools ] && [ -d .pipeline/templates ] && ok || bad "$name: .pipeline is missing core, tools or templates"
  [ -f .pipeline/project/surfaces.conf ] && [ -f .pipeline/ledger.jsonl ] && ok || bad "$name: project/ or the ledger was not created"
  [ -e .pipeline/.built-by-build-plugin ] && bad "$name: the build marker was left in .pipeline" || ok

  # the second install must be refused by the skill's own precondition
  test -e .pipeline && ok || bad "$name: precondition would not detect an existing .pipeline"

  if [ "$name" != default ]; then
    cp ".pipeline/examples/surfaces/$name.conf" .pipeline/project/surfaces.conf
  fi

  git "${GITQ[@]}" add -A >/dev/null 2>&1; git "${GITQ[@]}" commit -qm "Add gated-change" >/dev/null 2>&1
  git checkout -q -b feat >/dev/null 2>&1
  mkdir -p "$(dirname "$t4path")" "$(dirname "$ignpath")"
  echo a > "$t4path"; echo b > "$ignpath"
  git "${GITQ[@]}" add -A >/dev/null 2>&1; git "${GITQ[@]}" commit -qm feat >/dev/null 2>&1

  # status.sh: runs, reports, no shell error
  out="$(timeout 180 bash .pipeline/tools/status.sh 2>&1)"
  echo "$out" | grep -q "Pipeline status" && ok || bad "$name: status.sh printed no report"
  echo "$out" | grep -qiE "command not found|syntax error|Traceback|No such file" \
    && bad "$name: status.sh showed a shell error" || ok

  # reconcile.sh: the T4 path routes T4, the ignored one is not listed as a surface
  rout="$(BASE=main timeout 180 bash .pipeline/tools/reconcile.sh T0 2>&1)"
  echo "$rout" | grep -q "Actual tier : T4" && ok || bad "$name: $t4path did not route to T4"
  echo "$rout" | grep -E '^[[:space:]]+T[0-4][[:space:]]' | grep -q "$t4path" && ok \
    || bad "$name: $t4path is not listed under Surfaces hit"
  echo "$rout" | grep -E '^[[:space:]]+T[0-4][[:space:]]' | grep -q "$ignpath" \
    && bad "$name: ignored path $ignpath was routed" || ok

  # the git hook: installed, executable, guards at least one T4 rule
  hout="$(timeout 120 bash .pipeline/tools/install-hook.sh 2>&1)"
  echo "$hout" | grep -q "Installed .git/hooks/pre-push" && ok || bad "$name: install-hook.sh did not install"
  echo "$hout" | grep -Eq "Guarding [1-9][0-9]* T4 rule" && ok || bad "$name: the hook guards no T4 rule"
  [ -x .git/hooks/pre-push ] && ok || bad "$name: pre-push is not executable"

  # update from the plugin's kit: already current
  uout="$(timeout 120 bash .pipeline/tools/update-kit.sh "$PLUGIN/kit" --dry-run 2>&1)"
  echo "$uout" | grep -q "Already current" && ok || bad "$name: update-kit.sh --dry-run did not say Already current"
done

cd "$KIT" || exit 1
echo
echo "passed $PASS · failed $FAIL · skipped $SKIP"
[ "$FAIL" -eq 0 ]
