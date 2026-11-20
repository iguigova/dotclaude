---
name: qa
description: "Hand a fix to QA and prove it first: bring up the PR environment, post QA instructions on the Jira ticket, run every step in that environment, and post the evidence as a threaded reply. User-invoked via `/qa [KEY]`, or when the user asks for testing instructions plus evidence on a ticket."
argument-hint: <ticket-key> [PR refs]
---

# /qa — QA instructions, then evidence

Hand $ARGUMENTS to QA. The product is two comments on the ticket:

1. **QA instructions**, written for the QA tester. The project's memory names the tester, their pronouns, their account id and their address; mention them as `[~accountid:<id>]`.
2. **QA evidence**, your own run of those instructions, posted as a threaded reply to them.

The evidence numbers its tests to match the instructions one for one. When the project's memory names a reference pair of comments, follow its layout.

## 1. Read what is being tested

- Find the PRs from the ticket's comments, or with `"$(~/.claude/scripts/project_file.sh --script gh-ticket-prs.sh)" <KEY>`. For each one, read the diff at its current head, not the version you remember. A PR can move while you work: another session may push review fixes. Record each head SHA now, and read the commit bodies of anything newer.
- Say the mechanism to yourself: what the user does, what the code does in response, and what changed. The tests exercise that path. They do not exercise the diff line by line.
- List what the environment **cannot** show before writing any step: a branch that only splits in production, a second region the environment does not run. A limit like that goes under *Notes* in the instructions and under *Not covered* in the evidence, together with who checks it after release.

## 2. Bring up the environment

```bash
"$(~/.claude/scripts/project_file.sh --script pr_env.sh)" <owner/repo>#<N> [options]
```

Read its `--help` first: it names each repository's environment, the options each takes, and what each costs. Bringing one up is outward-facing and costs money, so ask the user once which options to use. It exits 0 only once the environment runs the PR's head commit; a branch that moves after this step means running it again.

Some data is shared beyond the environment; `pr_env.sh --help` and the scripts it names state where. Change such data only with the user's approval, and only after saving its before-state in the scratchpad. Open a note to restore it (`journal.sh -n`), and name the change under *Notes* in the instructions.

## 3. Write the instructions and post them

- **What changed.** Explain the mechanism in the tester's words, then give one bullet per behaviour change.
- **Where.** The URLs `pr_env.sh` printed. Say plainly what the environment writes to beyond itself and where its email lands, as its `--help` states.
- **Setup.** A fixture the tester can reach from the UI, or for an API-only change, through the calls the tests make. Check it is live: a soft-deleted row is invisible in the UI. Invitees use synthetic addresses, the tester's own address plus-addressed `<local>+<ticket>-<case>@<domain>`, one per test group.
- **Tests.** Group them with letters (A, B, C…) and number the steps. Each step reads `action → expected result`, and the expected result says what the tester will see: on screen, or for an API call, the status and the response fields.
- **Notes.** What this environment cannot show, and any known quirk that the tester should not fail the test for.

Post the comment:

```bash
"$(~/.claude/scripts/project_file.sh --script jira-comment.sh)" <KEY> <file.wiki>
```

## 4. Run every step yourself

- Create fixtures through the service the UI's controller calls. Do not insert rows yourself. Use your own address, plus-addressed the same way, never the tester's, and never reseed a fixture someone else may be testing on.
- **Code and database reads in the environment.** The way to run code there and read its database is in the `--help` of the script `pr_env.sh` names for that repository. Never write a database URL to a file.
- **API steps.** Make each call with `curl` against the environment and quote the status and the response fields in *Observed*.
- **Browser steps.** Drive them with Playwright, saving each screenshot in the folder the Playwright server is allowed to write to. Read the page with `browser_evaluate` so the evidence quotes text and `href` values exactly.
- **When a result differs from the instructions:**
  - The instructions were wrong: correct them. If no one has acted on the comment yet, edit it in place (`jira-comment.sh --edit <id> <KEY> <file.wiki>`) and rerun. Otherwise post a correction.
  - The product misbehaved: decide whether the fix caused it. Read the same code on the default branch. If it is there too, the problem existed before the fix. Record it in the evidence. Do not fail the fix for it.
- **Both comments are normative.** They state the current steps and results. Never mention earlier drafts, discarded runs or in-place corrections.

## 5. Post the evidence

Attach the screenshots first, since a comment can only embed an attachment that already exists:

```bash
"$(~/.claude/scripts/project_file.sh --script jira-attach.sh)" <KEY> <shot>.png …
```

Then post the evidence comment as a reply to the instructions:

```bash
"$(~/.claude/scripts/project_file.sh --script jira-comment.sh)" --reply <instructions-id> <KEY> <file.wiki>
```

- **What was tested.** Each PR, with its SHA and the environment running it, the date and UTC time window, the fixture ids, and the invitees.
- **How I ran it.** Every place where your run departed from the tester's path, with the tester's action each departure stands in for.
- **Results table.** Columns `||Test||Expected||Observed||Result||`, with one row per step, in the same order as the instructions. *Observed* quotes the page, the response and the database; it does not paraphrase. The Result column uses `(/)` for a pass and `(x)` for a fail.
- **Screenshots.** Embed them with `!name.png|thumbnail!`.
- **Secrets.** Shorten every token to 8 characters wherever the evidence shows it, in text and in screenshots.
- **Not covered here.** What this environment cannot show, and who checks it after release.
- **Found during the run, not caused by these PRs.** List each problem with the `file:line` on the default branch.

Journal the run: both comment ids, the pass/fail count, and a note for each problem that existed before the fix. Leave the environment up. The PR's own lifecycle tears it down when the PR closes.
