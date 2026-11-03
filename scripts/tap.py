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
and where the code under test prints.
"""

import contextlib
import io
import sys


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
    return t.end()


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
