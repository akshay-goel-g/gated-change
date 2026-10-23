#!/usr/bin/env bash
#
# coverage.sh — "what has landed that no gate has seen?", computed once.
#
# WHY THIS IS A LIBRARY AND NOT A COPY. `tools/status.sh` prints this to a
# terminal and `tools/dashboard.sh` bakes it into a web page. Two readers of
# the same question is exactly how `tools/lib/matrix.sh` came to exist — the
# gate matrix used to be restated per tool, and the copies disagreed about
# what was mandatory. A coverage number that says "3 unrouted" in one place
# and "all clear" in another is worse than either answer alone, because
# whichever a reader happens to see, the other is wrong.
#
# WHAT "UNROUTED" MEANS, AND WHAT IT DELIBERATELY DOES NOT. This does not
# attribute a gate to each commit. A gate records the commit it REVIEWED; the
# fix then lands as a LATER commit, so per-commit attribution would report
# every legitimate fix as a violation. What is computed instead is honest and
# derivable: work that landed SINCE the last recorded gate run, tiered by the
# same `surfaces.conf` rows `reconcile.sh` applies to a working tree. That set
# is precisely R0c's concern — edits made after routing already ran.
#
# Sourced, not executed. Every function writes to stdout and reads no globals
# beyond the arguments it is given, so a caller can use one without the rest.

# resolve_commit: the one way a stored commit string becomes a commit, never through a ref name (a tag
# or branch named like a stored short sha used to redirect the anchor and the range, G7 round 23).
# Sourced, so `exit` would take the caller down: that is the point. Counting without it is a wrong answer.
if [ ! -f "$(dirname "${BASH_SOURCE[0]}")/commit.sh" ]; then
  echo "missing $(dirname "${BASH_SOURCE[0]}")/commit.sh — cannot compute coverage" >&2
  exit 2
fi
. "$(dirname "${BASH_SOURCE[0]}")/commit.sh"

# The most recently committed commit named by a gate record WITH A VERDICT (outcome pass or fail),
# verified to exist HERE.
#
# NOT the physically-last "type":"gate" LINE. `ledger.sh add --commit <sha>`
# (tools/ledger.sh:59) is a real, documented option — a gate can be logged
# against a commit other than current HEAD, and gate lines are appended when
# the REVIEW happens, not in commit-graph order. A retro-logged or backfilled
# entry for an older commit can land physically after a real, later gate run,
# which made the old `tail -1` read exactly the wrong anchor: coverage would
# then re-flag already-gated commits as unrouted. So every gate line's commit
# is checked, and "most recent" is decided by commit-graph ANCESTRY, not file
# order.
#
# A ledger may legitimately name commits this clone has never seen: a
# `--project` fleet ledger, a squashed or rewritten history, a short sha from
# a different repo. Returning one unverified makes the caller compute
# `<unknown>..HEAD`, which git resolves to nothing, which prints "0 commits
# since" — the best-looking possible output and a lie. Empty output here means
# "no anchor", and callers must say so rather than fill it in.
#
# `--commit` is ledger data — untrusted, from whoever last ran `ledger.sh
# add`. Two rounds of a fresh G7 review found two ways that bites:
#
# 1. Verify FIRST with `git rev-parse --verify -q`, and use the FULL sha it
#    prints from then on — never the raw ledger value — for any further git
#    call. `rev-parse --verify` is deliberately the only place the raw,
#    dash-leading-possible value is used: it restricts itself to a single
#    revision argument. `git log`, in contrast, treats a leading-`-` argument
#    as an option — a ledger value of `--output=/some/path` once reached
#    `git log` as literally that option, and `git log` WROTE to the path
#    (proven by direct repro before this was caught). A verified full sha is
#    always hex-only (40 characters under SHA-1, 64 under SHA-256) — it can
#    never start with `-`, which is what makes it safe to hand to a second
#    git command without re-deriving that safety property each time.
# 2. Rank candidates by commit-graph ANCESTRY (`git merge-base --independent`
#    — "which of these commits is nobody else's ancestor"), never by commit
#    TIMESTAMP. An earlier version of this function picked the candidate with
#    the highest `%ct`, which is exactly as forgeable as the ledger value
#    itself: the same untrusted writer who can name a `--commit` at all can
#    author one throwaway commit with a `GIT_COMMITTER_DATE` set to whatever
#    they like — the fix that first tried rejecting future dates only turned
#    "wins instantly, forever" into "wins the moment real time reaches the
#    forged date, permanently if nothing later ever gets logged" — narrower,
#    not closed, found by a second fresh G7 round. Ancestry has no such
#    knob: it is derived from the immutable parent-hash chain, so a commit
#    only ranks as "newer" than another by actually descending from it.
#    Faking that means actually being a real descendant — at which point it
#    is not a forgery, it is exactly the newer work this function exists to
#    find. The one case ancestry cannot order — two candidates on genuinely
#    divergent history, neither a descendant of the other — is NOT given a
#    tie-break. A first attempt picked the lexicographically-greatest full
#    sha, reasoning it was as hard to aim for as a hash collision; a fresh
#    G7 round found that wrong — winning a greater-than comparison against a
#    known target is closer to a coin flip per attempt than a collision
#    search, and the same untrusted writer who can push a divergent commit
#    at all can as easily grind a handful of trivial variants of it first.
#    That reopened exactly the forgeable-anchor class this redesign exists
#    to close. There is no signal available here that is both decisive and
#    outside the same writer's control, so real ancestry ambiguity now
#    returns "no anchor" (see below) rather than guessing.
#
# A shallow or grafted clone can make a commit LOOK ancestor-free when a real
# ancestor exists past the fetch/graft boundary — this function's own
# existing comments already treat "a squashed or rewritten history" as an
# expected operating condition, and this is the same class of limitation,
# not a new one. Not addressed: detecting shallow/grafted history and
# refusing to answer would be the honest fix, left for a follow-up.
#
# ONLY commits on HEAD's own history are candidates. `git rev-parse --verify`
# proves a ledger commit is an OBJECT that exists here; it does not prove the
# commit is reachable from HEAD. Those diverge exactly when a gate was logged
# against a branch commit that was then rebased or squashed on merge — the
# ledger is append-only and never rewrites the entry (04-ledger.md), and the
# orphaned object survives git's gc grace window (two weeks by default, longer
# while a worktree reflog holds it). An orphan like that is a LEGITIMATE
# `merge-base --independent` tip: nothing descends from it because it was
# never merged. So one stale entry was enough to push the independent-set
# count past 1 and blank the anchor completely, at which point status.sh and
# the dashboard scan the entire history as "unrouted" — the whole coverage
# signal lost for weeks after any superseded branch, self-healing only by luck
# once gc prunes the object. `project/map.md`'s silent-failure row for this
# file anticipated the INVERSE symptom ("a wrong anchor prints '0 commits
# since', the best-looking possible answer"); the direction was incomplete.
# The filter below drops any candidate not reachable from HEAD BEFORE
# `merge-base --independent` runs, so an unmerged commit is never a rival for
# "newest reviewed commit on this line" — it is on a different line.
# Only a gate row with a VERDICT (outcome pass or fail) anchors. README calls `skipped` the absence
# of a verdict and `n/a` a recorded non-applicability; either used to reset the anchor, so an
# unreviewed T4 commit vanished from status the moment anyone logged `--outcome skipped`.
coverage_anchor() {
  _cov_ledger="$1"
  [ -f "$_cov_ledger" ] || return 0
  # Distinct commits, not distinct lines: a change with N gate rounds logged
  # against the same commit costs one verify call, not N.
  _cov_shas="$(grep '"type":"gate"' "$_cov_ledger" 2>/dev/null | grep -E '"outcome":"(pass|fail)"' \
    | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' | sort -u)"
  [ -n "$_cov_shas" ] || return 0
  # <full sha> <original raw ledger string>, one verified candidate per line
  # — kept paired so the function can still return the raw form the ledger
  # actually used (short or full), matching its pre-existing contract, while
  # every OTHER git call from here on uses only the safe, resolved full sha.
  _cov_pairs=""
  # A literal newline, assigned this way because `$(printf '\n')` does NOT
  # work for this: command substitution strips ALL trailing newlines from
  # its own output, so `$(printf '\n')` evaluates to an EMPTY string, not a
  # newline — found by this exact bug: `_cov_pairs` collapsed onto one line,
  # `awk '{print $1}'` misparsed it, and every candidate silently vanished.
  _cov_nl='
'
  # `$_cov_shas` is intentionally unquoted below — it is a newline-separated
  # LIST and needs word-splitting to become one candidate per iteration. That
  # also exposes it to pathname expansion: a ledger `"commit"` value of `*`
  # would otherwise iterate over this directory's actual filenames instead of
  # the literal string `*` (confirmed by direct repro). `set -f` disables
  # that half of the expansion while leaving the word-splitting this loop
  # needs intact; restored right after, before any `return` could skip it —
  # there is none between here and `set +f`. A fresh G6 round found this.
  set -f
  for _cov_sha in $_cov_shas; do
    # ledger.sh only writes a hex --commit; anything else in a hand-edited row is not a candidate.
    case "$_cov_sha" in ''|*[!0-9a-f]*) continue;; esac
    # Quoted, and `^{commit}` treats its argument as a revision string rather
    # than a shell fragment or a path — a ledger value reaching a command
    # position is the read-then-splice gap a prior G7 round found in
    # ledger.sh's gate ids. This call ALSO refuses anything option-shaped
    # (`--verify` restricts itself to one revision argument) — see the
    # header comment on why that matters.
    # Resolved among commit OBJECTS (see resolve_commit): a tag named like the short sha used to
    # redirect the anchor (G7 round 23).
    _cov_full="$(resolve_commit "$_cov_sha")" || continue
    [ -n "$_cov_full" ] || continue
    _cov_pairs="${_cov_pairs}${_cov_pairs:+$_cov_nl}$_cov_full $_cov_sha"
  done
  set +f
  [ -n "$_cov_pairs" ] || return 0

  # Ancestry, not timestamp: reduce the verified, deduplicated full shas to
  # the ones nobody else here descends from, in ONE `merge-base` call — an
  # ordinary commit whose ledger entry was retro-logged out of order is an
  # ancestor of the real later work and drops out here, no timestamp needed.
  _cov_fulls="$(printf '%s\n' "$_cov_pairs" | awk '{print $1}' | sort -u)"

  # Drop any candidate not reachable from HEAD — see the header comment. An
  # orphaned gate entry (its commit rebased or squashed away) still resolves
  # above but is on a different line of history, and left in it would be a
  # legitimate `merge-base --independent` tip that blanks the anchor.
  #
  # `rev-list --no-walk <cands> --not HEAD` lists precisely the candidates NOT
  # reachable from HEAD, in ONE call — not one per commit, which is the cost
  # class coverage_scan()'s own comment measured at 61s/63 commits. `--no-walk`
  # "has no effect if a range is specified" (git docs) and `--not HEAD` may
  # count as one on older git: if it is ignored the output is a SUPERSET (each
  # non-ancestor plus its unmerged ancestors), and `grep -vxF`-removing a sha
  # that was never in $_cov_fulls is a no-op — so the filter is correct either
  # way, and --no-walk is only a cheapness optimization. $_cov_fulls is
  # unquoted for the same reason it is unquoted on the merge-base line below:
  # every element is a rev-parse-resolved full hex sha, never option- or
  # glob-shaped. HEAD may not resolve (unborn branch) — then there are no
  # resolvable candidates anyway and $_cov_pairs already returned above; the
  # guard just avoids a spurious rev-list error.
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    _cov_notanc="$(git rev-list --no-walk $_cov_fulls --not HEAD -- 2>/dev/null)"
    if [ -n "$_cov_notanc" ]; then
      _cov_fulls="$(printf '%s\n' "$_cov_fulls" | grep -vxF "$_cov_notanc" 2>/dev/null)"
    fi
  fi
  [ -n "$_cov_fulls" ] || return 0

  _cov_independent="$(git merge-base --independent $_cov_fulls 2>/dev/null)"
  [ -n "$_cov_independent" ] || return 0
  # Usually exactly one tip (one clear newest commit). More than one means two gated commits that are
  # BOTH ancestors of HEAD yet neither descends from the other: HEAD's history holds a merge of two
  # lines, each gated on its own (the README's own two-branch flow). They used to be refused ("no
  # honest way to rank them") and status then called the commit missing and listed every gated
  # commit as unrouted (G8 round 11/12). There is nothing to rank: "unrouted" is the set of commits
  # NOT contained in ANY reviewed tip, so ALL independent tips are returned and the range is
  # `HEAD ^a ^b` (coverage_range). That cannot be gamed by choosing a winner, and a ledger writer who
  # can name a commit could always name HEAD itself, with the same effect as before. An unmerged or
  # orphaned candidate never reaches here: the HEAD-ancestor filter above dropped it.
  #
  # Printed as the raw ledger strings, space-separated, in full-sha order (deterministic).
  _cov_out=""
  for _cov_f in $(printf '%s\n' "$_cov_independent" | sort); do
    _cov_s="$(printf '%s\n' "$_cov_pairs" | awk -v f="$_cov_f" '$1==f{print $2; exit}')"
    if [ -n "$_cov_s" ]; then _cov_out="${_cov_out}${_cov_out:+ }$_cov_s"; fi
  done
  if [ -n "$_cov_out" ]; then
    printf '%s' "$_cov_out"
  fi
}

# The rev-list arguments for "everything not contained in any of these anchors": `HEAD ^a ^b`.
# $1 is coverage_anchor's output (one or several shas separated by spaces). Each is re-resolved to
# a full sha, so a ledger string can never reach git as anything but a commit.
coverage_range() {
  _cr_out="HEAD"
  set -f
  for _cr_a in $1; do
    _cr_f="$(resolve_commit "$_cr_a")" || continue
    _cr_out="$_cr_out ^$_cr_f"
  done
  set +f
  printf '%s' "$_cr_out"
}

# The kit's own path inside the repo (".pipeline/" for the documented install), or nothing when the kit
# IS the repo or INCLUDE_KIT=1. reconcile.sh excludes the same files from tiering: the kit's own
# files are not the project's work, and `.pipeline/tools/lib/*.sh` matches an ordinary `lib/` rule,
# so following README step 6 (a kit commit of its own) used to list the install commit as T3 work.
coverage_kit_prefix() {
  [ "${INCLUDE_KIT:-}" = 1 ] && return 0
  git -C "$1" rev-parse --show-prefix 2>/dev/null || true
}

# The data directory's path inside the repo ("pdata/") when PIPELINE_DATA points at one, else nothing. Its ledger,
# dashboard and reports are produced by the pipeline itself, so they are not the project's work either; its project/
# directory still is (coverage_scan keeps <prefix>project/ in, as it does for the kit).
coverage_data_prefix() {
  [ -n "${PIPELINE_DATA:-}" ] || return 0
  [ "${INCLUDE_KIT:-}" = 1 ] && return 0
  # Only a data directory in THIS repository has a prefix that means anything here (reconcile.sh applies the same rule).
  _cdp_repo="$(git rev-parse --show-toplevel 2>/dev/null)"
  _cdp_data="$(git -C "$PIPELINE_DATA" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$_cdp_data" ] && [ "$_cdp_data" = "$_cdp_repo" ] || return 0
  git -C "$PIPELINE_DATA" rev-parse --show-prefix 2>/dev/null || true
}

# The raw commit value the ledger claims, verified or not — so a caller can
# tell "no gate ever ran" from "a gate ran on a commit I cannot see."
coverage_claimed_anchor() {
  _cov_ledger="$1"
  [ -f "$_cov_ledger" ] || return 0
  grep '"type":"gate"' "$_cov_ledger" 2>/dev/null | grep -E '"outcome":"(pass|fail)"' | tail -1 \
    | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p'
}

# Tier every commit in a range. Emits one `<tier>\t<short-sha> <subject>` line
# per commit, highest tier that commit touches.
#
#   coverage_scan <surfaces.conf> <range> <max-commits>
#
# ONE git call and ONE awk pass, and that is load-bearing rather than tidy.
# The first working version did the obvious thing — `git show` per commit,
# then a `grep -E` per surfaces.conf rule per commit — and measured 61 SECONDS
# for this kit's own 63 commits: ~24 subprocesses each. On a 5,000-commit repo
# that is over an hour, for a command meant to be run casually. surfaces.conf's
# own TARGET rows predicted exactly this ("Git Bash on Windows... the slow
# one"; "process spawn is cheap [on Linux], so cost bugs hide"). Measured, not
# assumed — and the rewrite's equivalence was proven by re-running the original
# algorithm over every commit and diffing: zero tier mismatches.
#
# Rules are parsed inside awk with the same first-`::`/last-`::` split
# reconcile.sh uses. A regex contains "|" and ":" freely, so field-splitting on
# a single character corrupts it; `match(rest, /^.*::/)` is greedy, which is
# what finds the LAST separator. IGNORE rows are applied first, so a vendored
# or generated path can never raise a tier.
#
# A commit SUBJECT is fully attacker-controlled in a repo with untrusted
# contributors and lands on the marker line this parser keys on. git's `%s`
# strips newlines (later lines of a message are `%b`, not emitted), so a
# subject cannot introduce a line at all, let alone one beginning with \001.
coverage_scan() {
  _cov_conf="$1"; _cov_range="$2"; _cov_max="$3"; _cov_excl="${4:-}"; _cov_excl2="${5:-}"
  [ -f "$_cov_conf" ] || return 0
  _cov_marker="$(printf '\001')"
  # $_cov_range is unquoted on purpose: `A..HEAD`, `HEAD`, or `HEAD ^a ^b` (coverage_range), built
  # from resolved hex shas. set -f keeps a glob character from ever expanding.
  set -f
  # `--` ends the revisions: a committed root file named `HEAD` (or a branch-like name) made git fail
  # with "ambiguous argument", the swallowed error read as "0 unrouted" (G7 round 13).
  # core.quotePath=false: git prints a non-ASCII path as "src/auth/na\303\257ve.go" in quotes, and the
  # anchored rules never matched it (G7 round 26). A name still quoted after that (it holds a quote,
  # a backslash or a tab) loses its wrapping quotes in the awk below.
  git -c core.quotePath=false log --no-merges --no-renames -n "$_cov_max" --name-only --format="%x01%h %s" $_cov_range -- 2>/dev/null \
    | awk -v M="$_cov_marker" -v X="$_cov_excl" -v Y="$_cov_excl2" '
      function flush() { if (have) { printf "%d\t%s\n", top, cur; have = 0 } }
      NR == FNR {
        line = $0
        if (line ~ /^[ \t]*$/ || line ~ /^#/) next
        if (line ~ /^TARGET::/ || line ~ /^ACTION::/) next
        i = index(line, "::"); if (i == 0) next
        tier = substr(line, 1, i - 1)
        rest = substr(line, i + 2)
        if (!match(rest, /^.*::/)) next
        regex = substr(rest, 1, RLENGTH - 2)
        if (regex == "") next
        if (tier == "IGNORE") { ign[++ni] = regex; next }
        tn = (tier == "T4" ? 4 : (tier == "T3" ? 3 : (tier == "T2" ? 2 : (tier == "T1" ? 1 : 0))))
        if (tn == 0) next
        nr_++; rex[nr_] = regex; rtier[nr_] = tn
        next
      }
      substr($0, 1, 1) == M { flush(); cur = substr($0, 2); top = 0; have = 1; next }
      {
        if (!have || $0 == "") next
        if (length($0) > 1 && substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") $0 = substr($0, 2, length($0) - 2)
        # files of the kit itself (coverage_kit_prefix) -- but NOT <kit>/project/: surfaces.conf and the
        # project map are the rules of the project itself, and an edit to them needs a gate.
        if (X != "" && index($0, X) == 1 && index($0, X "project/") != 1) next
        if (Y != "" && index($0, Y) == 1 && index($0, Y "project/") != 1) next
        for (k = 1; k <= ni; k++) if ($0 ~ ign[k]) next
        for (k = 1; k <= nr_; k++) if (rtier[k] > top && $0 ~ rex[k]) top = rtier[k]
      }
      END { flush() }
    ' "$_cov_conf" -
  set +f
}

# Gate ids in the router's matrix with no entry anywhere in the ledger.
# 04-ledger.md: "A gate with no ledger entries did not run." Read through
# matrix.sh so this cannot become a second, drifting copy of the gate list.
# `grep -F` (literal, not a pattern) for the same reason cmd_gates() switched
# to it: a gate id is a key here, never a regex.
coverage_never_run() {
  _cov_ledger="$1"; _cov_kit="$2"
  [ -f "$_cov_kit/tools/lib/matrix.sh" ] || return 0
  # shellcheck disable=SC1090
  . "$_cov_kit/tools/lib/matrix.sh" 2>/dev/null || return 0
  command -v matrix_gates >/dev/null 2>&1 || return 0
  _cov_out=""
  for _cov_g in $(matrix_gates 2>/dev/null); do
    grep -qF "\"gate\":\"$_cov_g\"" "$_cov_ledger" 2>/dev/null \
      || _cov_out="${_cov_out}${_cov_out:+ }$_cov_g"
  done
  printf '%s' "$_cov_out"
}

# E10: where "unrouted" starts when NO gate has ever anchored it. Without this, the
# first status.sh after install listed every pre-install commit as unrouted work and
# exited 1 right after "You are done" -- history the kit had no chance to route.
#
# Prints the commit that first added this kit (so the range is <it>..HEAD), or HEAD
# when the kit is not committed yet (nothing is "since install" until it is), or
# nothing -- the old whole-history behaviour -- when it cannot or should not apply:
# the kit IS the repo (its own development repo), or BASELINE=none. BASELINE=<ref>
# overrides with an explicit starting point.
coverage_baseline() {
  _cb_kit="$1"
  if [ -n "${BASELINE:-}" ]; then
    [ "$BASELINE" = none ] && return 0
    # A hex string (what PIN_WARN tells users to set) is resolved among commit objects, never through a
    # ref name: a tag called like the sha would redirect the cutoff. Anything else is a ref the user
    # named on purpose.
    case "$BASELINE" in
      ''|*[!0-9a-f]*) git rev-parse --verify -q "${BASELINE}^{commit}" 2>/dev/null || true;;
      *)              resolve_commit "$BASELINE" 2>/dev/null || true;;
    esac
    return 0
  fi
  # Both answers come from git itself, so a path alias (an MSYS mount, a symlink) cannot
  # make the kit and the repo look like different places. The kit must live in THIS
  # repo, and not BE its root (the kit's own development repo keeps whole history).
  _cb_ktop="$(git -C "$_cb_kit" rev-parse --show-toplevel 2>/dev/null)" || return 0
  _cb_top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ "$_cb_ktop" = "$_cb_top" ] || return 0
  [ -z "$(git -C "$_cb_kit" rev-parse --show-prefix 2>/dev/null)" ] && return 0
  if [ -z "$(git -C "$_cb_kit" ls-files -- tools/status.sh 2>/dev/null)" ]; then
    # A kit that is git-IGNORED will never be committed: no cutoff (whole history).
    git -C "$_cb_kit" check-ignore -q tools/status.sh 2>/dev/null && return 0
    # Installed but not committed YET. Pin the cutoff the first time anyone asks, in
    # <kit>/.install-base, so it stays where the install was. Returning the CURRENT HEAD
    # each time made the range HEAD..HEAD forever: every later commit was "before the
    # install" and unrouted work was never counted. Once the kit is committed the
    # commit that added it takes over, except that the pin is still used when real work sits between it
    # and the install commit (see the end of this function).
    _cb_pin="$_cb_kit/.install-base"
    # The pin is written ONLY when the file is absent. Anything that already exists there -- an empty
    # file, garbage, uppercase hex, a BOM from a Windows editor, a sha this clone lacks, a directory, a
    # link -- is never replaced with HEAD: that made the range HEAD..HEAD and every unrouted commit
    # vanished, and a pin that could not be written returned the CURRENT HEAD on every call (the
    # moving cutoff). Counting the whole history is the direction that cannot hide work; delete
    # .install-base to pin again.
    if [ -e "$_cb_pin" ] || [ -L "$_cb_pin" ]; then
      # Not a link either: one to a loose ref (.git/refs/heads/main) would read as the CURRENT HEAD on
      # every call, a moving cutoff (G4 round 23).
      [ -L "$_cb_pin" ] && return 0
      [ -f "$_cb_pin" ] || return 0
      _cb_sha="$(tr -d ' \t\r\n' < "$_cb_pin" 2>/dev/null)"
      case "$_cb_sha" in ''|*[!0-9a-f]*) return 0;; esac
      # An ancestor of HEAD only: a hand-edited pin naming HEAD or a later commit would report
      # 0 unrouted. (A pin that merely counts MORE is the safe direction; this one counts less.)
      _cb_pf="$(resolve_commit "$_cb_sha")" || return 0
      [ -n "$_cb_pf" ] || return 0
      if git merge-base --is-ancestor "$_cb_pf" HEAD 2>/dev/null; then
        printf '%s\n' "$_cb_pf"; return 0
      fi
      # A real commit that is NOT an ancestor of HEAD (the project was rebased, or HEAD moved to
      # another line): the cutoff is where the lines meet, or -- with no common history -- everything.
      _cb_mb="$(git merge-base "$_cb_pf" HEAD 2>/dev/null)" && [ -n "$_cb_mb" ] \
        && { printf '%s\n' "$_cb_mb"; return 0; }
      return 0
    fi
    _cb_head="$(git rev-parse --verify -q HEAD 2>/dev/null)" || return 0
    # A pin that cannot be written cannot hold the cutoff: report no cutoff, never the moving HEAD.
    { printf '%s\n' "$_cb_head" > "$_cb_pin"; } 2>/dev/null || return 0
    printf '%s\n' "$_cb_head"
    return 0
  fi
  _cb_ins="$(git -C "$_cb_kit" log --diff-filter=A --format=%H -- tools/status.sh 2>/dev/null | tail -1)"
  [ -n "$_cb_ins" ] || return 0
  # An install commit that ALSO carries project work (adding .pipeline/ in the same commit as the
  # first feature is natural) must be counted, or a trust change in it drops out of "unrouted"
  # (G7 round 8). Then the cutoff is its parent; with no parent the whole history is the answer.
  _cb_prefix="$(git -C "$_cb_kit" rev-parse --show-prefix 2>/dev/null)"
  _cb_outside="$(git diff-tree --no-commit-id --name-only -r --root "$_cb_ins" 2>/dev/null \
                 | awk -v p="$_cb_prefix" 'index($0, p) != 1 { print; exit }')"
  _cb_cut="$_cb_ins"
  if [ -n "$_cb_outside" ]; then
    git rev-parse --verify -q "${_cb_ins}^{commit}" >/dev/null 2>&1 || return 0
    _cb_cut="$(git rev-parse --verify -q "${_cb_ins}^" 2>/dev/null)" || return 0
  fi
  # The kit was checked before it was committed: the pin written then (see above) is the last
  # commit that existed BEFORE the install, and work committed between it and the commit that adds
  # the kit is real, unrouted project work. Without this the pin was dropped the moment the kit was
  # committed and that work silently stopped counting (G6 round 11). Only a pin that is a strict
  # ancestor of the install commit's PARENT is used: a pin equal to the parent is the ordinary case
  # (status run, then the kit committed on its own) and must keep giving "0 since the install", and
  # using it would count the kit's own commit. So the pin can only COUNT MORE, never hide a commit;
  # the one price is that the kit's own commit is counted too when real work sits before it.
  _cb_pin="$_cb_kit/.install-base"
  _cb_par="$(git rev-parse --verify -q "${_cb_ins}^" 2>/dev/null)" || _cb_par=""
  if [ -f "$_cb_pin" ] && [ -n "$_cb_par" ]; then
    _cb_sha="$(tr -d ' \t\r\n' < "$_cb_pin" 2>/dev/null)"
    case "$_cb_sha" in ''|*[!0-9a-f]*) ;; *)
      _cb_full="$(resolve_commit "$_cb_sha")" || _cb_full=""
      if [ -n "$_cb_full" ] && [ "$_cb_full" != "$_cb_par" ] \
         && git merge-base --is-ancestor "$_cb_full" "$_cb_par" 2>/dev/null; then
        printf '%s\n' "$_cb_full"
        return 0
      fi;;
    esac
  fi
  printf '%s\n' "$_cb_cut"
}
