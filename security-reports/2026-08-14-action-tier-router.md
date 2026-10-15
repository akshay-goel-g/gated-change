# Security review — the ACTION::TIER::NAME::EVIDENCE router mechanism

Reviewed commit: `05eaa89` ("router: ACTION::TIER::NAME::EVIDENCE — declared events for a
diff-blind router") — the fresh-context G7 pass below reviewed this commit.
Fix commit: `3cb89d2` ("router: fix G6 round-1 findings on the ACTION row parser") — not
independently fresh-reviewed by G7 (G7 passed round 1 with no blocking/minor findings, so the
failure rule did not mandate a G7 re-run); self-verified below as a defense-in-depth check,
since the fix touches the same parser G7 already traced.

Files in scope: `tools/reconcile.sh`, `tools/ledger.sh`, `templates/project/surfaces.conf`.
Trust-boundary basis: `project/surfaces.conf:27-28` rates `tools/(reconcile|ledger|install-hook)\.sh$`
and `core/01-router\.md$` T4 ("Routing and evidence — a wrong answer here is silent and
confident" / "The gate matrix itself — every tool derives from it").

## Trust boundary walk

The new untrusted-ish input surface is two CLI flags (`--action NAME`, `--evidence
"<citation>"`) and one new config row kind (`ACTION::TIER::NAME::EVIDENCE` in
`surfaces.conf`). Neither is attacker-controlled in the classic remote sense — both come from
whoever is running the release process — but `surfaces.conf` is exactly the kind of file this
repo's own `project/surfaces.conf` rates T4 ("a wrong answer here is silent and confident"),
and `--evidence` is free text that reaches a JSON-emitting `printf` template in `ledger.sh`.
Traced every consumer, fresh-context (G7 round 1) plus self-verified extensions:

- **`ACTION_NAME`/`EVIDENCE` reaching `grep -E`** (`reconcile.sh`'s path-tiering loop): the
  ACTION-row parser (`_action_parse()`, `reconcile.sh:143-152`) never feeds a NAME or EVIDENCE
  value into the `grep -E "$regex"` call the path-tiering loop uses — the loop's own case
  statement excludes `ACTION::` lines before that point is ever reached. Live-reproduced the
  attack this exclusion prevents: a NAME containing `|` (e.g. `x|theme`), if the exclusion were
  removed, gets misparsed by the ORIGINAL (pre-this-change) `*::*::*` path-rule branch into the
  regex `T4::x|theme` — an alternation whose second arm (`theme`) matches any path containing
  that substring. Confirmed live both ways: with the exclusion removed, this row incorrectly
  printed a bogus `ACTION  src/theme.css  desc` hit line; with the exclusion in place (the
  shipped code), it contributes nothing. Pinned by
  `test_action_row_alternation_in_name_never_leaks_into_path_tiering` (`tests/run.sh`).
- **`ACTION_NAME`/`EVIDENCE` reaching the ledger's JSON template** (`ledger.sh cmd_route`):
  both new fields go through `json_escape()` before being spliced into the `printf`-built JSON
  object (`ledger.sh:511-513`, `emit "$(printf ... "%s" "%s" ...)"`), the same function every
  other free-text field in this file (`reason`, `note`, `claim`) already uses. Live-reproduced
  a forgery attempt: `--action 'store-publish","evidence":"forged","verdict":"match'
  --evidence 'cite" broken'` — the resulting line is valid JSON with exactly one `"evidence"`
  key (verified via `grep -o '"evidence"' | wc -l` = 1, and `assert_jsonl_valid`), not a
  duplicate-key forgery of the kind `ledger.sh`'s own `emit()` was hardened against earlier
  this session (`c53f749`). Pinned by `test_ledger_route_escapes_action_and_evidence`.
- **Neither field reaches an unescaped shell context.** `EVIDENCE` and `ACTION_NAME` are only
  ever used in `[ ]` string comparisons, `case` pattern matches (with the value on the *scrutinee*
  side, not the pattern side, so shell glob metacharacters in a value do not act as patterns),
  and `printf '%s'`/`json_escape` calls — never `eval`'d, never interpolated into a command
  string that is itself re-parsed by the shell.
- **The paired-presence refusal (`--action` requires `--evidence` and vice versa) is enforced
  twice, independently** — once in `reconcile.sh` before any git/file work, once again inside
  `ledger.sh route` itself. `ledger.sh` is the one piece of this kit `core/04-ledger.md` calls
  "not self-graded," and it does not trust `reconcile.sh`'s own check; a call to `ledger.sh
  route --action X` with no `--evidence`, bypassing `reconcile.sh` entirely, is independently
  refused. Live-reproduced both directions
  (`test_ledger_route_action_requires_evidence`, `test_ledger_route_evidence_requires_action`).

**Self-verified extension against the fix commit (`3cb89d2`), not independently
fresh-reviewed:** the four G6 round-1 findings this fix closes are correctness/robustness gaps
(a malformed row silently accepted, a duplicate NAME silently shadowed), not new sinks — the
fix adds refusals to the same `_action_parse()` extraction G7 already traced, using the same
`case`/`[ ]` constructs, no new `printf`/`grep`/`eval` call sites. Re-ran the alternation and
JSON-escaping tests above against `3cb89d2` directly: both still pass.

## Findings

- info::tools/reconcile.sh:143-152,`_action_parse()`::the same duplicate-NAME gap G6 filed
  (round 1) had a threat-model reading too — an insider with write access to `surfaces.conf`
  appending a second, lower-tier row sharing an existing NAME could attempt to shadow the
  original, though the pre-fix first-match-wins lookup order worked against that specific
  direction (the FIRST row always won, so a lower-tier row appended LATER could not
  silently downgrade an existing one — the opposite risk, an accidental fix silently losing
  precedence, was G6's actual finding). Closed either way by the round-2 fix: duplicate NAMEs
  now refuse outright rather than resolving via file order in either direction.

No blocking or minor findings. `passes_when: no unresolved finding above low` — met.

## Test evidence

Targeted regression run (not the full 280-test suite — this environment's full run takes
20+ minutes; kept fast and targeted per this session's own process note): 123/123 assertions
across `reconcile`/`action`/`ledger`/`compliance`/`matrix`/`surfaces`-filtered tests, plus
58/58 on the `action`-specific subset after the round-2 fix, 0 failures throughout. The
alternation-injection and JSON-escaping claims above are live-reproduced, not reasoned-only —
shown inline where each is made.

## Outcome

**PASS.** No unresolved finding above `info`. Neither `--action`/`--evidence` nor the new
`ACTION` row kind cross a trust boundary without a check, and no privilege grows unremarked —
the mechanism's whole purpose is to make an existing, unrouted T4 event *visible* to the
ledger, and it does not introduce a new way to claim a lower tier than the truth: `ACTUAL` is
computed as the max of the diff-based hits and the declared action's tier, never overridden
downward by `--action`.

**Named, not silently closed:** this report covers what the mechanism's own code does with the
input it receives. It does not, and cannot, cover whether a human or agent actually invokes
`--action` at the moment a real publish event happens — that gap is process discipline, named
explicitly in `01-router.md`'s R0d and `LEARNINGS.md`, not a code defect this gate's `owns`
field (adversarial reachability) is positioned to catch.
