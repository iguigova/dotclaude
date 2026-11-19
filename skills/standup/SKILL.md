---
name: standup
description: "Write and post the weekday async standup update: a reply in the project's Slack standup thread, covering the work since the previous update, gathered from the session history, live Jira statuses and your Slack messages. Posts only after you approve the draft. User-invoked via `/standup`, or when the user asks for today's standup or async update."
argument-hint: "[anything to add, e.g. \"include the Majestic work\"]"
---

# /standup — the async standup update

The update is one reply in the project's Slack standup thread, covering the work since your previous update. `standup.py --help` names the values and the secret the project provides. `$ARGUMENTS` names anything the draft must include; it adds to the evidence and does not replace it.

## 1. Gather

```bash
"$(~/.claude/scripts/project_file.sh --script standup.py)" gather
```

Each ticket's line carries its current Jira status, which labels the ticket in the draft because a ticket often moves on after the entry that last mentioned it, and its issue URL, which the draft's link copies and never builds.

A sparse report is still an answer. Say what it holds, and ask whether any work happened outside the journal.

## 2. Draft

Write Markdown in this shape. The previous update shows the voice, not the layout:

```
My async update for today:

- **BLOCKED** on <who>: [summary](issue URL): what is waiting
- Done: [summary](issue URL)
- In Progress: [summary](issue URL): one short clause on what moved
- Opened, in the backlog:
  - [summary](issue URL)
- <work with no ticket>: [what it was](Slack thread or page URL)
- PR reviews
- Claude housekeeping
```

- **A ticket starts as one line.** It carries the Jira status now, the linked summary, and a short clause after a colon. A Done ticket often needs no clause. When a ticket has more the reader needs, such as a blocker, a hand-off or the tickets it spawned, give it short sub-bullets instead.
- **Order: BLOCKED first, then from most finished to least** in the tracker's workflow, such as Done, Testing, Code Review, In Progress; then the opened tickets, work with no ticket, PR reviews, Claude housekeeping. Within a group, the ticket that moved most goes first.
- **BLOCKED** is bold and names who the ticket waits on. Write *unblocked* on the first update after it clears.
- **Short summaries.** Shorten a long Jira summary to the words that identify the ticket. Leave out mechanisms, counts, commit hashes, test totals and investigation detail. The reader wants status and blockers.
- **Opened tickets** are one bullet, each ticket a sub-bullet. A ticket opened and worked on in the same period is a line in its status group instead.
- **Work with no ticket** is its own line, linked to its Slack thread or page. Examples are a client site brought up, or a vendor asked to change an allowlist.
- **`PR Review:` entries** are the "PR reviews" line, present only when there was a review of someone else's PR. **`chore` entries** are the "Claude housekeeping" line, always present.
- Leave out any credential, and anything the evidence marks as private.
- Use your Slack messages to fill in follow-ups the journal lacks, for example a reply sent to a vendor.

Show the draft as a code block and ask for corrections. Nothing is posted until the user says to post it.

## 3. Post

Write the approved text to a file in the scratchpad, then post it:

```bash
"$(~/.claude/scripts/project_file.sh --script standup.py)" post <file>
```

The script sends it through `slack_post.py`, which reads the reply back and prints its permalink; it exits 1 when a list item did not render as one. Give that link to the user. It then names the session `standup <posted time>` (e.g. `standup 2026-09-29 13:05 UTC`, the reply's Slack timestamp in UTC) through `session_rename.sh`; show the line it prints. A failed rename warns on stderr and does not undo the post.

A correction after posting is an edit to the same message, not a second reply:

```bash
"$(~/.claude/scripts/project_file.sh --script standup.py)" edit <file> <ts>
```

## 4. Journal

```bash
"$(~/.claude/scripts/project_file.sh --script journal.sh)" -t "chore: async standup update <YYYY-MM-DD>" -b "posted in the standup thread (ts <ts>)"
```
