#!/usr/bin/env python3
"""Refresh the numbers a page dates, and the day they were counted.

Usage:
    page_counts.py PAGE
    page_counts.py --self-test

Rewrites, in place, every element of PAGE carrying data-count="<key>" with
what this machine counts now, and data-count="date" with today's date:
  commits, since   ~/.claude's commit count and the date of its first commit
  entries          journal entries in every session history a session ran in
  projects         how many of those histories hold an entry
  closed, open     notes closed and still open across them
The histories are found from the working directory each Claude Code session
transcript under ~/.claude/projects records: the nearest
.claude/session_history.md at or above it.
"""

import datetime
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from tap import Tap

HOME = Path.home()
TOOLING = HOME / ".claude"
QUEUE = TOOLING / "scripts" / "journal_queue.sh"
ENTRY = re.compile(r"^## 20\d\d-", re.M)
COUNTED = re.compile(r'(data-count="(\w+)"[^>]*>)[^<]*(<)')
DATETIME = re.compile(r'(data-count="date" datetime=")[^"]*(")')
TRANSCRIPT_HEAD = 30


def run(*args: str, env: dict | None = None) -> str:
    return subprocess.run(
        args, capture_output=True, text=True, check=True, env=env
    ).stdout


def long_date(d: datetime.date) -> str:
    return f"{d.day} {d:%B %Y}"


def transcript_cwd(path: Path) -> str | None:
    with path.open() as f:
        for _, line in zip(range(TRANSCRIPT_HEAD), f):
            if '"cwd"' in line:
                return json.loads(line).get("cwd")
    return None


def history_of(cwd: str) -> Path | None:
    for d in [Path(cwd), *Path(cwd).parents]:
        h = d / ".claude" / "session_history.md"
        if h.is_file():
            return h
    return None


def histories(projects: Path) -> list[Path]:
    cwds = {transcript_cwd(t) for t in projects.glob("*/*.jsonl")}
    found = {history_of(c) for c in cwds if c}
    return sorted(h for h in found if h)


def notes(history: Path, *flags: str) -> int:
    env = {"PATH": "/usr/bin:/bin", "HOME": str(HOME)}
    env["JOURNAL_HIST"] = str(history)
    return len(run(str(QUEUE), *flags, env=env).splitlines())


def counts(today: datetime.date) -> dict[str, str]:
    hs = histories(TOOLING / "projects")
    entries = [len(ENTRY.findall(h.read_text())) for h in hs]
    first = run("git", "-C", str(TOOLING), "log", "--reverse", "--format=%as")
    return {
        "commits": run(
            "git", "-C", str(TOOLING), "rev-list", "--count", "HEAD"
        ).strip(),
        "since": long_date(datetime.date.fromisoformat(first.split()[0])),
        "entries": f"{sum(entries):,}",
        "projects": str(sum(1 for n in entries if n)),
        "closed": f"{sum(notes(h, '--closed') for h in hs):,}",
        "open": f"{sum(notes(h) for h in hs):,}",
        "date": long_date(today),
    }


def keys_of(html: str) -> set[str]:
    return {m[2] for m in COUNTED.finditer(html)}


def rewrite(html: str, values: dict[str, str], today: datetime.date) -> str:
    missing = keys_of(html) - values.keys()
    if missing:
        raise SystemExit(f"page_counts: nothing counts {sorted(missing)}")
    html = COUNTED.sub(lambda m: m[1] + values[m[2]] + m[3], html)
    return DATETIME.sub(lambda m: m[1] + today.isoformat() + m[2], html)


def count(page: Path) -> int:
    today = datetime.datetime.now(datetime.UTC).date()
    page.write_text(rewrite(page.read_text(), counts(today), today))
    print(f"page_counts: {page} counted on {today}")
    return 0


# Self-test


def self_test() -> int:
    t = Tap()
    expect = t.check

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        day = datetime.date(2026, 11, 2)
        html = (
            '<dt data-count="open">0</dt>'
            '<time data-count="date" datetime="2000-01-01">old</time>'
        )
        out = rewrite(html, {"open": "16", "date": long_date(day)}, day)
        expect(
            out == '<dt data-count="open">16</dt><time data-count="date"'
            ' datetime="2026-11-02">2 November 2026</time>',
            "counts and the date, with its datetime, are rewritten",
        )
        try:
            rewrite('<dt data-count="nope">0</dt>', {}, day)
            expect(False, "a key nothing counts is refused")
        except SystemExit:
            expect(True, "a key nothing counts is refused")

        proj = root / "projects" / "p"
        work = root / "work" / "sub"
        proj.mkdir(parents=True)
        work.mkdir(parents=True)
        (root / "work" / ".claude").mkdir()
        (root / "work" / ".claude" / "session_history.md").write_text("x")
        cwd = json.dumps({"cwd": str(work)})
        (proj / "s.jsonl").write_text('{"type":"x"}\n' + cwd + "\n")
        expect(
            histories(root / "projects")
            == [root / "work" / ".claude" / "session_history.md"],
            "a session's history is the nearest one above its cwd",
        )

    return t.end()


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) != 2 or sys.argv[1].startswith("-"):
        print("usage: page_counts.py PAGE | --self-test", file=sys.stderr)
        return 2
    return count(Path(sys.argv[1]))


if __name__ == "__main__":
    sys.exit(main())
