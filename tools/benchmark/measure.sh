#!/usr/bin/env bash
#
# measure.sh — rework analysis from git history. Study 1 in README.md.
#
# Rework ratio = fix-shaped commits / all commits, for a set of paths.
# High rework means defects escaped whatever process was in place at the time.
# It costs nothing to compute and needs no experiment.
#
# Usage:
#   bash measure.sh [--since <date>] [--paths <pattern>] [--split <date>] [--csv]
#
#   --since   history window                    (default: 18 months ago)
#   --paths   limit to paths matching pattern   (default: all)
#   --split   compare before/after this date    (e.g. adoption date)
#   --csv     machine-readable output
#
set -uo pipefail

SINCE="18 months ago"
PATHS=""
SPLIT=""
CSV=0

while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="$2"; shift 2;;
    --paths) PATHS="$2"; shift 2;;
    --split) SPLIT="$2"; shift 2;;
    --csv)   CSV=1; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }

FIX_RE='(^|[^a-z])(fix|fixes|fixed|revert|hotfix|regression|bug|broke|broken|patch)([^a-z]|$)'

# count_range <since> <until|""> -> "total fixes"
count_range() {
  local since="$1" until="$2" args
  args=(--since="$since" --format=%s)
  [ -n "$until" ] && args+=(--until="$until")

  local subjects
  if [ -n "$PATHS" ]; then
    subjects=$(git log "${args[@]}" -- "$PATHS" 2>/dev/null)
  else
    subjects=$(git log "${args[@]}" 2>/dev/null)
  fi

  local total fixes
  total=$(printf '%s\n' "$subjects" | sed '/^$/d' | wc -l | tr -d ' ')
  fixes=$(printf '%s\n' "$subjects" | sed '/^$/d' | grep -icE "$FIX_RE" || true)
  echo "$total $fixes"
}

pct() { # numerator denominator
  [ "$2" -eq 0 ] && { echo "n/a"; return; }
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f%%", (a/b)*100 }'
}

report_line() { # label total fixes
  local label="$1" total="$2" fixes="$3" ratio
  ratio=$(pct "$fixes" "$total")
  if [ "$CSV" -eq 1 ]; then
    echo "$label,$total,$fixes,$ratio"
  else
    printf "  %-26s %6s commits %6s fixes   rework %s\n" "$label" "$total" "$fixes" "$ratio"
  fi
}

[ "$CSV" -eq 1 ] && echo "period,commits,fixes,rework_ratio"

if [ "$CSV" -eq 0 ]; then
  echo "Rework analysis"
  echo "---------------"
  echo "  window : since $SINCE"
  echo "  paths  : ${PATHS:-<all>}"
  echo
fi

if [ -n "$SPLIT" ]; then
  read -r t1 f1 <<EOF
$(count_range "$SINCE" "$SPLIT")
EOF
  read -r t2 f2 <<EOF
$(count_range "$SPLIT" "")
EOF
  report_line "before $SPLIT" "$t1" "$f1"
  report_line "after  $SPLIT" "$t2" "$f2"

  if [ "$CSV" -eq 0 ] && [ "$t1" -gt 0 ] && [ "$t2" -gt 0 ]; then
    echo
    awk -v a="$f1" -v b="$t1" -v c="$f2" -v d="$t2" 'BEGIN {
      r1=(a/b)*100; r2=(c/d)*100; delta=r2-r1
      printf "  change: %+.1f percentage points\n", delta
    }'
    echo
    echo "  Correlational only. Your skill, the codebase, and the difficulty of the"
    echo "  work all changed across this boundary too. Treat a small delta as noise;"
    echo "  treat a large one as a reason to look closer, not as proof."
    if [ "$t1" -lt 20 ] || [ "$t2" -lt 20 ]; then
      echo
      echo "  WARNING: fewer than 20 commits in one period. Too few to read anything into."
    fi
  fi
else
  read -r t f <<EOF
$(count_range "$SINCE" "")
EOF
  report_line "all" "$t" "$f"

  if [ "$CSV" -eq 0 ]; then
    echo
    echo "  Add --split <date> to compare two eras (e.g. your adoption date)."
    echo "  Add --paths <pattern> to isolate one feature area."
  fi
fi

if [ "$CSV" -eq 0 ]; then
  echo
  echo "What this does NOT tell you"
  echo "---------------------------"
  echo "  A commit calling itself a fix may be a typo correction; one that does not"
  echo "  may be a silent repair. This measures the SHAPE of your history, which"
  echo "  correlates with defect escape but is not the same thing. It is a starting"
  echo "  point for looking, not a verdict."
fi
