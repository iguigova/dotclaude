---
description: Inventory of everything you authored under .claude/ — skills, commands, scripts, rules, settings and memory. No argument censuses the tree, facts only — what needs attention, then one table of every item — runs per month, cost, upkeep; --kind narrows it to one kind. A name audits that one item.
argument-hint: "[name [--scope global|project]] [--kind skill|command|script|rules|settings|memory] [--json] [--project DIR]"
---

```bash
python3 ~/.claude/scripts/skill_inventory.py $ARGUMENTS
```

## No name — the census, facts only

Print it as the script emits it and add nothing: no status, no ranking, no
recommendation, no summary. Answer questions about it only when
asked.

## A name — that item, then audited

Two items can share a name. The script then lists the candidates instead of
a report — ask the user which one is meant and re-run with `--scope`.

Print the facts verbatim first. Then read the item's own file, end to end.

Then read what its kind depends on:

- **skill, command** — the scripts it names and the guidelines it cites,
  and `~/.claude/scripts/allowed_tools_lint.py <file>`'s rows, each judged.
- **script** — the items listed under `named by`, because a script's contract
  is whatever its callers rely on, and one named by nothing has no contract.
- **rules** — the documents it cites and the ones that cite it. A rule stated
  in two places is the finding.
- **settings** — run `~/.claude/scripts/settings_lint.py` first and report
  its output verbatim. Then read what the lint does not check: what each entry admits, the script behind a hook, the command
  behind a permission. An entry matching more than it names is the finding.
- **memory** — run `~/.claude/scripts/memory_fact.sh verify <name>` from the
  project root, which runs the fact's `verify:` in the environment the nightly
  check uses. Exit 0 is the claim holding, 75 is no answer, anything else
  contradicts it (`~/.claude/scripts/memory_lib.sh` states this). Report the
  result and never delete — `~/.claude/scripts/memory_check.sh` owns deletion,
  and it runs unattended.

Then invoke the `audit` skill, which owns the criteria and the rules. Three
fields of this report are what it means by "a tool reports": an unset variable
in a bash block, a fixed `/tmp` path and a line it restates are each flagged
patterns with a benign case.

What each field measures is in the script's docstring. Read it there when a
question depends on a definition; never restate it from memory.

## Closing the round

A finding the user approved is fixed, gated and committed in the same round.

```bash
~/.claude/scripts/tooling_commit.sh -m "<message>" -- <path>…
```

Report the sha it printed, or the refusal it named.

- **The message** — a subject in a form the script accepts, and a body stating
  the mechanism, then the defect it closed, as the finding did.
- **Nothing approved, or nothing found** — there is nothing to commit, and the
  round ends at the report.
