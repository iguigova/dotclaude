#!/usr/bin/env python3
"""Post ONE batched review to a GitHub PR — verdict body + selected inline
findings — in a single atomic call.

Counterpart to gh-pr-fetch.sh: that *reads* a PR for /review:pr, this *writes*
the review back. Posting is NEVER automatic for /review:pr — the skill drafts
to a file, shows it, and only runs this after the user confirms (a PR review is
public and outward-facing). Use --dry-run to validate the payload first.

The GitHub reviews API rejects the WHOLE review with 422 if any inline comment
points at a line that isn't in the diff. So every finding is validated against
the diff index (the same parser the review used for its line numbers) *before*
anything is posted:
  RIGHT-side comment -> line must be an added/context line's new_line
  LEFT-side  comment -> line must be a removed/context line's old_line
Invalid findings abort by default (so you can fix them); --drop-invalid instead
moves them into the summary body and posts the rest.

Pass --index-file: the review's line numbers came from that index, so the
review must be validated and posted against the same commit. The index carries
the head_sha it was built from; this checks the PR's head against it and
refuses when the author has pushed since, and pins the posted review to that
commit with `commit_id`. Without --index-file the index is re-derived from the
PR's current head, which validates the payload but cannot tell you the diff
moved under the review.

A finding another reviewer already raised is acknowledged in their thread,
not posted beside it: give it `in_reply_to` (the thread's top-level comment id)
and it is posted as a reply once the review is up. The reviews API cannot carry
replies, so they are separate calls after the one atomic review; a reply that
fails is reported, and the review stays posted. An `in_reply_to` that is not a
top-level inline comment on this PR aborts before anything posts (GitHub
rejects a reply to a reply).

Before posting, every new inline comment is checked against the other
reviewers' open anchors: one on the same (path, line, side) as someone else's
thread aborts, naming the thread, because it is almost always the same defect
raised twice. --allow-shared-anchor posts it anyway, for a genuinely different
defect on that line.

The event is COMMENT or APPROVE; a review never formally requests changes.
GitHub refuses an APPROVE from the PR's own author with a 422. When the author is the gh user posting, the review goes up as COMMENT, and
both the dry run and the post say so; the body is posted unchanged.

Usage:
    gh_pr_review_post.py <pr-ref> \
        --event COMMENT|APPROVE \
        --body-file <summary.md> \
        [--index-file <pr-index.json>] \
        [--findings-file <findings.json>] \
        [--dry-run] [--drop-invalid] [--allow-shared-anchor]
    gh_pr_review_post.py --self-test

<pr-ref>: https://github.com/Org/repo/pull/123 | Org/repo#123 | #123

findings.json is an array of inline comments:
    [ { "path": "src/x.py", "line": 42, "side": "RIGHT", "body": "..." }, ... ]
"side" defaults to "RIGHT" (the new version of the file). An entry acknowledging
another reviewer's thread carries only the id and the body:
    { "in_reply_to": 4095195953, "body": "..." }

On success prints the posted review's html_url, then each reply's html_url.
Exits non-zero on any failure, including a reply that did not post. A post
from a Claude session that has not loaded the draft skill is refused by
draft_gate.py before anything is read or sent; --dry-run is never refused.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gh_pr_ref import RefError, parse_slug  # noqa: E402
from resolve import script  # noqa: E402
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


def post(path: str, payload: dict) -> str:
    """POST `payload` to the API; on failure die with GitHub's own message,
    which gh prints to stdout while stderr carries only the bare status."""
    res = subprocess.run(["gh", "api", "-X", "POST", path, "--input", "-"],
                         capture_output=True, text=True, input=json.dumps(payload))
    if res.returncode != 0:
        die(" ".join(filter(None, [res.stderr.strip(), res.stdout.strip()])))
    return res.stdout


def head_sha(slug: str, number: str) -> "str | None":
    out = run(["gh", "pr", "view", number, "--repo", slug,
               "--json", "headRefOid"], check=False)
    if not out.strip():
        return None
    try:
        return json.loads(out).get("headRefOid")
    except json.JSONDecodeError:
        return None


def pr_author(slug: str, number: str) -> "str | None":
    out = run(["gh", "pr", "view", number, "--repo", slug,
               "--json", "author", "-q", ".author.login"], check=False)
    return out.strip() or None


def viewer() -> "str | None":
    return run(["gh", "api", "user", "-q", ".login"], check=False).strip() or None


def event_for(event: str, author: "str | None", poster: "str | None"
              ) -> "tuple[str, str | None]":
    """The event GitHub will accept from `poster`, and why it differs from the
    one asked for. An author may only COMMENT on their own PR."""
    if event == "COMMENT" or not author or author != poster:
        return event, None
    return "COMMENT", (f"{poster} is the PR's author, and GitHub refuses "
                       f"{event} on your own PR; posting as COMMENT")


def threads(slug: str, number: str) -> "list[dict]":
    """Every top-level inline comment on the PR: the threads a reply can name
    and the anchors a new comment would duplicate."""
    out = run(["gh", "api", "--paginate", f"repos/{slug}/pulls/{number}/comments",
               "--jq", ".[] | select(.in_reply_to_id == null) | {id, author: "
               ".user.login, path, line: (.line // .original_line), "
               "side: (.side // \"RIGHT\")}"])
    return [json.loads(ln) for ln in out.splitlines() if ln.strip()]


def split_replies(findings: "list[dict]") -> "tuple[list[dict], list[dict]]":
    """(findings to anchor in the diff, findings that reply to a thread)."""
    replies = [f for f in findings if f.get("in_reply_to")]
    return [f for f in findings if not f.get("in_reply_to")], replies


def unknown_threads(replies: "list[dict]", known: "list[dict]") -> "list[dict]":
    """Replies whose in_reply_to is not a top-level inline comment here."""
    ids = {t["id"] for t in known}
    return [r for r in replies if r["in_reply_to"] not in ids]


def shared_anchors(comments: "list[dict]", known: "list[dict]",
                   poster: "str | None") -> "list[tuple[dict, dict]]":
    """(new comment, another reviewer's thread) pairs on one anchor."""
    theirs = {(t["path"], t["line"], t["side"]): t
              for t in known if t["author"] != poster}
    return [(c, theirs[(c["path"], c["line"], c["side"])])
            for c in comments if (c["path"], c["line"], c["side"]) in theirs]


def postable_lines(index: dict) -> "set[tuple[str, int, str]]":
    """The (path, line, side) triples a comment may anchor to."""
    ok: "set[tuple[str, int, str]]" = set()
    for f in index.get("files", []):
        path = f["path"]
        for ln in f["lines"]:
            if ln["new_line"] is not None and ln["type"] in ("added", "context"):
                ok.add((path, ln["new_line"], "RIGHT"))
            if ln["old_line"] is not None and ln["type"] in ("removed", "context"):
                ok.add((path, ln["old_line"], "LEFT"))
    return ok


def split_findings(findings: "list[dict]", ok: "set[tuple[str, int, str]]"
                   ) -> "tuple[list[dict], list[dict]]":
    """(comments the API will accept, findings whose anchor is not in the diff)."""
    comments, invalid = [], []
    for f in findings:
        side = f.get("side", "RIGHT")
        if (f.get("path"), f.get("line"), side) in ok:
            comments.append({"path": f["path"], "line": f["line"],
                             "side": side, "body": f["body"]})
        else:
            invalid.append(f)
    return comments, invalid


def append_unanchored(body: str, invalid: "list[dict]") -> str:
    body += "\n\n---\n**Findings that could not be anchored inline:**\n"
    for f in invalid:
        body += f"\n- `{f.get('path')}:{f.get('line')}` — {f.get('body')}"
    return body


SELF_TEST_INDEX = {
    "head_sha": "a" * 40,
    "files": [
        {"path": "keep.py", "status": "modified", "imports": [], "lines": [
            {"old_line": 10, "new_line": 10, "side": "both", "type": "context",
             "text": "def a():"},
            {"old_line": None, "new_line": 11, "side": "RIGHT", "type": "added",
             "text": "    pass"},
        ]},
        {"path": "gone.py", "status": "deleted", "imports": [], "lines": [
            {"old_line": 1, "new_line": None, "side": "LEFT", "type": "removed",
             "text": "import os"},
        ]},
    ],
}


def _self_test() -> int:
    ok = postable_lines(SELF_TEST_INDEX)
    t = Tap()
    want = t.check

    want(("keep.py", 11, "RIGHT") in ok, "an added line is postable on RIGHT", "an added line is not postable on RIGHT")
    want(("keep.py", 10, "RIGHT") in ok, "a context line is postable on RIGHT", "a context line is not postable on RIGHT")
    want(("keep.py", 10, "LEFT") in ok, "a context line is postable on LEFT", "a context line is not postable on LEFT")
    want(("keep.py", 11, "LEFT") not in ok, "an added line is not postable on LEFT", "an added line is postable on LEFT")
    want(("gone.py", 1, "LEFT") in ok, "a deleted file's line is postable on LEFT", "a deleted file's line is not postable")
    want(("gone.py", 1, "RIGHT") not in ok,
         "a deleted file's line is not postable on RIGHT", "a deleted file's line is postable on RIGHT")
    # The phantom anchor the old parser produced: a deleted file's line numbers
    # landing on the previous file in the diff. GitHub 422s the whole review on
    # it, so it must be rejected here.
    want(("keep.py", 1, "LEFT") not in ok,
         "a deleted file's lines do not leak into the file before it", "keep.py:1 LEFT is postable — a deleted file's lines leaked into it")

    comments, invalid = split_findings([
        {"path": "keep.py", "line": 11, "body": "real"},
        {"path": "keep.py", "line": 1, "side": "LEFT", "body": "phantom"},
        {"path": "nope.py", "line": 3, "body": "file not in diff"},
    ], ok)
    want([c["body"] for c in comments] == ["real"],
         "a finding on a postable line is accepted", f"accepted {[c['body'] for c in comments]}, want ['real']")
    want([f["body"] for f in invalid] == ["phantom", "file not in diff"],
         "a phantom anchor and a file off the diff are rejected", f"rejected {[f['body'] for f in invalid]}")
    want(comments and comments[0]["side"] == "RIGHT",
         "the side defaults to RIGHT", "side did not default to RIGHT")
    want("`nope.py:3`" in append_unanchored("body", invalid),
         "--drop-invalid names each dropped finding", "--drop-invalid text does not name the dropped finding")

    # A finding that names a thread is a reply, and never reaches the diff
    # validation — its anchor is the thread's, not a line of ours.
    anchored, replies = split_replies([
        {"path": "keep.py", "line": 11, "body": "new"},
        {"in_reply_to": 7, "body": "confirmed"},
    ])
    want([f["body"] for f in anchored] == ["new"], "a reply is not treated as anchored", "a reply was treated as anchored")
    want([f["body"] for f in replies] == ["confirmed"], "a reply is split out", "a reply was not split out")

    known = [{"id": 7, "author": "bot[bot]", "path": "keep.py", "line": 11, "side": "RIGHT"},
             {"id": 8, "author": "me", "path": "keep.py", "line": 10, "side": "RIGHT"}]
    want(unknown_threads([{"in_reply_to": 7}, {"in_reply_to": 99}], known)
         == [{"in_reply_to": 99}], "a reply to a missing thread is caught", "a reply to a missing thread was not caught")

    # Another reviewer's anchor is a duplicate; my own earlier one is not — a
    # second pass re-raising a live finding of mine is the second-pass rule's
    # business, not this guard's.
    new = [{"path": "keep.py", "line": 11, "side": "RIGHT", "body": "dup"},
           {"path": "keep.py", "line": 10, "side": "RIGHT", "body": "mine"},
           {"path": "keep.py", "line": 11, "side": "LEFT", "body": "other side"}]
    got = [(c["body"], t["id"]) for c, t in shared_anchors(new, known, "me")]
    want(got == [("dup", 7)], "another reviewer's anchor is a shared anchor, my own is not", f"shared_anchors found {got}, want [('dup', 7)]")

    # An author may only COMMENT on their own PR; anyone else keeps the event.
    want(event_for("APPROVE", "me", "me")[0] == "COMMENT",
         "APPROVE on your own PR is downgraded to COMMENT", "APPROVE on your own PR was not downgraded to COMMENT")
    want(event_for("APPROVE", "them", "me") == ("APPROVE", None),
         "APPROVE on someone else's PR is kept", "APPROVE on someone else's PR was changed")
    want(event_for("COMMENT", "me", "me") == ("COMMENT", None),
         "COMMENT on your own PR carries no note", "COMMENT on your own PR carried a note")
    want(event_for("APPROVE", None, "me") == ("APPROVE", None),
         "an unknown author keeps the event", "an unknown author downgraded the event")
    _self_test_gate(want)
    _self_test_steps(want)
    _self_test_posting(want)

    return t.end()


def _self_test_gate(want) -> None:
    import tempfile
    gate = tempfile.mkdtemp()
    with open(os.path.join(gate, "drafted.json"), "w", encoding="utf-8") as fh:
        fh.write('["draft"]')
    refusal = ("draft_gate: load the draft skill with the Skill tool and check "
               "this text against it before sending; nothing was sent.\n")

    def run(session: str, *extra: str) -> "tuple[int, str]":
        env = {**os.environ, "CLAUDE_CODE_SESSION_ID": session, "DRAFT_GATE_DIR": gate}
        done = subprocess.run([sys.executable, __file__, "not a ref", "--event", "COMMENT",
                               "--body-file", "/dev/null", *extra],
                              env=env, capture_output=True, text=True)
        return done.returncode, done.stderr
    want(run("st") == (1, refusal),
         "a post from a session without draft is refused before the ref is read",
         "a post from a session without draft was not refused")
    allowed = run("drafted")[1]
    want(bool(allowed) and "draft_gate:" not in allowed,
         "a session that loaded draft goes on to read the ref", "a session that loaded draft was refused")
    want("draft_gate:" not in run("st", "--dry-run")[1],
         "a dry run is never refused", "a dry run was refused")
    os.remove(os.path.join(gate, "drafted.json"))
    os.rmdir(gate)


def _self_test_ends(fn, *args) -> "tuple[int | None, str]":
    """fn's exit code and what it said on stderr, or (None, '') when it returned."""
    import contextlib
    import io
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            fn(*args)
    except SystemExit as e:
        return e.code, err.getvalue()
    return None, ""


def _self_test_steps(want) -> None:
    import tempfile
    want(moved("a1", "b2") and not moved("a1", "a1") and not moved(None, "b2") and not moved("a1", None),
         "the PR has moved only when both heads are known and differ", "moved() misjudged the heads")
    with tempfile.TemporaryDirectory() as tmp:
        good, bad = os.path.join(tmp, "g.json"), os.path.join(tmp, "b.json")
        with open(good, "w") as fh:
            fh.write('[{"path": "a"}]')
        with open(bad, "w") as fh:
            fh.write('{"path": "a"}')
        want(read_findings(None) == [] and read_findings(good) == [{"path": "a"}],
             "no findings file is no findings, and a file's array is read", "read_findings misread")
        want(_self_test_ends(read_findings, bad)[0] == 1, "a findings file that is not an array is refused",
             "a non-array findings file was taken")
    invalid = [{"path": "x.py", "line": 9, "body": "b"}]
    want(fold_invalid("B", [], False) == "B", "with nothing invalid the body is as it was", "the body changed")
    want("`x.py:9` — b" in fold_invalid("B", invalid, True), "--drop-invalid folds an invalid finding into the body",
         "an invalid finding was not folded in")
    code, said = _self_test_ends(fold_invalid, "B", invalid, False)
    want(code == 1 and "x.py:9 (RIGHT)" in said, "an invalid finding without --drop-invalid is refused, named",
         f"fold_invalid ended {code}: {said}")
    known = [{"id": 7, "author": "other", "path": "a.py", "line": 3, "side": "RIGHT"}]
    want(_self_test_ends(require_known, [{"in_reply_to": 7}], known) == (None, "")
         and _self_test_ends(require_known, [{"in_reply_to": 8}], known)[0] == 1,
         "a reply to a known thread passes, and one to an unknown thread is refused", "require_known misjudged")
    clash = [{"path": "a.py", "line": 3, "side": "RIGHT"}]
    code, said = _self_test_ends(require_unshared, clash, known, "me", False)
    want(code == 1 and "a.py:3 is other's thread 7" in said, "a finding on another reviewer's thread is refused, named",
         f"require_unshared ended {code}: {said}")
    want(_self_test_ends(require_unshared, clash, known, "me", True) == (None, "")
         and _self_test_ends(require_unshared, clash, known, "other", False) == (None, ""),
         "--allow-shared-anchor lets it through, and one's own thread is no clash", "require_unshared over-refused")
    want(pinned_index(None, "o/r#1", [], "o/r", "1") == ({"files": []}, None),
         "with no index file and no findings there is no index to fetch", "pinned_index fetched for nothing")
    args = argparse.Namespace(event="APPROVE", drop_invalid=False)
    report = dry_run_report(args, "o/r#1", None, [{"in_reply_to": 7, "body": "r"}], invalid,
                            {"event": "COMMENT", "comments": [{}], "commit_id": "c1"})
    want((report["dropped"], report["inline_count"], report["commit_id"], report["requested_event"]) == (0, 1, "c1", "APPROVE"),
         "a dry run reports what it would post, dropping nothing without --drop-invalid", f"report {report}")
    args.drop_invalid = True
    want(dry_run_report(args, "o/r#1", None, [], invalid, {"event": "COMMENT", "comments": []})["dropped"] == 1,
         "with --drop-invalid the dry run counts what it folded in", "dropped not counted")


def _self_test_posting(want) -> None:
    """A stub gh on PATH answers each call from its arguments, so nothing leaves the machine."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        stub = os.path.join(tmp, "gh")
        with open(stub, "w") as fh:
            fh.write('#!/usr/bin/env bash\n[[ "$*" == *"--input -"* ]] && cat >/dev/null\n'
                     'case "$*" in\n'
                     '  *"pr view"*) echo \'{"headRefOid": "h2"}\' ;;\n'
                     '  */reviews*) echo \'{"html_url": "U/review"}\' ;;\n'
                     '  */comments/7/replies*) echo \'{"html_url": "U/reply7"}\' ;;\n'
                     '  *) echo "HTTP 404" >&2; exit 1 ;;\n'
                     'esac\n')
        os.chmod(stub, 0o755)
        index = os.path.join(tmp, "i.json")
        with open(index, "w") as fh:
            fh.write('{"head_sha": "h1", "files": []}')
        keep = os.environ["PATH"]
        os.environ["PATH"] = f"{tmp}:{keep}"
        try:
            code, said = _self_test_ends(pinned_index, index, "o/r#1", [], "o/r", "1")
            want(code == 1 and "reviewed h1, o/r#1 is now at h2" in said,
                 "an index built before the PR moved is refused, naming both heads", f"pinned_index ended {code}: {said}")
            with open(index, "w") as fh:
                fh.write('{"files": []}')
            want(pinned_index(index, "o/r#1", [], "o/r", "1") == ({"files": []}, "h2"),
                 "an index with no head pins the review to the PR's head", "the review was not pinned to the head")
            import contextlib
            import io
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                failed = post_replies("o/r", "1", [{"in_reply_to": 7, "body": "a"}, {"in_reply_to": 8, "body": "b"}])
            want(out.getvalue() == "U/reply7\n" and failed == ["  - reply to 8: HTTP 404"],
                 "each reply that posts prints its URL, and each that fails is named", f"{out.getvalue()!r} {failed}")
            with contextlib.redirect_stdout(io.StringIO()) as out2:
                code, said = _self_test_ends(post_review, "o/r", "1", {"event": "COMMENT"},
                                             [{"in_reply_to": 8, "body": "b"}])
            want(code == 1 and out2.getvalue() == "U/review\n" and "these replies are not" in said,
                 "a review that posts with a reply that does not is said, after the review's URL", f"{code} {said}")
        finally:
            os.environ["PATH"] = keep


def drafted() -> bool:
    """True when draft_gate.py lets this session send text to people."""
    return subprocess.run([script("draft_gate.py"), "check", "draft"]).returncode == 0


def parsed_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ref")
    ap.add_argument("--event", required=True,
                    choices=["COMMENT", "APPROVE"])
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--index-file")
    ap.add_argument("--findings-file")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--drop-invalid", action="store_true")
    ap.add_argument("--allow-shared-anchor", action="store_true")
    return ap.parse_args()


def read_findings(path: "str | None") -> "list[dict]":
    """The findings file's array; none at all with no file."""
    if not path:
        return []
    with open(path, encoding="utf-8") as fh:
        findings = json.load(fh)
    if not isinstance(findings, list):
        die("findings file must be a JSON array")
    return findings


def moved(indexed: "str | None", current: "str | None") -> bool:
    """The PR's head is known, and is not the commit the index was built from."""
    return bool(indexed and current and indexed != current)


def pinned_index(index_file: "str | None", ref: str, findings: "list[dict]",
                 slug: str, number: str) -> "tuple[dict, str | None]":
    """The diff index, and the commit to validate against and pin the review to."""
    if not index_file:
        index = json.loads(run([script("gh_pr_diff_index.py"), ref])) if findings else {"files": []}
        return index, index.get("head_sha")
    with open(index_file, encoding="utf-8") as fh:
        index = json.load(fh)
    indexed, current = index.get("head_sha"), head_sha(slug, number)
    if moved(indexed, current):
        die(f"The PR has moved since the index was built: reviewed "
            f"{indexed[:12]}, {slug}#{number} is now at {current[:12]}. "
            f"Every line number in the review came from the old diff. "
            f"Re-run gh_pr_diff_index.py and re-check the findings.")
    return index, indexed or current


def fold_invalid(body: str, invalid: "list[dict]", drop: bool) -> str:
    """The body, with findings on lines not in the diff folded in; refused without --drop-invalid."""
    if not invalid:
        return body
    if not drop:
        lines = "\n".join(f"  - {f.get('path')}:{f.get('line')} "
                          f"({f.get('side', 'RIGHT')})" for f in invalid)
        die(f"{len(invalid)} finding(s) point at lines not in the diff "
            f"(GitHub would 422 the whole review):\n{lines}\n"
            f"Fix the line numbers (see gh_pr_diff_index.py) or pass "
            f"--drop-invalid to fold them into the summary instead.")
    return append_unanchored(body, invalid)


def require_known(replies: "list[dict]", known: "list[dict]") -> None:
    missing = unknown_threads(replies, known)
    if missing:
        die("in_reply_to names no top-level inline comment on this PR: "
            + ", ".join(str(r["in_reply_to"]) for r in missing))


def require_unshared(comments: "list[dict]", known: "list[dict]",
                     poster: "str | None", allow: bool) -> None:
    shared = shared_anchors(comments, known, poster)
    if shared and not allow:
        lines = "\n".join(f"  - {c['path']}:{c['line']} is {t['author']}'s thread "
                          f"{t['id']}" for c, t in shared)
        die(f"{len(shared)} finding(s) land on another reviewer's thread:\n"
            f"{lines}\nIf it is the same defect, acknowledge it there: replace the "
            f"finding with {{\"in_reply_to\": <id>, \"body\": ...}}. If it is a "
            f"different defect on that line, pass --allow-shared-anchor.")


def post_replies(slug: str, number: str, replies: "list[dict]") -> "list[str]":
    """Post each reply under its thread, printing its URL; what did not post."""
    failed = []
    for r in replies:
        res = subprocess.run(
            ["gh", "api", "-X", "POST",
             f"repos/{slug}/pulls/{number}/comments/{r['in_reply_to']}/replies",
             "--input", "-"],
            capture_output=True, text=True, input=json.dumps({"body": r["body"]}))
        if res.returncode == 0:
            print(json.loads(res.stdout).get("html_url", "(reply posted)"))
        else:
            failed.append(f"  - reply to {r['in_reply_to']}: "
                          f"{(res.stderr or res.stdout).strip()}")
    return failed


def post_review(slug: str, number: str, payload: dict, replies: "list[dict]") -> None:
    resp = json.loads(post(f"repos/{slug}/pulls/{number}/reviews", payload))
    print(resp.get("html_url", "(posted; no html_url in response)"))
    failed = post_replies(slug, number, replies)
    if failed:
        die("The review is posted, but these replies are not:\n" + "\n".join(failed))


def dry_run_report(args: argparse.Namespace, pr: str, event_note: "str | None",
                   replies: "list[dict]", invalid: "list[dict]", payload: dict) -> dict:
    """What a dry run says it would post."""
    return {"would_post_to": pr,
            "event": payload["event"],
            "requested_event": args.event,
            "event_note": event_note,
            "commit_id": payload.get("commit_id"),
            "inline_count": len(payload["comments"]),
            "replies": [{"in_reply_to": r["in_reply_to"], "body": r["body"]} for r in replies],
            "dropped": len(invalid) if args.drop_invalid else 0,
            "payload": payload}


def main() -> None:
    if sys.argv[1:2] == ["--self-test"]:
        raise SystemExit(_self_test())
    args = parsed_args()
    if not args.dry_run and not drafted():
        raise SystemExit(1)
    try:
        _, _, number, slug = parse_slug(args.ref)
    except RefError as exc:
        die(str(exc))
    with open(args.body_file, encoding="utf-8") as fh:
        body = fh.read()
    findings = read_findings(args.findings_file)
    index, commit_id = pinned_index(args.index_file, args.ref, findings, slug, number)
    anchored, replies = split_replies(findings)
    comments, invalid = split_findings(anchored, postable_lines(index))
    body = fold_invalid(body, invalid, args.drop_invalid)
    poster = viewer()
    known = threads(slug, number) if findings else []
    require_known(replies, known)
    require_unshared(comments, known, poster, args.allow_shared_anchor)
    event, event_note = event_for(args.event, pr_author(slug, number), poster)
    payload = {"event": event, "body": body, "comments": comments,
               **({"commit_id": commit_id} if commit_id else {})}
    if args.dry_run:
        print(json.dumps(dry_run_report(args, f"{slug}#{number}", event_note, replies,
                                        invalid, payload), indent=2))
        return
    if event_note:
        print(event_note, file=sys.stderr)
    post_review(slug, number, payload, replies)


if __name__ == "__main__":
    main()
