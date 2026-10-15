# Security review — R0c Claude Code PostToolUse hook (tools/hooks/r0c-post-edit.sh, tools/install-claude-hook.sh)

Reviewed commit: working tree at the point of writing — self-authored fresh-context G7 pass
over new, previously-unreviewed files (not a diff against a prior reviewed state, since these
files did not exist before this branch). Report is filed before the commit that will carry it,
same reasoning as `security-reports/2026-08-15-dashboard-branch-pre-push-and-ledger-date.md`
gives for why the hash it can name and the hash that ends up on disk are necessarily different
by one commit — this report is named in the ledger entry that accompanies its own commit, not
by a HEAD sha inside its own text.

Files in scope: `tools/hooks/r0c-post-edit.sh`, `tools/install-claude-hook.sh`.
Trust-boundary basis (`project/surfaces.conf`, both rows added by this same change): `tools/
hooks/` is T4 ("Enforcement — the R0c reminder's own success is silent, so its failure is
too"); `tools/install-claude-hook.sh` is T4, folded into the existing `install-hook` row
("Routing and evidence — a wrong answer here is silent and confident").

## What these files do

1. **`tools/hooks/r0c-post-edit.sh`** — a Claude Code `PostToolUse` hook. Reads a JSON payload
   on stdin, extracts `tool_name` and `tool_input.file_path` by `sed` (the same
   extract-one-known-key idiom `tools/dashboard.sh`/`tools/ledger.sh` already use, not a
   parser), and — for `Edit`/`Write`/`MultiEdit` only — checks the file path against the T3/T4
   rows of `project/surfaces.conf`. On a match, prints a reminder naming the matched row and
   exits `2`; otherwise exits `0` silently.
2. **`tools/install-claude-hook.sh`** — merges a `PostToolUse` entry pointing at that script
   into `.claude/settings.json`, using python for the merge (refuses and prints a manual
   snippet instead when python is unavailable, never attempting a text-level splice into JSON
   it does not own).

## Trust boundary walk

- **`r0c-post-edit.sh`, is `$FILE_PATH` an injection sink?** Traced every use: (1) subject of
  `grep -qE "$rule"` — `$FILE_PATH` is the string being matched, never the pattern, so
  attacker-controlled content here cannot become a ReDoS or injection vector against the
  regex engine; the pattern itself (`$rule`) comes from `surfaces.conf`, a project-owned file,
  not from the hook payload. (2) Interpolated into an **unquoted** heredoc
  (`cat >&2 <<EOF ... $FILE_PATH ... EOF`) for the reminder message. Unquoted heredocs do
  perform parameter expansion on `$FILE_PATH` as written in the script — but that expansion is
  single-pass: the *value* substituted in is not re-scanned for further `$()`/backtick
  expansion, the same guarantee `"$FILE_PATH"` in a double-quoted string already has. Verified
  live, not just reasoned about: fed `{"tool_name":"Edit","tool_input":{"file_path":"$(touch
  /tmp/pwned)/tools/ledger.sh"}}` on stdin — a path crafted to both (a) match the T4 rule
  (the payload sits before the anchored `tools/ledger\.sh$` suffix the rule requires, so
  `(^|/)` still finds a `/` immediately before `tools/`) and (b) carry a real,
  executable-if-evaluated `$(touch /tmp/pwned)`. The hook matched, printed the string
  verbatim in the reminder, exited `2` as expected — and `/tmp/pwned` was never created,
  confirming no nested evaluation of the heredoc-interpolated value. `$FILE_PATH` never
  reaches `eval`, a command substitution position, or any other re-interpreted context.
- **`r0c-post-edit.sh`, malformed or adversarial JSON on stdin.** The `sed` extraction is
  intentionally narrow (`.*"file_path":"\([^"]*\)".*`) — it cannot capture a value containing
  an embedded `"`, which Claude Code's own JSON encoding would already escape as `\"`, so a
  legitimate payload never trips this; an adversarial payload crafted to *break* the
  extraction (no `file_path` key, empty stdin, truncated JSON) makes `FILE_PATH` empty, which
  the very next line (`[ -n "$FILE_PATH" ] || exit 0`) already handles as a clean no-op, not a
  crash. Live-reproduced: empty stdin, `{}`, and `not json at all` on stdin all exit `0` with
  no output.
- **`r0c-post-edit.sh`, what does exit `2` actually do?** Nothing destructive — `PostToolUse`
  hooks fire *after* the tool call already completed; exit `2` only surfaces the stderr text
  back to the calling agent as something to act on. There is no privilege here beyond "print a
  message," so there is no meaningful blast radius from a false positive, and a false negative
  (fails open with no `surfaces.conf`, or on a regex that happens not to match) degrades to
  exactly the memory-dependent status quo this hook improves on — not to something worse.
- **`install-claude-hook.sh`, does untrusted content reach the JSON it writes?** `COMMAND` is
  built entirely from `git -C "$KIT" rev-parse --show-prefix` (git-computed, not
  caller-influenced) and a fixed literal path suffix — no field of the hook payload, no
  environment variable beyond `KIT`/`HOME`, and no argument this script accepts feeds into the
  written JSON. The one value that IS spliced into hand-built JSON text without a library
  (the no-python fallback snippet) is that same fully-derived `$COMMAND` — traced and fixed a
  real escaping bug here during development (unescaped embedded `"` produced invalid JSON);
  see `LEARNINGS.md`, locked down by
  `test_install_claude_hook_refuses_and_prints_a_valid_snippet_without_python`, which parses
  the actual fallback output with `json.loads` rather than pattern-matching it.
- **`install-claude-hook.sh`, can it corrupt a settings.json it does not own?** The python
  merge path parses with `json.load` first and refuses (exit `2`, file untouched) on anything
  that doesn't parse or isn't a JSON object — live-reproduced against `{ not json` — rather
  than falling back to a text-level append that could produce a broken file. Idempotency is
  checked by exact `command` string match before appending, so re-running never duplicates an
  entry; live-reproduced across two consecutive installs plus a merge into a settings.json
  that already held an unrelated `PostToolUse` entry and an unrelated `permissions` block, both
  of which survived untouched.

## Findings

No findings, blocking or minor. One real bug was caught and fixed during development (the
no-python fallback's unescaped JSON snippet) — recorded in `LEARNINGS.md` and pinned by a test
that parses the actual output rather than re-reading the fix, not left as an open finding here.

## Test evidence

- `bash tests/run.sh r0c` → `passed 17 · failed 0 · skipped 0` (hook-script behavior: T3
  match, T4 match, non-match silence, non-Edit/Write/MultiEdit tools ignored, MultiEdit
  coverage, fails open with no `surfaces.conf`, message names the specific matched row)
- `bash tests/run.sh install_claude` → `passed 22 · failed 0 · skipped 0` (fresh install
  produces valid JSON; idempotent re-run; merge preserves unrelated existing settings content;
  refuses on corrupted JSON without touching the file; refuses with no T3/T4 rows; no-python
  fallback both refuses correctly and prints a snippet independently verified as valid JSON via
  `python -c "json.loads(...)"` against the hook's actual captured stdout)
- Manual injection probes against `r0c-post-edit.sh` (heredoc interpolation, malformed/empty
  stdin) described in the Trust boundary walk above, run directly, not simulated.

## Outcome

**PASS.** Both new files traced end to end. `r0c-post-edit.sh` has no path from its one
untrusted input (`tool_input.file_path`) to command execution, and its failure modes (missing
config, malformed stdin) degrade to silence rather than error. `install-claude-hook.sh` never
lets untrusted content reach the JSON it writes, refuses cleanly rather than guessing on
parse failure, and the one real defect found during development (a hand-built fallback string
that wasn't valid JSON) was caught before shipping and is now regression-tested against actual
output, not just the fix's own reasoning.

Logged: `ledger.sh add --change r0c-claude-hook --gate G7 --tier T4 --round 1 --outcome pass
--confidence high --challenged false --model claude-sonnet-5 --note "self-authored
fresh-context G7 pass on the two new T4 files this branch adds (tools/hooks/r0c-post-edit.sh,
tools/install-claude-hook.sh); see security-reports/2026-08-15-r0c-claude-hook.md"`.
