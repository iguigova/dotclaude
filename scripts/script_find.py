#!/usr/bin/env python3
"""Find the scripts that already do something, by what their headers say.

A script states what it does in its header: the module docstring of a .py,
the leading comment block of a .sh. That header is the only description a
script has, so it is what this searches -- the header and the file name of
every script under scripts/ and helpers/ of the global tree (~/.claude) and
of the project the working directory is in: the nearest directory at or
above it whose .claude/ holds scripts/ or helpers/, so a product repo's own
.claude/ of settings and agents does not hide the project around it. The census reads the same
headers through skill_inventory.py, so the two never describe a script two
ways.

A script is listed when its name or header holds at least one of the words.
A word holds where a word of the name or header starts with it, ignoring
case, so `camera` finds `cameras`. The list is ranked by the words held, each
weighted by how few scripts hold it (`find` states the weight), ties by name.
Each entry is the score, the scope, the path, the words it held and the
header's first sentence, so a reader decides from the list which to open.

--sources lists the production sources that have a reader, each beside its
script, by name. A script reads one when its header holds a line
`Production source: <name>`, one line per source; the header owns the claim,
so the list is never edited by hand and a reader added or removed changes it.

A reader exits 75 when a call to its source fails: refused, timed out, or
answered with an error. It uses 75 for nothing else, and its stderr names the
failed call. 75 is the code a memory fact's verify gives for no answer
(memory_lib.sh), so a caller tells "could not check" from every answer the
source gave. The reader's header states its 75 beside its other exit codes.

--untagged PATTERN keeps that list whole and true. It names every script whose
text matches PATTERN, a project's production resource names, and whose header
holds neither a `Production source:` line nor a `Production use: <what>` line.
The second is for a script that touches production without being a source's
reader, such as a deploy step or a one-ticket fetch. It also names every reader
whose header does not state its exit 75. It exits 1 when it names one, so a
selftest can gate on it. `--skip PATH` leaves out the script that holds the
pattern, which matches its own text.

Usage:
  script_find.py WORD [WORD ...] [--limit N]
  script_find.py --sources
  script_find.py --untagged PATTERN [--skip PATH]
  script_find.py --self-test
"""

from __future__ import annotations

import argparse
import ast
import math
import re
import sys
import tempfile
from pathlib import Path

import skill_inventory as si

LIMIT = 10
LINE_CHARS = 120
SENTENCE = re.compile(r"(?<=[.!?])\s")
SOURCE = re.compile(r"^Production source: (\S.*?)\s*$", re.M)
TAGGED = re.compile(r"^Production (?:source|use): \S", re.M)
# An exit code, not an octet: 34.246.75.172 states no exit.
NO_ANSWER = re.compile(r"(?<![\d.])75(?![\d.])")
COMMENT_LINE = re.compile(r"^#(?: (.*)|$)")
WORD = re.compile(r"[a-z0-9]+")
# A word this short or this common matches most headers and ranks nothing.
MIN_WORD = 4
COMMON = frozenset({"this", "that", "with", "from", "into", "what", "when",
                    "each", "every", "script", "scripts", "file", "files",
                    "prints", "print", "runs", "usage", "self", "test"})


def project_of(start: Path) -> Path | None:
    """The nearest directory at or above start whose .claude/ holds scripts/
    or helpers/, other than the home directory, whose .claude/ is the global
    tree. A .claude/ with neither is a repo's own settings, not a project."""
    for d in (start, *start.parents):
        if d != Path.home() and any((d / ".claude" / s).is_dir()
                                    for s in ("scripts", "helpers")):
            return d
    return None


def scripts(home: Path, project: Path | None) -> list[dict]:
    found = si.scripts_in(home, "global")
    return found + (si.scripts_in(project / ".claude", "project")
                    if project else [])


def header(suffix: str, text: str) -> str:
    """A script's whole header: every line of a .py docstring, the leading
    comment block of a .sh. A file that cannot be parsed has none."""
    if suffix == ".py":
        try:
            return ast.get_docstring(ast.parse(text)) or ""
        except (SyntaxError, ValueError):
            return ""
    return si.comment_block(text)


def header_lines(suffix: str, text: str) -> str:
    """A script's header line by line: a .py docstring, or every comment line
    a .sh starts with, blank ones included. header() stops a .sh at its first
    blank comment line, so a line further down would be missed."""
    if suffix == ".py":
        return header(suffix, text)
    lines = []
    for ln in text.splitlines():
        if ln.startswith("#!"):
            continue
        m = COMMENT_LINE.match(ln)
        if not m:
            break
        lines.append(m.group(1) or "")
    return "\n".join(lines)


def sources(items: list[dict]) -> list[tuple[str, dict]]:
    """Each production source a script's header names, beside the script,
    sorted by source and then path."""
    found = []
    for it in items:
        path = Path(it["path"])
        text = header_lines(path.suffix, path.read_text(encoding="utf-8",
                                                        errors="replace"))
        found += [(name, it) for name in SOURCE.findall(text)]
    return sorted(found, key=lambda f: (f[0].lower(), f[1]["path"]))


def untagged(items: list[dict], pattern: re.Pattern, skip: str = "") -> list[tuple[str, dict]]:
    """By path, each script that names a production resource and whose header
    says neither what source it reads nor what it does there ("untagged"), and
    each reader whose header does not state its exit 75 ("no 75")."""
    found = []
    for it in items:
        path = Path(it["path"])
        if skip and path.resolve() == Path(skip).resolve():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        head = header_lines(path.suffix, text)
        if pattern.search(text) and not TAGGED.search(head):
            found.append(("untagged", it))
        elif SOURCE.search(head) and not NO_ANSWER.search(head):
            found.append(("no 75", it))
    return sorted(found, key=lambda f: f[1]["path"])


def render_sources(found: list[tuple[str, dict]]) -> str:
    width = max((len(n) for n, _ in found), default=0)
    return "\n".join(f"{n:<{width}}  {it['scope']:<7}  {si.short(it['path'])}"
                     for n, it in found)


def header_of(path: Path) -> str:
    return header(path.suffix, path.read_text(encoding="utf-8", errors="replace"))


def words(text: str) -> list[str]:
    return list(dict.fromkeys(w for w in WORD.findall(text.lower())
                              if len(w) >= MIN_WORD and w not in COMMON))


def find(query: list[str], items: list[dict], limit: int,
         skip: str = "") -> list[dict]:
    """The scripts holding the most of the rarest query words. A word holds
    where a word of the name or header starts with it, so `camera` finds
    `cameras` and `long` does not find `along`. Each word weighs log(N/n), n
    the scripts holding it out of N, so a word every header uses ranks
    nothing and a word one script uses decides. A word in the name or the
    header's first sentence -- what the script says it does -- counts twice,
    above one met only in the detail further down."""
    docs = []
    for it in items:
        if it["path"] == skip:
            continue
        head = header_of(Path(it["path"]))
        lead = set(WORD.findall(f"{it['name']} {summary(head)}".lower()))
        docs.append((it, head, set(WORD.findall(f"{it['name']} {head}".lower())),
                     lead))
    query = [q.lower() for q in query]
    holds = {q: [any(w.startswith(q) for w in d[2]) for d in docs]
             for q in query}
    leads = {q: [any(w.startswith(q) for w in d[3]) for d in docs]
             for q in query}
    weight = {q: math.log(len(docs) / n) if (n := sum(h)) else 0.0
              for q, h in holds.items()}
    hits = []
    for k, (it, head, _, _) in enumerate(docs):
        found = [q for q in query if holds[q][k]]
        score = sum(weight[q] * (2 if leads[q][k] else 1) for q in found)
        if found:
            hits.append({**it, "score": round(score, 1),
                         "words": found,
                         "line": summary(head) or "(no header)"})
    hits.sort(key=lambda h: (-h["score"], h["name"]))
    return hits[:limit]


def summary(head: str) -> str:
    """The header's first sentence, at most LINE_CHARS long. A sentence can wrap
    across lines, so it is read from the first paragraph joined."""
    para = " ".join(head.strip().split("\n\n", 1)[0].split())
    line = SENTENCE.split(para, 1)[0]
    return line if len(line) <= LINE_CHARS else line[:LINE_CHARS - 1] + "…"


def render(hits: list[dict]) -> str:
    return "\n".join(f"{h['score']:>4}  {h['scope']:<7}  {si.short(h['path'])}"
                     f"  [{' '.join(h['words'])}]\n      {h['line']}"
                     for h in hits)


# ---------------------------------------------------------------- self-test

def self_test() -> int:
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        home, project = root / "home", root / "proj"
        si.write(home / "scripts/camera_report.py",
                 '"""Per-camera LPR\nreport. More.\n\nReads plates."""\n')
        si.write(home / "scripts/broken.py", '"""unterminated\n')
        si.write(project / ".claude/helpers/lambda-tail.sh",
                 "#!/usr/bin/env bash\n# Tail a Lambda's log stream. Newest\n"
                 "# stream first.\nset -e\n")
        si.write(project / ".claude/scripts/plates.sh",
                 "#!/bin/sh\n# Count plates along each camera, from 10.0.75.1.\n#\n"
                 "# Production source: plate reads\n#\n"
                 "# Production source: Camera roles\nset -e\n"
                 "# Production source: past the header\n")
        si.write(home / "scripts/rails_sql.py",
                 '"""Read Rails.\n\nProduction source: Rails Postgres\n'
                 'Not a source: line\n\nExit 0 rows, 75 a failed call.\n"""\n')
        si.write(project / ".claude/scripts/deploy.sh",
                 "#!/bin/sh\n# Deploy.\nset -e\n# Production use: past the header\necho prod-db\n")
        si.write(project / ".claude/scripts/golive.sh",
                 "#!/bin/sh\n# Go live.\n#\n# Production use: writes the config\necho prod-db\n")
        si.write(project / ".claude/scripts/tail.py",
                 '"""Tail it."""\nDB = "prod-db"\n')
        si.write(project / "api/repo/.claude/settings.json", "{}\n")
        items = scripts(home, project)
        got = {
            "ranked": [(h["name"], h["words"]) for h in
                       find(["camera", "plates", "long"], items, LIMIT)],
            "rare": [h["name"] for h in find(["lambda", "camera"], items, LIMIT)],
            "lead": [h["name"] for h in find(["reads"], items, LIMIT)]
                    + [h["name"] for h in find(["newest", "report"], items, LIMIT)],
            "limit": len(find(["camera", "plates"], items, 1)),
            "summary": summary("x" * 200)[-2:],
            "wrapped": [h["line"] for h in find(["report"], items, LIMIT)],
            "line": [h["line"] for h in find(["lambda"], items, LIMIT)],
            "broken": [h["name"] for h in find(["unterminated"], items, LIMIT)],
            "project": project_of(project / ".claude/scripts") == project,
            "nested": project_of(project / "api/repo") == project,
            "sources": [(n, it["name"]) for n, it in sources(items)],
            "untagged": [(kind, it["name"]) for kind, it in
                         untagged(items, re.compile(r"prod-db|Rails"))],
            "skip": [it["name"] for _, it in untagged(items, re.compile(r"prod-db|Rails"),
                                                      str(project / ".claude/scripts/tail.py"))],
        }
    want = {"ranked": [("plates.sh", ["camera", "plates"]),
                       ("camera_report.py", ["camera", "plates"])],
            "rare": ["lambda-tail.sh", "camera_report.py", "plates.sh"],
            "lead": ["camera_report.py", "camera_report.py", "lambda-tail.sh"],
            "limit": 1, "summary": "x…", "wrapped": ["Per-camera LPR report."],
            "line": ["Tail a Lambda's log stream."],
            "broken": [], "project": True, "nested": True,
            "sources": [("Camera roles", "plates.sh"), ("plate reads", "plates.sh"),
                        ("Rails Postgres", "rails_sql.py")],
            "untagged": [("untagged", "deploy.sh"), ("no 75", "plates.sh"),
                         ("untagged", "tail.py")],
            "skip": ["deploy.sh", "plates.sh"]}
    # A key on one side only is a check that never ran, so it fails too.
    bad = sorted(set(got) ^ set(want)) + [k for k in want
                                          if k in got and got[k] != want[k]]
    for k in bad:
        print(f"FAIL {k}: expected {want.get(k)!r} got {got.get(k)!r}")
    print("script_find self-test: " + ("FAIL" if bad else "ok"))
    return 1 if bad else 0


# --------------------------------------------------------------------- main

def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("word", nargs="*")
    ap.add_argument("--limit", type=int, default=LIMIT)
    ap.add_argument("--sources", action="store_true",
                    help="list the production sources that have a reader")
    ap.add_argument("--untagged", metavar="PATTERN",
                    help="name the scripts that match PATTERN with no production line,"
                         " and the readers whose header states no exit 75")
    ap.add_argument("--skip", metavar="PATH", default="",
                    help="with --untagged, a script to leave out")
    ap.add_argument("--self-test", action="store_true")
    return ap


def main() -> int:
    args = parser().parse_args()
    if args.self_test:
        return self_test()
    if args.sources:
        if args.word:
            parser().error("--sources takes no words")
        found = sources(scripts(si.HOME, project_of(Path.cwd())))
        print(render_sources(found) if found else
              "no script's header names a production source")
        return 0
    if args.untagged:
        if args.word:
            parser().error("--untagged takes no words")
        found = untagged(scripts(si.HOME, project_of(Path.cwd())), re.compile(args.untagged),
                         args.skip)
        for kind, it in found:
            print(f"{kind:<8}  {it['scope']:<7}  {si.short(it['path'])}")
        return 1 if found else 0
    if not args.word:
        parser().error("give at least one word")
    hits = find(args.word, scripts(si.HOME, project_of(Path.cwd())), args.limit)
    print(render(hits) if hits else "no script's name or header holds any of: "
          + " ".join(args.word))
    return 0


if __name__ == "__main__":
    sys.exit(main())
