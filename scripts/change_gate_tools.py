#!/usr/bin/env python3
"""change_gate_tools.py — change_gate.py's mutation through the tools that mutate for us: Stryker, go-gremlins, Dart's mutation_test and cargo-mutants.

Imported, never run; ``python3 change_gate_tools.py --self-test`` runs change_gate's whole
suite: the parts are one tool, and the cases that pin one part sit beside another.
"""

import contextlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402
from change_gate_base import COPY_SKIP, Change, EQUIVALENT, STRYKER, Verdict, change_diff, find_tool, git, missing, self_test_env, self_test_files, self_test_repo, self_test_run  # noqa: E402
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


CARGO_MUTANT = re.compile(r"^(?P<path>[^:\n]+):(?P<line>\d+):\d+: (?P<what>.+)$")


# cargo-mutants exits 2 when a mutant was missed and 3 when one timed out; both still write the report.
CARGO_JUDGED = (0, 2, 3)


def cargo_lived(out: Path) -> list[tuple[str, int, str]]:
    """cargo-mutants lists each missed and each timed-out mutant as path:line:column: what it replaced."""
    return [
        (m["path"], int(m["line"]), f'{m["what"]} ({kind})')
        for name, kind in (("missed.txt", "missed"), ("timeout.txt", "timeout"))
        for m in map(CARGO_MUTANT.match, line_text(out / name)) if m
    ]


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


class NoWorkspace(Exception):
    """A changed Rust file whose workspace cargo cannot name inside the repo; its args are the verdict's lines."""


def cargo_test_args(command: list[str]) -> list[str] | None:
    """cargo-mutants' arguments for a `cargo test …` command: each option before `--` goes to
    every cargo call, so the build and the tests agree, and what follows `--` to the test
    binaries. None for a command that is not `cargo test`."""
    if not command:
        return []
    if command[:2] != ["cargo", "test"]:
        return None
    rest = command[2:]
    split = rest.index("--") if "--" in rest else len(rest)
    return [f"--cargo-arg={a}" for a in rest[:split]] + rest[split:]


def cargo_root(repo: Path, change: Change, cargo: str, env: dict[str, str]) -> str:
    """The folder of the workspace a changed file builds in, from the repo, as cargo itself finds it."""
    run = subprocess.run([cargo, "locate-project", "--workspace", "--message-format", "plain"],
                         cwd=(repo / change.path).parent, env=env, capture_output=True, text=True)
    if run.returncode:
        raise NoWorkspace(f"rust: cargo locate-project failed for {change.path}", *run.stderr.splitlines()[-3:])
    root, here = Path(run.stdout.strip()).parent, repo.resolve()
    if not root.is_relative_to(here):
        raise NoWorkspace(f"rust: the workspace of {change.path} is {root}, outside the repo")
    return root.relative_to(here).as_posix()


def mutate_rust(repo: Path, base: str, files: list[Change], command: list[str], verdict: Verdict) -> None:
    """cargo-mutants once per workspace the changed files build in, each over its own part of the diff."""
    if missing("cargo-mutants", verdict, "cargo-mutants") or missing("cargo", verdict, "cargo locate-project"):
        return None
    args = cargo_test_args(command)
    if args is None:
        return verdict.fail(f"rust: --test rust takes a `cargo test …` command, not `{shlex.join(command)}`")
    tool, cargo = Path(find_tool("cargo-mutants")), find_tool("cargo")
    env = {**os.environ, "PATH": f"{tool.parent}{os.pathsep}{os.environ['PATH']}"}
    try:
        roots = {c.path: cargo_root(repo, c, cargo, env) for c in files}
    except NoWorkspace as no:
        return verdict.fail(*no.args)
    if clash := [p for p, r in roots.items() if PurePosixPath(p).relative_to(r).parts[0] == "b"]:
        return verdict.fail(f"rust: cargo-mutants reads git's b/ prefix and a folder named b off {', '.join(clash)} alike,"
                            " so it would mutate none of it", "fix: rename that folder under the workspace")
    for root in sorted(set(roots.values())):
        mutate_workspace(repo, base, root, (tool, args, env), verdict)
    return None


def mutate_workspace(repo: Path, base: str, root: str, runner: tuple[Path, list[str], dict[str, str]], verdict: Verdict) -> None:
    """cargo-mutants in one workspace, every package of it, on its own copy of the tree; with no
    --workspace, a workspace whose root is itself a package has only that package mutated. A
    diff that reaches no function makes no mutant, and cargo-mutants then writes no report."""
    (tool, args, env), what = runner, "rust" if root == "." else f"rust ({root})"
    with tempfile.TemporaryDirectory() as tmp:
        diff, out = Path(tmp) / "change.diff", Path(tmp) / "mutants.out"
        diff.write_text(change_diff(repo, base, root))
        run = subprocess.run([str(tool), "mutants", "--workspace", "--in-diff", str(diff), "-o", tmp, *args],
                             cwd=repo / root, env=env, capture_output=True, text=True)
        said = (run.stdout + run.stderr).splitlines()[-8:]
        if run.returncode not in CARGO_JUDGED or (run.returncode and not out.exists()):
            return verdict.fail(f"{what}: cargo-mutants exited {run.returncode}", *said)
        if not out.exists():
            return report_mutation(what, 0, [], verdict)
        total = json.loads((out / "outcomes.json").read_text())["total_mutants"]
        lived = [((Path(root) / p).as_posix(), n, d) for p, n, d in cargo_lived(out)]
        return judge(repo, what, total, lived, verdict)


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


FAKE_CARGO_MUTANTS = """#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
mode, here = os.environ.get("FAKE_CARGO", ""), pathlib.Path(__file__)
here.with_name("cargo.args").write_text(" ".join(sys.argv[1:]))
here.with_name("cargo.cwd").write_text(os.getcwd())
shutil.copy(sys.argv[sys.argv.index("--in-diff") + 1], here.with_name("cargo.diff"))
if mode == "none":
    sys.exit(0)
if mode == "noreport":
    sys.exit(2)
out = pathlib.Path(sys.argv[sys.argv.index("-o") + 1]) / "mutants.out"
out.mkdir()
(out / "missed.txt").write_text("src/lib.rs:1:30: replace > with >= in f\\n")
(out / "timeout.txt").write_text("src/lib.rs:1:30: replace > with < in f\\n")
(out / "outcomes.json").write_text(json.dumps({"total_mutants": 3, "missed": 1, "caught": 1, "timeout": 1}))
if mode == "broken":
    print("cargo-mutants broke")
    sys.exit(4)
sys.exit(2)
"""


# cargo locate-project --workspace: the nearest Cargo.toml above the folder, or a
# [workspace] one above that, which is enough of cargo's own walk for the cases.
FAKE_CARGO = """#!/usr/bin/env python3
import os, pathlib, sys
if os.environ.get("FAKE_CARGO") == "nolocate":
    print("error: could not find `Cargo.toml`", file=sys.stderr)
    sys.exit(101)
found = None
for folder in [pathlib.Path.cwd(), *pathlib.Path.cwd().parents]:
    manifest = folder / "Cargo.toml"
    if manifest.is_file() and (found is None or "[workspace]" in manifest.read_text()):
        found = manifest
print(found or "")
sys.exit(0 if found else 101)
"""


FAKE_UVX = """#!/bin/sh
[ -n "$FAKE_UVX_FAIL" ] && { echo "lizard broke" >&2; exit 1; }
printf '%s\\n' "$FAKE_UVX_CSV"
"""


def self_test_fakes(folder: Path) -> Path:
    folder.mkdir()
    fakes = (("npx", FAKE_NPX), ("gremlins", FAKE_GREMLINS), ("dart", FAKE_DART), ("cargo-mutants", FAKE_CARGO_MUTANTS),
             ("cargo", FAKE_CARGO), ("uvx", FAKE_UVX))
    for name, body in fakes:
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
            self_test_rust(t, repo, fakes)
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


RUST_LINE = "pub fn f(a: i32) -> bool { a > 1 }\n"


def self_test_rust_run(repo: Path, files: dict[str, str], mode: str = "", *flags: str) -> tuple[int, str]:
    self_test_files(repo, files)
    with self_test_env(FAKE_CARGO=mode):
        return self_test_run(repo, "--check", "mutation", *flags)


def self_test_rust(t: Tap, repo: Path, fakes: Path) -> None:
    crate = {"src/lib.rs": RUST_LINE, "Cargo.toml": "[package]\n"}
    status, out = self_test_rust_run(repo, crate)
    t.check(status == 1 and "rust: 2 of 3 mutants lived" in out and "src/lib.rs:1: replace > with >= in f (missed)" in out
            and "src/lib.rs:1: replace > with < in f (timeout)" in out, "a missed and a timed-out cargo-mutants mutant fail the gate", out)
    args = (fakes / "cargo.args").read_text()
    t.check(args.startswith("mutants --workspace --in-diff ") and " -o " in args and "cargo-arg" not in args,
            "cargo-mutants mutates the diff in every package, writing outside the repo, with no cargo arguments of its own", args)
    diff = (fakes / "cargo.diff").read_text()
    t.check("+++ b/src/lib.rs" in diff and "@@ -0,0 +1 @@" in diff,
            "cargo-mutants gets the change's diff, an untracked file and only its changed lines included", diff)
    marked = RUST_LINE.replace("}\n", "} // mutation: equivalent — a is never 1\n")
    status, out = self_test_rust_run(repo, crate | {"src/lib.rs": marked})
    t.check(status == 0 and "rust: 3 mutants, 1 killed, 2 marked equivalent" in out, "a cargo-mutants survivor on a line marked equivalent is accepted", out)
    self_test_rust_workspaces(t, repo, fakes)
    self_test_rust_command(t, repo, fakes, crate)
    self_test_rust_exits(t, repo, crate)
    self_test_rust_alone(t, repo, fakes, crate)


def self_test_rust_workspaces(t: Tap, repo: Path, fakes: Path) -> None:
    files = {"sub/src/lib.rs": RUST_LINE, "sub/Cargo.toml": "[package]\n", "README": "y\n"}
    status, out = self_test_rust_run(repo, files)
    t.check(status == 1 and "rust (sub): 2 of 3 mutants lived" in out and "sub/src/lib.rs:1: replace > with >= in f" in out,
            "a crate below the repo root is mutated where it is, its survivors named from the root", out)
    diff = (fakes / "cargo.diff").read_text()
    t.check(Path((fakes / "cargo.cwd").read_text()) == (repo / "sub").resolve() and "+++ b/src/lib.rs" in diff and "README" not in diff,
            "cargo-mutants runs in the crate's folder, on the diff of its files alone, named from there", diff)
    ws = {"ws/Cargo.toml": "[workspace]\n", "ws/a/Cargo.toml": "[package]\n", "ws/a/src/lib.rs": RUST_LINE}
    status, out = self_test_rust_run(repo, ws | {"ws/c/Cargo.toml": "[package]\n", "ws/c/src/lib.rs": RUST_LINE})
    t.check(out.count("rust (ws): 2 of 3 mutants lived") == 1 and "+++ b/a/src/lib.rs" in (fakes / "cargo.diff").read_text(),
            "two members of one workspace are mutated once, at the workspace", out)
    status, out = self_test_rust_run(repo, ws | {"ws/b/Cargo.toml": "[package]\n", "ws/b/src/lib.rs": RUST_LINE})
    t.check(status == 1 and "a folder named b off ws/b/src/lib.rs alike" in out,
            "a changed file in a folder named b under its workspace fails the gate, cargo-mutants would skip it", out)
    (repo.parent / "Cargo.toml").write_text("[workspace]\n")
    status, out = self_test_rust_run(repo, {"src/lib.rs": RUST_LINE})
    (repo.parent / "Cargo.toml").unlink()
    t.check(status == 1 and "rust: the workspace of src/lib.rs is" in out and "outside the repo" in out,
            "a Rust file whose workspace is outside the repo fails the gate", out)


def self_test_rust_command(t: Tap, repo: Path, fakes: Path, crate: dict[str, str]) -> None:
    self_test_rust_run(repo, crate, "", "--test", "rust=cargo test --locked --all-features -- --test-threads=1")
    args = (fakes / "cargo.args").read_text()
    t.check(args.endswith(" --cargo-arg=--locked --cargo-arg=--all-features -- --test-threads=1"),
            "a --test rust command's options reach every cargo call, and what follows -- the test binaries", args)
    self_test_rust_run(repo, crate, "", "--test", "rust=cargo test --locked")
    args = (fakes / "cargo.args").read_text()
    t.check(args.endswith(" --cargo-arg=--locked"), "a --test rust command with no -- passes only cargo options", args)
    status, out = self_test_rust_run(repo, crate, "", "--test", "rust=make test")
    t.check(status == 1 and "rust: --test rust takes a `cargo test …` command, not `make test`" in out,
            "a --test rust command that is not cargo test fails the gate", out)


def self_test_rust_alone(t: Tap, repo: Path, fakes: Path, crate: dict[str, str]) -> None:
    """cargo-mutants on a PATH that holds nothing else the gate could call, under a HOME with no bin folders."""
    alone = fakes.parent / "alone"
    alone.mkdir()
    (alone / "cargo-mutants").symlink_to(fakes / "cargo-mutants")
    for tool in ("git", "python3"):
        (alone / tool).symlink_to(shutil.which(tool))
    with self_test_env(PATH=str(alone), HOME=str(alone)):
        status, out = self_test_rust_run(repo, crate)
    t.check(status == 1 and "cargo is not installed, so cargo locate-project did not run" in out,
            "cargo-mutants with no cargo beside it fails the gate, naming the fix", out)


def self_test_rust_exits(t: Tap, repo: Path, crate: dict[str, str]) -> None:
    status, out = self_test_rust_run(repo, crate, "none")
    t.check(status == 0 and "rust: 0 mutants, 0 killed" in out, "a diff cargo-mutants makes no mutant of passes with none", out)
    status, out = self_test_rust_run(repo, crate, "noreport")
    t.check(status == 1 and "rust: cargo-mutants exited 2" in out, "a cargo-mutants that says a mutant lived but writes no report fails the gate", out)
    status, out = self_test_rust_run(repo, crate, "broken")
    t.check(status == 1 and "rust: cargo-mutants exited 4\n        cargo-mutants broke\n" in out,
            "a cargo-mutants whose unmutated tests fail fails the gate, showing what it printed", out)
    status, out = self_test_rust_run(repo, crate, "nolocate")
    t.check(status == 1 and "rust: cargo locate-project failed for src/lib.rs\n        error: could not find `Cargo.toml`" in out,
            "a Rust file cargo finds no workspace for fails the gate, showing what cargo said", out)

def self_test() -> int:
    from change_gate import self_test as whole

    return whole()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
