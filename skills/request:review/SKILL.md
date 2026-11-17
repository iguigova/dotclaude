---
name: request:review
description: "Ask the team to review a ticket's open pull requests, in one Slack thread per ticket: find the ticket's earlier review post in the project's review channel, list every open PR that names the ticket, and post a new request, or reply in that thread for a new PR or a re-review after changes, once the user approves the text. Use when the user asks to post, share or send a ticket's PRs for review, to request a review or a re-review in the team channel, or to tell the review thread that comments were addressed."
argument-hint: "<TICKET-KEY>   (omit to use the ticket the session is working)"
---

Ask for a review of every open PR on: $ARGUMENTS

A ticket has one review thread in the channel `.claude/review_channel` names. Every later message goes in that thread: a new PR, or a re-review once comments are addressed. The thread is found in Slack each run, never remembered, so it is the same thread from any session.

## 1. Read where the request stands

```bash
~/.claude/scripts/review_request_state.py <KEY> > <scratchpad>/review-state.json
```

`--help` states what it reads and each field. Show the PRs as a table: repo and number, title, review decision, checks, announced. Then act on `next`:

- **`post`**: no thread yet. Write a new post (§2) for the PRs in `new`.
- **`reply`**: a thread exists. Write a reply (§2) for the PRs in `new` and `rereview`.
- **`none`**: nothing to ask for. Say why (every PR announced and nobody behind, approved, or waiting) and stop.

Each PR in `waiting` is named, with its `why`. Read a failing check's log before saying what failed. Ask whether to wait, fix it, or leave it out. Wait on a pending check with `gh pr checks <url> --watch` in the background; never poll it. A run that exits 2 read nothing whole: say which read failed and stop.

## 2. Write the message

The `draft` skill's rules apply. Before a reply, read the thread with `~/.claude/scripts/slack_thread.py <thread.permalink> --out <dir>`. Its `People` block gives the tag of each person a reply may address.

A **new post**:

- One opening line, two short sentences with verbs: `Team, I've got <n> PRs ready for review on <KEY>. They <what the ticket does, in a few words>:`. With one PR, `Team, I've got a PR ready for review on <KEY>. It …:`. A verbless headline (`a PR ready for review for <KEY>, …`) fails the voice review.
- One bullet per PR: the bare link, then one sentence on what it changes, from its title and body, said for a reader who has not seen the ticket. Add a second sentence only for what people will notice once it deploys, such as everyone signing in again.
- `Thank you` on the last line.

A **reply** in the thread:

- For a re-review, tag each reviewer in `rereview` (their GitHub login matched to a name in `People`) and say that the changes from their reviews are pushed and each comment has a reply. Add one bullet per PR, saying what changed for whom, then close with `Could you take another look when you get a moment? Thank you`.
- For a new PR, one bullet in the new-post shape under `One more for review:`.

Then run the `voice` skill on the text, and rework it until the review returns NONE.

## 3. Post after approval

Show the final text and ask in the question dialog whether to post it. Once it is approved, run step 1 again. A changed `next`, `new` or `rereview` voids the approval: show what changed.

```bash
S=<scratchpad>/review-state.json
CH=$(jq -r .channel "$S")
~/.claude/scripts/slack_post.py post "$CH" <file>                                      # next: post
~/.claude/scripts/slack_post.py post "$CH" <file> --thread "$(jq -r .thread.ts "$S")"  # next: reply
```

`slack_post.py` reads the message back and prints its permalink. Give the permalink to the user.

## 4. Record it

Journal the message under the ticket, with its permalink and each PR's state when it was posted:

```bash
~/.claude/scripts/journal.sh -t "<KEY> review request" \
  -b "Review requested in <channel>: <permalink>" -b "<repo>#<n> <review decision>, checks <pass>/<fail>/<pending>" …
```
