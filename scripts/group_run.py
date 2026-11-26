#!/usr/bin/env python3
"""group_run.py — run a command as its own process group, and let nothing it starts outlive it.

Once the command ends, or overruns its timeout, the group is stopped: TERM,
then KILL for what is left after GRACE seconds. While it runs, SIGTERM or
SIGHUP to this process stops the group and exits 128 plus the signal, and
Ctrl-C stops it the same way. A database server or a worker a test run
leaves behind, or a process a broken test never ends, dies with the command
instead of running on, re-parented.

As a library, run() returns the command's status, or None when it overran,
with its output wherever the caller points it; OSError when it cannot start.
A caller that runs commands from worker threads wraps its main thread in
stopping_on_signal(), which stops every live group: a signal handler can only
be set on the main thread. A caller in another layer imports it with
resolve.py's module().

Exit, as a command: the command's own status, 128 plus the signal that ended
it, 124 when it overran, 127 when it could not start, 2 usage.

Usage:
  group_run.py [--timeout SECONDS] -- <command>…
  group_run.py --self-test

    from group_run import run
    status = run(argv, cwd=…, env=…, timeout=…, stdout=file, stderr=file)
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Mapping, Sequence
from contextlib import contextmanager, suppress

GRACE = 2.0
STOPS = (signal.SIGTERM, signal.SIGHUP)
OVERRAN, NOT_STARTED = 124, 127
LIVE: set[int] = set()


def stopped(signum: int, _frame) -> None:
    """Every live group is killed, then this process exits 128 plus the signal."""
    for pgid in list(LIVE):
        with suppress(ProcessLookupError):
            os.killpg(pgid, signal.SIGKILL)
    raise SystemExit(128 + signum)


def alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


def stop_group(child: subprocess.Popen) -> None:
    """TERM the group, give it GRACE seconds to go, KILL what is left, and reap the child."""
    with suppress(ProcessLookupError):
        os.killpg(child.pid, signal.SIGTERM)
    deadline = time.monotonic() + GRACE
    with suppress(subprocess.TimeoutExpired):
        child.wait(GRACE)
    while alive(child.pid) and time.monotonic() < deadline:  # mutation: equivalent — no run lands on the deadline's exact float
        time.sleep(0.02)
    with suppress(ProcessLookupError):
        os.killpg(child.pid, signal.SIGKILL)
    child.wait()


@contextmanager
def stopping_on_signal():
    """While the block runs, a stop signal to this process stops every live group and exits.
    Off the main thread it does nothing: the main thread's own block covers it."""
    on_main = threading.current_thread() is threading.main_thread()
    saved = {s: signal.signal(s, stopped) for s in STOPS} if on_main else {}
    try:
        yield
    finally:
        for s, handler in saved.items():
            signal.signal(s, handler)


def run(
    argv: Sequence[str],
    *,
    cwd: str | os.PathLike | None = None,
    env: Mapping[str, str] | None = None,
    timeout: float | None = None,
    stdout=None,
    stderr=None,
) -> int | None:
    child = subprocess.Popen(
        list(argv),
        cwd=cwd,
        env=None if env is None else dict(env),
        stdin=subprocess.DEVNULL,
        stdout=stdout,
        stderr=stderr,
        start_new_session=True,
    )
    LIVE.add(child.pid)
    with stopping_on_signal():
        try:
            return child.wait(timeout)
        except subprocess.TimeoutExpired:
            return None
        finally:
            stop_group(child)
            LIVE.discard(child.pid)


def exit_code(status: int | None) -> int:
    return OVERRAN if status is None else (128 - status if status < 0 else status)


def main(argv: list[str]) -> int:
    timeout, rest = None, argv
    if rest[:1] == ["--timeout"] and len(rest) > 1:
        timeout, rest = float(rest[1]), rest[2:]
    if rest[:1] != ["--"] or len(rest) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return exit_code(run(rest[1:], timeout=timeout))
    except OSError as e:
        print(f"group_run: {rest[1]}: {e.strerror}", file=sys.stderr)
        return NOT_STARTED


# ---------------------------------------------------------------- self-test


def self_test() -> int:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import tempfile
    from pathlib import Path

    from tap import Tap, scratch

    t = Tap()
    with scratch() as d:
        self_test_run(t, Path(d), tempfile)
        self_test_signals(t, Path(d))
        self_test_threads(t, Path(d))
        self_test_cli(t, Path(d))
    return t.end()


def self_test_gone(pid_file) -> bool:
    """A stop lands a moment after it is sent, so the process gets five seconds to die."""
    from pathlib import Path

    stat, deadline = Path(f"/proc/{int(pid_file.read_text())}/stat"), time.monotonic() + 5

    def dead():  # the stat file can vanish between any check and the read, so the read is the check
        try:
            return stat.read_text().split(") ")[1].startswith("Z")
        except FileNotFoundError:
            return True

    while not dead() and time.monotonic() < deadline:
        time.sleep(0.02)
    return dead()


def self_test_run(t, d, tempfile) -> None:
    with tempfile.TemporaryFile("w+") as out:
        script = f"sleep 300 >/dev/null & echo $! > {d}/left; pwd; echo $X; echo err >&2; exit 3"
        status = run(["sh", "-c", script], cwd=d, env={"X": "x"}, stdout=out, stderr=subprocess.STDOUT)
        out.seek(0)
        got = out.read()
    t.check(
        (status, got) == (3, f"{d}\nx\nerr\n") and self_test_gone(d / "left"),
        "the command's status and output come back, in its folder and env, and what it left behind dies",
        repr((status, got)),
    )
    heeds = f"sh -c 'trap \"touch {d}/termed; exit\" TERM; echo $$ > {d}/over; while :; do sleep 0.05; done' & wait"
    status = run(["sh", "-c", heeds], timeout=0.3)
    t.check(
        status is None and self_test_gone(d / "over") and (d / "termed").exists(),
        "a command that overruns gives None, and its group is sent TERM first",
    )
    hard = f"sh -c 'trap \"\" TERM; echo $$ > {d}/deaf; while :; do sleep 0.05; done' & wait"
    begun = time.monotonic()
    status = run(["sh", "-c", hard], timeout=0.3)
    took = time.monotonic() - begun
    t.check(
        status is None and self_test_gone(d / "deaf") and took >= GRACE,
        "a process that ignores TERM is killed once the grace is over",
        f"took {took:.1f}s",
    )
    try:
        run([str(d / "nowhere")])
        t.check(False, "a command that cannot start raises OSError")
    except OSError:
        t.check(True, "a command that cannot start raises OSError")
    t.check(signal.getsignal(signal.SIGTERM) == signal.SIG_DFL, "this process's own signals are restored")


def self_test_signals(t, d) -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    for sig, want in ((signal.SIGTERM, {143}), (signal.SIGHUP, {129}), (signal.SIGINT, {130, -2})):
        pid_file = d / f"hung{sig}"
        caller = (
            "import signal, sys; signal.signal(signal.SIGINT, signal.default_int_handler); "
            f"sys.path.insert(0, {here!r}); from group_run import run; "
            f"run(['sh', '-c', 'sleep 300 & echo $! > {pid_file}; wait'])"
        )
        child = subprocess.Popen([sys.executable, "-c", caller], stderr=subprocess.DEVNULL)
        while not pid_file.exists() or not pid_file.read_text():
            time.sleep(0.05)
        child.send_signal(sig)
        t.check(
            child.wait(10) in want and self_test_gone(pid_file),
            f"{signal.Signals(sig).name} to the caller stops the command it was running",
        )


def self_test_threads(t, d) -> None:
    import concurrent.futures

    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        got = list(pool.map(lambda n: run(["sh", "-c", f"exit {n}"]), (5, 6)))
    t.check(got == [5, 6] and not LIVE, "commands run from worker threads, and none stays live")
    here = os.path.dirname(os.path.abspath(__file__))
    pid_file = d / "threaded"
    caller = (
        f"import sys, threading; sys.path.insert(0, {here!r}); import group_run as g\n"
        "with g.stopping_on_signal():\n"
        f"    w = threading.Thread(target=g.run, args=(['sh', '-c', 'sleep 300 & echo $! > {pid_file}; wait'],))\n"
        "    w.start(); w.join()\n"
    )
    child = subprocess.Popen([sys.executable, "-c", caller], stderr=subprocess.DEVNULL)
    while not pid_file.exists() or not pid_file.read_text():
        time.sleep(0.05)
    child.send_signal(signal.SIGTERM)
    t.check(
        child.wait(10) == 143 and self_test_gone(pid_file),
        "a stop signal to a caller stops the groups its worker threads started",
    )


def self_test_cli(t, d) -> None:
    me = os.path.abspath(__file__)

    def cli(*args):
        done = subprocess.run([sys.executable, me, *args], capture_output=True, text=True)
        return done.returncode, done.stdout

    t.check(cli("--", "sh", "-c", "echo hi; exit 4") == (4, "hi\n"), "as a command, its status and stdout are the command's")
    t.check(cli("--", "true")[0] == 0, "a command that succeeds exits 0")
    t.check(cli("--timeout", "0.2", "--", "sleep", "5")[0] == OVERRAN, "an overrun exits 124, as timeout(1) does")
    t.check(cli("--", "sh", "-c", "kill -9 $$")[0] == 137, "a command killed by a signal exits 128 plus it")
    t.check(cli("--", str(d / "nowhere"))[0] == NOT_STARTED, "a command that cannot start exits 127")
    for bad in ((), ("--",), ("sleep", "1"), ("--timeout",)):
        t.check(cli(*bad)[0] == 2, f"{' '.join(bad) or 'no argument'} is a usage error")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__.strip())
        sys.exit(0)
    sys.exit(main(sys.argv[1:]))
