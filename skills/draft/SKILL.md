---
name: draft
description: Write an update for people to read — a ticket comment or description, a wiki page section, a PR comment, a chat post. Use before posting or editing one, and when asked for an update or summary. Triggered by `/draft` or the bare word "draft".
argument-hint: "[where it goes — ticket key, page id, PR or channel]"
---

# Draft

The reader was not in the session. They scan for the one thing they
need: the answer, a decision, their next step.

## Understand the need first

Read the destination as it stands now: the whole thread, the ticket's
latest comments and its status. The draft joins that conversation. When
someone else was asked to answer, or has answered already, the opening
clause says how this reply relates to that ("I also looked —"). Match
the structure and length of the author's own recent posts in that
medium.

Then work out what the asker needs, before drafting an answer:

- Who they are, and what their role asks of them at this stage of the
  work.
- What else they said on the same subject, in this place and in any
  other thread they are part of, and in what order.
- The need behind the words. A question about a step is often about the
  outcome the step serves.

When the words allow more than one need, do not answer the one you
assumed. Ask which they mean, and offer each plausible reading as a
choice they can pick.

## Content

The credo in the global CLAUDE.md sets the voice and the standards. The
rules below are what an update adds to them.

- The answer first. Then how the thing works, as far as the reader needs
  it to decide or act, and no further. Leave out how it was found.
- Every claim rests on evidence read for this draft: a query result, a
  file and line, a log, a link. The evidence sits beside its claim: a
  count with its date, a link.
- A fact that cannot be confirmed now is left out, or marked
  unconfirmed with who can confirm it.
- A problem is stated by its cause, with the evidence for it, not by
  its symptom. When the cause is not found yet, the draft says so.
- A change not yet made is conditional: it would, never it does.
- Each sentence names what it compares: "today's date in the car park's
  time zone", not "its own clock".
- A correction states what is true. It does not repeat the premise it
  corrects.
- For a reader outside the team, translate rather than cut. A code path
  or a column name becomes what the reader sees, and the fact itself
  stays.

## Length

As long as the question needs, and no longer. Every sentence answers
the question, supports the answer, or states the reader's next step.
Leave out the rest: a caveat the reader did not raise, an internal
detail they cannot act on, and an offer of work they did not ask for.
Four such additions come up most often:

- History. A status states where things stand now. When each step
  landed, and who did it, is the path to that state, not the state.
- A reassurance about what will happen later, such as a safeguard or
  something that "would catch it". It is a claim about a whole chain,
  up to the person it implies will hear. It stays only if the request
  asked for it and every link of the chain is checked.
- A reply to another message. One post serves one purpose. An answer
  to someone's earlier question, or an acknowledgement of a message
  other than the one being answered, is a post of its own, written when
  asked for.
- A closing ask. A next step is written only when the reader already
  has one. A draft that ends on its answer is finished; a question or
  task added to close on, such as asking someone for an estimate or
  handing them work nobody has assigned, goes.

Each fact appears once. A summary does not repeat the sections under
it, and a label does not repeat what the medium already shows, such as
a date the comment's timestamp carries. Next steps hold only what is
still to do; a finished item sits beside the finding it supports.

An answer to a question is complete where it is posted. Steps or
results that already have a record (a ticket comment, a page) are a
link to that record, not a copy of it. A status update opens with the
outcome of each ask, plus the links. Its proving numbers sit in the
sections below it, or in the opening when there are none.

## Shape

- Sections with plain labels only where the content divides. No title
  over the whole.
- In chat, no labels and no heading lines: each paragraph opens with
  its point, and a bold name appears only where it heads a list. One
  blank line separates blocks; none sits inside one.
- Bullets for parallel points, each a whole sentence.
- A ticket, page or PR the reader can open is a link. Other ids, hosts
  and commands as code.
- The reader's own next steps numbered. Choices offered to the reader
  numbered too, so the reply can name one.
- A table only for rows of the same kind.
- The message is the draft's text alone, with nothing about drafting it.

## Markup

Each medium has a writer, and the writer owns the markup. Write what
its `--help` says it takes, and never call the medium's API by hand.
Slack's writer is `~/.claude/scripts/slack_post.py`. A ticket or wiki
writer is the project's own helper.

A reply or an edit to a Slack post starts by reading its thread with
`~/.claude/scripts/slack_thread.py`. It writes every message under its
author's name, the files attached, and the channel id and thread ts the
writer needs. A post addressed to someone in the thread tags them with the
`<@U…>` its People block lists beside their name.

## Check, then post

Before showing the draft, read it once against Content, Length and
Shape. Then strike each sentence in turn. If the draft still gives the
reader what the request asked for without it, the sentence goes. Check
that no two bullets contradict, and that nothing the reader already has
is repeated.

Then check every number, name, date and link against its source, and
check them again after the last edit: an edit can make a checked
sentence false, and a moved sentence can lose the scope it was true in.

With no destination, the draft is the chat reply and nothing is posted.
Otherwise:

1. Show the final text, apart from the facts gathered for it.
2. Once it is approved, read the destination again. Anything new since
   the draft was written (a message, an answer, a status change) voids
   the approval. Do not post. Show what arrived and how it changes the
   draft.
3. Post it through the medium's writer.
4. Read the posted message back and confirm it rendered as intended,
   unless the writer does this itself.

Edit an earlier version in place rather than adding a second one.
