#!/usr/bin/env python3
"""Does the voice review still catch what the user rejected, and pass what the user kept?

    voice_test.py                    # every case in skills/voice/cases.json
    voice_test.py --self-test

The review is the voice skill's SKILL.md: a reviewer that did not write the text
reads My voice in the credo and the cases, and quotes each sentence that fails. A case is a
sentence the user rejected ("fails": true) or kept. Each case is reviewed in a
fresh headless session that sees every other case but not its own, three times; it
holds when the majority flagged it exactly when it fails. A case whose rule lives
outside My voice names it, "section": "<path>#<heading>", and the reviewer is
handed that section too.

Exit 0 every case held, 1 a case failed, 75 a run got no answer.
"""
import concurrent.futures
import json
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402

ROOT = pathlib.Path.home() / ".claude"
CREDO, REVIEW, CASES = ROOT / "credo.md", ROOT / "skills/voice/SKILL.md", ROOT / "skills/voice/cases.json"
RUNS, WORKERS, SECONDS, NO_ANSWER = 3, 6, 300, 75
SESSION = ["-p", "--tools", "", "--no-session-persistence", "--settings", '{"disableAllHooks":true}']


def section(text: str, heading: str) -> str:
    """The body of the level-2 section `heading` in a markdown text."""
    match = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return match.group(1).strip() if match else ""


def voice(credo: str) -> str:
    """The credo's My voice section."""
    return section(credo, "My voice")


def other(case: dict, read=lambda path: pathlib.Path(path).expanduser().read_text()) -> str:
    """The voice section a case's rule lives in, `<path>#<heading>`, or "" for My voice alone."""
    if "section" not in case:
        return ""
    path, heading = case["section"].split("#", 1)
    return f"\n\nOther voice section, {heading}:\n{section(read(path), heading)}"


def instructions(skill: str) -> str:
    """The skill's body, without its frontmatter or the text it is handed."""
    body = re.sub(r"\A---\n.*?\n---\n", "", skill, flags=re.S)
    return body.split("Text to check:")[0].strip()


def prompt(review: str, credo: str, others: list, text: str, extra: str = "") -> str:
    return (f"{instructions(review)}\n\nThe files are inlined here, so read nothing.\n\n"
            f"My voice:\n{voice(credo)}{extra}\n\nCases:\n{json.dumps(others, indent=1)}\n\n"
            f"Text to review:\n{text}\n")


def flagged(reply: str | None) -> bool | None:
    if reply is None or not reply.strip():
        return None
    return not reply.strip().upper().startswith("NONE")


def ask(text: str) -> str | None:
    try:
        done = subprocess.run(["claude", *SESSION, text], capture_output=True, text=True, timeout=SECONDS)
    except subprocess.TimeoutExpired:
        return None
    return done.stdout if done.returncode == 0 else None


def verdict(case: dict, flags: list) -> bool | None:
    if None in flags:
        return None
    return (sum(flags) * 2 > len(flags)) == case["fails"]


def run(cases: list, review: str, credo: str, asker=ask, runs: int = RUNS) -> int:
    def one(i: int) -> tuple:
        text = prompt(review, credo, cases[:i] + cases[i + 1:], cases[i]["text"], other(cases[i]))
        flags = [flagged(asker(text)) for _ in range(runs)]
        return verdict(cases[i], flags), flags
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        outcomes = list(pool.map(one, range(len(cases))))
    for case, (held, flags) in zip(cases, outcomes):
        mark = {True: "ok", False: "FAILED", None: "NO ANSWER"}[held]
        print(f"  {mark:9} {'fails' if case['fails'] else 'passes'} {sum(f or 0 for f in flags)}/{len(flags)} flagged  {case['text']}")
    held = [o[0] for o in outcomes]
    return 1 if False in held else NO_ANSWER if None in held else 0


def main(argv: list) -> int:
    if argv[:1] == ["--self-test"]:
        return self_test()
    return run(json.loads(CASES.read_text()), REVIEW.read_text(), CREDO.read_text())


def self_test() -> int:
    t = Tap()
    credo = "# C\n## My voice\nTalk, don't write.\n## Next\nx\n"
    t.check(voice(credo) == "Talk, don't write.", "voice() takes only the My voice section")
    doc = "# S\n## Application voice\nNo small numbers.\n## Formats\ny\n"
    t.check(other({"text": "A", "section": "s.md#Application voice"}, read=lambda p: doc)
            == "\n\nOther voice section, Application voice:\nNo small numbers.",
            "a case naming a section hands the reviewer that section alone")
    t.check(other({"text": "A"}) == "", "a case naming no section hands only My voice")
    t.check("No small numbers." in prompt("R", credo, [], "A", other({"section": "s#Application voice"}, read=lambda p: doc)),
            "the named section reaches the prompt")
    skill = "---\nname: v\n---\n# V\nRules.\n\nText to check:\n\n$ARGUMENTS\n"
    t.check(instructions(skill) == "# V\nRules.", "the prompt drops the frontmatter and the text placeholder")
    cases = [{"text": "A", "fails": True}, {"text": "B", "fails": False}]
    p = prompt("R", credo, cases[1:], "A")
    t.check('"B"' in p and '"A"' not in p.split("Text to review")[0], "a case never sees itself among the cases")
    t.check((flagged("NONE"), flagged('"x" — rule'), flagged("")) == (False, True, None),
            "NONE passes, a quoted line flags, an empty reply is no answer")
    t.check(verdict(cases[0], [True, True, False]) and verdict(cases[1], [False, False, True]),
            "the majority of runs decides")
    t.check(verdict(cases[0], [True, None, True]) is None, "a run with no answer leaves the case unanswered")
    import io, contextlib
    with contextlib.redirect_stdout(io.StringIO()):
        right = run(cases, "R", credo, asker=lambda s: '"A" — r' if "Text to review:\nA" in s else "NONE", runs=1)
        wrong = run(cases, "R", credo, asker=lambda s: "NONE", runs=1)
    t.check((right, wrong) == (0, 1), "run exits 0 when every case holds and 1 when one fails")
    return t.end()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
