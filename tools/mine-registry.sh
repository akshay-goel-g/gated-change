#!/usr/bin/env bash
#
# mine-registry.sh — draft coupling-registry entries from git history.
#
# Premise: your repo already recorded every coupling it has. Files that keep getting
# fixed together are coupled, whether or not anyone wrote that down. This finds them.
#
# Usage:
#   bash mine-registry.sh [output.md]
#
# Env:
#   SINCE=<git date>   history window                        (default: 3 years ago)
#   MAX_FILES=<n>      skip commits touching more than this  (default: 15)
#   MIN_PAIR=<n>       minimum co-occurrences to report      (default: 2)
#   TOP=<n>            how many pairs to emit                (default: 25)
#   HUB_PCT=<n>        drop files appearing in more than n%
#                      of analysed commits                   (default: 25)
#   EXCLUDE=<regex>    paths to ignore
#
set -euo pipefail

# Default lands in THIS kit's project/ (<kit>/project/registry-draft.md), wherever the
# script is run from. It used to be ./project/..., i.e. the repo root, so an install's draft
# landed outside .pipeline/ and the next step's `cp -r templates/project` nested (E7).
OUT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/project/registry-draft.md}"
SINCE="${SINCE:-3 years ago}"
MAX_FILES="${MAX_FILES:-15}"
MIN_PAIR="${MIN_PAIR:-2}"
TOP="${TOP:-25}"
HUB_PCT="${HUB_PCT:-25}"
EXCLUDE="${EXCLUDE:-(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|/dist/|/build/|/vendor/|node_modules/|\.min\.(js|css)$|\.map$)}"

command -v git >/dev/null || { echo "git not found" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 1; }

TMP_FILES=$(mktemp); TMP_HUBS=$(mktemp); TMP_PAIRS=$(mktemp); TMP_SHAS=$(mktemp)
trap 'rm -f "$TMP_FILES" "$TMP_HUBS" "$TMP_PAIRS" "$TMP_SHAS"' EXIT

echo "Scanning fix-shaped commits since '$SINCE' ..." >&2

# Commits whose message suggests something was repaired. These are the incidents.
git log --since="$SINCE" --format='%H' -i \
    --grep='fix' --grep='revert' --grep='hotfix' --grep='regression' --grep='broke' \
    > "$TMP_SHAS" 2>/dev/null || true

COMMITS=0; USED=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  COMMITS=$((COMMITS + 1))

  files=$(git show --name-only --format='' "$sha" 2>/dev/null \
          | sed '/^$/d' | grep -Ev "$EXCLUDE" | sort -u || true)
  [ -n "$files" ] || continue

  n=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
  # One file proves no coupling. Fifty is a refactor or a merge, and would pair
  # everything with everything.
  [ "$n" -ge 2 ] && [ "$n" -le "$MAX_FILES" ] || continue
  USED=$((USED + 1))

  printf '%s\n' "$files" | while IFS= read -r f; do
    printf '%s\t%s\n' "$sha" "$f"
  done >> "$TMP_FILES"
done < "$TMP_SHAS"

echo "  $COMMITS fix-shaped commits, $USED usable (2..$MAX_FILES files)" >&2

if [ "$USED" -lt 2 ]; then
  echo "" >&2
  echo "Not enough history to mine. This is the expected result for a young repo." >&2
  echo "Start with the universal registry in core/03-registry.md and let yours grow" >&2
  echo "from real incidents." >&2
  exit 0
fi

# --- Hub filter -------------------------------------------------------------
# A file touched in most commits (a changelog, a session log, a barrel export)
# co-occurs with everything and is coupled to nothing. Raw co-occurrence counts
# rank these first and bury the real signal, so drop them before pairing.
THRESH=$(( USED * HUB_PCT / 100 ))
[ "$THRESH" -lt 2 ] && THRESH=2

awk -F'\t' -v t="$THRESH" '{c[$2]++} END {for (f in c) if (c[f] > t) print f}' \
    "$TMP_FILES" | sort > "$TMP_HUBS"

HUBS=$(wc -l < "$TMP_HUBS" | tr -d ' ')
if [ "$HUBS" -gt 0 ]; then
  echo "  dropped $HUBS hub file(s) present in >${HUB_PCT}% of commits:" >&2
  sed 's/^/    /' "$TMP_HUBS" >&2
fi

# --- Pair generation --------------------------------------------------------
awk -F'\t' -v hubs="$TMP_HUBS" '
  BEGIN { while ((getline h < hubs) > 0) hub[h] = 1 }
  !($2 in hub) { n[$1]++; f[$1, n[$1]] = $2 }
  END {
    for (s in n) {
      if (n[s] < 2) continue
      for (i = 1; i <= n[s]; i++)
        for (j = i + 1; j <= n[s]; j++) {
          a = f[s, i]; b = f[s, j]
          if (a > b) { t = a; a = b; b = t }
          printf "%s :: %s\t%s\n", a, b, s
        }
    }
  }' "$TMP_FILES" > "$TMP_PAIRS"

if [ ! -s "$TMP_PAIRS" ]; then
  echo "No co-occurring file pairs survived filtering." >&2
  echo "  On a small repo the files you fix together can all look like 'hubs' (changed in more than" >&2
  echo "  HUB_PCT=$HUB_PCT% of the commits analysed) and be dropped. Try HUB_PCT=100, or wait for more history." >&2
  exit 0
fi

mkdir -p "$(dirname "$OUT")"

{
  echo "# Coupling registry — mined draft"
  echo
  echo "> Generated $(date -u '+%Y-%m-%d %H:%M UTC') from $USED fix commits since \"$SINCE\"."
  echo "> Files appearing in more than ${HUB_PCT}% of those commits were dropped as hubs."
  echo ">"
  echo "> **These are candidates, not entries.** Each pair is a statistical hint that two"
  echo "> files are coupled. Your job is to replace the blank \"because\" with what actually"
  echo "> happened. A pair you cannot explain should be deleted, not kept — an unexplained"
  echo "> rule gets ignored at review time, and one ignored rule discredits the rest."
  echo
  echo "---"
  echo

  rank=0
  cut -f1 "$TMP_PAIRS" | sort | uniq -c | sort -rn | head -n "$TOP" \
  | while read -r count pair; do
      [ "$count" -ge "$MIN_PAIR" ] || continue
      rank=$((rank + 1))

      left=${pair%% :: *}
      right=${pair##* :: }

      echo "## $rank. \`$left\`  +  \`$right\`"
      echo
      echo "Fixed together **${count}** times."
      echo
      echo "| If you touch | You must also check | Because |"
      echo "|---|---|---|"
      echo "| \`$left\` | \`$right\` | _<-- what actually broke_ |"
      echo
      echo "<details><summary>Commits</summary>"
      echo
      grep -F "$pair	" "$TMP_PAIRS" | cut -f2 | sort -u | while read -r sha; do
        subj=$(git log -1 --format='%s' "$sha" 2>/dev/null || echo '?')
        echo "- \`${sha:0:9}\` $subj"
      done
      echo
      echo "</details>"
      echo
    done

  echo "---"
  echo
  echo "## How to convert a candidate into an entry"
  echo
  echo "1. Open the commits. Read what actually went wrong."
  echo "2. Write the coupling as an instruction, not an observation:"
  echo "   \"if you touch X, check Y\" — not \"X and Y are related\"."
  echo "3. The **because** is the whole value. \"They change together\" is not a reason;"
  echo "   \"the allow rule is evaluated above the block rule\" is."
  echo "4. Delete anything you cannot explain."
  echo
  echo "## Reading the results honestly"
  echo
  echo "Co-occurrence is correlation. Two files fixed together may be coupled, or may"
  echo "simply both belong to the feature that needed the most work. The commits are"
  echo "included above precisely so you can tell those apart — if you find yourself"
  echo "keeping a pair because the number is high rather than because you remember why,"
  echo "delete it."
} > "$OUT"

echo "Wrote $OUT" >&2
echo "Next: open it, keep what you can explain, delete the rest." >&2
