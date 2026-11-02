---
name: recap
description: Recap the current conversation thread — the session task list, the notes it opened or closed, plus a concise, read-only "what we did → where it stands → what's left → what to do next" summary printed to the terminal. Does NOT write any file (use /journal to persist).
argument-hint: "[optional focus, e.g. 'decisions only' | 'as a PR description']"
---

Produce a concise recap of **this conversation thread** (the work done in the current session), printed to the terminal only.

This is **read-only and ephemeral**: do NOT write to any file, do NOT journal, do NOT commit, do NOT call /journal. If the user wants it persisted, point them to `/journal`.

Always open with **Tasks** — call `TaskList` and print every task with its id and status, in id order. This section is never omitted; if the list is empty, say so.

Next, **Notes** — the queue notes this session opened or closed, read from the entries stamped with its id:

```bash
~/.claude/scripts/journal_queue.sh --session "$CLAUDE_CODE_SESSION_ID" --show
```

Print its output verbatim and outside a code block. If it prints nothing, say so in one line.

Then cover, as tight bullet points (omit any section that is empty):

- **What this was about** — one line of context.
- **Done** — the concrete changes/actions taken this thread (edits, deploys, commands run, findings). State what is true now, changelog-tone — not the path that got there.
- **Current state** — where things stand, with any verification results (tests, CI, deploy status). Be honest: if something failed or was skipped, say so.
- **Outstanding** — anything left to do, open questions, or follow-ups offered but not yet done.
- **What's next** — the single action to take now, and why that one. Name it concretely — the command, file, or decision — not a category. Recommend exactly one thing; if the call is genuinely close, give the runner-up in a clause. Where the next step is the user's to make, say what the decision is rather than guessing the answer. If nothing is outstanding, say so and note that this is a safe point to `/compact`.

Rules:
- **Cite-or-tag** — only recap what actually happened in this thread; do not invent or infer outcomes. If a result was never verified, say so rather than asserting success.
- **Report, then recommend** — every section above **What's next** reports; only **What's next** proposes. Ground the recommendation in what this thread established and mark any assumption it rests on; a next step that depends on an unverified result must say so. Outstanding lists, What's next chooses — never restate the list as the recommendation.
- Keep it scannable and short. Prefer bullets and a small table for status if it helps.
- If `$ARGUMENTS` is provided, tailor the recap to that focus or output shape (e.g. "decisions only", "as a PR description", "for a Slack update").
