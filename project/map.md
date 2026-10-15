# System map

> Yours. **One page.** What exists, who owns it, what it depends on.
>
> Deliberately not an architecture diagram. Diagrams rot faster than anyone maintains
> them, and a diagram that is six months stale is worse than none because people still
> trust it. A component-and-owner list survives because it is cheap to correct.

## Why this exists

The coupling registry is a **behavioral** map: it records what breaks what, mined from
things that already went wrong. It never records what *exists*.

That leaves a specific blind spot: **a component nobody has broken yet is invisible to
Ripple.** The gate asks "what else does this touch?" and answers from incident history, so a
new or quiet component has no entry and gets no attention — right up until it is the thing
that broke.

This file is the structural half. Together they answer "what is there" and "what happens when
you disturb it."

---

## Components

Each row is something that can fail independently.

| Component | Does what | Owner | Fails how | Registry entries |
|---|---|---|---|---|
| `tools/reconcile.sh` | R0b/R0d — recomputes the tier from the real diff, or from a declared action | Change owner | **silent** — a wrong tier means the wrong gates are mandatory, and nothing else recomputes it | — |
| `tools/ledger.sh` | Writes and reads every record (gate, route, escape, assumption); `compliance` is the release decision | Change owner | **silent** — it once passed a change on a mistyped tier, and masked a refusal on a truncated line | — |
| `tools/lib/matrix.sh` | The only reader of the router's gate matrix; decides what each tier mandates | Change owner | **silent** — a malformed row once dropped a gate from "required" with exit 0 | — |
| `tools/lib/commit.sh` | `resolve_commit`: the ONE way a stored commit string (ledger row, pin, report, note) becomes a commit -- by object, never through a ref name; sourced by `ledger.sh`, `coverage.sh` (and so `status.sh`, `dashboard.sh`) and `check-refs.sh`. Any new code that hands a stored sha to git must go through it | Change owner | **silent** — a stored short sha handed to `git rev-parse` raw is redirected by a tag of the same name (UNBOUND reads PASS, the anchor moves) | — |
| `tools/lib/coverage.sh` | Computes unrouted work; shared by `status.sh` and the dashboard so they cannot disagree | Change owner | **silent** — a wrong anchor prints "0 commits since" (undercount); an **absent** anchor makes both readers count from the kit's install commit (pinned in `.install-base` while uncommitted; whole history only when that is unknown) — and before that was added, the whole history as unrouted (overcount, loud-but-wrong — R-007) | — |
| `tools/lib/default-branch.sh` | Resolves the repo's default branch from git; shared by `ledger.sh` (which `--change` names to refuse) and `dashboard.sh` (bakes it for `app.js`) so the write and read sides cannot disagree | Change owner | **silent** — resolves empty on any git hiccup and the caller falls back to a hand-list; a transiently-wrong value is a no-op with no detection (R-005) | — |
| `tools/status.sh` | The zero-argument "is the pipeline on?" report; compares the ledger against git history | Change owner | **silent** — its G4 starvation check once could not fire at all | — |
| `tools/dashboard.sh` + `tools/dashboard/` | Renders the ledger as a page; bakes a Coverage panel from `lib/coverage.sh` | Change owner | loud (generation) / **silent** (a stale snapshot reads as current) | — |
| `templates/pre-push` → `.git/hooks/pre-push` | Blocks a trust-boundary push with no matching security report | Change owner | **silent** — its success prints nothing, and the installed copy drifts from the template | — |
| `tools/install-hook.sh` | Installs that hook; refuses to guard nothing, and refuses to clobber | Change owner | **silent** — it once installed a hook whose placeholder regex matched nothing | — |
| `tools/hooks/r0c-post-edit.sh` | Claude Code PostToolUse reminder for R0c re-entry on a T3/T4 edit | Change owner | **silent** — it was dead on Windows for one full release and exited 0 every time | — |
| `tools/install-claude-hook.sh` | Merges that hook into `.claude/settings.json` without clobbering it | Change owner | loud — refuses rather than hand-edit JSON when python is absent | — |
| `tools/mine-registry.sh` | Drafts registry candidates from git history | Change owner | loud | — |
| `tools/update-kit.sh` | Refreshes a vendored `.pipeline/`'s portable parts (`core/`, `tools/`, `templates/`, top-level docs, and an install's `.kit-version` stamp, if present) from a newer kit, without touching `project/`, the ledger, or security reports | Change owner | loud — a failed `rm`/`cp` mid-refresh stops and names exactly what may be partial, but does not roll it back; T4 in `surfaces.conf` because a wrong path here still destroys a project's records | — |
| `tests/run.sh` | The suite. If it stops asserting, nothing else here is trustworthy | Change owner | **silent** — an always-true assertion passes forever | — |

**Registry entries is empty on every row, and that is a finding, not an omission.**
`project/registry.md` holds no couplings yet, so Ripple has nothing to trigger on for any
component above — `status.sh` now reports this rather than leaving it implicit.

**"Fails how"** carries most of the value in this table. Anything marked **silent** needs a
self-check (`core/07-failure.md`) and probably belongs in the trust surfaces in
`surfaces.conf` — silent failure is the definition of T4.

## External dependencies

Things you rely on and do not control. Not a package list — the runtime dependencies whose
failure is *your* outage.

| Dependency | Used for | If it fails | Controlled by |
|---|---|---|---|
| `git` | Everything. Tiering a diff, anchoring coverage, the pre-push hook, kit provenance | The kit does not function; most tools refuse rather than guess | platform |
| `bash` + coreutils (`sed`, `awk`, `grep`, `diff`) | Every tool here is shell. `awk` does the coverage scan and the registry count | Behaviour diverges between GNU and BSD; **untested on BSD — see below** | platform |
| `python3`/`python` | **`tools/install-claude-hook.sh` only**, to merge `.claude/settings.json` safely | That installer refuses and prints the entry to paste by hand (exit 2). Nothing else degrades | platform |
| `node` | `tests/dashboard-logic.test.js` only | Those JS tests skip loudly; the shell suite is unaffected | platform |
| `cygpath` | `tests/run.sh` only — the two assertions that need a literal `D:\`/`D:/` path to prove `_relpath` and the coverage guard handle a Windows drive letter | Both `_skip` loudly. But it exists only on Git Bash/Cygwin, so on the Linux and macOS runners `surfaces.conf` declares a TARGET those two assertions never execute — the drive-letter branches are covered on exactly one platform and asserted by nothing on the others. See `risks.md` R-004 | platform |
| A JSON-capable reader (`python`) | `tests/run.sh`'s JSONL validation | Those assertions skip loudly rather than weaken silently | platform |

**The `bash`/coreutils row is a live risk, not a formality.** `surfaces.conf` declares
"Linux/macOS bash" a TARGET, there is no CI, and every suite run to date has been Git Bash on
Windows — so GNU-vs-BSD divergence in the `awk`/`sed` this kit is built from is unverified.
Recorded in `project/risks.md`.

Package inventories belong to your dependency tooling, not here. This table is for the
handful whose failure changes what the product does.

## Data

Only what is persisted or leaves the process. If a row here involves personal data, enable
the **Comply** gate (`core/06-extending.md`) — it produces the detailed data-flow map, and
building that unconditionally is work most projects do not need.

| Data | Where it lives | Leaves the process? | Personal? |
|---|---|---|---|
| Gate / route / escape / assumption records (a route record also carries `base`, the commit the change started from — written by `reconcile.sh`, read by `compliance` — and, on a deliberate restart or a repeat firing of a declared action, `"restart":true`, written by `route` and read by `compliance` and the dashboard) — `tokens` (the aggregate cost) and, since `ledger-token-split`, the optional paired `tokens_in`/`tokens_out` split | `.pipeline/ledger.jsonl`, append-only JSONL, written only by `tools/ledger.sh` | Only when `dashboard.sh` bakes the lines into a `dashboard.html` someone then publishes | no |
| The install cutoff: the commit the kit was added at, so pre-install history is not counted as unrouted (E10) | `<kit>/.install-base`, one sha, written by `status.sh`/`dashboard.sh` (via `coverage.sh`) the first time they run in an install that is not yet committed. `update-kit.sh` leaves it alone. Reading a status therefore leaves a new untracked file; it is meant to be committed with the kit. After the kit is committed it is still read, but only when it names a strict ancestor of the install commit's parent (work committed between the first status run and the kit commit), so it can only make the count larger, never hide a commit; before the kit is committed it is the cutoff when it names an ancestor of HEAD, the merge-base with HEAD when it names a commit that is not an ancestor, and otherwise (empty, garbage, a sha this clone lacks, a directory, a link -- which is neither read nor written) it gives no cutoff and the whole history is counted. It is written only when the file is absent and is never rewritten or written through a symlink; `status.sh` says when a pin gives no cutoff (delete the file to pin again) | no | no |

---

## Keeping it true

**This file is updated by the Ripple gate, not on a schedule.** A change that adds a
component, adds an external dependency, or persists new data updates the map in the same
diff — and Ripple fails if it did not.

That coupling is the entire reason to trust this file. Documentation maintained on a cadence
drifts between cadences; documentation maintained by a gate drifts only if the gate is
skipped, which the ledger already records.

**Cap it at one page.** If it does not fit, you are describing implementation rather than
structure — the detail belongs in the feature docs, and what belongs here is the thing that
can fail on its own.
