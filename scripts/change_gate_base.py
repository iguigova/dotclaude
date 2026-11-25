#!/usr/bin/env python3
"""change_gate_base.py — change_gate.py's the files a change touched, the verdicts, and how a line's code is read apart from its text and its tests.

Imported, never run; ``python3 change_gate_base.py --self-test`` runs change_gate's whole
suite: the parts are one tool, and the cases that pin one part sit beside another.
"""

import contextlib
import dataclasses
import functools
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402




LIZARD = ["uvx", "lizard==1.26.0"]


# Stryker's TypeScript support imports typescript from beside Stryker itself, and
# npx skips installing a package the current folder already has, so npx runs
# from outside the repo with both, and its command changes into the repo.
STRYKER = ["npx", "-y", "-p", "@stryker-mutator/core@10.1.1", "-p", "typescript@5.5.4", "-c"]


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
    """The lines each file adds or changes since base, untracked files
    included. The worktree is staged into a scratch index, never the repo's
    own, so a move is seen as one whether or not git tracks its new path, and
    counts only the lines it edited: moving code is not writing it."""
    with tempfile.TemporaryDirectory() as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index")}
        run = functools.partial(subprocess.run, cwd=repo, env=env, capture_output=True, text=True, check=True)
        run(["git", "read-tree", base])
        run(["git", "add", "-A", "."])
        found = added_lines(run(["git", "diff", "--cached", "-U0", "--no-color", "--find-renames", base]).stdout)
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


SHELL_TEXT = re.compile(
    r"(?P<head>(?<!<)<<-?\s*(?P<q>['\"]?)(?P<tag>[A-Za-z_]\w*)(?P=q)[^\n]*\n)(?s:.*?)^\s*(?P=tag)$"
    r"|\\.|(?:^|(?<=\s))#[^\n]*|\$'(?:[^'\\]|\\.)*'|'[^']*'|\"(?:[^\"\\]|\\.)*\"",
    re.M,
)


def shell_code(text: str) -> list[str]:
    """Each line with its quoted text, heredoc bodies and comments blanked, a quote that spans lines
    included, as an awk or jq program does. A heredoc's opening line is read as any other line,
    and an escaped character stays code, so \\' opens no quote."""
    def blank(m: re.Match) -> str:
        head = m["head"] or ""
        if m[0].startswith("\\"):
            return m[0]
        return SHELL_TEXT.sub(blank, head) + re.sub(r"[^\n]", " ", m[0][len(head):])
    return SHELL_TEXT.sub(blank, text).splitlines()


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


SHELL_TEST_START = re.compile(r"^(\s*)(self_test\w*\s*\(\)\s*\{|if .*--self-test.*;\s*then\s*$)")


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
    from change_gate import main
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        status = main([str(repo), *args])
    return status, out.getvalue()


def self_test_moves(t: Tap) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        try:
            git(Path(tmp), "rev-parse", "HEAD")
            t.check(False, "a git command that fails raises, never answers empty")
        except subprocess.CalledProcessError:
            t.check(True, "a git command that fails raises, never answers empty")
        repo = self_test_repo(Path(tmp))
        (repo / "a.sh").write_text("".join(f"echo {i}\n" for i in range(20)))
        git(repo, "add", "-A")
        git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "a")
        (repo / "a.sh").rename(repo / "b.sh")
        t.check(changes(repo, "HEAD") == [], "a file moved unedited, untracked at its new path, is no changed code")
        t.check(git(repo, "status", "--porcelain") == " D a.sh\n?? b.sh\n", "and the repo's own index is left as it was",
                git(repo, "status", "--porcelain"))
        git(repo, "add", "-A")
        t.check(changes(repo, "HEAD") == [], "a file moved unedited and staged is no changed code")
        try:
            changes(repo, "no-such-base")
            refused = False
        except subprocess.CalledProcessError:
            refused = True
        t.check(refused, "a base git cannot read is an error, never an empty change")
        (repo / "b.sh").write_text((repo / "b.sh").read_text().replace("echo 3\n", "echo three\n"))
        git(repo, "add", "-A")
        got = changes(repo, "HEAD")
        t.check(got == [Change("b.sh", frozenset({4}))], "a moved file counts only the line the move edited", str(got))


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

def self_test() -> int:
    from change_gate import self_test as whole

    return whole()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
