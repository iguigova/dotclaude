---
name: notes
description: "Show and place the open notes a session wrote with `journal.sh -n`: asks Do, Drop or Keep open for each of the oldest four, and places each one marked Do as a memory fact, skill, command, script, rule, setting or ticket. An argument that is no ticket key or flag is one thing to note and place directly. Triggered by `/notes`, by the bare words note or notes used of the queue, and at session end."
argument-hint: "[TICKET | --session <id> | --all | the one thing to place]   (default: this session's notes)"
---

# /notes

```bash
/notes              # the notes this session opened — the default
/notes ABC-7703      # that ticket's open notes, from every session
/notes --session ID # that session's open notes — what the SessionEnd hook passes
/notes --all        # every open note, oldest first
/notes <thing>      # note this one thing and place it, queue or not
```

An argument matching `^[A-Z][A-Z0-9]*-[0-9]+$` is a ticket scope. Anything else is
the thing to place.

## Scope

Set it in the block that reads the queue: an empty scope is a run over every
session with nothing in the output to say so.

```bash
SESSION="${CLAUDE_CODE_SESSION_ID:?/notes: no session id — say --all to show every open note}"
SCOPE=(--opened-by "$SESSION")   # /notes <TICKET>      → SCOPE=(--ticket "<TICKET>")
                                 # /notes --session ID  → SCOPE=(--opened-by "ID")
                                 # /notes --all         → SCOPE=()
# Every call spells the reader's path out rather than holding it in a variable: a
# permission rule is matched against the text of the command, so a path the text
# does not contain matches no rule, and the read is left to the auto-mode
# classifier.
~/.claude/scripts/journal_queue.sh "${SCOPE[@]}" --show || exit 1
open=$(~/.claude/scripts/journal_queue.sh --ids) || exit 1
mine=$(~/.claude/scripts/journal_queue.sh "${SCOPE[@]}" --ids) || exit 1
open=($open) mine=($mine)
printf 'left out: %s of %s open\n' "$((${#open[@]} - ${#mine[@]}))" "${#open[@]}"
```

Always report what the scope left out: the count, and that `/notes --all`
reaches it.

An empty scope ends the run. Report the count it left out and stop there: a note
another session opened is not this run's to offer, and `--all` is the only thing
that widens the scope — never the run's own judgement that the rest looks worth
reading.

## Choose

First run steps 1 and 2 of *Placing a note* for the **oldest four**. Stating the
claim and searching what already covers it are both read-only, and they tell you
where each note would land.

Then print the whole scoped list: the table `--show` printed, every row verbatim,
with one column added at the end, **would go to**. For each of the four it holds
the exit Do would take and what already covers it — `memory — new; nearest
aws-profile.md`, `- — already in qa/SKILL.md:114`. Every other row holds `—`,
because this slice does not offer it.

Then offer the four, one question per note, each answered **Do**, **Drop** or
**Keep open**. Nothing is placed before the answers arrive.

- **Do** places the note by the exit its question states.
- **Drop** closes it `-`, the reason being the user's words, or `dropped by the
  user` when they gave none.
- **Keep open** changes nothing, and neither does a question left unanswered.

Offer the next four once this slice is recorded.

```
AskUserQuestion({ questions: [ one per note, oldest first:
  { question: "[<id>] <the note's whole text, as its row printed it>",
    header:   "<id>",
    multiSelect: false,
    options: [
      { label: "Do",        description: "<its would-go-to cell>" },
      { label: "Drop",      description: "close it `-`: not wanted" },
      { label: "Keep open", description: "leave it in the queue" } ] } ] })
```

Each question's free-text answer is the escape: a reason for a Drop, a different
exit for a Do, "stop", or a note named by id from outside this slice.

**Unattended there is nobody to ask.** A run under the SessionEnd hook skips this
section and places every note whose gate passes, leaving the rest open.

Three placements stay open unattended whatever their gate says: `-`, which is
the user's call (*Closing*); `ticket`, because filing one writes to a shared
tracker and its gate — the key exists — can only pass after the ticket is filed;
and a project's work item, whose command asks the user as it runs.

## Gates

Nothing is written until its gate passes.

| placement | gate | enforced by |
|---|---|---|
| `memory` | a `verify:` exists and passes now | `~/.claude/scripts/memory_fact.sh` |
| `skill` `command` `rules` | no name is newly unresolved | `~/.claude/scripts/name_lint.sh --gate <file>` |
| `script` | its `--self-test` passes | `selftest.sh` in that tree |
| `settings` | the tool it names exists | the harness |
| `ticket` | the key exists | the project's ticket helper |
| `-` | none | the user's judgement, proposed and never assumed |

Where the third column names a command, run it as written: it exits non-zero on
the gate it names. A `~/` path runs from any directory, and `name_lint.sh` takes
its project from the file it lints rather than from cwd. A project's own script
runs from the project root, where the SessionEnd hook starts its run.

The project's ticket helper is the one its `CLAUDE.md` names. The memory
scripts are global, and each takes its project's store from the working
directory.

## Placing a note

**1. State it in one sentence.** If it will not reduce to one, it is two notes;
open the second with `journal.sh -n`.

**2. Find what already covers it**, before writing anything:

```bash
~/.claude/scripts/memory_reconcile.sh --text "<the note>"
```

Judge the hits: new, update, contradiction, or redundant. A contradiction updates
what it contradicts — never file a second copy beside it. Redundant closes as
`- — already in <name>`.

**3. Choose the placement, in this order.**

- *Is it a work item of a kind the project's `CLAUDE.md` names a command for?*
  → run that command on it. The command does the work, asks for what it needs,
  and closes the note itself, so steps 2 and 4 do not apply.

- *Can a command be written that passes now and would fail if the claim became
  false?* → **memory**. Write it through the writer, which runs that command and
  refuses a claim it cannot confirm:

  ```bash
  ~/.claude/scripts/memory_fact.sh write <name> "<pointer hook>" <<'FACT'
  …the whole fact file…
  FACT
  ```

  A claim about a file in a repository is checked with
  `~/.claude/scripts/git_fact.sh`.

- *Is it a way of working — how to read something, what to check first, a trap to
  avoid?* → **skill** or **command**: the one whose procedure it improves, which
  the retrieval script already ranked. A way of working with no procedure to
  attach to stays open; when three open notes name the same absent procedure,
  that is the evidence for a new skill. One note is not a procedure.

- *Is it a repeated multi-step workflow?* → **script**, written with a
  `--self-test`.

- *Is it a preference a tool boundary can express?* → **settings**.

- *Is it a standing instruction?* → **rules**.

- *Does it need scheduling?* → **ticket**. Raise it with the project's ticket
  helper and close as `ticket:<KEY>`.

- *Was it done to a running system, leaving nothing any store holds?* → **`-`**.
  The reason is its only account, so it carries the whole of it.

- *None of these?* → leave it open. That is a complete answer.

**4. Run the gate, then close the note naming where it went and why.**

## Closing

One journal call per heading at the end. The heading follows `journal.sh`'s rule,
the ticket the work is for, which is what billing reads:

- A placement into the tooling (`memory`, `skill`, `command`, `script`, `rules`,
  `settings`) is work on the tooling, so it is `chore: notes`.
- A `ticket` or `-` placement is work on the note's own ticket: investigating
  product code to file the follow-up, or acting on a running system. Journal it
  under that ticket, one call per ticket. A note with no ticket stays under
  `chore: notes`.

```bash
~/.claude/scripts/journal.sh -t "chore: notes" -b "<what was placed>" --via /notes \
  --placed "<id>: <placement> — <reason>" … --sha <sha>
~/.claude/scripts/journal.sh -t "<note's TICKET> notes" -b "<what was filed or done>" \
  --via /notes --placed "<id>: ticket:<KEY> — <reason>" …
```

The reason says whatever is true — `fixed`, `superseded`, `disproven`, `already
in <name>`, `214 tables freed`.

A `-` close is the user's to give: a gate can prove a fact is true, but nothing
proves work is finished or unwanted. Propose those and take their edits.

One writer closes `-` without asking: `git_sweep.sh`, and only its own notes,
the ones whose text ends `(sweep:…)`. Such a note says a ref needs a person,
and the sweep closes it when its own check stops saying so — the branch or
stash is gone, or now kept or deleted. That check is the proof.

A project command that owns a kind of work item also closes its own notes `-`:
the one its `CLAUDE.md` names, and only notes captured under that kind's topic
(`journal_queue.sh --topic`). It closes one when the user has decided the item
inside the command, done or not wanted. That decision is the user's close.

## Rules

- Reading a note never closes it.
- One note, one place. If it belongs in two, it is two notes.
- Every run ends with journal entries naming each note and where it went, and
  commits its own paths with `~/.claude/scripts/tooling_commit.sh`, attended or
  not — nothing commits for it. A run that changed nothing says so.
