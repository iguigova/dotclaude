---
name: gist
description: Distil a source — an article, a post, a report, a pasted text, the session's own findings — into a one-page 16:9 executive-summary PDF, rendered by `~/.claude/scripts/gist.py`. Use when asked for a gist, a one-page summary or an executive summary as a PDF. Triggered by `/gist` or the bare word "gist".
argument-hint: "[URL, file, or nothing for the pasted text or the session's findings]"
---

# Gist

One page a busy reader takes in at a glance: a claim, the source's
numbers, three panels of short bullets, and a verdict. The layout is
fixed by `gist.py`; this skill writes its content.

## Read the source whole

Read all of it, from the source itself: fetch the URL, read the file,
or take the pasted text. Every figure on the page comes from what was
read. A claim the source makes about itself is attributed to the
source in the note, never stated as fact.

## Write the content

Write `<scratchpad>/<slug>.json` in the shape `gist.py --help` states.

- **title** — the source's main claim as a sentence with a verb, not a
  topic. One line.
- **subtitle** — what is summarised, its publisher and date.
- **metrics** — the source's own headline numbers, up to five. A value
  is a few characters (`12x`, `+25%`, `15 Sep`); its label says what
  it counts.
- **columns** — three panels that follow the source's own arc: problem,
  design, how it was built; or what shipped, what it means, what to do
  next. When the reader works in a project, one panel says what the
  source means for it. Three or four bullets each, each led by a bold
  phrase and kept to two lines.
- **takeaway** — the verdict: what the reader should conclude or do.
- **note** — whose figures they are, and any caveat the verdict rests
  on.

## Render and look

```bash
~/.claude/scripts/gist.py <scratchpad>/<slug>.json <scratchpad>/<slug>_gist.pdf
pdftoppm -png -r 110 -singlefile <scratchpad>/<slug>_gist.pdf <scratchpad>/<slug>_gist
```

An error names the part that does not fit: cut words from that part
and render again. Nothing shrinks to fit. Then read the PNG and check
that no label crowds the one beside it.

Copy the PDF to `~/Downloads/<slug>_gist.pdf` without overwriting
(`cp --update=none`; a name already taken gets a new slug). Report its
path and keep the JSON's path beside it, since a revision is an edit
to the JSON and a re-render.
