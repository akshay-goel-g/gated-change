# data-root.sh -- is PIPELINE_DATA a directory this repository may trust?   (sourced, not run)
#
# PIPELINE_DATA (D5) moves project/, ledger.jsonl, dashboard.html and security-reports/ away from the kit's code.
# Those files are the trust configuration: surfaces.conf decides what the push hook guards, commands.conf is run
# as evidence, the ledger is what compliance reads. A value left over from another project (exported once in a
# shell profile) would judge THIS repository by someone else's rules, and every tool would pass.
#
#   data_root_check <dir>   0 = usable; 1 = not, and DATA_ROOT_WHY says why
#
# Usable means: an absolute path, an existing directory, free of characters that cannot be baked into a hook or
# a settings.json command, and INSIDE the git repository the caller is working in (the cwd's toplevel).
# PIPELINE_DATA_EXTERNAL=1 waives only the last condition, for a deliberate shared data directory.
#
# Containment is decided on the PHYSICAL path of <dir> (`..` and symlinks resolved once with `cd -P`) by repository
# identity: the git repository holding it must share this one's git common directory (compared with `-ef`, so it does
# not depend on `D:/x` and `/d/x` being spelled the same on Windows). Any working tree of this repository qualifies; a
# different or nested repository does not. pre-push carries an inline copy of this check (a hook cannot rely on the
# kit being readable); tests/run.sh checks both.

data_root_check() {
  local d="$1" top real dtop c1 c2
  DATA_ROOT_WHY=""
  case "$d" in
    /*|[A-Za-z]:/*) ;;
    *\\*) DATA_ROOT_WHY="'$d' is not an absolute path (use forward slashes, e.g. D:/work/pdata or /d/work/pdata)"; return 1;;
    *) DATA_ROOT_WHY="'$d' is not an absolute path"; return 1;;
  esac
  _data_root_chars_ok "$d" || { DATA_ROOT_WHY="'$d' contains a character that cannot be baked into a hook or settings.json command"; return 1; }
  [ -d "$d" ] || { DATA_ROOT_WHY="'$d' is not an existing directory"; return 1; }
  # The top of a working tree of THIS repository is refused, waiver or not: tiering and coverage find the data directory by
  # its path inside the repository, and at the top that path is empty, so its own ledger and dashboard would be tiered as work.
  if _data_root_is_repo_top "$d"; then
    DATA_ROOT_WHY="'$d' is the top of this repository; use a subdirectory (the data directory is found by its path inside the repository, and at the top that path is empty, so the ledger and dashboard would be tiered as project work)"
    return 1
  fi
  [ "${PIPELINE_DATA_EXTERNAL:-0}" = 1 ] && return 0
  top="$(_data_root_git rev-parse --show-toplevel 2>/dev/null)" || { DATA_ROOT_WHY="the current directory is not inside a git repository (PIPELINE_DATA_EXTERNAL=1 allows a data directory elsewhere)"; return 1; }
  # Judge where the directory REALLY is: `..` segments and symlinks are resolved first, so `<repo>/..` or a link inside
  # the repository that leads out of it cannot pass by name.
  real="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || { DATA_ROOT_WHY="'$d' cannot be resolved to a physical directory"; return 1; }
  real="${real%/}"
  # It must belong to THIS repository: the git repository that contains it must share this one's git common directory.
  # That accepts any working tree of the repository (a linked worktree uses the main checkout's data directory, which
  # is what a shared .git/hooks bakes in) and refuses another project, and a nested repository (submodule, vendored
  # clone), whose commands.conf and surfaces.conf would otherwise judge this one.
  dtop="$(_data_root_git -C "$real" rev-parse --show-toplevel 2>/dev/null)" || { DATA_ROOT_WHY="'$d' is not inside this repository ($top); a PIPELINE_DATA from another project would judge this one by its rules (PIPELINE_DATA_EXTERNAL=1 to allow a shared directory)"; return 1; }
  c1="$(_data_root_common "$real")"; c2="$(_data_root_common "$top")"
  if [ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" -ef "$c2" ]; then return 0; fi
  DATA_ROOT_WHY="'$d' is inside a different git repository ($dtop) than this one ($top); that repository's commands.conf and surfaces.conf would judge this one (PIPELINE_DATA_EXTERNAL=1 to allow it)"
  return 1
}

# git with the repository-selecting environment removed. Git exports GIT_DIR (absolute, in a linked worktree) to the hooks it
# runs, and with it set `git -C <dir> rev-parse` describes THAT repository whatever <dir> is, so every directory would pass.
_data_root_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"
}

# True when <dir> is the top of a working tree of the repository the current directory is in (the main checkout or a linked one).
_data_root_is_repo_top() {
  local real dtop here c1 c2
  real="$(cd -P -- "$1" 2>/dev/null && pwd -P)" || return 1
  dtop="$(_data_root_git -C "$real" rev-parse --show-toplevel 2>/dev/null)" || return 1
  dtop="$(cd -P -- "$dtop" 2>/dev/null && pwd -P)" || return 1
  # -ef, not string equality: one directory can have two spellings (Git Bash resolves D:/x to /tmp/x through a mount alias but leaves /d/x alone).
  [ "$real" -ef "$dtop" ] || return 1
  here="$(_data_root_git rev-parse --show-toplevel 2>/dev/null)" || return 1
  c1="$(_data_root_common "$real")"; c2="$(_data_root_common "$here")"
  [ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" -ef "$c2" ]
}

# The physical path of the git common directory of the repository containing <dir> (shared by all of its worktrees).
_data_root_common() {
  local c
  c="$(_data_root_git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$c" in /*|[A-Za-z]:/*) ;; *) c="$1/$c";; esac
  (cd -P -- "$c" 2>/dev/null && pwd -P)
}

# data_root_check judged from <dir> (the project) instead of the current directory, then back. A hook runs wherever the session's
# shell is, which an agent can leave; the verdict on PIPELINE_DATA must not depend on that. An unusable <dir> changes nothing.
data_root_check_from() { # <dir> <value>
  local rc old="$PWD"
  cd -- "$1" 2>/dev/null || cd -- "$old"
  data_root_check "$2"; rc=$?
  cd -- "$old" 2>/dev/null
  return $rc
}

# data_root_require <tool-name>: for the tools. Refuses (exit 2) when PIPELINE_DATA is set and unusable.
data_root_require() {
  [ -n "${PIPELINE_DATA:-}" ] || return 0
  if data_root_check "$PIPELINE_DATA"; then
    # PIPELINE_DATA_EXTERNAL=1 returns before any containment check; say so when it actually waived something, because
    # exported in a profile it would otherwise let a stale PIPELINE_DATA judge every repository by another project's rules.
    if [ "${PIPELINE_DATA_EXTERNAL:-0}" = 1 ] && ! ( PIPELINE_DATA_EXTERNAL=0; data_root_check "$PIPELINE_DATA" ) >/dev/null 2>&1; then
      echo "WARNING: PIPELINE_DATA_EXTERNAL=1 is waiving the containment check: $PIPELINE_DATA is not in this repository, so its surfaces.conf, commands.conf, ledger and reports govern this one." >&2
    fi
    return 0
  fi
  echo "REFUSED: PIPELINE_DATA is not usable for $1: $DATA_ROOT_WHY. Nothing was read or written." >&2
  exit 2
}

# data_root_hook_mismatch: the installers bake PIPELINE_DATA into the pre-push hook and into the Claude Code hook commands
# (.claude/settings.json), but a shell reads whatever it has exported, so a shell without it reads the OTHER ledger and
# surfaces file while the hooks enforce the baked one -- and a shell WITH it, before the hooks were re-baked, reads a
# directory the hooks do not. Sets DATA_ROOT_HOOK_SRC (which hook), DATA_ROOT_HOOK_BAKED (its directory, or empty),
# DATA_ROOT_HOOK_DESC and DATA_ROOT_HOOK_FIX (text for a message) and returns 1 on a disagreement. Two spellings of one
# directory are one directory. The baked value comes from a repository-controlled file: control bytes are stripped.
_data_root_same() {
  [ "$1" = "$2" ] && return 0
  [ -n "$1" ] && [ -n "$2" ] && [ -d "$1" ] && [ -d "$2" ] && [ "$1" -ef "$2" ]
}
_data_root_clean() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'; }
# How to change what a hook enforces: install-hook.sh replaces its own hook with --force; install-claude-hook.sh refuses a
# different value even with --force, so the old entries have to be removed from .claude/settings.json first.
_data_root_rebake() { # <src> [set]
  local w=""; [ -z "${2:-}" ] || w=" with PIPELINE_DATA set"
  case "$1" in
    "Claude Code hook") echo "remove the R0c and Stop hook entries from .claude/settings.json and re-run install-claude-hook.sh$w";;
    *) echo "re-run install-hook.sh --force$w";;
  esac
}
# True when <value> could be a path PIPELINE_DATA accepts as far as its characters go (the same set data_root_check refuses).
_data_root_chars_ok() {
  case "$1" in
    *[\\\|\&\$\`\'\"}]*|*"
"*) return 1;;
  esac
  return 0
}
# data_root_why_safe <value>: DATA_ROOT_WHY from the last data_root_check, fit to print where an agent reads it. A value that is
# not even a possible path (it can come from a hand-edited settings.json) is never echoed: it would reach the agent as text
# to act on. The rest -- which may be plain prose, since only a few characters make a value impossible -- has its control
# bytes stripped and is shown.
data_root_why_safe() {
  if _data_root_chars_ok "$1"; then _data_root_clean "$DATA_ROOT_WHY"; else printf 'the value is not a usable path'; fi
}
_data_root_mismatch_set() { # <src> <baked-or-empty>
  DATA_ROOT_HOOK_SRC="$1"; DATA_ROOT_HOOK_BAKED="$2"
  if [ -n "$2" ] && ! _data_root_chars_ok "$2"; then
    # A value read from a repository-controlled file that is not even a possible path is never echoed: it would reach a
    # terminal or an agent as text to act on.
    DATA_ROOT_HOOK_BAKED="(an unusable value)"
    DATA_ROOT_HOOK_DESC="a PIPELINE_DATA that is not a usable path"
    DATA_ROOT_HOOK_FIX="Fix it: $(_data_root_rebake "$1")."
  elif [ -n "$2" ]; then
    DATA_ROOT_HOOK_DESC="the data directory $2"
    DATA_ROOT_HOOK_FIX="Export PIPELINE_DATA='$2' (the hook is shared by every worktree, so that is the directory a push from any of them is judged by), or $(_data_root_rebake "$1")."
  else
    DATA_ROOT_HOOK_DESC="the kit's own directory (no PIPELINE_DATA was baked in)"
    DATA_ROOT_HOOK_FIX="Unset PIPELINE_DATA here, or $(_data_root_rebake "$1" set)."
  fi
}
# The PIPELINE_DATA values baked into the kit's own hook commands (r0c-post-edit and stop-compliance) in a settings.json,
# one line per hook command, in file order: the value, or an empty line for a command with none baked in (it reads the kit
# directory, which a shell that exports PIPELINE_DATA is not using). A PIPELINE_DATA='...' text on any other command is not
# the kit's and is ignored. The sed branch is its own -e script: BSD sed reads a label to the end of the line.
data_root_claude_baked_list() { # <settings.json>
  grep -o "\(PIPELINE_DATA='[^']*' \)\{0,1\}bash [^,}]*\(r0c-post-edit\|stop-compliance\)" "$1" 2>/dev/null \
    | sed -e "s/^PIPELINE_DATA='\([^']*\)'.*/\1/" -e t -e "s/.*//"
}
# True when <dir> is in the same repository as the current directory's (the same git common directory), whichever working
# tree of it either is: a linked worktree and the main checkout share one. The test for "this data directory's prefix means
# something in the files this tool is judging", where comparing toplevels would call every other worktree foreign.
data_root_same_repo() { # <dir>
  local c1 c2
  c1="$(_data_root_common "$1")" || return 1; c2="$(_data_root_common .)" || return 1
  [ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" -ef "$c2" ]
}
# The repository being worked on, for evidence and compliance: the one the kit is in (a linked worktree's own .pipeline/ is
# that worktree's) -- unless the kit is its OWN checkout, separate from the project holding PIPELINE_DATA, in which case the
# project is the current directory's repository, the one data_root_check judged the data directory against. Except under
# PIPELINE_DATA_EXTERNAL=1, which skips that judgement: the kit's own repository is returned then (R-012 19).
data_root_work_root() { # <kit-dir> [fallback-dir]
  local kt kc dc
  kt="$(_data_root_git -C "$1" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$kt" ]; then
    if [ -z "${PIPELINE_DATA:-}" ] || [ "${PIPELINE_DATA_EXTERNAL:-0}" = 1 ]; then echo "$kt"; return 0; fi
    kc="$(_data_root_common "$kt")"; dc="$(_data_root_common "$PIPELINE_DATA")"
    if [ -n "$kc" ] && [ -n "$dc" ] && [ "$kc" -ef "$dc" ]; then echo "$kt"; return 0; fi
  fi
  _data_root_git -C "${2:-.}" rev-parse --show-toplevel 2>/dev/null
}
data_root_hook_mismatch() {
  local cur="${PIPELINE_DATA:-}"
  DATA_ROOT_HOOK_BAKED=""; DATA_ROOT_HOOK_SRC=""; DATA_ROOT_HOOK_DESC=""; DATA_ROOT_HOOK_FIX=""
  cur="${cur%/}"
  _data_root_prepush_mismatch "$cur" || return 1
  data_root_claude_mismatch
}
_data_root_prepush_mismatch() { # <current, no trailing slash>
  local hook baked cur="$1"
  hook="$(_data_root_git rev-parse --git-path hooks/pre-push 2>/dev/null)" || hook=""
  # Only the kit's own hook carries a baked data directory; a husky or hand-written pre-push has none, and calling it "the
  # kit's directory" would send the user to --force, which would overwrite it.
  if [ -n "$hook" ] && [ -f "$hook" ] && grep -q '^PIPELINE_DATA="\${PIPELINE_DATA:-' "$hook" 2>/dev/null; then
    baked="$(sed -n 's/^PIPELINE_DATA="\${PIPELINE_DATA:-\(.*\)}"$/\1/p' "$hook" 2>/dev/null | head -n 1)"
    baked="$(_data_root_clean "${baked%/}")"
    if ! _data_root_same "$baked" "$cur"; then
      _data_root_mismatch_set "pre-push hook" "$baked"; return 1
    fi
  fi
  return 0
}
# Only the Claude Code hooks (R0c and the Stop hook): each carries its own value, and both must agree with this shell.
data_root_claude_mismatch() {
  local baked cur="${PIPELINE_DATA:-}" top
  DATA_ROOT_HOOK_BAKED=""; DATA_ROOT_HOOK_SRC=""; DATA_ROOT_HOOK_DESC=""; DATA_ROOT_HOOK_FIX=""
  cur="${cur%/}"
  top="$(_data_root_git rev-parse --show-toplevel 2>/dev/null)" || return 0
  if [ -f "$top/.claude/settings.json" ] && grep -qs 'r0c-post-edit\|stop-compliance' "$top/.claude/settings.json"; then
    # A process substitution, not $(...): a command substitution drops the trailing empty line a command with no value gives.
    while IFS= read -r baked; do
      baked="$(_data_root_clean "${baked%/}")"
      if ! _data_root_same "$baked" "$cur"; then
        _data_root_mismatch_set "Claude Code hook" "$baked"; return 1
      fi
    done < <(data_root_claude_baked_list "$top/.claude/settings.json")
  fi
  return 0
}

# data_root_hook_warn <tool-name>: a one-line stderr warning when data_root_hook_mismatch fires. Never refuses.
data_root_hook_warn() {
  data_root_hook_mismatch && return 0
  echo "WARNING: the $DATA_ROOT_HOOK_SRC enforces $DATA_ROOT_HOOK_DESC, but $1 is using ${PIPELINE_DATA:-the kit directory}. $DATA_ROOT_HOOK_FIX" >&2
  return 0
}
