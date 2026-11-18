---
name: request:review
description: "Ask the team to review a ticket's open pull requests, in one Slack thread per ticket: find the ticket's earlier review post in the project's review channel, list every open PR that names the ticket, and post a new request, or reply in that thread for a new PR or a re-review after changes, once the user approves the text. Use when the user asks to post, share or send a ticket's PRs for review, to request a review or a re-review in the team channel, or to tell the review thread that comments were addressed."
argument-hint: "<TICKET-KEY>   (omit to use the ticket the session is working)"
---

Ask for a review of every open PR on: $ARGUMENTS

Every message after the first goes in the ticket's one review thread: a new PR, or a re-review once comments are addressed. `review_request_state.py --help` states where that thread is and how it is found.

## 1. Read where the request stands

```bash
~/.claude/scripts/review_request_state.py <KEY> > <scratchpad>/review-state.json
```

`--help` states what it reads and each field. Show the PRs as a table: repo and number, title, review decision, checks, announced. Then act on `next`:

- **`post`**: no thread yet. Write a new post (§2) for the PRs in `new`.
- **`reply`**: a thread exists. Write a reply (§2) for the PRs in `new` and `rereview`.
- **`none`**: nothing to ask for. Say why (every PR announced and nobody behind, approved, or waiting) and stop.

Each permalink in `earlier` is a duplicate thread from before the ticket recorded one: name each and ask whether to delete it (`~/.claude/scripts/slack_post.py delete <channel> <ts>`).

Each PR in `waiting` is named, with its `why`. Read a failing check's log before saying what failed. Ask whether to wait, fix it, or leave it out. Wait on a pending check with `gh pr checks <url> --watch` in the background; never poll it. A run that exits 2 read nothing whole: say which read failed and stop.

## 2. Write the message

The `draft` skill's rules apply. Before a reply, read the thread with `~/.claude/scripts/slack_thread.py <thread.permalink> --out <dir>`, so the reply answers what was said there.

A **new post**:

- One opening line, two short sentences with verbs: `Team, I've got <n> PRs ready for review on [<KEY>](<ticket_url>). They <what the ticket does, in a few words>:`. With one PR, `Team, I've got a PR ready for review on [<KEY>](<ticket_url>). It …:`. The key is always that Markdown link to the ticket, never bare text. A verbless headline (`a PR ready for review for <KEY>, …`) fails the voice review.
- One bullet per PR: the bare link, then one sentence on what it changes, from its title and body, said for a reader who has not seen the ticket. Add a second sentence only for what people will notice once it deploys, such as everyone signing in again.
- `Thank you` on the last line.

A **reply** in the thread:

- For a re-review, tag each reviewer in `rereview` by their `slack` tag (a null tag is asked of the user) and say that the changes from their reviews are pushed and each comment has a reply. Add one bullet per PR, saying what changed for whom, then close with `Could you take another look when you get a moment? Thank you`.
- For a new PR, one bullet in the new-post shape under `One more for review:`.

## 3. Post after approval

Show the final text and ask in the question dialog whether to post it. Once it is approved:

```bash
~/.claude/scripts/review_request_state.py send <KEY> <file> --expect <next from step 1>
```

It posts only while `next` is unchanged, in the thread for a reply, and records a new thread on the ticket. Exit 4 means the state moved: show what it printed and redraft. Give the user the permalink it prints.

## 4. Record it

Journal the message under the ticket, with its permalink and each PR's state when it was posted:

```bash
~/.claude/scripts/journal.sh -t "<KEY> review request" \
  -b "Review requested in <channel>: <permalink>" -b "<repo>#<n> <review decision>, checks <pass>/<fail>/<pending>" …
```
