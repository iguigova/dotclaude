#!/usr/bin/env python3
"""Fail a shell flag that takes a value without flag_value.sh's check.

    flag_lint.py FILE ...
    flag_lint.py --self-test

A case arm for a flag, such as `--review) REVIEW="$2"; shift 2 ;;`, shifts 2
to take the flag and its value. When the flag is the last word, `shift 2`
fails and shifts nothing, so the parsing loop meets the same flag forever, or
under -u the arm dies on an unbound $2. flag_value.sh holds the one check, so
every such arm calls `flag_value "$@"` (or `flag_value --may-be-empty "$@"`)
before it reads $2.

An arm whose label is a flag (it starts with -) and whose body, up to its ;;,
holds `shift 2` must hold that call, or a comment `# flag_value: <reason>`
saying why the arm needs none, such as a stub of a command whose caller always
passes the value.

Exit 0 when every file is clean, 1 when any is not, 2 when no file is named.
Each problem prints as file:line: <label>) — what is wrong.
"""
import contextlib
import io
import pathlib
import re
import sys

from tap import Tap, scratch

# A label starts a line, or follows `case … in` or the ;; of the arm before.
ARM = re.compile(r"(?:^[ \t]*|\bin[ \t]+|;;[ \t]+)\(?(-[\w-]*(?:\|-[\w-]*)*)\)(.*?)(?=;;)", re.S | re.M)
SHIFT_2 = re.compile(r"\bshift 2\b")
CHECKED = re.compile(r'\bflag_value (?:--may-be-empty )?"\$@"')
EXEMPT = re.compile(r"# flag_value: \S")


def to_line_end(text: str, arm: re.Match) -> str:
    """The arm and the rest of the line its ;; ends, where a comment on it sits."""
    return arm.group(0) + text[arm.end():].split("\n", 1)[0]


def unchecked(text: str, arm: re.Match) -> bool:
    body = arm.group(2)
    return bool(SHIFT_2.search(body)) and not (
        CHECKED.search(body) or EXEMPT.search(to_line_end(text, arm)))


def problems(path: pathlib.Path) -> list[str]:
    """Each flag arm in path that shifts 2 unchecked, as file:line: label."""
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        return [f"{path}: not readable: {e}"]
    return [f"{path}:{text.count(chr(10), 0, m.start()) + 1}: {m.group(1)}) shifts 2"
            ' without flag_value "$@"'
            for m in ARM.finditer(text) if unchecked(text, m)]


def run(paths: list[pathlib.Path]) -> int:
    found = [p for path in paths for p in problems(path)]
    for p in found:
        print(p)
    return 1 if found else 0


def self_test() -> int:
    t = Tap()

    def check(desc, want, got):
        t.check(want == got, desc, f"want: {want}", f"got:  {got}")

    with scratch():
        import tempfile
        root = pathlib.Path(tempfile.mkdtemp())

        def lint(text):
            f = root / "s.sh"
            f.write_text(text)
            return problems(f)

        check("an arm taking its value through flag_value is clean", [],
              lint('case "$1" in\n  --x) flag_value "$@"; X="$2"; shift 2 ;;\nesac\n'))
        check("--may-be-empty counts as the check", [],
              lint('  --x) flag_value --may-be-empty "$@"; X="$2"; shift 2 ;;\n'))
        check("an unchecked arm is named with its line", [f"{root}/s.sh:2: --x) shifts 2"
              ' without flag_value "$@"'], lint('case "$1" in\n  --x) X="${2:-}"; shift 2 ;;\nesac\n'))
        check("an arm spanning lines is read to its ;;", 1,
              len(lint('  --field)\n    f="$2"\n    shift 2 ;;\n')))
        check("each label of an alternation arm is one label", ["-t|--topic"],
              [p.split(": ")[1].split(")")[0] for p in lint('  -t|--topic) t="$2"; shift 2 ;;\n')])
        check("one line holding several arms judges each", 2,
              len(lint('case "$1" in -o) o="$2"; shift 2 ;; -d) d="$2"; shift 2 ;; *) shift ;; esac\n')))
        check("an arm that shifts once is no concern", [], lint('  --dry-run) D=1; shift ;;\n'))
        check("a non-flag arm is no concern", [], lint('  start) m="$2"; shift 2 ;;\n'))
        check("a parameter default is not a label", [],
              lint('x="${1:-}") y; shift 2 ;;\n'))
        check("a flag inside a string is not a label", [],
              lint("  echo '  (--dry-run)'\n  f \"$2\"; shift 2 ;;\n"))
        check("a stated exemption is clean", [],
              lint('  -o) out="$2"; shift 2 ;;  # flag_value: a stub of curl\n'))
        check("an exemption needs its reason", 1,
              len(lint('  -o) out="$2"; shift 2 ;;  # flag_value:\n')))
        check("an unreadable file is a problem, not a pass", True,
              "not readable" in problems(root / "gone.sh")[0])
        check("a clean run exits 0", 0, run([]))
        (root / "bad.sh").write_text('  --x) X="$2"; shift 2 ;;\n')
        with contextlib.redirect_stdout(io.StringIO()) as out:
            rc = run([root / "bad.sh"])
        check("a problem exits 1 and is printed", (1, 1), (rc, out.getvalue().count("\n")))
        check("an exemption on a later line covers no arm above it", 1,
              len(lint('  -o) out="$2"; shift 2 ;;\n  # flag_value: elsewhere\n')))
        with contextlib.redirect_stderr(io.StringIO()):
            check("no file named is a usage error", 2, main([]))
        (root / "clean.sh").write_text('  --x) flag_value "$@"; X="$2"; shift 2 ;;\n')
        check("a named clean file exits 0", 0, main([str(root / "clean.sh")]))
    return t.end()


def main(args: list[str]) -> int:
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if args[:1] == ["--self-test"]:
        return self_test()
    if not args:
        print("flag_lint.py: name the shell files to read (--help)", file=sys.stderr)
        return 2
    return run([pathlib.Path(a) for a in args])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
