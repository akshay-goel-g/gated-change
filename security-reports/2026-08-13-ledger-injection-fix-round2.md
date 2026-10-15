# G7 · Threat review (round 2) — ledger.sh JSON-injection fix, re-verification

**Base commit reviewed:** `9eff9f7929e51138746c83a8d68229e024137f21` — "docs: session handoff
and intent log for the review-and-fix pass". **The actual subject of this review is the
UNCOMMITTED working tree on top of that commit** (`git diff HEAD -- tools/ledger.sh
tests/run.sh`), which contains the fix for the round-1 finding below. No new commit exists yet
for this fix at review time.
**Prior finding this re-verifies:** `security-reports/2026-08-13-587e8e1.md` — BLOCKING,
unescaped/unvalidated scalar fields (`--lane` and others) let a caller splice a forged
duplicate JSON key into a ledger record, making `compliance` report PASS for a gate that had
logged `fail` with a blocking finding.
**Trust surfaces consulted:** `project/surfaces.conf` rates `tools/ledger.sh` T4: "Routing and
evidence — a wrong answer here is silent and confident." `project/registry.md` and
`project/map.md` are both unpopulated templates — no entries apply to this change.

## Verdict on the round-1 finding: RESOLVED

Reproduced the exact round-1 payload (`--lane 'normal","outcome":"pass","confidence":"fresh'`
against `cmd_add`) live. The write now succeeds but the record is correctly escaped
(`"lane":"normal\",\"outcome\":\"pass\",\"confidence\":\"fresh"`), contains exactly one
`"outcome"` key, and `compliance` correctly reports `FAIL G7 ... re-run required before
release` rather than the forged `PASS`. Verified structurally (grep for duplicate keys) and
semantically (`ledger.sh compliance` output), not just "still parses as JSON."

## What I tried to break it further

Beyond replaying the known payload: quote/backslash/nested-quote combinations and a trailing
lone backslash in `--note`, a quote+comma combo in `--model`, `--commit`, `--found-by`,
`--severity`, `--predicted`/`--actual`/`--reason` (`cmd_route`) and `--found-by`/`--severity`
(`cmd_escape`); an embedded raw newline inside `--note` (folds to literal `\n`, stays one
line); attempts to break the now-bare-position fields — non-integer/negative/`+`-prefixed/
whitespace-padded `--round`, `--minutes`, `--tokens`, and non-`true`/`false` `--challenged`
(`True`, `1`) — all correctly `REFUSED` with exit 2 and nothing written; malformed `--gate`
and `--tier` values containing injected JSON — correctly `REFUSED`; confirmed `--tier ''`
(empty) and `--gate G9` (a project-authored 9th gate per `core/06-extending.md`'s own
example) are both still accepted, so the new validation isn't over-strict against a
documented legitimate case. Every accepted record across ~15 payloads was validated with
Python's strict `json.loads` (the same check `tests/run.sh`'s `assert_jsonl_valid` uses) — all
valid, no duplicate keys, no forged values. Ran `bash tests/run.sh test_ledger_`: **76 passed,
0 failed, 0 skipped**.

## Findings

### MINOR — `is_uint` accepts leading zeros, producing lines invalid under strict JSON parsers

`tools/ledger.sh:147` (`is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }`)
accepts any all-digit string, including `"007"`. That value lands in the **bare** JSON
position (`"round":%s` at `tools/ledger.sh:417`), producing e.g. `"round":007`. Per RFC 8259 a
JSON number may not have a leading zero (except the literal `0`); confirmed this is rejected
by Python `json.loads`, Node's `JSON.parse`, and is the same check `assert_jsonl_valid`
(`tests/run.sh:153`) runs against every ledger line in the test suite. `tools/dashboard/app.js`
wraps its `JSON.parse` in try/catch (`tools/dashboard/app.js:89-90`) and counts the line as
"unparsed" rather than crashing, so this is not an outage — it is a silent drop of a
legitimately-logged gate run from the dashboard's stats, from an honest, non-malicious value
(e.g. someone zero-pads round numbers, or scripts `--round $(printf '%03d' "$n")`). This is
not a forgery — no key duplicates, no value is spoofed — so it does not reopen the round-1
vulnerability class, but it is a real gap against this file's own stated bar ("a ledger that
cannot be read back is the same as no ledger," `tools/ledger.sh:161-162`) and isn't covered by
any of the new tests (all use single-digit values). Same gap applies to `--minutes`,
`--tokens`, and (in `cmd_route`) `--round`.

**Affected:** `tools/ledger.sh:147` (`is_uint`), consumed at `tools/ledger.sh:336-344,
462-464`.

### Carried forward, still present, non-blocking — INFO from the round-1 report

`json_escape()` (`tools/ledger.sh:206-210`, unchanged by this fix) still does not escape C0
control characters other than tab/CR (form feed, vertical tab, a literal NUL if bash permits
it in an argument). Most parsers are lenient; noted for completeness, not blocking, same as
round 1.

## Verified clean

- Duplicate-key forgery via any of `--lane`, `--tier`, `--gate`, `--challenged`, `--round`,
  `--minutes`, `--tokens`, `--outcome`, `--confidence`, `--model`, `--note`, `--commit`
  (`cmd_add`); `--predicted`, `--actual`, `--reason`, `--round` (`cmd_route`); `--found-by`,
  `--severity`, `--note` (`cmd_escape`) — all either escaped in a quoted context or
  structurally validated in a bare context, live-tested and confirmed.
- `looks_like_tier`/`looks_like_gate` (`tools/ledger.sh:154-155`) are loose by design (shape,
  not enum) so a project-authored `G9`+ and empty `--tier` still work — checked directly
  against `core/06-extending.md`'s own G9 example rather than assumed.
- `bash tests/run.sh test_ledger_`: 76/76 passed.

## Recommendation

Not blocking for this fix — the round-1 forgery is closed and no new injection/forgery vector
was found. Tighten `is_uint` to reject leading zeros (`case "$1" in 0|[1-9]*([0-9])) return
0;; *) return 1;; esac` or equivalent) as a small follow-up so a legitimately-logged run is
never silently dropped by a strict-JSON consumer.
