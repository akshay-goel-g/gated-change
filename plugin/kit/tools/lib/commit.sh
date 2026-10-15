#!/usr/bin/env bash
#
# commit.sh -- the ONE way a stored commit string becomes a commit.
#
# WHY THIS IS A LIBRARY. Commit strings reach this kit from places an attacker (or just an unlucky
# pusher) can influence: ledger rows (`ledger.sh add --commit`; rows written before round 26 hold the
# 7-character abbreviation `detect_commit` used to store), the install pin, report files. Handed to
# `git rev-parse <string>^{commit}`, `git merge-base`, `git cat-file -e`, `git log` as they are, git
# tries REF NAMES before abbreviated object names -- so a tag or branch called like the short sha
# redirects the lookup, and anyone who can push a tag can turn an UNBOUND pass into a PASS or move the
# "unrouted" anchor (G7 rounds 23 and 24, G4 rounds 23 and 24: five separate call sites, found one
# review round at a time). Rule: nothing that came from a ledger row, a pin or a report goes to git
# until it has been through resolve_commit.
#
# resolve_commit <string>
#   prints the FULL sha of the one commit the string names, exit 0; prints nothing and exits 1 for
#   anything else. Never consults a ref name:
#     - not lower-case hex, or empty                            -> no
#     - exactly the repository's hash length (40, or 64 under sha256):
#         an object id, never a ref; a commit is itself, an annotated tag is peeled to its commit,
#         anything else (blob, tree) is no
#     - longer than that                                        -> no (it would be read as a ref)
#     - 4 .. hash length - 1: an abbreviation; objects only (`rev-parse --disambiguate`), and exactly
#         ONE commit may carry the prefix. A blob or tree sharing the prefix is ignored; two commits
#         sharing it is ambiguous (no, and the exit status is 2 rather than 1, so a caller can tell
#         "no such commit" from "cannot say which").
#     - shorter than 4                                          -> no
#
# Sourced, not executed. Its only state is the object-format cache (_RC_HASHLEN, _RC_HASHLEN_KEY),
# reset every time the file is sourced and re-read when the working directory or GIT_DIR changes.

_rc_load_hashlen() {
  case "$(git rev-parse --show-object-format 2>/dev/null)" in
    sha256) _RC_HASHLEN=64;;
    *)      _RC_HASHLEN=40;;
  esac
  _RC_HASHLEN_KEY="$PWD|${GIT_DIR-}"
}
# Whatever the environment says about the cache is not trusted: sourcing starts it afresh.
_RC_HASHLEN=""; _RC_HASHLEN_KEY=""
_rc_load_hashlen

resolve_commit() {
  local s="$1" n hashlen o t full count=0
  case "$s" in ''|*[!0-9a-f]*) return 1;; esac
  n="${#s}"
  # The object format is asked once per repository (see _rc_load_hashlen), not once per string. Callers
  # use this in $( ), whose cache would die with the subshell, so it is also loaded when the file is
  # sourced: the subshells inherit it.
  if [ "${_RC_HASHLEN_KEY-}" != "$PWD|${GIT_DIR-}" ]; then _rc_load_hashlen; fi
  hashlen="$_RC_HASHLEN"
  if [ "$n" -gt "$hashlen" ]; then return 1; fi
  if [ "$n" -eq "$hashlen" ]; then
    # A full-length hex string is an object id (git does not read it as a ref name when it is a valid
    # object); the type decides what it is.
    t="$(git cat-file -t "$s" 2>/dev/null)" || return 1
    case "$t" in
      commit) printf '%s\n' "$s"; return 0;;
      tag)    full="$(git rev-parse --verify -q "${s}^{commit}" 2>/dev/null)" || return 1
              [ -n "$full" ] || return 1
              printf '%s\n' "$full"; return 0;;
      *)      return 1;;
    esac
  fi
  [ "$n" -ge 4 ] || return 1
  for o in $(git rev-parse --disambiguate="$s" 2>/dev/null); do
    [ "$(git cat-file -t "$o" 2>/dev/null)" = commit ] || continue
    count=$((count + 1)); full="$o"
  done
  [ "$count" -le 1 ] || return 2   # ambiguous: callers that bind a result to a change treat it as UNBOUND
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$full"
}
