# Learnings

> Append-only. Written by the Harvest loop, after any escaped defect and any T3/T4
> change. Gated-change dogfoods its own template here — this file is about the kit
> itself, not about a project built with it.
>
> **What broke, and what we now know because of it.** Distinct from the intent log
> (what was *asked*) and the handoff (where we *are*).

## Format

```markdown
### <short name>
Date        : YYYY-MM-DD
What broke  : the observable symptom, not the diagnosis
Root cause  : what was actually true
Why we missed it : which gate should have caught this, and why it did not
Now         : the rule, test, or registry entry that exists because of this
```

## Entries

<!-- Newest at the bottom. Append, do not edit. -->

### experiments/001-first-run — both backlog items were stale, in different ways
Date        : 2026-08-10
What broke  : Not a defect in `gated-change` code — a gap in what the method checks.
  Both sample features in the first paired trial (`experiments/001-first-run`) turned
  out to be based on backlog descriptions that no longer matched the target codebase:
  arm A's bug had already been fixed (double-defended, in fact); arm B's requested
  behavior had been built once and deliberately removed, with two tests pinning the
  removal as intentional.
Root cause  : Nothing in the pipeline required checking a described defect against
  current code, or a requested behavior against git history, before Build. G1 Intent's
  card asked "who is this for, what does done mean" but not "does this still happen."
  G2 Scout's "what does everyone get wrong" lens — the closest fit — is gated to
  net-new capability only (footnote ¹ in the gate matrix), so it never fires for a
  bug-fix-shaped request, which is exactly the shape most likely to be stale.
Why we missed it : Arm A's version was caught anyway, because I read the target
  function before writing acceptance criteria — an instinct, not something the card
  required. Arm B's version was not caught, by design (arm B is the without-pipeline
  control) — but a dry run showed even the WITH-pipeline gate set as it existed before
  this Harvest pass had no explicit step that would have forced the same check.
Now         : Added a universal coupling entry (`core/03-registry.md`) — a backlog item
  asking for a behavior gets `git log -S<value>` before you build it. Extended G1a
  Intent (`core/cards/G1-intent.md`) to require reproducing a described defect before
  scoping it, explicitly independent of Scout's net-new-only trigger. Both are portable
  (not SampleApp-specific) — the pattern ("a diff-based reviewer can't see a reversed
  decision") applies to any codebase with history.

### experiments/001-first-run — reconcile.sh silently passed on real changes
Date        : 2026-08-10
What broke  : `bash reconcile.sh T4` reported "No changes against `<base>`" on arm A's
  branch despite three modified tracked files and one new untracked file sitting in the
  working tree.
Root cause  : The diff-gathering line only appended the uncommitted `git diff
  --name-only` output when the committed-diff variable was *already* non-empty
  (`[ -n "$CHANGED" ] && ...`), so a change with zero commits so far — the normal state
  right after Build, before R0b — dropped the entire uncommitted diff, not just
  untracked files. Untracked files were never included at all, committed or not.
Why we missed it : No test coverage on `reconcile.sh` itself (it's a shell script,
  exercised only by using it). Caught by using the tool for real during the trial, not
  by any gate — this is itself a small case-in-point for why Study 2/3 style dogfooding
  finds things code review of the tool wouldn't.
Now         : Fixed to union three sources (committed diff, uncommitted diff, untracked
  files via `git ls-files --others --exclude-standard`) unconditionally. Verified with a
  throwaway repo reproducing the exact shape (zero commits, mixed tracked/untracked
  changes) before and after.

### experiments/001-first-run — cost metrics didn't fit an agent-run trial
Date        : 2026-08-10
What broke  : Nothing broke, but `session-record.md`'s cost table had no honest place
  to put two real numbers from the trial: per-subagent token cost (the closest thing to
  a real cost figure available when the primary session can't read back its own token
  count), and the gap between wall-clock and summed gate-effort once four gates ran as
  parallel background subagents instead of serially.
Root cause  : The template (and `tools/benchmark/README.md`'s Study 2) was written
  assuming a human, serially-metered IDE session, where wall-clock and effort are the
  same number and `tokens_in`/`tokens_out` are just what the session used.
Why we missed it : Not a gate miss — a template gap, only visible once an agent
  actually ran the process being measured.
Now         : Added a "Subagent token cost" row and a "Gate-minutes, summed" row to
  `session-record.md`, and a note in `tools/benchmark/README.md` explaining why
  agent-run wall-clock should be read as an upper bound on speed advantage, not a
  measurement of it.

### experiments/002-second-run — branch-switching mid-trial corrupted which arm was current
Date        : 2026-08-10
What broke  : Two branch-tracking mistakes in one session — arm D's build briefly landed
  on `main` — both while running arm C and arm D interleaved in a single working tree
  (checking out arm D's branch to investigate while arm C's background gate subagents
  were still dispatched against arm C's own checked-out branch).
Root cause  : Nothing in the benchmark harness or the pipeline itself prevents
  branch-switching a shared working tree while a gate subagent is mid-flight against it.
  Waiting on a background gate made checking out the other arm's branch tempting; that is
  exactly when the current-branch assumption silently went stale.
Why we missed it : No gate covers this — it is a benchmark-tooling mistake, not a code
  defect. Both instances were self-caught by inspecting `git diff`/`git log` before
  trusting a commit, not by any gate, and the result correctly logged this as a
  process-tooling gap rather than a pipeline finding.
Now         : Adopted worktree-per-arm (`git worktree add`) for every paired trial from
  experiment 003 onward — each arm gets its own working tree so branch identity can never
  drift while another arm's gates are in flight. Documented in
  `tools/benchmark/README.md`'s Study 3 section so future trials don't have to
  rediscover it; the practice had been running two experiments ahead of the doc.

### experiments/003-third-run + 004-fourth-run — a gate correctly finding a real bug outside the diff had no documented handling
Date        : 2026-08-11
What broke  : Not a defect — a gap in the failure rule. Twice independently (pair 2's
  arm C's G6, and again pair 4's arm G's G8), a verify gate found a real, verifiable bug
  that was outside the two functions the change under review actually touched. Each time
  the author had to improvise the right response (log the fail honestly, file a separate
  follow-up, do not fold an unrelated fix into an already-scoped change) with no rule to
  point to, and no shared vocabulary for why forcing the fix in would have been wrong.
Root cause  : `core/02-gates.md`'s failure rule assumed every gate failure was *about* the
  diff being reviewed. It had no branch for "the gate is right, and also not talking about
  this change" — a real, recurring shape once gates run against a live product (G8
  Dogfood especially, since using the product surfaces whatever is broken, not only
  what the diff touched).
Why we missed it : Neither instance escaped — both were caught and handled correctly by
  instinct, verified against `git diff` before deciding scope. The gap was in the
  documentation, not the outcome: a rule that has to be reinvented per-arm is still a gap,
  even when every reinvention lands on the same right answer.
Now         : Added an explicit clause to the failure rule (`core/02-gates.md`): a gate
  failure confirmed via `git diff` to be outside the change under review is still logged
  as a `fail` (the gate's own binary criterion, not softened to make the number look
  better), but routes to a separate follow-up item instead of back through Build for this
  change.

### experiments/003-third-run + 004-fourth-run — nested subagent gate dispatches stalled on notification routing
Date        : 2026-08-11
What broke  : In both pairs, an arm built by its own dispatched subagent then dispatched
  gate subagents of its own (nested dispatch). Those gate subagents' completions notified
  the top-level orchestrating session instead of the arm subagent that actually spawned
  them, stalling the arm mid-flight until the orchestrator manually relayed each gate
  result back down. Pair 3's arm E lost a dispatched G8 entirely this way — it never
  resolved through the relay path and had to be redispatched fresh against the final
  commit.
Root cause  : The notification/completion path assumes one level of dispatch (session →
  subagent). Nesting a second level (subagent → its own subagents) has no defined return
  path, so completions surface at the top regardless of which session actually asked.
Why we missed it : Not visible in single-level dispatch, which is how every earlier
  experiment (001, 002) ran gates. Only appeared once experiment 003+004's pre-registration
  moved to building each arm end-to-end inside its own subagent — a structural change to
  how the benchmark itself runs, not to the pipeline being benchmarked.
Now         : Documented the fallback in `tools/benchmark/README.md`'s Study 3 section: a
  nested gate dispatch gets a defined wait, and a dispatch that does not resolve through
  the relay path is redispatched fresh against the latest commit rather than waited on
  indefinitely. Both arms' relayed results were still treated as equivalent to direct
  ones (correct — fresh context is about who reviews, not how the report arrives), but
  the stall cost real wall-clock that should not recur silently in future trials.

### experiments/003-third-run — reconcile.sh mechanically misfired 3/3 times on the shipped example surfaces.conf
Date        : 2026-08-11
What broke  : Not a defect in the target project — arm E's `reconcile.sh` hit T4
  identically on all three reconciliations of the same change, purely from
  `project/surfaces.conf`'s example rule `(auth|session|token|credential|permission)`
  substring-matching the word "session" inside an unrelated docs filename
  (`02-focus-sessions.md`) and, later, a test filename. No code in the diff touched
  auth/session/token/credential logic at all — every hit was a filename coincidence.
Root cause  : `project/surfaces.conf` ships as a generic example ("delete it and write
  your own," stated in its own header) with bare-keyword rules that match on filename
  substring, not on what a file actually does. "Session" collides with any project whose
  own domain vocabulary happens to reuse the word for something unrelated to auth (here,
  a focus-timer "session" feature). The file's header already warns adopters to replace
  it, but nothing surfaces that warning at the point it matters — reconcile just runs
  silently against whatever is in the file, example or not.
Why we missed it : The reconcile-miss-rate metric (`core/04-ledger.md`) is designed to
  catch exactly this class over time (this case is technically a "miss" — predicted T3,
  actual T4), but needs enough logged `route` records to cross the ~30% threshold before
  it says anything. Three identical misfires in one diff produced the signal instantly;
  nothing translated that into an immediate, visible warning.
Now         : `tools/reconcile.sh` now checks whether `$CONF` still contains the shipped
  example's marker text and prints a loud warning before showing tier output, rather than
  waiting for miss-rate statistics to accumulate. Confirmed by running it against this
  repo's own unmodified `project/surfaces.conf`: it re-triggered the same false-positive
  class live (`session-record-arm-*.md` → "Trust boundary", `ledger.jsonl` → "Quota
  accounting" via the bare word "ledger"), validating both the warning and the underlying
  finding in one run.

### ledger.sh wrote unescaped JSON, and reconcile.sh silently ignored --ledger
Date        : 2026-08-11
What broke  : Two bugs in the ledger tooling, both found by using it rather than reading it,
  while adding structured findings. (1) `emit` interpolated `--note` and `--change` straight
  into a JSON string with `printf '%s'`. A note containing a `"` or `\` produced a line no
  parser can read — verified: `{"note":"he said "it cancels out""}` fails with
  `Expecting ',' delimiter`. Gate notes are long agent-written prose that quote real code,
  so this was a matter of when, not if. (2) `reconcile.sh --log --ledger <path>` accepted
  `--ledger`, ignored it, and wrote to the default `.pipeline/ledger.jsonl` instead — I hit
  this myself mid-session and briefly wrote three test records into the repo.
Root cause  : (1) The ledger was designed around short human notes, where quoting is rare;
  it grew into the pipeline's main prose record without the escaping that implies. (2)
  `reconcile.sh` parsed only `--log` out of its arguments and forwarded nothing to
  `ledger.sh`, which does support `--ledger` — the two scripts disagreed about their own
  shared flag, and the disagreement failed silently in the direction of writing to the
  wrong file.
Why we missed it : No gate covers the kit's own shell tooling, and neither bug is visible
  by reading — the first needs a note containing a quote, the second needs someone to check
  where the record actually landed rather than trusting "(logged to ledger)". This is the
  second time `reconcile.sh` has shipped a silent-wrong-answer bug found only by real use
  (see the first entry above about dropped uncommitted diffs); "it printed something
  plausible" is the shared failure mode.
Now         : Added `json_escape` and routed every string field through it; verified all
  emitted lines parse, and that a note containing `"` and `\` round-trips verbatim.
  `reconcile.sh` now parses `--ledger` and `--log` in any order before reading the
  positional tier, and forwards the path — verified the default path stays untouched.
  Also, `--finding "severity::location::claim"` now warns when a `blocking`/`minor`
  finding has no citation, which makes the evidence rule mechanical instead of remembered.

### tools/dashboard.sh — default paths doubled .pipeline/.pipeline/ on every real install
Date        : 2026-08-11
What broke  : Nothing in this repo — `dashboard.sh`'s defaults (`$KIT/.pipeline/ledger.jsonl`,
  `$KIT/.pipeline/dashboard.html`) only ever "worked" because gated-change dogfoods itself
  from its own repo root, where `$KIT` happens to equal the repo root. Simulated a real
  installed project (`cp -r core tools .pipeline/` into a fresh repo, per `core/00-start.md`'s
  own install steps) and ran `bash .pipeline/tools/dashboard.sh` with no arguments: it looked
  for its own ledger at `.pipeline/.pipeline/ledger.jsonl`, never found the real one, and wrote
  output to the same doubled path.
Root cause  : Confused two different things that both happen to be named `.pipeline/` in this
  kit's vocabulary — `$KIT` (where the ASSETS live: cards, router, this script itself, fixed
  relative to the script) and the conventional ledger/output location (DATA, which
  `tools/ledger.sh` has always resolved relative to the *working directory*, not to itself).
  Every adopting project installs the kit as `<project>/.pipeline/`, so `$KIT` already equals
  `.pipeline/` there — appending another `.pipeline/` on top was wrong for every real install,
  right only in this repo's own self-referential layout.
Why we missed it : Never actually ran the tool from outside gated-change's own repo. Every
  smoke test up to this point happened to pass because the bug is invisible from inside the
  one location where `$KIT` and "conventional data root" coincide by construction.
Now         : Ledger/output defaults are plain `.pipeline/…` paths, relative to the caller's
  CWD — matching `tools/ledger.sh`'s own convention exactly, not `$KIT`. Re-verified against
  the same simulated installed project: finds the real ledger, writes to the correct path.
  General lesson, not specific to this script: **a tool that only runs from its own source
  tree has an unverified assumption about paths.** Test portability by actually simulating the
  install, not by reasoning about the code.

### tools/dashboard.sh — escape-rate metric alarmed on a 0% (good) rate
Date        : 2026-08-11
What broke  : The Projects overview's escape-rate line showed a ⚠️ next to "Escape rate: 0%
  (0 escaped)" — the *best* possible outcome, flagged as if it were bad. Caught by reading the
  actual rendered page text during verification, not by reviewing the code.
Root cause  : `metricLine(label, rate, alarmAt, n)`'s generic threshold check was `rate >=
  alarmAt`, reused for every metric. Reconcile miss rate has a real numeric alarm bound
  (~30%, from `core/04-ledger.md`) where `>=` is correct. Escape rate has no such bound —
  "lower is better," full stop — so passing `alarmAt=0` made the check `rate >= 0`, which is
  true for every non-null rate including the good one.
Why we missed it : Treated escape rate as "just another percentage metric" and forced it
  through the same generic threshold helper as miss rate, when `core/04-ledger.md` itself
  never gives escape rate a numeric bound — only a direction ("lower is better").
Now         : Escape rate gets its own render path (`escapeLine()`), alarming on the escape
  **count** being greater than zero, not on the rate crossing an arbitrary bound. Re-verified:
  0 escapes across all four demo projects now renders with no alarm on any of them.

### product-intelligence-extension install — G1's budget drifted across three hardcoded copies
Date        : 2026-08-11
What broke  : `dashboard.sh` warned on a genuinely second install (`product-intelligence-extension`,
  copied per the README's own `cp -r core/ .pipeline/core/` step, not run from inside this repo)
  that G1's budget disagreed between `core/01-router.md` (10 min) and `core/02-gates.md`
  (15 min). Fixing the router and re-running surfaced a **third** copy of the same number,
  hardcoded in `tools/ledger.sh`'s `budget_for()` (also 10), which the dashboard's own
  "over 2x budget" check reads from directly.
Root cause  : G1's per-gate budget exists in three independent places — the router's gate
  matrix, the gate index in `02-gates.md`, and `ledger.sh`'s `budget_for()` — with the card
  (`cards/G1-intent.md`) as the only one anyone actually edits when a gate's scope changes.
  Two of the three copies silently fell out of sync; nothing checks them against each other
  except `dashboard.sh`'s cross-reference, and that only runs when someone actually runs it.
Why we missed it : Same shape as the `dashboard.sh` KIT-path bug above — this repo's own
  `core/` was never exercised as an *installed copy* in a second project until this session.
  `01-router.md` vs `02-gates.md` disagreement is exactly the class of drift `dashboard.sh`
  was built to catch (`--print-model`'s stderr warnings) — it caught it correctly. The
  `ledger.sh` copy is outside what `dashboard.sh` cross-checks against the cards at all; it
  only surfaced because fixing the first two and re-running exposed the third.
Now         : All three numbers corrected to 15 min for G1, matching the card. Not yet
  fixed: `budget_for()` is still a fourth hardcoded table rather than derived from the cards
  the way `dashboard.sh` derives everything else — the same class of bug can recur for any
  other gate's budget. Worth a follow-up: have `ledger.sh` read budgets from `core/cards/*.md`
  instead of carrying its own copy.

### product-intelligence-extension install — a skipped gate defaulted to "fresh" confidence
Date        : 2026-08-11
What broke  : `ledger.sh add --gate G6 --outcome skipped` (no `--confidence` passed) recorded
  `"confidence":"fresh"` for a gate that never ran — `ledger.sh report` then counted it toward
  "fresh-context" runs and showed `G6/G7/G8: fresh 1` each, implying three fresh-context
  reviews happened this round when zero did. Caught by reading the report output and noticing
  the number didn't match what was actually done, not by any check in the tool.
Root cause  : `cmd_add`'s `confidence` default is `"fresh"`, correct for the common case (a
  gate that ran and wasn't explicitly marked low-confidence) but wrong for `outcome:skipped`,
  where there was no review to have a confidence level at all. The script has no dependency
  between `outcome` and `confidence` — they're independent flags that happen to interact
  badly at exactly this combination.
Now         : Hand-corrected the three ledger lines before trusting the report, then fixed
  the root cause: `cmd_add` tracks whether `--confidence` was explicitly passed
  (`confidence_set`, mirroring the existing `commit_set` pattern) and defaults to `low`
  instead of `fresh` whenever `outcome=skipped` and the caller didn't override it. An
  explicit `--confidence fresh` still wins if someone really means it. Verified: `ledger.sh
  add --gate G6 --outcome skipped` with no `--confidence` now records `"confidence":"low"`.

### product-intelligence-extension install — the dashboard existed and nobody was told
Date        : 2026-08-11
What broke  : Not a code defect — a discoverability one, caught by the user, not by any
  gate. `dashboard.sh` had already been built, run, and used to find the three bugs above,
  but nothing in `requirements.md` — the very first artifact written and the one a human
  actually reads and confirms — said it existed. The user had to ask "where can I see the
  dashboard" after the fact instead of finding a pointer to it in the first document.
Root cause  : `templates/requirements.md` and the `agent-instructions.md` snippet (the
  only enforcement point that runs before work starts, per its own header) both describe
  the confirm-gate sequence in detail but never mention `dashboard.sh` at all — it's
  documented in `00-start.md` and the tool's own header comment, neither of which a
  reviewer confirming `requirements.md` has any reason to open.
Why we missed it : Every earlier `dashboard.sh` learning (this file, above) was about the
  tool being *correct* once run. None of them asked whether anyone would know to run it,
  or where its output shows up in the artifacts a human actually reads — a gap in the
  templates, not the tool.
Now         : `templates/requirements.md` gets a "Pipeline status" line under its header
  pointing at `bash .pipeline/tools/dashboard.sh` → `.pipeline/dashboard.html`, generated
  starting at Intent, not deferred to release. `agent-instructions.md`'s "Always" list gets
  a matching bullet, so the agent surfaces it unprompted in every session, not only when
  asked. General lesson: a tool's correctness and a tool's discoverability are different
  bars — this repo had verified the first repeatedly and never checked the second.

### product-intelligence-extension install — Scout existed, but nothing made it real or confirmed
Date        : 2026-08-11
What broke  : Not a code defect — the user caught it by reading the shipped
  `requirements.md`: "I don't see checking existing or similar products... what can be
  included and excluded or improved." G2 Scout already covers exactly this, but this
  session logged it `outcome: skipped` in the ledger (visible, at least) and the "Prior
  art" section that got written anyway was generic, unresearched prose ("generic
  web-scraper extensions...") — no real competing products named, no actual search run,
  and nobody was asked to confirm it before `design.md` proceeded.
Root cause  : Two independent gaps, not one. (1) G2's card explicitly warns against a
  feature-comparison table (`fails_when: reads like a feature comparison table`) — a
  reasonable stance against feature-parity chasing, but it left no place for the concrete
  include/exclude/improve decisions the user wanted, so there was no template slot to fill
  even if Scout had been run for real. (2) Nothing enforced that Scout's output — unlike
  requirements/design/tasks — gets an explicit user confirmation before the pipeline moves
  on. "Never blocks a release" (router footnote ¹) reads, in practice, as "skippable and
  unreviewed," which isn't what non-blocking was meant to mean.
Now         : `cards/G2-scout.md` now requires the gap note **and** a comparison table
  (real, named products; explicit include/exclude/improve per row) as a required
  supplement below the gap note, never a replacement for it — and adds a "Confirm before
  continuing" section: non-blocking-for-release is not the same as unreviewed, so Scout's
  part of `requirements.md` gets the same explicit stop-and-confirm as the rest of the
  file. `templates/requirements.md` and `agent-instructions.md` carry both changes.
  Router footnote ¹ clarified to say so directly. General lesson: a gate's *design*
  argument against one failure mode (feature-parity chasing) can leave a different,
  legitimate need (concrete scope decisions against real alternatives) with nowhere to
  go — the fix was additive, not a reversal of the original reasoning.

### product-intelligence-extension install — G8's "running product" isn't always reachable
Date        : 2026-08-11
What broke  : Not a defect — a capability gap discovered while trying to run Dogfood-shaped
  verification on the Phase 1 MVP. This agent's browser tools cannot load an unpacked
  Chrome extension (`chrome://extensions` and its native directory picker are both out of
  reach) or drive `chrome.*` APIs from a plain page. G8's card assumes `input: the RUNNING
  product` without qualifying that assumption.
Root cause  : The card was written against the implicit assumption that the agent's own
  tools can always launch what it built. True for a web app behind a dev server; false for
  a browser extension, and not spelled out as a case to handle.
Why we missed it : The first target (SampleApp) was also a browser extension, so this gap
  existed the whole time and was never exercised in a way that surfaced it — nobody tried
  to run G8 through this agent's own tools against it before now.
Now         : `cards/G8-dogfood.md` gets a "When the running product isn't reachable"
  section: build fixture pages that match the target shape and inject the real source
  directly (verified this session — found a genuine bug this way: `PI_microdataProp` didn't
  handle schema.org's `<link itemprop="..." href="...">` convention for URL-valued
  properties, silently returning empty `availability` for every product). That technique
  is real Proof (G5), not Dogfood — it never exercises `chrome.*` orchestration, the popup
  UI, or a second use. The card now says so explicitly rather than letting a same-session
  fixture check quietly stand in for a gate whose whole point is a fresh, unbriefed user on
  the real thing.

### The skipped gates were hiding three blocking security defects — and R0b was broken
Date        : 2026-08-12
What broke  : The user asked "even though we designed a pipeline, why are there instances
  where the stages are skipped — isn't the whole purpose defeated?" Auditing honestly: on
  `catalog-extraction` I had skipped G6 Peer, G7 Threat, and R0b reconcile entirely, and
  logged them as skipped. Running them for real produced: **G6 PASS with 6 findings** (two
  genuine silent-wrong-data bugs in surrounding code) and **G7 FAIL with 3 blocking
  findings** — CSV formula injection reaching a spreadsheet evaluator from attacker-
  controlled page text, an unvalidated `chrome.tabs.update` navigation letting a scraped
  page drive up to 500 authenticated cross-origin requests, and the very diff under review
  widening the first of those sinks. All three would have shipped.
Root cause  : Three separate causes, only one defensible. (a) Some skips were correct — G6/G7/G8
  need fresh context, and the user had explicitly deferred them to a review pass. (b) One
  was pure drift: a bug found *by* a gate led to an edit on a T4 surface, and that edit never
  re-entered routing because a mid-session fix does not feel like "a change." (c) Underneath
  both: **the kit had no mechanical completion check.** `05-enforcement.md` names three
  enforcement points, two of which fire at the very end and one of which decays over a long
  session. Everything between session start and push was enforced by self-reporting, and
  `reconcile.sh` ended with a flat "Proceed to release." while printing an unrun HARD GATE
  directly above that line.
Why we missed it : Skipping the gate hid a bug *in* the gate. `reconcile.sh` defaulted
  `CONF` to the cwd-relative `project/surfaces.conf`, but the documented install puts the kit
  in `.pipeline/` and invokes it from the project root — so R0b died with "No surfaces file"
  for **every install that followed the README**. It only ever worked when run from the kit's
  own root, which is the one way this repo had dogfooded it. Nobody hit it because nobody ran
  the step.
Now         : Four fixes. (1) `tools/reconcile.sh` resolves `CONF` against the KIT, mirroring
  dashboard.sh — R0b works from an installed `.pipeline/` now. (2) New
  `ledger.sh compliance --change X --tier T --round N`: reads the ledger, exits non-zero when
  a tier-mandated gate has no **pass**, and treats `skipped` as what it is. This is the first
  check in the kit that is not self-graded. (3) `reconcile.sh` no longer says "Proceed to
  release" — it says routing matched and points at the compliance check as the thing that
  decides. (4) New **R0c Re-entry** rule in `01-router.md`: an edit to a T3/T4 surface made
  after R0a has run re-enters at R0a for that edit, at a new round. General lesson, and the
  honest answer to the user's question: **the pipeline's real guarantee was never "gates
  cannot be skipped" — it was "a skip cannot be invisible."** That held; the ledger said
  `fresh-context: 0` in bold and the user caught it by reading the dashboard. But visibility
  only pays off if someone looks, so the mechanical check now looks on their behalf.

### Package and Deploy: nothing in the pipeline produced a running product
Date        : 2026-08-12
What broke  : G8 Dogfood declares `input: the RUNNING product`. No phase produced one. The
  pipeline ran plan → build → verify on an unstated assumption that "built" and "runnable"
  are the same state — true for a library, false for any installable artifact, and the gap
  is exactly where verification stops happening quietly.
Root cause  : The kit had 3 phases (Build, Record, Release) and no step between Build and the
  verify gates. The user named this directly: "the build, install and deploy stage is missing."
Why we missed it : Both validation targets so far are browser extensions, where the gap is
  most acute — and in both cases the running product was produced by a human out-of-band, so
  the pipeline never had to admit it could not do it itself.
Now         : New `core/14-phases.md` defining **Package** (produce the artifact) and
  **Deploy** (get it running), as phases not gates — they have no persona and cannot fail a
  review, only fail to run. Commands live in the new `project/commands.conf`
  (`KIND::TARGET::COMMAND`), never in `core/`, because "chrome or firefox" would break the
  portability rule the whole repo rests on. `TARGET` joins to `surfaces.conf`, which makes
  the useful check mechanical: **a target you must verify but cannot run is a target nobody
  will dogfood.** A `DEPLOY::<target>::MANUAL::<why>` line records a deliberate human step;
  an absent line is an oversight, and they must not look alike. Two things deliberately kept
  OUT of the loop: repository/remote setup (one-time bootstrap — putting it in a per-change
  phase means every trivial change nominally passes through "where should this repo live"),
  and any promise to deploy into the user's *existing* browser profile, which is a MANUAL
  line rather than a promise the phase cannot keep.

### Every remediation round introduced new defects — and the compliance check was too strict
Date        : 2026-08-12
What broke  : Two things, both found by using the new tooling on the same change. (a) G7
  round 3 passed the security remediation but found **three of its six minors were created
  by the round-2 fix itself** — including a correctness regression where the scroll fallback
  still tested the raw `nextPageUrl` while pagination tested the validated one, so a page
  offering a cross-origin "next" satisfied neither branch: no pagination (correctly refused)
  and no infinite scroll (wrongly skipped), ending at page one reporting "Done". A security
  check had silently disabled a feature. (b) The `compliance` check written hours earlier
  matched passes only at the *current* round, so a one-line fix in round 3 demanded all six
  mandated gates re-run.
Root cause  : (a) A security fix changes control flow, and the branch *not* being hardened is
  the one that inherits the change's side effects. Hardening one of two sibling call sites —
  which round 3 also caught, twice — is the recurring shape. (b) Strict per-round matching
  mistakes "was re-verified" for "is still valid". The kit's own failure rule says return to
  the phase that produced the defect, *not to the start*; the check contradicted it.
Why we missed it : (a) No automated suite exists, so control-flow regressions have nothing
  to catch them — the round-3 reviewer only found it by driving the state machine with a
  scripted hostile content script. (b) The check was written and shipped in the same session
  without being run against a multi-round change; the first real use exposed it immediately.
Now         : `gate_passed_round` returns the LATEST round a gate passed, and compliance
  prints `PASS*  G5  Proof  passed at round 2 — 2 round(s) of changes since`. An older pass
  counts, and its age is visible; whether the change since invalidates it is a judgment the
  reviewer can only make if they can see the age. Exiting 1 is reserved for a gate that has
  *never* passed. General lesson, and it applies to the kit itself: **a check strict enough
  that nobody can satisfy it gets bypassed, and a bypassed check measures nothing.** The bar
  stays "a skip cannot be invisible", not "nothing may ever be skipped". Second lesson, for
  any project: after a remediation round, re-review the remediation — on this change that
  found something three rounds running.

### reconcile could not see staged files, and skipped local `master`
Date        : 2026-08-12
What broke  : Three defects in `tools/reconcile.sh`, all of the same shape — a confident
  answer computed from the wrong inputs. (a) A file that had been `git add`ed but not yet
  committed appeared in none of the three sources reconcile unioned, so R0b saw an empty
  diff and reported "No changes" for work that was staged and ready. (b) The base-resolution
  chain checked `origin/main`, `origin/master` and local `main`, but not local `master` — so
  a repo with no remote and the older default name fell through to `HEAD~1` and reconciled
  against the previous commit rather than the branch point. (c) On an empty diff the script
  exited **0**, which `templates/agent-instructions.md` tells an agent to read as a pass.
Root cause  : (a) Staging moves a file out of every other query at once: it is no longer
  untracked, it no longer differs from the index, and it is not yet in any commit. The three
  sources were each individually correct and collectively had a hole exactly where the most
  ordinary pre-commit state sits. (b) An omission, invisible because the fallback silently
  produced a plausible-looking answer instead of an error. (c) "Nothing to compare" was
  encoded as success rather than as the environment error it almost always is.
Why we missed it : `LEARNINGS.md` already answered this question, on 2026-08-10, about this
  same file: *"No test coverage on reconcile.sh itself (it's a shell script, exercised only
  by using it)."* The lesson was recorded and not acted on, so the next two defects in the
  same function were found the same expensive way. A learning that changes no tooling is a
  note, not a control.
Now         : `tests/run.sh` exists — 26 tests, no dependencies — and it found the staged-file
  defect on its first run, before any user did. Reconcile unions four sources including
  `git diff --name-only --cached`; the base chain tries `origin/HEAD` first (the repository's
  own answer rather than our guess) and falls through `main` **and** `master` before warning
  loudly that `HEAD~1` is not a branch point; an empty diff exits 2, with `--allow-empty` for
  wrappers that legitimately expect one. General lesson: **when the same "why we missed it"
  is written twice, the fix is a test, not a better intention.**

### The kit routed itself: a fresh install reported 17 T4 surfaces, none of them the user's code
Date        : 2026-08-12
What broke  : Installing the kit the documented way — `cp -r gated-change/ your-project/.pipeline/`
  — and then editing one line of application code produced a T4 verdict with seventeen trust
  surfaces hit, sixteen of which were the kit's own files. `.pipeline/ledger.jsonl` and
  `.pipeline/core/04-ledger.md` matched the quota rule; four `session-record-arm-*.md` matched
  the trust-boundary rule; `05-enforcement.md` matched the enforcement rule. The consequence
  is circular: writing the ledger, which is what you do to record that a gate ran, raised the
  tier of the change you were recording it for.
Root cause  : Two independent defects that only compound. (1) reconcile read the whole working
  tree with no notion that `.pipeline/` is the tool rather than the project — the kit was
  inside the scope of its own analysis. (2) The shipped example rules matched bare keywords
  anywhere in a path, so any file whose *name* contained "ledger", "session" or "enforcement"
  hit a T4 rule regardless of what the file did.
Why we missed it : The kit has only ever been run from its own root, where `.pipeline/` does not
  exist — the same blind spot that shipped the CONF-resolution bug two days earlier. Both are
  the same missing test: nobody had installed the kit into another repo the way the README
  tells a user to, and run it. experiments/003 recorded three mechanical misfires against
  these exact rules and the response was to add a warning about the example rather than to fix
  the example.
Now         : reconcile excludes the kit's own prefix (located with `git rev-parse --show-prefix`,
  so no path normalisation is involved) and says how many files it dropped — silently
  narrowing a routing decision is the behaviour this script exists to catch. `INCLUDE_KIT=1`
  restores the old behaviour for the one case that needs it: this repo reviewing itself, where
  every file genuinely is the product. The example rules are anchored to path segments
  (`(^|/)auth/`, `(^|/)ledger\.[a-z]+$`) with the trade written down, and `IGNORE::` rows now
  exist for vendored and generated paths. `tests/run.sh` covers all four behaviours. General
  lesson: **a warning about a defect is not a fix for it** — experiments/003 found this exact
  class three times and the tool kept shipping the confident wrong answer with a caveat above it.

### The compliance check was stricter than the matrix it claimed to mirror
Date        : 2026-08-12
What broke  : `ledger.sh` hardcoded which gates a tier mandates, and its copy disagreed with
  `core/01-router.md` in two places. The router marks G8 `M⁵` — mandatory *unless the change
  is invisible to users* — and the copy demanded it flatly, so an invisible T3 refactor could
  not pass compliance at all. At T1 the router mandates nothing (G4/G5/G6 are all `R`) and the
  copy demanded G5. `reconcile.sh` held a third copy, as prose, which had drifted from both.
Root cause  : The matrix was written in one place and restated in two others. Restating a
  table is not duplication of effort, it is duplication of *authority*: when they disagree
  there is no rule for which one wins, and the one that runs beats the one that is documented.
  The footnotes made it worse — they encode conditions (is this invisible? is this a bug fix?)
  that no copy could evaluate, so the copy silently resolved them by dropping them.
Why we missed it : Nothing compared the copies. `dashboard.sh` already had drift checks for
  gate budgets across three files — the machinery existed and simply was not pointed at the
  most consequential table in the kit.
Now         : `tools/lib/matrix.sh` reads the router, and ledger.sh, reconcile.sh and
  dashboard.sh all ask it. A footnoted mandate with no verdict now reports `UNRESOLVED` and
  prints the footnote — the question, not just the refusal — and is answered either by running
  the gate or by `--outcome n/a --note "<why>"`, which is accepted only where the cell actually
  carries a footnote. `M (hard)` with no marker refuses an n/a outright. General lesson:
  **a check that is stricter than the rule it enforces does not produce more rigour, it
  produces false entries** — the only way to satisfy it was to log a pass nobody earned, and
  that is worse than the gap it was covering.

### Two fresh-context re-runs, two NEW bugs each round, zero repeats — and what that pattern is worth
Date        : 2026-08-12
What broke  : Not a single defect — a full paired-trial run of G4 Ripple and G6 Peer on the
  same SampleApp change (`week-strip-day-selection`), across two rounds. Round 1: both gates
  failed, found (independently, in separate fresh sessions) that an ARIA attribute was the
  wrong contract, a fresh-install state left the strip in a misleading "wall of pressed cells,"
  the feature doc's own invariants were now false, and — worst — the change's `design.md`
  *claimed* an accessibility risk was recorded in `risks.md` when it was not (an in-repo
  instance of "a comment asserting provenance is not provenance," CLAUDE.md's own rule, broken
  by the person who wrote that rule down). All fixed, tested, re-diffed. Round 2: both gates
  re-run FRESH — no narrative, no "here's what we fixed" — and both failed AGAIN, each finding
  a DIFFERENT real bug **in the round-1 fixes themselves**: the wall-of-pressed-cells fix used
  the wrong condition and still produced a wall for a schedule that existed but wasn't yet
  assigned to any day; the keyboard-focus fix enumerated three DOM regions a re-render needed
  to protect and missed a fourth (a conditionally-rendered CTA, easy to leave off a hand-written
  list). Zero overlap between round 1 and round 2's findings, and zero overlap between G4's and
  G6's round-2 findings with each other.
Root cause  : Two things worth separating. First, ordinary: any fix is written by the same
  author, in the same session, under the same blind spot that produced the original bug — see
  the addition to `core/cards/G4-ripple.md`'s edge table this session, "a fix disproportionately
  reproduces the same class of gap as the bug it fixes." Second, specific to this run: I nearly
  didn't get a real answer to any of this. Round 2's first compliance check reported all three
  gates as `SKIPPED` — because I had fixed `tools/ledger.sh`'s bugs in the KIT's own source repo
  but never re-synced that fix into the PROJECT's installed `.pipeline/` copy, so the install was
  silently running the old, broken tool. The result looked plausible enough to almost accept.
Why we missed it : G4/G6 caught the product bugs because they are DESIGNED to run blind and
  fresh — the whole point of the context rule (`02-gates.md`) is that a session which didn't
  write the fix has no anchor telling it the fix worked. My own stale-install mistake was caught
  for a boring but important reason: the result (SKIPPED) didn't match what I remembered having
  verified (FAIL, with real finding counts, confirmed earlier the same session) — and I traced
  the disagreement between memory and output instead of accepting either one on faith. No card
  currently names this as a discipline; it worked because it was already a habit in this
  session, not because the pipeline asked for it anywhere.
Now         : `core/cards/G4-ripple.md`'s edge table gained the "fix reproduces the bug's own
  class of gap" paragraph (this session). Two things NOT yet done, flagged rather than guessed
  at: (1) no card or doc currently tells an agent "if a repeat check disagrees with what you
  remember verifying, that disagreement is itself a finding — trace it before trusting either
  side"; (2) no part of the router or `04-ledger.md` names a **stopping heuristic** for repeat
  rounds — this run's shrinking severity and zero-repeat pattern across two rounds is exactly
  the kind of signal that should tell you round 3 has low expected value, but nothing currently
  operationalizes "decreasing severity + no repeated findings across N rounds → stop" as
  distinct from "keep re-running until you get bored" (bad) or "never stop" (also bad). Both are
  candidates for a future Harvest pass on the kit itself, not implemented here.

### Findings-as-attack-surface — a quoted finding becomes trusted input for a later gate
Date        : 2026-08-13
What broke  : Nothing yet — this is a named, watched risk, not an incident, per this kit's own
  evidence discipline (`core/11-evolution.md` Step 2: anecdote-tier, not a pattern or an
  incident). Recorded because the vector is real and traced from an actual entry in this file,
  not hypothetical.
Root cause  : Two existing rules combine into a path nothing currently defends. The evidence
  rule (`02-gates.md`) requires quoting hostile content **verbatim** in a finding's `claim` —
  "a finding without a citation is deleted, not softened." The CSV-formula-injection entry
  above (2026-08-12, "The skipped gates were hiding three blocking security defects") is a real
  case: G7's finding necessarily quoted the actual injection payload, because the rule gives no
  other option. Separately, G7 Threat's own card lists `prior findings` as trusted `input:` for
  a later, fresh-context run of that same gate — and other gates read the ledger too. A finding
  written correctly, exactly as the rules require, becomes attacker-controlled text sitting in
  a file a later gate is told to trust.
Why we missed it : No gate's `withhold` field currently excludes `prior findings` on the
  grounds that they might themselves carry live hostile content — the blind review rule
  (`02-gates.md`) only ever reasoned about the AUTHOR's account biasing the reviewer, never
  about the ledger itself as an injection carrier read back into a fresh context. It surfaced
  from tracing the evidence rule and G7's `input:` field side by side, not from anything
  failing in practice.
Now         : Nothing built. A sandbox for the blind-review `withhold` rule was already
  rejected in an earlier review round (G4 needs live-repo write access, G8's input IS the
  running product, and a sandbox breaks both), and no new enforcement mechanism is proposed
  here either. This entry is the control for now — a named, watched risk at anecdote tier.
  Promote it (`core/11-evolution.md` Step 2) if a real gate run is ever found to have acted on
  injected content read back from `prior findings`, rather than merely quoting it once and
  moving on.

### Routing five changes without committing between them produced four false "under" verdicts
Date        : 2026-08-13
What broke  : Not a code defect — a real methodological trap in how `reconcile.sh` gets used.
  Five logically distinct fixes were built in one session, each Triaged and reconciled with
  `bash tools/reconcile.sh T<n> --log`, but nothing was ever committed between them. Four of
  the five reconciled as under-classified ("actual T4" against a predicted T1/T3), which looked
  like real findings about those changes — until checked against `project/surfaces.conf`
  directly: none of the four touched a T4 surface on their own content (a template doc, a
  reference-prose file, a `LEARNINGS.md` note). The actual T4 hit in every one of those diffs
  was `tools/ledger.sh`, correctly and separately being modified by a different one of the five
  changes in the same batch, still sitting uncommitted.
Root cause  : `reconcile.sh BASE=HEAD` (correctly) diffs the *entire* uncommitted working tree
  against the last real commit — it has no concept of "just this logical change," because there
  is no such boundary in git until something is committed. Every reconcile call after the first
  file touching a T4 surface landed will see that file, regardless of which of the five changes
  it is nominally routing. This is `reconcile.sh` doing exactly what it is documented to do; the
  mistake was treating five sequential Triage calls in one uncommitted tree as if they were
  isolated, the way they would be on five separate branches or after five separate commits.
Why we missed it : No gate caught it — this was a same-session author mistake, corrected only
  by cross-checking the "under" verdicts against `surfaces.conf` by hand once the resulting
  four-changes-with-no-G5-entry pattern looked suspicious on its own (three "under" verdicts on
  a docs-only batch was the tell). `01-router.md`'s own R0b rule ("actual > predicted → Stop.
  Run every gate the higher tier requires") is correct and was technically obeyed each time —
  the tier really was T4 for that diff, at that moment — but obeying it four times in a row
  without noticing the diffs were four times the same contaminated superset was the actual gap.
Now         : Not fixed in the tool — this is a usage discipline, not a bug, and `reconcile.sh`
  should not start guessing which files "belong" to which change; that guess would be exactly
  the kind of silent, confident wrong answer this file's entire history warns against. Recorded
  here as the rule: **route one change at a time, and either commit before Triage-ing the next
  one, or accept that every subsequent reconcile in the same uncommitted tree reports the union
  of everything still sitting there.** The four contaminated route entries were left in
  `ledger.jsonl` rather than edited (never backfill), and a fifth, honest entry
  (`doc-and-schema-followups`) supersedes them by routing the same four changes correctly, as
  the one combined T4 diff they concretely were by the time anyone looked again.

### The router can only tier a diff, and the most irreversible events in an installable artifact's life are not one
Date        : 2026-08-13
What broke  : Not a code defect — a gap surfaced by an external dogfight review (multi-persona:
  dev/tester/PM/business/front-end/back-end/devops) that traced `T4`'s own definition against
  what `reconcile.sh` can actually see, using a Chrome extension as the worked case.
Root cause  : `T4` is defined (`01-router.md`) as "anything a user cannot undo, and anything
  touching money." `reconcile.sh`'s only input is `git diff --name-only` against a base ref,
  and every `TIER::REGEX::LABEL` row in `surfaces.conf` matches a PATH. For an installable
  artifact distributed through a store, the events that concentrate the most real-world
  irreversibility change no file at all: pressing Publish (a version number that can never be
  reused or rolled back), a permission-warning delta that silently re-prompts or drops
  existing users, ramping a staged rollout, rotating or losing the signing key, editing the
  listing or privacy disclosure. Each one is T4 by the router's own written definition. None of
  them can be routed by the router's own mechanism, because none of them are diffs. This is not
  a missing row — no row, however well written, closes a gap whose input type is wrong.
Why we missed it : `14-phases.md` had already argued this exact shape of gap into existence one
  step earlier in the pipeline ("G8 Dogfood declares `input: the RUNNING product`. Nothing in
  the pipeline produced one" — which is why Package and Deploy exist) and then stopped one step
  short: `Release` is named in the loop diagram and in one table row, with no chapter, no
  executor, and no record type in `ledger.sh` (only `gate`/`route`/`escape` exist). Nothing
  internal caught it because nothing internal asks "can every T4 thing be expressed as a path" —
  the router's tests pin path-matching *behaviour*, correctly, and none of them are positioned
  to notice that the input type itself has a hole. It took an outside review naming a concrete
  domain (store publish) to make the missing input type visible.
Now         : Not built. Two things exist as of this entry, both partial and both already
  path-based rather than a fix for the underlying gap: `BASE=<last-release-tag>` on
  `reconcile.sh` (documented in `01-router.md`, R0b) catches trust/permission drift accumulated
  across several already-merged PRs — still a diff, just a bigger one, against the release
  point instead of the branch point. And `templates/project/surfaces.conf` now says this gap
  out loud, in its own "WHAT THIS FILE CANNOT ROUTE" section, rather than shipping a worked
  Chrome-extension example that implies coverage it does not have.
  **Deliberately deferred, not forgotten:** an `ACTION::TIER::NAME::EVIDENCE` row kind — an
  event with a tier and no path — would close this for real, but it changes what a row in
  `surfaces.conf` is allowed to be, which means it changes the router (`reconcile.sh`,
  `01-router.md`, `ledger.sh` compliance) rather than a project's config, so it is T4 on this
  kit's own surfaces and needs its own routed change with fresh-context gates — not something
  to fold into the docs/config pass that produced this entry. This branch already has three
  changes awaiting those gates (`SESSION-HANDOFF.md`); a fourth un-gated T4 change on top of
  those would be the kit failing its own compliance check while building the tool that runs it.

  **Built, 2026-08-13, branch `router/action-tier-mechanism`.** The deferred row kind above is
  implemented, not just designed: `ACTION::TIER::NAME::EVIDENCE` rows now live alongside
  `TIER::REGEX::LABEL`/`IGNORE::REGEX::LABEL`/`TARGET::LABEL::HOW_VERIFIED` in `surfaces.conf`,
  and `reconcile.sh`'s path-tiering loop explicitly excludes `ACTION::` before it ever reaches
  the `*::*::*` shape check that used to treat anything with two `::`s as a path rule —
  otherwise a NAME like `store-publish` would have been grepped against the file list, matched
  nothing, and said nothing, which is the exact silent-drop shape a fresh-context review of
  this same branch's `tools/lib/matrix.sh` found independently the same day
  (`security-reports/2026-08-13-first-push-matrix-hook-review.md`, Finding 1: a malformed gate
  row silently dropped a HARD GATE with exit 0). `reconcile.sh` now validates every `ACTION`
  row's shape on *every* run, not only when `--action` is used, and refuses loudly rather than
  repeating that shape of bug in its own new row kind.

  New invocation: `bash tools/reconcile.sh --action store-publish --evidence "<citation>"`.
  Both flags are required together (refused otherwise, before any git work happens); an unknown
  NAME is refused and the refusal lists the `ACTION` rows it did find; a pure action invocation
  with zero file changes is not treated as the empty-diff refusal (the action is its own
  evidence of a reconciliation event); it composes with a normal diff-based reconcile in the
  same call (`ACTUAL` becomes the max of whatever the diff hit and whatever the action
  declares, the same way two path rules hitting one file already combine); and with no
  predicted tier given, prediction defaults to the action's own tier, since there is nothing to
  *guess* about a fact being declared. `ledger.sh route` gained matching `--action`/`--evidence`
  fields, required together independently of `reconcile.sh`'s own check (`ledger.sh` is the one
  piece of this kit that is "not self-graded" and has to hold the pairing rule itself). Full
  design rationale — including why this got its own step, R0d, rather than folding into R0b —
  lives in `01-router.md`. `templates/project/surfaces.conf` now ships five worked `ACTION`
  rows for the Chrome-extension example (`store-publish`, `permission-delta`, `rollout-ramp`,
  `key-rotation`, `listing-edit`) and its "WHAT THIS FILE CANNOT ROUTE" section says what is
  closed and what is not.

  **Honestly partial, not fully closed — named in `01-router.md`'s R0d and
  `templates/project/surfaces.conf`, not silently left out:** nothing detects a real-world
  publish event or forces `--action` to be invoked — it is a declaration, not a sensor, and a
  human or agent who forgets to run it leaves the pipeline exactly as blind as before this
  entry. `EVIDENCE` is checked for presence only, not shape or content (the same bar G7's
  `finding` citations already hold). There is no retraction mechanism — a mistaken `ACTION` is
  corrected by a superseding ledger entry, never an edit. And there is no `compliance` check
  that an `ACTION` was ever exercised for a change that should have declared one, the way there
  already is for a mandated gate that never ran — named as the natural next mechanical check,
  not built in this pass.

### `ledger.jsonl:20` ("my-first-feature") is contamination, not a real record — and the bug that put it there
Date        : 2026-08-13
What broke  : A fresh-context G8 Dogfood reviewer, dispatched to use `tools/ledger.sh` as a
  first-time adopter would, invoked it by absolute path (`bash D:/work/gated-change/tools/ledger.sh`)
  from an unrelated scratch project elsewhere on disk, and deliberately omitted `--ledger` to
  test the default-path behavior. The write landed in THIS repo's own root `ledger.jsonl`, not
  the scratch project the reviewer intended — line 20, `"change":"my-first-feature"`, describes
  no real change in this repo and should not be read as one.
Root cause  : `tools/ledger.sh`'s default-path logic checks whether `KIT_ROOT` (where the script
  itself lives) is, by itself, a repo root or nested inside one — it never considers the
  CALLER's cwd or repo at all. That correctly distinguishes "this kit IS the repo" (self-hosting)
  from "this kit is copied into `.pipeline/` inside a bigger repo" (installed) for the one
  invocation pattern the kit documents (`cp -r gated-change/ your-project/.pipeline/`, then run
  from your project root). It does nothing sane for a THIRD pattern nobody wrote a check for:
  referencing a kit checkout by absolute path from a completely unrelated location. In that
  case `KIT_ROOT` resolves to the referenced kit's own repo root, which for a standalone dev
  checkout (this repo) has no git prefix — so the self-hosting branch fires, and the write goes
  to `$KIT_ROOT/ledger.jsonl`, i.e. this repo's own ledger, regardless of where the caller
  actually stands or what they meant to log. The confirmation message is identical either way.
Why we missed it : `core/04-ledger.md`'s own canonical usage examples omit `--ledger` entirely,
  which reads as "this is normal and safe" rather than "this only defaults sensibly for the one
  documented invocation shape." Nothing in this repo's own dogfooding ever exercised the
  absolute-path-from-elsewhere pattern, because this repo always invokes its own tools
  relative to its own root — the self-hosting case that the earlier default-path fix
  (2026-08-12/13 entries) was written to get right. The reviewer's task explicitly asked it to
  invoke by full path from a scratch dir rather than the documented installed-copy pattern,
  which surfaced a real gap in what "safe to omit --ledger" actually covers.
Now         : Not fixed. Logged as a `blocking` finding under `ledger-hardening`'s G8 entry
  (round 1, fail). The stray `ledger.jsonl:20` line is left exactly as the bug produced it,
  not edited or deleted — per this file's own precedent two entries up ("routing five changes
  without committing between them"), a ledger line does not get cleaned up to make the record
  look better, even when the line is contamination rather than a real gate run. This entry is
  what makes that line legible to whoever reads it next.

### `ledger.sh add` let a CLI flag forge the ledger it is supposed to be evidence for
Date        : 2026-08-13
What broke  : Fresh-context G4/G6/G7 reviews of `587e8e1` (dispatched earlier this session,
  three independent gates converging on the same defect) live-reproduced a JSON-injection bug:
  a crafted `--lane` value forged a duplicate `"outcome"` key, and `ledger.sh compliance` then
  reported **PASS for a gate that had actually failed with a blocking finding**. Full transcript
  in `security-reports/2026-08-13-587e8e1.md`.
Root cause  : `json_escape()` was applied to `change`/`commit`/`kit`/`model`/`note` and to
  `finding_json`'s `location`/`claim`, but not to `tier`, `gate`, `outcome`, `confidence`, or
  `lane` in `cmd_add`'s final `emit()` template, nor to `predicted`/`actual` in `cmd_route`, nor
  to `found_by`/`severity` in `cmd_escape` — every one of those splices a CLI argument straight
  into a quoted JSON string position. A second, distinct vector existed alongside it: `round`,
  `minutes`, `tokens`, and `challenged_premise` sit in BARE (unquoted) JSON positions in the same
  templates (`"round":%s`, not `"round":"%s"`) — no escaping scheme protects a value that isn't
  inside quotes to begin with; only rejecting a non-integer/non-boolean value does.
Why we missed it : `finding_json` (severity/location/out-of-scope-filed) got the strict
  refuse-don't-warn treatment this session's earlier hardening pass gave it, and the file's own
  comments narrate that incident at length — but the identical risk shape sitting one call frame
  up, in the scalar fields every `emit()` template also splices, was never audited the same way.
  `tests/run.sh` had 244 passing assertions and none of them tried a value containing `"` or `,`
  in `--lane`, `--tier`, `--gate`, `--round`, `--challenged`, `--minutes`, or `--tokens` — every
  existing test that touches those fields uses a well-formed value, so the gap was invisible to
  the suite that was supposed to be the proof this file works.
Now         : Fixed. Every string-context field now passes through `json_escape()` before
  reaching `emit()`. Every bare-position field (`round`, `minutes`, `tokens`,
  `challenged_premise` in both `cmd_add` and `cmd_route`) is now validated by `is_uint`/
  `is_bool` and REFUSED — nothing written — on a non-numeric/non-boolean value, matching
  `finding_json`'s own established "refuse what makes the record false, don't warn-and-write
  it" rule rather than inventing a new policy. `tier`/`gate` get a structural `looks_like_tier`/
  `looks_like_gate` check (a `T`/`G` prefix plus digits, or empty for tier) deliberately looser
  than a fixed T0–T4/G1–G8 enum, because `06-extending.md` lets a project author gates past G8.
  6 new regression tests in `tests/run.sh`, independently verified fail-before/pass-after by
  stashing the fix: all 6 fail against the pre-fix code for the right reason (the exact
  security-report payload forges `outcome:pass`; a malformed `--gate` value visibly corrupts the
  written record) and pass again with the fix restored. Logged as `G5` round 2 under both
  `ledger-hardening` and `doc-and-schema-followups` (same commit). **Not yet done:** a
  fresh-context re-dispatch of `G4`/`G6`/`G7`/`G8` round 2 to independently verify this fix, per
  the context rule (`02-gates.md`) — this entry and the round-2 `G5` pass cover the mechanical
  proof only, not a fresh review.

### `isolation: "worktree"` on a fresh-context dispatch does not pin to the caller's branch
Date        : 2026-08-14
What broke  : Dispatching the fresh-context G4+G6+G7 combined review and the G8 dogfood
  review for the `ACTION::TIER::NAME::EVIDENCE` mechanism (this same file's own "Built"
  entry, above) using `isolation: "worktree"` produced worthless reviews on the first
  attempt: both worktrees were checked out at `259805d` — `origin/master`'s tip — not
  `router/action-tier-mechanism`'s actual HEAD (`05eaa89`, the implementation commit).
  G8 reported "no --action/--evidence flags exist anywhere" and failed, correctly, against
  code that genuinely did not have the feature. G4/G6/G7's stale-worktree run was still
  mid-flight when this was caught; per this session's own precedent (`ledger.jsonl:20`,
  the "my-first-feature" contamination entry, same date as most of this file's history) it
  was allowed to finish rather than killed, but its output was not logged as a review of
  this change.
Root cause  : The `Agent` tool's `isolation: "worktree"` option creates a git worktree, but
  nothing in its available parameters lets the caller specify which branch or commit to base
  it on — and its default, empirically, was the repository's default branch (`master`), not
  the caller's own current branch. A caller mid-feature-branch who reaches for worktree
  isolation specifically *because* they have uncommitted narrative files they want hidden
  from a blind reviewer (the actual reason it was chosen here) gets a worktree that is not
  just missing those uncommitted files — it is missing the entire feature branch's commit
  history, silently.
Why we missed it : Nothing in this kit's own gate matrix or context rule (`02-gates.md`)
  addresses subagent-dispatch mechanics at all — those rules assume "a fresh session" means
  "a session with no memory of this conversation," not "a session pointed at the right git
  ref." No test in `tests/run.sh` exercises agent dispatch (it cannot; that is outside this
  repo's own tooling). The failure was caught only because a supervising process
  cross-checked the worktree's actual commit against the branch tip from outside the
  dispatch entirely — the dispatched agent itself had no way to know its own checkout was
  wrong, since `git log -1` inside a stale-but-otherwise-valid worktree looks completely
  ordinary from the inside.
Now         : Two things, this session: (1) both dispatches were redone without worktree
  isolation — directly in the main checkout, after `git stash push -u` moved the
  uncommitted narrative files (`LEARNINGS.md`, `SESSION-HANDOFF.md`) out of the working tree
  for the duration, restored via `git stash pop` once both reviews completed. This achieves
  the same blind-review goal (the reviewer cannot see the author's own account of the
  change) without depending on worktree base-ref behavior at all. (2) Every dispatch prompt
  in this session, from this point forward, opens with an explicit instruction: run `git log
  -1 --oneline` as the FIRST action and confirm it matches the exact commit sha expected,
  stopping immediately and reporting only the mismatch if it does not — the same
  self-verification this file's own task brief required of the top-level session at its own
  start ("Confirm with `git log -1 --oneline` and `git status`... you should see a clean
  tree with that commit as HEAD"), now pushed down one level to every subagent dispatch too.
  **Not fixed at the tool level** — this is a caller-side discipline (verify the ref, or
  don't use worktree isolation for a branch that isn't the default), not a bug filed against
  the `Agent` tool itself, which was never told what to correct. Worth naming if this
  pattern recurs: a `ref`/`base` parameter on `isolation: "worktree"` dispatches would close
  this at the source rather than relying on every prompt to add a self-check.

### dashboard.sh's auto-regen would have committed forever, on every push, once installed
Date        : 2026-08-14
What broke  : Not shipped — caught in manual testing before it ever reached a test file
  or a commit. Building the pre-push extension that regenerates `dashboard.html` and
  commits it when the ledger has moved (closing the "dashboard is always stale" complaint
  from the downstream `product-intelligence-extension` target), the first working version
  passed an initial "regenerate + commit" check and then FAILED its own very next check:
  running the hook a second time, with nothing about the ledger changed at all, committed
  again anyway. Unbounded, this would have created one auto-commit on literally every
  single push to any repo with the hook installed, forever, whether or not anyone had
  logged a gate run since the last one.
Root cause  : Two fields `tools/dashboard.sh` bakes into the model on every run are not a
  function of the ledger at all, and a raw diff of the regenerated file against what was
  already committed treated both as "content changed": (1) `"generated"`, a fresh UTC
  timestamp, different by construction on every invocation; (2) `"kitCommit"`, computed as
  `git rev-parse --short HEAD` run from the kit directory — for an embedded kit (no
  separate `.git` under it, which is the normal install AND how this repo runs on itself),
  that resolves to the ENCLOSING repo's current HEAD. Every commit changes HEAD, including
  the auto-commit this hook itself makes. So the dashboard.html this hook had JUST
  committed already recorded a `kitCommit` one commit behind its own sha, by construction
  — the next run could never see it as "unchanged," even with an identical ledger,
  because the file could never correctly predict the commit that would contain it.
Why we missed it : The design brief called for "regenerate and stage if the ledger
  changed," which reads naturally as "diff the output, commit if different" — a
  reasonable-sounding design that is wrong specifically because two fields in the
  generated file are not deterministic functions of the ledger. Nothing in
  `tools/dashboard.sh`'s own header flags `generated`/`kitCommit` as volatile-for-diffing
  purposes; there was no reason to suspect it before actually running the hook twice in a
  row and watching HEAD move both times.
Now         : Fixed. The comparison that decides whether to commit strips both fields
  (`sed 's/"generated":"[^"]*"/"generated":""/;s/"kitCommit":"[^"]*"/"kitCommit":""/'`)
  before comparing the freshly regenerated file against `git show HEAD:<path>`; if they
  match, the working-tree file is reverted to exactly the committed bytes (no dangling
  diff, no partial regen left lying around) instead of committed. Verified by hand in a
  throwaway repo through five rounds (no ledger yet → skip; ledger appears → regen +
  commit; immediate re-run, nothing changed → true no-op; an uncommitted ledger edit →
  still picked up and committed; `dashboard.sh` made to fail via a corrupted card → warns,
  does not block the push) before writing it up as `tests/run.sh` regression tests
  (`test_hook_dashboard_regen_is_a_noop_once_settled` is the direct lock against this
  recurring). Also verified empirically, not assumed, while building this: a commit made
  by a hook DURING `pre-push` is not what the in-flight push actually sends — git resolves
  the sha to transfer before the hook runs — so the auto-commit always rides out on the
  NEXT push, never the current one. That is documented in `templates/pre-push`'s own
  comment rather than left as something a future reader has to re-discover.

### install-claude-hook.sh's no-python fallback printed a snippet that was not valid JSON
Date        : 2026-08-15
What broke  : Not shipped — caught in manual testing before it ever reached a commit.
  `tools/install-claude-hook.sh` (installs the new R0c `PostToolUse` hook into
  `.claude/settings.json`) uses python to merge safely when it is present, and — the same
  "refuse rather than guard nothing" trade `install-hook.sh` already makes — prints the
  entry to add by hand and exits 2 when it is not. Manually running that fallback path
  (python hidden from `PATH`) and piping the printed snippet through `json.loads` to check
  it was actually pasteable, it wasn't: `"command": "bash "$CLAUDE_PROJECT_DIR/tools/
  hooks/r0c-post-edit.sh""` — the inner double quotes around the path (needed in the shell
  command itself, since it contains a `$VAR/…` expansion) were not escaped for JSON.
Root cause  : The python merge path is correct — `json.dump()` escapes a string value's
  embedded quotes automatically. The fallback snippet is built by hand in bash for the
  case where python is unavailable, and that hand-built string interpolated the raw
  command (containing literal `"` characters) directly into a hand-written JSON literal
  with no escaping step of its own — the one place in this script doing what `tools/
  ledger.sh`'s own header already warns against: splicing a value into JSON text without
  going through an escape function first.
Why we missed it : The success path (python present, `json.dump` does the escaping) was
  tested first and looked complete; the fallback only exists for the *absence* of the tool
  that would have made this a non-issue automatically, and nothing exercises string
  content differing between the two paths unless the fallback's own output is fed back
  through a JSON parser, not just read by eye.
Now         : Fixed — `COMMAND_JSON_ESCAPED="$(printf '%s' "$COMMAND" | sed 's/"/\\"/g')"`
  before the string is spliced into the printed snippet. Verified by piping the fallback's
  actual stdout through `python -c "json.loads(...)"` (not just re-reading the sed), which
  is now `tests/run.sh`'s `test_<removed-installer-case>
  without_python` — it hides python via `PATH`, captures the real printed output, and
  parses it as JSON rather than pattern-matching the text.

### The unbounded auto-recommit came back through a different field, and the lock caught it
Date        : 2026-08-15
What broke  : Not shipped — caught by the suite within seconds of the change. Adding a
  `"coverage"` object to `tools/dashboard.sh`'s model (the dashboard's new unrouted-work
  panel) immediately failed `test_hook_dashboard_regen_is_a_noop_once_settled`, the
  regression lock written months earlier for the `"kitCommit"` infinite-recommit bug. The
  pre-push hook auto-committed a regenerated `dashboard.html` on a push where the ledger
  had not moved at all.
Root cause  : Identical in shape to the original bug, reached through a new field. The
  hook decides whether to commit by comparing the regenerated file against the committed
  one with non-deterministic fields blanked first — `"generated"` and `"kitCommit"`.
  `"coverage"` is computed from **git HEAD**, not from the ledger: how many commits have
  landed since the last gate record, and what they touched. Every commit changes it,
  including the auto-commit the hook itself makes, so the committed file could never
  predict its own coverage value and the next run always saw a "change." The mental slip
  was categorising coverage as "dashboard data" (like gates/matrix/spine, which are stable
  and SHOULD be compared) rather than as "a function of HEAD" (like kitCommit, which must
  not be).
Why we missed it : Nothing did — this is the entry where the process worked. The lock
  existed precisely because this failure mode is invisible by inspection (it takes two
  consecutive runs with an unchanged ledger to see it) and it fired on the first run after
  the change. Worth recording anyway for the generalisation: **any new field in the
  dashboard model must be classified as a function-of-the-ledger or a function-of-HEAD
  before it is added**, because only the former may participate in the no-op comparison.
  That question is now stated in `templates/pre-push`'s own comment rather than left for
  the next author to rediscover by watching HEAD move.
Now         : Fixed by adding `"coverage"` to the no-op comparison's exclusions, matched as
  a whole LINE (`s/^"coverage":.*$/"coverage":null,/`) because the value contains nested
  braces and a sed character class cannot balance them — `dashboard.sh`'s MODEL heredoc
  puts it on its own line, which makes the line-anchored form safe. That fix creates a
  second-order honesty problem, discharged rather than left implicit: the hook regenerates
  when the LEDGER moves, so commits that land with no gate logged leave the baked panel
  behind and it can **undercount — in exactly the scenario the panel exists for**. The
  panel therefore always states that its counts were taken at generation time and points at
  `tools/status.sh` for a live answer, pinned by a test asserting that line appears *even
  when the panel looks clean*. Related: the same change's in-repo check compared path
  strings and silently disabled coverage on Git Bash for Windows (`D:/x` from
  `git rev-parse --show-toplevel` vs `/d/x` from `pwd` — a mismatch `tools/ledger.sh`'s own
  header already documented); it failed CLOSED, so nothing looked wrong. Both sides of that
  comparison are now produced by git.

### `. <(sed …)` sourcing kept the emit() backstop red on macOS CI for two weeks
Date        : 2026-09-03
What broke  : `test_emit_refuses_a_line_that_is_not_a_json_object` was the only failing test
  on the `macos-latest` CI job, and it failed on **every run since 2026-08-19** — the first
  time the three-OS matrix (added for risk R-003) ever executed. `expected exit 3, got 127` /
  `bash: emit: command not found`. `ubuntu-latest` and `windows-latest` were green throughout.
  The handoff carried "confirm the CI run passed" as an open action item across the whole
  `dashboard-p0-review-fixes` branch; nobody opened the run.
Root cause  : The test loaded `ledger.sh`'s functions minus its `case "${1:-}"` dispatch block
  via `. <(sed '/^case …/,$d' ledger.sh)` — sourcing a **process substitution**. On the
  bash 3.2.57 that ships on macOS, `. <(…)` reading from the `/dev/fd` FIFO silently loads
  nothing: `emit()` is never defined, the call is command-not-found (127, not the asserted 3),
  and `sed` takes SIGPIPE. bash 4+ (the Linux and Git-Bash-on-Windows CI legs) has no such bug.
  Not risk R-004 — the `_relpath` drive-letter branch `_skip`ped cleanly the whole time.
Why we missed it : Two blind spots stacked. (1) The dev platform is Git Bash on Windows, which
  ships a modern bash, so no local run — including the pre-push suite — could ever reproduce
  it. (2) G5 Proof's "Linux/macOS bash" target had never had *executed* evidence: R-003,
  accepted 2026-08-15, says exactly this ("a workflow file is a plan, not evidence"). The
  matrix was wired but its first red result was never read — the gap R-003 predicted, realised.
Now         : (1) The test stages the stripped prefix in a real `mktemp` file and sources that,
  the canonical portable form (`507071b`). (2) A new suite invariant,
  `test_no_kit_shell_file_sources_a_process_substitution`, greps every tracked kit shell file
  (`*.sh` + `templates/pre-push`, minus `releases/`) and fails if `. <(…)` / `source <(…)`
  reappears (`9375ec0`, hardened in `4a8ef61` after the round-2 review) — the generalisation,
  since the same construct in `tools/ledger.sh` would break real macOS *users*, not just CI.
  (3) R-003's wording updated: CI has now run, found one real bug, and the residue narrows to
  "macOS still has no *green* run until this lands." The deeper process fix is the handoff
  discipline — a red CI run is not an item to carry, it is the thing to open first.

### `reconcile.sh --change` defaulted to the branch name, so `master` became a "change"
Date        : 2026-09-03
What broke  : Caught by the four-persona dashboard review (P1-5), not shipped to a user — but
  the bad data was live in `ledger.jsonl` (one `route` record, `change:"master"`, commit
  `507071b`), written *this same session* while gating the macOS CI fix. On the dashboard it
  rendered as a change named "master" where all five mandated gates showed **"should have
  reviewed this, but didn't"** — a gap warning for work that was never a change.
Root cause  : `reconcile.sh` sets `CHANGE="${CHANGE:-$(git rev-parse --abbrev-ref HEAD)}"`. On
  a trunk branch (this kit is trunk-based — everything commits to `master`) with no `CHANGE=`
  set, every `reconcile.sh … --log` writes a route record named for the branch. Route records
  and gate records correlate **only** by sharing a `change` string, so a record named for a
  permanent branch collects reconciles from many unrelated changes and joins with none.
Why we missed it : Nothing refused the name at write time — `ledger.sh route` took any
  `--change`. And the dashboard had no notion of "a change group that is all `route` records
  and no gates" — `computeStatus` just saw a T3/T4 route, derived the mandated set, found no
  gate records, and reported every one missing. The kit's own `agent-instructions.md` did not
  tell an agent to set `CHANGE=`, so the default was the path of least resistance.
Now         : (1) `ledger.sh` refuses `--change` ∈ `{master, main, develop, development, dev,
  trunk, HEAD, unknown}` on **all four** `--change` writers (`route`, `add`, `escape`,
  `assume`) — `feat/x` and other branch-per-change names still pass. (2) `reconcile.sh` names
  an `--action` route for its action (a real identifier) and, on a refused `--log`, surfaces
  the reason and `exit 2` instead of the old silent fall-through — R0b's "a change may not
  reach Release without a recorded reconciliation" is now enforced, not hoped for. (3) The
  dashboard tags a branch-named, gate-less, action-less group `isRoutingArtifact` and renders
  it once, muted, last, with no gate graph and no warning — the read-side guard for ledgers
  written before (2). (4) `CHANGE=` is documented in `reconcile.sh`'s header, `01-router.md`
  R0b, `04-ledger.md`, and `agent-instructions.md`. (5) The trunk-name list is
  hand-enumerated in two languages (`ledger.sh` + `app.js`) — a repo whose trunk is some
  *other* name is **risk R-005**, with a parity test (`test_branchy_change_list_matches_…`)
  pinning the two copies equal and the computed-from-git fix noted as the next step.

### Four gate subagents on one working tree, mutation-testing in place, contaminated each other
Date        : 2026-09-03
What broke  : During the P1-5 (T4) gate lane, G4/G5/G6/G7 ran as parallel fresh-context
  subagents against the same repo checkout. G5 Proof does mutation testing — revert a hunk,
  watch the test fail, restore. It reverted `app.js` and `ledger.sh` **in place**, and (a)
  left a `// REVERTED for G5 proof` edit in `app.js` that the coordinator caught only by
  chance on `git status`; (b) a later mutation landed exactly when the coordinator's own
  `bash tests/run.sh` filter ran, producing two spurious `FAIL`s that passed clean seconds
  later; (c) G6 Peer, reading `ledger.sh` for its review, saw a mutation-reverted line and
  had to note it was reviewing against the committed state, not the tree.
Why we missed it : The context rule (`02-gates.md`) says run verify gates in a fresh
  *session* — it is silent on whether those sessions share a *filesystem*. Spawning four at
  once on one working directory seemed like parallelism; it was four writers on one file.
Now         : Rule for a multi-gate lane — **G5 Proof (the only gate that mutates files) works
  on a `git worktree` or a copy, never in place**, and every mutation is `git checkout`-reverted
  and re-verified before the next. The coordinator messages this to the Proof subagent at
  spawn and checks `git status --porcelain` after each gate reports. A cleaner future fix:
  give each fresh-context gate its own worktree (`isolation: "worktree"`), so "fresh session"
  also means "fresh tree."

### The blind-review `withhold` leaks straight through the commit message
Date        : 2026-09-03
What broke  : The round-1 fresh-context gate prompts for `dashboard-p1-readability` told the
  subagent to review `git show <commit>`. `git show` prints the full commit message, and that
  commit's message was a point-by-point P1-1…P1-9 rationale. G6 Peer flagged it
  (`core/cards/G6-peer.md:18`): "the card's `withhold` field cannot hold under a commit
  message this explanatory." It judged the code independently anyway, but the gate design
  assumes the reviewer never sees the author's reasoning, and the prompt handed it over.
Why we missed it : `withhold` is enforced on the *prompt*, and the prompt itself withheld the
  rationale — then gave the reviewer a command that reads it back out. `git show` felt like
  "here is the diff," not "here is the diff plus a defence of it."
Now         : Fresh-context gate prompts say "review `git diff <base> <head>`" and "do not
  read commit messages (`git log` / `git show` full messages)". Round 2+ prompts were fixed
  this way. The safest input is a squashed patch with no message. This also means the
  coordinator should keep round-1 commit messages terse and move the rationale to the PR body
  or the intent log, where a blind reviewer is not pointed at it.

### `!isIndependent(confidence)` is not "was a self-check" — a skip has no confidence to report
Date        : 2026-09-03
What broke  : P1-6 keyed the new "A self-check by the author" caveat, the hatched-pass
  rendering, and a new "N self-check run(s)" metric on `confidence !== "fresh"`. But
  `ledger.sh:466` auto-stamps `confidence:"low"` on a `skipped`/`n-a` record *precisely
  because* "a gate that did not run has no review, so it has no confidence to report" — so
  `low` there is a placeholder, not a judgement. The dashboard then printed "Scout sat this
  one out. (A self-check by the author…)" and counted the skip. 9 of the 60 non-fresh records
  in the kit's own ledger are skips. G6 Peer round 2 caught it; round 3 caught the mirror —
  the `fresh` filter had the same gap for a lone `{skipped, fresh}` record.
Why we missed it : `computeStatus`, 40 lines from the new code, already encodes the rule
  ("a `skipped`/`n-a` record is the ABSENCE of a verdict, not one") — the new code did not
  reuse the concept. "Not fresh" and "graded their own work" looked like the same predicate.
Now         : `isVerdict(outcome)` (`pass`|`fail`) + `isSelfCheck(r)` (`isVerdict` AND not
  independent). Only a real verdict that was not independent is a self-check; `fresh` is
  `isVerdict AND isIndependent`. Both the caveat and the metric route through it.

### A JS object keyed by a ledger free-text field is a prototype-pollution surface
Date        : 2026-09-03
What broke  : `railSummary` used `var escChanges = {}` keyed by ledger **change names**;
  `friendlyAssumptions` used `var byText = {}` keyed by **assumption text**. On a plain
  object, `constructor` / `toString` / `valueOf` / `hasOwnProperty` are all keys that read
  truthy — so a change named `constructor` rendered a phantom "⚠ escaped defect" badge and
  was the only row the "escapes" filter kept — and `byText["__proto__"] = x` sets the
  prototype instead of an own property, so a `__proto__`-named assumption vanished from
  `Object.keys`. G6 Peer round 1 found both. `buildExecutions`'s `byChange[change] =
  byChange[change] || {}` has the same shape and is worse (a change named `__proto__` writes
  `Object.prototype`) — pre-existing, now **risk R-006**.
Why we missed it : change names and assumption text are attacker-influenced — the page takes
  a ledger by drag-and-drop and, since `fetchPath`, over the network — but they read as
  "just strings", and the maps are private locals that never leave the function.
Now         : Every map keyed by a ledger field uses `Object.create(null)`; every lookup
  against a fixed table (`LEAD`, `VERDICT`, `SEV_RANK`) is `hasOwnProperty`-guarded or
  `hasOwnProperty.call`-guarded. `project/registry.md` gains an entry: touch a JS object
  keyed by a ledger field → `Object.create(null)`, because `__proto__`/`constructor` are
  valid change and assumption names.

### `tests/dashboard-logic.test.js` `load()` did not reset `global.document` — one failure cascaded
Date        : 2026-09-03
What broke  : The render tests install a stub `global.document`, then `delete` it at the end
  of the test body. A failing assertion throws before that `delete`, so the stub persists
  into the next `load()`, and every subsequent test inherits a half-built DOM — one real
  failure becomes a wall of unrelated ones, hiding the cause. G5 Proof hit it while pointing
  the new tests at old code for the discrimination proofs.
Why we missed it : the tests had only ever run green, where the cascade never triggers; the
  `test()` wrapper reports a failure but does not reset shared global state.
Now         : `load()` does `delete global.document` (and resets `PIPELINE` / `LEDGERS`) at
  the top, so each test starts clean regardless of how the previous one ended.

### Opus (`claude-opus-5`) 529'd repeatedly for fresh-context gate subagents
Date        : 2026-09-03
What broke  : G5 Proof round 2 for `dashboard-p1-readability` died mid-run on HTTP 529
  Overloaded, three times across resume attempts — the same rate-limit pattern the
  2026-09-02 session logged (~10 opus deaths). The gate cards specify opus ("strongest
  available") for G5/G6.
Now         : When opus is unavailable, "strongest available" is Sonnet — re-spawn on
  `model: "sonnet"` and record the model on the ledger row (`08-models.md` already wants the
  model recorded; a downgrade forced by an outage is exactly what that field is for). A
  thrice-resumed agent also accumulates confused state; a clean fresh spawn on Sonnet
  produced a better review than continuing to poke the dying opus one.

### Asking "which gates?" before the reconcile under-gated a T3 change
Date        : 2026-09-04
What broke  : For `dashboard-p2-polish` the coordinator asked the change owner a "gate depth"
  question up front and got "G3 + G6 fresh, G4/G8 inline" — a reasonable answer for the
  *light-polish* framing it was asked under. Then `reconcile.sh` ran and returned **T3**
  (the change touches `tools/dashboard.sh` and `tests/run.sh`), and T3 **mandates G1, G5 and
  G7** on top of that. The gates were run late, out of the normal order, after the code was
  already written and three rounds deep — G5 then failed on a real coverage gap that a
  first-round G5 would have caught before two rounds of churn.
Why we missed it : The R0a triage predicted T3 correctly, but the "how deep do we gate this"
  conversation happened as if the answer were free-standing rather than *on top of the tier's
  own mandate*. "G3 + G6 fresh" read as "these are the gates" instead of "these, plus whatever
  the matrix requires".
Now         : The gate-set is the router's to decide, not a question to the owner. Ask the
  owner only about the **discretionary** gates (the `R` cells — Scout, Craft) and about
  **fresh-vs-inline** for the mandated ones. State the mandated set explicitly from the
  reconciled tier *before* asking anything. If the tier is still uncertain at planning time,
  run a dry `reconcile.sh` against the current tree first.

### The blind-review `git show` leak came back through "review these N commits"
Date        : 2026-09-04
What broke  : The P1 session fixed the round-1 gate prompt to say "review `git diff`, don't
  read commit messages" (LEARNINGS 2026-09-03). For `dashboard-p2-polish` the round-2 G3
  prompt still named the individual commits ("the change is two commits… `git log --oneline
  -3`… `git diff A B`") so the reviewer could see the range — and G3 then ran `git show
  <sha>` to trace which commit introduced a CSS rule, and saw that commit's rationale-heavy
  body. G3 flagged it (`--withhold-breached true`); the verdict was independently grounded.
Why we missed it : "Here is a commit range" and "here is a squashed diff" feel equivalent,
  but the first leaves `git show`/`git log -p` one keystroke away and a plausible reason to
  reach for them (which commit did X?).
Now         : Hand a fresh-context gate a **single squashed diff or a patch file** with no
  commit metadata — `git diff <base> <head> > /tmp/change.patch` and point at the file.
  Never name individual commits in the prompt. If the reviewer needs "which change did X",
  that is a question for the coordinator, not `git`.

### Hand-built JSON in a generator was tested by substring, so a broken serializer stayed green
Date        : 2026-09-04
What broke  : `parse_matrix()` in `tools/dashboard.sh` assembles the router matrix JSON by
  string concatenation (an inter-gate comma, a per-cell separator). The only test,
  `test_dashboard_emits_the_router_matrix`, asserted a couple of substrings (`"G8":{"T0":`,
  `"T4":"M"}`). G5 Proof round 4 showed a one-character mutation — dropping the inter-gate
  comma — produces invalid JSON that still contains both substrings, so the whole suite stays
  green while the generated page's `const PIPELINE = {…}` fails to parse at load and the
  dashboard renders blank.
Why we missed it : substring assertions on generated output look like they check structure;
  they check presence. The P1 pass's own new tests had the same shape until a fresh G5
  challenged one of them.
Now         : Any generator that hand-builds JSON (or any structured format) gets a test that
  **parses the whole output** and asserts its shape — `test_dashboard_model_matrix_is_valid_json`
  loads `--print-model` through `json.load` and checks every gate has a full `T0..T4` row.
  Substring checks are fine as an *additional* smoke test, never the only one.

### "Compute, don't enumerate" only fixed half of the focus-restore — the recogniser is still a list
Date        : 2026-09-04
What broke  : G4 Ripple round 1 flagged `applyPendingFocus` as an enumerated `{kind}` switch
  populated by only 3 of ~9 `renderAll()` callers (the R-004/R-005 shape). The round-2 fix
  split it into `captureFocus()` (reads the focused element) + `restoreFocus()` (re-finds it),
  and the commit + comment claimed the mechanism was now "caller-count-independent". It is —
  for `restoreFocus`. But `captureFocus` still recognises the focused element by an `if` chain
  of `.matches(".exec-row")`, `.matches("g.state")`, … — a *fixed list of control types*.
  G6 Peer's final re-review (two rounds later) found `.back-link` was not on that list, so
  keyboard-activating "← All projects" dropped focus to `<body>` (WCAG 2.4.3).
Why we missed it : when you break a "list of cases" into a capture/restore pair, it *feels*
  fully generic, and the restore half genuinely is. The residual list is the recogniser, and
  it is easy to stop looking at it once the more visible half is generic.
Now         : `captureFocus` recognises a FIXED set of control types — say so in the comment,
  don't claim the whole mechanism is enumeration-free. When adding a new keyboard-activatable
  control, add it to the recogniser in the same change. For controls whose element is gone
  after the render they trigger (a view transition), `restoreFocus` needs an explicit
  landmark fallback, not just "not found → give up".

### A `\0` string separator is safe in impl source and a trap in test tooling
Date        : 2026-09-04
What broke  : `captureFocus`/`restoreFocus` key their focus descriptors as `"kind\0attr\0attr"`.
  `"\0"` in a JS string literal is `\`+`0` → U+0000, correct and safe — it can't appear in an
  HTML attribute value. But: (a) G5 Proof's added tests wrote `var NUL = '<literal NUL byte>'`,
  which made `tests/dashboard-logic.test.js` register as **binary** to git — no diff, no CRLF
  normalisation; (b) fixing it via `python - <<'EOF' … s.replace(…, '…\\u0000…') … EOF`
  produced *actual* NUL bytes anyway — the quoted heredoc did not reliably protect `\\u0000`
  from becoming `\0`→NUL somewhere in the bash→python hand-off. Cost ~4 rounds of
  whack-a-mole.
Why we missed it : a NUL byte is invisible in every tool that renders the file (Read, the
  diff viewer, the editor), and `node` runs the file fine — the tests passed the whole time.
Now         : in test code, write the separator as `String.fromCharCode(0)`, never a literal
  or a heredoc-substituted escape. Edit a file that must contain `\uXXXX` escapes with Write
  + a standalone `.py` script (`open(p,'rb')` / `.replace(b'\x00', b'\\u0000')` / `open(p,'wb')`),
  never a nested heredoc. Guard the commit with
  `python3 -c "print(open(f,'rb').read().count(b'\x00'))"`.

### The in-app browser pane's focus model is not a real browser's, for automation
Date        : 2026-09-04
What broke  : Verifying P2-5 (a keyboard-a11y change) in the browser pane repeatedly gave
  wrong-looking results: programmatic `.focus()` set `document.activeElement` but `:focus` /
  `:focus-visible` did **not** match, so `getComputedStyle` showed the un-focused style and
  the skip link looked like it never revealed. Synthetic `KeyboardEvent({key:'Enter'})` did
  not trigger a native `<button>`/`<a>` default action or a `<summary>` toggle. The key
  driver sends `key: ""` for Space, so Space-use of a `role="button"` cannot be
  exercised at all (G8 Dogfood hit the same wall independently).
Why we missed it : the divergence is silent — the calls succeed, they just don't do what a
  real keypress does. Several "the ring isn't showing" / "Enter isn't working" dead ends
  before the pattern was clear.
Now         : in the browser pane — DOM attributes and computed styles via `javascript_tool`;
  focus-ring *reveal* and native-control *use* via the real `computer` key tool +
  screenshots; a custom `role="button"`'s **Space** handling only via a unit test on the key
  handler plus an in-page `el.dispatchEvent(new KeyboardEvent('keydown',{key:' '}))`. Do not
  trust `.focus()` + `:focus-visible` or synthetic `KeyboardEvent` on native elements.

### A gate FAIL on a scope-deferred issue: the verdict is the gate's, the resolution is the owner's
Date        : 2026-09-04
What broke  : Nothing broke — this is how it should go. `dashboard-keyboard-a11y`'s
  requirements explicitly deferred rail-list ergonomics (roving-tabindex, arrow keys) to
  P2-8, and the review spec asked for `tabindex="0"` on every row. G8 Dogfood then FAILed the
  change: ~60 sequential Tab stops through the rail with no bypass is a real WCAG 2.4.1
  barrier, and `fails_when` is absolute. The scope note did not make the finding go away.
Now         : a gate's FAIL on an in-scope symptom stands even when the *root* fix was
  deferred by an earlier scope decision. What the coordinator takes to the owner is the
  *resolution* — here: mitigate now with the standard 2.4.1 bypass (a skip link, cheap,
  stayed on the T1 surface), and move the deferred half (roving-tabindex) into the later
  item's scope *in writing* (requirements.md Out-of-scope) so it is inherited, not lost.
  Do not argue a gate out of its finding with "but that's out of scope".

### `python3 open(p, "w")` on Windows silently rewrites a repo file to CRLF
Date        : 2026-09-04
What broke  : Mid-P2-8, a `python3 - <<'EOF' … s = open(p).read(); … open(p,"w").write(s) … EOF`
  used to do a multi-site string replace in `tools/dashboard/app.js` turned the
  **whole file** CRLF — Python's text-mode write translates `\n` → `\r\n` on Windows.
  `git add` normalised the committed blob to LF (`.gitattributes: *.js text eol=lf`),
  so the commit was clean, but the working tree stayed CRLF, and a plain
  `git checkout HEAD -- app.js` was a **no-op** (git saw the content as identical
  modulo EOL). Only `rm app.js && git checkout HEAD -- app.js` forced a fresh
  `.gitattributes`-applied checkout back to LF.
Why we missed it : CRLF is invisible in Read, the diff viewer, and the editor; `node`
  runs the file fine; the tests all passed. The only tell was the `git commit`
  "CRLF will be replaced by LF" warning.
Now         : never `open(p, "w")` a repo file from a script on this platform — use the
  Edit tool, or `open(p, "wb")` / `open(p, "w", newline="\n")`. Check a file that
  should be LF with `python3 -c "print(open(f,'rb').read().count(b'\r\n'))"`. This
  joins the `\0`-separator / NUL-byte trap (2026-09-04, P2-5) as a
  "scripted file edits on Windows have sharp edges" note.

### A filter/search has to match what the user SEES, not the key it is stored under
Date        : 2026-09-04
What broke  : P2-8's rail filter matched `railQuery` against `cg.change` — the raw ledger
  slug, `dashboard-p1-readability`. The rail *displays* `titleCase(cg.change)` —
  "Dashboard P1 Readability". A user reads the row, types "P1 Readability", gets
  "No changes match this filter." Any query containing a space returned zero. G8
  Dogfood found it on the re-walk ("undercuts the headline use case for a 33-item
  list"); a first pass had brushed past it as a test-harness artefact.
Why we missed it : the code that renders the name and the code that filters it were
  written a screen apart, and the slug→title transform is easy to forget exists
  once you are staring at `cg.change` in `railKeep`.
Now         : `railFilterNorm(s) = s.toLowerCase().replace(/[-_\s]+/g, "")` applied to
  **both** sides — the display form and the query both collapse to the same
  separator-free string. General rule: any user-facing search over slug-keyed data
  must reverse the display transform (or index both forms). Write a test that types
  the name the way the row reads it.

### Roving tabindex over a re-render-everything view: the tab stop and the focus are two things, synced at every seam
Date        : 2026-09-04
What broke  : P2-8 made the rail one Tab stop — exactly one `.exec-row` with
  `tabindex="0"`. `renderRail` recomputes which row that is from `selectedExec`.
  But *actual keyboard focus* is moved independently by three other paths: the
  arrow handler (`handleRailArrows`), the "show all" button, and P2-5's
  `restoreFocus` after a background `renderAll`. Each one moved focus to a row
  without moving `tabindex="0"` there — so focus sat on a `tabindex="-1"` row while
  the tab stop was elsewhere, and Shift-Tabbing back into the rail jumped to the
  wrong place. G4 Ripple caught it in the show-all path; G6 Peer caught the arrow
  and `restoreFocus` paths across two rounds.
Why we missed it : "one tab stop" felt like a property of the render, so the render
  was the only place it was enforced. Every *other* place that calls `.focus()` on
  a rail row is also a place the tab stop has to move.
Now         : any code that programmatically focuses a roving-group member must also
  do the `0`/`-1` swap in the same breath. Factored the intent into the three
  handlers; a test asserts `restoreFocus` onto a rail row makes it the tab stop.
  When a widget has a "computed" active element AND imperative focus moves,
  every focus move is a seam.

### A gate PASS on the fix, FAIL on what the re-walk surfaces, is a real FAIL — and folding it beats deferring when it is cheap
Date        : 2026-09-04
What broke  : Nothing broke — process worked. G8 Dogfood round 6 confirmed the
  round-6 fix (pinned tail selection) was genuinely closed, then returned **FAIL**
  because re-walking the same route solidified a separate, pre-existing filter bug
  (spaces match nothing). `fails_when` is absolute; the gate did not hand-wave it
  because "the thing you asked me to check is fixed."
Now         : a re-verification gate that finds a NEW real surprise in the path it
  was told to walk FAILS, even when the original finding is closed — the gate
  reports both ("the fix is good to land if the new thing is a separate ticket").
  The coordinator then chooses: fold it into this change, or spin a follow-up.
  Fold it when it is small and in the same file (P2-8: `railFilterNorm` was ~2
  lines); spin a ticket when it is a different surface or a design question. Here
  folding it cost one more round and left nothing behind for P2-9.

### Replacing an enumerated list with a computed property is not done until the computed part has ONE home
Date        : 2026-09-08
What broke  : Nothing shipped broken. R-005 asked to replace `change_is_branchy()`'s
  hand-enumerated trunk-name list (`master main develop …`) with a computed check —
  resolve the repo's real default branch from git and refuse THAT. The first cut did
  exactly that, and did it in two places: a `resolve_default_branch()` function in
  `tools/ledger.sh` (write side) and a byte-for-byte-equivalent inline `case` in
  `tools/dashboard.sh` (read side). Three separate fresh-context gates — G4 Ripple,
  G5 Proof, G6 Peer — independently flagged the duplication in round 1.
Root cause  : G4's own card warns against "a condition that is a list of cases rather
  than a computed property," and the fix honoured that for the *primary* check while
  reintroducing the same smell one level up: the computed logic itself became a
  copy-paste pair, free to drift. The write side refuses at write time so only
  pre-existing ledgers could mis-render — which is why every gate rated it *minor*,
  not blocking — but "minor × 3 independent reviewers" is the signal that the fix is
  the wrong shape, not that each finding is small.
Why we missed it : the build framed "compute the default branch" as the deliverable
  and "where the computed value is read" as an implementation detail. The kit already
  had the answer in plain sight — `tools/lib/matrix.sh` and `tools/lib/coverage.sh`
  exist precisely because the gate matrix and the coverage anchor are each read by
  two tools and "two readers of one fact is two chances to read it differently."
Now         : when a fix swaps an enumerated list for a computed property AND that
  property is consumed in more than one place, the shared-source extraction is part
  of the fix, not a follow-up. Round 2 moved it to `tools/lib/default-branch.sh`
  (new T4 surface, one row in `surfaces.conf` and `map.md`), sourced by both tools.
  `tests/run.sh:test_default_branch_resolution_is_a_single_sourced_lib` now fails if
  either tool re-inlines either half of the resolution.

### A file-mutating verify gate run concurrently with blind gates corrupts the tree they are reading — and fork-bombs Git Bash on Windows
Date        : 2026-09-08
What broke  : During R-005's round-1 gate lane, G5 Proof (the one non-blind gate)
  ran its discrimination proof the way the SESSION-HANDOFF note describes —
  `git show master:tools/ledger.sh > tools/ledger.sh`, run the new tests, swap back.
  It did this in the shared working tree, concurrently with G4 Ripple and G6 Peer
  (blind, reading that same tree) and with the coordinator committing ledger lines.
  The coordinator's `git status` showed `tools/ledger.sh` / `tools/dashboard.sh`
  reverted to `master` mid-round; a `git checkout -- .` in G5 would also have wiped
  the un-committed G1/G7 ledger entries. Separately, running the ~40-min full suite
  alongside five subagents exhausted the Windows/cygwin process table —
  `dofork: child -1 … Resource temporarily unavailable`, `fork: retry`, spurious
  "card is malformed" from `awk` killed mid-read, and eventually the parent Claude
  process itself exited with round-2 gate verdicts logged-but-not-committed.
Root cause  : two independent mistakes. (1) The handoff's "squashed patch, swap files
  for discrimination" recipe assumes the gate has the tree to itself; nothing said
  where to swap. (2) Windows Git Bash `fork()` is the binding constraint and the
  existing "do NOT stack `dashboard.sh` regen on `tests/run.sh`" note did not
  generalise to "or on N subagents."
Now         : (a) a gate that mutates files (G5's discrimination proof, any
  regen-and-compare) works in a throwaway `cp -r`/`git clone` copy under a temp dir,
  never the working tree — state it in the gate's brief explicitly, or give the
  subagent its own worktree. (b) On Windows, the full suite runs BEFORE or AFTER the
  fresh-context gates, not during — the gates use filtered runs. (c) Commit each
  gate's ledger line the moment it reports; a restart erases the intent to commit
  without erasing the work (this was already a 2026-09-06 handoff lesson — it
  recurred here under load, so it is now a rule with a reason, not a note).
