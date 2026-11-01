# dotclaude

My Claude Code setup: the rules it works by, the skills and commands it runs,
and the tested scripts behind them. It mirrors `~/.claude`.

| Path | What it holds |
|---|---|
| `CLAUDE.md` | The global rules every session loads. |
| `credo.md` | Who I am and how I work, imported by `CLAUDE.md`. |
| `*_guidelines.md` | Coding, style and accessibility guidelines, and one per language. |
| `skills/`, `commands/` | What a session can be asked to do, such as `/audit` or `/journal`. |
| `scripts/` | The scripts the rules and skills call. Each offers `--self-test`. |
| `settings.json`, `statusline.sh` | Hooks, permissions and the status line. |

## The loop

A rule names the script that enforces it. The script carries its own
`--self-test`, and `scripts/selftest.sh` runs every one of them, with
`shellcheck`, the frontmatter lint and the settings lint. A change is committed
only when that selftest passes, and the session records it in a journal.

## Memory

What a session keeps for the next one is a fact: one file, one claim, and a
`verify:` command that exits 0 while the claim holds. `scripts/memory_fact.sh`
writes a fact only when its command passes, and `scripts/memory_check.sh --all`
re-runs every command each night and deletes a fact its own command
contradicts. `scripts/memory_schedule.sh install` schedules that run on a
systemd user timer, which catches up on a night the machine missed. The facts
stay on the machine; only the scripts are here.

## Use it

Read it, take what fits. To try the whole setup, clone it to `~/.claude` on a
machine without one; the scripts resolve paths from `$HOME`.

```bash
~/.claude/scripts/selftest.sh
```

The selftest needs `git`, `python3` and `shellcheck`.

## How it is published

`~/.claude` is a local-only repo. `scripts/dotclaude_export.sh` copies the
files above, as committed, into this repo. It refuses the copy on any denylisted
name, token shape, real email or binary file, runs the copy's selftest, and
commits.

## License

MIT
