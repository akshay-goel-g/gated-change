# Grounding — project-specific false-claim patterns

> Yours. `core/12-grounding.md` gives the general taxonomy and checklist. This file
> records patterns **specific to this codebase** — libraries it uses that behave
> unusually, APIs the agent has confused with something else before, and version
> quirks worth checking every time.

Add an entry when a hallucination actually happens here, not speculatively. A
recorded pattern with no real incident is exactly the kind of unearned rule
`core/11-evolution.md` warns against.

## Format

```markdown
### <short name>
Caught     : <date>
Claimed    : <what was asserted, false>
Actually   : <what was true>
Why it happened : <which taxonomy pattern from core/12, and the specific confusion>
Check now  : <the grep/lookup that would catch it next time>
```

## Entries

*None yet.*
