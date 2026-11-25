#!/usr/bin/env python3
"""change_gate_complexity.py — change_gate.py's the complexity check: lizard's count, and the shell count change_gate makes itself.

Imported, never run; ``python3 change_gate_complexity.py --self-test`` runs change_gate's whole
suite: the parts are one tool, and the cases that pin one part sit beside another.
"""

import csv
import io
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402
from change_gate_base import Change, LIZARD, MAX_CCN, MEASURED, Verdict, block_end, missing, self_test_env, self_test_files, self_test_run, shell_code, test_region  # noqa: E402


# ---------------------------------------------------------------- complexity

def over_limit(csv_text: str) -> list[str]:
    """lizard --csv rows whose CCN is above the cap, as file:line name (CCN n). A row's long name
    holds commas inside quotes, so the rows are read as CSV, never split on commas."""
    rows = [r for r in csv.reader(io.StringIO(csv_text)) if r]
    return [f"{r[6]}:{r[9]} {r[7]} (CCN {r[1]})" for r in rows if int(r[1]) > MAX_CCN]


SHELL_FUNC = re.compile(r"^(\s*)(?:function\s+([\w:.-]+)\s*(?:\(\s*\))?|([\w:.-]+)\s*\(\s*\))\s*\{")


SHELL_BRANCH = re.compile(r"\b(?:if|elif|while|until|for)\b|&&|\|\||;;&?|;&")


def shell_functions(lines: list[str]) -> list[tuple[str, int, int]]:
    """Each function as (name, first line, last line), 1-based."""
    found = []
    for i, line in enumerate(lines):
        if m := SHELL_FUNC.match(line):
            found.append((m[2] or m[3], i + 1, block_end(lines, i, m[1], "shell")))
    return found


def shell_ccn(code: list[str], span: tuple[int, int], inner: list[tuple[int, int]]) -> int:
    own = set(range(span[0], span[1] + 1))
    for first, last in inner:
        own -= set(range(first, last + 1))
    return 1 + sum(len(SHELL_BRANCH.findall(code[n - 1])) for n in own)


def shell_over_limit(path: str, text: str) -> list[str]:
    """The shell functions above the cap, as file:line name (CCN n); a self-test is skipped."""
    lines = text.splitlines()
    tests = test_region(lines, "shell")
    funcs = shell_functions(lines)
    code = shell_code(text)
    over = []
    for name, first, last in funcs:
        if first in tests or name.endswith("self_test"):
            continue
        inner = [(f, e) for _, f, e in funcs if f in range(first + 1, last)]
        ccn = shell_ccn(code, (first, last), inner)
        if ccn > MAX_CCN:
            over.append(f"{path}:{first} {name} (CCN {ccn})")
    return over


def lizard_over_limit(repo: Path, paths: list[str], verdict: Verdict) -> list[str] | None:
    """lizard's functions above the cap, or None once it has failed the verdict."""
    if not paths:
        return []
    if missing("uvx", verdict, "the complexity check"):
        return None
    run = subprocess.run([*LIZARD, "--csv", *paths], cwd=repo, capture_output=True, text=True)
    if run.returncode != 0:
        verdict.fail(f"lizard exited {run.returncode}", *run.stderr.splitlines()[-5:])
        return None
    return over_limit(run.stdout)


def check_complexity(repo: Path, files: list[Change], verdict: Verdict) -> None:
    print(f"== complexity: no function above CCN {MAX_CCN}")
    shell = [c.path for c in files if c.language == "shell"]
    measured = [c.path for c in files if c.language in MEASURED]
    if not shell and not measured:
        return verdict.ok("no changed file in a measured language")
    over = lizard_over_limit(repo, measured, verdict)
    if over is None:
        return None
    for path in shell:
        over += shell_over_limit(path, (repo / path).read_text(errors="replace"))
    if over:
        return verdict.fail(f"{len(over)} functions above CCN {MAX_CCN}", *over)
    return verdict.ok(f"{len(shell) + len(measured)} files, every function at CCN {MAX_CCN} or under")


def self_test_complexity(t: Tap, repo: Path) -> None:
    self_test_files(repo, {"a.py": "x = 1\n", "s.sh": "echo\n"})
    over = '4,12,19,2,4,"f","a.py","f","f ( x )",1,4'
    with self_test_env(FAKE_UVX_CSV=over):
        status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 1 and "a.py:1 f (CCN 12)" in out, "a function above CCN 10 fails the gate", out)
    with self_test_env(FAKE_UVX_CSV=over.replace(",12,", ",10,")):
        status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 0 and "2 files, every function" in out, "a function at CCN 10 passes, and shell is measured beside it", out)
    with self_test_env(FAKE_UVX_FAIL="1"):
        status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 1 and "lizard exited 1" in out, "a lizard that fails fails the gate", out)
    self_test_files(repo, {"s.clj": "(def x 1)\n"})
    status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 0 and "no changed file in a measured language" in out, "a change in no measured language passes", out)
    self_test_files(repo, {"s.sh": SHELL_CCN.format(branches=" && ".join(["a"] * 11))})
    status, out = self_test_run(repo, "--check", "complexity")
    t.check(status == 1 and "s.sh:2 busy (CCN 11)" in out, "a shell function above CCN 10 fails the gate, with no lizard", out)


SHELL_CCN = """#!/usr/bin/env bash
busy() {{
  {branches}
}}
"""


def self_test_shell_ccn(t: Tap) -> None:
    def over(text: str) -> list[str]:
        return shell_over_limit("s.sh", text)
    ten = " && ".join(["a"] * 11)
    t.check(over(SHELL_CCN.format(branches=ten)) == ["s.sh:2 busy (CCN 11)"],
            "ten && make CCN 11, one over the cap", *over(SHELL_CCN.format(branches=ten)))
    t.check(over(SHELL_CCN.format(branches=" && ".join(["a"] * 10))) == [], "nine && make CCN 10, at the cap")
    kinds = "if a; then b; elif c; then d; fi\n  while a; do b; done\n  until a; do b; done\n  for x in y; do z; done\n  a || b\n  case $x in a) b ;; c) d ;& e) f ;;& esac\n  a && b && c"
    t.check(over(SHELL_CCN.format(branches=kinds)) == ["s.sh:2 busy (CCN 12)"],
            "if, elif, while, until, for, ||, && and each case arm count one", *over(SHELL_CCN.format(branches=kinds)))
    quoted = "echo '&& && && && && && && && && &&' \"|| || || || || || || || || ||\" # && && && && && && && && && &&"
    t.check(over(SHELL_CCN.format(branches=quoted)) == [], "&& and || in quotes or a comment are not counted")
    spanning = "awk '\n    " + ten + "\n  ' f\n  echo \"\n    " + ten + "\n  \""
    t.check(over(SHELL_CCN.format(branches=spanning)) == [], "&& in a quote that spans lines, as an awk program, is not counted",
            *over(SHELL_CCN.format(branches=spanning)))
    heredoc = "cat <<EOF && a | jq '.a && .b'\n  don't\nEOF\n  " + ten
    t.check(over(SHELL_CCN.format(branches=heredoc)) == ["s.sh:2 busy (CCN 12)"],
            "a heredoc's body is text, an apostrophe in it opens no quote, and its opening line is code but for its quotes",
            *over(SHELL_CCN.format(branches=heredoc)))
    apostrophes = "# don't\n  echo it\\'s\n  " + ten
    t.check(over(SHELL_CCN.format(branches=apostrophes)) == ["s.sh:2 busy (CCN 11)"],
            "an apostrophe in a comment or escaped opens no quote", *over(SHELL_CCN.format(branches=apostrophes)))
    nested = "inner() {\n    " + ten + "\n  }\n  a && b"
    t.check(over(SHELL_CCN.format(branches=nested)) == ["s.sh:3 inner (CCN 11)"],
            "a nested function counts its own lines, and its outer function leaves them out", *over(SHELL_CCN.format(branches=nested)))
    t.check(over("f() { " + ten + "; }\n") == ["s.sh:1 f (CCN 11)"], "a one-line function is counted", *over("f() { " + ten + "; }\n"))
    t.check(over("function g {\n  " + ten + "\n}\n") == ["s.sh:1 g (CCN 11)"], "a function declared with the function keyword is counted")
    tests = ("self_test() {\n  " + ten + "\n}\ncsu_self_test() {\n  " + ten
             + "\n}\nif [ \"$1\" = --self-test ]; then\n  h() { " + ten + "; }\nfi\n")
    t.check(over(tests) == [], "a self-test is not counted: self_test, a name ending in it, or the --self-test block", *over(tests))

def self_test() -> int:
    from change_gate import self_test as whole

    return whole()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
