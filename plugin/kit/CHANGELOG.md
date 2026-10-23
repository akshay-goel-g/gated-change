# Changelog

Every release has three sections, and the third is the one that matters:

- **Fixed** — defects in portable code. You get these by upgrading; nothing to do.
- **Added** — new capability. Optional unless you want it.
- **Action required** — things you hold a **copy** of. The kit cannot reach into your
  `.git/hooks/pre-push` or your `CLAUDE.md`, so an improvement there is inert until you
  re-copy it. If a release has no such changes the section says so explicitly, rather
  than being omitted — an absent section is indistinguishable from an overlooked one.

Versioning, for this product specifically:

| | Means |
|---|---|
| **MAJOR** | a `project/` format change needing a migration · a gate id removed or renamed · a ledger field whose meaning changes |
| **MINOR** | a new gate · a new tool · a new optional config row · a new ledger field |
| **PATCH** | a tool bug fix · a doc fix · a rule anchored more precisely |

**The ledger is append-only forever.** Fields may be added, never renamed or removed, and
readers must tolerate absent fields — a line written by 1.0.0 has to stay readable by every
later version. It is the one artifact a user can never regenerate.

---

## Unreleased

Compliance and install-path correctness (ACTION-PLAN E1-E11). Reviewed by six fresh-context
gates over thirteen rounds (no round has yet had all six pass); the findings drove several
redesigns, recorded in `ledger.jsonl`.

### Added

- **`PIPELINE_DATA`: data apart from code (ACTION-PLAN D5).** One environment variable names the directory that holds
  `project/`, `ledger.jsonl`, `dashboard.html` and `security-reports/`, separately from the kit's code. Unset, it is the
  kit's own directory and nothing changes. `ledger.sh`, `status.sh`, `reconcile.sh`, `dashboard.sh`, `mine-registry.sh`,
  both installers, the R0c and Stop hooks and the pre-push template all read it. This is what lets a plugin keep its
  (shared, read-only) code apart from each project's files. Kit-location and git-history logic in `status.sh` is
  unchanged and still assumes the kit is inside the project repository. `PIPELINE_DATA` must be an absolute directory
  inside the repository being worked on (`tools/lib/data-root.sh`; `PIPELINE_DATA_EXTERNAL=1` waives that): these files
  are trust configuration, and a value left over from another project is refused instead of obeyed. The installers
  bake the value into the pre-push hook and the Claude Code hook commands. The data directory is excluded from
  reconcile and coverage tiering, as the kit's own files are. Found by the D1/D2/D5 gate round (change
  `multi-surface-d1-d2-d5`), which also made G2, G3 and G8 agent tool lists explicit and fixed the dashboard's
  cwd-relative defaults and the pre-push dashboard comparison under an absolute data path.

  Round 3 of that gate: the pre-push hook now exports its baked `PIPELINE_DATA` to the `dashboard.sh` it runs (it
  committed a coverage panel from the kit-side surfaces before); the data directory is excluded from tiering only when
  it is inside this repository (a foreign `PIPELINE_DATA_EXTERNAL=1` directory's `src/` prefix once swallowed this
  repo's `src/auth`), and reconcile says so in a Note; `install-claude-hook.sh` refuses a re-run with a different
  `PIPELINE_DATA` instead of adding a second entry; `status.sh` reports the data directory baked into the hook; a
  trailing slash no longer makes `install-hook.sh` see a different hook; the hook's inline check refuses the same
  characters as `data-root.sh`. **Narrowed, not widened:** the gate agents are no longer all "read-only". Only G1 and G3
  are; G2, G4-G7 carry a `tools:` list that includes Bash or the web tools, and G8 uses a `disallowedTools` denylist,
  which grants every tool not named, including any added to Claude Code later. Model IDs in `project/models.conf` are
  kept in one place with a "checked <date>" each, but whether they are current cannot be verified offline.

- **Gate subagents and a model map (ACTION-PLAN D1, D2).** `templates/agents/pipeline-gate-g1..g8.md`
  (also in `.claude/agents/` for the kit itself): one Claude Code subagent per gate with `omitClaudeMd`,
  a tool list per gate, the model of its tier, and the card's own `withhold:` line. `project/models.conf`
  maps the card tiers to model IDs; `core/schemas/findings.schema.json` describes the findings a gate
  returns, in the vocabulary `ledger.sh add --finding` already enforces. Tests keep the agents, cards,
  `models.conf` and schema in step. Not yet run as live gates.

- **Ledger tamper-evidence (ACTION-PLAN C3).** Every new record ends with `"prev"`, the sha256 of the line before it, and
  `ledger.sh verify` walks the chain: an edited, deleted or inserted line is a BREAK (exit 1), two branches concatenated
  after a merge are a BREAK unless you say `--allow-joins` (a record inserted with a correct link looks the same), older lines are the unchained prefix. A rewritten or truncated tail is only visible
  against a pinned head (`verify --expect-head <hash>`), and a ledger with every `prev` stripped only against git
  (`verify --against <rev>`: the ledger committed there must be an exact prefix of this one). A JOIN must be an unbroken
  run from the fork, so a forged or edited record cannot pass as one. An unchained record after the chain began (a branch
  cut before this change, an older kit copy) is a permanent BREAK: **Action required** is to re-append such records with the current kit. Nothing is required of existing ledgers; new records simply start
  the chain. Writers are serialised with a lock directory (`<ledger>.lock`, waits `LEDGER_LOCK_WAIT` seconds, default 150, then refuses and names the `rmdir` remedy; a lock older than two minutes is broken) so parallel gate runs chain correctly. Plain `verify` prints that it is unpinned and unanchored. The chain authenticates order, not authors: a forged record appended at the tail reads as a normal append (an exact copy of an existing record is a BREAK). Run `verify` in CI and before a release. The chain does not stop someone who recomputes every hash, and the record's own `kit` field is still a CRC.
- **Stop hook (ACTION-PLAN C2).** `install-claude-hook.sh` now also registers `tools/hooks/stop-compliance.sh` as a
  Claude Code `Stop` hook. When the ledger's latest route is T3/T4 and `ledger.sh compliance` for it fails, the session
  cannot end: the hook returns a block with the unmet gates. Once per stop (`stop_hook_active`), at most 3 times for an
  unchanged state, fail-open on anything it cannot establish, off with `PIPELINE_STOP_HOOK=off`. **Action required
  (existing installs):** re-run `bash .pipeline/tools/install-claude-hook.sh` to add the hook to `.claude/settings.json`.
  Tests: `bash tests/stop-hook-e2e.sh`.
- **Gate evidence (ACTION-PLAN C1).** `ledger.sh add` now refuses a *fresh* T3/T4 `pass` that cites nothing. Accepted:
  a finding with a location (an `info` finding is the form for "checked, holds"), `--evidence file:line`, or
  `--evidence-cmd EVIDENCE::<name>`, which runs a line declared in `project/commands.conf`, records the exit code, a
  sha256 of the output and a sha256 of the conf line, and refuses a `pass` when the command fails or the line is `MANUAL`.
  `project/commands.conf` is a T4 surface in this repository (the shipped `templates/project/surfaces.conf` carries the row commented
  out: `<kit>/project/` is the adopter's own, so an active row would list the install commit as unrouted T4 work). Write-time only: older lines are not re-judged, and a hand-edited ledger
  still bypasses it (ACTION-PLAN C3). A citation must name an existing file and a line within it; an untiered fresh pass
  is held to the same rule; an `EVIDENCE::` command must print something and `commands.conf` must be committed.
  Known limits (accepted, ACTION-PLAN C3 and later): a citation proves a real file and line exist, not that they are relevant,
  and it may be an untracked file; an `EVIDENCE::` command is checked against HEAD for `commands.conf` only, so the files it runs
  (`tests/run.sh` and the like) may be uncommitted when it runs; the hash is of the output with trailing newlines trimmed.
  Existing installs keep their own `project/commands.conf` (no `EVIDENCE::` lines) until they add some.
  **Action required (existing installs):** `update-kit` does not touch `project/`. To use `--evidence-cmd`, add `EVIDENCE::<name>::<command>`
  lines to your `project/commands.conf` and commit it; to make that file a T4 surface (optional; uncomment the row in the shipped template), add
  `T4::(^|/)project/commands\.conf$::What a gate may run as evidence` to your `project/surfaces.conf`. `--evidence file:line`
  and `info` findings work without either. Gate runs of a fresh T3/T4 pass that cite nothing are now refused: update any script that logs one.

### Changed

- **Relicensed from AGPL-3.0 to PolyForm Shield 1.0.0** (source-available; use in your own
  projects, no competing product). Basis: no third party held a copy under the AGPL.
  `LICENSE` is the verbatim 1.0.0 text; `NOTICE` carries the `Required Notice:` line.

### Fixed

- **`ledger.sh` default no longer depends on the current directory (D5).** `ledger.sh add` run from a subdirectory of an
  installed project wrote `<subdir>/.pipeline/ledger.jsonl`, while `status.sh` and the Stop hook read
  `<project>/.pipeline/ledger.jsonl`. The default is now `$PIPELINE_DATA/ledger.jsonl`, one absolute path (the kit's
  directory when unset). A kit vendored somewhere other than `.pipeline/` now writes inside itself, as its `status.sh`
  always read.

- **Small quality fixes (ACTION-PLAN B1-B6).**
  - *B1* The 25 macOS CI failures were test-harness portability in `tests/run.sh` (GNU `sed -i EXPR FILE`, padded `wc -w`), not product bugs; the tests now use portable helpers. Confirm on a real macOS run.
  - *B2* The R0c edit hook matched the ABSOLUTE path against repo-relative rules, so a file in another project's `auth/`, or any file of a repository checked out under a directory called `core/`, tripped a rule. It now decides membership by directory identity and matches the path relative to the repo root; files outside the repository are ignored.
  - *B3* `install-hook.sh` compared the template with the installed copy (whose `PIPELINE_DIR` it had rewritten), so a re-run said "a different hook exists" for any kit not at `.pipeline/`. It now compares what would be installed.
  - *B4* `ledger.sh escape` matched the change name as a regex (`a.b` found gate runs logged for `aXb`); it is a fixed-string match on the escaped name now.
  - *B5* CI pins `actions/checkout` to a commit (v4.4.0), and a test keeps every action pinned.
  - *B6* `status.sh` reports, advisory only, when `project/registry.md`, `project/map.md` or the mined draft is `REGISTRY_STALE_COMMITS` (default 100, 0 = off) or more commits behind HEAD; `mine-registry.sh` stamps the commit it ran at. **Action required (existing installs):** none; `update-kit.sh` brings all of B2-B4 and B6 (they are in `tools/`).

- **One-time text scrub of `ledger.jsonl` for publication (an exception to "append-only; supersede, never edit").**
  Eight existing lines had the name of a retired third-party vendor in their free-text `note` / `claim` fields;
  those words were reworded. No other field of any row
  was touched (`commit`, `base`, `round`, `outcome`, `tier`, `gate`, `change`, ids and dates are as written) and
  line endings are unchanged; the lines are 13, 24, 28, 29, 30, 58, 61 and 423 as of the commit that carries this
  note. `dashboard.html` was regenerated from the ledger.
- **Round 29 (findings of the round-28 reviews).** The default base is now an EXACT ref: `rev-parse --verify
  refs/remotes/origin/main` falls back to git's name search when that ref is missing and finds a TAG of that
  full name (a plain `git fetch` delivers one), so a tag could pick the base the pre-push hook and
  `reconcile.sh` diff against. Both now use `git show-ref --verify` and hand git the object id; a dangling
  `origin/HEAD` target makes `reconcile.sh` refuse ("Cannot compare") and makes the hook fall through to
  `origin/main`/`origin/master`, then to the empty tree. `ledger.sh` escapes EVERY control byte below 0x20 (a
  pasted ESC made a line the dashboard rejected and `compliance` read), starts a new line when the ledger does
  not end in a newline (a record glued behind a PASS made a FAIL invisible), and escapes change names in the
  defaulted-assumption and kit-build searches. **Action required:** the pre-push fix is in the hook COPY in
  `.git/hooks/`; re-run `bash tools/install-hook.sh --force`. **Not fixed, recorded as findings:** the
  ledger default path depends on the working directory, the hook's zero sha and empty tree are sha1 only,
  `dashboard.sh`/`ledger.sh` do not fail when `coverage.sh`/`default-branch.sh` are missing, `$_LEDGER_SH` is
  unquoted in `reconcile.sh`, and `install-hook.sh` hard-codes `.pipeline/` in a message.
- **Declared actions can fire again, each as its own event, whatever the base.** `reconcile.sh --action NAME ...`
  a second time used to be refused (base moved) or silently continued the first firing's lineage (same base:
  a redeploy of the same HEAD, or a fix committed before pushing). Every firing after the first on a change now
  starts its own lineage (when its route carries a base: `reconcile.sh --log` sends one whenever git finds a
  merge-base), so the gate results logged for the previous firing read NOT RUN for the new one. A
  repeat firing is always recorded as round 1 (an event is not a round of work), so `ROUND=2` on it no longer
  lets the first event's passes carry forward. The first firing on a change with only diff routes keeps its round.
- **A pass that clears a FAIL must be bound to the change.** `compliance` checked the commit of the highest-round
  pass, so a round-1 pass logged last on an unrelated commit cleared a round-2 fail unchecked; it now also checks
  the pass(es) logged after the last fail (any one bound pass clears it), and the highest-round pass must stay
  bound too. The first declared-action firing on a change with no routes is recorded as round 1, so a repeat
  firing always finds a round-1 route to restart from. A repeat firing WITH a base now carries the restart marker
  whatever routes the change has (a first firing kept at round 2, or an advisory route with no base, used to
  leave none), an explicit `--restart-lineage` is no longer dropped silently when the change has no round-1
  route with a base, and a restart-marked route WITH a base starts a lineage even when it is the only round-1 route; the dashboard
  mirrors it. A route with no base never starts a lineage (it used to be able to lower the tier floor).
- **Round 20 (findings of the round-19 reviews).** `--restart-lineage` given with a stale `--round` is now
  recorded as round 1 with a note, instead of being dropped silently while the old lineage's passes kept
  counting; on a change with no route it says there is nothing to restart. `--base` is stored (and compared)
  as the full sha, so an abbreviated spelling of the same commit is the same base (rows written earlier
  with an abbreviation still read as the same base). A restart is round 1 whether or not an `--action` is
  given. The pre-push hook blocks when a T4 row of `surfaces.conf` is not a valid regular expression (it
  used to read the grep error as "no trust file changed"), and a T4 row starting with `-` is matched as a
  pattern. Coverage: a root file named `HEAD` no longer reads as "0 unrouted" (scan, counts and the orphan
  filter); the install pin is written only when the file is absent and is never overwritten with HEAD: a pin
  that is a commit but not an ancestor uses the merge-base, anything else (empty, garbage, a sha this clone
  lacks, a directory, a pin that cannot be written) counts the whole history and is left alone, and
  `status.sh` says how to get out; the dashboard's staleness check is a membership test over all anchors;
  edits under `<kit>/project/` are counted as project work by both `status.sh` and `reconcile.sh`;
  anchors must be hex. **Not fixed, recorded as R-009 (9)-(12):** a force push is judged by what it adds,
  not by the trust-boundary commits it discards; `surfaces.conf` is not a guarded path; the kit's own files
  are not in the unrouted list; the install cutoff can be steered by a merge resolution.
- **A stored commit string never reaches git through a ref name.** `compliance`, `status.sh`, the dashboard
  and `check-refs.sh` resolved the short shas the ledger stores with `git rev-parse <sha>^{commit}` and
  friends, which read a ref name of the same spelling first: anyone able to push a tag could turn an
  UNBOUND pass into a PASS, move the upper bound through the route's own stored commit, or move the
  "unrouted" anchor and range. Every kit tool (`ledger.sh`, `status.sh`, `coverage.sh`, the dashboard,
  `check-refs.sh`) goes through `resolve_commit` (`tools/lib/commit.sh`) now: objects only, exactly one
  commit, a FULL annotated-tag id is peeled (an abbreviated one is not a commit: it is refused), more than a
  full sha is refused, and a stored value that does not resolve is "cannot be checked" and never passed on
  raw. The pre-push hook is the exception: it has its own prefix guard (R-009 (4)). Needs git 1.7.9+
  (`rev-parse --disambiguate`); `--show-object-format` (2.38+) is only asked to tell sha256 repositories
  apart, and an older git is read as sha1. The pre-push hook uses
  `printf`, not `echo`, for the changed-file list (dash's `echo` interprets `\c`: a file named `0\c`
  switched the trust check off).
- **Round 26 (findings of the round-25 reviews).** The default base is named by full ref
  (`refs/remotes/origin/main`, `refs/heads/main`...) in `reconcile.sh` and the pre-push hook, so a tag called
  `main` cannot move it to HEAD. `tools/lib/commit.sh` and `tools/check-refs.sh` are routed surfaces (T4, T3).
  A hex `BASELINE` goes through `resolve_commit`. `ledger.sh add --commit` refuses anything that is not
  exactly one commit (a tree, 3 or 41 hex characters, an ambiguous prefix) and stores the full sha, as
  does the default (it stored 7 characters). A prefix two commits share reads UNBOUND, not "cannot be
  checked". A missing `lib/commit.sh` stops `ledger.sh`, `status.sh` and `check-refs.sh` with exit 2
  (it used to leave every gate PASS). A recorded base that does not resolve is reported as such, not as
  "predates --base". The object format is read once per repository, when `lib/commit.sh` is sourced (a
  cache filled inside a `$( )` was thrown away with the subshell, so `status.sh` saw no saving).
  Round 27 (findings of the round-26 reviews): a non-ASCII path (git prints it quoted) is tiered by
  `reconcile.sh` and counted by `status.sh`/the dashboard; `reconcile.sh` refuses (exit 2) when `BASE...HEAD`
  has no merge base (an orphan branch, a shallow clone, a mistyped `BASE`, a stale `origin/HEAD`) instead of
  reading the empty answer as "no committed changes"; logging before the first commit works again
  (`detect_commit` wrote the word `HEAD`); `route` and `assume` validate `--commit` like `add` does, through
  one function, and an explicit empty `--commit` is refused where a commit exists. **Not fixed, recorded
  as R-009 (13):** a T4 file added only inside a merge commit's resolution is not in the unrouted list.
  Round 28 (round-27 reviews): with a guessed base and a single commit, `reconcile.sh` tiers that commit
  (against git's empty tree) instead of only the working tree; run from a subdirectory it lists untracked
  files repo-wide and root-relative (it listed only the current directory's, relative to it, so anchored
  rules missed them); `check-refs.sh --dir` checks a note whose name contains a space (it was skipped, and
  its stale claims passed). `dashboard.sh` also exits 2 and writes no page when `lib/commit.sh` is missing
  (it used to write the page with a null coverage panel). `reconcile.sh` exits 2 with "Cannot compare" when
  the base shares no history with HEAD, and `--allow-empty` does not bypass it: a wrapper on a shallow CI
  checkout that got 0 before now needs a `BASE` the checkout contains. **Not fixed, recorded as R-009
  (14):** a submodule marked `ignore = all` hides its changes from the file lists the kit builds.
- **A later `n/a` or `skipped` cannot clear a FAIL on a gate that never passed,** and the dashboard orders
  "after" by ledger position like `compliance` does (it ordered by round).
- **A fail is "after" a pass by position in the ledger, not round number.** A fail logged with `--round`
  forgotten (it defaults to 1) below an earlier round-2 pass was ignored and the gate read PASS.
- **`skipped` and `n/a` gate rows no longer anchor "unrouted work".** Logging one used to make an
  unreviewed T4 commit vanish from `status.sh` and the dashboard. Only pass and fail rows are verdicts.
- **Work committed between the first `status.sh` and the kit's own commit still counts** (the cutoff pin was
  dropped once the kit was committed).
- **Two branches each gated and then merged are both anchors.** `status.sh` and the dashboard count what is
  not contained in ANY gated tip (they used to refuse to pick one and list every gated commit as unrouted,
  exit 1, with a false "not found in this repo"). Gated commits that exist but are not reachable from where
  you are (squash or rebase merge, another branch) are described as that.
- **The kit's own files are not project work in `status.sh`** (a kit commit of its own was listed as T3
  because `.pipeline/tools/lib/*.sh` matches a `lib/` rule; `INCLUDE_KIT=1` brings them back, as for
  `reconcile.sh`). An unresolved `BASELINE=<ref>` is reported instead of silently ignored. The
  `.install-base` pin is only used when it is an ancestor of HEAD and is never written through a symlink.
- **Pre-push**: a hex-named tag or branch no longer counts as review evidence for a commit; file names keep
  leading/trailing whitespace; a failure to list a range's files now blocks instead of passing it; trust
  files are looked up with literal pathspecs.
- **`compliance` let an earlier PASS hide a later blocking FAIL** (round 2 passing at exit 0).
  A `fail` logged after the latest pass now voids it until the gate re-runs to a pass; nothing
  logged after that fail except a pass changes that -- a `skipped` after the fail does not bring
  the old pass back. A `skipped` after a *pass* does not void it: it records an exception (the
  pre-push override advice logs one), and treating that as a failure re-failed released changes.
- **`compliance --tier` was taken on trust.** `--tier T1` on a change reconciled as T4 mandated
  nothing and exited 0. It is now refused (exit 2) against the tier `reconcile.sh` recorded;
  within the current lineage the floor is the HIGHEST tier `reconcile.sh` recorded (a later round
  re-diffed against a moved base sees only the newest edit, and a narrower diff is not a smaller
  change); a real downgrade is a deliberate new round-1 reconcile with a different base, which starts a
  new lineage and now needs `--restart-lineage` (below).
  A bare hand-typed `ledger.sh route --actual T1` (no `--base`) cannot lower it.
- **Gate records were not tied to the change.** Passes logged before the change existed, or on
  a sibling branch, satisfied it. `reconcile.sh` now records where the change started
  (`base`, write-once per lineage: round 1 records it, rounds 2+ keep it, a round-1 route
  starts a new lineage); compliance reports `UNBOUND` for a pass outside that base and the
  change's tips. A pass logged AT the base still counts (pre-build G1 lands there and cannot
  be told apart). A pass whose commit cannot be checked here (no base recorded, or not in this
  clone) is counted with a NOTE and a summary line -- the exit code alone cannot tell you.
- **Pre-push re-blocked after committing the report.** The hook now requires a report to name
  a commit that CONTAINS every trust-touching commit in the push (merge edits judged with
  `diff-tree -c` plus a check that the merge produced what a correct merge of its parents would,
  so a merge that quietly reverts a change already on the remote counts as trust-touching), not
  `HEAD`; a reviewed branch merged with `--no-ff` passes. The hook now FAILS CLOSED when git
  cannot diff the push (the remote's commit is not in your clone: `git fetch`), and sees trust
  files with non-ASCII names. The hook also
  ignores SIGPIPE: `git push 2>&1 | head` used to kill it before `exit 1` on Git for Windows,
  which git reads as success, so the push went through after printing BLOCKED.
- `update-kit.sh` said "Already current" when only `core/` or `templates/` changed; it now
  also compares a checksum of every portable file.
- `mine-registry.sh` wrote to `./project/` at the repo root; `status.sh` listed all
  pre-install history as unrouted right after install; `reconcile.sh` ignored unknown flags and
  `--round`; `ledger.sh escape` accepted any `--found-by`; `--commit` accepted non-hex text.

### Added

- A `base` field on `route` records (new optional ledger field; absent on older lines, which
  skip binding with a NOTE) and `ledger.sh route --base <sha>`.
- `reconcile.sh --round <n>`; `BASELINE=<ref>|none` for `status.sh`/`dashboard.sh`; a README
  step 6 (commit `.pipeline/`, work on a branch); `ledger.jsonl` is committed and is NOT union-merged (risk R-008).

### Changed

- With nothing gated yet, `status.sh` and the dashboard count unrouted work from the commit
  that installed the kit (pinned in `<kit>/.install-base` while uncommitted), not from the
  start of history. `BASELINE=none` restores the old behaviour.
- `ledger.sh add` warns on a gate id the router does not list (authored G9+ stays legal).

### Action required

- **Re-copy the pre-push hook:** `bash .pipeline/tools/install-hook.sh --force`. The installed
  hook is a copy; until you do, none of the pre-push changes apply to you (`status.sh` flags
  the difference). The hook also regenerates and commits `dashboard.html` on a push where the
  ledger moved, and that commit rides out on the NEXT push (documented in README step 4).
- Do NOT set `.pipeline/ledger.jsonl merge=union` (an earlier draft of this step said to): a union
  merge lets the compliance verdict follow merge direction. If you already added it, remove it. When
  two branches both log gates and the ledger conflicts, keep both sides' lines in the order they were
  logged, then run `compliance` and re-log any gate whose pass came from the other branch (R-008).
- Changes that already have route entries: those entries have no `base`, so binding is skipped
  for them with a NOTE, and that is the safe state. Do NOT re-run `reconcile.sh --log` on a
  change that has already landed to "fix" it: a round-1 route with a different base starts a new
  lineage, and is now REFUSED (exit 2) unless you pass `--restart-lineage` (`reconcile.sh --restart-lineage`,
  or `RESTART_LINEAGE=1`; only the exact value 1 counts), which records `"restart":true` on the row. Only a
  marked row (or the change's first round-1 route) starts a lineage, so merging two branches' ledgers can no
  longer restart one by accident (`compliance` notes the unmarked row instead). A restart re-records the base and the tier
  floor and makes every gate result logged so far read `NOT RUN` for the new lineage -- including a G1
  logged before the restart's route, which you log again. The same base again is just a re-run of the
  same reconcile and needs nothing. Use `--round 2` (or higher) for follow-ups; the dashboard lists an
  older lineage's rounds as their own "(earlier lineage N)" group instead of mixing them in.
  `compliance` without `--round` now checks the latest round of the current lineage, not round 1.
- `ledger.sh` options that take a value refuse a following `--option` as that value (`add --change
  --log` used to write a change named `--log`); `reconcile.sh` and the pre-push hook list a renamed
  trust file under both its old and new path, so the router and `status.sh` no longer call a file moved
  out of `auth/` T0.
- `<kit>/.install-base` is written by the first `status.sh`/dashboard run on an uncommitted kit;
  commit it with the kit (README step 6) or leave it -- it is only a pin.

---

## 1.0.0 — 2026-08-12

First versioned release. Everything before this existed only as git history, and the
version number starts here because nothing had ever been packaged or shipped.

### Fixed

- **Reconcile could not see staged files.** A file `git add`ed but not committed appeared in
  none of the three sources it read — the ordinary state at R0b. Now four sources.
- **Reconcile routed the kit itself.** A fresh install reported 17 T4 surfaces, 16 of them
  the kit's own files, because `ledger.jsonl` and `session-record-arm-a.md` match rules
  written about ledgers and sessions. Writing the ledger raised the tier of the change you
  were recording. The kit's own directory is now excluded (`INCLUDE_KIT=1` to override).
- **Reconcile skipped local `master`.** The base chain checked `origin/main`,
  `origin/master` and local `main`, then fell to `HEAD~1` — the previous commit, not the
  branch point — silently. `origin/HEAD` is now tried first, and the `HEAD~1` fallback says
  so out loud.
- **An empty diff exited 0.** "Nothing to compare" is normally a wrong base, and
  `agent-instructions.md` tells an agent to branch on this exit code. It is now exit 2, with
  `--allow-empty` for wrappers that legitimately expect one.
- **R0b took 134 seconds on a 201-file diff**, in a step the docs call "seconds". The rule
  loop was files × rules subprocesses; inverted to one grep per rule, the same fixture takes
  2.1 seconds with byte-identical output.
- **`compliance` mandated more than the router documents.** It demanded G8 flatly at T3
  where the matrix says `M⁵` (skip when the change is invisible), and G5 at T1 where nothing
  is mandatory — so an invisible refactor could only pass by logging a gate that never ran.
  All tools now read the matrix from `core/01-router.md`.
- **The pre-push hook shipped a placeholder that was a valid regex.** `<your|trust|boundary|paths>`
  matched "trust" and "boundary" and nothing anyone owns, so an unedited hook installed,
  ran, and reported success by staying silent. Rules are now derived from `surfaces.conf`,
  and both the hook and its installer refuse rather than guard nothing.
- **The example surfaces matched substrings of filenames**, so a doc named `04-ledger.md`
  hit a quota rule. Rules are anchored to path segments.
- **Two contradictory loop diagrams.** `core/00-start.md` drew the loop twice and the copy a
  new user follows was the stale one.
- **The challenge-rate metric could print above 100%**, dividing challenges across all runs
  by fresh-context runs only.

### Added

- `tests/run.sh` — the kit's own suite. 145 assertions, no dependencies. It found the
  staged-file defect on its first run.
- `tools/lib/matrix.sh` — the gate matrix, read from the router by every tool.
- `tools/install-hook.sh` — installs the pre-push hook, refuses to install one that guards
  nothing, and prints the rules it is guarding.
- `dashboard.sh --check` — exits non-zero when the kit disagrees with itself. Runs in the
  suite.
- `IGNORE::` rows in `surfaces.conf`, for vendored and generated paths.
- `--outcome n/a` in the ledger, honoured by `compliance` only where the router's cell
  carries a footnote, and only with a `--note` giving the reason.
- `VERSION`, this file, and a `.kit-version` stamp written at install time.
- The kit runs its own pipeline: its own `surfaces.conf`, the hook installed, all four
  records. `compliance` currently reports its own branch INCOMPLETE, which is true.

### Action required

**None.** This is the first release, so nobody holds a copy of anything yet.

From 1.1.0 onward this section will name the templates you have copies of —
`.git/hooks/pre-push`, the `agent-instructions.md` block pasted into your agent's
instruction file, and anything in `project/` whose format changed — because those are the
changes an upgrade cannot make for you.
