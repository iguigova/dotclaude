#!/usr/bin/env python3
"""Does each skill still fire when it should? Run its trigger cases through fresh sessions.

    skill_trigger_test.py [--root DIR] [NAME ...]   # DIR's cases, default ~/.claude
    skill_trigger_test.py --changed PATH ...        # what tooling_commit.sh runs
    skill_trigger_test.py --self-test

A description is how Claude picks a skill, so editing one can lose a trigger with
nothing failing. A skill's cases are the triggers it must keep, and they live in
skill_triggers.json in the .claude root that holds the skill:

    {"timelog": [{"prompt": "log my time", "fires": true},
                 {"prompt": "add a timing log line", "fires": false}]}

Each prompt runs in a fresh headless session with only the Skill tool and hooks
off, so a case can load a skill and do nothing else, and the session stops at its
first call. A case passes when the skill fired, or stayed quiet, in most runs.

--changed takes the paths of a commit and runs only the skills and commands whose
description or cases differ from HEAD; a skill with no should-fire case is refused,
and so is a run that got no answer. A disable-model-invocation skill is skipped,
since Claude cannot start it. There is no size limit: each run prints a tested
skill's description length against HEAD, so the cost of a change sits beside the
proof that it lost nothing.

Exit 0 every case held, 1 a case failed or a skill cannot be tested, 75 no answer.
"""
import concurrent.futures
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from frontmatter_lint import block  # noqa: E402
from tap import Tap  # noqa: E402

CASES_FILE = "skill_triggers.json"
USER_ROOT = pathlib.Path.home() / ".claude"
RUNS = 3
WORKERS = 6
SESSION_SECONDS = 300
NO_ANSWER = 75
COMPONENT = re.compile(r"^(?P<root>.+)/(?:skills/(?P<skill>[^/]+)/SKILL\.md|commands/(?P<command>[^/]+)\.md)$")
SESSION = ["-p", "--tools", "Skill", "--output-format", "stream-json", "--verbose",
           "--no-session-persistence", "--settings", '{"disableAllHooks":true}']


@dataclass(frozen=True)
class Case:
    name: str
    prompt: str
    fires: bool


class Untestable(Exception):
    """A skill the run was asked to test has no usable cases."""


# ---------------------------------------------------------------- one session

def called_skills(message: dict) -> list[str]:
    return [b["input"].get("skill") for b in message["message"]["content"]
            if b.get("type") == "tool_use" and b["name"] == "Skill"]


def read_turn(lines) -> list[str] | None:
    """The skills of the first turn that called one, [] for none, None for no answer."""
    for line in lines:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            return None
        if message.get("type") == "assistant" and called_skills(message):
            return called_skills(message)
        if message.get("type") == "result":
            return None if message.get("is_error") else []
    return None


def ask(prompt: str, cwd: str) -> list[str] | None:
    with subprocess.Popen(["claude", *SESSION, prompt], cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True) as session:
        deadline = threading.Timer(SESSION_SECONDS, session.kill)
        deadline.start()
        turn = read_turn(session.stdout)
        deadline.cancel()
        session.kill()
    return turn


# ---------------------------------------------------------------- verdicts

def verdict(case: Case, turns: list) -> tuple[bool | None, int]:
    """Whether the case held, None when a run got no answer, and how many runs fired."""
    fired = sum(case.name in (t or []) for t in turns)
    if any(t is None for t in turns):
        return None, fired
    return (fired * 2 > len(turns)) == case.fires, fired


def run_case(case: Case, cwd: str, runs: int = RUNS, asker=ask) -> tuple[bool | None, int, list]:
    turns = [asker(case.prompt, cwd) for _ in range(runs)]
    return (*verdict(case, turns), turns)


def report(case: Case, held: bool | None, fired: int, turns: list) -> None:
    mark = {True: "ok", False: "FAILED", None: "NO ANSWER"}[held]
    sign = "+" if case.fires else "-"
    seen = "" if held else f"  called: {turns}"
    print(f"  {mark:9} {case.name} {sign} {fired}/{len(turns)}  {case.prompt}{seen}")


def run_cases(cases: list[Case], cwd: str, runs: int = RUNS, asker=ask) -> int:
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        outcomes = list(pool.map(lambda c: run_case(c, cwd, runs, asker), cases))
    for case, outcome in zip(cases, outcomes):
        report(case, *outcome)
    held = [o[0] for o in outcomes]
    return 1 if False in held else NO_ANSWER if None in held else 0


# ---------------------------------------------------------------- what to test

def frontmatter(text: str | None) -> dict:
    fields = yaml.safe_load(block(text)[0] or "") if text else None
    return fields if isinstance(fields, dict) else {}


def head_text(path: pathlib.Path) -> str | None:
    """PATH as HEAD holds it, None when HEAD does not hold it."""
    done = subprocess.run(["git", "-C", str(path.parent), "show", f"HEAD:./{path.name}"],
                          capture_output=True, text=True)
    return done.stdout if done.returncode == 0 else None


def component_path(root: pathlib.Path, name: str) -> pathlib.Path | None:
    candidates = (root / "skills" / name / "SKILL.md", root / "commands" / f"{name}.md")
    return next((p for p in candidates if p.exists()), None)


def description_change(path: pathlib.Path) -> tuple[int, int] | None:
    """Its description's length at HEAD and now, None when the two read the same."""
    before = frontmatter(head_text(path)).get("description") or ""
    after = frontmatter(path.read_text()).get("description") or ""
    return None if before == after else (len(before), len(after))


def cases_at_head(root: pathlib.Path) -> dict:
    return json.loads(head_text(root / CASES_FILE) or "{}")


def cases_now(root: pathlib.Path) -> dict:
    path = root / CASES_FILE
    return json.loads(path.read_text()) if path.exists() else {}


def changed_cases(root: pathlib.Path) -> set[str]:
    old, new = cases_at_head(root), cases_now(root)
    return {name for name in new if new[name] != old.get(name)}


def targets(paths: list[str]) -> dict[pathlib.Path, set[str]]:
    """Each .claude root among PATHS, with the names whose description or cases changed."""
    found: dict[pathlib.Path, set[str]] = {}
    for raw in paths:
        path = pathlib.Path(raw).resolve()
        if path.name == CASES_FILE and path.exists():
            found.setdefault(path.parent, set()).update(changed_cases(path.parent))
        match = COMPONENT.match(str(path))
        if match and path.exists() and description_change(path):
            name = match["skill"] or match["command"]
            found.setdefault(pathlib.Path(match["root"]), set()).add(name)
    return {root: names for root, names in found.items() if names}


def invocable(root: pathlib.Path, name: str) -> bool:
    path = component_path(root, name)
    return not (path and frontmatter(path.read_text()).get("disable-model-invocation"))


def cases_for(root: pathlib.Path, name: str, table: dict) -> list[Case]:
    if component_path(root, name) is None:
        raise Untestable(f"{root / CASES_FILE} has cases for {name}, which is no skill or command here")
    cases = [Case(name, c["prompt"], c["fires"]) for c in table.get(name, [])]
    if not any(c.fires for c in cases):
        raise Untestable(f"{name} has no should-fire case in {root / CASES_FILE}; add the prompts it must keep")
    return cases


def session_dir(root: pathlib.Path, scratch: str) -> str:
    """User skills list from any directory; a project's list only from inside it."""
    return scratch if root == USER_ROOT else str(root.parent)


def print_lengths(root: pathlib.Path, names: set[str]) -> None:
    for name in sorted(names):
        path = component_path(root, name)
        change = description_change(path) if path else None
        if change:
            print(f"  {name}: description {change[0]} -> {change[1]} characters")


# ---------------------------------------------------------------- entry

def test_root(root: pathlib.Path, names: set[str], asker=ask) -> int:
    print(f"trigger cases: {root}")
    print_lengths(root, names)
    table = cases_now(root)
    runnable = sorted(n for n in names if invocable(root, n))
    cases = [c for n in runnable for c in cases_for(root, n, table)]
    with tempfile.TemporaryDirectory() as scratch:
        return run_cases(cases, session_dir(root, scratch), asker=asker)


def run(wanted: dict[pathlib.Path, set[str]], asker=ask) -> int:
    try:
        statuses = [test_root(root, names, asker) for root, names in wanted.items()]
    except Untestable as why:
        print(f"skill_trigger_test: {why}", file=sys.stderr)
        return 1
    return 1 if 1 in statuses else max(statuses, default=0)


def main(argv: list[str]) -> int:
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["--changed"]:
        return run(targets(argv[1:]))
    root, names = USER_ROOT, argv
    if argv[:1] == ["--root"]:
        root, names = pathlib.Path(argv[1]).resolve(), argv[2:]
    return run({root: set(names) or set(cases_now(root))})


# ---------------------------------------------------------------- self-test

SKILL = "---\nname: {n}\ndescription: {d}\n{x}---\nbody\n"


def write_skill(root: pathlib.Path, name: str, description: str, extra: str = "") -> pathlib.Path:
    path = root / "skills" / name / "SKILL.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(SKILL.format(n=name, d=description, x=extra))
    return path


def git(repo: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                   check=True, capture_output=True)


def fake_asker(table: dict):
    return lambda prompt, _cwd: table[prompt]


def stub_claude(bin_dir: pathlib.Path, lines: list[dict]) -> None:
    stream = "\n".join(json.dumps(line) for line in lines)
    path = bin_dir / "claude"
    path.write_text(f"#!/bin/sh\ncat <<'EOF'\n{stream}\nEOF\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def self_test_turns(t: Tap, base: pathlib.Path) -> None:
    call = {"type": "assistant", "message": {"content": [
        {"type": "text", "text": "x"}, {"type": "tool_use", "name": "Skill", "input": {"skill": "a"}}]}}
    quiet = {"type": "assistant", "message": {"content": [{"type": "text", "text": "x"}]}}
    done = {"type": "result", "is_error": False}
    failed = {"type": "result", "is_error": True}
    as_lines = lambda *msgs: [json.dumps(m) for m in msgs]  # noqa: E731
    t.check(read_turn(as_lines(call, done)) == ["a"], "a turn that calls a skill names it")
    t.check(read_turn(as_lines(quiet, done)) == [], "a turn that answers in text called nothing")
    t.check(read_turn(as_lines(failed)) is None, "an errored session is no answer, not a quiet one")
    t.check(read_turn([]) is None, "a session that printed nothing is no answer")
    t.check(read_turn(["Invalid API key"]) is None, "a session that printed no stream is no answer")
    stub_claude(base, [call, done])
    old = os.environ["PATH"]
    os.environ["PATH"] = f"{base}{os.pathsep}{old}"
    t.check(ask("p", str(base)) == ["a"], "ask reads the first turn from the session's stream")
    os.environ["PATH"] = old


def self_test_verdicts(t: Tap) -> None:
    up, down = Case("a", "p", True), Case("a", "p", False)
    t.check(verdict(up, [["a"], ["a"], []]) == (True, 2), "a should-fire case holds on most runs")
    t.check(verdict(up, [["a"], [], ["b"]]) == (False, 1), "a should-fire case fails on one run in three")
    t.check(verdict(down, [["b"], [], ["a"]]) == (True, 1), "a should-not case holds when most runs stay quiet")
    t.check(verdict(down, [["a"], ["a"], []]) == (False, 2), "a should-not case fails when most runs fire")
    t.check(verdict(up, [["a"], None, ["a"]])[0] is None, "a run with no answer makes the case unanswered")
    quiet = open(os.devnull, "w")
    keep, sys.stdout = sys.stdout, quiet
    held = run_cases([up], "/", 1, fake_asker({"p": ["a"]}))
    lost = run_cases([up], "/", 1, fake_asker({"p": []}))
    none = run_cases([up], "/", 1, fake_asker({"p": None}))
    sys.stdout = keep
    quiet.close()
    t.check((held, lost, none) == (0, 1, NO_ANSWER), "the run exits 0, 1 or 75 by what the cases did")


def self_test_targets(t: Tap, repo: pathlib.Path) -> None:
    git(repo, "init", "-q")
    a, b = write_skill(repo, "a", "old"), write_skill(repo, "b", "same")
    cmd = repo / "commands" / "c.md"
    cmd.parent.mkdir()
    cmd.write_text("---\ndescription: old\n---\nbody\n")
    (repo / CASES_FILE).write_text('{"b": [{"prompt": "p", "fires": true}]}')
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base")
    t.check(not targets([str(a), str(b)]), "an unchanged skill is nothing to test")
    a.write_text(SKILL.format(n="a", d="old", x="") + "more body\n")
    t.check(not targets([str(a)]), "a body edit is nothing to test")
    a.write_text(SKILL.format(n="a", d="new", x=""))
    cmd.write_text("---\ndescription: new\n---\nbody\n")
    t.check(targets([str(a), str(cmd)]) == {repo: {"a", "c"}}, "a changed description selects that skill or command")
    t.check(description_change(a) == (3, 3), "the length is read at HEAD and now")
    fresh = write_skill(repo, "fresh", "brand new")
    t.check(targets([str(fresh)]) == {repo: {"fresh"}}, "a skill HEAD does not hold counts as changed")
    (repo / CASES_FILE).write_text('{"b": [{"prompt": "q", "fires": true}]}')
    t.check(targets([str(repo / CASES_FILE)]) == {repo: {"b"}}, "changed cases select their skill")
    t.check(not targets([str(repo / "gone" / "SKILL.md")]), "a path that is no skill is ignored")


def self_test_cases(t: Tap, repo: pathlib.Path) -> None:
    write_skill(repo, "ok", "d")
    write_skill(repo, "manual", "d", "disable-model-invocation: true\n")
    (repo / CASES_FILE).write_text(json.dumps({
        "ok": [{"prompt": "fire", "fires": True}, {"prompt": "quiet", "fires": False}],
        "nofire": [{"prompt": "quiet", "fires": False}], "ghost": [{"prompt": "x", "fires": True}]}))
    write_skill(repo, "nofire", "d")
    write_skill(repo, "none", "d")
    table = cases_now(repo)
    t.check(len(cases_for(repo, "ok", table)) == 2, "a skill's cases are read from the root's file")
    t.check(not invocable(repo, "manual"), "a skill only the user can start is not testable")
    t.check(invocable(repo, "ok"), "an ordinary skill is testable")
    t.check(session_dir(USER_ROOT, "/s") == "/s", "user skills run in a scratch directory")
    t.check(session_dir(repo / ".claude", "/s") == str(repo), "project skills run from the project")
    quiet = open(os.devnull, "w")
    keep = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = quiet
    answers = fake_asker({"fire": ["ok"], "quiet": []})
    passed = run({repo: {"ok", "manual"}}, answers)
    refused = [run({repo: {name}}, answers) for name in ("none", "nofire", "ghost")]
    empty = run({})
    sys.stdout, sys.stderr = keep
    quiet.close()
    t.check(passed == 0, "a run skips the manual skill and passes on the rest")
    t.check(refused == [1, 1, 1], "a skill with no cases, no should-fire case or no file is refused")
    t.check(empty == 0, "nothing changed is a pass")


def self_test_main(t: Tap, repo: pathlib.Path) -> None:
    git(repo, "init", "-q")
    git(repo, "commit", "-q", "--allow-empty", "-m", "base")
    write_skill(repo, "m", "d")
    quiet = open(os.devnull, "w")
    keep = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = quiet
    statuses = (main(["--root", str(repo), "m"]), main(["--root", str(repo)]),
                main(["--changed", str(repo / "skills" / "m" / "SKILL.md")]))
    sys.stdout, sys.stderr = keep
    quiet.close()
    t.check(statuses == (1, 0, 1), "main refuses a named or changed skill with no cases, and a root with none is empty")


def self_test() -> int:
    t = Tap()
    with tempfile.TemporaryDirectory() as tmp:
        base = pathlib.Path(tmp)
        for sub in ("bin", "targets", "cases", "main"):
            (base / sub).mkdir()
        self_test_turns(t, base / "bin")
        self_test_verdicts(t)
        self_test_targets(t, base / "targets")
        self_test_cases(t, base / "cases")
        self_test_main(t, base / "main")
    return t.end()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
