#!/usr/bin/env python3
"""Index a GitHub PR's unified diff: postable lines + added imports.

Walks the diff once and, per changed file, emits:
  * every line a review comment can legally anchor to, with its
    post-merge (new-file) and pre-merge (old-file) line number and side —
    this is the single source of truth for /review:pr line numbers AND for
    the line-validation in gh-pr-review-post.sh (a comment on a line not in
    the diff makes the GitHub reviews API 422 the *whole* review).
  * the import/require lines the diff ADDS, for the import-boundary step.
    Each carries `in_docstring`: a syntactically valid import inside a
    triple-quoted string is an example, not a dependency.

A comment is postable on:
  RIGHT side -> any added ('+') or context (' ') line   -> use its new_line
  LEFT  side -> any removed ('-') or context (' ') line -> use its old_line

Header lines are told from hunk content by POSITION, not by prefix: a hunk's
`@@ -a,b +c,d @@` states how many old and new lines it carries, and the walk
stays inside the hunk until both are consumed. Inside a hunk the first
character is the marker and nothing else, so a removed SQL or Haskell comment
(`-- note`, arriving as `--- note`) is a removed line, not a `--- a/path`
header. Outside a hunk, `+++ /dev/null` marks a deletion and the path comes
from the `--- a/path` line, so a deleted file gets its own record instead of
its lines landing on the previous file.

Usage:
    gh-pr-diff-index.sh <pr-ref>
    gh-pr-diff-index.sh --diff-file <path> [--head-sha <sha>]
    gh-pr-diff-index.sh --self-test

<pr-ref> is one of:
    https://github.com/Org/repo/pull/123
    Org/repo#123
    #123                 (uses CWD's git remote)

Output JSON (to stdout):
    {
      "head_sha": "<the commit the diff describes, or null>",
      "files": [
        { "path": "...",
          "old_path": "<the path at the merge base, or null for an added file>",
          "status": "modified" | "added" | "deleted",
          "lines":   [ {old_line, new_line, side, type, text} ],
          "imports": [ {new_line, lang, in_docstring, text} ] }
      ]
    }

`head_sha` is the PR's headRefOid when the index fetched the diff itself, or
whatever `--head-sha` passed in; it is what gh-pr-review-post.sh checks the PR
against before posting, so a review is never anchored to a commit it did not
read. It is null only when a saved diff was indexed without one.

Exits non-zero if the gh call fails or the ref is unrecognized.
"""
from __future__ import annotations

import ast
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gh_pr_ref import RefError, parse_slug  # noqa: E402
from tap import Tap  # noqa: E402


def die(msg: str) -> "None":
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def run(cmd: "list[str]", check: bool = True) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        if check:
            die(res.stderr.strip() or f"command failed: {' '.join(cmd)}")
        return ""
    return res.stdout


def fetch(ref: str) -> "tuple[str, str | None]":
    """(diff text, head sha) for a PR reference."""
    try:
        _, _, number, slug = parse_slug(ref)
    except RefError as exc:
        die(str(exc))
    diff = run(["gh", "pr", "diff", number, "--repo", slug])
    meta = run(["gh", "pr", "view", number, "--repo", slug,
                "--json", "headRefOid"], check=False)
    sha = None
    if meta.strip():
        try:
            sha = json.loads(meta).get("headRefOid")
        except json.JSONDecodeError:
            sha = None
    return diff, sha


# An added line is an import if, after stripping the leading '+', it PARSES as
# one. A line-shape regex is not enough: `from that mix, and derive a different
# SCALE` is English prose in a docstring and matched the old `^\s*(import|from)\s`,
# so a boundary step got told to judge a sentence. Python is checked with the
# real parser; JS requires the module specifier's quote, which prose never has.
JS_IMPORT = re.compile(
    r"""  ^\s*import\s+[^;]*?\bfrom\s*['"`]    # import X from 'y'
        | ^\s*import\s*['"`]                   # side-effect import 'y'
        | ^\s*export\s+[^;]*?\bfrom\s*['"`]    # re-export — a dependency too
        | \brequire\(\s*['"`]                  # require('y')
    """,
    re.VERBOSE,
)
PY_EXT = (".py",)
JS_EXT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")

HUNK_RE = re.compile(r"^@@+ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
DEV_NULL = "/dev/null"


def lang_for(path: str) -> "str | None":
    if path.endswith(PY_EXT):
        return "python"
    if path.endswith(JS_EXT):
        return "js"
    return None


def is_import(text: str, lang: "str | None") -> bool:
    if lang == "python":
        stripped = text.strip()
        if not stripped.startswith(("import ", "from ")):
            return False
        try:
            tree = ast.parse(stripped)
        except SyntaxError:
            return False
        return (len(tree.body) == 1
                and isinstance(tree.body[0], (ast.Import, ast.ImportFrom)))
    if lang == "js":
        return bool(JS_IMPORT.search(text))
    return False


def docstring_toggle(text: str) -> bool:
    """True when this line opens or closes a triple-quoted string."""
    return (text.count('"""') + text.count("'''")) % 2 == 1


def header_path(field: str) -> "str | None":
    """The path from a `--- a/x` / `+++ b/x` header field, or None for /dev/null.

    git quotes a path containing a control or non-ASCII byte and may append a
    tab-separated timestamp; both are undone here so the path matches what the
    reviews API expects.
    """
    field = field.split("\t", 1)[0].strip()
    if field == DEV_NULL:
        return None
    if len(field) >= 2 and field.startswith('"') and field.endswith('"'):
        field = field[1:-1].encode("latin-1", "backslashreplace").decode(
            "unicode_escape")
    if field[:2] in ("a/", "b/"):
        field = field[2:]
    return field


def parse_diff(diff: str) -> "list[dict]":
    files: "list[dict]" = []
    cur: "dict | None" = None
    old_ln = new_ln = 0
    rem_old = rem_new = 0
    old_path: "str | None" = None       # from the most recent `--- ` header
    saw_old_header = False

    lines = diff.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        in_hunk = rem_old > 0 or rem_new > 0

        if in_hunk:
            # Inside a hunk the first character is the marker, full stop.
            marker = raw[0] if raw else " "
            if marker == "\\":                     # \ No newline at end of file
                i += 1
                continue
            if marker not in " +-":
                # Counts disagree with the body (truncated or hand-edited diff).
                # End the hunk and re-read this line as a header rather than
                # swallowing the next file.
                rem_old = rem_new = 0
                continue
            text = raw[1:] if raw else ""
            if cur is None:                        # hunk with no file header
                i += 1
                continue
            if marker == " ":
                cur["lines"].append({"old_line": old_ln, "new_line": new_ln,
                                     "side": "both", "type": "context",
                                     "text": text})
                old_ln += 1
                new_ln += 1
                rem_old = max(0, rem_old - 1)
                rem_new = max(0, rem_new - 1)
            elif marker == "+":
                cur["lines"].append({"old_line": None, "new_line": new_ln,
                                     "side": "RIGHT", "type": "added",
                                     "text": text})
                lang = lang_for(cur["path"])
                # A syntactically valid import inside a docstring — a restore
                # snippet, a usage example — is text, not a dependency. Parity
                # over the file's added lines flags it; it starts False, so a
                # hunk that opens mid-docstring under-flags rather than
                # suppressing a real import, which is the safe direction.
                was_in_docstring = cur["_in_docstring"]
                if lang == "python" and docstring_toggle(text):
                    cur["_in_docstring"] = not was_in_docstring
                if is_import(text, lang):
                    cur["imports"].append({"new_line": new_ln, "lang": lang,
                                           "in_docstring": was_in_docstring,
                                           "text": text.rstrip()})
                new_ln += 1
                rem_new = max(0, rem_new - 1)
            else:
                cur["lines"].append({"old_line": old_ln, "new_line": None,
                                     "side": "LEFT", "type": "removed",
                                     "text": text})
                old_ln += 1
                rem_old = max(0, rem_old - 1)
            i += 1
            continue

        # Header region.
        i += 1
        if raw.startswith("diff --git "):
            cur = None
            old_path = None
            saw_old_header = False
            continue
        if raw.startswith("--- "):
            old_path = header_path(raw[4:])
            saw_old_header = True
            continue
        if raw.startswith("+++ "):
            new_path = header_path(raw[4:])
            if new_path is None:
                path, status = old_path, "deleted"
            elif saw_old_header and old_path is None:
                path, status = new_path, "added"
            else:
                path, status = new_path, "modified"
            if path is None:                       # +++ /dev/null with no --- a/
                cur = None
                continue
            cur = {"path": path, "old_path": old_path, "status": status,
                   "lines": [], "imports": [], "_in_docstring": False}
            files.append(cur)
            continue
        m = HUNK_RE.match(raw)
        if m:
            old_ln = int(m.group(1))
            rem_old = int(m.group(2)) if m.group(2) is not None else 1
            new_ln = int(m.group(3))
            rem_new = int(m.group(4)) if m.group(4) is not None else 1
        # anything else (index, mode, similarity, Binary files ...) is skipped
    for f in files:
        f.pop("_in_docstring", None)   # walk state, not output
    return files


SELF_TEST_DIFF = """\
diff --git a/keep.py b/keep.py
index 111..222 100644
--- a/keep.py
+++ b/keep.py
@@ -10,3 +10,4 @@ def outer():
 def a():
     pass
+    import json
\x20
diff --git a/gone.py b/gone.py
deleted file mode 100644
index 333..0000000
--- a/gone.py
+++ /dev/null
@@ -1,3 +0,0 @@
-import os
-def b():
-    pass
diff --git a/db/q.sql b/db/q.sql
index 444..555 100644
--- a/db/q.sql
+++ b/db/q.sql
@@ -1,5 +1,5 @@
 SELECT 1
--- legacy note
-WHERE x = 1
+WHERE x = 2
 FROM t
diff --git a/old.py b/new.py
similarity index 92%
rename from old.py
rename to new.py
--- a/old.py
+++ b/new.py
@@ -1,3 +1,3 @@
 import os
-x = 1
+x = 2
 y = 1
diff --git a/fresh.py b/fresh.py
new file mode 100644
--- /dev/null
+++ b/fresh.py
@@ -0,0 +1,2 @@
+import sys
+y = 3
diff --git a/prose.py b/prose.py
new file mode 100644
--- /dev/null
+++ b/prose.py
@@ -0,0 +1,8 @@
+import boto3
+def restore():
+    '''Restore snippet:
+
+        import json
+    from that mix, we derive a different SCALE, producing a different result.
+    '''
+    return None
diff --git a/app.ts b/app.ts
new file mode 100644
--- /dev/null
+++ b/app.ts
@@ -0,0 +1,5 @@
+import { A } from '../controllers/a'
+export { B } from './b'
+const c = require('./c')
+  import the config from the dashboard before running
+const d = 1
"""


def _self_test() -> int:
    files = {f["path"]: f for f in parse_diff(SELF_TEST_DIFF)}
    t = Tap()
    want = t.check

    want(set(files) == {"keep.py", "gone.py", "db/q.sql", "new.py", "fresh.py",
                        "prose.py", "app.ts"},
         "every file in the diff is indexed", f"file set is {sorted(files)}")

    # A deleted file is its own record, with its own lines and status.
    if "gone.py" in files and "keep.py" in files:
        want(files["gone.py"]["status"] == "deleted",
             "a deleted file is its own record, with status deleted", f"gone.py status {files['gone.py'].get('status')}")
        want([ln["old_line"] for ln in files["gone.py"]["lines"]] == [1, 2, 3],
             "a deleted file keeps its own old lines", "gone.py old_lines wrong")
        want(all(ln["old_line"] in (10, 11, 12) or ln["old_line"] is None
                 for ln in files["keep.py"]["lines"]),
             "a file does not absorb a deleted file's lines", "keep.py absorbed another file's lines")
        want(len(files["keep.py"]["lines"]) == 4,
             "a file keeps exactly its own lines", f"keep.py has {len(files['keep.py']['lines'])} lines, want 4")

    # A removed line whose content starts with '-- ' is a removed line, and the
    # old_line numbering after it does not shift.
    if "db/q.sql" in files:
        sql = files["db/q.sql"]["lines"]
        want([(ln["old_line"], ln["new_line"], ln["type"]) for ln in sql] ==
             [(1, 1, "context"), (2, None, "removed"), (3, None, "removed"),
              (None, 2, "added"), (4, 3, "context")],
             "a removed line starting with '-- ' is indexed without old_line drift", f"db/q.sql index wrong: "
             f"{[(l['old_line'], l['new_line'], l['type']) for l in sql]}")
        want(any(ln["text"] == "-- legacy note" and ln["old_line"] == 2
                 for ln in sql),
             "the removed '-- legacy note' line is in the index", "the removed '-- legacy note' line is missing from the index")

    # Renames index under the new path; new files are 'added' and keep imports.
    if "new.py" in files:
        want(files["new.py"]["status"] == "modified",
             "a rename is indexed as modified", f"rename status {files['new.py'].get('status')}")
        want(files["new.py"]["old_path"] == "old.py",
             "a rename keeps its old path", f"rename old_path {files['new.py'].get('old_path')}")
    if "keep.py" in files and "gone.py" in files:
        want(files["keep.py"]["old_path"] == "keep.py",
             "a modified file's old path is its path", f"keep.py old_path {files['keep.py'].get('old_path')}")
        want(files["gone.py"]["old_path"] == "gone.py",
             "a deleted file's old path is its path", f"gone.py old_path {files['gone.py'].get('old_path')}")
    if "fresh.py" in files:
        want(files["fresh.py"]["status"] == "added",
             "a new file is added", f"fresh.py status {files['fresh.py'].get('status')}")
        want(files["fresh.py"]["old_path"] is None,
             "a new file has no old path", f"fresh.py old_path {files['fresh.py'].get('old_path')}")
        want([im["new_line"] for im in files["fresh.py"]["imports"]] == [1],
             "a new file keeps its imports", f"fresh.py imports {files['fresh.py']['imports']}")
    if "keep.py" in files:
        want([im["new_line"] for im in files["keep.py"]["imports"]] == [12],
             "a modified file keeps its imports", f"keep.py imports {files['keep.py']['imports']}")

    # English prose that opens with 'from ' is not an import; a real import
    # quoted inside a docstring is one textually, so it is kept and flagged
    # rather than dropped. Both shapes appeared in one production review.
    if "prose.py" in files:
        got = [(im["new_line"], im["in_docstring"])
               for im in files["prose.py"]["imports"]]
        want(got == [(1, False), (5, True)],
             "prose is not an import, and a docstring import is flagged", f"prose.py imports {got}, want [(1, False), (5, True)]")

    # A JS module specifier is always quoted, which is what separates an
    # import from a sentence containing the words 'import' and 'from'.
    if "app.ts" in files:
        got = [im["new_line"] for im in files["app.ts"]["imports"]]
        want(got == [1, 2, 3], "a JS import needs a quoted specifier", f"app.ts imports {got}, want [1, 2, 3]")

    return t.end()


def main() -> None:
    args = sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        raise SystemExit(0)
    if not args:
        die("Usage: gh-pr-diff-index.sh <pr-ref> | --diff-file <path> "
            "[--head-sha <sha>] | --self-test")
    if args[0] == "--self-test":
        raise SystemExit(_self_test())
    head_sha = None
    if args[0] == "--diff-file":
        if len(args) < 2:
            die("--diff-file needs a path")
        with open(args[1], encoding="utf-8", errors="replace") as fh:
            diff = fh.read()
        rest = args[2:]
        if rest:
            if rest[0] != "--head-sha" or len(rest) < 2:
                die(f"Unexpected argument: {rest[0]} (want --head-sha <sha>)")
            head_sha = rest[1]
    else:
        diff, head_sha = fetch(args[0])
    print(json.dumps({"head_sha": head_sha, "files": parse_diff(diff)}, indent=2))


if __name__ == "__main__":
    main()
