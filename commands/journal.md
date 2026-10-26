---
description: Append a session-history entry via the journal.sh writer.
argument-hint: "[what to record — defaults to this turn's work]"
---

Write a session-history entry for the current project with the single writer. From the user's input (`$ARGUMENTS`) and the recent work this turn, compose the call; `journal.sh --help` states every field.

```bash
~/.claude/scripts/journal.sh -t "<TICKET> <topic>" -b "<outcome bullet>" [-b …] \
  [--via /skill] [-n "<title> — <detail>" …] \
  [--placed "<id>: <placement> — <reason>" …] \
  [-c "<TICKET>: <commit summary>" | --sha <sha> …]
```

Show the user the resulting header line and the `committed →` line, or the warning that says the commit was refused, and each note the writer opened, as it printed it.
