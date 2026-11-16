#!/usr/bin/env python3
"""usage_snapshot.py — what the setup did, counted from the session transcripts.

Usage:
    usage_snapshot.py [--projects <dir>] [--repo <dir>]
    usage_snapshot.py --self-test

Prints one JSON object. Each count reads one event the transcripts record in
one fixed form, in the top-level transcripts of every project under
--projects (default ~/.claude/projects); a subagent's transcript is not
read, so its calls are not counted twice.

    since      the day of the earliest event in any transcript
    sessions   transcripts read: one per session
    sent_back  replies ask_gate.py returned because they held a question in
               prose: a user turn that starts "Stop hook feedback:" followed
               by ask_gate.py's refusal
    held       tool calls refused while a blocked call waited for the user:
               an error result that starts "PreToolUse:<tool> hook error:
               Auto mode blocked", block_gate.py's refusal
    gate_fail  change_gate.py runs whose verdict line is "change_gate: FAIL"
    gate_pass  change_gate.py runs whose verdict line is "change_gate: PASS"
    audits     calls of the audit skill
    commits    commits in --repo (default ~/.claude), counted by git

Only these counts are printed: no project, file, prompt or reply leaves the
transcripts. dotclaude_export.sh writes this into the public copy as
usage.json, which the showcase page reads.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tap import Tap  # noqa: E402

SENT_BACK = "Stop hook feedback:\nThis reply holds a question in prose"
HELD = re.compile(r"^PreToolUse:\S+ hook error: Auto mode blocked ")
VERDICT = re.compile(r"^change_gate: (PASS|FAIL)$", re.M)
KEYS = ("sessions", "sent_back", "held", "gate_fail", "gate_pass", "audits")


def text(content) -> str:
    """A tool result's content as text, whether a string or a list of parts."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def parts(content) -> list:
    """The parts of a user turn's content. Only a tool result has a
    "content" of its own, so only a tool result's body is ever read."""
    if not isinstance(content, list):
        return []
    return [p for p in content if isinstance(p, dict)]


def user_events(content) -> list:
    """The counted events a user turn holds."""
    if isinstance(content, str):
        return ["sent_back"] if content.startswith(SENT_BACK) else []
    found = []
    for r in parts(content):
        body = text(r.get("content"))
        if r.get("is_error") and HELD.match(body):
            found.append("held")
        found += ["gate_" + v.lower() for v in VERDICT.findall(body)]
    return found


def assistant_events(content) -> list:
    """The counted events an assistant turn holds: audit skill calls."""
    if not isinstance(content, list):
        return []
    return ["audits" for p in content
            if isinstance(p, dict) and p.get("type") == "tool_use"
            and p.get("name") == "Skill"
            and (p.get("input") or {}).get("skill") == "audit"]


def events(entry: dict) -> list:
    content = (entry.get("message") or {}).get("content")
    if entry.get("type") == "user":
        return user_events(content)
    if entry.get("type") == "assistant":
        return assistant_events(content)
    return []


def entries(path: Path):
    """Each JSON line of a transcript; a line that is not JSON is skipped."""
    with path.open(errors="replace") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def count(projects: Path) -> dict:
    counts = dict.fromkeys(KEYS, 0)
    stamps = []
    for path in sorted(projects.glob("*/*.jsonl")):
        counts["sessions"] += 1
        for entry in entries(path):
            stamps += [entry["timestamp"]] if entry.get("timestamp") else []
            for event in events(entry):
                counts[event] += 1
    first = min(stamps, default=None)
    return {"since": first[:10] if first else None, **counts}


def commits(repo: Path):
    """git's count of commits in repo, or None when git gives no answer."""
    done = subprocess.run(["git", "-C", str(repo), "rev-list", "--count", "HEAD"],
                          capture_output=True, check=False)
    return int(done.stdout) if done.returncode == 0 else None


def snapshot(projects: Path, repo: Path) -> dict:
    return {**count(projects), "commits": commits(repo)}


# ---------------------------------------------------------------- self-test

def line(kind: str, content, stamp="2026-10-02T09:00:00Z") -> str:
    return json.dumps({"type": kind, "timestamp": stamp,
                       "message": {"content": content}})


def result(body, error=False) -> list:
    return [{"type": "tool_result", "is_error": error, "content": body}]


FIXTURE = [
    line("user", SENT_BACK + ': "Shall I?"', "2026-10-01T08:00:00Z"),
    line("user", "Shall I commit it?"),
    line("user", result("PreToolUse:Bash hook error: Auto mode blocked Bash (x): y", error=True)),
    line("user", result("PreToolUse:Bash hook error: Auto mode blocked Bash (x): y, as a file prints it")),
    line("user", result([{"type": "text", "text": "ok\nchange_gate: FAIL\n"}])),
    line("user", result("change_gate: PASS")),
    line("user", result('print(f"change_gate: {verdict}")')),
    line("assistant", [{"type": "tool_use", "name": "Skill", "input": {"skill": "audit"}},
                       {"type": "tool_use", "name": "Skill", "input": {"skill": "draft"}}]),
    line("assistant", [{"type": "tool_use", "name": "Skill", "input": {"skill": "audit"}}]),
    "not json",
]


def self_test() -> int:
    t = Tap()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "p" / "s").mkdir(parents=True)
        (root / "p" / "s.jsonl").write_text("\n".join(FIXTURE) + "\n")
        (root / "p" / "s" / "agent.jsonl").write_text(FIXTURE[0] + "\n")
        (root / "q").mkdir()
        (root / "q" / "t.jsonl").write_text(FIXTURE[8] + "\n")
        got = count(root)
        t.check(got["sessions"] == 2, "one session per top-level transcript, subagents not read", str(got))
        t.check(got["sent_back"] == 1, "ask_gate's refusal is counted, a plain question is not", str(got))
        t.check(got["held"] == 1, "block_gate's refusal is counted, its words in a result that is no error are not", str(got))
        t.check((got["gate_fail"], got["gate_pass"]) == (1, 1),
                "a change_gate verdict line is counted, its source line is not", str(got))
        t.check(got["audits"] == 3, "audit skill calls are counted across projects, other skills are not", str(got))
        t.check(got["since"] == "2026-10-01", "since is the earliest day in any transcript", str(got))
        t.check(count(root / "none") == {"since": None, **dict.fromkeys(KEYS, 0)},
                "no transcripts count as zero, with no since day")
        t.check(commits(root) is None, "a folder that is no repo gives no commit count")
        subprocess.run(["git", "init", "-q", tmp], check=True)
        subprocess.run(["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@example.com",
                        "commit", "-q", "--allow-empty", "-m", "one"], check=True)
        t.check(commits(root) == 1, "commits are counted by git")
        out = json.dumps(snapshot(root, root))
        t.check("Shall I" not in out and "draft" not in out,
                "the snapshot holds counts only, no text from a transcript", out)
    return t.end()


def main() -> int:
    ap = argparse.ArgumentParser(description="Count what the setup did, from the transcripts.")
    ap.add_argument("--projects", type=Path, default=Path.home() / ".claude" / "projects")
    ap.add_argument("--repo", type=Path, default=Path.home() / ".claude")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    print(json.dumps(snapshot(args.projects, args.repo), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
