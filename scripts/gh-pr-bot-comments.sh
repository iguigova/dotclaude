#!/usr/bin/env python3
"""Fetch the review comments on a GitHub PR that may still need an answer.

A bot thread is a top-level inline review comment (``in_reply_to_id`` is
null) authored by a review bot (Greptile, CodeRabbit, …). A human thread is
the same from any other reviewer. A human note is a reviewer's review body or
issue comment, which has no thread to reply in. Powers the /review:bot skill.

"Human" is any login without the ``[bot]`` suffix other than the viewer (the
``gh`` user the replies are posted as), whatever the bot filter says, so
narrowing to one bot never hides a reviewer.

On the viewer's own PR, the viewer's latest review is a reviewer's ask too:
``own_review`` carries it, read by gh-pr-prior-review.sh so one parser decides
which review and which inline comments are the viewer's. On anyone else's PR
the viewer only answers, and ``own_review`` is null.

Usage:
    gh-pr-bot-comments.sh <pr-ref> [bot-login-substr ...]
    gh-pr-bot-comments.sh --self-test

<pr-ref> is one of:
    https://github.com/Org/repo/pull/123
    Org/repo#123
    #123                 (uses CWD's git remote)

Extra args narrow the bot filter to logins containing those substrings
(case-insensitive). With no extra args, ANY login ending in "[bot]" counts.

Output JSON (to stdout):
    {
      "owner", "repo", "number",
      "review_decision": "APPROVED" | ... | null,
      "summary":  [ {id, author, body} ],          # issue-level bot summaries
      "threads":  [ {id, author, path, line, original_line, severity,
                     html_url, diff_hunk, body, already_replied,
                     reply_authors} ],
      "open_count": <#threads with already_replied == false>,
      "viewer": "<gh login>",
      "human_threads": [ {id, author, path, line, html_url, diff_hunk, body,
                          already_replied, reply_authors} ],
      "human_notes":    [ {id, kind: "review" | "comment", author, state,
                          created_at, html_url, body, answered} ],
      "human_open_count": <#human_threads with already_replied == false>,
      "own_review": null | {id, html_url, state, commit, stale, body, asks,
                            answered,
                            findings: [ {id, path, line, body, already_replied} ]},
      "own_open_count": <#own_review.findings with already_replied == false>
    }

A human thread is already_replied once anyone but its author replies. A human
note is answered once the viewer posts an issue comment or review body after
it. human_open_count counts threads only: a note may be a status post that
needs no answer, so the skill reads each unanswered note and decides.

``own_review.asks`` is true when its body holds one of the sections
/review:pr writes its asks under (**Must fix before merge**, **Should fix**,
**Open questions**, **Nits:**); a clean approve has none and asks nothing.
``own_review.answered`` is true once the viewer posts a PR comment after the
review that links it (``#pullrequestreview-<id>``); a PR comment on any other
subject leaves it open. An own finding is already_replied once it draws any
reply, the viewer's included, since on one's own PR the viewer is who answers.

Exits non-zero if any gh call fails.
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gh_pr_ref import RefError, parse_ref  # noqa: E402
from tap import Tap  # noqa: E402


def die(msg: str) -> "None":
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def run(cmd: "list[str]", check: bool = True, stdin: "str | None" = None) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True, input=stdin)
    if res.returncode != 0:
        if check:
            die(res.stderr.strip() or f"command failed: {' '.join(cmd)}")
        return ""
    return res.stdout


def gh_json(path: str, paginate: bool = True):
    cmd = ["gh", "api", path]
    if paginate:
        cmd.append("--paginate")
    return json.loads(run(cmd) or "[]")


SEV_RE = re.compile(r'alt="(P[0-9])"')


def is_bot(login: str, substrs: "list[str]") -> bool:
    """A login counts as a review bot: any `…[bot]`, or one matching a substring."""
    login_l = login.lower()
    if substrs:
        return any(s in login_l for s in substrs)
    return login.endswith("[bot]")


def is_human(login: str, viewer: str) -> bool:
    """A reviewer who is neither a bot nor the viewer answering the review."""
    return not login.endswith("[bot]") and login != viewer


def human_threads(inline: "list[dict]", viewer: str) -> "list[dict]":
    """Top-level inline comments by a human reviewer, with who answered them."""
    out = []
    for c in inline:
        author = c["user"]["login"]
        if c.get("in_reply_to_id") is not None or not is_human(author, viewer):
            continue
        repliers = [r["user"]["login"] for r in inline
                    if r.get("in_reply_to_id") == c["id"]]
        out.append({
            "id": c["id"],
            "author": author,
            "path": c.get("path"),
            "line": c.get("line"),
            "html_url": c.get("html_url"),
            "diff_hunk": c.get("diff_hunk"),
            "body": c.get("body"),
            "already_replied": any(r != author for r in repliers),
            "reply_authors": repliers,
        })
    return out


def human_notes(reviews: "list[dict]", issue: "list[dict]",
                viewer: str) -> "list[dict]":
    """Review bodies and issue comments by a human reviewer.

    A note is answered once the viewer speaks at PR level after it; an
    empty review body (a bare approval) says nothing to answer.
    """
    said = [(r.get("submitted_at"), r["user"]["login"], r.get("body") or "",
             "review", r) for r in reviews]
    said += [(c.get("created_at"), c["user"]["login"], c.get("body") or "",
              "comment", c) for c in issue]
    viewer_times = [t for t, who, body, _, _ in said
                    if who == viewer and body.strip() and t]
    return [{
        "id": raw["id"],
        "kind": kind,
        "author": who,
        "state": raw.get("state"),
        "created_at": t,
        "html_url": raw.get("html_url"),
        "body": body,
        "answered": any(v > t for v in viewer_times),
    } for t, who, body, kind, raw in sorted(said, key=lambda x: x[0] or "")
        if is_human(who, viewer) and body.strip()]


def classify(inline: "list[dict]", issue: "list[dict]",
             substrs: "list[str]") -> dict:
    """Split a PR's comments into unresolved bot threads and run summaries.

    A thread is top-level (`in_reply_to_id` is null) and bot-authored; it is
    already_replied when any other comment replies to it, whoever wrote the
    reply.
    """
    replied_to = {c["in_reply_to_id"] for c in inline if c.get("in_reply_to_id")}
    threads = []
    for c in inline:
        if c.get("in_reply_to_id") is not None:
            continue
        if not is_bot(c["user"]["login"], substrs):
            continue
        sev = SEV_RE.search(c.get("body", "") or "")
        threads.append({
            "id": c["id"],
            "author": c["user"]["login"],
            "path": c.get("path"),
            "line": c.get("line"),
            "original_line": c.get("original_line"),
            "severity": sev.group(1) if sev else None,
            "html_url": c.get("html_url"),
            "diff_hunk": c.get("diff_hunk"),
            "body": c.get("body"),
            "already_replied": c["id"] in replied_to,
            "reply_authors": [
                r["user"]["login"] for r in inline
                if r.get("in_reply_to_id") == c["id"]
            ],
        })
    summary = [
        {"id": c["id"], "author": c["user"]["login"], "body": c.get("body")}
        for c in issue if is_bot(c["user"]["login"], substrs)
    ]
    return {
        "summary": summary,
        "threads": threads,
        "open_count": sum(1 for t in threads if not t["already_replied"]),
    }


def classify_humans(inline: "list[dict]", reviews: "list[dict]",
                    issue: "list[dict]", viewer: str) -> dict:
    """The human side of the review: inline threads and PR-level notes."""
    threads = human_threads(inline, viewer)
    return {
        "viewer": viewer,
        "human_threads": threads,
        "human_notes": human_notes(reviews, issue, viewer),
        "human_open_count": sum(1 for t in threads if not t["already_replied"]),
    }


# The bold section labels /review:pr's posted body files each ask under.
ASK_SECTION = re.compile(r"\*\*(Must fix before merge|Should fix|Open questions|Nits:)")

PRIOR_REVIEW = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "gh-pr-prior-review.sh")


def fetch_blob(reviews: "list[dict]", inline: "list[dict]",
               head_sha: str) -> dict:
    """REST reviews and inline comments in gh-pr-fetch.sh's blob shape.

    Only reviews with a body are kept: a reply posted to a thread files an
    empty review of its own, which would otherwise stand as the latest.
    """
    return {
        "head_sha": head_sha,
        "reviews": [{"author": r["user"]["login"], "state": r.get("state"),
                     "body": r["body"], "commit": r.get("commit_id"),
                     "submitted_at": r.get("submitted_at")}
                    for r in reviews if (r.get("body") or "").strip()],
        "review_comments": [{"id": c["id"], "in_reply_to": c.get("in_reply_to_id"),
                             "author": c["user"]["login"], "path": c.get("path"),
                             "line": c.get("line"), "commit": c.get("commit_id"),
                             "body": c.get("body"), "created_at": c.get("created_at")}
                            for c in inline],
    }


def prior_review(blob: dict, viewer: str) -> dict:
    """gh-pr-prior-review.sh's answer for the viewer over one blob."""
    return json.loads(run([PRIOR_REVIEW, "--as", viewer], stdin=json.dumps(blob)))


def own_review(reviews: "list[dict]", inline: "list[dict]", issue: "list[dict]",
               viewer: str, head_sha: str, pr_author: str) -> dict:
    """The viewer's latest review as asks to answer, on the viewer's own PR."""
    if viewer != pr_author:
        return {"own_review": None, "own_open_count": 0}
    prior = prior_review(fetch_blob(reviews, inline, head_sha), viewer)
    mine = prior["prior"]
    findings = [{"id": f["id"], "path": f["path"], "line": f["line"],
                 "body": f["body"], "already_replied": bool(f["replies"])}
                for f in prior["findings"]]
    review = None
    if mine is not None:
        raw = next(r for r in reviews if r["user"]["login"] == viewer
                   and r.get("submitted_at") == mine["submitted_at"])
        anchor = f"pullrequestreview-{raw['id']}"
        review = {
            "id": raw["id"], "html_url": raw.get("html_url"),
            "state": mine["state"], "commit": mine["commit"],
            "stale": mine["stale"], "body": mine["body"],
            "asks": bool(ASK_SECTION.search(mine["body"] or "")),
            "answered": any(c["user"]["login"] == viewer
                            and (c.get("created_at") or "") > mine["submitted_at"]
                            and anchor in (c.get("body") or "") for c in issue),
            "findings": findings,
        }
    return {"own_review": review,
            "own_open_count": sum(1 for f in findings if not f["already_replied"])}


def _comment(cid, login, body="", reply_to=None, at=None):
    return {"id": cid, "user": {"login": login}, "body": body,
            "in_reply_to_id": reply_to, "created_at": at}


def _review(rid, login, body, at, state="COMMENTED"):
    return {"id": rid, "user": {"login": login}, "body": body,
            "submitted_at": at, "state": state}


def _self_test() -> int:
    inline = [
        _comment(1, "greptile-apps[bot]", 'x <img alt="P1"> nested'),
        _comment(2, "coderabbitai[bot]", "answered already"),
        _comment(3, "iguigova", "reply to the rabbit", reply_to=2),
        _comment(4, "a-human", "human top-level comment"),
        _comment(5, "greptile-apps[bot]", "reply from the bot itself", reply_to=1),
    ]
    issue = [_comment(9, "greptile-apps[bot]", "run summary"),
             _comment(10, "iguigova", "looks good")]
    t = Tap()
    want = t.check

    r = classify(inline, issue, [])
    want([t["id"] for t in r["threads"]] == [1, 2],
         "only top-level bot threads are listed", f"threads {[t['id'] for t in r['threads']]}, want [1, 2]")
    want(r["threads"][0]["severity"] == "P1", "the severity is parsed from the img alt", "severity not parsed from the img alt")
    want(r["threads"][0]["already_replied"] is True,
         "a thread the bot itself replied to is marked replied", "a thread the bot itself replied to is not marked replied")
    want(r["threads"][1]["already_replied"] is True,
         "a thread a human replied to is marked replied", "a thread a human replied to is not marked replied")
    want(r["open_count"] == 0, "a replied thread is not open", f"open_count {r['open_count']}, want 0")
    want([s["id"] for s in r["summary"]] == [9],
         "a human issue comment is not a bot summary", "the human issue comment leaked into the bot summaries")

    # A substring filter narrows to one bot, and leaves the rest out entirely.
    r = classify(inline, issue, ["greptile"])
    want([t["id"] for t in r["threads"]] == [1],
         "a substring filter narrows to one bot", f"greptile filter gave {[t['id'] for t in r['threads']]}, want [1]")

    # An unanswered bot thread is what the skill exists to find.
    r = classify([_comment(1, "greptile-apps[bot]", "unanswered")], [], [])
    want(r["open_count"] == 1, "an unanswered bot thread is counted open", "an unanswered bot thread is not counted open")

    # A human reviewer's thread is open until someone other than them answers,
    # and neither a bot nor the viewer counts as a reviewer.
    h_inline = inline + [
        _comment(6, "a-human", "follow-up from the same human", reply_to=4),
        _comment(7, "iguigova", "the viewer's own top-level note"),
        _comment(8, "reviewer-two", "answered"),
        _comment(11, "iguigova", "answer", reply_to=8),
    ]
    h = classify_humans(h_inline, [], [], "iguigova")
    want([t["id"] for t in h["human_threads"]] == [4, 8],
         "a human reviewer's top-level threads are listed", f"human threads {[t['id'] for t in h['human_threads']]}, want [4, 8]")
    want(h["human_threads"][0]["already_replied"] is False,
         "a reviewer's own follow-up does not close their thread", "a reviewer's own follow-up closed their thread")
    want(h["human_threads"][1]["already_replied"] is True,
         "the viewer's reply closes a human thread", "the viewer's reply did not close a human thread")
    want(h["human_open_count"] == 1,
         "the open human threads are counted", f"human_open_count {h['human_open_count']}, want 1")

    # Narrowing the bot filter never turns another bot into a human.
    h = classify_humans([_comment(1, "coderabbitai[bot]", "x")], [], [], "me")
    want(h["human_threads"] == [], "a bot outside the filter is not a human", "a bot outside the filter counted as human")

    # A note is answered only by the viewer speaking after it; a bare
    # approval is not a note.
    reviews = [_review(20, "jp", "", "2026-01-01T10:00:00Z", "APPROVED"),
               _review(21, "jp", "please rename", "2026-01-01T11:00:00Z")]
    issue_h = [_comment(22, "ci-user", "Preview deployed", at="2026-01-01T09:00:00Z"),
               _comment(23, "me", "renamed", at="2026-01-01T12:00:00Z"),
               _comment(24, "jp", "one more", at="2026-01-01T13:00:00Z")]
    notes = classify_humans([], reviews, issue_h, "me")["human_notes"]
    want([(n["id"], n["answered"]) for n in notes]
         == [(22, True), (21, True), (24, False)],
         "a note is answered only by the viewer speaking after it", f"notes {[(n['id'], n['answered']) for n in notes]}, "
         "want [(22, True), (21, True), (24, False)]")

    # On the viewer's own PR, the latest review with a body is an ask; its
    # inline findings close on any reply, and the body only on a PR comment
    # that links it. On anyone else's PR there is no own review.
    o_reviews = [_review(30, "me", "**Nits:** x", "2026-01-01T10:00:00Z"),
                 _review(35, "me", "", "2026-01-01T10:30:00Z")]
    o_inline = [_comment(31, "me", "open finding"),
                _comment(32, "me", "answered finding"),
                _comment(33, "me", "fixed", reply_to=32)]
    o_issue = [_comment(40, "me", "unrelated", at="2026-01-01T11:00:00Z")]
    o = own_review(o_reviews, o_inline, o_issue, "me", "h1", "someone-else")
    want(o == {"own_review": None, "own_open_count": 0},
         "no own review surfaces on someone else's PR", "an own review surfaced on someone else's PR")
    o = own_review(o_reviews, o_inline, o_issue, "me", "h1", "me")
    r = o["own_review"]
    want(r is not None and r["id"] == 30,
         "the own review is the latest with a body", f"own review {r and r['id']}, want 30 (an empty reply review displaced it)")
    want(r is not None and r["asks"] is True, "a Nits section asks", "a Nits section did not ask")
    want(r is not None and r["answered"] is False,
         "an unrelated PR comment does not answer the own review", "an unrelated PR comment answered the own review")
    want([(f["id"], f["already_replied"]) for f in (r or {}).get("findings", [])]
         == [(31, False), (32, True)], "an own finding closes on any reply", f"own findings {r and r['findings']}")
    want(o["own_open_count"] == 1, "the open own findings are counted", f"own_open_count {o['own_open_count']}, want 1")
    o_issue.append(_comment(41, "me", "Addressed: pull/1#pullrequestreview-30",
                            at="2026-01-01T12:00:00Z"))
    o = own_review(o_reviews, o_inline, o_issue, "me", "h1", "me")
    want(o["own_review"]["answered"] is True,
         "a PR comment linking the review answers it", "a PR comment linking the review did not answer it")
    o = own_review([_review(36, "me", "Approve: **Checked and cleared:** x",
                            "2026-01-01T13:00:00Z")], [], [], "me", "h1", "me")
    want(o["own_review"]["asks"] is False, "a clean approve asks nothing", "a clean approve asked something")

    want(is_bot("Greptile-Apps[bot]", []), "the [bot] suffix is matched in any case", "case-sensitive [bot] suffix missed")
    want(not is_bot("iguigova", []), "a human is not a bot", "a human counted as a bot")

    return t.end()


def main() -> None:
    args = sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        raise SystemExit(0)
    if args[:1] == ["--self-test"]:
        raise SystemExit(_self_test())
    if not args:
        die("Usage: gh-pr-bot-comments.sh <pr-ref> [bot-login-substr ...] | --self-test")
    try:
        owner, repo, number = parse_ref(args[0])
    except RefError as exc:
        die(str(exc))
    substrs = [s.lower() for s in args[1:]]
    slug = f"{owner}/{repo}"

    inline = gh_json(f"repos/{slug}/pulls/{number}/comments")
    issue = gh_json(f"repos/{slug}/issues/{number}/comments")
    reviews = gh_json(f"repos/{slug}/pulls/{number}/reviews")
    viewer = run(["gh", "api", "user", "--jq", ".login"]).strip()
    view = json.loads(
        run(["gh", "pr", "view", number, "--repo", slug,
             "--json", "reviewDecision,headRefOid,author"])
        or "{}"
    )

    print(json.dumps({
        "owner": owner, "repo": repo, "number": int(number),
        "review_decision": view.get("reviewDecision"),
        **classify(inline, issue, substrs),
        **classify_humans(inline, reviews, issue, viewer),
        **own_review(inline=inline, reviews=reviews, issue=issue, viewer=viewer,
                     head_sha=view.get("headRefOid", ""),
                     pr_author=(view.get("author") or {}).get("login", "")),
    }, indent=2))


if __name__ == "__main__":
    main()
