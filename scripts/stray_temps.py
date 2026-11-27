#!/usr/bin/env python3
"""stray_temps.py — the entries of a temp folder a user left: stale, unheld, and which of them only a temp maker names.

An entry is stale when the user owns it, it holds something to reclaim, nothing
in it changed for STALE_DAYS days, and none of the user's processes works in it
or holds a file in it. A hidden entry is a convention's, such as the display's
lock, so it is never one. It is removable when its name is one only a temp
maker gives: tempfile's tmp prefix and random part, with any suffix, or
mktemp's default. stray_sweep.py reports them and removes the removable.

Imported, never run; ``python3 stray_temps.py --self-test`` checks it.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import time
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

STALE_DAYS = 7
DAY = 86400
MADE_BY_TEMP_MAKER = re.compile(r"tmp[a-z0-9_]{8}(?:\.[\w.-]+)?|tmp\.[A-Za-z0-9]{10}")


@dataclass(frozen=True)
class Entry:
    path: Path
    size: int
    newest: float
    removable: bool


def held_paths(pids: Iterable[int]) -> set[str]:
    """Every folder a process works in and every file it holds open, of the processes given."""
    held = set()
    for pid in pids:
        d = Path(f"/proc/{pid}")
        try:
            held.add(os.readlink(d / "cwd"))
            held.update(os.readlink(d / "fd" / fd) for fd in os.listdir(d / "fd"))
        except OSError:
            continue
    return held


def measure(path: Path) -> tuple[int, float]:
    """Bytes on disk under path, itself included, and the newest change to anything in it."""
    top = path.lstat()
    size, newest = top.st_blocks * 512, top.st_mtime
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            s = os.lstat(os.path.join(root, name))
            size, newest = size + s.st_blocks * 512, max(newest, s.st_mtime)
    return size, newest


def in_use(path: Path, held: set[str]) -> bool:
    return any(h == str(path) or h.startswith(f"{path}/") for h in held)


def judged(path: Path, held: set[str], now: float) -> Entry | None:
    """The entry when it is stale: something to reclaim, unchanged for a week, held by none."""
    try:
        size, newest = measure(path)
    except OSError:
        return None
    if size and now - newest >= STALE_DAYS * DAY and not in_use(path, held):
        return Entry(path, size, newest, bool(MADE_BY_TEMP_MAKER.fullmatch(path.name)))
    return None


def stale_temps(root: Path, uid: int, pids: Iterable[int], now: float) -> list[Entry]:
    """The user's stale entries under root, largest first and then by name, held by none of
    pids, the user's processes; a hidden one is a convention's."""
    held = held_paths(pids)
    owned = (p for p in root.iterdir() if p.lstat().st_uid == uid and not p.name.startswith("."))
    return sorted(filter(None, (judged(p, held, now) for p in owned)), key=lambda e: (-e.size, e.path.name))


def remove(entries: Iterable[Entry]) -> list[Entry]:
    """The removable entries, each removed; the rest are kept."""
    gone = []
    for e in (e for e in entries if e.removable):
        if e.path.is_dir() and not e.path.is_symlink():
            shutil.rmtree(e.path)
        else:
            e.path.unlink()
        gone.append(e)
    return gone


# ---------------------------------------------------------------- self-test


def self_test() -> int:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from tap import Tap, scratch

    t = Tap()
    with scratch() as d:
        root = Path(d) / "tmp"
        self_test_temps(t, root, self_test_tree(root))
    return t.end()


def self_test_tree(root: Path) -> int:
    """Temp entries a week stale, fresh, held, hidden and empty, the kept `work` the largest;
    the clock they were judged by."""
    now = int(time.time())
    old = now - STALE_DAYS * DAY
    stale = ("tmpab_12cd9", "tmp.AbCdEfGh12", "work", "tmpfresh0_1", "tmpheld0__1", "tmp.Recent0000")
    for name in (*stale, ".X0-lock", "tmpq_8rt0ax.ci_gate", "tmpshort"):
        (root / name / "sub").mkdir(parents=True)
        (root / name / "sub" / "f").write_text("x" * 5000)
    (root / "work" / "sub" / "g").write_text("x" * 5000)
    (root / "tmploose0_1").write_text("y")
    (root / "uv-0a.lock").write_text("")
    for path in root.rglob("*"):
        os.utime(path, (old, old))
    os.utime(root / "tmp.Recent0000" / "sub" / "f", (old + 1, old + 1))
    os.utime(root / "tmpfresh0_1", (now, now))
    return now


def self_test_temps(t, root: Path, now: int) -> None:
    with open(root / "tmpheld0__1" / "sub" / "f"):
        stale = stale_temps(root, os.getuid(), [os.getpid()], now)
    t.check(
        sorted(e.path.name for e in stale)
        == ["tmp.AbCdEfGh12", "tmpab_12cd9", "tmploose0_1", "tmpq_8rt0ax.ci_gate", "tmpshort", "work"],
        "an entry is stale once nothing in it changed for a week and no process given holds it;"
        " a hidden one and an empty file are not",
        repr(sorted(e.path.name for e in stale)),
    )
    t.check(
        sorted(e.path.name for e in stale if e.removable)
        == ["tmp.AbCdEfGh12", "tmpab_12cd9", "tmploose0_1", "tmpq_8rt0ax.ci_gate"],
        "only a name a temp maker gives is removable, a suffix included",
    )
    self_test_order(t, stale)
    gone = remove(stale)
    t.check(
        sorted(p.name for p in root.iterdir())
        == [".X0-lock", "tmp.Recent0000", "tmpfresh0_1", "tmpheld0__1", "tmpshort", "uv-0a.lock", "work"]
        and len(gone) == 4,
        "removing takes the removable, folders and files, and keeps the rest",
    )
    t.check(not in_use(root / "tmpab", {str(root / "tmpab_12cd9")}), "a held path's prefix is not the path")
    try:
        stale[0].__setattr__("size", 0)
        t.check(False, "an entry judged is never changed")
    except AttributeError:
        t.check(True, "an entry judged is never changed")


def self_test_order(t, stale: list[Entry]) -> None:
    t.check(
        [e.path.name for e in stale]
        == ["work", "tmp.AbCdEfGh12", "tmpab_12cd9", "tmpq_8rt0ax.ci_gate", "tmpshort", "tmploose0_1"]
        and stale[0].size > stale[1].size >= 5000,
        "largest first, sized on disk, and an equal size by name",
        repr([(e.path.name, e.size) for e in stale]),
    )


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(__doc__)
