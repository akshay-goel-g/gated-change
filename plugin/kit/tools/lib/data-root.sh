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
# Containment is decided by directory identity (`-ef`), walking up from <dir> with parameter expansion, so it does
# not depend on `D:/x` and `/d/x` being spelled the same on Windows and forks nothing per segment. pre-push carries
# an inline copy of this walk (a hook cannot rely on the kit being readable); tests/run.sh checks both.

data_root_check() {
  local d="$1" top p depth=0
  DATA_ROOT_WHY=""
  case "$d" in
    /*|[A-Za-z]:/*) ;;
    *) DATA_ROOT_WHY="'$d' is not an absolute path"; return 1;;
  esac
  case "$d" in
    *[\\\|\&\$\`\'\"]*|*"
"*) DATA_ROOT_WHY="'$d' contains a character that cannot be baked into a hook or settings.json command"; return 1;;
  esac
  [ -d "$d" ] || { DATA_ROOT_WHY="'$d' is not an existing directory"; return 1; }
  [ "${PIPELINE_DATA_EXTERNAL:-0}" = 1 ] && return 0
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { DATA_ROOT_WHY="the current directory is not inside a git repository (PIPELINE_DATA_EXTERNAL=1 allows a data directory elsewhere)"; return 1; }
  p="${d%/}"
  while [ "$depth" -lt 100 ]; do
    depth=$((depth + 1))
    if [ -n "$p" ] && [ -e "$p" ] && [ "$p" -ef "$top" ]; then return 0; fi
    case "$p" in */*) ;; *) break;; esac
    [ "${p%/*}" != "$p" ] || break
    p="${p%/*}"
    [ -n "$p" ] || p="/"
  done
  DATA_ROOT_WHY="'$d' is not inside this repository ($top); a PIPELINE_DATA from another project would judge this one by its rules (PIPELINE_DATA_EXTERNAL=1 to allow a shared directory)"
  return 1
}

# data_root_require <tool-name>: for the tools. Refuses (exit 2) when PIPELINE_DATA is set and unusable.
data_root_require() {
  [ -n "${PIPELINE_DATA:-}" ] || return 0
  data_root_check "$PIPELINE_DATA" && return 0
  echo "REFUSED: PIPELINE_DATA is not usable for $1: $DATA_ROOT_WHY. Nothing was read or written." >&2
  exit 2
}
