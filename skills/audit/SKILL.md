---
name: audit
description: Judge one thing that has been read — a file, a script, a command, a change, a design — against the user's credo, and report the technical debt, hacks, holes, defects, gaps and refactors it carries. Every finding carries a quote and a line number, nothing is edited until the user approves that finding, and what was checked and found clean is named so silence means checked. User-invoked via `/audit [what]`, and invoked by a command that has already gathered the evidence.
argument-hint: "[what to audit — defaults to what this session has already read]"
---

# Audit

## Have the evidence first

An audit judges what was read, never what was recalled.

- **Invoked by a command that already gathered it** — audit that.
- **Invoked on a name** — read the thing end to end, then read what it depends
  on. A file's own text says what it does; its dependencies say whether it is
  telling the truth.
- **Invoked bare** — the subject is what this session has read since its last
  compaction, listed first. Anything known only from before it, or from the
  summary, is recalled: read it again or leave it out.
- **Where a claim turns on behaviour, run it.** A verdict about what a script
  does, what a flag accepts or what a number is belongs to a command you ran and
  quoted, not to a reading of the source.

## Judge against these

- **The credo**, `~/.claude/credo.md`, which the global `CLAUDE.md` loads:
  every line of "My principles" and "What I ask", and "My voice" for prose
  written to people.
- **The bar in the global `CLAUDE.md`** — *Nothing is finished while it leaves
  debt* — and, where its qualities conflict, the order `coding_guidelines.md`
  ranks them: correct first.
- **A hack** is a workaround outliving its cause, or a value that is right
  today only because nothing has collided with it yet.
- **In a skill, command or rules file, every sentence changes what a model
  does.** One that restates another file, explains a default or defends a
  choice nobody would make otherwise is a finding: every run reads it, and it
  drifts when only its source is edited. Point at the source instead.

## Report

1. **Findings, numbered, most severe first.** Each states the mechanism, then
   the defect, then the fix proposed. The number is what the user approves.
2. **Checked and clean** — the look-alikes cleared, so silence means checked
   rather than skipped.
3. **In an ideal world** — the larger change, unnumbered, so it is never
   approved by accident.

## Rules

- **Every finding carries its evidence** — a quote and a line number, from the
  subject or from the facts handed to you.
- **The facts you were handed are part of the subject.** A gathered fact can be
  wrong, and a wrong fact is a defect in whatever produced it. Distrust the one
  word the verdict would rest on, and check it.
- **Propose only.** Nothing is edited until the user approves that finding.
  Approving one is not approving the rest.
- **Fewer, better findings.** A short list that is all true beats a long one.
- **A tool reports; you judge.** A probe that flags a pattern has flagged a
  pattern — say whether this instance is the defect or the benign case, and why.
- **A passing test is not a clean bill.** A meaningful assertion of the wrong
  behaviour pins the defect in place and reads as deliberate. Where a subject is
  well covered, ask what the coverage makes it safe to be wrong about.
