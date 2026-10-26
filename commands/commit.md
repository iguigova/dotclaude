---
description: Commit the working-tree changes, split into one commit per logical change, with a message stating what changed and why.
argument-hint: "(no arguments — commits the working-tree changes)"
---

Commit the working-tree changes, one commit per logical change: changes to independent features, areas or concerns go in separate commits.

- The message is a title of at most 80 characters, a blank line, then a body stating what changed and why, never implementation detail.
- No "Generated with Claude" text and no Co-Authored-By line.
- A tooling repo commits through `~/.claude/scripts/tooling_commit.sh`, never a bare `git commit`.
