# Security review — round 2 re-verification of the content-script T4 fix

Reviewed: the uncommitted working tree (`git diff HEAD`) on top of base commit
`9eff9f7929e51138746c83a8d68229e024137f21`. Scope for this report: the T4-tiering fix in
`templates/project/surfaces.conf`, and the routing/prose changes in `core/00-start.md`,
`core/01-router.md`, `core/14-phases.md`. `core/01-router.md` is itself a T4 surface per this
repo's own `project/surfaces.conf:29` ("The gate matrix itself — every tool derives from it"),
so this gate is a HARD GATE for this diff, independent of the content-script question.

## Round-1 finding: resolved for the common case, not fully

Round 1 (`security-reports/2026-08-13-extension-phases-narrow-pass.md`) found that
`templates/project/surfaces.conf` had zero coverage for content scripts — MV3's
highest-privilege, most commonly `<all_urls>`-injected surface — and reproduced it by tiering
`src/content-scripts/inject.js` as T0.

Independently reproduced with different paths than round 1 used. Built a scratch repo
(outside this checkout) with four files and ran `BASE=HEAD CONF=<new surfaces.conf>
bash tools/reconcile.sh T1`:

| Path | Tiers as |
|---|---|
| `content-scripts/inject.js` | **T4** (correct) |
| `content_script/inject2.js` | **T4** (correct) |
| `contentScripts/inject3.js` (camelCase) | **T0 — not caught** |
| `content-script.js` (single file, no directory) | **T0 — not caught** |

**The new row (`T4::(^|/)content[-_]?scripts?/::...`) resolves the round-1 finding for the
hyphen/underscore directory convention it targets — dash/underscore, singular/plural,
nested at any depth.** It does not catch camelCase directory names or single-file content
scripts (e.g. a top-level `content.js`), both of which are real MV3 layouts. This is a
narrower gap than round 1's — a single unrouted convention among several, not zero
coverage — and is judged **minor**, not blocking: the row's own comment scopes it as the one
universal case, not exhaustive coverage, and the dominant convention (a `content-scripts/`
or `content_script/` directory) is now caught.

## Anchoring — verified against this file's own documented rule

Confirmed by direct grep -E test, not inspection: the new/changed rows (`content-scripts`,
`.pem$`, `update\.xml$`, `messages?|messaging`, the T2 UI-surface additions) match only a full
path segment or a full filename, never a substring. No false positive against adversarially
chosen near-miss names: `pemphigus.md`, `updatexml.js`, `instantmessages.js`,
`some-non-content-scripts-related-file.js`, `notcontent-scripts/foo.js`, `devtoolsy/x.js` all
correctly do not match.

## Parser / regex integrity

Read `tools/reconcile.sh`'s parser (lines 259–282: split each line on first/last `::`, skip
`#`/`TARGET::`/`IGNORE::`/blank) against the full current `templates/project/surfaces.conf`.
Every row, old and new, is a single physical line — no label wraps, no truncation. Compiled
every `T1..T4`/`IGNORE` regex in the file with both `grep -E` and Python's `re` module: all
compile cleanly, no catastrophic-backtracking shapes, no unbalanced groups.

## Out-of-scope observation, not a security finding

The working tree also modifies `tools/ledger.sh`, `tests/run.sh`, and `ledger.jsonl` with an
unrelated fix (JSON-injection via unescaped `--lane`/`--found-by`/etc. fields reaching a bare
position in the emitted record) plus its own regression tests. That is a real, separate fix,
not incidental to this diff's stated subject, and mixing it into the same uncommitted change
as the content-script/router/phases work is a scope-separation issue for G4/G6 to flag, not a
threat finding against this fix.

## Test evidence

`bash tests/run.sh` (full suite, run against this working tree): **270 passed · 0 failed · 0
skipped**, exit 0.

## Verdict

**PASS.** No unresolved finding above low. The round-1 T4-routing gap is resolved for the
convention it names; the camelCase/single-file gap is a new, narrower, minor finding — track
it, do not block release on it. `core/01-router.md`'s new R0b release-time `BASE=<tag>`
guidance is accurate and does not weaken any existing hard-gate requirement.
