# Architecture

How the tooling is built, why each part exists, and how a part is added,
changed or removed. The list of every item, what it does and who calls it,
is generated on demand: `/inventory` (`scripts/skill_inventory.py`) prints
the census with each script's callers under "named by", and
`scripts/script_find.py <words>` finds a script by what its header says.
This page names entry points only.

## Layers

Two layers, and every session runs in exactly one project.

- **Global**: `~/.claude`. The methods every project can run, the scripts
  they call, the rules and the hooks. It names no employer.
- **Project**: `<project>/.claude`. That project's values, secrets, verbs,
  domain skills and records. Nothing about one project lives anywhere else.

A name resolves in the project first, then in the global layer. When
neither has it, the caller stops with exit 1 and names both places it
looked. Nothing guesses and nothing falls back to a default.

## Parts

| Part | What it is | Layers |
|---|---|---|
| value | One setting, one file, such as `atlassian_site` | Project only; no global defaults |
| secret | One credential, one file in `<project>/.secrets/`, never versioned | Project only |
| script | One verb: its contract in `--help`, proven by `--self-test` | Both; a project script overrides the global one of the same name and keeps its contract |
| skill | A method: the order of steps, the judgement, the claim each step proves | Global for shared workflows, project for domain work; never overridden |
| rule | A `CLAUDE.md` line, loaded every turn | Both, by Claude Code's own layering |
| setting | Permissions, plugins and hooks in `settings.json` and `<project>/.claude/settings.local.json` | Both; a project's settings are not inherited from parent directories |
| record | Session history, notes and memory facts | Project only |

### Value and secret

`scripts/project_file.sh <name>` prints the project's `.claude/<name>`, and
exits 1 naming where it looked when there is none. `scripts/secret_file.sh
<name>` prints `<project>/.secrets/<name>`, and exits 1 when it is absent or
empty. A script reads every value and credential through these two, never
from a path of its own.

### Script

A script is one verb. Its header states what it does, every exit code it
uses and a `Usage:` block; `--help` prints that header. The exit codes are
the house meanings in `shell_coding_guidelines.md` → Exit Codes and Failure:
0 done and proven, 1 refused or missing, 2 usage, 75 no answer. Its
`--self-test` prints TAP through `scripts/tap.sh` or `scripts/tap.py` and
proves the contract the header states.

A project script that overrides a global one keeps the global contract, and
passes the global script's self-test cases.

### Skill

A skill holds the method and nothing else: the steps, the judgement, and the
claim each step proves. It calls scripts by name, never by path, and holds no
value, ID or URL. It names a capability, such as the tracker or the chat,
where it can.

Claude Code loads a personal skill over a project skill of the same name, so
a skill name lives in one layer only.

### Composition

Skills call scripts, and scripts call scripts, each by name through the
resolution above. A step that differs between projects is a verb the project
provides. Its contract is the claim it proves. For example, `pr_env` takes a
PR reference, prints the environment's URL, and exits 0 only once the PR's
head commit is proven deployed there. How it gets there is the project's
business. A project without the verb stops at that step. When two projects
implement a verb the same way, the implementation moves to the global layer.

### Where prose goes

| Prose | Home |
|---|---|
| A script's caveats | Its `--help` |
| A fact about one project | A memory fact in that project |
| A policy that holds every turn | `CLAUDE.md` |
| The method | The skill |

## The map

Each family below names the problem it solves, its entry points, and what
it hands on.

### Rules and their gates

`CLAUDE.md`, `credo.md` and the `*_guidelines.md` files say how every
session works. A rule that can be checked names the script that enforces it,
and hooks in `settings.json` run those scripts:

- `scripts/guideline_gate.py`: no code is edited before its guidelines are read.
- `scripts/ask_gate.py`: a question to the user goes through the question dialog.
- `scripts/block_gate.py`: once a call is blocked, nothing else runs until the user answers.

### The gate loop

Every change is proven before it is kept. Each script's `--self-test` proves
its contract. `scripts/selftest.sh` runs every self-test, `shellcheck`, and
the lints for frontmatter, settings, allowed tools and prose names, then
`scripts/change_gate.py` holds the changed code to the complexity cap and the
mutation check. `scripts/gate_lib.sh` holds the checks every tooling repo
shares. `scripts/tooling_commit.sh` commits named paths only when that gate
is green, and hands the commit to the session history.

### Records: history, notes and memory

What a session did and learned outlives it.

- **History.** `scripts/journal.sh` appends one entry per state-changing turn
  to `<project>/.claude/session_history.md`. `/timelog` bills from it,
  and `/recap` reads it.
- **Notes.** `journal.sh -n` opens a note in the same file;
  `scripts/journal_queue.sh` reads the queue. `/notes` places each note as a
  fact, skill, script, rule, setting or ticket. A SessionStart hook
  (`scripts/session_start_notes.sh`) reports the queue. A SessionEnd hook
  (`scripts/session_end_notes.sh`) places what it can unattended, and
  `scripts/session_end_report.sh` writes `.claude/session_end.last` for the
  next session.
- **Memory.** `scripts/memory_fact.sh` writes a fact only when its `verify`
  command passes. `scripts/memory_check.sh --all` re-runs every command each
  night, on the timer `scripts/memory_schedule.sh` installs, and deletes a
  fact its own command contradicts. `scripts/git_fact.sh` checks a claim
  about a file in a repository.

### Projects and accounts

- `scripts/project_file.sh` and `scripts/secret_file.sh` resolve a project's
  values and secrets.
- `scripts/claude_account.sh` runs a project under the account its
  `.claude/config_dir` names. That account's directory links every shared
  entry back to `~/.claude`, so one copy of the tooling serves every account.
  A SessionStart hook says when a session runs under the wrong one.
- `scripts/dev_setup.sh` reports a clone's branch, its drift and its
  uncommitted work.
- `scripts/git_sweep.sh`, run once a day from a SessionEnd hook
  (`scripts/session_end_sweep.sh`), removes git state that is proven finished
  and writes `.claude/git_sweep.last`.

### Service verbs

One script per action on an outside system. A verb that needs a site or a
token reads it through `project_file.sh` and `secret_file.sh`:

- Jira: `jira-*.sh`
- Confluence: `confluence-*.sh`, with `atlassian-auth.sh`
- GitHub pull requests: `gh-pr-*.sh`, `gh_pr_ref.py`, `gh-ticket-prs.sh`
- Slack: `slack_post.py`, `slack_thread.py`
- Browser logins: `playwright_login.sh`

### Workflows

The skills a person asks for by name: `review:pr`, `review:bot`,
`request:review`, `timelog`, `draft`, `voice`, `audit`, `benchmark`,
`normative`, `gist`, `inventory`, `recap`, `journal` and `notes`. Each is a
method over the verbs above. `skill_triggers.json` holds the cases that say
when each should fire, and `scripts/skill_trigger_test.py` runs them.

### Publishing

`~/.claude` is a local-only repo. `scripts/session_end_export.sh` runs
`scripts/dotclaude_export.sh` for each new commit. The export copies the
public part into the public dotclaude clone, refuses any name in
`dotclaude_denylist.txt`, runs the copy's selftest, and pushes. Text in the
global layer is therefore public, and names no employer.

## Changing the system

### Add a skill

1. **Choose its layer.** A method any project could run goes in
   `~/.claude/skills/`; domain work goes in the project. The name must not
   exist in the other layer.
2. **The skill holds the method only.** It calls scripts by name and holds
   no value, ID or URL.
3. **Every step that touches a system is a script.**
   - Reuse one that fits (`script_find.py`).
   - A new one states its contract in `--help` and proves it with `--self-test`.
   - A step that differs per project is a verb the project provides. A verb
     with one implementation starts in that project.
4. **Every setting is a value file in the project, and every credential a secret.**
5. **Caveats go in `--help`, project facts in memory, and every-turn policy in `CLAUDE.md`.**
6. **In the same commit:** add the skill's cases to `skill_triggers.json`,
   get `selftest.sh` green, and update every document the skill makes false.

### Add a script

Search first with `script_find.py`. A new script is one verb, with its
header, its exit codes and its `--self-test`. It lives in the project until
a second project needs the same implementation.

### Change a part

A changed contract changes its `--help`, its `--self-test` and every caller
`/inventory <name>` lists under "named by", in one commit.

### Remove a part

`/inventory <name>` shows what names the part. Remove or repoint those
callers first. Delete the part in the same commit as every document that
names it.
