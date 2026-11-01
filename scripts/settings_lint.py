#!/usr/bin/env python3
"""Lint the permission rules in Claude Code settings files.

    settings_lint.py FILE ...
    settings_lint.py --self-test

A permission rule that matches nothing, or matches everything, fails silently:
the prompt it was meant to skip still appears, or the prompt it was meant to
keep never does. Clicking "always allow" writes a rule for the exact command
that was on screen, so these accumulate without anyone writing them.

Enforced:

  the file is JSON
  no rule appears twice, and none is in both allow and deny
  a Bash allow carries a * — without one it matches a single exact command
  a trailing wildcard is written ' *', never the legacy ':*'
  a Bash allow never names an inline-code interpreter (python3 -c, bash -c …),
    which runs anything and so allows every command
  a Bash rule naming a script by path names one that exists and is executable
  a Read or Edit path never starts with a single / before a filesystem root
    directory: one / anchors at the settings file, so the rule matches nothing

Exit 0 when every file is clean, 1 when any is not. Each problem prints as
file: rule — what is wrong, so the verdict is always attributable to one rule.
"""
import json
import os
import pathlib
import re
import sys

LISTS = ("allow", "ask", "deny")
TOOL_RULE = re.compile(r"^(\w+)\((.*)\)$", re.S)
INLINE_CODE = re.compile(
    r"^(python3?|bash|sh|zsh|node|perl|ruby) +-[ce]\b|^eval\b")
ROOT_DIRS = frozenset({
    "home", "mnt", "tmp", "Users", "etc", "opt", "var", "usr", "root", "srv",
})


# ── reading ──────────────────────────────────────────────────────────────

def load(path: pathlib.Path):
    """The settings mapping, or None with the reason it could not be read."""
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except (OSError, json.JSONDecodeError) as e:
        return None, f"not readable JSON: {e}"


def rules(settings: dict) -> dict[str, list[str]]:
    perms = settings.get("permissions") or {}
    return {k: list(perms.get(k) or []) for k in LISTS}


def split(rule: str):
    """(tool, specifier) — the specifier is None for a bare tool name."""
    m = TOOL_RULE.match(rule)
    return (m.group(1), m.group(2)) if m else (rule, None)


# ── one rule at a time ───────────────────────────────────────────────────

def bash_problems(kind: str, spec: str) -> list[str]:
    out = []
    if spec.endswith(":*"):
        out.append("legacy ':*' — write the trailing wildcard as ' *'")
    if kind == "allow" and "*" not in spec:
        out.append("no * — it matches one exact command, a one-off")
    if kind == "allow" and INLINE_CODE.search(spec):
        out.append("inline-code interpreter — it runs anything, "
                   "so it allows every command")
    out += script_problems(spec.split()[0].removesuffix(":*"))
    return out


def script_problems(program: str) -> list[str]:
    if not program.startswith(("/", "~/")):
        return []
    path = pathlib.Path(program).expanduser()
    if os.access(path, os.X_OK) and path.is_file():
        return []
    return [f"names {program}, which is not an executable file"]


def path_problems(spec: str) -> list[str]:
    head = spec.split("/")[1] if spec.startswith("/") else ""
    if spec.startswith("//") or head not in ROOT_DIRS:
        return []
    return [f"single / anchors at the settings file, not at /{head}; "
            "write // for an absolute path or ~/ for home"]


def rule_problems(kind: str, rule: str) -> list[str]:
    tool, spec = split(rule)
    if spec is None:
        return []
    if tool == "Bash":
        return bash_problems(kind, spec)
    if tool in ("Read", "Edit"):
        return path_problems(spec)
    return []


# ── across rules ─────────────────────────────────────────────────────────

def duplicates(lists: dict[str, list[str]]) -> list[str]:
    out = [f"{r} — listed twice in {k}"
           for k, rs in lists.items() for r in set(rs) if rs.count(r) > 1]
    both = set(lists["allow"]) & set(lists["deny"])
    return out + [f"{r} — in both allow and deny" for r in sorted(both)]


def lint_file(path: pathlib.Path) -> list[str]:
    """The problems in one settings file."""
    settings, why = load(path)
    if why:
        return [why]
    lists = rules(settings)
    per_rule = [f"{r} — {p}"
                for k, rs in lists.items() for r in rs
                for p in rule_problems(k, r)]
    return duplicates(lists) + per_rule


# ── entry ────────────────────────────────────────────────────────────────

def run(files: list[pathlib.Path]) -> int:
    problems = []
    for f in files:
        problems += [f"{f}: {p}" for p in lint_file(f)]
    for p in problems:
        print(f"  {p}")
    print(f"settings_lint: {len(files)} files, errors={len(problems)}")
    print("settings_lint: " + ("FAIL" if problems else "PASS"))
    return 1 if problems else 0


def self_test() -> int:
    import tempfile
    rc = 0

    def check(desc, want, got):
        nonlocal rc
        if want == got:
            print(f"  ok   {desc}")
        else:
            print(f"  FAIL {desc}\n    want: {want}\n    got:  {got}",
                  file=sys.stderr)
            rc = 1

    print("settings_lint.py --self-test")
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        tool = root / "tool.sh"
        tool.write_text("#!/bin/sh\n")
        tool.chmod(0o755)

        def problems(allow=(), deny=()):
            f = root / "s.json"
            f.write_text(json.dumps(
                {"permissions": {"allow": list(allow), "deny": list(deny)}}))
            return lint_file(f)

        def first(*allow):
            p = problems(allow)
            return p[0] if p else "NO PROBLEM REPORTED"

        clean = [f"Bash({tool} *)", "Bash(git add *)", "Read(~/.claude/**)",
                 "Read(//etc/hosts)", "Edit(/src/**)", "mcp__x__y"]
        check("well-formed rules are clean", [], problems(clean))

        # One rule per check, breaking that check and nothing else.
        check("a fixed command is a one-off", True,
              "one-off" in first("Bash(jira.sh ABC-1)"))
        check("the legacy :* form is named", True,
              "legacy" in first("Bash(jq:*)"))
        check("an inline-code interpreter allows everything", True,
              "every command" in first("Bash(python3 -c ' *)"))
        check("a missing script is named", True,
              "not an executable" in first(f"Bash({root}/gone.sh *)"))
        check("a single-slash absolute path matches nothing", True,
              "anchors at the settings file" in first("Read(/home/u/**)"))
        check("a duplicate is named", True,
              "listed twice" in first("Bash(git add *)", "Bash(git add *)"))
        check("allow and deny of one rule is named", True,
              any("both allow and deny" in p
                  for p in problems(["Bash(ls *)"], ["Bash(ls *)"])))

        (root / "bad.json").write_text("{")
        check("unparseable JSON is named, not skipped", True,
              "not readable JSON" in lint_file(root / "bad.json")[0])
    return rc


def main(args: list[str]) -> int:
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if args[:1] == ["--self-test"]:
        return self_test()
    return run([pathlib.Path(a) for a in args])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
