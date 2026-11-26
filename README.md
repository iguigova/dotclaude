# dotclaude

My Claude Code setup: the rules it works by, the skills it runs,
and the tested scripts behind them. It mirrors `~/.claude`.

[iguigova.github.io/dotclaude](https://iguigova.github.io/dotclaude/) walks
through the loop and a day with it next to a plain setup, in pictures.

| Path | What it holds |
|---|---|
| `CLAUDE.md` | The global rules every session loads. |
| `credo.md` | Who I am and how I work, imported by `CLAUDE.md`. |
| `*_guidelines.md` | Coding, style and accessibility guidelines, and one per language. |
| `skills/` | What a session can be asked to do, such as `/audit` or `/journal`. |
| `scripts/` | The scripts the rules and skills call. Each offers `--self-test`. |
| `settings.json`, `statusline.sh` | Hooks, permissions and the status line. |
| `index.html` | The page above. |

The look of my pages and documents is one file, the way the credo is:
[`brand.css`](https://github.com/iguigova/iguigova.github.io/blob/main/brand.css),
shown with itself at [iguigova.github.io/style.html](https://iguigova.github.io/style.html).
Beside it, [`brand.js`](https://github.com/iguigova/iguigova.github.io/blob/main/brand.js)
gives every page the same Light and Dark switch, and
[`analytics.js`](https://github.com/iguigova/iguigova.github.io/blob/main/analytics.js)
counts the page's visits with Google Analytics, which sets cookies.

## Layers

Two layers: `~/.claude` holds the methods, scripts and rules every project
shares, and each project's own `.claude/` holds its values, secrets, verbs
and records. [`ARCHITECTURE.md`](ARCHITECTURE.md) states the parts, how they
fit together, and how one is added, changed or removed.

## The loop

A rule names the script that enforces it. The script carries its own
`--self-test`, and `scripts/selftest.sh` runs every one of them, with
`shellcheck`, the frontmatter lint and the settings lint. It then holds the
code the change touched to `coding_guidelines.md`'s bar through
`scripts/change_gate.py`: no function above cyclomatic complexity 10, and
every mutant on a changed line killed by the script's own self-test. A
project's gate runs the same script over its own code in Python, Ruby,
JavaScript and TypeScript, Go, Dart, Clojure and Haskell, naming a language's
test command with `--test` where the gate cannot find one. For Python it reuses the coverage file CI already wrote.
C# has no mutation runner yet, so a C# change fails the gate. A change
is committed only when that selftest passes, and the session records it in a
journal.

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

The selftest needs `git`, `python3` with `pytest`, `pytest-cov` and ReportLab, `shellcheck`
and `uv`.

## How it is published

`~/.claude` is a local-only repo, and everything here, this README and the
page included, is written there. `scripts/dotclaude_export.sh` copies it, as
committed, into this repo. It refuses the copy on any denylisted name, token
shape, Slack id, real email or binary file, runs the copy's selftest, and commits.
When any session ends, `scripts/session_end_export.sh` runs that export for
a new `~/.claude` commit and pushes the result; a refusal opens a note.
Each `~/.claude` commit made through `scripts/tooling_commit.sh` runs the
export's scan on the new HEAD first and prints any hit to the session that
committed it, so a refusal is seen before the session ends.

Every push then runs the selftest on GitHub, in `.github/workflows/selftest.yml`,
and a push to `main` publishes the page from that commit.

## License

MIT
