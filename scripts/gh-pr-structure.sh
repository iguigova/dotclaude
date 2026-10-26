#!/usr/bin/env python3
"""Measure what a PR does to the shape of each source file it changes.

The structure step of /review:pr asks whether a change leaves the code it
touches harder to change. That judgment is the reviewer's; this supplies the
numbers it starts from. Per changed source file:

  * size       — lines at the merge base and at the head, and whether the PR
                 carries the file past THRESHOLD lines. A crossing is a
                 tripwire: it asks "decompose first?", it does not answer it.

Per function the diff touches, at the merge base and at the head, from a real
parse (tree-sitter) of Python, TypeScript, JavaScript, Ruby and Dart:

  * lines       — the function's span, signature to end.
  * complexity  — 1 + its decisions (McCabe): if, elif/elsif/else-if, unless,
                  loops, case/when arms, ternaries, catch/rescue, and each
                  &&, ||, ??, and, or.
  * nesting     — the deepest stack of control structures (if, loops, switch,
                  try, a Ruby block); an else-if continues its chain rather
                  than opening a level.
  * exits       — return, raise, throw.
  * params      — parameters as declared.

A function is a declaration (def, function, a method, a Dart signature with its
body) or a function value bound to a name (`const f = () =>`, `k: (x) => x`,
`f = lambda`, `lam = ->`). An anonymous function value — a callback, a
block — is part of the function it is written in, and its decisions are
counted there.
A function nested in another is measured on its own and is excluded from its
parent's counts.

Each changed line belongs to the innermost function that contains it; a
function is reported only when it owns a changed line, at either commit. It is
matched across the two commits by its qualified name (`Class.method`, with
`#2` for a second definition of one name): one present at both is `modified`,
one only at the head `added`, one only at the base `removed`, and its counts at
the commit it is absent from are null.

A file in a language with no grammar here (haml, erb, shell, …) reports its
size, `functions: null` and `parse_errors: null`, which is unknown, not none.
`parse_errors` lists each place either commit's text did not parse cleanly —
the commit, its lines, and the function they fall in, null when none does. An
error over lines that more than one function owns is one entry per run of
lines with one owner. A named function's counts are the parser's best reading
of a text it misread; an error outside every function can hide a function the
walk missed.
An empty list is a clean parse at both commits. Read every count as where to
look first, never as a finding.

A test file (under spec/ or test/, or named *_spec.* / *_test.* / *.test.* /
*.spec.* / test_*) is marked `test` and ranked after every source file.

Usage:
    gh-pr-structure.sh <pr-ref> --index-file <pr-index.json>
    gh-pr-structure.sh --self-test

The parser is PARSER_PIN, run through `uv`: when it is not importable, the
script re-runs itself under `uv run --with PARSER_PIN`, which installs nothing
outside uv's cache.

The index is gh-pr-diff-index.sh's output. Its head_sha must be the PR's live
head: the files are fetched at that head (gh-pr-file.sh) and at the merge base
(gh-pr-file.sh --base), and an index of another commit would pair one commit's
diff with another's files. An added file starts at zero lines and is not
fetched at the merge base; any other is fetched there under the index's
old_path, so a rename is measured against the file it was. A fetch that fails,
or a path missing where the index says it exists, stops the run: a file read
as empty would report every line as new. Deleted files and files with no
source extension are listed under `skipped`.

Output JSON (to stdout). Files: source before test, then crossings first, then
the largest complexity gain in any function, then the largest nesting gain.
Functions within a file: largest complexity gain first.
    {
      "head_sha": "...",
      "threshold": 1000,
      "files": [
        { "path": "...", "status": "modified" | "added", "test": bool,
          "language": "<grammar>" | null,
          "parse_errors": [ { "commit": "base" | "head",
                              "lines": [first, last],
                              "function": "K.m" | null } ] | null,
          "lines_base": N, "lines_head": N, "crosses_threshold": bool,
          "functions": [
            { "name": "K.m", "status": "modified" | "added" | "removed",
              "lines": [base, head], "complexity": [base, head],
              "nesting": [base, head], "exits": [base, head],
              "params": [base, head] }
          ] | null }
      ],
      "skipped": ["<path>", ...]
    }

Exits non-zero if the ref or index is unusable, the index names a commit other
than the live head, any file cannot be fetched, or the parser cannot be loaded.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
THRESHOLD = 1000
PARSER_PIN = "tree-sitter-language-pack==1.22.1"
UV_MARK = "GH_PR_STRUCTURE_UNDER_UV"

SOURCE_EXT = (".py", ".rb", ".rake", ".ts", ".tsx", ".js", ".jsx", ".mjs",
              ".cjs", ".go", ".clj", ".cljs", ".cljc", ".hs", ".dart", ".sh",
              ".java", ".kt", ".swift", ".haml", ".erb")
GRAMMAR_BY_EXT = {".py": "python", ".rb": "ruby", ".rake": "ruby",
                  ".ts": "typescript", ".tsx": "tsx", ".js": "javascript",
                  ".jsx": "javascript", ".mjs": "javascript",
                  ".cjs": "javascript", ".dart": "dart"}
TEST_RE = re.compile(r"(^|/)(spec|specs|test|tests|__tests__)/"
                     r"|(^|/)test_[^/]*$|[._](spec|test)\.[^/]+$")


def die(msg: str) -> "None":
    print(msg, file=sys.stderr)
    raise SystemExit(1)


# Grammars — the node types each language's parse names for each concept.
# Every name here was read from a parse with PARSER_PIN, not from memory.

JS_LIKE = {
    "scopes": {"class_declaration", "class", "abstract_class_declaration"},
    "declarations": {"function_declaration", "generator_function_declaration",
                     "method_definition"},
    "values": {"arrow_function", "function_expression"},
    "decisions": {"if_statement", "for_statement", "for_in_statement",
                  "while_statement", "do_statement", "switch_case",
                  "ternary_expression", "catch_clause"},
    "logic": {"binary_expression": {"&&", "||", "??"}},
    "nesting": {"if_statement", "for_statement", "for_in_statement",
                "while_statement", "do_statement", "switch_statement",
                "try_statement"},
    "exits": {"return_statement", "throw_statement"},
    "params": "formal_parameters",
}
GRAMMARS = {
    "python": {
        "scopes": {"class_definition"},
        "declarations": {"function_definition"},
        "values": {"lambda"},
        "decisions": {"if_statement", "elif_clause", "conditional_expression",
                      "for_statement", "while_statement", "except_clause",
                      "case_clause", "for_in_clause", "if_clause"},
        "logic": {"boolean_operator": {"and", "or"}},
        "nesting": {"if_statement", "for_statement", "while_statement",
                    "try_statement", "match_statement"},
        "exits": {"return_statement", "raise_statement"},
        "params": "parameters",
    },
    "ruby": {
        "scopes": {"class", "module", "singleton_class"},
        "declarations": {"method", "singleton_method"},
        "values": {"lambda"},
        "decisions": {"if", "unless", "elsif", "if_modifier",
                      "unless_modifier", "while", "until", "while_modifier",
                      "until_modifier", "for", "when", "in_clause",
                      "conditional", "rescue", "rescue_modifier"},
        "logic": {"binary": {"&&", "||", "and", "or"}},
        "nesting": {"if", "unless", "while", "until", "for", "case",
                    "case_match", "begin", "do_block", "block"},
        "exits": {"return"},
        "params": "method_parameters",
    },
    "typescript": JS_LIKE,
    "tsx": JS_LIKE,
    "javascript": JS_LIKE,
    "dart": {
        "scopes": {"class_definition", "mixin_declaration",
                   "extension_declaration", "enum_declaration"},
        "declarations": {"function_body"},
        "values": {"function_expression"},
        "decisions": {"if_statement", "for_statement", "while_statement",
                      "do_statement", "switch_statement_case",
                      "switch_expression_case", "conditional_expression",
                      "catch_clause", "logical_and_operator",
                      "logical_or_operator", "if_null_expression"},
        "logic": {},
        "nesting": {"if_statement", "for_statement", "while_statement",
                    "do_statement", "switch_statement", "try_statement"},
        "exits": {"return_statement", "throw_expression"},
        "params": "formal_parameter_list",
    },
}
# A name bound to a function value: the parent node and the field holding it.
BINDINGS = {"variable_declarator": "name", "pair": "key", "assignment": "left",
            "initialized_variable_definition": "name",
            "public_field_definition": "name", "field_definition": "property"}
RUBY_RAISE = {"raise", "fail"}


# The parser — loaded once, through uv when it is not already importable.

def load_parser():
    try:
        from tree_sitter_language_pack import get_parser
        return get_parser
    except ImportError:
        if os.environ.get(UV_MARK):
            die(f"{PARSER_PIN} did not load under uv")
        uv = shutil.which("uv") or die(f"uv is not installed; it runs "
                                       f"{PARSER_PIN}")
        os.environ[UV_MARK] = "1"
        os.execv(uv, [uv, "run", "-q", "--no-project", "--with", PARSER_PIN,
                      "python", "-I", os.path.abspath(__file__),
                      *sys.argv[1:]])


# Function discovery — pure, over one parsed tree.

def text(node) -> str:
    return node.text.decode("utf-8", "replace") if node is not None else ""


def dart_signature(body):
    """The signature a Dart function_body follows, unwrapped to its name."""
    sig = body.prev_named_sibling
    if sig is not None and sig.type == "method_signature":
        sig = sig.named_children[0] if sig.named_children else sig
    return sig


def binding_name(node) -> "str | None":
    parent = node.parent
    field = BINDINGS.get(parent.type) if parent is not None else None
    bound = parent.child_by_field_name(field) if field else None
    return text(bound) or None


def is_function(node, grammar: dict) -> bool:
    if not node.is_named:
        return False
    if node.type in grammar["declarations"]:
        return True
    return node.type in grammar["values"] and binding_name(node) is not None


def function_name(node, grammar: dict) -> str:
    if node.type == "function_body":
        sig = dart_signature(node)
        named = sig.child_by_field_name("name") if sig is not None else None
        return text(named) or text(sig).split("(")[0].strip() or "<body>"
    if node.type in grammar["values"]:
        return binding_name(node)
    own = text(node.child_by_field_name("name"))
    if node.type == "singleton_method":
        return f"{text(node.child_by_field_name('object'))}.{own}"
    return own or "<anonymous>"


def span(node) -> "tuple[int, int]":
    """1-based first and last line, a Dart body's signature included."""
    start = node
    if node.type == "function_body" and dart_signature(node) is not None:
        start = node.prev_named_sibling
    return start.start_point[0] + 1, node.end_point[0] + 1


def functions(root, grammar: dict) -> "list[dict]":
    found, seen = [], {}

    def walk(node, scope):
        here = scope
        if node.is_named and node.type in grammar["scopes"]:
            name = text(node.child_by_field_name("name"))
            here = scope + [name] if name else scope
        if is_function(node, grammar):
            qual = ".".join(scope + [function_name(node, grammar)])
            seen[qual] = seen.get(qual, 0) + 1
            if seen[qual] > 1:
                qual = f"{qual}#{seen[qual]}"
            first, last = span(node)
            found.append({"name": qual, "node": node,
                          "first": first, "last": last})
            here = scope + [function_name(node, grammar)]
        for child in node.children:
            walk(child, here)

    walk(root, [])
    return found


# Metrics — one function's own body, nested functions excluded.

def params_of(node, grammar: dict) -> int:
    holder = dart_signature(node) if node.type == "function_body" else node
    if holder is None:
        return 0
    plist = holder.child_by_field_name("parameters")
    if plist is None:
        plist = next((c for c in holder.named_children
                      if c.type == grammar["params"]), None)
    if plist is None:
        return 1 if holder.child_by_field_name("parameter") else 0
    if grammar["params"] == "formal_parameter_list":
        return count_type(plist, "formal_parameter")
    return len(plist.named_children)


def count_type(node, kind: str) -> int:
    return (node.type == kind) + sum(count_type(c, kind)
                                     for c in node.named_children)


def is_decision(node, grammar: dict) -> bool:
    if node.type in grammar["decisions"]:
        return True
    ops = grammar["logic"].get(node.type)
    return bool(ops) and text(node.child_by_field_name("operator")) in ops


def is_else_if(node) -> bool:
    parent = node.parent
    return (node.type == "if_statement" and parent is not None
            and parent.type in ("else_clause", "if_statement"))


def is_exit(node, grammar: dict) -> bool:
    if node.type in grammar["exits"]:
        return True
    if grammar is not GRAMMARS["ruby"] or node.type != "identifier":
        return False
    parent = node.parent
    return text(node) in RUBY_RAISE and (
        parent.type != "call" or parent.child_by_field_name("method") == node)


def metrics(fn: dict, grammar: dict) -> dict:
    counts = {"decisions": 0, "nesting": 0, "exits": 0}

    def walk(node, depth):
        if node is not fn["node"] and is_function(node, grammar):
            return
        if node.is_named:
            counts["decisions"] += is_decision(node, grammar)
            counts["exits"] += is_exit(node, grammar)
            if node.type in grammar["nesting"] and not is_else_if(node):
                depth += 1
                counts["nesting"] = max(counts["nesting"], depth)
        for child in node.children:
            walk(child, depth)

    walk(fn["node"], 0)
    return {"lines": fn["last"] - fn["first"] + 1,
            "complexity": 1 + counts["decisions"],
            "nesting": counts["nesting"], "exits": counts["exits"],
            "params": params_of(fn["node"], grammar)}


# One file's record — which functions the diff touched, and their two shapes.

def owner(fns: "list[dict]", line: int) -> "str | None":
    """The innermost function containing a line: the one starting last."""
    holding = [f for f in fns if f["first"] <= line <= f["last"]]
    return max(holding, key=lambda f: f["first"])["name"] if holding else None


def touched(fns: "list[dict]", lines: "list[int]") -> "set[str]":
    return {name for name in (owner(fns, n) for n in lines) if name}


def changed_lines(entry: dict, kind: str, field: str) -> "list[int]":
    return [ln[field] for ln in entry["lines"] if ln["type"] == kind]


def function_rows(entry: dict, base_fns, head_fns, grammar) -> "list[dict]":
    names = (touched(base_fns, changed_lines(entry, "removed", "old_line")) |
             touched(head_fns, changed_lines(entry, "added", "new_line")))
    base = {f["name"]: metrics(f, grammar) for f in base_fns}
    head = {f["name"]: metrics(f, grammar) for f in head_fns}
    rows = []
    for name in names:
        b, h = base.get(name), head.get(name)
        status = "modified" if b and h else ("added" if h else "removed")
        rows.append({"name": name, "status": status,
                     **{k: [b and b[k], h and h[k]]
                        for k in ("lines", "complexity", "nesting", "exits",
                                  "params")}})
    return sorted(rows, key=lambda r: (-gain(r, "complexity"),
                                       -gain(r, "nesting"), r["name"]))


def parse_errors(tree, fns: "list[dict]", commit: str) -> "list[dict]":
    """Each outermost ERROR or MISSING node, cut into runs of lines that one
    function owns."""
    found = []

    def walk(node):
        if node.type == "ERROR" or node.is_missing:
            # A node that ends at column 0 ends on the line before.
            first = node.start_point[0] + 1
            row, column = node.end_point
            last = max(first, row + (column > 0))
            runs = []
            for line in range(first, last + 1):
                name = owner(fns, line)
                if runs and runs[-1]["function"] == name:
                    runs[-1]["lines"][1] = line
                else:
                    runs.append({"commit": commit, "lines": [line, line],
                                 "function": name})
            found.extend(runs)
            return
        for child in node.children:
            if child.has_error:
                walk(child)

    walk(tree.root_node)
    return found


def gain(row: dict, key: str) -> int:
    base, head = row[key]
    return (head or 0) - (base or 0)


def parse(get_parser, grammar_name: str, source: str):
    return get_parser(grammar_name).parse(source.encode("utf-8"))


def file_record(entry: dict, base: str, head: str, get_parser) -> dict:
    ext = os.path.splitext(entry["path"])[1]
    grammar_name = GRAMMAR_BY_EXT.get(ext)
    n_base, n_head = len(base.splitlines()), len(head.splitlines())
    record = {"path": entry["path"], "status": entry["status"],
              "test": bool(TEST_RE.search(entry["path"])),
              "language": grammar_name, "parse_errors": None,
              "lines_base": n_base, "lines_head": n_head,
              "crosses_threshold": n_base <= THRESHOLD < n_head,
              "functions": None}
    if grammar_name is None:
        return record
    grammar = GRAMMARS[grammar_name]
    trees = [parse(get_parser, grammar_name, t) for t in (base, head)]
    fns = [functions(t.root_node, grammar) for t in trees]
    record["parse_errors"] = [e for commit, tree, f in zip(("base", "head"),
                                                           trees, fns)
                              for e in parse_errors(tree, f, commit)]
    record["functions"] = function_rows(entry, *fns, grammar)
    return record


def file_gain(record: dict, key: str) -> int:
    return max((gain(r, key) for r in record["functions"] or []), default=0)


def rank(records: "list[dict]") -> "list[dict]":
    return sorted(records, key=lambda r: (r["test"],
                                          not r["crosses_threshold"],
                                          -file_gain(r, "complexity"),
                                          -file_gain(r, "nesting"),
                                          r["path"]))


def measurable(entry: dict) -> bool:
    return entry["status"] != "deleted" and entry["path"].endswith(SOURCE_EXT)


# I/O — the fetch helpers own the commit and the directory.

def fetch_dir(ref: str, at: "list[str]") -> "tuple[str, str]":
    res = subprocess.run([f"{HERE}/gh-pr-head-dir.sh", *at, ref],
                         capture_output=True, text=True)
    if res.returncode != 0:
        die(res.stderr.strip() or "gh-pr-head-dir.sh failed")
    sha, directory = res.stdout.strip().split("\t")
    return sha, directory


def fetch(ref: str, at: "list[str]", paths: "list[str]") -> None:
    """Every path asked for exists at that commit, so any miss is fatal."""
    if not paths:
        return
    res = subprocess.run([f"{HERE}/gh-pr-file.sh", *at, ref, *paths],
                         capture_output=True, text=True)
    if res.returncode != 0:
        die(res.stderr.strip() or "gh-pr-file.sh failed")


def read(directory: str, path: str) -> str:
    full = os.path.join(directory, path)
    if not os.path.isfile(full):
        return ""
    with open(full, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def base_text(base_dir: str, entry: dict) -> str:
    """An added file starts empty; any other is read under its old path."""
    if entry["status"] == "added":
        return ""
    return read(base_dir, entry["old_path"])


def measure(ref: str, index: dict, get_parser) -> dict:
    if any("old_path" not in e for e in index["files"]):
        die("the index carries no old_path; re-run gh-pr-diff-index.sh")
    entries = [e for e in index["files"] if measurable(e)]
    head_sha, head_dir = fetch_dir(ref, [])
    if index.get("head_sha") != head_sha:
        die(f"index describes {index.get('head_sha')}, the PR head is "
            f"{head_sha}; re-run gh-pr-fetch.sh and gh-pr-diff-index.sh")
    fetch(ref, [], [e["path"] for e in entries])
    fetch(ref, ["--base"], [e["old_path"] for e in entries
                            if e["status"] != "added"])
    _, base_dir = fetch_dir(ref, ["--base"])
    records = [file_record(e, base_text(base_dir, e),
                           read(head_dir, e["path"]), get_parser)
               for e in entries]
    return {"head_sha": head_sha, "threshold": THRESHOLD,
            "files": rank(records),
            "skipped": [e["path"] for e in index["files"]
                        if not measurable(e)]}


# Self-test — every grammar against hand-counted fixtures, offline.

FIXTURES = {
    "python": ("app/k.py", """\
class K:
    def m(self, a, b=1):
        if a and b:
            for x in a:
                if x:
                    return x
        elif b:
            raise E
        return [y for y in a if y]

    def inner_host(self):
        def inner(z):
            return z if z else 0
        return inner
""", {"K.m": {"lines": 8, "complexity": 8, "nesting": 3, "exits": 3,
              "params": 3},
     "K.inner_host.inner": {"lines": 2, "complexity": 2, "nesting": 0,
                            "exits": 1, "params": 1},
     "K.inner_host": {"lines": 4, "complexity": 1, "nesting": 0,
                      "exits": 1, "params": 1}}),
    "ruby": ("app/k.rb", """\
module M
  class K
    def m(a, b = 1, *c, d:, &f)
      if a && b
        a.each do |i|
          return i if i
        end
      elsif b || c
        raise E
      end
      x = a ? 1 : 2
      case x
      when 1 then 1
      when 2 then 2
      end
    end

    def self.s; end
  end
end
""", {"M.K.m": {"lines": 14, "complexity": 9, "nesting": 2, "exits": 2,
                "params": 5},
      "M.K.self.s": {"lines": 1, "complexity": 1, "nesting": 0, "exits": 0,
                     "params": 0}}),
    "typescript": ("src/k.ts", """\
export class K {
  m(a: number, b = 1): number {
    if (a && b) {
      return 1;
    } else if (b ?? a) {
      try { throw new Error(); } catch (e) { return 2; }
    }
    [a].forEach((v) => { if (v) { return; } });
    return a ? 3 : 4;
  }
}
const g = (z: number) => z || 0;
""", {"K.m": {"lines": 9, "complexity": 8, "nesting": 2, "exits": 5,
              "params": 2},
     "g": {"lines": 1, "complexity": 2, "nesting": 0, "exits": 0,
           "params": 1}}),
    "dart": ("lib/k.dart", """\
class K {
  int m(int a, {int b = 1}) {
    if (a > 0 && b > 0) {
      return 1;
    } else if (b > 0) {
      for (var i in [a]) {
        if (i > 0) return i;
      }
    }
    final g = (int z) => z > 0 ? z : 0;
    return a ?? 0;
  }
  int get v => 1;
}
""", {"K.m": {"lines": 11, "complexity": 7, "nesting": 3, "exits": 3,
              "params": 2},
      "K.m.g": {"lines": 1, "complexity": 2, "nesting": 0, "exits": 0,
                "params": 1},
      "K.v": {"lines": 1, "complexity": 1, "nesting": 0, "exits": 0,
              "params": 0}}),
}


def _entry(path: str, status: str, added: "list[int]",
           removed: "list[int]") -> dict:
    lines = ([{"type": "added", "new_line": n, "old_line": None}
              for n in added] +
             [{"type": "removed", "new_line": None, "old_line": n}
              for n in removed])
    return {"path": path, "old_path": None if status == "added" else path,
            "status": status, "lines": lines}


def _self_test(get_parser) -> int:
    fails = []

    def want(cond: bool, msg: str) -> None:
        if not cond:
            fails.append(msg)

    # Each grammar: every function found, each count as hand-counted.
    for lang, (path, source, expected) in FIXTURES.items():
        tree = parse(get_parser, lang, source)
        want(not tree.root_node.has_error, f"{lang} fixture does not parse")
        fns = functions(tree.root_node, GRAMMARS[lang])
        got = {f["name"]: metrics(f, GRAMMARS[lang]) for f in fns}
        want(set(got) == set(expected),
             f"{lang} functions {sorted(got)}, want {sorted(expected)}")
        for name, want_m in expected.items():
            want(got.get(name) == want_m,
                 f"{lang} {name}: {got.get(name)}, want {want_m}")

    # A changed line belongs to its innermost function only.
    path, source, _ = FIXTURES["python"]
    edit = _entry(path, "modified", [13], [])
    rows = file_record(edit, source, source, get_parser)["functions"]
    want([r["name"] for r in rows] == ["K.inner_host.inner"],
         f"line 13 owners {[r['name'] for r in rows]}")

    # Matching: a branch added to K.m is a modified row with both shapes; a
    # function only at the head is added; one only at the base is removed.
    base = "def keep(a):\n    return a\n\ndef gone():\n    pass\n"
    head = ("def keep(a):\n    if a:\n        return a\n    return 0\n\n"
            "def new(b, c):\n    return b\n")
    rec = file_record(_entry("m.py", "modified", [2, 3, 4, 6, 7], [4, 5]),
                      base, head, get_parser)
    by = {r["name"]: r for r in rec["functions"]}
    want(by.get("keep", {}).get("complexity") == [1, 2]
         and by["keep"]["status"] == "modified", f"keep row {by.get('keep')}")
    want(by.get("new", {}).get("status") == "added"
         and by["new"]["params"] == [None, 2], f"new row {by.get('new')}")
    want(by.get("gone", {}).get("status") == "removed"
         and by["gone"]["lines"] == [2, None], f"gone row {by.get('gone')}")
    want(rec["functions"][0]["name"] == "keep",
         f"function rank {[r['name'] for r in rec['functions']]}")

    # Size: a crossing is base at or under the threshold and head over it.
    cross = file_record(_entry("big.py", "modified", [], []),
                        "x = 1\n" * 990, "x = 1\n" * 1011, get_parser)
    over = file_record(_entry("over.py", "modified", [], []),
                       "x = 1\n" * 1010, "x = 1\n" * 1020, get_parser)
    want(cross["crosses_threshold"], "990 -> 1011 lines must cross")
    want(not over["crosses_threshold"], "1010 -> 1020 is over, not crossing")

    # No grammar: size only, functions and parse errors unknown. A broken
    # parse names its commit, its lines and the function they fall in.
    haml = file_record(_entry("v.haml", "modified", [1], []), "%p\n",
                       "%p\n%p\n", get_parser)
    want(haml["functions"] is None and haml["parse_errors"] is None
         and haml["lines_head"] == 2, f"haml record {haml}")
    clean = "def clean(a):\n    return a\n"
    broken = file_record(
        _entry("b.py", "modified", [4, 5], []), clean,
        clean + "\ndef hit(b):\n    return b +\n\nx = (\n", get_parser)
    want(broken["parse_errors"] == [
        {"commit": "head", "lines": [5, 5], "function": "hit"},
        {"commit": "head", "lines": [7, 7], "function": None}],
         f"broken parse errors {broken['parse_errors']}")
    want(rec["parse_errors"] == [], f"clean parse errors {rec['parse_errors']}")
    # One error over a function and a line it hides is two runs, and a trailing
    # newline adds no line: acme-hub's HomeLocationTCForm.tsx, shrunk.
    section = "const Section = ({\n}: Props) => (\n  <div>{t}</div>\n);\n"
    wrapped = file_record(_entry("w.tsx", "modified", [5], []), section,
                          section + "  onSubmit: async (v) => {\n", get_parser)
    want(wrapped["parse_errors"] == [
        {"commit": "head", "lines": [1, 4], "function": "Section"},
        {"commit": "head", "lines": [5, 5], "function": None}],
         f"wrapped parse errors {wrapped['parse_errors']}")

    # Test paths, and only test paths, are marked; tests rank last.
    for tpath, is_test in {"spec/a_spec.rb": True, "app/tests/x.py": True,
                           "src/x.test.ts": True, "pkg/x_test.go": True,
                           "test_x.py": True, "app/latest.rb": False,
                           "app/contest_service.rb": False}.items():
        got = bool(TEST_RE.search(tpath))
        want(got == is_test, f"test({tpath}) = {got}, want {is_test}")
    spec = file_record(_entry("spec/z_spec.rb", "modified", [], []), "", "",
                       get_parser)
    order = [r["path"] for r in rank([spec, rec, over, cross])]
    want(order == ["big.py", "m.py", "over.py", "spec/z_spec.rb"],
         f"file rank {order}")

    # A rename is read at the merge base under its old path; an added file is
    # never read there, so a stray file at its path cannot leak in.
    with tempfile.TemporaryDirectory() as tmp:
        for name, body in {"old.py": "a\nb\n", "fresh.py": "stray\n"}.items():
            with open(os.path.join(tmp, name), "w", encoding="utf-8") as fh:
                fh.write(body)
        renamed = {"path": "new.py", "old_path": "old.py",
                   "status": "modified"}
        added = {"path": "fresh.py", "old_path": None, "status": "added"}
        want(base_text(tmp, renamed) == "a\nb\n", "rename not read at old path")
        want(base_text(tmp, added) == "", "an added file was read at the base")

    # Deleted files and non-source files are skipped, not measured.
    want(not measurable(_entry("gone.py", "deleted", [], [])), "deleted kept")
    want(not measurable(_entry("README.md", "modified", [], [])), ".md kept")
    want(measurable(_entry("app/x.rb", "modified", [], [])), ".rb skipped")

    if fails:
        print("gh-pr-structure self-test: FAIL\n  " + "\n  ".join(fails),
              file=sys.stderr)
        return 1
    print(f"gh-pr-structure self-test: PASS ({len(FIXTURES)} grammars against "
          "hand-counted fixtures, innermost-function ownership, "
          "modified/added/removed matching, threshold crossing, no-grammar "
          "files, parse errors split into runs by commit, line and function, "
          "test-path marking, ranking, rename base path, skip rules)")
    return 0


def main() -> None:
    args = sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        raise SystemExit(0)
    if args[:1] == ["--self-test"]:
        raise SystemExit(_self_test(load_parser()))
    if len(args) != 3 or args[1] != "--index-file":
        die("Usage: gh-pr-structure.sh <pr-ref> --index-file <pr-index.json>"
            " | --self-test")
    with open(args[2], encoding="utf-8") as fh:
        index = json.load(fh)
    print(json.dumps(measure(args[0], index, load_parser()), indent=2))


if __name__ == "__main__":
    main()
