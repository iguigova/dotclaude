#!/usr/bin/python3
"""change_gate.py — the checks coding_guidelines.md → Verification adds to CI,
on the code a change touched.

  complexity  no function in a changed file has a cyclomatic complexity above
              10, as lizard counts it: Python, JavaScript, TypeScript, Go, Ruby,
              C# and Dart. Shell, Clojure and Haskell have no counter and are
              not measured.
  mutation    every mutant on a changed line is killed by the tests, unless
              that line's comment carries `mutation: equivalent — <reason>`,
              the reason saying why no test can tell the mutant apart.

Mutation runs per kind of file:

  self-tested script  a .sh or .py that offers --self-test (a .sh that offers
                      none fails, having no test): this script's
                      mutator, run against the script's own --self-test, which
                      passes only by exiting 0 with a TAP plan and no failed
                      case. Its test code, a self_test function or an
                      `if … --self-test …; then` block, is not mutated.
  Python              this script's mutator. The --test python command, else
                      `<repo>/.venv/bin/python -m pytest`, else `python3 -m
                      pytest`, runs once with per-test coverage (it needs
                      pytest-cov); each mutant then runs, through -k, only the
                      tests whose coverage ran its line, or the whole command
                      for a line run only at import. --coverage names a
                      coverage file a run with --cov-context=test already
                      wrote, such as CI's own: the gate reads it instead of
                      running the suite again, and reruns only the tests
                      covering the changed lines, once, unmutated, to check
                      the copy and time the mutants. The src/ above each
                      changed file, the copy's src/ and its root lead
                      PYTHONPATH, ahead of an editable install.
  Ruby, Clojure,      this script's mutator, running the --test command for
  Haskell             the language for each mutant; with none, it fails.
  JavaScript, TS      StrykerJS over the changed line ranges, testing with the
                      --test js command, else `npm test`
  Go                  gremlins --diff, testing with `go test`
  Dart                mutation_test over the changed lines, testing with the
                      --test dart command, else `flutter test` in a Flutter
                      package and `dart test` otherwise
  C#                  no runner yet: a changed C# file fails the gate

This script's mutator swaps comparison, boolean and test operators (< and <=,
== and != or /=, and/or, &&/||, -gt/-le, True/False, if/unless, Clojure's
(if/(if-not and (inc/(dec, and the like) in the code part of a changed line,
never inside a string or a comment. A mutant on a
line marked equivalent is not run, and every verdict counts those apart.

A test command is given per language, `--test <language>=<command>`, the
command split as the shell splits it; a repository passes the commands its CI
runs. When the unmutated tests fail, the gate fails and shows the end of their
output. A tool that is not installed fails the gate, naming the command that
installs it. The gate runs on /usr/bin/python3, never a repo's own Python,
since it runs inside repos whose pyenv pins an older one. Mutation never edits the checkout: the mutator works on a copy, and each
tool works in its own sandbox.

"Changed" runs from the merge-base of HEAD with --base, by default origin's
default branch, or HEAD in a repo with no origin, to the working tree,
untracked files included. Test files are not mutated; complexity counts them
like any other file.

Usage:
  change_gate.py [--base REF] [--check complexity|mutation] [--test <language>=<command>]…
                 [--coverage <coverage file>] [<repo>]
  change_gate.py --self-test

Exit:
  0  every check passed
  1  a check failed (each prints FAIL)
  2  usage error, or not a git repo
"""

import contextlib
import csv
import dataclasses
import io
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import tokenize
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from tap import Tap  # noqa: E402

LIZARD = ["uvx", "lizard==1.26.0"]
STRYKER = ["npx", "-y", "-p", "@stryker-mutator/core@10.1.1", "stryker", "run"]
GO_BIN = Path.home() / "go/bin"
MAX_CCN = 10
EQUIVALENT = re.compile(r"mutation: equivalent\s*[—-]+\s*\S")
INSTALL = {
    "uvx": "curl -LsSf https://astral.sh/uv/install.sh | sh",
    "npx": "nvm install --lts",
    "gremlins": "go install github.com/go-gremlins/gremlins/cmd/gremlins@latest",
    "dart": "a Dart or Flutter SDK on PATH, then: dart pub global activate mutation_test",
}
LANGUAGES = {
    ".py": "python", ".sh": "shell", ".rb": "ruby", ".go": "go", ".dart": "dart",
    ".cs": "csharp", ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js",
    ".ts": "js", ".tsx": "js", ".clj": "clojure", ".cljs": "clojure", ".cljc": "clojure", ".hs": "haskell",
}
MEASURED = {"python", "ruby", "go", "dart", "csharp", "js"}
TEST_FILE = re.compile(
    r"(^|/)(tests?|spec|__tests__|test_driver)/|(^|/)test_[^/]*\.py$|_test\.(py|go|dart)$"
    r"|_spec\.rb$|\.(test|spec)\.[cm]?[jt]sx?$|Tests?\.cs$|_test\.clj[cs]?$|Spec\.hs$"
)
COPY_SKIP = {".git", "node_modules", "tmp", "log", ".venv", "mutants", ".stryker-tmp"}


# ---------------------------------------------------------------- changed code

@dataclasses.dataclass(frozen=True)  # mutation: equivalent — nothing assigns to a Change, so frozen only states it
class Change:
    path: str
    lines: frozenset[int]

    @property
    def language(self) -> str:
        return LANGUAGES.get(Path(self.path).suffix, "")


def git(repo: Path, *args: str, check: bool = True) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=check).stdout


def default_base(repo: Path) -> str:
    """origin's default branch, or HEAD in a repo with no origin."""
    return git(repo, "symbolic-ref", "-q", "refs/remotes/origin/HEAD", check=False).strip() or "HEAD"


HUNK = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@")


def added_lines(diff: str) -> dict[str, set[int]]:
    """The new-side line numbers each file's diff adds or changes."""
    out: dict[str, set[int]] = {}
    path = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = None if line == "+++ /dev/null" else line[6:]
        elif (m := HUNK.match(line)) and path:
            start, count = int(m[1]), int(m[2] or 1)
            out.setdefault(path, set()).update(range(start, start + count))
    return {p: s for p, s in out.items() if s}


def changes(repo: Path, base: str) -> list[Change]:
    found = added_lines(git(repo, "diff", "-U0", "--no-color", "--no-renames", base))
    for path in git(repo, "ls-files", "--others", "--exclude-standard").splitlines():
        found[path] = set(range(1, line_count(repo / path) + 1))
    return [Change(p, frozenset(s)) for p, s in sorted(found.items()) if (repo / p).is_file()]


def line_count(path: Path) -> int:
    with contextlib.suppress(OSError, UnicodeDecodeError):
        return len(path.read_text().splitlines())
    return 0


def runner(path: Path) -> str:
    """What runs a script, as selftest.sh's sweep runs it: python3 for a .py or a python shebang, else bash."""
    with path.open(errors="replace") as f:
        first = f.readline()
    return "python3" if path.suffix == ".py" or "python" in first else "bash"


def is_self_tested(path: Path) -> bool:
    return path.suffix in (".sh", ".py") and "--self-test" in path.read_text(errors="replace")


# ---------------------------------------------------------------- verdicts

class Verdict:
    def __init__(self):
        self.failed = 0

    def fail(self, what: str, *detail: str) -> None:
        self.failed += 1
        print(f"   FAIL {what}")
        for line in detail:
            print(f"        {line}")

    def ok(self, what: str) -> None:
        print(f"   ok   {what}")


def find_tool(name: str) -> str | None:
    """The tool on PATH, or in Go's bin folder, where `go install` puts it."""
    return shutil.which(name) or shutil.which(name, path=str(GO_BIN))


def missing(tool: str, verdict: Verdict, what: str) -> bool:
    if find_tool(tool):
        return False
    verdict.fail(f"{tool} is not installed, so {what} did not run", f"fix: {INSTALL.get(tool, 'install ' + tool)}")
    return True


# ---------------------------------------------------------------- complexity

def over_limit(csv_text: str) -> list[str]:
    """lizard --csv rows whose CCN is above the cap, as file:line name (CCN n). A row's long name
    holds commas inside quotes, so the rows are read as CSV, never split on commas."""
    rows = [r for r in csv.reader(io.StringIO(csv_text)) if r]
    return [f"{r[6]}:{r[9]} {r[7]} (CCN {r[1]})" for r in rows if int(r[1]) > MAX_CCN]


def check_complexity(repo: Path, files: list[Change], verdict: Verdict) -> None:
    print(f"== complexity: no function above CCN {MAX_CCN}")
    measured = [c.path for c in files if c.language in MEASURED]
    if not measured:
        return verdict.ok("no changed file in a measured language")
    if missing("uvx", verdict, "the complexity check"):
        return None
    run = subprocess.run([*LIZARD, "--csv", *measured], cwd=repo, capture_output=True, text=True)
    if run.returncode != 0:
        return verdict.fail(f"lizard exited {run.returncode}", *run.stderr.splitlines()[-5:])
    over = over_limit(run.stdout)
    if over:
        return verdict.fail(f"{len(over)} functions above CCN {MAX_CCN}", *over)
    return verdict.ok(f"{len(measured)} files, every function at CCN {MAX_CCN} or under")


# ---------------------------------------------------------------- the mutator

@dataclasses.dataclass(frozen=True)  # mutation: equivalent — nothing assigns to a Mutant, so frozen only states it
class Mutant:
    path: str
    line: int
    before: str
    after: str

    def describe(self) -> str:
        return f"{self.path}:{self.line}: {self.before.strip()}  →  {self.after.strip()}"


def pair(a: str, b: str, left: str = "", right: str = "") -> list[tuple[re.Pattern, str]]:
    """a becomes b and b becomes a, each matched literally between the same left and right context."""
    return [(re.compile(left + re.escape(x) + right), y) for x, y in ((a, b), (b, a))]


def word(a: str, b: str) -> list[tuple[re.Pattern, str]]:
    return pair(a, b, r"\b", r"\b")


def flag(a: str, b: str) -> list[tuple[re.Pattern, str]]:
    """A test operator such as -gt, standing alone after whitespace."""
    return pair(a, b, r"(?<=\s)", r"\b")


LESS_EQ, MORE_EQ = re.compile(r"(?<![<>=!-])<=(?![<=>])"), re.compile(r"(?<![<>=!-])>=(?![<=>])")
LESS, MORE = re.compile(r"(?<![<>=!-])<(?![<=>-])"), re.compile(r"(?<![<>=!-])>(?![<=>])")
ORDER = [
    (LESS_EQ, "<"), (LESS_EQ, ">"), (MORE_EQ, ">"), (MORE_EQ, "<"),
    (LESS, "<="), (LESS, ">="), (MORE, ">="), (MORE, "<="),
]
COMPARE = [*ORDER, *pair("==", "!=", r"(?<![=!<>])", r"(?!=)")]
OPERATORS = {
    "shell": [
        *flag("-eq", "-ne"), *flag("-lt", "-ge"), *flag("-gt", "-le"), *flag("-lt", "-le"), *flag("-gt", "-ge"),
        *pair("-z", "-n", r"(?:(?<=\[ )|(?<=\[\[ ))", r"\b"),
        *pair("&&", "||"), *word("return 0", "return 1"), *word("true", "false"),
        *pair("==", "!=", r"(?<=\s)", r"(?=\s)"),
    ],
    "python": [
        *COMPARE, *word("and", "or"), *word("True", "False"), *pair("+ 1", "- 1", "", r"\b"),
        (re.compile(r"\bnot\s+(?!in\b)"), ""),
        (re.compile(r"\bis not\b"), "is"),
    ],
    "clojure": [
        *pair("<", "<=", r"(?<=\()", r"(?=\s)"), *pair(">", ">=", r"(?<=\()", r"(?=\s)"),
        *pair("<", ">=", r"(?<=\()", r"(?=\s)"), *pair(">", "<=", r"(?<=\()", r"(?=\s)"),
        *pair("=", "not=", r"(?<=\()", r"(?=\s)"), *pair("and", "or", r"(?<=\()", r"(?=\s)"),
        *pair("if", "if-not", r"(?<=\()", r"(?=\s)"), *pair("when", "when-not", r"(?<=\()", r"(?=\s)"),
        *pair("inc", "dec", r"(?<=\()", r"(?=\s)"), *word("true", "false"),
    ],
    "haskell": [
        *ORDER, *pair("==", "/="), *pair("&&", "||"),
        *word("True", "False"), *pair("+ 1", "- 1", "", r"\b"),
    ],
    "ruby": [
        *COMPARE, *pair("&&", "||"), *word("and", "or"), *word("true", "false"), *pair("+ 1", "- 1", "", r"\b"),
        *word("if", "unless"), *pair(".any?", ".none?"),
    ],
}
DOUBLE_QUOTED = r"\"(?:[^\"\\\n]|\\.)*\""
QUOTED = {
    "clojure": re.compile(DOUBLE_QUOTED), "haskell": re.compile(DOUBLE_QUOTED),
    "default": re.compile(r"'[^'\n]*'|" + DOUBLE_QUOTED),
}
COMMENT = {
    "shell": re.compile(r"(^|(?<=\s))#"), "clojure": re.compile(";"), "haskell": re.compile("--"),
    "default": re.compile("#"),
}


def code_part(line: str, language: str) -> str:
    """The line with quoted text blanked and any comment dropped, same length up to the comment.
    A quote is ' or " except in Clojure and Haskell, where ' is not one; a shell # opens a comment
    only where a word starts, so ${#a[@]} is code."""
    blanked = QUOTED.get(language, QUOTED["default"]).sub(lambda m: " " * len(m[0]), line)
    comment = COMMENT.get(language, COMMENT["default"]).search(blanked)
    return blanked[: comment.start()] if comment else blanked


PY_TEXT = {tokenize.STRING, tokenize.COMMENT} | {getattr(tokenize, n) for n in ("FSTRING_START", "FSTRING_MIDDLE", "FSTRING_END") if hasattr(tokenize, n)}


def blank(chars: list[list[str]], start: tuple[int, int], end: tuple[int, int]) -> None:
    for row in range(start[0], end[0] + 1):
        line = chars[row - 1]
        lo, hi = (start[1] if row == start[0] else 0), (end[1] if row == end[0] else len(line))
        line[lo:hi] = " " * (hi - lo)


def python_code(text: str) -> list[str]:
    """Each line with its strings and comments blanked, multi-line strings included, as the tokenizer
    sees them; a file it cannot tokenize falls back to code_part line by line."""
    chars = [list(line) for line in text.splitlines(keepends=True)]
    try:
        for token in tokenize.generate_tokens(io.StringIO(text).readline):
            if token.type in PY_TEXT:
                blank(chars, token.start, token.end)
    except (tokenize.TokenError, SyntaxError):
        return [code_part(line, "python") for line in text.splitlines(keepends=True)]
    return ["".join(c) for c in chars]


def line_mutants(path: str, number: int, line: str, language: str, code: str | None = None) -> list[Mutant]:
    if line.startswith("#!"):
        return []
    code = code_part(line, language) if code is None else code
    out = []
    for pattern, replacement in OPERATORS[language]:
        for m in pattern.finditer(code):
            out.append(Mutant(path, number, line, line[: m.start()] + replacement + line[m.end():]))
    return out


SHELL_TEST_START = re.compile(r"^(\s*)(self_test\s*\(\)\s*\{|if .*--self-test.*;\s*then\s*$)")
PY_TEST_DEF = re.compile(r"^(\s*)def _?self_test\w*\(")


def block_end(lines: list[str], start: int, indent: str, language: str) -> int:
    """The last line, 1-based, of the block opened at index start."""
    closer = re.compile(rf"^{indent}(fi\b|\}})") if language == "shell" else None
    if closer and re.search(r"(;\s*\}|\bfi)\s*$", lines[start]):
        return start + 1
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if closer and closer.match(line):
            return i + 1
        if not closer and line.strip() and len(line) - len(line.lstrip()) <= len(indent):
            return i
    return len(lines)


def test_region(lines: list[str], language: str) -> set[int]:
    """The lines of a self-tested script's own self-test, which mutation leaves alone: weakening
    an assertion is never caught by the assertion."""
    opener = SHELL_TEST_START if language == "shell" else PY_TEST_DEF
    region: set[int] = set()
    for i, line in enumerate(lines):
        if m := opener.match(line):
            region.update(range(i + 1, block_end(lines, i, m[1], language) + 1))
    return region


def mutants_of(repo: Path, change: Change, language: str, skip: frozenset[int] = frozenset()) -> list[Mutant]:
    text = (repo / change.path).read_text()
    lines = text.splitlines(keepends=True)
    code = python_code(text) if language == "python" else [code_part(line, language) for line in lines]
    return [
        m for n in sorted(change.lines - skip) if n <= len(lines)
        for m in line_mutants(change.path, n, lines[n - 1], language, code[n - 1])
    ]


def copy_tree(source: Path, target: Path) -> Path:
    """A copy to mutate; node_modules is linked, not copied, and the other skipped folders are left out."""
    def skip(folder: str, names: list[str]) -> list[str]:
        return [n for n in names if n in COPY_SKIP]
    shutil.copytree(source, target, ignore=skip, symlinks=True)  # mutation: equivalent — a link copied as its target reads the same
    if (source / "node_modules").is_dir():
        (target / "node_modules").symlink_to(source / "node_modules")
    return target


TAP_PLAN = re.compile(r"^1\.\.\d+$", re.M)


BASELINE_TAIL = 15


def run_tests(command: list[str], cwd: Path, timeout: float | None, tap: bool) -> tuple[bool, str]:
    """Whether the tests passed, and what they printed. They pass by exiting 0, and with tap also by
    printing a TAP plan and no failed case: a self-test that stopped printing has not passed."""
    try:
        run = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, f"timed out after {timeout:.0f}s"
    except OSError as e:
        return False, str(e)
    printed = run.stdout + run.stderr
    tap_held = bool(TAP_PLAN.search(run.stdout)) and "not ok" not in run.stdout
    return run.returncode == 0 and (not tap or tap_held), printed


def passes(command: list[str], cwd: Path, timeout: float, tap: bool) -> bool:
    return run_tests(command, cwd, timeout, tap)[0]


def timed(command: list[str], cwd: Path, tap: bool) -> tuple[float | None, list[str]]:
    """Seconds the unmutated tests took, or None when they fail before any mutation; and the end
    of what they printed, which says why when they fail. The unmutated run has no time limit: a
    suite takes as long as it takes, and each mutant's limit is set from it."""
    start = time.monotonic()
    held, printed = run_tests(command, cwd, None, tap)
    return (time.monotonic() - start if held else None), printed.splitlines()[-BASELINE_TAIL:]


def write_fresh(path: Path, text: str, stamp: int) -> None:
    """Write the file with an mtime no earlier write had: a compiled-code cache keyed by mtime and
    size, such as Python's .pyc or Ruby's bootsnap, would otherwise run the previous mutant when
    two of the same length land in one second."""
    path.write_text(text)
    os.utime(path, (stamp, stamp))


def survivors(work: Path, mutants: list[Mutant], tests_for, tap: bool) -> list[Mutant]:
    """The mutants whose tests still pass. tests_for(mutant) gives (command, timeout), or None when no test covers it."""
    lived, stamp = [], int(time.time())
    for mutant in (m for m in mutants if not EQUIVALENT.search(m.before)):
        target = work / mutant.path
        original = target.read_text()
        lines = original.splitlines(keepends=True)
        lines[mutant.line - 1] = mutant.after
        write_fresh(target, "".join(lines), stamp := stamp + 1)
        test = tests_for(mutant)
        if test is None or passes(test[0], work, test[1], tap):
            lived.append(mutant)
        write_fresh(target, original, stamp := stamp + 1)
    return lived


def mutation_verdict(what: str, found: list[Mutant], lived: list[Mutant], verdict: Verdict) -> None:
    """The mutator's verdict: its mutants on lines marked equivalent never ran, and are counted apart."""
    marked = sum(1 for m in found if EQUIVALENT.search(m.before))
    return report_mutation(what, len(found), [m.describe() for m in lived], verdict, marked)


def report_mutation(what: str, total: int, lived: list[str], verdict: Verdict, equivalent: int = 0) -> None:
    if lived:
        return verdict.fail(f"{what}: {len(lived)} of {total} mutants lived", *lived)
    marked = f", {equivalent} marked equivalent" if equivalent else ""
    return verdict.ok(f"{what}: {total} mutants, {total - equivalent} killed{marked}")


# ---------------------------------------------------------------- self-tested scripts, Ruby, Python

def mutate_self_tested(repo: Path, change: Change, verdict: Verdict) -> None:
    language = "shell" if change.path.endswith(".sh") else "python"
    with tempfile.TemporaryDirectory() as tmp:
        work = copy_tree((repo / change.path).parent, Path(tmp) / "w")
        name = Path(change.path).name
        command = [runner(work / name), f"./{name}", "--self-test"]
        took, tail = timed(command, work, tap=True)
        if took is None:
            return verdict.fail(f"{change.path}: its --self-test fails before any mutation", *tail)
        region = test_region((work / name).read_text().splitlines(), language)
        found = mutants_of(work, Change(name, change.lines), language, frozenset(region))
        lived = survivors(work, found, lambda _m: (command, took * 3 + 10), tap=True)
        return mutation_verdict(change.path, found, lived, verdict)


def mutate_with_command(repo: Path, files: list[Change], language: str, command: list[str], verdict: Verdict) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        work = copy_tree(repo, Path(tmp) / "w")
        took, tail = timed(command, work, tap=False)
        if took is None:
            return verdict.fail(f"{language}: `{shlex.join(command)}` fails before any mutation", *tail)
        found = [m for c in files for m in mutants_of(work, c, language)]
        lived = survivors(work, found, lambda _m: (command, took * 3 + 10), tap=False)
        return mutation_verdict(language, found, lived, verdict)


def venv_python(repo: Path) -> str:
    local = repo / ".venv/bin/python"
    return str(local) if local.exists() else "python3"


def covering_tests(db: Path, path: Path, relative: str) -> dict[int, list[str]]:
    """Per line, the pytest node ids whose run executed it, from a coverage file with test contexts.
    A line run only while the tests were collected, such as a decorator or a module constant, has
    an empty list: every test imported it, so every test can kill its mutant. A file is found by
    its absolute path, or by its path in the repo when the coverage run kept relative_files."""
    from coverage.numbits import numbits_to_nums  # noqa: PLC0415 — only the Python runner needs coverage
    out: dict[int, list[str]] = {}
    query = (
        "select c.context, lb.numbits from line_bits lb join file f on f.id = lb.file_id "
        "join context c on c.id = lb.context_id where f.path in (?, ?)"
    )
    with sqlite3.connect(db) as conn:
        for context, bits in conn.execute(query, (str(path), relative)):
            node = context.split("|")[0]
            for n in numbits_to_nums(bits):
                out.setdefault(n, []).extend([node] if node else [])
    return out


def launcher_in(repo: Path, launcher: list[str]) -> list[str]:
    """The launcher with a relative interpreter path made absolute from the repo, since it runs in a
    copy; the path is not resolved, so a venv's python stays the venv's."""
    head = launcher[0]
    return [os.path.abspath(repo / head) if "/" in head else head, *launcher[1:]]


def test_names(nodes: list[str]) -> str:
    """A -k expression selecting these pytest node ids by test name. It may select more tests than
    the nodes, never fewer, and a test run in addition can only kill a mutant, not spare one."""
    return " or ".join(sorted({node.split("::")[-1].split("[")[0] for node in nodes}))


def import_path(work: Path, paths: list[str]) -> str:
    """A PYTHONPATH that puts the copy's own code first: an editable install, which points at the
    repo, sits in site-packages and so comes after it, and would otherwise test the unmutated code.
    The src directory above each changed file leads, so a package's own src/ in a monorepo counts
    as the root's does."""
    candidates = [*filter(None, (src_root(work, path) for path in paths)), work / "src", work]
    roots = [str(r) for r in dict.fromkeys(candidates) if r.is_dir()]
    return os.pathsep.join([*roots, *filter(None, [os.environ.get("PYTHONPATH")])])


def src_root(work: Path, path: str) -> Path | None:
    """The first directory named src on the path to a file, or None when there is none."""
    folders = Path(path).parts[:-1]
    return work.joinpath(*folders[:folders.index("src") + 1]) if "src" in folders else None


Covered = dict[str, dict[int, list[str]]]


def measured(work: Path, files: list[Change], pytest: list[str]) -> tuple[Covered, float | None, list[str]]:
    """Run the whole command once with per-test coverage, in the copy."""
    coverage = work / ".coverage"
    baseline = ["env", f"COVERAGE_FILE={coverage}", *pytest,
                "-q", "-p", "no:cacheprovider", "--cov", "--cov-context=test", "--cov-report="]
    took, tail = timed(baseline, work, tap=False)
    covered = {c.path: covering_tests(coverage, work / c.path, c.path) for c in files} if took is not None else {}
    return covered, took, tail


def reused(repo: Path, work: Path, files: list[Change], pytest: list[str], db: Path) -> tuple[Covered, float | None, list[str]]:
    """Read per-test coverage from a run already made, then run once, unmutated, only the tests that
    cover a line a mutant will run on: that run checks the copy's environment and times each
    mutant's limit. A line with no mutant, such as a def run at import, selects nothing."""
    covered = {c.path: covering_tests(db, repo / c.path, c.path) for c in files}
    changed = [covered[path][n] for path, n in mutated_lines(work, files) if n in covered[path]]
    if not changed:
        return covered, 0.0, []
    took, tail = timed([*pytest, "-q", "-p", "no:cacheprovider", *selection(changed)], work, tap=False)
    return covered, took, tail


def mutated_lines(work: Path, files: list[Change]) -> list[tuple[str, int]]:
    """The lines a mutant will run on: changed, mutable, and not marked equivalent."""
    found = (m for c in files for m in mutants_of(work, c, "python"))
    return sorted({(m.path, m.line) for m in found if not EQUIVALENT.search(m.before)})


def selection(covering: list[list[str]]) -> list[str]:
    """pytest arguments selecting every test in these lists; none when a line was run only at import,
    since then every test can kill its mutant."""
    if any(not nodes for nodes in covering):
        return []
    return ["-k", test_names([n for nodes in covering for n in nodes])]


def mutate_python(repo: Path, files: list[Change], command: list[str], coverage: str | None, verdict: Verdict) -> None:
    launcher = launcher_in(repo, command or [venv_python(repo), "-m", "pytest"])
    with tempfile.TemporaryDirectory() as tmp:
        work = copy_tree(repo, Path(tmp) / "w")
        pytest = ["env", f"PYTHONPATH={import_path(work, [c.path for c in files])}", *launcher]
        covered, took, tail = reused(repo, work, files, pytest, Path(coverage)) if coverage else measured(work, files, pytest)
        if took is None:
            return verdict.fail(f"python: `{shlex.join(launcher)}` fails before any mutation", *tail)
        found = [m for c in files for m in mutants_of(work, c, "python")]

        def tests_for(m: Mutant):
            if m.line not in covered[m.path]:
                return None
            nodes = covered[m.path][m.line]
            select = ["-k", test_names(nodes)] if nodes else []
            return [*pytest, "-q", "-x", "-p", "no:cacheprovider", *select], took * 3 + 10
        lived = survivors(work, found, tests_for, tap=False)
        return mutation_verdict("python", found, lived, verdict)


# ---------------------------------------------------------------- tools that mutate for us

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


def mutate_js(repo: Path, files: list[Change], command: list[str], verdict: Verdict) -> None:
    if missing("npx", verdict, "StrykerJS"):
        return None
    with tempfile.TemporaryDirectory() as tmp:
        config, out = Path(tmp) / "stryker.json", Path(tmp) / "report.json"
        config.write_text(json.dumps({
            "testRunner": "command", "commandRunner": {"command": shlex.join(command)},
            "reporters": ["json"], "jsonReporter": {"fileName": str(out)},
            "tempDirName": str(Path(tmp) / "sandbox"), "cleanTempDir": "always", "ignorePatterns": sorted(COPY_SKIP),
            "mutate": [r for c in files for r in ranges(c)],
        }))
        run = subprocess.run([*STRYKER, str(config)], cwd=repo, capture_output=True, text=True)
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


# ---------------------------------------------------------------- dispatch

def partition(repo: Path, files: list[Change]) -> tuple[list[Change], dict[str, list[Change]]]:
    """The changed source files: self-tested scripts, and the rest by language. Test files are neither."""
    source = [c for c in files if c.language and not TEST_FILE.search(c.path)]
    scripts = [c for c in source if is_self_tested(repo / c.path)]
    by_language: dict[str, list[Change]] = {}
    for c in (c for c in source if c not in scripts):
        by_language.setdefault(c.language, []).append(c)
    return scripts, by_language


def check_mutation(repo: Path, base: str, files: list[Change], options: "Options", verdict: Verdict) -> None:
    print("== mutation: every mutant on a changed line is killed")
    scripts, by_language = partition(repo, files)
    if not scripts and not by_language:
        return verdict.ok("no changed source file")
    for c in scripts:
        mutate_self_tested(repo, c, verdict)
    for language, group in sorted(by_language.items()):
        run_language(repo, base, language, group, options, verdict)
    return None


def run_language(repo: Path, base: str, language: str, files: list[Change], options: "Options", verdict: Verdict) -> None:
    names, command = ", ".join(c.path for c in files), options.tests.get(language, [])
    if language == "shell":
        return verdict.fail(f"shell: {names} offers no --self-test, so no test can kill a mutant")
    if language in ("ruby", "clojure", "haskell"):
        if not command:
            return verdict.fail(f"{language}: no --test {language}=<command> for {names}")
        return mutate_with_command(repo, files, language, command, verdict)
    runners = {"python": lambda: mutate_python(repo, files, command, options.coverage, verdict),
               "js": lambda: mutate_js(repo, files, command or ["npm", "test"], verdict),
               "go": lambda: mutate_go(repo, base, verdict), "dart": lambda: mutate_dart(repo, files, command, verdict)}
    if language in runners:
        return runners[language]()
    return verdict.fail(f"{language}: no mutation runner, so {names} cannot pass", "fix: add one to change_gate.py")


@dataclasses.dataclass
class Options:
    repo: str = "."
    base: str | None = None
    checks: tuple[str, ...] = ("complexity", "mutation")
    tests: dict[str, list[str]] = dataclasses.field(default_factory=dict)
    coverage: str | None = None


TESTED = ("python", "ruby", "clojure", "haskell", "js", "dart")


def test_command(value: str) -> tuple[str, list[str]]:
    """A --test value, <language>=<command>, as the language and the command's words."""
    language, _, command = value.partition("=")
    if language not in TESTED or not command.strip():
        raise ValueError(f"--test takes <language>=<command> with a language in {', '.join(TESTED)}, not {value}")
    return language, shlex.split(command)


def check_named(value: str) -> tuple[str, ...]:
    if value not in ("complexity", "mutation"):
        raise ValueError(f"--check takes complexity or mutation, not {value}")
    return (value,)


def set_option(options: Options, flag: str, value: str) -> None:
    """Apply one flag that takes a value."""
    if flag == "--test":
        language, command = test_command(value)
        options.tests[language] = command
    elif flag == "--check":
        options.checks = check_named(value)
    else:
        setattr(options, flag.removeprefix("--"), value)


VALUED = ("--base", "--check", "--test", "--coverage")


def parse(argv: list[str]) -> Options:
    """The options, or ValueError naming the argument it cannot read."""
    options, args = Options(), list(argv)
    while args:
        flag = args.pop(0)
        if flag in VALUED and not args:
            raise ValueError(f"{flag} needs a value")
        if flag in VALUED:
            set_option(options, flag, args.pop(0))
        elif flag.startswith("-"):
            raise ValueError(f"unknown argument {flag}")
        else:
            options.repo = flag
    return options


def main(argv: list[str]) -> int:
    try:
        options = parse(argv)
        repo = Path(git(Path(options.repo), "rev-parse", "--show-toplevel").strip())
        base = git(repo, "merge-base", options.base or default_base(repo), "HEAD").strip()
        files = changes(repo, base)
    except (ValueError, subprocess.CalledProcessError) as e:
        print(f"change_gate.py: {getattr(e, 'stderr', '') or e}; see --help", file=sys.stderr)
        return 2
    print(f"change_gate {repo}, base {base}, {len(files)} changed files")
    verdict = Verdict()
    if "complexity" in options.checks:
        check_complexity(repo, files, verdict)
    if "mutation" in options.checks:
        check_mutation(repo, base, files, options, verdict)
    print(f"change_gate: {'FAIL' if verdict.failed else 'PASS'}")
    return 1 if verdict.failed else 0


# ---------------------------------------------------------------- self-test

FIXTURE_SH = """#!/usr/bin/env bash
over() { [ "$1" -gt "$2" ]; }
if [ "${1:-}" = --self-test ]; then
  over 5 3 || exit 1
  over 1 3 && exit 1
  printf 'ok 1 - over\\n1..1\\n'
fi
"""


def self_test_repo(root: Path) -> Path:
    repo = root / "r"
    repo.mkdir()
    git(repo, "init", "-q")
    (repo / "README").write_text("x\n")
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
    return repo


def self_test_run(repo: Path, *args: str) -> tuple[int, str]:
    """The gate's exit status, and what it printed to stdout and stderr together."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        status = main([str(repo), *args])
    return status, out.getvalue()


def self_test_mutants(t: Tap) -> None:
    diff = "+++ b/a.py\n@@ -1,0 +2,2 @@\n+x\n+y\n@@ -9 +11 @@\n-z\n+w\n+++ /dev/null\n@@ -1 +0,0 @@\n"
    t.check(added_lines(diff) == {"a.py": {2, 3, 11}}, "a diff yields the new-side lines it adds, deletions dropped",
            str(added_lines(diff)))
    t.check(ranges(Change("a.js", frozenset({1, 2, 3, 7}))) == ["a.js:1-3", "a.js:7-7"],
            "consecutive changed lines become one Stryker range")
    t.check(code_part('x = "a == b"  # c < d', "python") == "x =         " + "  ", "quoted text and comments are not code")
    t.check(code_part('(if (< a b) "x" b) ; (> c d)', "clojure") == '(if (< a b)     b) ' and code_part("f x' y' == z -- c", "haskell")
            == "f x' y' == z ", "a Clojure ; and a Haskell -- open comments, and ' quotes nothing there")
    t.check(code_part('(( ${#a[@]} )) && x  # y', "shell") == "(( ${#a[@]} )) && x  ", "a shell hash inside a word is code")
    shell = [m.after.strip() for m in line_mutants("s", 1, '[ "$a" -gt 1 ] && exit 0\n', "shell")]
    t.check(set(shell) == {'[ "$a" -le 1 ] && exit 0', '[ "$a" -ge 1 ] && exit 0', '[ "$a" -gt 1 ] || exit 0'},
            "shell comparisons and && are mutated, exit codes are not", *shell)
    py = [m.after.strip() for m in line_mutants("p", 1, "return a <= b and not c  # x == y\n", "python")]
    t.check({"return a < b and not c  # x == y", "return a <= b or not c  # x == y", "return a <= b and c  # x == y"} <= set(py)
            and not any("x != y" in m for m in py), "Python comparisons, and/or and not are mutated, comments are not", *py)
    t.check(line_mutants("p", 1, "def f(x) -> int:\n", "python") == [], "-> and => are not comparisons")
    clj = {m.after.strip() for m in line_mutants("c", 1, "(when (< a b) (inc a))\n", "clojure")}
    t.check(clj == {"(when-not (< a b) (inc a))", "(when (<= a b) (inc a))", "(when (>= a b) (inc a))", "(when (< a b) (dec a))"},
            "Clojure forms are mutated at their head", *sorted(clj))
    hs = {m.after.strip() for m in line_mutants("h", 1, "f x = x == 1 && x' <- y\n", "haskell")}
    t.check(hs == {"f x = x /= 1 && x' <- y", "f x = x == 1 || x' <- y"}, "Haskell's /= replaces !=, and <- is no comparison", *sorted(hs))


def self_test_masks(t: Tap) -> None:
    t.check(line_mutants("p", 1, "report = sorted(errors)\n", "python") == [], "an operator word inside a name is not mutated")
    doc = 'x = 1\n"""a < b\nand c == d"""\ny = f"{a < b} and"  # e > f\n'
    code = python_code(doc)
    t.check([len(c) for c in code] == [len(x) for x in doc.splitlines(keepends=True)]
            and [len(c) for c in python_code('"""open\n')] == [8], "masked lines keep their length, tokenizable or not",
            str([len(c) for c in code]))
    t.check("<" not in code[1] and "==" not in code[2] and "a < b" in code[3] and ">" not in code[3] and "and" not in code[3],
            "a multi-line string and a comment are not code, an f-string expression is", *code)
    sh_lines = FIXTURE_SH.splitlines()
    t.check(test_region(sh_lines, "shell") == {3, 4, 5, 6, 7}, "a shell self-test block is test code, to its fi",
            str(test_region(sh_lines, "shell")))
    py_lines = ["def f(a):", "    return a", "def self_test():", "    t = 1", "", "    return t == 1", "x = 1"]
    t.check(test_region(py_lines, "python") == {3, 4, 5, 6}, "a Python self_test function is test code, to its dedent",
            str(test_region(py_lines, "python")))


def self_test_edges(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        for name, body, want in (("a.py", "x\n", "python3"), ("b.sh", "#!/usr/bin/env python3\n", "python3"), ("c.sh", "#!/bin/sh\n", "bash")):
            (Path(tmp) / name).write_text(body)
            t.check(runner(Path(tmp) / name) == want, f"{name} runs under {want}, as the sweep runs it")
    t.check(code_part("# a == b\n", "shell") == "" and code_part("a == b  # c\n", "ruby") == "a == b  ", "a line that opens with a hash is all comment")
    t.check(not passes(["/nonexistent/x"], Path("."), 10, tap=False) and not passes(["sleep", "5"], Path("."), 0.1, tap=False),
            "a command that cannot start or overruns its timeout has not passed")
    t.check(test_region(["x=1", "self_test() { echo; }", "y=2"], "shell") == {2}, "a one-line shell self_test is test code alone")
    lines = ["a = 1\n", "# mutation: equivalent — why\n"]
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "f").write_text("".join(lines))
        t.check(accepted(Path(tmp), "f", 2) and not accepted(Path(tmp), "f", 0) and not accepted(Path(tmp), "f", 3),
                "a survivor is accepted only on a real line marked equivalent")
    t.check(not passes(["sh", "-c", "exit 0"], Path("."), 10, tap=True), "a self-test that prints no plan has not passed")


def self_test_reports(t: Tap) -> None:
    rows = '4,12,19,2,4,"f","a.js","f","f ( x , y )",1,4\n1,10,10,1,1,"g","a.js","g","g ( )",5,5\n'
    t.check(over_limit(rows) == ["a.js:1 f (CCN 12)"],
            "a function above CCN 10 is flagged, one at 10 is not, and a comma in a long name is read as CSV", *over_limit(rows))
    report = {"files": {"a.js": {"mutants": [
        {"status": "Survived", "mutatorName": "EqualityOperator", "replacement": "x >= hi", "location": {"start": {"line": 2}}},
        {"status": "Killed", "mutatorName": "BlockStatement", "replacement": "{}", "location": {"start": {"line": 1}}}]}}}
    t.check(stryker_lived(report) == [("a.js", 2, "EqualityOperator → x >= hi (Survived)")], "a Stryker survivor is read from its report")
    greml = {"files": [{"file_name": "b.go", "mutations": [{"type": "CONDITIONALS_BOUNDARY", "status": "LIVED", "line": 4},
                                                         {"type": "X", "status": "KILLED", "line": 4}]}]}
    t.check(gremlins_lived(greml) == [("b.go", 4, "CONDITIONALS_BOUNDARY (LIVED)")], "a gremlins survivor is read from its report")
    dart = ET.fromstring('<undetected-mutations><file name="lib/d.dart"><mutation line="2"><original>a &gt;= b</original>'
                         '<modified>a &gt; b</modified></mutation></file></undetected-mutations>')
    t.check(dart_lived(dart) == [("lib/d.dart", 2, "a >= b → a > b")], "a mutation_test survivor is read from its report")
    t.check(parse(["--check", "mutation", "r", "--test", "ruby=rspec -x 'a b'"]) == Options("r", None, ("mutation",), {"ruby": ["rspec", "-x", "a b"]}),
            "the repo, the check and a language's test command, split as the shell splits it, are read")
    refused = []
    for argv in (["--test", "go=go test"], ["--test", "ruby="], ["--", "rspec"]):
        with contextlib.suppress(ValueError):
            parse(argv)
            refused.append(argv)
    t.check(refused == [], "a test command for an untested language, an empty one, and a bare -- are refused", str(refused))


FAKE_NPX = """#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
if os.environ.get("FAKE_BROKEN"):
    print("stryker broke")
    sys.exit(3)
config = json.loads(pathlib.Path(sys.argv[-1]).read_text())
shutil.copy(sys.argv[-1], pathlib.Path(__file__).with_name("stryker.json"))
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
CALC = 'def over(a, b):\n    """Whether a is\n    more than b, not equal."""\n    return a > b\n\n\ndef unused(a):\n    return a + 1\n'
WEAK_TEST = "from calc import over\n\n\ndef test_over():\n    assert over(5, 3)\n    assert not over(1, 3)\n"


def self_test_fakes(folder: Path) -> Path:
    folder.mkdir()
    for name, body in (("npx", FAKE_NPX), ("gremlins", FAKE_GREMLINS), ("dart", FAKE_DART), ("uvx", FAKE_UVX)):
        (folder / name).write_text(body)
        (folder / name).chmod(0o755)
    return folder


@contextlib.contextmanager
def self_test_env(**values: str):
    saved = {k: os.environ.get(k) for k in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for k, v in saved.items():
            os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)


def self_test_files(repo: Path, files: dict[str, str]) -> None:
    """The fixture's untracked files become exactly these."""
    for path in git(repo, "ls-files", "--others", "--exclude-standard").splitlines():
        (repo / path).unlink()
    for path, body in files.items():
        (repo / path).parent.mkdir(parents=True, exist_ok=True)
        (repo / path).write_text(body)


def self_test_tools(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo, fakes = self_test_repo(Path(tmp)), self_test_fakes(Path(tmp) / "fakes")
        with self_test_env(PATH=f"{fakes}:{os.environ['PATH']}"):
            self_test_js(t, repo, fakes)
            self_test_go_dart(t, repo, fakes)
            self_test_complexity(t, repo)


def self_test_js(t: Tap, repo: Path, fakes: Path) -> None:
    self_test_files(repo, {"a.js": "if (a > b) x()\n"})
    status, out = self_test_run(repo, "--check", "mutation")
    t.check(status == 1 and "a.js:1: EqualityOperator → a >= b (Survived)" in out, "a StrykerJS survivor fails the gate", out)
    config = json.loads((fakes / "stryker.json").read_text())
    t.check(config["mutate"] == ["a.js:1-1"] and config["commandRunner"]["command"] == "npm test",
            "Stryker mutates only the changed lines, testing with npm test by default", str(config))
    t.check(".venv" in config["ignorePatterns"] and ".git" in config["ignorePatterns"],
            "Stryker leaves out of its sandbox the folders the gate's own copy leaves out", str(config))
    self_test_run(repo, "--check", "mutation", "--test", "js=yarn test --ci")
    config = json.loads((fakes / "stryker.json").read_text())
    t.check(config["commandRunner"]["command"] == "yarn test --ci", "Stryker tests with the --test js command", str(config))
    self_test_files(repo, {"a.js": "if (a > b) x() // mutation: equivalent — x is idempotent\n"})
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
    self_test_files(repo, {"a.js": "x()\n", "b.go": "package b\n"})
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


def self_test_complexity(t: Tap, repo: Path) -> None:
    self_test_files(repo, {"a.py": "x = 1\n", "s.sh": "echo\n"})
    over = '4,12,19,2,4,"f","a.py","f","f ( x )",1,4'
    with self_test_env(FAKE_UVX_CSV=over):
        status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 1 and "a.py:1 f (CCN 12)" in out, "a function above CCN 10 fails the gate", out)
    with self_test_env(FAKE_UVX_CSV=over.replace(",12,", ",10,")):
        status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 0 and "1 files, every function" in out, "a function at CCN 10 passes, and shell is not measured", out)
    with self_test_env(FAKE_UVX_FAIL="1"):
        status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 1 and "lizard exited 1" in out, "a lizard that fails fails the gate", out)
    self_test_files(repo, {"s.sh": "echo\n"})
    status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 0 and "no changed file in a measured language" in out, "a change in no measured language passes", out)


SILENT_SH = """#!/usr/bin/env bash
self_test() {
  printf 'ok 1 - x\\n1..1\\n'
}
[ "${1:-}" = --self-test ] && self_test
"""


def self_test_scripts(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        self_test_files(repo, {"s.sh": SILENT_SH})
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 0 and "s.sh: 1 mutants, 1 killed" in out,
                "a mutant that silences the self-test is killed: exit 0 with no plan is not a pass", out)
        (repo / "s.sh").write_text("#!/usr/bin/env bash\n# offers --self-test and prints nothing\n")
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "its --self-test fails before any mutation" in out, "a self-test that prints no plan unmutated fails the gate", out)
        status, out = self_test_run(Path(tmp))
        t.check(status == 2 and "not a git repository" in out, "a folder outside git is a usage error, with git's reason", out)
        status, out = self_test_run(repo, "--nope")
        t.check(status == 2 and "unknown argument --nope; see --help" in out, "an unknown argument is a usage error naming it", out)
        clone = Path(tmp) / "clone"
        subprocess.run(["git", "clone", "-q", str(repo), str(clone)], check=True)
        head = git(repo, "rev-parse", "HEAD").strip()
        git(clone, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "ahead")
        status, out = self_test_run(clone, "--check", "complexity")
        t.check(default_base(clone).startswith("refs/remotes/origin/") and default_base(repo) == "HEAD" and f"base {head}," in out,
                "the base is the merge-base with origin's default branch, or HEAD with no origin", out)


def self_test_python(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        self_test_files(repo, {"calc.py": CALC, "test_calc.py": WEAK_TEST})
        with self_test_env(COVERAGE_FILE=str(Path(tmp) / "elsewhere")):
            status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "calc.py:4: return a > b  →  return a >= b" in out,
                "a pytest suite that misses the boundary lets a mutant live, whatever COVERAGE_FILE the caller set", out)
        t.check("calc.py:8:" in out and "test_calc.py:" not in out, "a line no test runs lives, and test files are not mutated", out)
        strong = WEAK_TEST + "    assert not over(3, 3)\n\n\ndef test_unused():\n    assert unused(1) == 2\n"
        self_test_files(repo, {"calc.py": CALC, "test_calc.py": strong.replace("import over", "import over, unused")})
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 0 and "python: 3 mutants, 3 killed" in out, "a pytest suite that pins every line kills every mutant", out)
        self_test_files(repo, {"calc.py": CALC, "tests/test_calc.py": WEAK_TEST, "console/probe_test.py": "import no_such_module\n",
                               "bin/py": "#!/bin/sh\nexec python3 \"$@\"\n"})
        (repo / "bin/py").chmod(0o755)
        status, out = self_test_run(repo, "--check", "mutation", "--test", "python=bin/py -m pytest tests")
        t.check(status == 1 and "calc.py:4: return a > b  →  return a >= b" in out and "a <= b" not in out,
                "a --test python command keeps its own test paths and runs from the repo, choosing tests per mutant", out)
        status, out = self_test_run(repo, "--check", "mutation", "--test", "python=bin/py -m pytest")
        t.check(status == 1 and "fails before any mutation" in out and "no_such_module" in out,
                "a baseline that fails shows the end of its output", out)
        self_test_python_src(t, Path(tmp))


def self_test_python_src(t: Tap, tmp: Path) -> None:
    (tmp / "srclayout").mkdir()
    repo = self_test_repo(tmp / "srclayout")
    strong = WEAK_TEST + "    assert not over(3, 3)\n\n\ndef test_unused():\n    assert unused(1) == 2\n"
    installed = f'#!/bin/sh\nPYTHONPATH="${{PYTHONPATH:+$PYTHONPATH:}}{repo}/src" exec python3 "$@"\n'
    self_test_files(repo, {"src/calc.py": CALC, "tests/test_calc.py": strong.replace("import over", "import over, unused"),
                           "bin/py": installed})
    (repo / "bin/py").chmod(0o755)
    status, out = self_test_run(repo, "--check", "mutation", "--test", "python=bin/py -m pytest tests")
    t.check(status == 0 and "python: 3 mutants, 3 killed" in out,
            "a src layout installed editable tests the mutated copy, not the repo it was installed from", out)
    (tmp / "monorepo").mkdir()
    repo = self_test_repo(tmp / "monorepo")
    installed = f'#!/bin/sh\nPYTHONPATH="${{PYTHONPATH:+$PYTHONPATH:}}{repo}/packages/calc/src" exec python3 "$@"\n'
    self_test_files(repo, {"packages/calc/src/calc.py": CALC,
                           "packages/calc/tests/test_calc.py": strong.replace("import over", "import over, unused"),
                           "bin/py": installed})
    (repo / "bin/py").chmod(0o755)
    status, out = self_test_run(repo, "--check", "mutation", "--test", "python=bin/py -m pytest packages/calc/tests")
    t.check(status == 0 and "python: 3 mutants, 3 killed" in out,
            "a package's own src/ in a monorepo, installed editable, tests the mutated copy too", out)
    (tmp / "imported").mkdir()
    repo = self_test_repo(tmp / "imported")
    self_test_files(repo, {"flags.py": "STRICT = True\n\n\ndef strict():\n    return STRICT\n",
                           "tests/test_flags.py": "from flags import strict\n\n\ndef test_strict():\n    assert strict()\n"})
    status, out = self_test_run(repo, "--check", "mutation", "--test", "python=python3 -m pytest tests")
    t.check(status == 0 and "python: 1 mutants, 1 killed" in out,
            "a line run only at import is tested by the whole suite, not counted as untested", out)


def self_test_reuse(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        self_test_files(repo, {"calc.py": CALC, "tests/test_calc.py": WEAK_TEST})
        for name, extra in (("absolute", []), ("relative", ["--cov-config", str(Path(tmp) / "rc")])):
            (Path(tmp) / "rc").write_text("[run]\nrelative_files = True\n")
            db = Path(tmp) / f"{name}.coverage"
            subprocess.run(["env", f"COVERAGE_FILE={db}", "python3", "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests",
                            "--cov", "--cov-context=test", "--cov-report=", *extra], cwd=repo, capture_output=True, check=False)
            status, out = self_test_run(repo, "--check", "mutation", "--test", "python=python3 -m pytest tests", "--coverage", str(db))
            t.check(status == 1 and "calc.py:4: return a > b  →  return a >= b" in out and "calc.py:8:" in out,
                    f"a coverage file with {name} paths is reused, and its untested lines still live", out)
        self_test_files(repo, {"calc.py": CALC, "tests/test_calc.py": WEAK_TEST, "tests/test_broken.py": "def test_broken():\n    assert False\n"})
        status, out = self_test_run(repo, "--check", "mutation", "--test", "python=python3 -m pytest tests", "--coverage", str(db))
        t.check(status == 1 and "calc.py:4: return a > b  →  return a >= b" in out,
                "a reused coverage file reruns only the tests covering the changed lines, so an unrelated failure is not run", out)
        self_test_files(repo, {"calc.py": CALC, "tests/test_calc.py": WEAK_TEST.replace("assert not over(1, 3)", "assert not over(1, 3) and False")})
        status, out = self_test_run(repo, "--check", "mutation", "--test", "python=python3 -m pytest tests", "--coverage", str(db))
        t.check(status == 1 and "fails before any mutation" in out,
                "with a reused coverage file, covering tests that fail unmutated still fail the gate", out)


def self_test_commands(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        self_test_files(repo, {"m.rb": "def f(a) = a > 1\n"})
        status, out = self_test_run(repo, "--check", "mutation", "--test", "ruby=grep -q 'a > 1' m.rb")
        t.check(status == 0 and "ruby: 2 mutants, 2 killed" in out, "a --test ruby command runs for every mutant", out)
        status, out = self_test_run(repo, "--check", "mutation", "--test", "ruby=true")
        t.check(status == 1 and "ruby: 2 of 2 mutants lived" in out,
                "a test command is judged by its exit status alone, so one that always passes kills nothing", out)
        status, out = self_test_run(repo, "--check", "mutation", "--test", "ruby=sh -c 'echo broke; exit 1'")
        t.check(status == 1 and "fails before any mutation\n        broke" in out, "a test command that fails unmutated fails the gate, saying why", out)


def self_test_gate(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        script = repo / "clamp.sh"
        script.write_text(FIXTURE_SH)
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "-ge" in out and "lived" in out, "a self-test that misses the boundary lets a mutant live", out)
        script.write_text(FIXTURE_SH.replace("  over 1 3 && exit 1\n", "  over 1 3 && exit 1\n  over 3 3 && exit 1\n"))
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 0 and "2 mutants, 2 killed" in out, "a self-test that pins the boundary kills every mutant", out)
        t.check(git(repo, "status", "--porcelain").strip() == "?? clamp.sh" and "-gt" in script.read_text(),
                "the gate leaves the checkout as it found it")
        script.write_text(FIXTURE_SH.replace('"$2" ]; }', '"$2" ]; }  # mutation: equivalent — callers never pass equal values'))
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 0 and "2 mutants, 0 killed, 2 marked equivalent" in out,
                "the mutator runs no mutant on a line marked equivalent, and counts it apart", out)
        script.write_text(FIXTURE_SH.replace('"$2" ]; }', '"$2" ]; }  # mutation: equivalent'))
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "1 of 2 mutants lived" in out, "a marker with no reason marks nothing", out)


def self_test_refusals(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        self_test_files(repo, {"m.rb": "def f(a) = a > 1\n"})
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "ruby: no --test ruby=<command>" in out, "a Ruby change with no test command fails", out)
        self_test_files(repo, {"s.sh": "echo $(( 1 + 1 ))\n"})
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "shell: s.sh offers no --self-test" in out, "a shell script with no self-test fails, naming why", out)
        self_test_files(repo, {"p.cs": "class P {}\n"})
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "csharp: no mutation runner" in out, "a language with no runner fails, never skips", out)
        bare = Path(tmp) / "bin"
        bare.mkdir()
        (bare / "git").symlink_to(shutil.which("git"))
        self_test_files(repo, {"a.js": "module.exports = 1\n"})
        with self_test_env(PATH=str(bare)):
            status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "npx is not installed" in out, "a missing tool fails the gate, naming the fix", out)


def self_test() -> int:
    t = Tap()
    self_test_mutants(t)
    self_test_masks(t)
    self_test_edges(t)
    self_test_reports(t)
    self_test_gate(t)
    self_test_refusals(t)
    self_test_tools(t)
    self_test_python(t)
    self_test_commands(t)
    self_test_reuse(t)
    self_test_scripts(t)
    return t.end()


if __name__ == "__main__":
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__)
        sys.exit(0)
    sys.exit(self_test() if sys.argv[1:2] == ["--self-test"] else main(sys.argv[1:]))
