#!/usr/bin/env python3
"""What every Python self-test prints: TAP, as tap.sh prints it for shell.

Usage:
    tap.py --self-test

    t = Tap()
    t.check(cond, "<name>", "<detail>", ...)
    return t.end()

Each check prints `ok N - <name>` or `not ok N - <name>` and, on a miss,
its details as `# ` lines; end prints the plan `1..N` and returns the exit
status, 0 when every case held, else 1. tap.sh states what a name must be
and where the code under test prints. project(folder) makes a fixture
folder a project, as tap.sh's tap_project does. `with scratch():` around a
self-test removes every temp folder it makes, in Python or in a process it
starts, which the sweep holds it to.
"""

import contextlib
import io
import os
import sys
import tempfile


class Tap:
    def __init__(self):
        self.n = 0
        self.failed = 0

    def check(self, cond: bool, name: str, *detail: str) -> bool:
        self.n += 1
        print(f"{'ok' if cond else 'not ok'} {self.n} - {name}")
        if not cond:
            self.failed += 1
            for line in "\n".join(detail).splitlines():
                print(f"# {line}")
        return cond

    def end(self) -> int:
        print(f"1..{self.n}")
        return 1 if self.failed else 0


def project(folder: str) -> str:
    """folder made a project as project_init.sh marks one; returns folder."""
    os.makedirs(os.path.join(folder, ".claude"), exist_ok=True)
    with open(os.path.join(folder, ".claude", "project"), "w") as f:
        f.write(os.path.basename(os.path.normpath(folder)) + "\n")
    return folder


@contextlib.contextmanager
def scratch():
    """The block's temp folders, Python's and its children's, land in one, removed after."""
    saved = tempfile.tempdir, os.environ.get("TMPDIR")
    with tempfile.TemporaryDirectory() as d:
        tempfile.tempdir = os.environ["TMPDIR"] = d
        try:
            yield d
        finally:
            tempfile.tempdir = saved[0]
            os.environ.pop("TMPDIR")
            if saved[1] is not None:
                os.environ["TMPDIR"] = saved[1]


def self_test() -> int:
    t = Tap()
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        inner = Tap()
        inner.check(True, "one")
        inner.check(False, "two", "why\nand why")
        status = inner.end()
    t.check(
        out.getvalue() == "ok 1 - one\nnot ok 2 - two\n# why\n# and why\n1..2\n",
        "cases are numbered, details follow theirs, the plan comes last",
        out.getvalue(),
    )
    t.check(status == 1, "a failed case makes the run exit 1")
    with contextlib.redirect_stdout(io.StringIO()):
        held = Tap()
        held.check(True, "one")
        status = held.end()
    t.check(status == 0, "a run whose cases all held exits 0")
    with tempfile.TemporaryDirectory() as d:
        project(os.path.join(d, "p"))
        with open(os.path.join(d, "p", ".claude", "project")) as f:
            t.check(f.read() == "p\n", "a fixture project is marked with its name")
        t.check(project(os.path.join(d, "p")) == os.path.join(d, "p"),
                "a folder already marked is marked again")
    self_test_scratch(t)
    return t.end()


def self_test_scratch(t: Tap) -> None:
    import subprocess

    before = os.environ.get("TMPDIR"), tempfile.tempdir
    with scratch() as d:
        made = tempfile.mkdtemp()
        child = subprocess.run(["mktemp", "-d"], capture_output=True, text=True).stdout.strip()
        t.check(os.path.dirname(made) == d == os.path.dirname(child),
                "a temp folder made in Python or by a child lands in the scratch folder", made, child)
    t.check(not os.path.exists(d), "and the scratch folder is removed after")
    t.check((os.environ.get("TMPDIR"), tempfile.tempdir) == before, "TMPDIR is as it was")
    os.environ["TMPDIR"] = outer = tempfile.mkdtemp()
    try:
        with scratch():
            pass
        t.check(os.environ["TMPDIR"] == outer, "a TMPDIR set before is kept")
    finally:
        os.environ.pop("TMPDIR")
        os.rmdir(outer)
        if before[0] is not None:
            os.environ["TMPDIR"] = before[0]


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__.strip())
        sys.exit(0)
    sys.exit(__doc__)
