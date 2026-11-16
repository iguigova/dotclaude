---
name: request:review
description: "Ask the team to review a ticket's open pull requests: list every open PR that names the ticket, check each is ready, write one Slack post linking them all, and post it to the project's review channel after the user approves the text. Use when the user asks to post, share or send a ticket's PRs for review, or to request a review in the team channel."
argument-hint: "<TICKET-KEY>   (omit to use the ticket the session is working)"
---

Ask for a review of every open PR on: $ARGUMENTS

## 1. List the PRs

```bash
~/.claude/scripts/gh-ticket-prs.sh <KEY>
```

`--help` states what it reads and prints. Show the PRs as a table: repo and number, title, review decision, checks.

- **A PR that is not `ready`** is named, with why (draft, conflicting, a failing or a pending check). Read a failing check's log before saying what failed. Ask whether to wait, fix it or leave it out. A pending check is waited on with `gh pr checks <url> --watch` in the background, never polled.
- **A PR already approved** stays out of the post unless the user wants it in.
- **No open PR** ends the run: say so.

## 2. Write the post

The `draft` skill's rules apply. Match the user's own earlier review requests in the channel: read the latest one with `~/.claude/scripts/slack_thread.py <permalink> --out <dir>` when the session history records one.

The shape:

- One opening line: `Team, <n> PRs ready for review for <KEY>, <what the ticket is about in a few words>:`
- One bullet per PR: the bare link, then one sentence on what it changes, from its title and body, said for a reader who has not seen the ticket. Add a second sentence only for what people will notice once it deploys, such as everyone signing in again.
- `Thank you` on the last line.

Then run the `voice` skill on the text and rework it until the review returns NONE.

## 3. Post after approval

Show the final text and ask, in the question dialog, whether to post it. Once approved, read the PR list again with step 1's script; a PR that changed state since then voids the approval, so show what changed.

```bash
CH=$(grep -v '^#' "$(~/.claude/scripts/project_file.sh review_channel)")
~/.claude/scripts/slack_post.py post "$CH" <file>
```

A project with no `.claude/review_channel` has no channel to post to: say so and stop. `slack_post.py` reads the message back and prints its permalink; give the permalink to the user.

## 4. Record it

Journal the post under the ticket, with its permalink and each PR's state at posting time:

```bash
~/.claude/scripts/journal.sh -t "<KEY> review request" \
  -b "Review requested in <channel>: <permalink>" -b "<repo>#<n> <review decision>, checks <pass>/<fail>/<pending>" …
```
