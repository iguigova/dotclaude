#!/usr/bin/env python3
"""change_gate_tools.py — change_gate.py's mutation through the tools that mutate for us: Stryker, go-gremlins and Dart's mutation_test.

Imported, never run; ``python3 change_gate_tools.py --self-test`` runs change_gate's whole
suite: the parts are one tool, and the cases that pin one part sit beside another.
"""

import contextlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402
from change_gate_base import COPY_SKIP, Change, EQUIVALENT, STRYKER, Verdict, find_tool, git, missing, self_test_env, self_test_files, self_test_repo, self_test_run  # noqa: E402
from change_gate_mutator import copy_tree, report_mutation  # noqa: E402


# ---------------------------------------------------------------- tools that mutate for us

# Stryker switches mutants through __STRYKER_ACTIVE_MUTANT__ in one instrumented
# sandbox, so no file changes between mutants. Turbo's strict env mode hides that
# variable from the test, and its cache replays the first run's pass, so under a
# turbo test command every mutant survives unless the mode is loose and the run forced.
TURBO_MUTATION_ENV = {"TURBO_ENV_MODE": "loose", "TURBO_FORCE": "true"}

def accepted(repo: Path, path: str, line: int) -> bool:
    lines = line_text(repo / path)
    return 0 < line <= len(lines) and bool(EQUIVALENT.search(lines[line - 1]))


def line_text(path: Path) -> list[str]:
    with contextlib.suppress(OSError):
        return path.read_text().splitlines()
    return []


def stryker_lived(report: dict) -> list[tuple[str, int, str]]:
    return [
        (path, m["location"]["start"]["line"], f'{m["mutatorName"]} → {m.get("replacement", "")} ({m["status"]})')
        for path, body in report["files"].items() for m in body["mutants"]
        if m["status"] in ("Survived", "NoCoverage")
    ]


def gremlins_lived(report: dict) -> list[tuple[str, int, str]]:
    return [
        (f["file_name"], m["line"], f'{m["type"]} ({m["status"]})')
        for f in report["files"] for m in f["mutations"]
        if m["status"] in ("LIVED", "NOT COVERED")
    ]


def dart_lived(report: ET.Element) -> list[tuple[str, int, str]]:
    """mutation_test's xml report lists only the undetected mutations, per file."""
    return [
        (f.get("name", ""), int(m.get("line", 0)), f'{m.findtext("original", "").strip()} → {m.findtext("modified", "").strip()}')
        for f in report.iter("file") for m in f.iter("mutation")
    ]


DART_FOUND = re.compile(r"Found (\d+) mutations")


def judge(repo: Path, what: str, total: int, lived: list[tuple[str, int, str]], verdict: Verdict) -> None:
    left = [f"{p}:{n}: {d}" for p, n, d in lived if not accepted(repo, p, n)]
    return report_mutation(what, total, left, verdict, len(lived) - len(left))


def ranges(change: Change) -> list[str]:
    """Stryker's file:start-end ranges for the changed lines, one per run of consecutive lines."""
    out, lines = [], sorted(change.lines)
    start = prev = lines[0]
    for n in lines[1:] + [None]:
        if n != prev + 1:
            out.append(f"{change.path}:{start}-{prev}")
            start = n
        prev = n if n is not None else prev
    return out


def symlinked_dirs(repo: Path) -> list[str]:
    """Each link to a folder under the repo, which Stryker's sandbox copy cannot copy."""
    found = []
    for root, dirs, _ in os.walk(repo):
        dirs[:] = [d for d in dirs if d not in COPY_SKIP]
        found += [str((Path(root) / d).relative_to(repo)) for d in dirs if (Path(root) / d).is_symlink()]
    return sorted(found)


def mutate_js(repo: Path, files: list[Change], command: list[str], verdict: Verdict) -> None:
    if missing("npx", verdict, "StrykerJS"):
        return None
    with tempfile.TemporaryDirectory() as tmp:
        config, out = Path(tmp) / "stryker.json", Path(tmp) / "report.json"
        config.write_text(json.dumps({
            "testRunner": "command", "commandRunner": {"command": shlex.join(command)},
            "reporters": ["json"], "jsonReporter": {"fileName": str(out)},
            "tempDirName": str(Path(tmp) / "sandbox"), "cleanTempDir": "always",
            "ignorePatterns": sorted(COPY_SKIP) + symlinked_dirs(repo),
            "mutate": [r for c in files for r in ranges(c)],
        }))
        inside = f"cd {shlex.quote(str(repo))} && stryker run {shlex.quote(str(config))}"
        env = {**os.environ, **TURBO_MUTATION_ENV}
        run = subprocess.run([*STRYKER, inside], cwd=tmp, env=env, capture_output=True, text=True)
        if not out.exists():
            return verdict.fail(f"StrykerJS exited {run.returncode} with no report", *run.stdout.splitlines()[-8:])
        report = json.loads(out.read_text())
        total = sum(len(b["mutants"]) for b in report["files"].values())
        return judge(repo, "js/ts", total, stryker_lived(report), verdict)


def mutate_go(repo: Path, base: str, verdict: Verdict) -> None:
    if missing("gremlins", verdict, "gremlins"):
        return None
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "gremlins.json"
        run = subprocess.run([find_tool("gremlins"), "unleash", "--diff", base, "-o", str(out), "."],
                             cwd=repo, capture_output=True, text=True)
        if not out.exists():
            return verdict.fail(f"gremlins exited {run.returncode} with no report", *run.stdout.splitlines()[-8:])
        report = json.loads(out.read_text())
        total = report["mutants_killed"] + report["mutants_lived"] + report["mutants_not_covered"]
        return judge(repo, "go", total, gremlins_lived(report), verdict)


def dart_config(files: list[Change], command: list[str]) -> str:
    entries = "".join(
        f'<file>{c.path}' + "".join(f'<lines begin="{n}" end="{n}"/>' for n in sorted(c.lines)) + "</file>"
        for c in files
    )
    test = escape(shlex.join(command))
    return (f'<?xml version="1.0" encoding="UTF-8"?><mutations version="1.1"><files>{entries}</files>'
            f'<commands><command group="test" expected-return="0" working-directory=".">{test}</command></commands>'
            f'<threshold failure="100"></threshold></mutations>')


def dart_default(repo: Path) -> list[str]:
    return ["flutter", "test"] if "flutter:" in (repo / "pubspec.yaml").read_text(errors="replace") else ["dart", "test"]


def mutate_dart(repo: Path, files: list[Change], command: list[str], verdict: Verdict) -> None:
    if missing("dart", verdict, "mutation_test"):
        return None
    runner = command or dart_default(repo)
    with tempfile.TemporaryDirectory() as tmp:
        work = copy_tree(repo, Path(tmp) / "w")
        (work / "change_gate.xml").write_text(dart_config(files, runner))
        out = Path(tmp) / "report"
        run = subprocess.run(["dart", "pub", "global", "run", "mutation_test", "change_gate.xml", "-f", "xml", "-o", str(out)],
                             cwd=work, capture_output=True, text=True)
        reports = list(out.glob("*.xml"))
        if not reports:
            return verdict.fail(f"mutation_test exited {run.returncode} with no report", *run.stdout.splitlines()[-8:])
        root = ET.parse(reports[0]).getroot()
        total = int(m[1]) if (m := DART_FOUND.search(run.stdout)) else 0
        return judge(repo, "dart", total, dart_lived(root), verdict)


FAKE_NPX = """#!/usr/bin/env python3
import json, os, pathlib, shlex, shutil, sys
if os.environ.get("FAKE_BROKEN"):
    print("stryker broke")
    sys.exit(3)
here = pathlib.Path(__file__)
turbo = {k: os.environ.get(k) for k in ("TURBO_ENV_MODE", "TURBO_FORCE")}
here.with_name("npx.json").write_text(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(), "turbo": turbo}))
path = shlex.split(sys.argv[-1])[-1]
config = json.loads(pathlib.Path(path).read_text())
shutil.copy(path, here.with_name("stryker.json"))
mutants = [{"status": "Survived", "mutatorName": "EqualityOperator", "replacement": "a >= b", "location": {"start": {"line": 1}}},
           {"status": "Killed", "mutatorName": "BlockStatement", "replacement": "{}", "location": {"start": {"line": 1}}}]
pathlib.Path(config["jsonReporter"]["fileName"]).write_text(json.dumps({"files": {"a.js": {"mutants": mutants}}}))
"""


FAKE_GREMLINS = """#!/usr/bin/env python3
import json, os, pathlib, sys
if os.environ.get("FAKE_BROKEN"):
    print("gremlins broke")
    sys.exit(4)
pathlib.Path(__file__).with_name("gremlins.args").write_text(" ".join(sys.argv[1:]))
report = {"files": [{"file_name": "b.go", "mutations": [{"type": "CONDITIONALS_BOUNDARY", "status": "LIVED", "line": 1}]}],
          "mutants_killed": 1, "mutants_lived": 1, "mutants_not_covered": 0}
pathlib.Path(sys.argv[sys.argv.index("-o") + 1]).write_text(json.dumps(report))
"""


FAKE_DART = """#!/usr/bin/env python3
import pathlib, shutil, sys
shutil.copy("change_gate.xml", pathlib.Path(__file__).with_name("dart.xml"))
out = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
out.mkdir(parents=True)
(out / "r.xml").write_text('<undetected-mutations><file name="lib/d.dart"><mutation line="1"><original>a &gt; b</original>'
                           '<modified>a &gt;= b</modified></mutation></file></undetected-mutations>')
print("Found 2 mutations in 1 source files!")
"""


FAKE_UVX = """#!/bin/sh
[ -n "$FAKE_UVX_FAIL" ] && { echo "lizard broke" >&2; exit 1; }
printf '%s\\n' "$FAKE_UVX_CSV"
"""


def self_test_fakes(folder: Path) -> Path:
    folder.mkdir()
    for name, body in (("npx", FAKE_NPX), ("gremlins", FAKE_GREMLINS), ("dart", FAKE_DART), ("uvx", FAKE_UVX)):
        (folder / name).write_text(body)
        (folder / name).chmod(0o755)
    return folder


def self_test_tools(t: Tap) -> None:
    from change_gate_complexity import self_test_complexity
    with tempfile.TemporaryDirectory() as tmp:
        repo, fakes = self_test_repo(Path(tmp)), self_test_fakes(Path(tmp) / "fakes")
        with self_test_env(PATH=f"{fakes}:{os.environ['PATH']}"):
            self_test_js(t, repo, fakes)
            self_test_go_dart(t, repo, fakes)
            self_test_complexity(t, repo)


def self_test_js_command(t: Tap, repo: Path) -> None:
    for package in (None, "[]", "{", '{"scripts": {"build": "x"}}', '{"scripts": ["test"]}'):
        self_test_files(repo, {"a.js": "if (a > b) x()\n"} | ({"package.json": package} if package else {}))
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "js: no --test js=<command> for a.js" in out and "no test script for `npm test`" in out,
                f"with no --test js and package.json {package or 'missing'}, the gate fails naming the flag", out)


def self_test_js(t: Tap, repo: Path, fakes: Path) -> None:
    self_test_js_command(t, repo)
    self_test_files(repo, {"a.js": "if (a > b) x()\n", "package.json": '{"scripts": {"test": "node --test"}}'})
    status, out = self_test_run(repo, "--check", "mutation")
    t.check(status == 1 and "a.js:1: EqualityOperator → a >= b (Survived)" in out, "a StrykerJS survivor fails the gate", out)
    config = json.loads((fakes / "stryker.json").read_text())
    t.check(config["mutate"] == ["a.js:1-1"] and config["commandRunner"]["command"] == "npm test",
            "Stryker mutates only the changed lines, testing with npm test by default", str(config))
    t.check(".venv" in config["ignorePatterns"] and ".git" in config["ignorePatterns"],
            "Stryker leaves out of its sandbox the folders the gate's own copy leaves out", str(config))
    npx = json.loads((fakes / "npx.json").read_text())
    t.check("typescript@5.5.4" in npx["argv"] and not Path(npx["cwd"]).is_relative_to(repo),
            "npx installs typescript beside Stryker, run from outside the repo", str(npx))
    t.check(npx["argv"][-1].startswith(f"cd {shlex.quote(str(repo))} && stryker run "),
            "Stryker itself runs in the repo", str(npx))
    t.check(npx["turbo"] == TURBO_MUTATION_ENV,
            "Stryker runs with turbo in loose env mode and forced, so a turbo test sees each mutant", str(npx))
    (repo / "logs").symlink_to(fakes, target_is_directory=True)
    (repo / "node_modules").mkdir(exist_ok=True)
    (repo / "node_modules" / "linked").symlink_to(fakes, target_is_directory=True)
    self_test_run(repo, "--check", "mutation")
    config = json.loads((fakes / "stryker.json").read_text())
    t.check("logs" in config["ignorePatterns"] and "node_modules/linked" not in config["ignorePatterns"],
            "a linked folder is left out of Stryker's sandbox, one under a skipped folder is not looked for", str(config))
    (repo / "logs").unlink()
    self_test_run(repo, "--check", "mutation", "--test", "js=yarn test --ci")
    config = json.loads((fakes / "stryker.json").read_text())
    t.check(config["commandRunner"]["command"] == "yarn test --ci", "Stryker tests with the --test js command", str(config))
    self_test_files(repo, {"a.js": "if (a > b) x() // mutation: equivalent — x is idempotent\n", "package.json": '{"scripts": {"test": "t"}}'})
    status, out = self_test_run(repo, "--check", "mutation")
    t.check(status == 0 and "1 marked equivalent" in out, "a survivor on a line marked equivalent is accepted and counted apart", out)


def self_test_go_dart(t: Tap, repo: Path, fakes: Path) -> None:
    self_test_files(repo, {"b.go": "package b\n"})
    status, out = self_test_run(repo, "--check", "mutation")
    t.check(status == 1 and "b.go:1: CONDITIONALS_BOUNDARY (LIVED)" in out, "a gremlins survivor fails the gate", out)
    head = git(repo, "rev-parse", "HEAD").strip()
    t.check((fakes / "gremlins.args").read_text().startswith(f"unleash --diff {head} -o"), "gremlins diffs against the base")
    self_test_files(repo, {"lib/d.dart": "bool f(a, b) => a > b;\n", "pubspec.yaml": "name: d\n"})
    status, out = self_test_run(repo, "--check", "mutation")
    t.check(status == 1 and "dart: 1 of 2 mutants lived" in out and "lib/d.dart:1:" in out, "a mutation_test survivor fails the gate", out)
    self_test_files(repo, {"a.js": "x()\n", "b.go": "package b\n", "package.json": '{"scripts": {"test": "t"}}'})
    with self_test_env(FAKE_BROKEN="1"):
        status, out = self_test_run(repo, "--check", "mutation")
    t.check(status == 1 and "StrykerJS exited 3 with no report\n        stryker broke\n" in out
            and "gremlins exited 4 with no report\n        gremlins broke\n" in out,
            "a tool that writes no report fails the gate, showing what it printed", out)
    config = (fakes / "dart.xml").read_text()
    t.check('<lines begin="1" end="1"/>' in config and ">dart test<" in config, "mutation_test gets the changed lines and dart test", config)
    self_test_files(repo, {"lib/d.dart": "bool f(a, b) => a > b;\n", "pubspec.yaml": "name: d\n"})
    self_test_run(repo, "--check", "mutation", "--test", "dart=sh -c 'a && b'")
    config = (fakes / "dart.xml").read_text()
    t.check(">sh -c 'a &amp;&amp; b'<" in config,
            "mutation_test gets the --test dart command, escaped for its XML", config)

def self_test() -> int:
    from change_gate import self_test as whole

    return whole()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
