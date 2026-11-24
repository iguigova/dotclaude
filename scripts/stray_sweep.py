#!/usr/bin/env python3
"""stray_sweep.py — report what this user left running or lying around on this machine, and remove the stale temp folders.

Four kinds, each read from /proc and /tmp:

  orphan  a process re-parented to init or the user's systemd, whose session
          leader is gone, at the top of a cgroup scope where every process
          at the top is such an orphan: nothing that started that work is
          left. A browser's crash handler is re-parented too, but its scope
          still holds the browser, so it is not an orphan.
  zombie  a process that ended and whose parent never reaped it, named with
          that parent.
  long    a test or gate process (LONG_TEST) running over LONG_HOURS hours.
  temp    an entry of /tmp this user owns, nothing in it touched for
          STALE_DAYS days, and no process of this user working in it or
          holding a file in it. A hidden entry is a convention's, such as
          the display's lock, and an empty file holds nothing to reclaim, so
          neither is one.

--apply removes the temp entries whose name only a temp maker gives
(tempfile's tmp prefix and its random part, with any suffix; mktemp's
default), and only those: a named folder may be someone's
work, and a process is never killed, since its owner may want it.

Exit 0 nothing is stray, 1 something is and the report names it, 2 usage.

Usage:
  stray_sweep.py                  print what is stray now
  stray_sweep.py --apply          remove the removable temp entries, then print
  stray_sweep.py [--apply] --write FILE
                                  the report into FILE instead, which is
                                  removed when nothing is stray
  stray_sweep.py --self-test
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import time
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

LONG_TEST = re.compile(
    r"pytest|rspec|jest|vitest|flutter_tester|dart test|--self-test|ci_gate|change_gate"
    r"|selftest\.sh|tooling_commit"
)
LONG_HOURS = 1
STALE_DAYS = 7
MADE_BY_TEMP_MAKER = re.compile(r"tmp[a-z0-9_]{8}(?:\.[\w.-]+)?|tmp\.[A-Za-z0-9]{10}")
SYSTEMD_USER = "/usr/lib/systemd/systemd --user"
COMMAND_WIDTH = 100
LISTED = 5
DAY = 86400


@dataclass(frozen=True)
class Proc:
    pid: int
    ppid: int
    sid: int
    uid: int
    state: str
    scope: str
    cpu: float
    age: float
    cmd: str


@dataclass(frozen=True)
class Entry:
    path: Path
    size: int
    newest: float
    removable: bool


# ---------------------------------------------------------------- processes


def read_proc(pid: int, uptime: float, tick: int) -> Proc:
    """One process from /proc; OSError when it ended while being read."""
    d = Path(f"/proc/{pid}")
    comm, rest = (d / "stat").read_text().rsplit(") ", 1)
    f = rest.split()
    cmd = (d / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
    return Proc(
        pid=pid,
        ppid=int(f[1]),
        sid=int(f[3]),
        uid=d.stat().st_uid,
        state=f[0],
        scope=(d / "cgroup").read_text().strip().split(":", 2)[2],
        cpu=(int(f[11]) + int(f[12])) / tick,
        age=uptime - int(f[19]) / tick,
        cmd=cmd or f"[{comm.split(' (', 1)[1]}]",
    )


def read_procs() -> dict[int, Proc]:
    uptime, tick = float(Path("/proc/uptime").read_text().split()[0]), os.sysconf("SC_CLK_TCK")
    procs = {}
    for name in (n for n in os.listdir("/proc") if n.isdigit()):
        try:
            procs[int(name)] = read_proc(int(name), uptime, tick)
        except OSError:
            continue
    return procs


def orphaned(procs: dict[int, Proc], p: Proc) -> bool:
    adopters = {1} | {q.pid for q in procs.values() if q.cmd.startswith(SYSTEMD_USER)}
    return p.ppid in adopters and p.sid not in procs and p.sid != 0


def scopes(procs: dict[int, Proc], uid: int) -> list[list[Proc]]:
    """The user's processes, grouped by the cgroup scope each runs in."""
    grouped = defaultdict(list)
    for p in (p for p in procs.values() if p.uid == uid):
        grouped[p.scope].append(p)
    return list(grouped.values())


def tops(procs: dict[int, Proc], members: list[Proc]) -> list[Proc]:
    """The members whose parent runs in another scope, or is gone."""
    return [p for p in members if getattr(procs.get(p.ppid), "scope", None) != p.scope]


def orphans(procs: dict[int, Proc], uid: int) -> list[Proc]:
    """The orphans at the top of each scope whose every top process is one."""
    found = []
    for top in (tops(procs, members) for members in scopes(procs, uid)):
        if all(orphaned(procs, p) for p in top):
            found += top
    return found


def zombies(procs: dict[int, Proc], uid: int) -> list[Proc]:
    return [p for p in procs.values() if p.uid == uid and p.state == "Z"]


def long_tests(procs: dict[int, Proc], uid: int) -> list[Proc]:
    return [
        p
        for p in procs.values()
        if p.uid == uid and p.age > LONG_HOURS * 3600 and LONG_TEST.search(p.cmd)
    ]


# ---------------------------------------------------------------- temp


def held_paths(procs: Iterable[Proc]) -> set[str]:
    """Every folder a process works in and every file it holds open, of the processes given."""
    held = set()
    for p in procs:
        d = Path(f"/proc/{p.pid}")
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


def stale_temps(root: Path, uid: int, procs: dict[int, Proc], now: float) -> list[Entry]:
    """The user's stale entries under root, largest first; a hidden one is a convention's."""
    held = held_paths(p for p in procs.values() if p.uid == uid)
    owned = (p for p in root.iterdir() if p.lstat().st_uid == uid and not p.name.startswith("."))
    return sorted(filter(None, (judged(p, held, now) for p in owned)), key=lambda e: -e.size)


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


# ---------------------------------------------------------------- report


def human(size: int) -> str:
    for unit in ("B", "K", "M", "G"):
        if size < 1024 or unit == "G":
            return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024
    return ""  # mutation: equivalent — the loop returns at G


def below(procs: dict[int, Proc], pid: int) -> list[Proc]:
    """Every process descended from pid, nearest first."""
    found, frontier = [], [pid]
    while frontier:
        children = [p for p in procs.values() if p.ppid in frontier]
        found, frontier = found + children, [p.pid for p in children]
    return found


def proc_line(kind: str, p: Proc, procs: dict[int, Proc]) -> str:
    share = 100 * p.cpu / max(p.age, 1)
    line = f"{kind:7} {p.pid:>7}  {p.age / DAY:.1f}d  cpu {share:.0f}%  {p.cmd[:COMMAND_WIDTH]}"
    if kind == "orphan" and (under := below(procs, p.pid)):
        line += f"  (+{len(under)} below, {under[0].pid}: {under[0].cmd[:COMMAND_WIDTH]})"
    if kind == "zombie":
        line += f"  (parent {p.ppid}: {getattr(procs.get(p.ppid), 'cmd', '?')[:COMMAND_WIDTH]})"
    return line


def counted(entries: list[Entry]) -> str:
    return f"{len(entries)}, {human(sum(e.size for e in entries))}"


def removal_lines(kept: list[Entry], gone: list[Entry]) -> list[str]:
    """What --apply removed, or would remove from what is kept."""
    removable, lines = [e for e in kept if e.removable], []
    if gone:
        lines.append(f"        removed {counted(gone)}: made by a temp maker")
    if removable:
        lines.append(f"        removable by --apply: {counted(removable)}")
    return lines


def temp_lines(stale: list[Entry], gone: list[Entry]) -> list[str]:
    kept = [e for e in stale if e not in gone]
    head = f"temp    {len(stale)} entries of /tmp untouched for {STALE_DAYS}+ days, {human(sum(e.size for e in stale))}"
    listed = [f"        {human(e.size):>7}  {e.path}" for e in kept[:LISTED]]
    return [head, *removal_lines(kept, gone), *listed] if stale else []


def report(procs: dict[int, Proc], uid: int, stale: list[Entry], gone: list[Entry]) -> str:
    """Every stray, one line each; empty when nothing is stray, the removed alone not counting."""
    kinds = [("orphan", orphans(procs, uid)), ("zombie", zombies(procs, uid)), ("long", long_tests(procs, uid))]
    lines = [proc_line(kind, p, procs) for kind, found in kinds for p in found]
    lines += temp_lines(stale, gone)
    if not any(found for _, found in kinds) and all(e in gone for e in stale):
        return ""
    when = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    return f"stray_sweep {when}: what this user left on this machine\n" + "\n".join(lines) + "\n"


def write(text: str, out: Path | None) -> None:
    if out is None:
        print(text, end="")
    elif text:
        out.write_text(text)
    else:
        out.unlink(missing_ok=True)


def main(argv: list[str]) -> int:
    apply, out = "--apply" in argv, None
    rest = [a for a in argv if a != "--apply"]
    if rest[:1] == ["--write"] and len(rest) == 2:
        out = Path(rest[1])
    elif rest:
        print(__doc__, file=sys.stderr)
        return 2
    procs, uid = read_procs(), os.getuid()
    stale = stale_temps(Path("/tmp"), uid, procs, time.time())
    gone = remove(stale) if apply else []
    text = report(procs, uid, stale, gone)
    write(text, out)
    return 1 if text else 0


# ---------------------------------------------------------------- self-test


def self_test() -> int:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from tap import Tap, scratch

    t = Tap()
    with scratch() as d:
        self_test_procs(t, self_test_table())
        self_test_lines(t, self_test_table())
        self_test_temps(t, Path(d), self_test_tree(Path(d) / "tmp"))
        self_test_live(t, Path(d))
    return t.end()


def self_test_table() -> dict[int, Proc]:
    """A browser beside its crash handler, two abandoned scopes, and what is not stray."""

    def p(pid, ppid, sid, scope, cmd="x", state="S", age=7200.0, uid=1000):
        return Proc(pid, ppid, sid, uid, state, scope, age / 2, age, cmd)

    rows = (
        p(1, 0, 1, "/init.scope", "init"),
        p(10, 1, 10, "/user", SYSTEMD_USER),
        p(20, 10, 20, "/app-browser", "browser"),
        p(21, 10, 999, "/app-browser", "crash handler"),
        p(30, 10, 998, "/run-a", "bash -c serve"),
        p(31, 30, 31, "/run-a", "python3 -m http.server"),
        p(40, 1, 997, "/run-b", "loop"),
        p(50, 10, 50, "/run-c", "leader of its own session"),
        p(60, 10, 996, "/run-d", "someone else's", uid=0),
        p(70, 20, 20, "/app-browser", "gone", state="Z"),
        p(80, 20, 20, "/app-browser", "pytest -n 8", age=3601),
        p(81, 20, 20, "/app-browser", "pytest -n 8", age=3600),
        p(82, 20, 20, "/app-browser", "vim", age=9000),
    )
    return {row.pid: row for row in rows}


def self_test_procs(t, procs: dict[int, Proc]) -> None:
    t.check(
        [q.pid for q in orphans(procs, 1000)] == [30, 40],
        "an orphan whose scope holds nothing else at its top is reported, and adopted by init too;"
        " a crash handler beside its live browser, a session leader and another user's are not",
        repr([q.pid for q in orphans(procs, 1000)]),
    )
    t.check([q.pid for q in zombies(procs, 1000)] == [70], "a zombie is reported")
    t.check(
        [q.pid for q in long_tests(procs, 1000)] == [80],
        "a test past an hour is reported, one at the hour and a long editor are not",
    )
    t.check([q.pid for q in below(procs, 10)][:4] == [20, 21, 30, 50], "below lists the nearest first")
    try:
        procs[1].__setattr__("pid", 2)
        t.check(False, "a process read is never changed")
    except AttributeError:
        t.check(True, "a process read is never changed")


def self_test_lines(t, procs: dict[int, Proc]) -> None:
    text = report(procs, 1000, [], [])
    lines = text.splitlines()
    t.check(
        "orphan       30  0.1d  cpu 50%  bash -c serve  (+1 below, 31: python3 -m http.server)" in lines
        and "orphan       40  0.1d  cpu 50%  loop" in lines,
        "an orphan names what runs below it, and no parent",
        text,
    )
    t.check("zombie       70  0.1d  cpu 50%  gone  (parent 20: browser)" in lines, "a zombie names its parent", text)
    calm = {q.pid: q for q in procs.values() if q.pid in (1, 10, 20, 50)}
    t.check(report(calm, 1000, [], []) == "", "nothing stray reports nothing")
    t.check(
        (human(512), human(1023), human(1024), human(5 * 1024**4)) == ("512B", "1023B", "1.0K", "5120.0G"),
        "sizes read in the largest unit under 1024, up to G",
    )


def self_test_tree(root: Path) -> int:
    """Temp entries a week stale, fresh, held, hidden and empty; the clock they were judged by."""
    now = int(time.time())
    old = now - STALE_DAYS * DAY
    stale = ("tmpab_12cd9", "tmp.AbCdEfGh12", "work", "tmpfresh0_1", "tmpheld0__1", "tmp.Recent0000")
    for name in (*stale, ".X0-lock", "tmpq_8rt0ax.ci_gate", "tmpshort"):
        (root / name / "sub").mkdir(parents=True)
        (root / name / "sub" / "f").write_text("x" * 5000)
    (root / "tmploose0_1").write_text("y")
    (root / "uv-0a.lock").write_text("")
    for path in root.rglob("*"):
        os.utime(path, (old, old))
    os.utime(root / "tmp.Recent0000" / "sub" / "f", (old + 1, old + 1))
    os.utime(root / "tmpfresh0_1", (now, now))
    return now


def self_test_temps(t, d: Path, now: int) -> None:
    root, procs = d / "tmp", read_procs()
    with open(root / "tmpheld0__1" / "sub" / "f"):
        stale = stale_temps(root, os.getuid(), procs, now)
    t.check(
        sorted(e.path.name for e in stale)
        == ["tmp.AbCdEfGh12", "tmpab_12cd9", "tmploose0_1", "tmpq_8rt0ax.ci_gate", "tmpshort", "work"],
        "an entry is stale once nothing in it changed for a week and none of this user's processes"
        " holds it; a hidden one and an empty file are not",
        repr(sorted(e.path.name for e in stale)),
    )
    t.check(
        sorted(e.path.name for e in stale if e.removable)
        == ["tmp.AbCdEfGh12", "tmpab_12cd9", "tmploose0_1", "tmpq_8rt0ax.ci_gate"],
        "only a name a temp maker gives is removable, a suffix included",
    )
    t.check(stale[0].size >= 5000 and stale[-1].path.name == "tmploose0_1", "largest first, sized on disk")
    self_test_report(t, stale, report({}, 1000, stale, []))
    gone = remove(stale)
    t.check(
        sorted(p.name for p in root.iterdir())
        == [".X0-lock", "tmp.Recent0000", "tmpfresh0_1", "tmpheld0__1", "tmpshort", "uv-0a.lock", "work"],
        "--apply removes the removable, folders and files, and keeps the rest",
    )
    self_test_report(t, stale, report({}, 1000, stale, gone))
    t.check(not in_use(root / "tmpab", {str(root / "tmpab_12cd9")}), "a held path's prefix is not the path")
    try:
        stale[0].__setattr__("size", 0)
        t.check(False, "an entry judged is never changed")
    except AttributeError:
        t.check(True, "an entry judged is never changed")


def self_test_report(t, stale: list[Entry], text: str) -> None:
    applied = "removed 4," in text
    t.check(
        "temp    6 entries" in text and f"{stale[0].path.parent}/work" in text
        and ("removable by --apply" not in text) == applied,
        "the report counts the stale, names what is kept, and says what --apply "
        + ("removed" if applied else "would remove"),
        text,
    )
    if applied:
        t.check(report({}, 1000, [e for e in stale if e.removable], stale) == "", "removing every stray clears the report")


def self_test_live(t, d: Path) -> None:
    import subprocess

    me = read_procs()[os.getpid()]
    t.check(me.uid == os.getuid() and me.state in "RS" and "stray_sweep" in me.cmd, "this process reads from /proc")
    out = d / "report"
    write("", out)
    t.check(not out.exists(), "--write with nothing stray leaves no report, and none there is no error")
    write("x\n", out)
    write("", out)
    t.check(not out.exists(), "--write removes the report once nothing is stray")
    write("x\n", out)
    t.check(out.read_text() == "x\n", "--write writes the report when something is")
    self_path = os.path.abspath(__file__)
    for bad in (["--nope"], ["--write"], ["--apply", "a", "b"]):
        usage = subprocess.run([sys.executable, self_path, *bad], capture_output=True, text=True)
        t.check(usage.returncode == 2 and "Usage:" in usage.stderr, f"{' '.join(bad)} is a usage error")
    run = subprocess.run([sys.executable, self_path, "--write", str(out)], capture_output=True, text=True)
    t.check(run.returncode in (0, 1) and run.stdout == "", "a run with --write prints nothing", run.stderr)


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__.strip())
        sys.exit(0)
    sys.exit(main(sys.argv[1:]))
