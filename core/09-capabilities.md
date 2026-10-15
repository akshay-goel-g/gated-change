# Capabilities — what the agent cannot make, and what to do about it

> Portable. Do not edit. Your wired-up tools go in `project/capabilities.conf`.

---

## The failure mode

Ask a coding agent for a promo video and it will not say "I cannot make videos." It will
write you a shot list, or an HTML animation, or a `<canvas>` sketch, and present it as the
deliverable. Ask for an app icon and you get a hand-written SVG that is *technically an
icon*. Ask for a notification sound and you get a Web Audio oscillator.

None of that is refusal and none of it is lying. It is **silent substitution**: producing the
nearest thing within reach and letting it stand in for the thing that was asked for. It is
the single most common way AI-assisted products end up looking amateur, because the
substitution is invisible in a diff and obvious to a user.

The pipeline's job is to make the gap **visible at Triage**, before work starts.

---

## The capability boundary

| Asset | The agent can | The agent cannot | Route to |
|---|---|---|---|
| **Copy, docs, code** | Everything | — | Itself |
| **Diagrams** | Mermaid, SVG, ASCII — genuinely good | — | Itself |
| **Screenshots** | Capture via browser automation | Invent one that does not exist | Browser automation |
| **Icons** | Simple geometric SVG; specify a brief precisely | A brand mark with taste | Icon set, vector tool, designer |
| **Illustration / photo** | Write the prompt or brief; evaluate candidates | Generate raster imagery | Image model, stock, illustrator |
| **Video** | Script, storyboard, shot list, edit decision list | Render or edit footage | Screen recorder + editor |
| **Audio** | Specify duration, character, loudness; pick from a library | Synthesize a pleasing sound | Sound library, audio tool |
| **Fonts** | Recommend and pair | Draw a typeface | Type foundry, open licenses |
| **Anything needing a real account, device, or signature** | Prepare, draft, instruct | Act as you | A human |

**The pattern:** the agent is strong at *specification and evaluation*, weak at *synthesis of
perceptual artifacts*. Use it for the brief and the critique, not the render.

---

## The declaration rule

When a task requires an asset the agent cannot produce, it must **say so before starting**,
and offer real options:

> This needs a 128px app icon. I can't generate raster art or produce a polished brand mark.
> Three options:
> 1. I write a precise brief and you run it through an image model
> 2. I pick from an open-licensed icon set and adapt it — fastest, least distinctive
> 3. You brief a designer; I write the spec and review the result against it
>
> I'd take (2) now and (3) before the store listing.

**What this rule forbids:** producing the weak substitute silently, and calling it done.
If the substitute is genuinely the right call — a rough SVG placeholder to unblock layout —
say that it is a placeholder, and where it must be replaced before release.

---

## The suggestion rule

The same principle generalizes past media. Whenever something **outside the current default
would produce a materially better result**, say so before doing the work, not after:

- A different model would do this better (or the same, for a tenth of the cost)
- A library already solves this and is better tested than what is about to be written
- This belongs in a spreadsheet, a database, or a cron job, not in application code
- The best version of this needs a human — a lawyer, a designer, a native speaker

**Timing is the whole rule.** "A designer would do this better" is useful before the icon is
drawn and merely deflating after. The agent is the only party in the loop who knows what it
is about to do, which makes it the only one who can raise this in time.

---

## Where this fires in the pipeline

| Stage | What it does |
|---|---|
| **Triage** | Lists non-code assets the change needs. Any gap → declaration rule, before planning |
| **requirements.md** | Assets are acceptance criteria too. "App icon at 5 sizes" is a deliverable, not a detail |
| **Craft gate** | Placeholders are findings. A placeholder that reached the release candidate is a defect |
| **Release** | No unreplaced placeholder ships. This is a checklist item, not a judgment call |

---

## Configuring your side

`project/capabilities.conf` lists what *your* setup has wired up, which changes the routing —
an agent with an image tool connected should use it rather than propose it. Keep it current:
a stale capability file causes the exact silent substitution this file exists to prevent,
because the agent believes a tool is unavailable and quietly makes do.
