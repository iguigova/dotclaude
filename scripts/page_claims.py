#!/usr/bin/env python3
"""Check the claims a page makes, and refresh the numbers it dates.

Usage:
    page_claims.py [--root DIR] [--run DIR] PAGE
    page_claims.py --count PAGE
    page_claims.py --self-test

A claim is an element carrying data-check="<path>" and data-says="<words>":
the file at <path>, relative to DIR (default the page's own folder), must hold
<words> on one line. The same element may carry data-test="<path>" and
data-proves="<case>", the self-test case that proves the claim's behaviour:
the TAP that script's self-test printed, <run>/<script>.txt as
`selftest.sh --keep <run>` writes it (default DIR/run), must hold the line
`ok N - <case>`. A path with a part starting with a dot fails: GitHub Pages
serves no such path, so the reader's browser could never check it. The page
runs the same check in the reader's browser, against the run published with
it; this runs it before the page is published. Each claim is judged as
git_fact.sh judges a fact: 0 the words are there, 1 the file was read and they
are not, 75 the file could not be read, so nothing is learned. A case is 0 on
`ok`, 1 on `not ok` or when it never printed, 75 when the TAP could not be read. A claim with a
self-test case is one claim, judged by the worse of its two parts, as the page
counts it. The exit status is 1 when any claim fails, else 75 when any got no
answer, else 0.

--count rewrites, in place, every element carrying data-count="<key>" with
what this machine counts now, and data-count="date" with today's date:
  commits, since   ~/.claude's commit count and the date of its first commit
  entries          journal entries in every session history a session ran in
  projects         how many of those histories hold an entry
  closed, open     notes closed and still open across them
The histories are found from the working directory each Claude Code session
transcript under ~/.claude/projects records: the nearest
.claude/session_history.md at or above it.
"""

import argparse
import contextlib
import datetime
import io
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path

from tap import Tap

HOME = Path.home()
TOOLING = HOME / ".claude"
QUEUE = TOOLING / "scripts" / "journal_queue.sh"
ENTRY = re.compile(r"^## 20\d\d-", re.M)
COUNTED = re.compile(r'(data-count="(\w+)"[^>]*>)[^<]*(<)')
DATETIME = re.compile(r'(data-count="date" datetime=")[^"]*(")')
TRANSCRIPT_HEAD = 30
CASE = re.compile(r"^(ok|not ok) \d+ - (.*)$")


# Claims


@dataclass(frozen=True)
class Part:
    path: str
    says: str
    case: bool = False


@dataclass(frozen=True)
class Claim:
    parts: tuple[Part, ...]


@dataclass(frozen=True)
class Verdict:
    code: int
    line: int = 0


class ClaimParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.claims: list[Claim] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        parts = []
        if "data-check" in a and "data-says" in a:
            parts.append(Part(a["data-check"], a["data-says"]))
        if "data-test" in a and "data-proves" in a:
            parts.append(Part(a["data-test"], a["data-proves"], case=True))
        if parts:
            self.claims.append(Claim(tuple(parts)))


def claims(html: str) -> list[Claim]:
    parser = ClaimParser()
    parser.feed(html)
    return parser.claims


def unserved(path: str) -> bool:
    return any(part.startswith(".") for part in Path(path).parts)


def printed(run: Path, part: Part) -> Path:
    return run / f"{Path(part.path).name}.txt"


def judge(root: Path, run: Path, part: Part) -> Verdict:
    if unserved(part.path):
        return Verdict(1)
    try:
        text = (printed(run, part) if part.case else root / part.path).read_text()
    except OSError:
        return Verdict(75)
    for i, line in enumerate(text.split("\n")):
        if part.case:
            m = CASE.match(line)
            if m and m[2] == part.says:
                return Verdict(0 if m[1] == "ok" else 1, i + 1)
        elif part.says in line:
            return Verdict(0, i + 1)
    return Verdict(1)


def report(run: Path, part: Part, v: Verdict) -> str:
    where = printed(run, part) if part.case else part.path
    if v.code == 0:
        return f"  ok   {where}:{v.line}"
    if v.code == 1 and unserved(part.path):
        return f"  FAIL {part.path} is a path GitHub Pages does not serve"
    if v.code == 1 and part.case:
        return f"  FAIL {where} has no passing case: {part.says}"
    if v.code == 1:
        return f"  FAIL {where} no longer says: {part.says}"
    return f"  ??   {where} could not be read"


def status(codes: list[int]) -> int:
    if 1 in codes:
        return 1
    return 75 if 75 in codes else 0


def check(page: Path, root: Path, run: Path) -> int:
    found = claims(page.read_text())
    if not found:
        print(f"page_claims: {page} makes no claims", file=sys.stderr)
        return 1
    codes = []
    for c in found:
        verdicts = [judge(root, run, p) for p in c.parts]
        print("\n".join(report(run, p, v) for p, v in zip(c.parts, verdicts)))
        codes.append(status([v.code for v in verdicts]))
    tested = sum(1 for c in found if any(p.case for p in c.parts))
    print(f"{codes.count(0)} of {len(codes)} claims hold, {tested} with a self-test")
    return status(codes)


# Counts


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
        raise SystemExit(f"page_claims: nothing counts {sorted(missing)}")
    html = COUNTED.sub(lambda m: m[1] + values[m[2]] + m[3], html)
    return DATETIME.sub(lambda m: m[1] + today.isoformat() + m[2], html)


def count(page: Path) -> int:
    today = datetime.datetime.now(datetime.UTC).date()
    page.write_text(rewrite(page.read_text(), counts(today), today))
    print(f"page_claims: {page} counted on {today}")
    return 0


# Self-test


def self_test() -> int:
    t = Tap()
    expect = t.check

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        run = root / "run"

        def checked(page: Path, root: Path) -> int:
            with contextlib.redirect_stdout(io.StringIO()):
                return check(page, root, run)

        (root / "a.sh").write_text("# one\n# it never &amp; pushes\n")
        run.mkdir()
        (run / "a.sh.txt").write_text(
            "ok 1 - a red case mentioned\nok 2 - a red case\nnot ok 3 - broken\n1..3\n"
        )
        page = root / "index.html"
        holds = '<p data-check="a.sh" data-says="never &amp;amp; pushes">'
        page.write_text(holds)
        found = claims(page.read_text())
        expect(
            found == [Claim((Part("a.sh", "never &amp; pushes"),))],
            "an entity in data-says is read as the browser reads it",
        )
        expect(
            judge(root, run, found[0].parts[0]) == Verdict(0, 2),
            "the words found give 0 and their line",
        )
        expect(checked(page, root) == 0, "a page whose claims hold exits 0")
        tested = '<p data-check="a.sh" data-says="one" data-test="a.sh" data-proves='
        case = claims(tested + '"a red case">')
        expect(
            case == [Claim((Part("a.sh", "one"), Part("a.sh", "a red case", True)))],
            "a claim and its self-test case are one claim",
        )
        expect(
            judge(root, run, case[0].parts[1]) == Verdict(0, 2),
            "a case is its whole name on an ok line of the run, not a part of one",
        )
        page.write_text(holds + tested + '"a red case">')
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            check(page, root, run)
        expect(
            said.getvalue().endswith("2 of 2 claims hold, 1 with a self-test\n"),
            "a tested claim counts once, and the tally says it is tested",
        )
        page.write_text(tested + '"no such case">')
        expect(checked(page, root) == 1, "a case the run never printed fails")
        page.write_text(tested + '"broken">')
        expect(checked(page, root) == 1, "a case that printed not ok fails")
        (run / "a.sh.txt").unlink()
        page.write_text(tested + '"a red case">')
        expect(checked(page, root) == 75, "a run whose TAP is missing gets no answer")
        page.write_text(holds + '<p data-check="a.sh" data-says="pushes">')
        expect(checked(page, root) == 0, "a phrase on a line holds")
        page.write_text(holds + '<p data-check="a.sh" data-says="one\n# it">')
        expect(checked(page, root) == 1, "words across two lines do not hold")
        (root / ".hidden").mkdir()
        (root / ".hidden" / "w.yml").write_text("run: it\n")
        page.write_text(holds + '<p data-check=".hidden/w.yml" data-says="run">')
        expect(checked(page, root) == 1, "a path Pages does not serve fails")
        page.write_text(holds + '<p data-check="gone.sh" data-says="x">')
        expect(checked(page, root) == 75, "an unreadable file exits 75")
        page.write_text(
            '<p data-check="gone.sh" data-says="x">'
            '<p data-check="a.sh" data-says="always">'
        )
        expect(checked(page, root) == 1, "a contradiction outranks no answer")
        page.write_text("<p>no claims</p>")
        expect(checked(page, root) == 1, "a page with no claims fails")

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
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("page", type=Path)
    ap.add_argument("--root", type=Path)
    ap.add_argument("--run", type=Path)
    ap.add_argument("--count", action="store_true")
    a = ap.parse_args()
    if a.count:
        return count(a.page)
    root = a.root or a.page.parent
    return check(a.page, root, a.run or root / "run")


if __name__ == "__main__":
    sys.exit(main())
