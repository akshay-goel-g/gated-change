# 14 — Package and Deploy

> Portable. Do not edit. **Your** commands go in `project/commands.conf`.

## Why these exist

G8 Dogfood declares `input: the RUNNING product`. Nothing in the pipeline produced one.

That is not a small omission. It means the gate most likely to find what a user would
report is also the gate most likely to be skipped, because running it requires work nobody
was assigned. The pipeline went plan → build → verify with an unstated assumption that
"built" and "runnable" are the same state. For a library they nearly are. For an installable
artifact — an extension, a mobile app, a container, a signed binary — they are not, and the
gap is exactly where verification quietly stops happening.

**Package** produces the artifact. **Deploy** gets it running somewhere a human or a gate
can actually use it.

---

## They are phases, not gates

| | Gates | Phases |
|---|---|---|
| Asks | a question | nothing |
| Can | stop the change | only fail to run |
| Needs | a persona | a command |

A gate is a persona whose judgment can reject work (`06-extending.md`). Package and Deploy
have no opinion — they either produce the artifact or they error. Making them gates would
add permanent rows to the matrix for things that cannot fail a review, and would imply a
reviewer where there is only a script.

They sit between Build and the verify gates:

```
  BUILD  ──>  PACKAGE  ──>  DEPLOY  ──>  VERIFY GATES
              artifact      running      …Dogfood needs this
```

**Deploy precedes Dogfood, and that ordering is the whole point.**

---

## `project/commands.conf`

`core/` cannot name your toolchain. A browser extension builds for Chrome and Firefox; a
Rust CLI has no browser at all; a service deploys to a cluster. Encoding any of that here
would break the one rule this kit has.

So the project declares its own commands, in one file, in one format:

```
KIND::TARGET::COMMAND
```

| KIND | Answers |
|---|---|
| `DEPS` | What must be installed before anything builds |
| `PACKAGE` | How the artifact for this target is produced |
| `DEPLOY` | How that artifact is made to RUN, locally, for a human or a gate |
| `EVIDENCE` | A command a gate may cite as proof: `ledger.sh add ... --evidence-cmd EVIDENCE::<name>`. `TARGET` is a free name. It must exit 0 and print something; the file must be committed when it runs. See `02-gates.md` |

`TARGET` matches a `TARGET::` label in `surfaces.conf` — that is the join, and it is what
makes the following check mechanical rather than a good intention:

> **Every target that must be verified needs a way to run it.**
> A target with no `DEPLOY` line is a target nobody can dogfood, and it will be the one that
> ships broken.

Declare the gap explicitly rather than leaving the line out — `DEPLOY::<target>::MANUAL::<why>`
records that a human must do it and why automation is not available. An absent line reads as
an oversight; a `MANUAL` line reads as a decision.

---

## Deploy means a clean instance, not your daily environment

The honest scope of "deploy locally" is narrower than it sounds, and overselling it is how
this phase turns back into a manual step nobody runs.

Most runtimes can be launched fresh with the artifact loaded — a throwaway profile, a
temporary container, a simulator instance. Most **cannot** be made to inject the artifact
into the environment you are already using, because that environment is stateful, logged
in, and yours. Attaching to it usually requires either a privileged debugging channel or a
human clicking through a native dialog.

**Deploy targets the clean instance.** If your workflow needs the artifact in your everyday
environment, that is a `MANUAL` line with the steps written out — not a promise the phase
cannot keep.

---

## Where this fires

| Stage | What it does |
|---|---|
| **Triage (R0a)** | A target with no `DEPLOY` line is a capability gap — declare it now (`09-capabilities.md`), not at Dogfood |
| **Package** | Produces the artifact for every target the change affects |
| **Deploy** | Produces the running instance the verify gates consume |
| **G8 Dogfood** | Its `input` is satisfied by Deploy's output, or it does not run and the ledger says so |
| **Release** | An artifact that was never packaged for a declared target did not ship for that target |

---

## What does not belong here

**One-time project setup.** Choosing where the repository lives, creating the remote,
picking the host — that happens once, before the loop exists. Putting it in a per-change
phase means every trivial change nominally passes through "where should this repo live",
which is precisely the ceremony creep that gets pipelines abandoned. It belongs in
bootstrap tooling, run once.

**`DEPS` is the exception, and only just.** It is in the loop because a dependency change
is a real change with real blast radius, and because a build that silently ran against
stale dependencies is a defect nobody can see in a diff. Keep it to installing what the
project already declares — not deciding what the project should be.

---

## What this chapter does not cover, said out loud

This chapter is titled Package and Deploy for a reason: those are the two phases with an
executor. **Release has none.** For most artifacts that is fine — Release is "merge and tag."

For an installable artifact with a store or marketplace in front of it, it is not. Publishing
is where the actual irreversibility concentrates — a version number that can never be reused,
a permission-warning delta that silently re-prompts (or drops) every existing user, a signing
key that if lost means the listing can never be updated again — and every one of those events
changes **zero files**. R0a/R0b tier a diff (`01-router.md`); an event with no diff cannot be
tiered by a `TIER::REGEX::LABEL` row, no matter how correctly `project/surfaces.conf` is
filled in. `T4`'s own definition — "anything a user cannot undo" — describes the publish step
better than it describes most of what a path-based row can actually see.

The event-shaped part of this gap now has a mechanism, even without Release having an
executor: `01-router.md`'s **R0d** — a declared `ACTION::TIER::NAME::EVIDENCE` row in
`surfaces.conf`, fired explicitly with `bash reconcile.sh --action <name> --evidence
"<citation>"` at the moment the event actually happens, not folded into R0b's Build-then-diff
window. It still runs from a script, not a phase with an executor — R0d is a routing step, not
a new chapter here — and it closes nothing automatically: nobody is forced to invoke it, so a
publish nobody remembered to declare is exactly as invisible as before. `BASE=<last-release-tag>`
on `reconcile.sh` (`01-router.md`, R0b) remains the file-diff-shaped mitigation, unaffected by
any of this. Full rationale, including what R0d still leaves open, is in `01-router.md` and
`LEARNINGS.md`.
