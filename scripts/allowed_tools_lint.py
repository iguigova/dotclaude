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
import os
from functools import partial
import pathlib
import re
import shutil
import string
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from skill_inventory import skills_in, commands_in   # noqa: E402
from tap import Tap   # noqa: E402

# https://code.claude.com/docs/en/permissions, "Read-only commands". git is
# read-only only in some forms, so it is not here. cd is read-only only into a
# working directory, which a file cannot show, so a cd anywhere passes.
READ_ONLY = {"ls", "cat", "echo", "pwd", "head", "tail", "grep", "find", "wc",
             "which", "diff", "stat", "du", "cd"}

FENCE = re.compile(r"^\s*```(\w*)\s*$")
SPAN = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
MD_REF = re.compile(r"`(\.claude/[^`\s]+\.md)`")
SHELLS = {"bash", "sh", "shell"}

CONTINUATION = re.compile(r"\\\n\s*")
QUOTED = re.compile(r"'[^']*'?|\"[^\"]*\"?")
PLACEHOLDER = re.compile(r"<[A-Za-z][^<>\n]*>")
COMMENT = re.compile(r"#[^\n]*")
SEPARATOR = re.compile(r"[;|&\n][|&]*")
OPENERS = "{(" + string.whitespace


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


# --- Splitting a block into subcommands --------------------------------------
# A token is (text, end), its text None for a separator. Each scanner returns
# None where its kind of token does not start, and the first that matches wins.

def split(block: str) -> list[str]:
    """Subcommands of a shell block, quotes and $( ) kept whole."""
    pieces = [_trim(p) for p in _pieces(CONTINUATION.sub(" ", block))]
    return [p for p in pieces if p not in ("", "}", ")")]


def _pieces(block: str) -> list[str]:
    """The block's text between separators."""
    out, cur, i = [], "", 0
    while i < len(block):
        text, i = _token(block, i, cur[-1:])
        if text is None:
            out.append(cur)
            cur = ""
        else:
            cur += text
    return out + [cur]


def _token(block: str, i: int, prev: str) -> tuple[str | None, int]:
    scanners = (_quoted, _placeholder, _subst, partial(_comment, prev),
                partial(_redirect, prev), _separator)
    return _first(scanners, block, i)


def _first(scanners, block: str, i: int) -> tuple[str | None, int]:
    """The first scanner's token, else the one character at i."""
    for scan in scanners:
        if (hit := scan(block, i)) is not None:
            return hit
    return block[i], i + 1


def _matched(pattern: re.Pattern, block: str, i: int):
    m = pattern.match(block, i)
    return (m.group(0), m.end()) if m else None


def _quoted(block, i):
    return _matched(QUOTED, block, i)


def _placeholder(block, i):
    return _matched(PLACEHOLDER, block, i)


def _subst(block, i):
    """A $( … ) to its closing bracket, its quotes and $( ) kept whole."""
    if not block.startswith("$(", i):
        return None
    j = i + 2
    while j < len(block) and block[j] != ")":
        j = _first((_quoted, _placeholder, _subst), block, j)[1]
    return block[i:j + 1], j + 1


def _comment(prev, block, i):
    """A # that starts a word runs to the line's end and is dropped."""
    mid_word = prev and not prev.isspace()
    if block[i] != "#" or mid_word:
        return None
    return "", _matched(COMMENT, block, i)[1]


def _redirect(prev, block, i):
    """The & of >&, <& or &> redirects, and separates nothing."""
    after_arrow = prev in ("<", ">")
    before_arrow = block[i + 1:i + 2] == ">"
    if block[i] != "&" or not (after_arrow or before_arrow):
        return None
    return "&", i + 1


def _separator(block, i):
    hit = _matched(SEPARATOR, block, i)
    return (None, hit[1]) if hit else None


def _trim(piece: str) -> str:
    """A piece without the brackets of the group or subshell it opens or
    closes."""
    s = piece.lstrip(OPENERS).rstrip()
    for o, c in (("(", ")"), ("{", "}")):
        s = _drop_unmatched(s, o, c)
    return s


def _drop_unmatched(s: str, o: str, c: str) -> str:
    while s.endswith(c) and s.count(c) > s.count(o):
        s = s[:-1].rstrip()
    return s


# Same page, "Process wrappers": stripped before a rule is matched, with the
# options and the duration or niceness they take; xargs only when bare.
WRAPPERS = {"timeout", "time", "nice", "nohup", "stdbuf", "command", "builtin"}
WITH_ARG = {"timeout": {"-k", "-s", "--kill-after", "--signal"},
            "nice": {"-n", "--adjustment"},
            "stdbuf": {"-i", "-o", "-e"}}


def unwrap(cmd: str) -> str:
    """The command a wrapper runs, as the matcher sees it."""
    words = cmd.split()
    while (inner := _unwrap_once(words)) is not None:
        words = inner
    return " ".join(words)


def _unwrap_once(words: list[str]) -> list[str] | None:
    """The words inside one wrapper, None when the first word is none."""
    if len(words) > 1 and words[0] == "xargs" and words[1][0] != "-":
        return words[1:]
    if words[:1] and words[0] in WRAPPERS:
        return _wrapped(words[0], words[1:])
    return None


def _wrapped(wrapper: str, words: list[str]) -> list[str]:
    """The words after a wrapper's options and the duration timeout takes."""
    while words[:1] and words[0].startswith("-"):
        opt, words = words[0], words[1:]
        if opt in WITH_ARG.get(wrapper, ()):
            words = words[1:]
    return words[1:] if wrapper == "timeout" else words


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
    found = [(path, n, c) for n, shell in _snippets(text, root)
             for c in split(shell)]
    for ref in sorted(set(MD_REF.findall(text))):
        found += commands(root / ref, root, seen)
    return found


def _snippets(text: str, root: pathlib.Path):
    """(line, shell text) for each fenced shell block and each span that
    runs an executable."""
    for n, lang, chunk in _regions(text):
        if lang is None:
            yield from ((n, s) for s in _spans(chunk, root))
        elif lang in SHELLS:
            yield n, chunk


def _regions(text: str):
    """(line, lang, text) for each fenced block, lang its fence's; and for
    each body line outside one, lang None. An unclosed block is dropped."""
    _, start = frontmatter(text)
    block, lang, at = None, "", 0
    for n, ln in enumerate(text.split("\n")[start - 1:], start):
        fence = FENCE.match(ln)
        if fence and block is None:
            block, lang, at = [], fence.group(1), n + 1
        elif fence:
            yield at, lang, "\n".join(block)
            block = None
        elif block is not None:
            block.append(ln)
        else:
            yield n, None, ln


def _spans(line: str, root: pathlib.Path) -> list[str]:
    spans = [s.group(1) for s in SPAN.finditer(line)]
    return [s for s in spans if s.split() and executable(s.split()[0], root)]


def lint(path: pathlib.Path) -> list[str]:
    rules = bash_rules(frontmatter(path.read_text())[0])
    if rules is None:
        return []
    ran = unwrapped(commands(path.resolve(), project_root(path), set()))
    rows = [f"{f}:{n}\tunruled\t{c}" for f, n, c in ran if unruled(rules, c)]
    return rows + [f"{path}\tunused\tBash({r})" for r in unused(rules, ran)]


def unwrapped(found: list) -> list:
    """(path, line, command) with each wrapper dropped, and a bare wrapper
    dropped whole."""
    ran = [(f, n, unwrap(c)) for f, n, c in found]
    return [(f, n, c) for f, n, c in ran if c]


def unused(rules: list[str], ran: list) -> list[str]:
    used = {r for _, _, c in ran for r in rules if admits(r, c)}
    return [r for r in rules if r not in used]


def project_root(path: pathlib.Path) -> pathlib.Path:
    """The folder holding the file's .claude, else the file's own folder."""
    parts = path.resolve().parts
    if ".claude" not in parts:
        return path.resolve().parent
    return pathlib.Path(*parts[:parts.index(".claude")])


def unruled(rules: list[str], cmd: str) -> bool:
    admitted = any(admits(r, cmd) for r in rules)
    return not admitted and cmd.split()[0] not in READ_ONLY


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
        cmd_root = project_root(cmd)
    want = [".claude/commands/c.md:7\tunruled\ttest -r f",
            ".claude/commands/c.md:7\tunruled\texit 1",
            ".claude/commands/c.md:7\tunruled\tgit push",
            ".claude/commands/c.md:7\tunruled\tjob.sh <a|b> <id>",
            ".claude/commands/c.md\tunused\tBash(curl:*)"]
    t = Tap()
    for w in want:
        _, kind, what = w.split("\t")
        t.check(w in got, f"flagged {kind}: {what}")
    t.check(got == want,
            "nothing else is flagged, past a read file's piped span, a quoted"
            " ';', a redirect's '&', a continuation and a comment",
            *got)
    t.check(admits("git:*", "git"), "git:* admits git")
    t.check(admits("git:*", "git status"), "git:* admits git status")
    t.check(not admits("git:*", "gitk"), "git:* does not admit gitk")
    t.check(admits("ls*", "lsof"), "ls* admits lsof")
    t.check(not admits("ls *", "lsof"), "ls * does not admit lsof")
    t.check(split("echo $(date) && (cd a && make)")
            == ["echo $(date)", "cd a", "make"],
            "a $( ) stays whole and a subshell splits into its commands")
    t.check(split("x=$(a | b $(c; d) e); f") == ["x=$(a | b $(c; d) e)", "f"],
            "a separator inside a nested $( ) splits nothing")
    t.check(split("echo $(a") == ["echo $(a"],
            "an unclosed $( runs to the block's end")
    t.check(split("a &>/dev/null; b") == ["a &>/dev/null", "b"],
            "the & of &> redirects and separates nothing")
    t.check(split("a\n\n  b") == ["a", "b"],
            "a blank line in a block separates and adds no command")
    t.check([unwrap(c) for c in ("timeout -k 5 120 foo -x", "nice -n 5 foo",
                                 "stdbuf -oL foo", "time nohup foo",
                                 "xargs foo", "xargs -0 foo", "xargs")]
            == ["foo -x", "foo", "foo", "foo", "foo", "xargs -0 foo",
                "xargs"],
            "a process wrapper is read as the command it runs")
    t.check(by_root == [cmd], "a root's commands are found")
    t.check(cmd_root == root.resolve(),
            "a file under .claude has the folder holding it as its root")
    t.check(project_root(pathlib.Path("/usr/bin/env"))
            == pathlib.Path("/usr/bin"),
            "a file under no .claude has its own folder as its root")
    return t.end()


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
