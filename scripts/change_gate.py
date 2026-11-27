#!/usr/bin/python3
"""change_gate.py — the checks coding_guidelines.md → Verification adds to CI,
on the code a change touched.

  complexity  no function in a changed file has a cyclomatic complexity above
              10, as lizard counts it: Python, JavaScript, TypeScript, Go, Ruby,
              C#, Dart and Rust. Shell is counted here, since lizard reads none: 1,
              plus one for each if, elif, while, until, for, case arm ended
              by ;; and each && or ||, in a function's own lines, its nested
              functions, its quoted text, heredoc bodies and comments left
              out. A quote that spans lines is text to its end, so an awk, jq
              or Python program a function embeds is not counted, and is not
              measured. A self-test's lines are not counted, since `cond &&
              tap_ok || tap_not_ok` is an assertion, as t.check is in Python.
              Clojure and Haskell have no counter and are not measured.
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
                      Mutants run --jobs at a time, one per core unless
                      it says otherwise, each on its own copy, once the
                      unmutated self-test passes in every copy at once;
                      one that fails beside a copy of itself, as a fixed
                      path or port would, runs them one at a time.
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
                      --test js command, else `npm test` when package.json
                      has a test script; with neither, it fails. A turbo
                      command runs in loose env mode and forced, or turbo
                      hides each mutant from the test and replays its cache
  Go                  gremlins --diff, testing with `go test`
  Dart                mutation_test over the changed lines, testing with the
                      --test dart command, else `flutter test` in a Flutter
                      package and `dart test` otherwise
  Rust                cargo-mutants --in-diff once per workspace the changed
                      files build in, as `cargo locate-project --workspace`
                      names it, each over the diff of the files under it.
                      It tests with `cargo test`; a --test rust command, which
                      must be `cargo test …`, passes its options before `--`
                      to every cargo call and the rest to the test binaries.
                      A diff that reaches no function has no mutant and passes
  C#                no runner yet: a changed C# file fails the gate

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

The work is split by part, each module beside this one with its own
--self-test: change_gate_base.py (what changed, verdicts, reading a line's
code), change_gate_complexity.py, change_gate_mutator.py, change_gate_scripts.py
(self-tested scripts, test commands, Python) and change_gate_tools.py (Stryker,
go-gremlins, Dart, cargo-mutants). This file parses the options and dispatches.

Usage:
  change_gate.py [--base REF] [--check complexity|mutation] [--test <language>=<command>]…
                 [--coverage <coverage file>] [--jobs N] [<repo>]
  change_gate.py --self-test

Exit:
  0  every check passed
  1  a check failed (each prints FAIL)
  2  usage error, or not a git repo
"""

import contextlib
import dataclasses
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402
from group_run import stopping_on_signal  # noqa: E402
from change_gate_base import Change, FIXTURE_SH, TEST_FILE, Verdict, changes, default_base, git, is_self_tested, self_test_env, self_test_files, self_test_moves, self_test_repo, self_test_run  # noqa: E402
from change_gate_complexity import check_complexity, over_limit, self_test_shell_ccn  # noqa: E402
from change_gate_mutator import self_test_copies, self_test_edges, self_test_stamps, self_test_masks, self_test_mutants  # noqa: E402
from change_gate_scripts import mutate_python, mutate_self_tested, mutate_with_command, self_test_python, self_test_reuse, self_test_scripts, self_test_side_by_side  # noqa: E402
from change_gate_tools import dart_lived, gremlins_lived, mutate_dart, mutate_go, mutate_js, mutate_rust, self_test_tools, stryker_lived  # noqa: E402


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
        mutate_self_tested(repo, c, options.jobs, verdict)
    for language, group in sorted(by_language.items()):
        run_language(repo, base, language, group, options, verdict)
    return None


NO_COMMAND = {"js": ("and package.json has no test script for `npm test`",)}


def npm_test(repo: Path) -> list[str]:
    """`npm test` when the repo's package.json has a test script, else no command."""
    try:
        scripts = json.loads((repo / "package.json").read_text()).get("scripts")
    except (OSError, ValueError, AttributeError):
        return []
    return ["npm", "test"] if isinstance(scripts, dict) and "test" in scripts else []


def run_language(repo: Path, base: str, language: str, files: list[Change], options: "Options", verdict: Verdict) -> None:
    names, command = ", ".join(c.path for c in files), options.tests.get(language, [])
    if language == "shell":
        return verdict.fail(f"shell: {names} offers no --self-test, so no test can kill a mutant")
    command = command or (npm_test(repo) if language == "js" else [])
    if language in ("ruby", "clojure", "haskell", "js") and not command:
        return verdict.fail(f"{language}: no --test {language}=<command> for {names}", *NO_COMMAND.get(language, ()))
    if language in ("ruby", "clojure", "haskell"):
        return mutate_with_command(repo, files, language, command, verdict)
    runners = {"python": lambda: mutate_python(repo, files, command, options.coverage, verdict),
               "js": lambda: mutate_js(repo, files, command, verdict),
               "go": lambda: mutate_go(repo, base, verdict), "dart": lambda: mutate_dart(repo, files, command, verdict),
               "rust": lambda: mutate_rust(repo, base, files, command, verdict)}
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
    jobs: int = dataclasses.field(default_factory=lambda: os.cpu_count() or 1)


TESTED = ("python", "ruby", "clojure", "haskell", "js", "dart", "rust")


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


def jobs_named(value: str) -> int:
    """A --jobs value, a whole number above 0."""
    if not value.isdigit() or int(value) < 1:
        raise ValueError(f"--jobs takes a whole number above 0, not {value!r}")
    return int(value)


def set_option(options: Options, flag: str, value: str) -> None:
    """Apply one flag that takes a value."""
    if flag == "--test":
        language, command = test_command(value)
        options.tests[language] = command
    elif flag == "--check":
        options.checks = check_named(value)
    elif flag == "--jobs":
        options.jobs = jobs_named(value)
    else:
        setattr(options, flag.removeprefix("--"), value)


VALUED = ("--base", "--check", "--test", "--coverage", "--jobs")


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
        self_test_files(repo, {"a.js": "module.exports = 1\n", "package.json": '{"scripts": {"test": "t"}}'})
        with self_test_env(PATH=str(bare)):
            status, out = self_test_run(repo, "--check", "mutation")
        t.check(status == 1 and "npx is not installed" in out, "a missing tool fails the gate, naming the fix", out)


def self_test() -> int:
    t = Tap()
    self_test_mutants(t)
    self_test_masks(t)
    self_test_edges(t)
    self_test_copies(t)
    self_test_stamps(t)
    self_test_moves(t)
    self_test_reports(t)
    self_test_gate(t)
    self_test_refusals(t)
    self_test_tools(t)
    self_test_python(t)
    self_test_commands(t)
    self_test_reuse(t)
    self_test_scripts(t)
    self_test_side_by_side(t)
    self_test_shell_ccn(t)
    return t.end()

if __name__ == "__main__":
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__)
        sys.exit(0)
    with stopping_on_signal():
        sys.exit(self_test() if sys.argv[1:2] == ["--self-test"] else main(sys.argv[1:]))
