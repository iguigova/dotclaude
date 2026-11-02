#!/usr/bin/env python3
"""Check a skill's or command's `allowed-tools` Bash rules against the shell
commands its steps run: a command no rule admits, and a rule no command uses.

    allowed_tools_lint.py [PATH ...]   # a file, or a root whose skills and
                                       # commands are read; default: ~/.claude
                                       # and the cwd's .claude
    allowed_tools_lint.py --self-test
    allowed_tools_lint.py --help

A file without `allowed-tools` is skipped: it runs under the session's own
permissions, so it has no list to drift.

The commands a file runs are its fenced bash or sh blocks, and each inline code
span whose first word is an executable: on PATH, or an executable file at a
`~/` or project-relative path. A backticked `.claude/<path>.md` the file
names is a file its steps read, so its commands count too. The project root
is the folder holding the file's `.claude`.

A block is split into subcommands the way the matcher splits it, on `&&`,
`||`, `;`, `|`, `&` and newlines
(https://code.claude.com/docs/en/permissions, "Compound commands"); a
leading `{` or `(` is dropped, and the text of a `$( … )` or a
`<placeholder>` is not split further. A process wrapper, such as `timeout
120`, is dropped first ("Process wrappers"). Each subcommand is matched as
written: a rule matches "the command text Claude writes", and `~` is matched
as text, never expanded (same page, "Wildcard patterns"). `X:*` is the same
rule as `X *`, which matches `X` alone and `X …` but not `Xy`. The read-only
commands that page lists need no rule.

Only Bash rules are checked; Read, WebFetch, an MCP tool and the rest name no
command a step writes out.

Each row prints as path:line<TAB>unruled<TAB>command, or
path<TAB>unused<TAB>Bash(rule). A tool reports; the reader judges: an unused
rule may serve a step that names its tool in prose, and that step is then the
thing to fix, by naming the command.
Exit 0 nothing found, 1 rows printed, 2 usage.
"""
import fnmatch
import itertools
import os
import pathlib
import re
import shutil
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from skill_inventory import skills_in, commands_in   # noqa: E402

# https://code.claude.com/docs/en/permissions, "Read-only commands". git is
# read-only only in some forms, so it is not here. cd is read-only only into a
# working directory, which a file cannot show, so a cd anywhere passes.
READ_ONLY = {"ls", "cat", "echo", "pwd", "head", "tail", "grep", "find", "wc",
             "which", "diff", "stat", "du", "cd"}

FENCE = re.compile(r"^\s*```(\w*)\s*$")
SPAN = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
MD_REF = re.compile(r"`(\.claude/[^`\s]+\.md)`")


def frontmatter(text: str) -> tuple[str, int]:
    """The frontmatter block and the line its body starts on."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return "", 1
    for i, ln in enumerate(lines[1:], 1):
        if ln.strip() == "---":
            return "\n".join(lines[1:i]), i + 2
    return "", 1


def bash_rules(front: str) -> list[str] | None:
    """The Bash rule bodies of `allowed-tools`, None when there is no key."""
    m = re.search(r"^allowed-tools:(.*(?:\n[ \t-].*)*)", front, re.M)
    if not m:
        return None
    rules = []
    for tok in re.finditer(r"Bash(?:\(([^)]*)\))?", m.group(1)):
        rules.append(tok.group(1) if tok.group(1) is not None else "*")
    return rules


def admits(rule: str, cmd: str) -> bool:
    if rule.endswith(":*"):
        rule = rule[:-2] + " *"
    if rule.endswith(" *") and cmd == rule[:-2]:
        return True
    return fnmatch.fnmatchcase(cmd, rule)


def split(block: str) -> list[str]:
    """Subcommands of a shell block, quotes and $( ) kept whole."""
    out, cur, i, quote, depth = [], [], 0, "", 0
    block = re.sub(r"\\\n\s*", " ", block)
    while i < len(block):
        c = block[i]
        if quote:
            cur.append(c)
            if c == quote:
                quote = ""
        elif c in "'\"":
            quote = c
            cur.append(c)
        elif c == "<" and re.match(r"<[A-Za-z][^<>\n]*>", block[i:]):
            quote = ">"
            cur.append(c)
        elif block.startswith("$(", i):
            depth += 1
            cur.append("$(")
            i += 1
        elif c == ")" and depth:
            depth -= 1
            cur.append(c)
        elif depth:
            cur.append(c)
        elif c == "#" and (not cur or cur[-1].isspace()):
            while i < len(block) and block[i] != "\n":
                i += 1
            continue
        elif c == "&" and (cur[-1:] in (["<"], [">"])
                           or block[i + 1:i + 2] == ">"):
            cur.append(c)
        elif c in ";|&\n":
            out.append("".join(cur))
            cur = []
            while i + 1 < len(block) and block[i + 1] in "|&":
                i += 1
        else:
            cur.append(c)
        i += 1
    out.append("".join(cur))
    cmds = []
    for s in out:
        s = s.strip()
        while s[:1] in "{(":
            s = s[1:].strip()
        for o, c in (("(", ")"), ("{", "}")):
            while s.endswith(c) and s.count(c) > s.count(o):
                s = s[:-1].rstrip()
        if s and s not in ("}", ")"):
            cmds.append(s)
    return cmds


# Same page, "Process wrappers": stripped before a rule is matched, with the
# options and the duration or niceness they take; xargs only when bare.
WRAPPERS = {"timeout", "time", "nice", "nohup", "stdbuf", "command", "builtin"}
WITH_ARG = {"timeout": {"-k", "-s", "--kill-after", "--signal"},
            "nice": {"-n", "--adjustment"},
            "stdbuf": {"-i", "-o", "-e"}}


def unwrap(cmd: str) -> str:
    """The command a wrapper runs, as the matcher sees it."""
    words = cmd.split()
    while words:
        w = words[0]
        if w == "xargs" and len(words) > 1 and not words[1].startswith("-"):
            words = words[1:]
            continue
        if w not in WRAPPERS:
            break
        words = words[1:]
        while words and words[0].startswith("-"):
            opt = words.pop(0)
            if opt in WITH_ARG.get(w, ()) and words:
                words.pop(0)
        if w == "timeout" and words:
            words.pop(0)
    return " ".join(words)


def executable(word: str, root: pathlib.Path) -> bool:
    if "/" not in word:
        return shutil.which(word) is not None
    p = pathlib.Path(os.path.expanduser(word))
    if not p.is_absolute():
        p = root / p
    return p.is_file() and os.access(p, os.X_OK)


def commands(path: pathlib.Path, root: pathlib.Path, seen: set) -> list:
    """(path, line, command) for every command the file and its reads run."""
    if path in seen or not path.is_file():
        return []
    seen.add(path)
    text = path.read_text()
    _, start = frontmatter(text)
    lines = text.split("\n")
    found, block, lang, at = [], None, "", 0
    for n, ln in enumerate(lines[start - 1:], start):
        m = FENCE.match(ln)
        if m and block is None:
            block, lang, at = [], m.group(1), n + 1
            continue
        if m and block is not None:
            if lang in ("bash", "sh", "shell"):
                found += [(path, at, c) for c in split("\n".join(block))]
            block = None
            continue
        if block is not None:
            block.append(ln)
            continue
        for s in SPAN.finditer(ln):
            words = s.group(1).split()
            if words and executable(words[0], root):
                found += [(path, n, c) for c in split(s.group(1))]
    for ref in sorted(set(MD_REF.findall(text))):
        found += commands(root / ref, root, seen)
    return found


def lint(path: pathlib.Path) -> list[str]:
    rules = bash_rules(frontmatter(path.read_text())[0])
    if rules is None:
        return []
    parts = path.resolve().parts
    root = (pathlib.Path(*parts[:parts.index(".claude")])
            if ".claude" in parts else path.resolve().parent)
    rows, used = [], set()
    for f, n, cmd in commands(path.resolve(), root, set()):
        cmd = unwrap(cmd)
        if not cmd:
            continue
        hit = [r for r in rules if admits(r, cmd)]
        used.update(hit)
        if not hit and cmd.split()[0] not in READ_ONLY:
            rows.append(f"{f}:{n}\tunruled\t{cmd}")
    rows += [f"{path}\tunused\tBash({r})" for r in rules if r not in used]
    return rows


def files(args: list[str]) -> list[pathlib.Path]:
    out = []
    for a in args:
        p = pathlib.Path(a).expanduser()
        if p.is_file():
            out.append(p)
            continue
        base = p if p.name == ".claude" else p / ".claude"
        out += [pathlib.Path(i["path"])
                for i in skills_in(base, "") + commands_in(base, "")]
    return out


def self_test() -> int:
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        (root / ".claude/commands").mkdir(parents=True)
        (root / ".claude/shared").mkdir()
        tool = root / ".claude/run.sh"
        tool.write_text("#!/bin/sh\n")
        tool.chmod(0o755)
        (root / ".claude/shared/steps.md").write_text(
            "Then `.claude/run.sh --all | cat` and `not-a-command x`.\n")
        cmd = root / ".claude/commands/c.md"
        cmd.write_text(
            "---\ndescription: d\n"
            "allowed-tools: Read, Bash(git -C ~/x commit:*), Bash(cat:*), "
            "Bash(.claude/run.sh:*), Bash(curl:*)\n---\n"
            "Read `.claude/shared/steps.md`.\n"
            "```bash\n"
            "test -r f || { echo no >&2; exit 1; }\n"
            "cd out  # a comment; not a command\n"
            "git -C ~/x commit -m \"a; b\" -- \\\n  f.txt\n"
            "git push\n"
            "job.sh <a|b> <id>\n"
            "```\n")
        got = [r.replace(str(root) + "/", "") for r in lint(cmd)]
        by_root = files([str(root)])
    want = [".claude/commands/c.md:7\tunruled\ttest -r f",
            ".claude/commands/c.md:7\tunruled\texit 1",
            ".claude/commands/c.md:7\tunruled\tgit push",
            ".claude/commands/c.md:7\tunruled\tjob.sh <a|b> <id>",
            ".claude/commands/c.md\tunused\tBash(curl:*)"]
    checks = [admits("git:*", "git"), admits("git:*", "git status"),
              not admits("git:*", "gitk"), admits("ls*", "lsof"),
              not admits("ls *", "lsof"),
              split("echo $(date) && (cd a && make)")
              == ["echo $(date)", "cd a", "make"],
              [unwrap(c) for c in ("timeout -k 5 120 foo -x", "nice -n 5 foo",
                                   "stdbuf -oL foo", "time nohup foo",
                                   "xargs foo", "xargs -0 foo")]
              == ["foo -x", "foo", "foo", "foo", "foo", "xargs -0 foo"]]
    checks.append(by_root == [cmd])
    if got == want and all(checks):
        print("allowed_tools_lint self-test: PASS (unruled, unused, a read "
              "file's piped span, a quoted ';', a placeholder's '|', a "
              "redirect's '&', a continuation, a comment, a $( ), a process "
              "wrapper)")
        return 0
    print("allowed_tools_lint self-test: FAIL", file=sys.stderr)
    for w, g in itertools.zip_longest(want, got, fillvalue=""):
        print(f"  want {w!r}\n  got  {g!r}", file=sys.stderr)
    return 1


def main() -> int:
    args = sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if args[:1] == ["--self-test"]:
        return self_test()
    if any(a.startswith("-") for a in args):
        print(f"unknown option: {args}", file=sys.stderr)
        return 2
    roots = args or ["~/.claude", ".claude"]
    rows = [r for f in files(roots) for r in lint(f)]
    if not rows:
        return 0
    print("\n".join(rows))
    return 1


if __name__ == "__main__":
    sys.exit(main())
