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

A folder is one of three things to the tooling:

- **Project**: a folder whose `.claude/project` names it, written by
  `scripts/project_init.sh`. It holds the project layer and the records.
  Its `.claude/` is versioned in the project's own repository, or, when the
  project spans several repositories, in a local-only repository at the
  project's folder that ignores the clones beneath it. A public
  repository ignores the records, which stay on this machine.
- **Clone**: a git repository the project works in, listed in the project's
  `.claude/clones`. A clone's own `.claude/`
  belongs to the clone's repository and is never a layer. A clone that is
  itself a project carries its own `.claude/project`, and inside it that
  nearer project is the layer.
- **Root**: a folder that holds projects, such as `~/src`. It has no project
  layer: its values, secrets, clones and records stop with exit 1, and scripts
  resolve in the global layer alone. A session starts in a project's
  folder: Claude Code keeps a session's transcript under the folder it
  starts in, and a SessionStart hook,
  `scripts/session_start_project.sh`, names the project the session
  resolved to, and tells the user when it started at a root or below its
  project's folder, so transcripts and records never split by start folder.

The project is the nearest folder at or above the working directory whose
`.claude/` holds `project`; `~/.claude` is never taken for one, and a
`.claude/` without the marker is passed over. `scripts/project_file.sh
--root` is the one finder: every script that needs the project calls it. A
name resolves in the project first, then in the global layer, and a name in
neither stops the caller with exit 1. Nothing guesses and nothing falls back
to a default.

## Parts

| Part | What it is | Layers |
|---|---|---|
| value | One setting, one file, such as `atlassian_site` | Project only; no global defaults |
| secret | One credential, one file in `<project>/.secrets/`, never versioned | Project only |
| clone | A git repository the project works in: one line of `<project>/.claude/clones` | Project only |
| script | One verb: its contract in `--help`, proven by `--self-test` | Both; a project script overrides the global one of the same name and keeps its contract |
| skill | A method: the order of steps, the judgement, the claim each step proves | Global for shared workflows, project for domain work; never overridden |
| rule | A `CLAUDE.md` line, loaded every turn | Both, by Claude Code's own layering |
| setting | Permissions, plugins and hooks in `settings.json` and `<project>/.claude/settings.local.json` | Both; a project's settings are not inherited from parent directories |
| record | Session history, notes and memory facts | Project only |

### Value and secret

`scripts/project_file.sh --value <name>` prints a value without its blank
and `#` lines, and exits 1 naming where it looked when the file is missing or
holds no value. `scripts/secret_file.sh <name>` prints the path of
`<project>/.secrets/<name>`, and exits 1 when it is absent or empty.
`project_file.sh --root` prints the project's folder. A script reads every
value and credential, and finds the project, through these, never from a path
of its own or from where the script itself sits.

### Clone

`<project>/.claude/clones` lists one clone a line, `<name> <path>
<remote>`, whitespace-separated, with blank and `#` lines ignored. The path
is from the project's folder, and the remote is the clone's `git remote
get-url origin`. `scripts/clones.sh --add <path>` writes the line from the
clone itself. `project_file.sh --clones` prints every listed clone, and
refuses a line in another shape or a name listed twice. `project_file.sh
--clone <name>` prints the clone's folder, and exits 1 naming the manifest
when the name is not listed or the folder's origin is not that remote.
`clones.sh` reports every clone through `dev_setup.sh`, and `--sync` clones
the missing ones. A script reaches a clone only by its name. A self-test
reads a clone and never writes to one: `change_gate.py` links each listed
clone into the copy it tests in.

### Script

A script is one verb. Its header is its contract, `--help` prints it, and
its `--self-test` proves it; `shell_coding_guidelines.md` states the header,
the exit codes and the self-test.

`scripts/project_file.sh --script <name>` resolves a script: the project's
`.claude/scripts/<name>`, else `~/.claude/scripts/<name>`, else exit 1
naming both. A project script that overrides a global one keeps the global
contract. The global script's `--self-test` proves it by running the
implementation `UNDER_TEST` names, and `gate_layer_names` in the project's
`selftest.sh` fails an override whose global script does not read
`UNDER_TEST`, or whose cases it does not pass.

### Skill

A skill holds the method and nothing else: the steps, the judgement, and the
claim each step proves. It must call scripts by name, through
`project_file.sh --script`, and hold no value, ID or URL. It names a
capability, such as the tracker or the chat, where it can.

Claude Code loads a personal skill over a project skill of the same name, so
a skill name lives in one layer only; `gate_layer_names` fails a name both
hold.

### Composition

Skills call scripts, and scripts call scripts, each by name through
`project_file.sh --script`; a sourced library such as `atlassian-auth.sh` is
found the same way, and a Python script resolves through `scripts/resolve.py`,
whose `module()` imports a Python library such as `group_run.py` the same way.
The two resolvers are reached at `~/.claude/scripts`, and a self-test sources
`tap.sh` or imports `tap.py` from beside itself. A step that differs between projects is a verb the project
provides. Its contract is the claim it proves. For example, `pr_env` takes a
PR reference, prints the environment's URL, and exits 0 only once the PR's
head commit is proven deployed there. How it gets there is the project's
business. `scripts/project_verbs.txt` lists every verb a global part calls,
with its contract, which the project's script carries word for word in its
`--help`; `gate_verb_contracts` fails a copy that differs. A project without the verb stops at that step. When two projects
implement a verb the same way, the implementation moves to the global layer.

### Where prose goes

| Prose | Home |
|---|---|
| A script's caveats | Its `--help` |
| A fact about one project | A memory fact in that project |
| A policy that holds every turn | `CLAUDE.md` |
| The method | The skill |

## Context and containers

The diagrams follow the C4 model (https://c4model.com). The system is both
layers. `/inventory` is the code-level view, generated from the tree.

```mermaid
flowchart TB
  dev["<b>Developer</b><br>[Person]<br>Asks for work and answers its prompts"]
  visitor["<b>Visitor</b><br>[Person]<br>Reads the public copy"]
  cc["<b>Claude Code</b><br>[Software System]<br>The assistant in the terminal"]
  sys["<b>The tooling</b><br>[Software System]<br>~/.claude and each project's .claude:<br>rules, gates, skills, tested scripts, records"]
  timer["<b>systemd user timer</b><br>[Software System]<br>Fires at 04:30, catches up missed nights"]
  work["<b>Jira, Confluence, Slack</b><br>[Software System]<br>Tickets, pages, posts"]
  gh["<b>GitHub</b><br>[Software System]<br>Pull requests, the public dotclaude repo and its Pages site"]
  dev -- "types requests, approves steps" --> cc
  cc -- "loads rules, fires hooks, runs skills and scripts" --> sys
  timer -- "runs the nightly memory check" --> sys
  sys -- "one script per action" --> work
  sys -- "reads and comments on PRs; pushes the export" --> gh
  visitor -- "reads over HTTPS" --> gh
```

```mermaid
flowchart TB
  cc["<b>Claude Code</b><br>[Software System]"]
  timer["<b>systemd user timer</b><br>[Software System]"]
  ext["<b>Jira, Confluence, Slack, GitHub</b><br>[Software System]"]
  subgraph sys [The tooling]
    rules["<b>Rules</b><br>[Markdown]<br>CLAUDE.md, credo.md"]
    guides["<b>Guidelines</b><br>[Markdown]<br>*_guidelines.md"]
    hooks["<b>Hooks</b><br>[JSON]<br>settings.json"]
    skills["<b>Skills</b><br>[Markdown]<br>skills/: the methods"]
    scripts["<b>Scripts</b><br>[Bash, Python]<br>scripts/: one verb each, self-tested"]
    project["<b>Project layer</b><br>[Files]<br>&lt;project&gt;/.claude: values, verbs, skills;<br>&lt;project&gt;/.secrets"]
    records["<b>Records</b><br>[Markdown]<br>session history, notes, memory facts"]
  end
  clones["<b>Clones</b><br>[git repositories]<br>listed in &lt;project&gt;/.claude/clones"]
  cc -- "loads every turn" --> rules
  cc -- "reads before a code edit; guideline_gate.py refuses until then" --> guides
  cc -- "fires on session and tool events" --> hooks
  cc -- "loads when asked" --> skills
  hooks -- "run the gates and the session-end scripts" --> scripts
  skills -- "call by name through project_file.sh --script" --> scripts
  scripts -- "read values, secrets and project verbs" --> project
  scripts -- "write and recheck" --> records
  scripts -- "reach by name through project_file.sh --clone" --> clones
  timer -- "memory_check.sh --all" --> scripts
  scripts -- "one verb per action" --> ext
```

## The map

Each family below names the problem it solves, its entry points, and what
it hands on.

### Rules and their gates

`CLAUDE.md` and `credo.md`, which it imports, are in every turn's context
and say how every session works. The `*_guidelines.md` files are read on
demand, before a code edit. A rule that can be checked names the script that
enforces it, and hooks in `settings.json` run these scripts, each said in the
first sentence of its own header. `scripts/hook_list.py --write` writes the
list, and `selftest.sh` refuses one out of step with the hooks or the headers.

<!-- hooks:begin -->
- `scripts/session_end_notes.sh` (SessionEnd): SessionEnd hook: place what the ending session noticed, unattended.
- `scripts/session_end_sweep.sh` (SessionEnd): SessionEnd hook: sweep the project's git clones and the machine's strays, at most once a day, and report what the ending session leaves running.
- `statusline.sh` (SessionEnd --end): the status line, and the SessionEnd hook that removes its caches.
- `scripts/session_end_export.sh` (SessionEnd): SessionEnd hook: publish ~/.claude's public part whenever it has moved.
- `scripts/block_gate.py` (SessionEnd clear; PermissionDenied denied; PreToolUse gate; PostToolUse[AskUserQuestion] clear; UserPromptSubmit clear): once auto mode blocks a call, no other tool runs until the user answers.
- `scripts/guideline_gate.py` (SessionEnd clear; PreToolUse[Edit|Write|NotebookEdit] edit; PostToolUse[Read] read; SessionStart[compact] clear): no code is edited with the edit tools before its guidelines are read in that session.
- `scripts/draft_gate.py` (SessionEnd clear; PostToolUse[Skill] loaded; SessionStart[compact] clear): no text is sent to people before its writing skill is loaded in that session.
- `scripts/ask_gate.py` (Stop stop): a reply asks nothing in prose; a question to the user is the dialog.
- `scripts/session_start_notes.sh` (SessionStart): SessionStart hook: say how much is in the note queue, before the session forgets to ask.
- `scripts/session_start_last.sh` (SessionStart): SessionStart hook: show what ran while nobody was here.
- `scripts/claude_account.sh` (SessionStart check): run a project under its own Claude Code account, sharing every piece of the tooling in ~/.claude.
- `scripts/session_start_project.sh` (SessionStart): SessionStart hook: name the project a session resolved to, and say so when the session started where its records split.
<!-- hooks:end -->

### The gate loop

Every change is proven before it is kept. Each script's `--self-test` proves
its contract. `scripts/selftest.sh` runs every self-test, `shellcheck`, and
the lints for frontmatter, settings, allowed tools and prose names, then
`scripts/change_gate.py` holds the changed code to the complexity cap and the
mutation check. `scripts/gate_lib.sh` holds the checks every tooling repo
shares. `scripts/tooling_commit.sh` commits named paths only when that gate
is green; `journal.sh` commits the session history through it.

A change is kept in this order:

```mermaid
flowchart TB
  edit["Edit"] -- "1. PreToolUse" --> gg["guideline_gate.py<br>refuses until the guidelines are read"]
  gg -- "2. tooling_commit.sh -m … -- paths" --> st["selftest.sh<br>self-tests, shellcheck, lints"]
  st -- "3" --> cg["change_gate.py<br>complexity cap, mutation check"]
  cg -- "4. green" --> commit["commit of the named paths"]
  commit -- "5" --> j["journal.sh<br>entry committed through tooling_commit.sh"]
  j -- "6. SessionEnd" --> ex["session_end_export.sh → dotclaude_export.sh<br>allowlist copy, denylist refusal, selftest, commit"]
  ex -- "7. push" --> gh["GitHub: public dotclaude"]
```

### Records: history, notes and memory

What a session did and learned outlives it.

- **History.** `scripts/journal.sh` appends one entry per state-changing turn
  to `<project>/.claude/session_history.md`. `/timelog` bills from it.
- **Notes.** `journal.sh -n` opens a note in the same file;
  `scripts/journal_queue.sh` reads the queue, for `/notes` and `/recap`.
  `/notes` places each note as a
  fact, skill, script, rule, setting or ticket. A SessionStart hook
  (`scripts/session_start_notes.sh`) reports the queue. A SessionEnd hook
  (`scripts/session_end_notes.sh`) places what it can unattended, and
  `scripts/session_end_report.sh` writes `.claude/session_end.last` for the
  next session.
- **Reports.** Each unattended run adds a report to the project's `.claude/`:
  `memory_check.last`, `session_end.last` or `git_sweep.last`. A SessionStart
  hook (`scripts/session_start_last.sh`) shows each once, whole, and moves it
  aside. Two reports of current state, `~/.claude/memory_check.last` from the
  nightly check and `~/.claude/stray_sweep.last` from the stray sweep, are
  shown while they exist; each writer removes its own once nothing is left.
- **Memory.** `scripts/memory_fact.sh` writes a fact only when its `verify`
  command passes. `scripts/memory_check.sh --all` re-runs every command each
  night, on the timer `scripts/memory_schedule.sh` installs, and deletes a
  fact its own command contradicts. `scripts/git_fact.sh` checks a claim
  about a file in a repository. A project's facts live in
  `<project>/.claude-project-data/memory/`, versioned with the project.

```mermaid
flowchart TB
  hist[("session_history.md<br>entries and notes")]
  mem[("memory/<br>one fact per file")]
  journal["journal.sh"] -- "appends entries; -n opens a note" --> hist
  queue["journal_queue.sh"] -- "reads the open notes" --> hist
  notes["/notes"] -- "lists through" --> queue
  notes -- "places a note as a fact" --> fact["memory_fact.sh"]
  start["session_start_notes.sh<br>SessionStart"] -- "reports the queue" --> queue
  endn["session_end_notes.sh<br>SessionEnd"] -- "detaches when a note is open" --> run["session_end_run.sh"]
  run -- "places unattended" --> notes
  run --> report["session_end_report.sh"] --> sel[(".claude/session_end.last")]
  fact -- "writes when verify passes" --> mem
  check["memory_check.sh --all<br>04:30 timer"] -- "reruns verify, deletes a contradicted fact" --> mem
  check --> mcl[(".claude/memory_check.last")]
  last["session_start_last.sh<br>SessionStart"] -- "shows once, moves aside" --> sel
  last -- "shows once, moves aside" --> mcl
```

### Projects and accounts

- `scripts/project_init.sh` makes a git repository a project: its `.claude/`
  and the `project` marker, the line that re-includes `.claude/` in a
  repository that ignores all it does not name, a private `<project>/.secrets/`, the ignore lines that keep secrets and
  transcripts out of git, and the link from `~/.claude/projects/<slug>` into
  `<project>/.claude-project-data/`, where Claude Code then keeps the
  project's sessions and memory. A second run has nothing to do.
- `scripts/project_file.sh` and `scripts/secret_file.sh` resolve a project's
  folder, values, scripts, clones and secrets; `scripts/resolve.py` reads them
  for Python.
- `scripts/clones.sh` lists, reports and clones the repositories a project
  works in.
- `scripts/claude_account.sh` runs a project under the account its
  `.claude/config_dir` names. That account's directory links every shared
  entry back to `~/.claude`, so one copy of the tooling serves every account.
  A SessionStart hook says when a session runs under the wrong one.
  `claude-me`, from `shell/memcap.sh`, runs a session in any project under the
  default `~/.claude` account instead.
- `scripts/dev_setup.sh` reports a clone's branch, its drift and its
  uncommitted work.
- `scripts/git_sweep.sh`, run once a day from a SessionEnd hook
  (`scripts/session_end_sweep.sh`), removes git state that is proven finished
  and writes `.claude/git_sweep.last`. The same run then runs
  `scripts/stray_sweep.py --apply`, which removes the stale temp folders and
  reports the processes and files this user left on the machine. Every
  session end also runs it once that session's Claude Code process has
  exited, so the next session sees what the last one left running.

### Service verbs

One script per action on an outside system. A verb that needs a site or a
token reads it through `project_file.sh` and `secret_file.sh`:

- Jira: `jira-*.sh`
- Confluence: `confluence-*.sh`, with `atlassian-auth.sh`
- GitHub pull requests: `gh-pr-*.sh`, `gh_pr_ref.py`, `gh-ticket-prs.sh`, `ticket_prs.py`
- Slack: `slack_post.py`, `slack_thread.py`
- Browser logins: `playwright_login.sh`

### Workflows

The skills a person asks for by name: `review:pr`, `review:bot`,
`request:review`, `timelog`, `draft`, `voice`, `audit`, `benchmark`,
`normative`, `gist`, `inventory`, `recap`, `journal`, `notes`,
`standup`, `postmortem`, `slack:reply`, `ticket` and `qa`. Most are methods over the verbs above. `skill_triggers.json` holds the cases that say
when each should fire, and `scripts/skill_trigger_test.py` runs them.

### Publishing

`~/.claude` is a local-only repo. For each new commit,
`scripts/session_end_export.sh` runs `scripts/dotclaude_export.sh`, which
copies the allowlisted part into the public dotclaude clone, refuses any name
in `dotclaude_denylist.txt`, runs the copy's selftest and commits; then
`session_end_export.sh` pushes the clone. Text in the global layer is
therefore public, and names no employer.

## Changing the system

### Add a skill

1. **Choose its layer.** A method any project could run goes in
   `~/.claude/skills/`; domain work goes in the project. The name must not
   exist in the other layer.
2. **The skill holds the method only.** It calls scripts by name through
   `project_file.sh --script`, and holds no value, ID or URL.
3. **Every step that touches a system is a script.**
   - Reuse one that fits (`script_find.py`).
   - A new one states its contract in `--help` and proves it with `--self-test`.
   - A step that differs per project is a verb the project provides.
4. **Every setting is a value file in the project, and every credential a secret.**
5. **Caveats go in `--help`, project facts in memory, and every-turn policy in `CLAUDE.md`.**
6. **In the same commit:** add the skill's cases to `skill_triggers.json`,
   get `selftest.sh` green, and update every document the skill makes false.

### Add a script

Search first with `script_find.py`. A new script is one verb, with its
header, its exit codes and its `--self-test`. A verb that holds a project's
specifics lives in that project; one with none lives in the global layer. A
project verb that a global part calls is listed with its contract in
`scripts/project_verbs.txt`, in the same commit as its first caller. A
project verb moves to the global layer when a second project implements it
the same way.

### Add a project

Run `scripts/project_init.sh` in the repository, with `--account <config
dir>` when it runs under its own account. List the repositories it works
in with `scripts/clones.sh --add <path>`, which `scripts/clones.sh --sync`
clones on another machine. Then add the project's
`scripts/selftest.sh`, sourcing `gate_lib.sh` and running `gate_layer_names`.

### Change a part

A changed contract changes its `--help`, its `--self-test` and every caller
`/inventory <name>` lists under "named by", in one commit.

### Remove a part

`/inventory <name>` shows what names the part. Remove or repoint those
callers first. Delete the part in the same commit as every document that
names it.
