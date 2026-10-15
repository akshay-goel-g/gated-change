# Security review — reject branch-name pseudo-changes at write time (P1-5)

Reviewed commit: `3435db9` — G7 · Threat, fresh context, blind (intent derived from the diff,
not the commit body / SESSION-HANDOFF / INTENT-LOG), single commit
(`git show 3435db9`), against the files as they exist at that sha.

Files in scope, and why each is here:

- **`tools/ledger.sh`** — T4 by `project/surfaces.conf:27`
  (`tools/(reconcile|ledger|…)\.sh$` — "Routing and evidence — a wrong answer here is silent
  and confident"). New `change_is_branchy()` / `refuse_branchy_change()` (`:207-215`), called
  from `cmd_add` (`:383`) and `cmd_route` (`:535`).
- **`tools/reconcile.sh`** — T4, same row. `CHANGE=` is now resolved *after* flag parsing
  (`:87-121`); the `--log` block now captures `ledger.sh route`'s stderr, surfaces a refusal,
  and `exit 2` instead of swallowing it (`:625-651`).
- **`core/01-router.md`** — T4 by `project/surfaces.conf:30` ("The gate matrix itself — every
  tool derives from it"). Prose only: a paragraph telling the reader to set `CHANGE=` on a
  trunk branch (`:71-77`).
- **`tools/dashboard/app.js`** — T1 ("Dashboard assets"), reviewed at full depth anyway:
  this is where an unvalidated `ledger.jsonl` reaches `rail.innerHTML`, and the
  2026-09-01 G7 report named that boundary. New `changeIsBranchy()` (`:161`), the
  `isRoutingArtifact` tag in `buildExecutions` (`:250-254`), the `renderRail` artifact
  branch (`:1255-1265`), and the `changeCount` / auto-select filters (`:309`, `:1310-1312`).
- **`tools/dashboard/app.css`** — T1. Three rules for the muted artifact row.
- **`core/04-ledger.md`**, **`templates/agent-instructions.md`** — T2 / T3 prose: same
  `CHANGE=` instruction. `agent-instructions.md` is `project/surfaces.conf:48`
  ("Pasted into every adopting project's agent file").
- **`tests/run.sh`** (T3), **`tests/dashboard-logic.test.js`** (unmatched) — assertions.
- **`dashboard.html`** — generated artifact (dashboard.sh bakes app.css + app.js in), not
  reviewed directly.

Highest tier in the change: **T4**, so G7 runs as a HARD GATE.

`project/surfaces.conf` here is this repository's own answers (`# SELF: gated-change`;
`templates/surfaces.conf` is the shipped example), so these are the correct boundaries to
review against.

## What the diff does (derived from the diff, not the narrative)

`reconcile.sh` defaults `--change` to `git rev-parse --abbrev-ref HEAD`. Run on a trunk branch
with no `CHANGE=` set, it wrote a route record named `master` — a record that collects
reconciliations from many unrelated changes, never acquires gate records of its own, and which
the dashboard rail rendered as a change where every mandated gate was skipped.

The change closes that on three sides:

1. **Write side (`ledger.sh`).** `cmd_add` and `cmd_route` refuse `--change` in the fixed set
   `{master, main, develop, trunk, HEAD, unknown}` before anything is written — `exit 2`,
   nothing appended.
2. **Caller side (`reconcile.sh`).** An `--action` run defaults `--change` to the *action
   name* (a real identifier from `surfaces.conf`) rather than the branch. The `--log` path
   now captures `ledger.sh`'s stderr; on a non-zero return it prints `RECONCILE NOT RECORDED`
   with the real reason and `exit 2`, where it previously printed
   `(ledger not written — is tools/ledger.sh present?)` and fell through to a tier-only
   exit 0/1.
3. **Read side (`app.js`).** For ledgers written before (1): a branch-named group whose every
   round has zero gate records and no declared `--action` route is tagged
   `isRoutingArtifact`, rendered once, muted, at the bottom of the rail with a plain-text
   note, and excluded from `changeCount` and auto-selection.

## Threat model — who is the untrusted party?

Two boundaries, both already named by prior reports in this directory:

- **Whoever supplies a `ledger.jsonl` to the rendered dashboard** — not only whoever runs
  `dashboard.sh`. `app.js` accepts a ledger by **drag-and-drop** (`wireDropzone`) and
  **re-fetches one over the network** in live mode (`fetchPath`, added 2026-09-01). Neither
  path is written or validated by `tools/ledger.sh`. See
  `security-reports/2026-09-01-dashboard-p0-review-fixes.md` and
  `security-reports/2026-08-13-587e8e1.md`.
- **The caller of `reconcile.sh` / `ledger.sh`** — `--change`, `--action`, `CHANGE=` are raw
  strings from the invocation.

## Trust-boundary walk

### 1 · `app.js` — is the new `.artifact-note` HTML an injection sink?

**No. Traced, not assumed.**

- `changeIsBranchy(name)` is `["master","main","develop","trunk","HEAD","unknown"].indexOf(name) >= 0`.
  `Array.prototype.indexOf` compares with `===`, so it returns true for **exactly** those six
  ASCII string literals and nothing else. A crafted ledger line
  `{"type":"route","change":"master<img src=x onerror=alert(1)>", …}` does **not** satisfy it
  — `indexOf` returns `-1` — so such a group is never tagged `isRoutingArtifact` and never
  enters the artifact branch. It renders through the normal `escapeHtml(titleCase(cg.change))`
  path (`app.js:1266`), unchanged by this diff.
- Inside the artifact branch, `cg.change` is therefore provably one of the six safe literals —
  and it is *still* passed through `escapeHtml(cg.change)` (`app.js:1258`) before
  interpolation. Belt and braces; no way to reach `rail.innerHTML` with markup.
- `n` (`app.js:1256`) is `cg.rounds.reduce((s,r) => s + r.routes.length, 0)`. `r.routes` is
  constructed as an array by the ingest loop (`ex.routes.push(r)`), `.length` is a
  non-negative integer, and the accumulator seed is `0`. A crafted `routes` array cannot make
  `n` a string or an object — a ledger consumer never assigns `ex.routes`, it only pushes to
  it. `n` is interpolated as a text node, and `n === 1` is a strict compare for the plural.
  No breakout, no type confusion.
- The rest of the `.artifact-note` string is static; `&lt;name&gt;` is already entity-encoded
  in source.

The 2026-09-01 report's rule ("every render of a `.round` goes through `escapeHtml()`/`attr()`;
do not add a raw one") is upheld for this new `.change` render too.

### 2 · `ledger.sh` — does `refuse_branchy_change` echo `$1` unsafely?

**No.** `refuse_branchy_change` does `echo "REFUSED: --change '$1' …" >&2` — `$1` sits inside a
double-quoted string passed to `echo`; the shell expands the parameter but does not re-parse
its contents, so `$( )`, backticks, `;`, `|`, `&`, `>` in `$1` are inert. `change_is_branchy`
uses `case "$1" in master|main|…` — `$1` is the quoted *subject*, not a pattern, so no glob or
word-splitting on it either. This matches every other `REFUSED: … '$x'` site in the file
(`:135` predicted tier, `:284` action name, `:225` malformed rows) — the new code introduces
no pattern the file did not already rely on. Terminal-control-sequence bytes in `$1` would be
emitted verbatim to a TTY, but that is a pre-existing, uniform property of the file's error
output, not a regression from this change. **Info only.**

### 3 · `reconcile.sh` — can `--action` inject via the `--change` field?

**No — `$ACTION_NAME` is validated before it becomes `$CHANGE` on the write path.** Order:

1. `--action) ACTION_NAME="$2"` (`:105`).
2. `CHANGE="$ACTION_NAME"` when `CHANGE=` was unset (`:117`).
3. `ACTION_NAME` is looked up against the `ACTION::TIER::NAME::EVIDENCE` rows of
   `$CONF`; if no row's NAME field matches exactly, `REFUSED: no ACTION row named
   '$ACTION_NAME'` and `exit 2` (`:283-295`). The shape validator just above also refuses
   any ACTION row whose NAME or EVIDENCE contains a stray `::` (`:230-239`).
4. Only then does the `--log` block (`:625`) call
   `ledger.sh route --change "$CHANGE" …`.

So `--action 'master","x":"y'` requires an operator-authored `surfaces.conf` row literally
named `master","x":"y` — and `surfaces.conf` is itself the T4 trust boundary; anyone who can
write it already owns all routing. Even then, `cmd_route` renders the field as
`"change":"%s"` with `"$(json_escape "$change")"` (`ledger.sh:585`) — `json_escape` escapes
`\` then `"` then tab/CR then folds newlines, so `"` becomes `\"` and there is no JSON
breakout. This diff does not touch that emit path; `change_is_branchy` is a pre-check that
either `exit`s or falls through to the unchanged `json_escape` + `emit`. **Covered, layered.**

### 4 · Privilege / boundary — does the refusal let a legitimate record be suppressed?

This is the one place the change trades one failure mode for another, and it is worth naming.

- **Before:** a reconcile on a trunk branch with no `CHANGE=` wrote a route record named
  `master`. Mislabeled, correlates with nothing, mis-rendered — but *present*, and the
  read-side guard in this same commit now renders it harmlessly.
- **After:** the same invocation (`reconcile.sh T2 --log`, or `ledger.sh add --change master
  …`) `exit 2`s and writes **nothing**. For a shop doing genuine **trunk-based development**
  — all work lands on `main` / `master` / `trunk`, no per-change branch — every
  `--log` and every `ledger.sh add` that forgets `CHANGE=` now produces a *hole* in the audit
  trail instead of a *mislabeled row*. If such a project's convention is to pass the branch
  name as the change identifier (e.g. a CI wrapper that does `CHANGE=$(git branch --show-current)`),
  there is **no override flag** to record legitimate work under the name `main` — the value is
  simply unusable, and `ledger.sh compliance --change main` will then find zero gate records
  where real ones existed before.

This is not adversarially reachable — the `--change` / `CHANGE=` value is chosen by the
operator, not by a hostile input, so an attacker cannot force a victim's real change to be
named `trunk`. It is a **self-inflicted availability regression** for one legitimate workflow,
and it is loud (exit 2, a five-line message naming the fix) and documented in three files. It
is aligned with the kit's own stated philosophy (`surfaces.conf` Q1: "a confident wrong answer
… is silent and confident" — refuse loudly instead). Rated **minor**: real, newly introduced,
no escape hatch, but loud and operator-scoped.

`cmd_escape` (`ledger.sh:596`) is **not** given the `change_is_branchy` check — only `cmd_add`
and `cmd_route`. `ledger.sh escape --change master` still writes. Minor inconsistency; escape
is always a deliberate manual act naming a historical change, so the omission is defensible.
**Info.**

### 5 · `reconcile.sh` exit 2 on a refused `--log` — does the pre-push hook fail open or closed?

**The shipped pre-push hook (`templates/pre-push`) never runs `reconcile.sh`.** It greps the
changed-file list against the `surfaces.conf` trust regex and checks that a report in
`security-reports/` names the HEAD sha (`:126-149`); it then regenerates the dashboard
(`:214-262`) and `exit 0`s. `tools/hooks/r0c-post-edit.sh` only *prints* a `reconcile.sh`
command in a reminder string (`:112`), it does not execute it. So reconcile's exit code is
consumed by the **agent / developer** following `agent-instructions.md` step 3, and by
`tests/run.sh` — not by any hook.

For that consumer the change is a **fail-closed improvement**: previously a `--log` whose
`ledger.sh route` was refused printed `(ledger not written — is tools/ledger.sh present?)` and
the script continued to a tier-only `exit 0` ("Reconciled") or `exit 1` — i.e. R0b's "a
reconciliation must be recorded" was silently unmet while the script reported success. Now the
same situation is `exit 2` with `RECONCILE NOT RECORDED` on stderr. The stderr/exit-code
capture (`_route_err=$(… 2>&1 >/dev/null); _route_rc=$?`) has the redirection order right:
stderr is captured, stdout is discarded. A wrapper that switched specifically on
`[ $? -eq 1 ]` to detect under-classification would now see `2` first and miss that branch —
but no such consumer exists in the kit, and the message is explicit. **Info.**

## T4 boundary check

Three T4 rows are matched: `tools/ledger.sh` and `tools/reconcile.sh`
(`project/surfaces.conf:27`), and `core/01-router.md` (`:30`). Walked each:

- `core/01-router.md` — **prose only**. A new advisory paragraph; the gate matrix table below
  it is untouched. No tool derives behavior from the new text.
- `tools/ledger.sh` — a new pure allowlist predicate and a new refusal function; two call
  sites, both *before* `emit`. No change to `json_escape`, `emit`, `finding_json`, or the
  bare-position integer checks. Privilege is **narrowed** (six new refused inputs), not grown.
- `tools/reconcile.sh` — `CHANGE=` resolution moved after flag parsing; the `--log` block
  now propagates a downstream refusal instead of masking it. No new external input, no new
  file or network access, no privilege growth.

**No trust boundary is crossed without a check. No privilege grew. The one behavioral
regression (§4) is operator-scoped, loud, and not attacker-reachable.**

## Verdict

**PASS.** Every injection vector traced to a real terminus: the `app.js` allowlist is a
strict-equality membership test and the value is escaped regardless; `ledger.sh`'s refusal
message quotes `$1` the same safe way the rest of the file already does; `reconcile.sh`'s
`--action → --change` path is validated against `surfaces.conf` before the write and
`json_escape` still covers the field. The `--log` exit-2 change is a fail-closed improvement
over a previously silent miss. One **minor** finding (§4): the branch-name blocklist has no
override, so a trunk-based-development project that forgets `CHANGE=` now gets an audit-trail
hole instead of a mislabeled record — loud and documented, but a real regression for that
workflow. No unresolved finding at blocking severity.

## Findings

| Severity | Location | Claim |
|---|---|---|
| minor | `tools/ledger.sh:207` | `change_is_branchy` blocks `{master,main,develop,trunk,HEAD,unknown}` as `--change` in `cmd_add`/`cmd_route` with no override flag. A trunk-based-development project (work lands on `main`/`trunk`, no per-change branch) that forgets `CHANGE=` now gets `exit 2` and an unrecorded reconciliation / gate — an audit-trail hole where a mislabeled-but-present record existed before. Not attacker-reachable (the value is operator-chosen); loud and documented in 3 files. |
| info | `tools/reconcile.sh:625` | `--log` now propagates `ledger.sh route`'s non-zero exit as `exit 2` with `RECONCILE NOT RECORDED`, replacing a silent fall-through to a tier-only `exit 0/1`. Fail-closed improvement. No hook consumes this exit code — `templates/pre-push` never runs `reconcile.sh`; the consumer is the agent per `agent-instructions.md` step 3. |
| info | `tools/ledger.sh:161` / `tools/dashboard/app.js:161` | `changeIsBranchy` / `change_is_branchy` are duplicated allowlists in two languages, kept in sync by hand. Drift would only ever *narrow* what the read-side mutes vs. what the write-side refuses (or vice versa) — no security impact, but a maintenance hazard the code comments already acknowledge. |
| info | `tools/ledger.sh:596` | `cmd_escape` is not given the `change_is_branchy` check that `cmd_add`/`cmd_route` got; `ledger.sh escape --change master` still writes. Defensible (escape is a deliberate manual act) but inconsistent. |
| info | `tools/dashboard/app.js:1258` | `.artifact-note` HTML built by string concatenation into `rail.innerHTML`; `cg.change` is provably one of six literals here (strict-`===` allowlist) *and* is `escapeHtml()`-wrapped; `n` is a numeric `reduce`. No injection reachable. Noted because the sink class matches the 2026-09-01 report's flagged sinks. |
| info | `project/surfaces.conf:27,30` | Three T4 rows matched (`ledger.sh`, `reconcile.sh`, `01-router.md`). `01-router.md` change is prose only; the two shell changes narrow accepted input and add no external surface. No boundary crossed without a check; no privilege grown. G7 ran as a T4 hard gate. |

Full suite not re-run as part of this review (blind, diff-only). The seven added tests
(3 in `dashboard-logic.test.js`, 4 in `run.sh`) assert the allowlist, the feature-branch
pass-through, the `--action` fallback name, and the `--log` refusal surfacing + exit 2.

---

## Round 2 addendum — commit `08c61a0` (G7 · Threat, inline, not fresh-context)

Round 2 responds to this report's own findings and G4 Ripple's. Changes: the
`change_is_branchy` allowlist gained four names; `cmd_escape` and `cmd_assume` now call the
same guard (closing the `info` finding above); the `reconcile.sh` "RECONCILE NOT RECORDED"
message was reworded; `project/risks.md` gained **R-005** for the hand-enumerated-list residue
this report's `info` finding flagged.

No new attack surface. The escape/assume guard is the identical `change_is_branchy "$1" &&
refuse_branchy_change "$1"` line — same `case "$1"` matcher, same quoted-parameter `echo` to
stderr — already traced here. The four added list entries are literal strings in the same
`case`. The message reword is stderr text. `risks.md` is not a trust surface. The round-1
finding about the missing override flag stands unchanged (R-005 records only the
non-standard-trunk-name residue, not the override question).

---

## Round 3 addendum — commit `332d457` (G7 · Threat, inline)

Round 3 responds to G5 Proof / G6 Peer round-2 minors. Changes: `change_is_branchy`'s list
trimmed (removed `mainline`/`release`/`stable`, added `dev`) — this **narrows** the set of
`--change` values accepted, the safe direction; `refuse_branchy_change`'s stderr message
genericised (no behavior change); two new tests (`test_branchy_change_list_matches_between_
ledger_and_dashboard` pins the two hand-kept lists equal, closing the drift hazard this
report's `info` finding flagged; `every changeIsBranchy name drives the routing-artifact tag`
exercises the read-side guard for every name). No new input, sink, persisted field, network,
or privilege. No trust boundary crossed that round 1 did not already cover.

The records commit on top (`321f598`) changes only `ledger.jsonl`, `dashboard.html`,
`SESSION-HANDOFF.md`, `INTENT-LOG.md`, `LEARNINGS.md`, and this file — no code.
