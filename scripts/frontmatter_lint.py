#!/usr/bin/env python3
"""Lint the YAML frontmatter of every skill and command under each root.

    frontmatter_lint.py [ROOT ...]   # default: ~/.claude and the cwd's .claude
    frontmatter_lint.py --self-test

A skill or command is routed by its frontmatter before the file is opened, so a
block that is absent, unparseable or silently the wrong type costs the whole file
its routing and says nothing while doing it.

Nothing else reads these blocks strictly, and that is deliberate: the census in
skill_inventory.py reads them with a line regex so it can still describe a file
that is malformed. A lenient reader cannot be a gate, and a gate cannot be the
census, so the two readers are separate on purpose. What they share is which
files exist — this walks the tree with the census's own skills_in/commands_in, so
the gate can never cover fewer files than the census lists.

Enforced:

  opens with --- on line 1 and the block closes with ---
  the block is strict YAML and a mapping
  no duplicate key, which YAML resolves last-wins without complaint
  description and argument-hint are present, and are non-empty strings
  a skill also carries name, matching its directory

The string rule catches most. `argument-hint: [TICKET | --all]` unquoted is a
YAML flow sequence and `description: Do X: then Y` is a mapping. Both parse, so
nothing else objects — they are simply not the string the reader wanted.

Exit 0 when every file is clean, 1 when any is not. Each problem prints as
path:key — what is wrong, so the verdict is always attributable to one file.
"""
import sys
import pathlib
import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from skill_inventory import skills_in, commands_in   # noqa: E402
from tap import Tap   # noqa: E402

REQUIRED = ("description", "argument-hint")


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses a duplicate key instead of taking the last one."""


def _no_dups(loader, node, deep=False):
    seen, mapping = set(), {}
    for k, v in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in seen:
            raise yaml.YAMLError(f"duplicate key {key!r}")
        seen.add(key)
        mapping[key] = loader.construct_object(v, deep=deep)
    return mapping


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dups)


def block(text: str):
    """The frontmatter text, or None with the reason it could not be read."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, "no frontmatter: line 1 is not ---"
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i]), None
    return None, "the frontmatter block is never closed by a second ---"


def lint(item: dict) -> list[str]:
    """Every problem in one census item, as a list of strings."""
    path = pathlib.Path(item["path"])
    where = f"{item['scope']}:{item['kind']}:{item['name']}"
    text, why = block(path.read_text(encoding="utf-8", errors="replace"))
    if why:
        return [f"{where} — {why}"]
    try:
        fm = yaml.load(text, Loader=StrictLoader)
    except yaml.YAMLError as e:
        return [f"{where} — the frontmatter is not strict YAML: {str(e).splitlines()[0]}"]
    if not isinstance(fm, dict):
        return [f"{where} — the frontmatter is {type(fm).__name__}, not a mapping"]

    out = []
    for key in list(REQUIRED) + (["name"] if item["kind"] == "skill" else []):
        if key not in fm:
            out.append(f"{where}:{key} — missing")
        elif not isinstance(fm[key], str):
            out.append(f"{where}:{key} — parsed as {type(fm[key]).__name__}, not a string; quote it")
        elif not fm[key].strip():
            out.append(f"{where}:{key} — empty")
    if item["kind"] == "skill" and isinstance(fm.get("name"), str) and fm["name"] != item["name"]:
        out.append(f"{where}:name — {fm['name']!r} does not match its directory {item['name']!r}")
    return out


def items_under(root: pathlib.Path, scope: str) -> list[dict]:
    return skills_in(root, scope) + commands_in(root, scope)


def run(roots) -> int:
    items = []
    for r in roots:
        root = pathlib.Path(r)
        items += items_under(root, "global" if root == pathlib.Path.home() / ".claude" else "project")
    problems = [p for it in items for p in lint(it)]
    for p in problems:
        print(f"  {p}")
    print(f"frontmatter_lint: {len(items)} files, errors={len(problems)}")
    print("frontmatter_lint: " + ("PASS" if not problems else "FAIL"))
    return 1 if problems else 0


def self_test() -> int:
    import tempfile
    t = Tap()

    def check(desc, want, got):
        t.check(want == got, desc, f"want: {want}", f"got:  {got}")

    good = '---\ndescription: does a thing\nargument-hint: "[x]"\n---\nbody\n'

    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)

        def write(rel, body):
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body)
            return p

        def problems(rel, body):
            """Lint one file through the census walker, exactly as a run does."""
            write(rel, body)
            name = pathlib.Path(rel).parent.name if rel.endswith("SKILL.md") else pathlib.Path(rel).stem
            return [p for it in items_under(root, "test") for p in lint(it) if it["name"] == name]

        check("a complete command is clean", [], problems("commands/good.md", good))
        check("a complete skill is clean", [],
              problems("skills/s/SKILL.md", '---\nname: s\ndescription: d\nargument-hint: "[x]"\n---\n'))
        check("a command is not asked for a name", [], problems("commands/noname.md", good))

        # One file per rule, breaking that rule and nothing else.
        def first(rel, body):
            p = problems(rel, body)
            return p[0] if p else "NO PROBLEM REPORTED"

        check("no frontmatter at all is named as such", True,
              "line 1 is not ---" in first("commands/nofm.md", "# just a heading\n"))
        check("an unclosed block is named as unclosed", True,
              "never closed" in first("commands/unclosed.md", "---\ndescription: d\n"))
        check("a missing argument-hint is named by key", True,
              first("commands/nohint.md", "---\ndescription: d\n---\n").endswith("argument-hint — missing"))
        # The trap: both of these parse, so nothing else would object.
        check("an unquoted flow sequence is not a string", True,
              "not a string" in first("commands/seq.md", "---\ndescription: d\nargument-hint: [A | B]\n---\n"))
        check("an unquoted colon makes a mapping, not a string", True,
              "not a string" in first("commands/map.md", "---\ndescription: d\nargument-hint:\n  a: b\n---\n"))
        check("an empty value is not the same as a present one", True,
              "empty" in first("commands/empty.md", '---\ndescription: d\nargument-hint: ""\n---\n'))
        check("a duplicate key is refused, not resolved last-wins", True,
              "duplicate key" in first("commands/dup.md", "---\ndescription: a\ndescription: b\nargument-hint: x\n---\n"))
        check("a skill whose name misses its directory is named", True,
              "does not match its directory" in
              first("skills/actual/SKILL.md", '---\nname: other\ndescription: d\nargument-hint: "x"\n---\n'))

        # The walker is the census's, so a symlinked skill is excluded from the
        # gate exactly as it is from the census — neither is ours to lint.
        (root / "skills/linked").mkdir(parents=True, exist_ok=True)
        (root / "skills/linked/SKILL.md").symlink_to(root / "commands/nofm.md")
        check("a symlinked skill is not ours, so the gate skips it too", [],
              [p for it in items_under(root, "test") for p in lint(it) if it["name"] == "linked"])
    return t.end()


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--self-test"]:
        sys.exit(self_test())
    roots = args or [pathlib.Path.home() / ".claude", pathlib.Path.cwd() / ".claude"]
    sys.exit(run([r for r in roots if pathlib.Path(r).is_dir()]))
