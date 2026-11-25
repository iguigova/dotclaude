#!/usr/bin/env python3
"""change_gate_mutator.py — change_gate.py's the mutator: the mutants of a changed line, and running the tests against each on its own copy.

Imported, never run; ``python3 change_gate_mutator.py --self-test`` runs change_gate's whole
suite: the parts are one tool, and the cases that pin one part sit beside another.
"""

import dataclasses
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tokenize
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402
from group_run import run as run_group  # noqa: E402
from change_gate_base import COPY_SKIP, Change, EQUIVALENT, FIXTURE_SH, PY_TEXT, Verdict, added_lines, blank, code_part, git, runner, shell_code, test_region  # noqa: E402

PROJECT_FILE = Path(__file__).resolve().parent / "project_file.sh"


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


def code_lines(text: str, language: str) -> list[str]:
    """Each line of TEXT with its quoted text and comments blanked: Python and shell read whole, so a
    string or a quoted program spanning lines is text throughout; the rest line by line."""
    if language == "python":
        return python_code(text)
    if language == "shell":
        return shell_code(text)
    return [code_part(line, language) for line in text.splitlines(keepends=True)]


def mutants_of(repo: Path, change: Change, language: str, skip: frozenset[int] = frozenset()) -> list[Mutant]:
    text = (repo / change.path).read_text()
    lines = text.splitlines(keepends=True)
    code = code_lines(text, language)
    return [
        m for n in sorted(change.lines - skip) if n <= len(lines)
        for m in line_mutants(change.path, n, lines[n - 1], language, code[n - 1])
    ]


def project_file(repo: Path, *args: str) -> str:
    """What project_file.sh prints for args in repo; its refusal reaches stderr and raises."""
    return subprocess.run([str(PROJECT_FILE), *args], cwd=repo, stdout=subprocess.PIPE, text=True, check=True).stdout


def listed_clones(repo: Path) -> list[str]:
    """The paths from repo of the clones it lists, when repo is a project's folder with a clones manifest."""
    if not (repo / ".claude" / "project").is_file() or not (repo / ".claude" / "clones").is_file():
        return []
    root = project_file(repo, "--root").strip()
    return [str(Path(line.split("\t")[1]).relative_to(root)) for line in project_file(repo, "--clones").splitlines()]


def link_clones(repo: Path, target: Path, clones: list[str]) -> Path:
    """Each clone linked into the copy, never copied: a self-test reads a clone and never writes to one."""
    for rel in clones:
        (target / rel).parent.mkdir(parents=True, exist_ok=True)
        (target / rel).symlink_to(repo / rel)
    return target


def copy_tree(source: Path, target: Path) -> Path:
    """A copy to mutate; node_modules and each listed clone are linked, not copied, and the other skipped folders are left out."""
    clones = listed_clones(source)
    linked = {source / rel for rel in clones}

    def skip(folder: str, names: list[str]) -> list[str]:
        return [n for n in names if n in COPY_SKIP or Path(folder, n) in linked]
    shutil.copytree(source, target, ignore=skip, symlinks=True)  # mutation: equivalent — a link copied as its target reads the same
    if (source / "node_modules").is_dir():
        (target / "node_modules").symlink_to(source / "node_modules")
    return link_clones(source, target, clones)


def copy_listed(repo: Path, target: Path) -> Path:
    """A copy of the files git lists in the working tree, tracked or untracked and not ignored: the repo as it stands, without
    the ignored state beside it, so a self-test that reads a file outside its script's folder finds it in the copy."""
    for name in filter(None, git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0")):
        source, copy = repo / name, target / name
        if source.is_symlink() or source.is_file():
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, copy, follow_symlinks=False)  # mutation: equivalent — a file link copied as its target reads the same
    return link_clones(repo, target, listed_clones(repo))


TAP_PLAN = re.compile(r"^1\.\.\d+$", re.M)


BASELINE_TAIL = 15


def group_run(command: list[str], cwd: Path, timeout: float | None, out, err) -> int | None:
    """The command's status, or None when it overran timeout. It runs under group_run.py, so
    nothing it starts outlives it, with a TMPDIR removed once it ends: a mutant can start a
    process that never ends, or break the cleanup of a folder its test made, and a test runs
    once per mutant."""
    with tempfile.TemporaryDirectory() as tmp:
        env = {**os.environ, "TMPDIR": tmp}
        return run_group(command, cwd=cwd, env=env, timeout=timeout, stdout=out, stderr=err)


def read_back(f) -> str:
    f.seek(0)
    return f.read()


def run_tests(command: list[str], cwd: Path, timeout: float | None, tap: bool) -> tuple[bool, str]:
    """Whether the tests passed, and what they printed. They pass by exiting 0, and with tap also by
    printing a TAP plan and no failed case: a self-test that stopped printing has not passed. What
    they print goes to files, not pipes, so a process holding a pipe open cannot stall the read."""
    with tempfile.TemporaryFile("w+") as out, tempfile.TemporaryFile("w+") as err:
        try:
            status = group_run(command, cwd, timeout, out, err)
        except OSError as e:
            return False, str(e)
        stdout, stderr = read_back(out), read_back(err)
    if status is None:
        return False, f"timed out after {timeout:.0f}s"
    tap_held = bool(TAP_PLAN.search(stdout)) and "not ok" not in stdout
    return status == 0 and (not tap or tap_held), stdout + stderr


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


def self_test_mutants(t: Tap) -> None:
    from change_gate_tools import ranges
    diff = "+++ b/a.py\n@@ -1,0 +2,2 @@\n+x\n+y\n@@ -9 +11 @@\n-z\n+w\n+++ /dev/null\n@@ -1 +0,0 @@\n"
    t.check(added_lines(diff) == {"a.py": {2, 3, 11}}, "a diff yields the new-side lines it adds, deletions dropped",
            str(added_lines(diff)))
    t.check(ranges(Change("a.js", frozenset({1, 2, 3, 7}))) == ["a.js:1-3", "a.js:7-7"],
            "consecutive changed lines become one Stryker range")
    t.check(code_part('x = "a == b"  # c < d', "python") == "x =         " + "  ", "quoted text and comments are not code")
    awk = "awk '\n  a && b\n' f && g\n"
    t.check([len(line_mutants("s", n, line, "shell", code)) for n, (line, code)
             in enumerate(zip(awk.splitlines(keepends=True), code_lines(awk, "shell")), 1)] == [0, 0, 1],
            "code inside a quote that spans lines is not mutated as shell; the code after it is")
    t.check(code_lines("a == b\n", "go") == ["a == b\n"], "a language read line by line keeps its code")
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


def self_test_groups(t: Tap) -> None:
    def dead(stat: Path) -> bool:
        return not stat.exists() or stat.read_text().split(") ")[1].startswith("Z")

    def gone(pid_file: Path) -> bool:
        """A kill lands a moment after it is sent, so the process gets five seconds to die."""
        stat, deadline = Path(f"/proc/{int(pid_file.read_text())}/stat"), time.monotonic() + 5
        while not dead(stat) and time.monotonic() < deadline:
            time.sleep(0.02)
        return dead(stat)

    with tempfile.TemporaryDirectory() as tmp:
        for timeout, script in ((10, "sleep 300 & echo $! > pid; echo out; echo err >&2"), (0.5, "sleep 300 & echo $! > pid; wait")):
            passed, printed = run_tests(["bash", "-c", script], Path(tmp), timeout, tap=False)
            t.check(gone(Path(tmp) / "pid") and passed == (timeout == 10),
                    f"a process the tests started dies with them, timeout {timeout}s", f"{passed} {printed!r}")
        t.check(run_tests(["bash", "-c", "sleep 300 & echo out; echo err >&2"], Path(tmp), 10, tap=False) == (True, "out\nerr\n"),
                "a process holding the output open does not stall the read, and both streams are read back")
        left = run_tests(["mktemp", "-d"], Path(tmp), 10, tap=False)[1].strip()
        t.check(left.startswith("/") and not Path(left).exists() and Path(left).parent != Path(tempfile.gettempdir()),
                "a folder the tests leave in their TMPDIR is removed with it", left)


def self_test_copies(t: Tap) -> None:
    from change_gate_base import self_test_repo

    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        (repo / "a" / "b").mkdir(parents=True)
        (repo / "a" / "b" / "c.py").write_text("x = 1\ny = x < 2\n")
        copy = copy_listed(repo, Path(tmp) / "copy")
        t.check((copy / "a" / "b" / "c.py").is_file(), "a listed file two folders deep is copied")
        last = mutants_of(repo, Change("a/b/c.py", frozenset({2, 3})), "python")
        t.check(last and {m.line for m in last} == {2}, "a change on the last line is mutated, one past it is not", repr(last))
        self_test_clone_links(t, repo, Path(tmp))


def self_test_clone_links(t: Tap, repo: Path, tmp: Path) -> None:
    clone, remote = repo / "api" / "2.0" / "c", "file:///nowhere/c.git"
    git(repo, "init", "-q", str(clone))
    git(clone, "remote", "add", "origin", remote)
    (clone / "data").write_text("d\n")
    (repo / ".claude").mkdir()
    (repo / ".claude" / "project").write_text("r\n")
    t.check(not (copy_listed(repo, tmp / "bare") / "api").exists(), "a project that lists no clones links none")
    (repo / ".claude" / "clones").write_text(f"c api/2.0/c {remote}\nc api/2.0/c {remote}\n")
    try:
        copy_listed(repo, tmp / "twice")
        t.check(False, "a manifest project_file.sh refuses stops the copy")
    except subprocess.CalledProcessError:
        t.check(True, "a manifest project_file.sh refuses stops the copy")
    (repo / ".claude" / "clones").write_text(f"c api/2.0/c {remote}\n")
    for name, copy in (("copy_listed", copy_listed(repo, tmp / "listed")), ("copy_tree", copy_tree(repo, tmp / "tree"))):
        linked = copy / "api" / "2.0" / "c"
        t.check(linked.is_symlink() and linked.resolve() == clone.resolve(), f"{name} links a listed clone into its copy, never copies it")
        found = project_file(copy, "--clone", "c").strip()
        t.check(found == str(linked.parent.resolve() / "c"), f"and a self-test in the {name} copy reaches the clone by its name", found)


def self_test_stamps(t: Tap) -> None:
    """Two mutants of one size each run as written: the stamps climb past every mtime there is,
    so a .pyc compiled from the original or an earlier mutant is never taken for the next."""
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        mod = work / "mod.py"
        mod.write_text("X = 1\n")
        then = int(time.time()) - 1
        os.utime(mod, (then, then))
        subprocess.run([sys.executable, "-c", "import mod"], cwd=work, check=True)
        mutants = [Mutant("mod.py", 1, "X = 1\n", f"X = {n}\n") for n in (2, 3)]
        test = ([sys.executable, "-c", "import mod; assert mod.X in (1, 2)"], 30)
        lived = survivors(work, mutants, lambda m: test, tap=False)
        t.check(lived == mutants[:1], "each mutant is judged as written, never by a stale .pyc", repr(lived))


def self_test_edges(t: Tap) -> None:
    from change_gate_tools import accepted
    with tempfile.TemporaryDirectory() as tmp:
        for name, body, want in (("a.py", "x\n", "python3"), ("b.sh", "#!/usr/bin/env python3\n", "python3"), ("c.sh", "#!/bin/sh\n", "bash")):
            (Path(tmp) / name).write_text(body)
            t.check(runner(Path(tmp) / name) == want, f"{name} runs under {want}, as the sweep runs it")
    t.check(code_part("# a == b\n", "shell") == "" and code_part("a == b  # c\n", "ruby") == "a == b  ", "a line that opens with a hash is all comment")
    t.check(not passes(["/nonexistent/x"], Path("."), 10, tap=False) and not passes(["sleep", "5"], Path("."), 0.1, tap=False),
            "a command that cannot start or overruns its timeout has not passed")
    self_test_groups(t)
    t.check(test_region(["x=1", "self_test() { echo; }", "y=2"], "shell") == {2}, "a one-line shell self_test is test code alone")
    t.check(test_region(["x=1", "self_test_e2e() {", "  echo", "}", "y=2"], "shell") == {2, 3, 4},
            "a shell self_test_ helper is test code, as a Python one is")
    lines = ["a = 1\n", "# mutation: equivalent — why\n"]
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "f").write_text("".join(lines))
        t.check(accepted(Path(tmp), "f", 2) and not accepted(Path(tmp), "f", 0) and not accepted(Path(tmp), "f", 3),
                "a survivor is accepted only on a real line marked equivalent")
    t.check(not passes(["sh", "-c", "exit 0"], Path("."), 10, tap=True), "a self-test that prints no plan has not passed")

def self_test() -> int:
    from change_gate import self_test as whole

    return whole()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
