---
name: postmortem
description: "Write a blameless post-mortem for a Jira ticket in the standard template, publish it under the project's post-mortem parent page after one confirmation, and comment the link on the ticket. Traces where the defect came from, when the fix shipped and how many users it affects today. User-invoked via `/postmortem [KEY]`, or when the user asks to write a post-mortem for a ticket."
argument-hint: <ticket-key>
---

# /postmortem — blameless post-mortem for a ticket

Write the post-mortem for $ARGUMENTS.

A report is one Confluence page under the page the project's `postmortem_parent` value names, titled `<KEY>: <customer-facing symptom>`. Its structure is the standard template, [`template.storage.html`](template.storage.html). Once it is published, the ticket gets a comment linking to it.

## 1. Gather the ticket record

```bash
"$(~/.claude/scripts/project_file.sh --script postmortem_evidence.py)" <KEY> --out <scratchpad>/evidence
```

`postmortem_evidence.py --help` states each file it writes. Read `<KEY>.md` in full, every linked dossier, every Slack thread `<scratchpad>/evidence/slack.md` lists (the customer's report is often there), every file under `<scratchpad>/evidence/attachments/`, and `latest-sibling.storage.html` for the voice and depth a report carries. The incident a fix ticket was raised from is usually a linked issue. It carries the customer report, the manual recovery, and follow-ups nobody filed.

**Use current keys.** `## Issues mentioned in the text` resolves every key the text names, so `ABC-12 → XYZ-345 (moved)` is one issue with two keys, not two issues. Write the current key everywhere, and give the old key once as "formerly".

## 2. Gather what the ticket does not hold

Fetch first (`git fetch origin`) and read the repo's default branch, never a stale checkout; `git rev-parse --abbrev-ref origin/HEAD` names it.

- **Where the defect came from.** Find the commit that introduced each defective line: `git log <default-branch> -S'<line>' -- <path>`, or `git log -L '/def <fn>(/,+25:<path>'`. Read the file at that commit with `git show <sha>:<path>` to confirm the claim. The code has often changed shape since, and an earlier version may have been correct. Cite short SHA and date.
- **Why it stayed hidden.** Name the second writer, the later change, or the missing check that turned a latent fault into an incident. Date it the same way.
- **When the fix shipped.** Run `gh pr view <N> -R <org>/<repo> --json createdAt,mergedAt,mergedBy,reviews` for each PR. Take deploy times from the ticket's comments or from the function's last-modified time.
- **How many are affected today.** Re-measure the affected population on the day you write, with the ticket's measurement script if it has one. "Heals on next use" is a claim, and only a count taken today shows whether anyone has healed. State the date and source beside every count. Write "not measured" where nothing was.
- **Earlier follow-ups.** For each follow-up the originating incident listed, check the default branch today and cite `file:line` for what is still open. Search Jira to see whether each follow-up was ever filed.
- **People.** Take every name from a system of record: `atlassian-auth.sh` plus `/rest/api/2/user/search?query=`, or `gh api users/<login> --jq .name`. Never infer a name from a login.

## 3. Write

Load the `draft` skill with the Skill tool before writing: `postmortem_publish.sh` refuses to publish until it is loaded.

Copy `template.storage.html` to `<scratchpad>/pm<KEY>.storage.html` and replace every bracketed placeholder; the storage format is Confluence XHTML. Keep its headings, summary rows, info panel and table header rows exactly as they are: `postmortem_publish.sh` refuses a report that departs from them. The summary table carries the page owner (the user's Atlassian account id), the incident and related tickets, the symptom, priority, affected services and evidence links. The Customer row carries the ticket's client label, and is the one row left out when no customer is involved; the template marks it `data-optional`, an attribute to delete when the row is kept.

| Section | What it holds |
|---|---|
| Executive summary | How the thing works, then what broke in it, then where it stands today with today's counts. |
| Leadup | The dated commits and events that made the incident possible, oldest first. |
| What went wrong | Each defect and its consequence. Include defects caught before release, such as a first fix that would have regressed. |
| What was the impact | Reported, measured and exposed populations, each with its source. Internal cost: escalations and manual fixes. |
| Detection | Who noticed and how. What would have shown it sooner. |
| Response | Who did what, when. Name the main delay plainly. |
| Recovery | The contract the fix enforces, each PR with its merge and deploy time, and the state measured today. |
| Timeline | UTC, from the dossier's history and the PR data. |
| Five whys | One chain per independent cause, near-misses included. |
| Blameless cause | The structural gap every defect shares, and what now closes it. |
| Backlog check | Whether any item covered this, and the state of earlier follow-ups on the default branch. |
| Related incidents | Earlier incidents with the same cause, by current key. |
| Lessons learned | One transferable lesson per line, including what went well. |
| Follow-up tasks | Each item, stated as filed (with key) or "to be filed". Never claim a ticket exists without its key. |

Rules:

- **Blameless.** Causes are structural. People appear only in Response and Timeline, and only for what they did.
- **Cite every claim.** Every count, date, name and code claim traces to a measurement, a commit, a PR or the dossier.
- **Resolved is not recovered.** "Deemed resolved" means the fix shipped and passed QA. Say separately whether affected users have actually recovered.
- **No end-user personal data and no secrets.** Omit end users' names and emails, and any password or token. Customer company names and staff names are fine.

## 4. Confirm, then publish

Run the dry run. It creates nothing:

```bash
"$(~/.claude/scripts/project_file.sh --script postmortem_publish.sh)" --dry-run \
  --ticket <KEY> --title "<KEY>: <symptom>" <scratchpad>/pm<KEY>.storage.html
```

Summarise the report for the user. Include what they should know before it is shared: populations not yet recovered, follow-ups not filed, and the named people. Then ask **one** `AskUserQuestion`: publish under the proposed title. On yes:

```bash
"$(~/.claude/scripts/project_file.sh --script postmortem_publish.sh)" \
  --ticket <KEY> --title "<KEY>: <symptom>" <scratchpad>/pm<KEY>.storage.html
```

If it stops after creating the page, the page exists: fix it as in §6 and do not publish again.

## 5. Close

- Journal the publication with `journal.sh`. Open a note with `-n` for each unfiled follow-up the user has not decided on.
- Give the user the page link and the ticket comment id, and list what the report leaves open.

## 6. Correcting a published report

Fetch the live page with `"$(~/.claude/scripts/project_file.sh --script confluence-page.sh)" <id> --to <scratchpad>`, because someone may have edited it. Change only what is wrong, with targeted `Edit` calls on the file it prints, and write it back with `"$(~/.claude/scripts/project_file.sh --script confluence-safe-update.sh)" --from <that file>`. The ticket comment links to the page, not to a version, and stays as it is.
