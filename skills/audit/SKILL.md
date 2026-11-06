---
name: audit
description: "Judge one thing that has been read — a file, a script, a command, a change, a design, an answer — against the user's credo, and report the technical debt, hacks, holes, defects, gaps and refactors it carries. `/audit [what]`, bare for this prompt's answer and the one before it; run unasked on every answer before it is sent, and by a command that has gathered the evidence."
argument-hint: "[what to audit — defaults to this prompt's answer and the one before it]"
---

# Audit

## Have the evidence first

An audit judges what was read, never what was recalled.

- **Invoked by a command that already gathered it** — audit that.
- **Invoked on a name** — read the thing end to end, then read what it depends
  on. A file's own text says what it does; its dependencies say whether it is
  telling the truth.
- **Invoked bare** — the subject is two answers and the work each describes:
  the answer to the prompt the audit is in, and the answer to the prompt before
  it. When that prompt asks for nothing but the audit, its answer is the report,
  which the self-check under Report covers.
- **Run unasked** — the subject is the answer about to be sent and the work it
  describes.
- **Recalled is not read.** Anything known only from before the last
  compaction, or from the summary, is recalled: read it again or leave it out.
- **Where a claim turns on behaviour, run it.** A verdict about what a script
  does, what a flag accepts or what a number is belongs to a command you ran and
  quoted, not to a reading of the source.

## Judge against these

- **The credo**, `~/.claude/credo.md`, which the global `CLAUDE.md` loads:
  every line of "My principles" and "What I ask", and "My voice" for prose
  written to people.
- **The bar in the global `CLAUDE.md`** — *Nothing is finished while it leaves
  debt*.
- **A hack** is a workaround outliving its cause, or a value that is right
  today only because nothing has collided with it yet.
- **In a skill, command or rules file, every sentence changes what a model
  does.** One that restates another file, explains a default or defends a
  choice nobody would make otherwise is a finding: every run reads it, and it
  drifts when only its source is edited. Point at the source instead.

## Report

1. **The subject, as read** — each file, answer or output judged, so the
   reader sees what the findings cover.
2. **Findings, numbered, most severe first.** Each states the mechanism, then
   the defect, then the fix proposed. The report ends by asking, in one
   multi-select question dialog, which findings to apply: one option per
   finding, named by its number.
3. **Checked and clean** — each credo line that held and the look-alikes
   cleared, so silence means checked rather than skipped.
4. **In an ideal world** — the larger change, unnumbered, so it is never
   approved by accident.

The report is a subject too. Before sending it, audit it as a draft against
this skill. Fix the draft, never the subject, then end the report with one
line naming what that self-check changed, or that it changed nothing.

## Rules

- **Every finding carries its evidence** — a quote and where it sits:
  `file:line`, or the answer or command output it came from, in the subject or
  in the facts handed to you.
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
