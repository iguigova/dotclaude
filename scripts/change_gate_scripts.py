#!/usr/bin/env python3
"""change_gate_scripts.py — change_gate.py's mutation for a self-tested script, a test command, and Python's per-test coverage.

Imported, never run; ``python3 change_gate_scripts.py --self-test`` runs change_gate's whole
suite: the parts are one tool, and the cases that pin one part sit beside another.
"""

import concurrent.futures
import os
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402
from change_gate_base import Change, EQUIVALENT, Verdict, default_base, git, runner, self_test_env, self_test_files, self_test_repo, self_test_run, test_region  # noqa: E402
from change_gate_mutator import Mutant, copy_listed, copy_tree, mutants_of, mutation_verdict, passes, survivors, timed  # noqa: E402


# ---------------------------------------------------------------- self-tested scripts, Ruby, Python

def mutate_self_tested(repo: Path, change: Change, jobs: int, verdict: Verdict) -> None:
    language = "shell" if change.path.endswith(".sh") else "python"
    with tempfile.TemporaryDirectory() as tmp:
        work = (copy_listed(repo, Path(tmp) / "w") / change.path).parent
        name = Path(change.path).name
        command = [runner(work / name), f"./{name}", "--self-test"]
        took, tail = timed(command, work, tap=True)
        if took is None:
            return verdict.fail(f"{change.path}: its --self-test fails before any mutation", *tail)
        region = test_region((work / name).read_text().splitlines(), language)
        found = mutants_of(work, Change(name, change.lines), language, frozenset(region))
        lived = side_by_side(change.path, Path(tmp) / "w", work, found, (command, took * 3 + 10), jobs, verdict)
        return mutation_verdict(change.path, found, lived, verdict)


def side_by_side(what: str, root: Path, work: Path, mutants: list[Mutant], test: tuple[list[str], float], jobs: int, verdict: Verdict) -> list[Mutant]:
    """survivors for one TAP command, jobs mutants at a time, each worker in its own copy of root. The
    unmutated test first runs in every copy at once; when any copy fails, the mutants run one at a
    time instead, since a test holding a fixed path or port collides with itself, and a collision
    would read as a killed mutant."""
    live = [m for m in mutants if not EQUIVALENT.search(m.before)]
    jobs = min(jobs, len(live))
    if jobs < 2:
        return survivors(work, live, lambda _m: test, tap=True)
    rel = work.relative_to(root)
    works = [work] + [Path(shutil.copytree(root, root.with_name(f"{root.name}.{i}"), symlinks=True)) / rel for i in range(1, jobs)]
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        if not all(pool.map(lambda w: passes(test[0], w, test[1], True), works)):
            verdict.ok(f"{what}: mutants ran one at a time, since its self-test failed beside copies of itself")
            return survivors(work, live, lambda _m: test, tap=True)
        verdict.ok(f"{what}: mutants ran {jobs} at a time")
        shares = pool.map(lambda i: survivors(works[i], live[i::jobs], lambda _m: test, tap=True), range(jobs))
        lived = {id(m) for share in shares for m in share}
    return [m for m in live if id(m) in lived]


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
    its absolute path, or by its path in the repo when the coverage run kept relative_files. A run
    with --cov-branch records arcs in place of lines, and an arc's positive ends are the lines run."""
    from coverage.numbits import numbits_to_nums  # noqa: PLC0415 — only the Python runner needs coverage
    lines = (
        "select c.context, lb.numbits from line_bits lb join file f on f.id = lb.file_id "
        "join context c on c.id = lb.context_id where f.path in (?, ?)"
    )
    arcs = (
        "select c.context, a.fromno, a.tono from arc a join file f on f.id = a.file_id "
        "join context c on c.id = a.context_id where f.path in (?, ?)"
    )
    runs: set[tuple[str, int]] = set()
    with sqlite3.connect(db) as conn:
        for context, bits in conn.execute(lines, (str(path), relative)):
            runs.update((context, n) for n in numbits_to_nums(bits))
        for context, *ends in conn.execute(arcs, (str(path), relative)):
            runs.update((context, n) for n in ends if n > 0)  # mutation: equivalent — line 0 holds no code, so no mutant sits on it
    out: dict[int, list[str]] = {}
    for context, n in sorted(runs):
        node = context.split("|")[0]
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


CALC = 'def over(a, b):\n    """Whether a is\n    more than b, not equal."""\n    return a > b\n\n\ndef unused(a):\n    return a + 1\n'


WEAK_TEST = "from calc import over\n\n\ndef test_over():\n    assert over(5, 3)\n    assert not over(1, 3)\n"


READS_ABOVE_SH = """#!/usr/bin/env bash
self_test() {
  [ -f ../data.txt ] && printf 'ok 1 - x\\n1..1\\n'
}
[ "${1:-}" = --self-test ] && self_test
"""


SILENT_SH = """#!/usr/bin/env bash
self_test() {
  printf 'ok 1 - x\\n1..1\\n'
}
[ "${1:-}" = --self-test ] && self_test
"""


WEAK_SH = """#!/usr/bin/env bash
big() { [ "$1" -gt 9 ]; }
small() { [ "$1" -lt 3 ]; }
self_test() {
  big 10 && ! big 9 && echo 'ok 1 - big' || echo 'not ok 1 - big'
  small 1 && echo 'ok 2 - small' || echo 'not ok 2 - small'
  echo 1..2
}
[ "${1:-}" = --self-test ] && self_test
"""


COLLIDES_SH = """#!/usr/bin/env bash
big() { [ "$1" -gt 9 ]; }
self_test() {
  local d="/tmp/change_gate_collides.$PPID"  # a fixed path, outside the TMPDIR each run has
  mkdir "$d" 2>/dev/null || { echo 'not ok 1 - alone'; echo 1..1; return; }
  sleep 0.2
  big 10 && ! big 9 && echo 'ok 1 - big' || echo 'not ok 1 - big'
  rmdir "$d"; echo 1..1
}
[ "${1:-}" = --self-test ] && self_test
"""


def self_test_side_by_side(t: Tap) -> None:
    from change_gate import parse
    t.check(parse([]).jobs == (os.cpu_count() or 1) and parse(["--jobs", "3"]).jobs == 3,
            "mutants run one per core unless --jobs says how many")
    for bad in ("0", "x", "-1"):
        status, out = self_test_run(Path("."), "--jobs", bad)
        t.check(status == 2 and "--jobs takes a whole number above 0" in out, f"--jobs {bad} is a usage error", out)
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        self_test_parallel(t, repo)
        self_test_collides(t, repo)


def self_test_parallel(t: Tap, repo: Path) -> None:
    self_test_files(repo, {"w.sh": WEAK_SH})
    (repo / "gone").symlink_to(repo / "nowhere")
    status, two = self_test_run(repo, "--check", "mutation", "--jobs", "2")
    _, one = self_test_run(repo, "--check", "mutation", "--jobs", "1")
    lived = [line for line in two.splitlines() if "w.sh:" in line and "→" in line]
    t.check(status == 1 and "w.sh: mutants ran 2 at a time" in two and len(lived) == 1 and "-lt 3" in lived[0],
            "mutants run side by side, a dangling link copied as a link, and the one the test misses lives", two)
    t.check([x for x in two.splitlines() if "at a time" not in x] == one.splitlines() and "at a time" not in one,
            "side by side and one at a time reach the same verdict", two, one)


def self_test_collides(t: Tap, repo: Path) -> None:
    self_test_files(repo, {"w.sh": COLLIDES_SH})
    status, out = self_test_run(repo, "--check", "mutation", "--jobs", "2")
    t.check(status == 0 and "w.sh: mutants ran one at a time, since its self-test failed beside copies of itself" in out,
            "a self-test that collides with a copy of itself runs its mutants one at a time, and passes", out)


def self_test_scripts(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = self_test_repo(Path(tmp))
        self_test_files(repo, {"s.sh": SILENT_SH})
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 0 and "s.sh: 1 mutants, 1 killed" in out,
                "a mutant that silences the self-test is killed: exit 0 with no plan is not a pass", out)
        self_test_files(repo, {"bin/r.sh": READS_ABOVE_SH, "data.txt": "x\n"})
        status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 0 and "bin/r.sh: 1 mutants, 1 killed" in out,
                "a self-test reading a file outside its script's folder finds it in the copy", out)
        self_test_files(repo, {"s.sh": SILENT_SH})
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
        strong = WEAK_TEST + "    assert not over(3, 3)\n\n\ndef test_unused():\n    assert unused(1) == 2\n"
        self_test_files(repo, {"calc.py": CALC, "tests/test_calc.py": strong.replace("import over", "import over, unused")})
        branch = Path(tmp) / "branch.coverage"
        subprocess.run(["env", f"COVERAGE_FILE={branch}", "python3", "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests",
                        "--cov", "--cov-branch", "--cov-context=test", "--cov-report="], cwd=repo, capture_output=True, check=False)
        status, out = self_test_run(repo, "--check", "mutation", "--test", "python=python3 -m pytest tests", "--coverage", str(branch))
        t.check(status == 0 and "python: 3 mutants, 3 killed" in out,
                "a reused --cov-branch coverage file, which records arcs, names the tests behind each line", out)
        self_test_files(repo, {"calc.py": CALC, "tests/test_calc.py": WEAK_TEST, "tests/test_broken.py": "def test_broken():\n    assert False\n"})
        status, out = self_test_run(repo, "--check", "mutation", "--test", "python=python3 -m pytest tests", "--coverage", str(db))
        t.check(status == 1 and "calc.py:4: return a > b  →  return a >= b" in out,
                "a reused coverage file reruns only the tests covering the changed lines, so an unrelated failure is not run", out)
        self_test_files(repo, {"calc.py": CALC, "tests/test_calc.py": WEAK_TEST.replace("assert not over(1, 3)", "assert not over(1, 3) and False")})
        status, out = self_test_run(repo, "--check", "mutation", "--test", "python=python3 -m pytest tests", "--coverage", str(db))
        t.check(status == 1 and "fails before any mutation" in out,
                "with a reused coverage file, covering tests that fail unmutated still fail the gate", out)

def self_test() -> int:
    from change_gate import self_test as whole

    return whole()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
