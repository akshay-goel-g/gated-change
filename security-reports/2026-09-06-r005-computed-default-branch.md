# Security review — computed default branch for change_is_branchy / changeIsBranchy (R-005)

Reviewed commit: **`77b5c3207d8542697d8190a7bc0d85aefb0f1a6a`** — G7 · Threat, fresh context,
blind (author's threat assessment and stated purpose withheld; `specs/**` not read). Intent
derived from the diff: retire R-005 by resolving the repo's *actual* default branch from git
and refusing THAT as a `--change` first, keeping the hand-enumerated list as the git-absent
fallback.

Model: `claude-sonnet-5` (strongest available for this account).

## Files in scope

- **`tools/ledger.sh`** — T4 (`project/surfaces.conf` `tools/(reconcile|ledger|…)\.sh$` —
  "Routing and evidence — a wrong answer here is silent and confident"). New
  `resolve_default_branch()` + `DEFAULT_BRANCH` (`:198-218`), new first clause in
  `change_is_branchy()` (`:236`).
- **`tools/dashboard.sh`** — T3 ("Tooling with several callers"). New `_default_branch`
  resolution + `DEFAULT_BRANCH_ID` (`:627-632`), new `"defaultBranch"` model field (`:639`).
- **`tools/dashboard/app.js`** — T1 ("Dashboard assets"), reviewed at depth: new first clause
  in `changeIsBranchy()` (`:169`), `changeIsBranchy` added to `module.exports` (`:2805`).
- **`tests/run.sh`** (T3), **`tests/dashboard-logic.test.js`** (unmatched), **`project/risks.md`**
  (not a trust surface) — assertions / bookkeeping.

Highest tier in the change: **T4** → G7 is a HARD GATE.

`project/surfaces.conf` here is this repo's own answers (`SELF: gated-change`), so these are the
correct boundaries.

## Threat model — who is the untrusted party

Two, both already named by prior reports in this directory:

1. **Whoever influences the git state `dashboard.sh` / `ledger.sh` run against** — new for this
   change. `refs/remotes/origin/HEAD` is set from the remote's advertised HEAD at `git clone`
   and by `git remote set-head`; `init.defaultBranch` is read from *every* config scope
   (system, `$HOME/.gitconfig`, local, worktree, `-c`, and the `GIT_CONFIG_COUNT` /
   `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` environment variables). None of these is chosen by
   the `ledger.sh` invocation.
2. **Whoever supplies a `ledger.jsonl` to the rendered dashboard** (drag-drop / live re-fetch)
   and **the caller of `ledger.sh` / `reconcile.sh`** — the standing boundaries from
   `2026-09-01-dashboard-p0-review-fixes.md` and `2026-09-03-branch-name-pseudo-changes.md`.

## Trust-boundary walk

### 1 · Command / argument injection via the new `git` calls or the `[ ]` test — NO

`resolve_default_branch()` (`ledger.sh:210`) and `dashboard.sh:627-631` interpolate **no caller
input** into their two `git` invocations (`git symbolic-ref --quiet --short
refs/remotes/origin/HEAD`, `git config --get init.defaultBranch`). The *output* flows to:

- `[ -n "$DEFAULT_BRANCH" ]` — 2-arg `test`, `-n` unary, safe for any content.
- `[ "$1" = "$DEFAULT_BRANCH" ]` (`ledger.sh:236`) — 3 arguments to `[`, `$2` is the binary
  `=`; bash's `test` compares as strings regardless of whether either operand looks like an
  operator (`-o`, `!`, `(`, `=`). No word-splitting or globbing (both operands quoted).
- `case "$_default_branch" in origin/?*)` — quoted case subject, not re-parsed.
- `"${ref#origin/}"` / `"${_default_branch#origin/}"`, `printf '%s\n' "$x"` (format string is a
  literal first arg), `json_escape "$x"` (value reaches `sed` on stdin) — all safe.

`init.defaultBranch` config values are arbitrary bytes (git does not validate on read) and
`origin/HEAD`'s target is refname-constrained but still permits `< > | ; & $ ( ) ' "`. Neither
reaches a shell-evaluated position.

### 2 · Does the `defaultBranch` model field land in `<script>` un-escaped — NO

This is the exact class of the 2026-09-01 `KIT_ID` / `VERSION`-quote finding. The fix follows
the house pattern that finding established:

- `DEFAULT_BRANCH_ID="$(json_escape "$_default_branch")"` (`dashboard.sh:632`) — backslash,
  then `"`, then tab/CR, then newline-fold, same order as every sibling `MODEL` value.
- the whole `MODEL` then goes through `escape_payload` → `MODEL_SAFE` (`dashboard.sh:771`),
  which neutralises `</script` and `<!--` case-insensitively (the 2026-09-01 round-2 fix).
- `const PIPELINE = <MODEL_SAFE>;` is a **JS object literal**, so `\"` is a valid string
  escape — no `JSON.parse` strictness issue.

Verified end to end at this sha. `git config init.defaultBranch
'x</script><img src=y onerror=alert(1)>","evilKey":"pwned'`, then `dashboard.sh`:

```
defaultBranch":"x<\/script><img src=y onerror=alert(1)>\"...
raw </script> occurrences in page: 1   (the page's own closing tag)
"evilKey":"pwned" sibling-key occurrences: 0
```

`PIPELINE.defaultBranch` is read in exactly one place — `name === PIPELINE.defaultBranch`
(`app.js:169`) — and is **never** interpolated into `innerHTML` / `textContent`. No DOM sink.

### 3 · `app.js` `typeof` / `&&` guard — no coercion or prototype issue

`if (typeof PIPELINE.defaultBranch === "string" && PIPELINE.defaultBranch && name === PIPELINE.defaultBranch) return true;`

- `typeof … === "string"` — an absent field (older generated page, or the Node unit harness's
  `freshPipeline()`) is `"undefined"` → clause is false → hand-list only. Backward compatible.
- `&& PIPELINE.defaultBranch` — `""` (git resolved nothing) is falsy → hand-list only. This is
  what stops an empty computed value matching every `--change`.
- `name === PIPELINE.defaultBranch` — strict `===`, no property access on `name`, no coercion.
  `changeIsBranchy(undefined)` / `(123)` are false, unchanged from before.

Their two Node tests (`…refuses the computed PIPELINE.defaultBranch…`, `…falls back to the
hand-list only when … absent or empty`) pin exactly these cases.

### 4 · Can the read side suppress a real refusal — NO

`isRoutingArtifact` (`app.js:295`) is tagged only when `changeIsBranchy(change)` **and**
`rounds.every(r => r.gates.length === 0 && r.routes.every(rt => !rt.action))`. A change that
has any gate record is never tagged, so naming the default branch after a real change cannot
hide that change's failing/skipped gates. The `changeIsBranchy` first clause can only *add*
`true` returns, never remove one — `changeIsBranchy('master')` is still `true` via the
unconditional hand-list array. Read-side behaviour is unchanged-or-stronger.

### 5 · Write side for `master` — unchanged-or-stronger

`change_is_branchy()` runs the hand `case` unconditionally after the new early-return; `master`
et al. are still refused whatever `DEFAULT_BRANCH` resolves to. No weakening.

### 6 · `origin/HEAD` / multi-valued config edge cases — no break

- Multi-valued `init.defaultBranch`: `git config --get` returns the **last** value, exit 0
  (verified against local git). Both tools use `--get` → they agree. No crash, no empty, no
  "refuse everything".
- `origin/HEAD` symlinked to `refs/heads/<x>` (not `refs/remotes/origin/*`): `--short` yields
  `<x>` with no `origin/` prefix → both tools fall through to `init.defaultBranch`. Consistent.
- `git symbolic-ref` / `git config` failing (bare repo, no remote, unset config): `ref=""` →
  fallthrough → `DEFAULT_BRANCH=""` → hand-list only. No `set -e`, so non-zero returns are
  inert.

## Findings

### MINOR — the write-side `--change` refusal set is now data-driven from git state an attacker can influence

`tools/ledger.sh:236` (`change_is_branchy` first clause) + `tools/ledger.sh:210-218`
(`resolve_default_branch`).

Before this change the branch-name blocklist was a fixed 8-name list and the 2026-09-03 G7
report cleared it explicitly as *"not adversarially reachable — the `--change` / `CHANGE=`
value is chosen by the operator, not by a hostile input."* This change makes part of the
refusal decision depend on `git config --get init.defaultBranch` and the remote-advertised
`refs/remotes/origin/HEAD` — inputs that are **not** chosen by the `ledger.sh` invocation and
that an attacker can influence by:

- writing any git config scope, including `$HOME/.gitconfig` (global) or via the
  `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` environment variables, or
- controlling the remote's advertised HEAD at `git clone` time.

An actor with one of those and knowledge of a target change's exact name can force
`ledger.sh add --change <name>` and `ledger.sh route --change <name>` (and therefore
`reconcile.sh --log` for that change) to `exit 2` and write nothing — a **targeted hole in the
evidence trail** for that one change. Verified end to end at this sha:

```
$ git config init.defaultBranch 'my-real-feature'
$ ledger.sh add --change my-real-feature --gate G7 --tier T3 --outcome pass --model m
REFUSED: --change 'my-real-feature' is a branch name or placeholder, not a change.
  ... Nothing was written ...
exit=2
$ git config --unset init.defaultBranch      # identical command, no hostile config
logged: G7 (Threat) on my-real-feature — round 1, 0 finding(s), pass
exit=0
```

Bounded, and why it is **minor** not blocking:

- **Loud** — `exit 2` plus a 5-line stderr message; `reconcile.sh --log` surfaces it and exits
  2 (the 2026-09-03 fail-closed change). A developer sees "my change name is a branch name?"
  and stops.
- Needs the **exact** target change name; cannot DoS the whole ledger (no value equals every
  `--change`), cannot touch records already written, cannot alter the read-side rendering of a
  change that has gate records (finding-4 above).
- The same actor generally holds larger levers (config write ⇒ `core.fsmonitor` / alias
  command execution; env control ⇒ `PATH`).
- Directly parallel to the 2026-09-03 report's own **minor** finding (blocklist has no
  override ⇒ trunk-based project gets an audit-trail hole), which passed the gate.

The change's commentary and the R-005 retro name the *"refuses a plausible real change name"*
edge but not this *adversarial-influence* angle — hence a finding rather than silent
inheritance.

### INFO — comment overstates the parallel to `reconcile.sh`'s BASE chain

`tools/ledger.sh:206`, `tools/dashboard.sh:618-619` say the resolution is *"Same … as
tools/reconcile.sh's BASE chain: … origin/HEAD, then init.defaultBranch, then empty."*
`reconcile.sh:312-319`'s BASE chain does **not** consult `init.defaultBranch` — it is
origin/HEAD → origin/main → origin/master → main → master → HEAD~1. The load-bearing half of
the claim ("adds no dependency ledger.sh does not already have") **is** accurate:
`ledger.sh:126` shells to git at load, `detect_commit` (`:380`) per write, and
`reconcile.sh:312` makes the identical `symbolic-ref … refs/remotes/origin/HEAD` call.
Doc imprecision only; no behavioural impact.

### INFO — `defaultBranch` inherits the standing `json_escape` limitations, same as every sibling field

`json_escape` does not touch U+2028 / U+2029 (a JS string-literal break pre-ES2019) or lone
surrogates. This is uniform across `kitCommit`, `note`, coverage rows etc. and was accepted in
prior G7 rounds; `defaultBranch` is no worse. Not a regression.

## T4 boundary check

`tools/ledger.sh` and `tools/reconcile.sh`-class T4 row matched. Walked: a new pure resolver
function, a new first clause in an existing predicate that only ever *adds* refusals, two new
`git` reads that already existed elsewhere in the same file, and one new `json_escape`'d model
field carried through the existing `escape_payload`. **No trust boundary is crossed without a
check.** Privilege on the write side did not grow in capability, but the *set of inputs that
can trigger a refusal* widened to include attacker-influenceable git state — remarked as the
MINOR finding above rather than left implicit.

## Verdict

**PASS.** Injection into `<script>` via `defaultBranch` is defeated by the same
`json_escape` + `escape_payload` combination the 2026-09-01 finding established for
`kitCommit`, verified end to end. No command/argument injection through the two new `git`
calls or the `[ "$1" = "$DEFAULT_BRANCH" ]` test. The `app.js` guard is coercion- and
prototype-safe and backward compatible. The read side cannot suppress a real change's gate
records, and the write side for `master` is unchanged-or-stronger. One **minor** finding: the
write-side refusal is now partly data-driven from `init.defaultBranch` / `origin/HEAD`, so an
actor who can influence git config or the remote's HEAD and knows a change's exact name can
force a targeted, loud, bounded refusal of that change's ledger writes — directly analogous to
the 2026-09-03 minor that also passed. No unresolved finding above minor.

## Findings (structured)

| severity | location | claim |
|---|---|---|
| minor | `tools/ledger.sh:236` (+ `:210-218`) | write-side `--change` refusal now depends on `git config --get init.defaultBranch` / `refs/remotes/origin/HEAD`; an actor with git-config write (incl. global / `GIT_CONFIG_*` env) or remote-HEAD control at clone time, knowing a target change's exact name, can force `ledger.sh add/route --change <name>` to `exit 2` and write nothing — targeted evidence-trail hole. Loud (exit 2 + message, surfaced by `reconcile.sh --log`), bounded (exact name; no whole-ledger DoS; existing records and read-side rendering of changes-with-gates unaffected). Verified: command output in report §Findings. Analogous to the 2026-09-03 minor that passed. |
| info | `tools/ledger.sh:206` / `tools/dashboard.sh:618-619` | comment claims "same resolution as reconcile.sh's BASE chain … then init.defaultBranch"; `reconcile.sh:312-319` BASE chain does not consult `init.defaultBranch`. The "no new git dependency" half is accurate (`ledger.sh:126`, `:380`; `reconcile.sh:312`). Doc-only. |
| info | `tools/dashboard/app.js:169` / `tools/dashboard.sh:632,639` | `defaultBranch` reaches `<script>` only via `json_escape` + whole-MODEL `escape_payload` (the 2026-09-01 `KIT_ID` pattern); never rendered to DOM. Verified end to end: `</script><img>` + `","evilKey":"…` payload emits `<\/script>` + `\"`, 1 raw `</script>` in page, 0 injected keys. Guard is `===`-only, empty/absent field falls through to hand-list. No finding. |
| info | multi-valued `init.defaultBranch` / non-`origin/*` `origin/HEAD` | `git config --get` returns last value exit 0 (verified); both tools use `--get` so they agree; `origin/HEAD`→`refs/heads/x` falls through to `init.defaultBranch` in both. No crash, no "refuse everything". |

## Ledger line

```
ledger.sh add --change r005-computed-default-branch --gate G7 --tier T4 --round 1 \
  --outcome pass --confidence fresh --challenged true --model claude-sonnet-5 \
  --finding "minor::tools/ledger.sh:236::write-side --change refusal now data-driven from git init.defaultBranch / origin/HEAD; attacker who can set git config (incl global / GIT_CONFIG_* env) or remote HEAD at clone time, knowing a change's exact name, can force ledger.sh add/route --change <name> to exit 2 with nothing written — targeted evidence hole; loud + bounded, analogous to 2026-09-03 minor" \
  --finding "info::tools/ledger.sh:206::comment overstates parallel to reconcile.sh BASE chain (which does not consult init.defaultBranch); the no-new-dependency claim is accurate" \
  --finding "info::tools/dashboard/app.js:169::defaultBranch reaches <script> only via json_escape + escape_payload (2026-09-01 KIT_ID pattern), never a DOM sink; injection defeated end-to-end; === guard is coercion/proto-safe and backward compatible"
```

---

# Round 2 — re-verify (fresh context, blind, HARD GATE T4)

Reviewed commit: **`6d97b78a455812b761a00285fe3fec0bf37fd517`**. G7 · Threat, fresh session,
author's threat assessment / stated purpose withheld, `specs/**` + `ledger.jsonl` excluded.
Model: `claude-sonnet-5`. Input: round-2 squashed diff (`patch-blind-r2.diff`),
`project/surfaces.conf`, prior `security-reports/`, current tree.

## What round 2 changed (derived from the diff)

- `resolve_default_branch()` (the `git symbolic-ref refs/remotes/origin/HEAD` +
  `git config --get init.defaultBranch` logic) moved out of an inline block in `ledger.sh`
  and an inline block in `dashboard.sh` into one new file **`tools/lib/default-branch.sh`**,
  now sourced by both (`ledger.sh:207` — `. "$(dirname "${BASH_SOURCE[0]}")/lib/default-branch.sh"`;
  `dashboard.sh:66` — `. "$HERE/lib/default-branch.sh"`).
- `refuse_branchy_change()` (`ledger.sh:232-249`) now branches: when the refused name equals
  the git-resolved `$DEFAULT_BRANCH` it prints *"this repository's default branch, resolved
  from git (origin/HEAD, or init.defaultBranch)"* instead of the generic *"a branch name or
  placeholder"*, plus a new `CHANGE=<name>` hint line for everyone.
- `project/surfaces.conf` +1 T4 row for the new lib; `project/map.md`, `project/risks.md`
  (R-005 rewrite), `tests/run.sh` + `tests/dashboard-logic.test.js` additions.

## Re-verification against the round-2 questions

### 1 · Does the sourced lib change the trust picture — NO

`tools/lib/` **already** holds sourced-not-executed libraries with the identical trust
property: `lib/matrix.sh` (T4) and `lib/coverage.sh` (T4), each `. `-sourced by `ledger.sh`
and `dashboard.sh` one or two lines above the new source line. An attacker who can drop or
edit `tools/lib/default-branch.sh` can equally drop or edit `tools/ledger.sh`,
`tools/lib/matrix.sh`, or `tools/lib/coverage.sh` in the same tree with the same filesystem
access — sourcing runs whatever is at that path in the caller's shell either way. **No code
execution is reachable that editing `ledger.sh` itself did not already give.** The installed
`.pipeline/` copy is the same story: `.pipeline/tools/lib/default-branch.sh` needs the same
write access as `.pipeline/tools/ledger.sh`. Adding one file to the "sourced .sh" set widens
that set by one member; it does not lower the bar to join it.

Source-path resolution: `dirname "${BASH_SOURCE[0]}"` (ledger) / `$HERE` (dashboard) — both
are exactly how each file already resolves `lib/matrix.sh`, so no new `$0`/`BASH_SOURCE`
exposure is introduced that the pre-existing matrix source line did not already carry.

### 2 · `_kit_h` fingerprint picks up the new file — VERIFIED

`_kit_h` is `cat "$KIT"/tools/*.sh "$KIT"/tools/lib/*.sh | cksum` in **all four** places that
compute it — `tools/dashboard.sh:610`, `tools/ledger.sh:291`, `tools/status.sh:338`,
`tools/update-kit.sh:81`. `tools/lib/*.sh` is in every glob, so `tools/lib/default-branch.sh`
is now covered by the kit fingerprint consistently across the dashboard stamp, the per-record
ledger stamp, the `status.sh` readout, and `update-kit`. This is a small *strengthening*: with
the resolution logic in one file instead of two inline copies, a one-sided edit can no longer
make one tool's fingerprint move while the other's stays put.

### 3 · New refusal message interpolating `$1` — no new terminal-escape exposure

The new branch fires only inside `[ "$1" = "$DEFAULT_BRANCH" ]`, so the `$1` it `echo`s is
**byte-identical** to the operator-supplied `--change` value that had to match for the branch
to be taken. `refuse_branchy_change`'s pre-existing `else` branch already `echo`s that same
`$1`. `init.defaultBranch` can carry arbitrary bytes (git does not validate config on read),
so `$DEFAULT_BRANCH` — and therefore the echoed `$1` — can contain ANSI/terminal control
bytes when an attacker controls a git-config scope; but for the message to render, the
operator must already have typed that exact byte sequence as the `--change` argument, i.e.
they already hold the string. No victim sees attacker bytes they had not already supplied.
This is the standing "these tools `echo` git-derived values to a terminal" class (`status.sh`
prints `KIT_ID`, etc.), not a regression. Info only.

### 4 · Is the round-1 minor materially changed — slightly BETTER, mechanism unchanged

Re-reproduced at this sha:

```
$ git config init.defaultBranch 'my-real-feature'
$ ledger.sh add --change my-real-feature --gate G7 --tier T3 --outcome pass --model m
REFUSED: --change 'my-real-feature' is this repository's default branch, resolved from git
  (origin/HEAD, or init.defaultBranch) -- not a change.
  ...
  Nothing was written to <ledger>.
exit=2
```

The DoS mechanism (attacker with git-config write, incl. global `~/.gitconfig` /
`GIT_CONFIG_*` env, or remote-HEAD control at clone time + knowledge of a target change's
exact name ⇒ targeted, loud, bounded refusal of that one change's ledger writes) is
**unchanged** from round 1 — the resolution moved files but returns the same value to the
same comparison. The new message **helps the victim, not the attacker**: it now names
`origin/HEAD` / `init.defaultBranch` as the cause, so a developer hitting a poisoned config
is pointed straight at it rather than left puzzling over "my change name is a branch name?".
Louder = better against a DoS. It **leaks nothing**: the disclosed value is the operator's
own `--change` input echoed back, and "which branch git thinks is default" is something the
same user can read with `git config` / `git symbolic-ref` directly. Round-1 minor stands as
**accepted residue**, marginally improved, still directly analogous to the 2026-09-03 minor
that passed. Not worse.

### 5 · New T4 surface row — CORRECT

`T4::(^|/)tools/lib/default-branch\.sh$::Resolves the repo's default branch — decides which
--change names ledger.sh refuses, and read by the dashboard too`. Tier matches its siblings
`lib/matrix.sh` and `lib/coverage.sh` (both T4) and is justified on its own terms: a wrong
answer here either refuses a real change (loud) or fails to refuse a branchy `--change`
(silent evidence-trail pollution — the R-005 failure). The `(^|/)…$` anchor matches both
`tools/lib/default-branch.sh` and the installed `.pipeline/tools/lib/default-branch.sh`.

### 6 · `<script>` injection defence for `defaultBranch` — STILL HOLDS

The bake path is textually unchanged from round 1: `dashboard.sh:630`
`DEFAULT_BRANCH_ID="$(json_escape "$(resolve_default_branch)")"` → `json_escape`
(`:403-407`: `\`→`\\`, `"`→`\"`, tab, CR, newline-fold) → `"defaultBranch":"$DEFAULT_BRANCH_ID"`
in `MODEL` (`:637`) → `MODEL_SAFE=$(escape_payload "$MODEL")` (`:769`; neutralises
`</script`, `<!--` case-insensitively) → `printf '%s' "$MODEL_SAFE"` into `const PIPELINE =`
(`:826`). `resolve_default_branch()` returns the same bytes the round-1 inline code did to
the same `json_escape` call, so round-1's end-to-end verification (payload
`x</script><img …>","evilKey":"pwned` → `<\/script>` + `\"`, 1 raw `</script>`, 0 injected
keys) still applies. `app.js` guard (`:169`) unchanged: `typeof === "string" &&
PIPELINE.defaultBranch && name === PIPELINE.defaultBranch` — absent/empty falls through to
the hand-list, strict `===`, no DOM sink.
Live check (after retrying past this Windows Git-Bash box's `fork: Resource temporarily
unavailable` process-table exhaustion — R-003 territory, not a defect in the change):
`git config init.defaultBranch 'prodX</script>"evil'`, then `dashboard.sh --print-model`
emits `"defaultBranch":"prodX</script>\"evil",` — `json_escape` has turned the `"` into `\"`
(no sibling-key injection into `PIPELINE`), and the raw `</script>` here is harmless because
`--print-model` prints `$MODEL` directly (not HTML); the *page* path (`assemble_html`) runs
`escape_payload "$MODEL"` first, which is what turns `</script>` into `<\/script>` — the
round-1-verified behaviour, unchanged.

### 7 · Round-2 test additions — nothing lets a hostile fixture through

The new bash tests (`test_ledger_refuses_the_computed_default_branch_*`,
`test_default_branch_resolution_is_a_single_sourced_lib`,
`test_ledger_default_branch_resolution_prefers_origin_head`, the fallback tests) build real
git state with `git update-ref` / `symbolic-ref` / `config` and assert refusals; none parse
untrusted ledger content or feed a crafted payload that could pass unescaped. The
fallback tests correctly pin `init.defaultBranch ""` locally to shadow a stray global. The
JS tests exercise only benign `'prod'`. **Gap (info):** no round-2 test pins the
`</script>` / quote *escaping* of `defaultBranch` specifically — the JS tests set only
`'prod'` and the bash tests assert only `"defaultBranch":"prod"`; the escaping is covered
transitively by the KIT_ID `escape_payload` tests and round-1's manual check, but a dedicated
regression like the `KIT_ID` quote test would be worth adding (G5).

## Findings (round 2)

| severity | location | claim |
|---|---|---|
| minor (residue) | `tools/ledger.sh:226` (+ `tools/lib/default-branch.sh:55-62`) | Round-1 minor **unchanged in mechanism, marginally improved in diagnosability**. Attacker with git-config write (incl. global / `GIT_CONFIG_*` env) or remote-HEAD control at clone + exact target change name ⇒ forces `ledger.sh add/route/escape/assume --change <name>` to `exit 2`, nothing written — targeted evidence-trail hole. Re-reproduced at `6d97b78`. Loud (`exit 2` + message, surfaced by `reconcile.sh --log`), bounded (exact name, no whole-ledger DoS, existing records and changes-with-gates untouched). New message names `origin/HEAD`/`init.defaultBranch` as the cause — helps the victim diagnose, leaks nothing (operator's own input echoed back). Accepted as residue, as in round 1; analogous to the 2026-09-03 minor that passed. |
| info | `tools/lib/default-branch.sh` (whole file) / `surfaces.conf:30` | Moving `resolve_default_branch()` into a sourced lib does not change the trust picture: `tools/lib/` already holds `. `-sourced T4 libs (`matrix.sh`, `coverage.sh`); writing `tools/lib/default-branch.sh` (or its `.pipeline/` copy) needs the same access as writing `ledger.sh` itself — no new code-exec path. `_kit_h` globs `tools/lib/*.sh` in all 4 computations (`dashboard.sh:610`, `ledger.sh:291`, `status.sh:338`, `update-kit.sh:81`) so the new file is fingerprinted consistently — a small strengthening over two inline copies. T4 row correct, tier consistent with siblings, anchor matches the installed path. |
| info | `tools/ledger.sh:238` | New refusal message `echo`s `$1`, which in that branch is byte-identical to `$DEFAULT_BRANCH` (an `init.defaultBranch` value can carry terminal control bytes). No new terminal-escape exposure: the branch fires only when the operator already supplied that exact byte sequence as `--change`, and the sibling `else` branch already `echo`s the same `$1`. Standing "these tools echo git-derived values to a terminal" class, not a regression. |
| info | `tools/dashboard/app.js:169` / `tools/dashboard.sh:630,637,769` | `<script>` injection defence for `defaultBranch` unchanged from round 1 — same `json_escape` + whole-`MODEL` `escape_payload` chain, `resolve_default_branch()` returns the same bytes to the same call. Round-1 end-to-end verification still applies. Live re-run blocked by Git-Bash `fork` exhaustion (environment, not the change). |
| info | `tests/dashboard-logic.test.js:295-323` / `tests/run.sh` | Round-2 tests build real git state and assert refusals; none feed a crafted unescaped payload. No dedicated regression pins `defaultBranch`'s `</script>`/quote escaping (JS tests use only `'prod'`, bash asserts only `"defaultBranch":"prod"`) — covered transitively, but a `KIT_ID`-style quote test is worth adding (G5). |

## Verdict — round 2

**PASS** (hard gate, T4). The round-2 changes are a refactor (shared lib, matching
`matrix.sh`/`coverage.sh`) plus a strictly-more-informative refusal message. No new trust
boundary is crossed; no privilege grew; the `<script>` injection defence is byte-for-byte the
round-1 defence. The round-1 minor is **unchanged in mechanism and slightly better in
diagnosability** — accepted as residue exactly as in round 1. No unresolved finding above the
pre-existing minor.

**challenged_premise: false** (round 1 already recorded the challenge that produced the minor;
round 2's deltas are net-neutral-to-positive and I concur with them).

## Ledger line — round 2

```
ledger.sh add --change r005-computed-default-branch --gate G7 --tier T4 --round 2 \
  --outcome pass --confidence fresh --challenged false --model claude-sonnet-5 \
  --finding "minor::tools/ledger.sh:226::round-1 minor unchanged in mechanism, better in diagnosability: attacker with git-config write (incl global / GIT_CONFIG_* env) or remote-HEAD control + exact change name forces ledger.sh add/route/escape/assume --change <name> to exit 2 with nothing written; re-reproduced at 6d97b78; loud + bounded; new message names origin/HEAD / init.defaultBranch as cause (helps victim, leaks nothing); accepted residue, analogous to 2026-09-03 minor" \
  --finding "info::tools/lib/default-branch.sh::sourced lib does not change the trust picture — tools/lib/ already holds sourced T4 libs (matrix.sh, coverage.sh); writing the new file needs the same access as writing ledger.sh; _kit_h globs tools/lib/*.sh in all 4 computations so the file is fingerprinted consistently; T4 surface row correct" \
  --finding "info::tools/ledger.sh:238::new refusal message echoes \$1 which equals \$DEFAULT_BRANCH (init.defaultBranch = arbitrary bytes) but is byte-identical to the operator-supplied --change value; no new terminal-escape exposure beyond the sibling else branch" \
  --finding "info::tools/dashboard/app.js:169::defaultBranch <script> injection defence unchanged from round 1 (json_escape + whole-MODEL escape_payload); resolve_default_branch returns same bytes to same call; round-1 end-to-end verification still applies" \
  --finding "info::tests/dashboard-logic.test.js:295::no round-2 regression pins defaultBranch </script>/quote escaping (tests use only benign 'prod'); covered transitively, a KIT_ID-style quote test is worth adding (G5)"
```

---

## Round 3 — close-out (no threat re-review needed)

Round 3 changed only:

- `tests/run.sh` (T3) — strengthened `test_default_branch_resolution_is_a_single_sourced_lib`
  (both resolution halves must live only in the lib) and added
  `test_dashboard_default_branch_hostile_value_is_escaped_in_the_page`, which pins the
  `<script>`/quote escaping G7 verified by hand at round 2 — this is now a regression test,
  addressing the round-2 `info` finding directly.
- `project/risks.md`, `project/map.md`, `INTENT-LOG.md`, `LEARNINGS.md`, `SESSION-HANDOFF.md`,
  `specs/.../requirements.md`, `ledger.jsonl` — docs and evidence.

**The trust-boundary files this report reviews — `tools/ledger.sh` and
`tools/lib/default-branch.sh` — are byte-identical between `d71962f` (the round-2 code
commit, tree reviewed as `6d97b78` above) and the branch tip.** Verified:
`git diff d71962f..HEAD -- tools/ledger.sh tools/lib/default-branch.sh` is empty. Round 3
introduces no adversarial surface; the round-2 **PASS** stands for the landed tip.

## Pre-push `--no-verify`

The pre-push hook checks `git rev-parse HEAD` (the pushed tip) against the shas named in
this report. The tip is the commit that *adds this section* plus the round-3 doc/ledger
commits — none of which touch a T4 file — so the hook cannot find the tip sha here (it would
be circular to add it). The push uses `git push --no-verify`; the exception is recorded in
the ledger as a G7 `skipped` at round 3 with this reasoning, per the hook's own instruction.
