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
    gh-pr-review-post.sh <pr-ref> \
        --event COMMENT|APPROVE \
        --body-file <summary.md> \
        [--index-file <pr-index.json>] \
        [--findings-file <findings.json>] \
        [--dry-run] [--drop-invalid] [--allow-shared-anchor]
    gh-pr-review-post.sh --self-test

<pr-ref>: https://github.com/Org/repo/pull/123 | Org/repo#123 | #123

findings.json is an array of inline comments:
    [ { "path": "src/x.py", "line": 42, "side": "RIGHT", "body": "..." }, ... ]
"side" defaults to "RIGHT" (the new version of the file). An entry acknowledging
another reviewer's thread carries only the id and the body:
    { "in_reply_to": 4095195953, "body": "..." }

On success prints the posted review's html_url, then each reply's html_url.
Exits non-zero on any failure, including a reply that did not post.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gh_pr_ref import RefError, parse_slug  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


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


# /review:pr budgets an inline comment at 60 words: defect, consequence, fix.
# Reported, never enforced — a finding that genuinely needs more should not be
# blocked from posting by its prose length, but an author reading six 170-word
# comments is reading an essay, and nothing else in the pipeline would say so.
INLINE_WORD_BUDGET = 60


def over_budget(comments: "list[dict]") -> "list[tuple[str, int]]":
    """(anchor, word count) for each inline comment or reply above the budget."""
    out = []
    for c in comments:
        n = len(c["body"].split())
        if n > INLINE_WORD_BUDGET:
            anchor = (f"reply to {c['in_reply_to']}" if c.get("in_reply_to")
                      else f"{c['path']}:{c['line']}")
            out.append((anchor, n))
    return out


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
    fails = []

    def want(cond: bool, msg: str) -> None:
        if not cond:
            fails.append(msg)

    want(("keep.py", 11, "RIGHT") in ok, "an added line is not postable on RIGHT")
    want(("keep.py", 10, "RIGHT") in ok, "a context line is not postable on RIGHT")
    want(("keep.py", 10, "LEFT") in ok, "a context line is not postable on LEFT")
    want(("keep.py", 11, "LEFT") not in ok, "an added line is postable on LEFT")
    want(("gone.py", 1, "LEFT") in ok, "a deleted file's line is not postable")
    want(("gone.py", 1, "RIGHT") not in ok,
         "a deleted file's line is postable on RIGHT")
    # The phantom anchor the old parser produced: a deleted file's line numbers
    # landing on the previous file in the diff. GitHub 422s the whole review on
    # it, so it must be rejected here.
    want(("keep.py", 1, "LEFT") not in ok,
         "keep.py:1 LEFT is postable — a deleted file's lines leaked into it")

    comments, invalid = split_findings([
        {"path": "keep.py", "line": 11, "body": "real"},
        {"path": "keep.py", "line": 1, "side": "LEFT", "body": "phantom"},
        {"path": "nope.py", "line": 3, "body": "file not in diff"},
    ], ok)
    want([c["body"] for c in comments] == ["real"],
         f"accepted {[c['body'] for c in comments]}, want ['real']")
    want([f["body"] for f in invalid] == ["phantom", "file not in diff"],
         f"rejected {[f['body'] for f in invalid]}")
    want(comments and comments[0]["side"] == "RIGHT",
         "side did not default to RIGHT")
    want("`nope.py:3`" in append_unanchored("body", invalid),
         "--drop-invalid text does not name the dropped finding")

    # The word budget is reported, so it has to count words rather than
    # sentences — three long sentences is the shape it exists to catch.
    long_one = {"path": "a.py", "line": 1, "body": "w " * (INLINE_WORD_BUDGET + 1)}
    short_one = {"path": "b.py", "line": 2, "body": "one. two. three."}
    got = over_budget([long_one, short_one])
    want([a for a, _ in got] == ["a.py:1"],
         f"over_budget flagged {got}, want only a.py:1")

    # A finding that names a thread is a reply, and never reaches the diff
    # validation — its anchor is the thread's, not a line of ours.
    anchored, replies = split_replies([
        {"path": "keep.py", "line": 11, "body": "new"},
        {"in_reply_to": 7, "body": "confirmed"},
    ])
    want([f["body"] for f in anchored] == ["new"], "a reply was treated as anchored")
    want([f["body"] for f in replies] == ["confirmed"], "a reply was not split out")

    known = [{"id": 7, "author": "bot[bot]", "path": "keep.py", "line": 11, "side": "RIGHT"},
             {"id": 8, "author": "me", "path": "keep.py", "line": 10, "side": "RIGHT"}]
    want(unknown_threads([{"in_reply_to": 7}, {"in_reply_to": 99}], known)
         == [{"in_reply_to": 99}], "a reply to a missing thread was not caught")

    # Another reviewer's anchor is a duplicate; my own earlier one is not — a
    # second pass re-raising a live finding of mine is the second-pass rule's
    # business, not this guard's.
    new = [{"path": "keep.py", "line": 11, "side": "RIGHT", "body": "dup"},
           {"path": "keep.py", "line": 10, "side": "RIGHT", "body": "mine"},
           {"path": "keep.py", "line": 11, "side": "LEFT", "body": "other side"}]
    got = [(c["body"], t["id"]) for c, t in shared_anchors(new, known, "me")]
    want(got == [("dup", 7)], f"shared_anchors found {got}, want [('dup', 7)]")
    want(over_budget([{"in_reply_to": 7, "body": "w " * (INLINE_WORD_BUDGET + 1)}])
         == [("reply to 7", INLINE_WORD_BUDGET + 1)], "a long reply was not flagged")

    # An author may only COMMENT on their own PR; anyone else keeps the event.
    want(event_for("APPROVE", "me", "me")[0] == "COMMENT",
         "APPROVE on your own PR was not downgraded to COMMENT")
    want(event_for("APPROVE", "them", "me") == ("APPROVE", None),
         "APPROVE on someone else's PR was changed")
    want(event_for("COMMENT", "me", "me") == ("COMMENT", None),
         "COMMENT on your own PR carried a note")
    want(event_for("APPROVE", None, "me") == ("APPROVE", None),
         "an unknown author downgraded the event")

    if fails:
        print("gh-pr-review-post self-test: FAIL\n  " + "\n  ".join(fails),
              file=sys.stderr)
        return 1
    print("gh-pr-review-post self-test: PASS (phantom and off-diff anchors "
          "rejected, deleted file is LEFT-only, side defaults to RIGHT, replies "
          "split out and checked, another reviewer's anchor refused, own-PR "
          "verdict posts as COMMENT)")
    return 0


def main() -> None:
    if sys.argv[1:2] == ["--self-test"]:
        raise SystemExit(_self_test())

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
    args = ap.parse_args()

    try:
        _, _, number, slug = parse_slug(args.ref)
    except RefError as exc:
        die(str(exc))

    with open(args.body_file, encoding="utf-8") as fh:
        body = fh.read()

    findings = []
    if args.findings_file:
        with open(args.findings_file, encoding="utf-8") as fh:
            findings = json.load(fh)
        if not isinstance(findings, list):
            die("findings file must be a JSON array")

    # The commit to validate against, and to pin the review to.
    commit_id = None
    if args.index_file:
        with open(args.index_file, encoding="utf-8") as fh:
            index = json.load(fh)
        indexed = index.get("head_sha")
        current = head_sha(slug, number)
        if indexed and current and indexed != current:
            die(f"The PR has moved since the index was built: reviewed "
                f"{indexed[:12]}, {slug}#{number} is now at {current[:12]}. "
                f"Every line number in the review came from the old diff. "
                f"Re-run gh-pr-diff-index.sh and re-check the findings.")
        commit_id = indexed or current
    else:
        index = json.loads(run([os.path.join(HERE, "gh-pr-diff-index.sh"),
                                args.ref])) if findings else {"files": []}
        commit_id = index.get("head_sha")

    anchored, replies = split_replies(findings)
    comments, invalid = split_findings(anchored, postable_lines(index))

    if invalid:
        lines = "\n".join(f"  - {f.get('path')}:{f.get('line')} "
                          f"({f.get('side', 'RIGHT')})" for f in invalid)
        if not args.drop_invalid:
            die(f"{len(invalid)} finding(s) point at lines not in the diff "
                f"(GitHub would 422 the whole review):\n{lines}\n"
                f"Fix the line numbers (see gh-pr-diff-index.sh) or pass "
                f"--drop-invalid to fold them into the summary instead.")
        body = append_unanchored(body, invalid)

    poster = viewer()
    known = threads(slug, number) if findings else []
    missing = unknown_threads(replies, known)
    if missing:
        die("in_reply_to names no top-level inline comment on this PR: "
            + ", ".join(str(r["in_reply_to"]) for r in missing))
    shared = shared_anchors(comments, known, poster)
    if shared and not args.allow_shared_anchor:
        lines = "\n".join(f"  - {c['path']}:{c['line']} is {t['author']}'s thread "
                          f"{t['id']}" for c, t in shared)
        die(f"{len(shared)} finding(s) land on another reviewer's thread:\n"
            f"{lines}\nIf it is the same defect, acknowledge it there: replace the "
            f"finding with {{\"in_reply_to\": <id>, \"body\": ...}}. If it is a "
            f"different defect on that line, pass --allow-shared-anchor.")

    event, event_note = event_for(args.event, pr_author(slug, number), poster)
    payload = {"event": event, "body": body, "comments": comments}
    if commit_id:
        payload["commit_id"] = commit_id

    if args.dry_run:
        print(json.dumps({"would_post_to": f"{slug}#{number}",
                          "event": event,
                          "requested_event": args.event,
                          "event_note": event_note,
                          "commit_id": commit_id,
                          "inline_count": len(comments),
                          "replies": [{"in_reply_to": r["in_reply_to"],
                                       "body": r["body"]} for r in replies],
                          "dropped": len(invalid) if args.drop_invalid else 0,
                          "over_word_budget": [
                              {"anchor": a, "words": n,
                               "budget": INLINE_WORD_BUDGET}
                              for a, n in over_budget(comments + replies)],
                          "payload": payload}, indent=2))
        return

    if event_note:
        print(event_note, file=sys.stderr)
    resp = json.loads(post(f"repos/{slug}/pulls/{number}/reviews", payload))
    print(resp.get("html_url", "(posted; no html_url in response)"))
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
    if failed:
        die("The review is posted, but these replies are not:\n" + "\n".join(failed))


if __name__ == "__main__":
    main()
