# Security review — uncommitted working tree on top of 9eff9f7929e51138746c83a8d68229e024137f21

Reviewed: the uncommitted working-tree diff (`git diff HEAD`) on top of commit
`9eff9f7929e51138746c83a8d68229e024137f21` ("docs: session handoff and intent log for the
review-and-fix pass"). This report covers the working tree, not that commit itself — the
commit predates the diff under review; `git status` shows no other pending commits.

Files in scope: `templates/project/surfaces.conf`, `core/00-start.md`, `core/01-router.md`,
`core/14-phases.md`, `LEARNINGS.md`, `INTENT-LOG.md`, `SESSION-HANDOFF.md`, `ledger.jsonl`.

## Trust boundary walk

`templates/project/surfaces.conf` is not executable code, but it is the input that decides
whether `tools/reconcile.sh` (T4 surface per this repo's own `project/surfaces.conf:29`, and
per `core/01-router.md:29` the file this diff also edits) treats a future adopter's own diff
as mandatory-gated or invisible. The adversarial question for a routing config is: *what
attacker-relevant path can change without tripping any T3/T4 row?*

Traced every row in the new file (`tools/reconcile.sh:259-282`'s parser: split each physical
line on the first/last `::`, skip anything starting with `#`, `TARGET::`, `IGNORE::`, or
blank). Confirmed no rule line in the diff wraps its label onto a second physical line — every
new/changed row (`.pem$`, `update\.xml$`, `(core|engine)/`, `(messages?|messaging)`) is a
single physical line, so none of the truncation the diff's own commentary warns about is
present. Confirmed regex safety: all four new/changed patterns are flat alternations/anchors
with no nested quantifiers — no catastrophic-backtracking shape.

**Finding — the file's own stated highest-privilege MV3 surface is unrouted.** A real Chrome
extension's content scripts (`content-scripts/`, `content_scripts/`) are the surface with the
broadest DOM/page access, frequently granted `<all_urls>`, and the most common injection
vector in extension CVEs. No row in the new file matches that path shape. Reproduced directly:
a scratch repo with `src/content-scripts/inject.js` copied verbatim against the new
`templates/project/surfaces.conf`, reconciled with `tools/reconcile.sh`, tiers as **T0, "none
mandatory"** — a change to the extension's highest-trust surface routes as cosmetic. This is
not a hypothetical: it is the same finding already recorded, with severity `blocking`, in this
diff's own `ledger.jsonl` addition (`extension-phases-narrow-pass`, round 1, `G8`, outcome
`fail`, finding id `extension-phases-narrow-pass-r1-G8-1`), and it is **not fixed** in the file
as it stands in the working tree — the diff ships the file that failed its own G8 run.

The new placeholder row `T4::(^|/)(core|engine)/::Core feature logic — REPLACE with YOUR
silent-failure surface` does not cover content scripts either (`content-scripts` does not
match `(core|engine)`), and its own comment block correctly warns it is a placeholder — but
neither the file's "WHAT THIS FILE CANNOT ROUTE" section nor `LEARNINGS.md`/`SESSION-HANDOFF.md`
name content-scripts as a still-open gap. Both docs discuss a different, real gap (store-side
events with no diff at all) at length, which is accurate as far as it goes but is not the same
gap as this one — this one **is** diff-visible and could be closed with one more row.

## What can a hostile input, caller, or confused user do with this

- A **hostile caller** (malicious contributor, or a compromised dependency touching the
  extension's own source) can edit `content-scripts/` — the code with page-DOM/`<all_urls>`
  reach — and, if this template is adopted as-is, no gate is mandated: `reconcile.sh` reports
  T0, `ledger.sh compliance` has nothing to require, and the change can merge with zero fresh-context
  review. This is a real widening of what ships ungated, not a cosmetic doc issue, because the
  file's own stated purpose (replacing a narrow single-project example with "a genuine
  any-Chrome-extension profile" — `INTENT-LOG.md`) is what a new adopter will trust at face
  value.
- A **confused user** (an adopter reading `surfaces.conf` and its "WHAT THIS FILE CANNOT ROUTE"
  section) is told the file's limits are only about non-diff store events, and reasonably
  concludes path-based coverage of their own source tree is otherwise complete. It is not.
- No secret, credential, or auth-bypass path was found; this is a coverage gap, not an
  injection or credential-handling defect in the reviewed files themselves.

## Findings

- blocking::templates/project/surfaces.conf::No T3/T4 row matches `content-scripts/` or
  `content_scripts/` — the MV3 surface with the broadest page access. Reproduced with
  `tools/reconcile.sh` against a scratch repo: a content-script edit tiers as T0. Same finding
  already logged as `blocking` in this diff's own `ledger.jsonl` (`extension-phases-narrow-pass`,
  `G8`, round 1, outcome `fail`) and left unaddressed in the file as it currently stands.
- minor::SESSION-HANDOFF.md:50-54::Item 4 ("Extension-phases narrow pass") is listed among
  completed work in "What changed, by commit" with no mention of the open `G8` blocking finding
  recorded in this same diff's `ledger.jsonl`; "Not done, and why" and "Next, in order" name three
  other deferred items (macOS `sha256sum`, the `ACTION::` router mechanism, fraud/abuse)
  but omit this one, which is a T4-tier, same-diff, self-reported blocking gate failure.
- minor::project/risks.md::Empty (`| R-001 | | | accept / mitigate / transfer | | | |`). Per
  `project/govern.md:33`, "Accepting a new standing risk" requires "Risk owner + T4 approver,
  recorded in `risks.md`" — the content-scripts gap, if accepted rather than fixed, has not been
  recorded there.
- info::templates/project/surfaces.conf:104-121::The "WHAT THIS FILE CANNOT ROUTE" section is
  accurate about the gap it names (store-side, non-diff events — verified against
  `tools/reconcile.sh`'s only input being `git diff --name-only`, lines 145-150) but does not
  mention the separate, diff-visible content-scripts gap above; read together with the ledger's
  own G8 fail, the section understates what the file cannot currently route.
- info::tools/reconcile.sh:259-282::Parser confirmed line-by-line; every new/changed rule in
  the diff is a single physical line with no wrapped label, so the truncation bug the diff's own
  commentary describes fixing is not present in what's shipped.

## Outcome

**Fail.** One blocking finding: `templates/project/surfaces.conf`'s highest-privilege MV3
surface (content scripts) is unrouted, reproduced directly, and already self-identified as
blocking in this diff's own `ledger.jsonl` G8 entry — the diff ships without remediating a gap
it already found. Per `core/cards/G7-threat.md`, `escalate_to: T4 approver. NEVER the author
alone` — this cannot be cleared by re-running the same pass solo; add a content-scripts row (or
fold it into a broadened placeholder) and re-reconcile before this ships as the template's
"genuine any-Chrome-extension profile."
