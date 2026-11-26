---
name: ticket
description: "Work a Jira ticket through its whole cycle — understand, plan, build, test, close — routing each phase to the skill or script that does it. Uses only the phases the goal needs: a Triage ticket stops once its answer is posted. Applies to any ticket, not only bugs; a Slack thread with a ticket is worked as that ticket. User-invoked via `/ticket [KEY]`, or when the user asks to take on a ticket."
argument-hint: <ticket-key>
---

# /ticket — the cycle for $ARGUMENTS

Five phases, in order. Each names what it reuses.

Before anything else, title the session with the bare ticket key, nothing more: `"$(~/.claude/scripts/project_file.sh --script session_rename.sh)" <KEY>` (e.g. `ABC-123`). Show the line it prints: a title record written, which the header shows once the session is resumed. A later `/review:pr` or `/review:bot` in the same session replaces it with its own title, which `/review:bot` reads its PR from.

## Tasks

The bullets below are the task list. Seed it with `TaskCreate`, one task per bullet, the bullet's text as its description:

- First, only the ticket-record bullet. Read the record, then seed every bullet the ticket's goal needs.
- A bullet that holds only under a condition — an API route changed, an open PR on the same code — is seeded once the condition is known to hold.
- A phase the goal does not need gets no tasks; say which phases are skipped and why.
- Work found along the way is a new task, not a wider one.

## A Triage ticket

A ticket whose record says `type: Triage` asks a question, and its answer is the deliverable. Nothing is built under it: no branch, no commit, no PR.

- Run §1 in full, except the post-mortem question, which waits until the answer names a cause.
- Answer in place of §2–§4, written as `/slack:reply` §4 says, for the reporter.
- Post the answer where the question was asked, the Slack thread the ticket links or else the ticket, after the user approves the text, and link it from the other.
- An answer that has not found the cause names what the data rules out, what no source read can see, and who holds a source that can. Ask that person for it with the `input` moment (§Throughout).
- A fix the answer calls for is a ticket of its own, created through `"$(~/.claude/scripts/project_file.sh --script jira-create.sh)"` and linked to this one, and worked with its own `/ticket`.
- Close with §5.

## 1. Understand

- Read the ticket record: `"$(~/.claude/scripts/project_file.sh --script postmortem_evidence.py)" <KEY> --out <scratchpad>/evidence` writes the ticket, its threads, linked issues and history, every Slack thread they link, and the ticket's attachments. Match each record an attachment holds against our own data.
- Check the ticket against the project's Definition of Ready: `"$(~/.claude/scripts/project_file.sh --script jira_dor.py)" <KEY>`. Show its output as printed. A ticket that fails it goes back to the reporter for completion. When an item fails:
  - Draft a comment that mentions the reporter (`[~accountid:<id>]`) and lists each failed item with its evidence, and each `judge` item you cannot settle from the record.
  - Ask the user whether to return the ticket with that comment, or go ahead without. Post it with `"$(~/.claude/scripts/project_file.sh --script jira-comment.sh)"` only on a yes. When the user goes ahead, the `started` comment (§Throughout) says which items are missing and why work began anyway.
  - When the team completes the ticket itself, start the description from `jira_dor.py <KEY> --skeleton`, write it with `"$(~/.claude/scripts/project_file.sh --script jira-description.sh)"`, and run the check again.
- Trace the mechanism in code, then measure it in production. Ask before reading each production source, keep raw data in the scratchpad, and publish counts only. Each source's reader: `"$(~/.claude/scripts/project_file.sh --script script_find.py)" --sources`. A source whose reader exits 75 is reported as unread, never as a measurement.
- Read where the code stands: `"$(~/.claude/scripts/project_file.sh --script ticket_prs.py)" <KEY> --since <created> --path <org/repo:file>…`, one `--path` per file the mechanism runs through.
- For each change found shipped, confirm it is deployed (`"$(~/.claude/scripts/project_file.sh --script deploy_status.py)" <org/repo> --contains <sha>`; its `--help` names where each platform records a deploy), and measure its effect before counting it as done. First count the runs of the path it changed since the deploy: a symptom that stopped on a path that has not run is not a fix shown to work.
- Ask whether to write a post-mortem, for every ticket: `/postmortem <KEY>`.
- Report and ask the open questions: `/draft`. The report names each PR's drift and each unanswered review finding.

## 2. Plan

- Follow each acceptance criterion as written unless a measurement says otherwise. List each deviation with the ticket that owns the criterion and why.
- List every caller, in every repo, of anything the change touches.
- Read every side effect (money, a message, a write) in code before it drives a decision.
- Offer the options with one recommendation.
- Record the decisions on every ticket they affect, and send deviations to the reporter: `"$(~/.claude/scripts/project_file.sh --script jira-comment.sh)"`, `"$(~/.claude/scripts/project_file.sh --script jira-link.sh)"`, and `"$(~/.claude/scripts/project_file.sh --script jira-create.sh)"` for split-off work.

## 3. Build

- When an open PR touches the same code, branch from its head, say so on its ticket, and retarget after it merges.
- When the change spans PRs in several repos, post the merge order on the ticket. Name each step between merges, such as a package tag the next PR must pin, and open a note for each.
- Pass the gate: `"$(~/.claude/scripts/project_file.sh --script ci_gate.py)" <repo>`.
- When the PRs are open for review: `"$(~/.claude/scripts/project_file.sh --script jira-progress.sh)" <KEY> review --pr <url>…` (§Throughout).
- Review, once the PR settles (`"$(~/.claude/scripts/project_file.sh --script gh-pr-bot-fetch.sh)" --wait` exits 0 and `.gate.checks.pending` is empty in what `gh-pr-fetch.sh` writes): `/review:pr` on every PR, the author's own included, then `/review:bot` to answer the bot and that review together. On a colleague's PR, `/review:pr` alone.
- Once `/review:bot` has answered a colleague's review: `/request:review <KEY>` asks them, in the ticket's thread, to take another look.

## 4. Test

- QA: `/qa <KEY>`, after §3's reviews, so the evidence is for the head the team will review.
- Once QA's evidence is posted: `/request:review <KEY>` asks the team in the review channel. It keeps one thread per ticket, so a later PR or a re-review is a reply in that thread.
- Acceptance: fixtures and replies for the tester, through `/draft`.

## 5. Close

The cycle ends when nothing it created is left without an owner.

- Place every open note on the ticket: `/notes <KEY>`. Work still owed, a check due on a later date among it, becomes a ticket through `"$(~/.claude/scripts/project_file.sh --script jira-create.sh)"`, with the date in it.
- Restore the shared state the cycle changed, such as a staging row or a flag, from its saved before-state, and say so on the ticket. State kept on purpose is named in a ticket comment, with the reason.
- Make the description match what shipped, each decision as the code implements it: `"$(~/.claude/scripts/project_file.sh --script jira-description.sh)"`.

## Throughout

- Keep the ticket's story on the ticket. No ticket goes silent: each moment below posts its comment through `"$(~/.claude/scripts/project_file.sh --script jira-progress.sh)" <KEY> <moment>`, without asking, and the session reports the text and the comment id. `--help` states each moment's options.
  - `started`: once the Definition of Ready check is settled, before any other work.
  - `blocked`: when work cannot go on, with what blocks it, who owns the blocker and the expected date.
  - `unblocked`: when the blocker clears.
  - `review`: when the PRs are open for review.
  - `input`: when the work needs an answer from another person or team.
- Place notes with `/notes <KEY>` whenever a batch is ready.
