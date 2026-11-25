---
name: slack:reply
description: "Answer a question asked in a Slack thread — usually a product or support question about how a setting behaves — from the code on the default branch and live production data, then post the reply in the thread after one confirmation. User-invoked via `/slack:reply [permalink]`, or when the user hands over a Slack thread link and asks for help answering it."
argument-hint: <slack-permalink>
---

# /slack:reply — answer a Slack thread from code and data

Answer the thread at $ARGUMENTS.

An answer is one reply in the thread. It says what to do, then how the thing works, in words the asker uses. Every claim in it traces to code on the default branch, a production measurement or a file the asker attached, matched against them. Nothing is posted until the user approves the text.

## 1. Read the thread

Load the `draft` skill, then read the thread as it says, with `slack_thread.py`, then open every file it names with Read.

Write down the question as the asker put it, and the setting, screen or customer it is about. A screenshot shows how the asker configured something. It is their claim, not a fact: what it shows is confirmed in §3 or is reported as unconfirmed.

## 2. Read the code that decides it

The question names a UI label. The code names a column. Find the column first, then every place that reads it.

- Bring the repo current: `"$(~/.claude/scripts/project_file.sh --script dev_setup.sh)" <repo>`. If the branch it reports is behind, read `origin/<default>` with `git show origin/<default>:<path>` and `git grep <pattern> origin/<default>`, not the checkout.
- Go from the label to the column: grep the locale files for the label's text, then the view or serializer that uses the key.
- Find every reader of the column: `git grep -n <column> origin/<default>`, plus a grep across the project's other repositories. The answer often depends on one reader the asker never sees.
- Trace the flow the question is about end to end, such as how a recurring plan creates its records. Name the method where the setting is read or ignored.
- Find the specs that cover the asker's case. A spec that sets up their exact configuration is the strongest code evidence there is.
- Read the ticket that added the setting (`git log -S<column> --reverse origin/<default>`, then the ticket key in the commit) to learn what it was meant to do.

Cite `file:line` at the commit you read.

## 3. Measure it in production

Production SQL runs through the project's `prod_sql.sh` verb: SQL in, rows out, read-only. Its `--help` states its scopes and what the database holds that its models do not say; read it first. A project without the verb stops here, and the answer says what went unmeasured. Ask the user once to allow it, then run:

```bash
"$(~/.claude/scripts/project_file.sh --script prod_sql.sh)" <scratchpad>/q.sql > <scratchpad>/q.txt
```

Find the asker's records and check that they are set up as the screenshot shows. Then look at what the system actually did with them, for example the records a setting produced in the last 30 days, grouped by the field the question is about.

Every count in the answer carries its query and the date it was run. Anything you could not explain is reported as untraced, never guessed at.

## 4. Write the reply

Write the reply with the `draft` skill, to `<scratchpad>/reply.md`. The asker knows the product, not the code. When the setting they asked about is not the one that matters, the reply says what it does instead. `file:line`, SQL and internal ids go to the user in the terminal, beside the draft, never into the reply.

## 5. Confirm, then post

A claim about the present (today, now, currently, every) rests on a measurement of the last few hours, and is measured again just before posting: a figure aggregated over earlier days describes those days. Confirm and post as `draft`'s "Check, then post" says, beside the evidence for each claim, with

```bash
"$(~/.claude/scripts/project_file.sh --script slack_post.py)" post <channel> <scratchpad>/reply.md --thread <thread-ts>
```

## 6. Close

- Journal it: `"$(~/.claude/scripts/project_file.sh --script journal.sh)" -t "<KEY or customer> <topic>" -b "<the answer>" -b "<the evidence>" -b "<the reply's permalink>"`. A finding that needs work, such as a defect the trace turned up, is a note (`-n`), and becomes a ticket through `/notes`.
- Name the session: tell the user to run `/rename <topic>`, using the same topic as the journal entry so the two match. `/rename` is a built-in command and only the user can run it.
- Say it is a safe point to `/compact`: the answer, its evidence and the permalink are in the journal.
