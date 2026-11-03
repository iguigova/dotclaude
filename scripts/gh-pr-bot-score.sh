#!/usr/bin/env python3
"""Read a review bot's verdict on a PR: its confidence score, the commit that
score was written against, and the findings it could not post inline.

Usage:
    gh-pr-bot-score.sh <pr-ref> [bot-login-substr ...]
    gh-pr-bot-score.sh --self-test

<pr-ref> takes the same forms as the sibling helpers:
    https://github.com/Org/repo/pull/123
    Org/repo#123
    #123                 (uses CWD's git remote)

Extra args narrow the bot filter (default: greptile). They are passed straight
through to gh-pr-bot-comments.sh, which owns ref parsing, pagination and the
bot-login rule; this never re-implements them.

Output JSON (to stdout):
    {
      "owner", "repo", "number",
      "head_sha":     "<the PR's current head>",
      "score":        <int>   | null,   # Greptile's "Confidence Score: N/5"
      "max":          <int>   | null,
      "at_max":       <bool>,           # score == max
      "reviewed_sha": "<sha>" | null,   # the commit the score was written for
      "stale":        <bool>,           # reviewed_sha does not match head_sha
      "outside_diff": [ {severity, title, path, body} ],
      "outside_diff_count": <int>
    }

Two fields carry the whole point:

`stale` is true when the bot's last run predates the current head, which is the
normal state right after a push. A score read while stale describes the old
code, so `gh-pr-bot-fetch.sh --wait` waits for it to clear before believing the number. A score
of null with stale true means the new run has not reported yet.

`outside_diff` holds the findings the bot raised on lines the diff does not
cover, each with its `body`, the bot's prose for it. Greptile posts these in
an issue comment, not as review threads, so they never appear in
gh-pr-bot-comments.sh's `threads[]` and never count towards its `open_count`. A PR can read as "no open threads" with real
findings outstanding; this is where they surface.

A listed finding is a worklist entry, not a blocker: one already addressed
can stay listed, as two anchored to deleted files did on psi-serverless
PR #194 (2026-09-23). Reconcile the list against the replies already posted; `at_max` is the bot's verdict, not the
length of this array.

Exits non-zero if any gh call fails.
"""
import json
import os
import re
import subprocess
import sys
import textwrap

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gh_pr_ref import RefError, parse_ref  # noqa: E402
from tap import Tap  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

# "Confidence Score: 4/5", wherever it sits in the HTML the bot posts.
SCORE_RE = re.compile(r"Confidence\s+Score:\s*(\d+)\s*/\s*(\d+)", re.I)
# The summary footer links the commit it reviewed: .../commit/<sha>
COMMIT_RE = re.compile(r"/commit/([0-9a-f]{7,40})", re.I)
# The marker Greptile puts on the comment holding its out-of-diff findings.
OUTSIDE_MARKER = "greptile_outside_diff"
# One out-of-diff bullet: severity badge, bold title, then a `path:line`.
OUTSIDE_RE = re.compile(
    r'^-\s*<img\s+alt="(?P<severity>P\d)".*?\*\*(?P<title>.+?)\*\*\s*`(?P<path>[^`]+)`',
    re.M,
)


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def parse_score(body: str):
    """(score, max) from a bot summary body, or (None, None)."""
    m = SCORE_RE.search(body or "")
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def parse_reviewed_sha(body: str):
    """The last commit the bot says it reviewed, or None.

    The footer link is the last commit URL in the body; earlier ones may point
    at unrelated commits the summary happens to mention.
    """
    found = COMMIT_RE.findall(body or "")
    return found[-1].lower() if found else None


def parse_outside_diff(body: str):
    """The out-of-diff findings in a bot summary body.

    A finding's body is the indented prose after its bullet line, up to the
    next bullet. The comment's own trailing note is indented the same way, so
    the last finding carries it.
    """
    body = body or ""
    matches = list(OUTSIDE_RE.finditer(body))
    out = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
        line_end = body.find("\n", m.end())
        prose = body[line_end:end] if line_end != -1 and line_end < end else ""
        out.append(
            {
                "severity": m.group("severity"),
                "title": m.group("title").strip(),
                "path": m.group("path").strip(),
                "body": textwrap.dedent(prose).strip(),
            }
        )
    return out


def shas_match(a: "str | None", b: "str | None") -> bool:
    """True when two shas name the same commit, allowing an abbreviation.

    The bot's footer link is often abbreviated, so an equality test on the full
    head sha would call every score stale.
    """
    if not a or not b:
        return False
    a, b = a.lower(), b.lower()
    n = min(len(a), len(b))
    return n >= 7 and a[:n] == b[:n]


def build(head_sha, summaries):
    """Fold the bot's summary comments into the verdict. Pure; self-tested."""
    score = maximum = reviewed = None
    outside: "list[dict]" = []
    for entry in summaries:
        body = entry.get("body") or ""
        if OUTSIDE_MARKER in body:
            outside.extend(parse_outside_diff(body))
            continue
        s, mx = parse_score(body)
        if s is not None:
            score, maximum = s, mx
            reviewed = parse_reviewed_sha(body)
    return {
        "head_sha": head_sha,
        "score": score,
        "max": maximum,
        "at_max": score is not None and score == maximum,
        "reviewed_sha": reviewed,
        "stale": not shas_match(reviewed, head_sha),
        "outside_diff": outside,
        "outside_diff_count": len(outside),
    }


def self_test() -> int:
    t = Tap()
    want = t.check

    summary = (
        '<!-- greptile_summary -->\n<h2><a href="https://app.greptile.com/api/'
        'retrigger?id=1"><img alt="Retrigger"></a>Confidence Score: 4/5</h2>\n'
        "<h3>Summary</h3>\n- Does a thing.\n"
        '<sub>Reviews (1) · Last reviewed commit: ["ABC-10785: one name..."]'
        "(https://github.com/acme/billing-service/commit/38b76486df4d8980"
        "ce306f2515dab05d3f7f4753)</sub>"
    )
    outside = (
        "<!-- greptile_outside_diff -->\n<h3>Comments Outside Diff</h3>\n"
        '- <img alt="P2" src="p2.svg" align="top">&nbsp;**Deleted builders '
        "remain documented** `apps/functions/apis/cybersource/config/"
        'cybersource_create_plan_request.py:1` <a href="x">▶</a>\n\n'
        "  Removing these request builders leaves the docs stale.\n"
        '- <img alt="P1" src="p1.svg" align="top">&nbsp;**Console utilities '
        'no longer import** `apps/x/configuration.py:59` <a href="x">▶</a>\n\n'
        "  Removing the class breaks the console utilities.\n"
        "  They fail at import.\n"
    )

    want(parse_score(summary) == (4, 5), "the confidence score is parsed", f"score: got {parse_score(summary)}, want (4, 5)")
    want(parse_score("no score here") == (None, None), "a body with no score gives no score", "a body with no score must give (None, None)")
    want(parse_score("Confidence Score: 5 / 5") == (5, 5), "spaces around the slash still parse", "spaces around the slash must still parse")

    want(
        parse_reviewed_sha(summary) == "38b76486df4d8980ce306f2515dab05d3f7f4753",
        "the reviewed commit is parsed from the footer link", f"reviewed sha: got {parse_reviewed_sha(summary)}",
    )
    want(parse_reviewed_sha("nothing") is None, "a body with no commit link gives no commit", "a body with no commit link must give None")
    # The footer link is the last one; an earlier mention must not win.
    want(
        parse_reviewed_sha("see /commit/aaaaaaa then /commit/bbbbbbb") == "bbbbbbb",
        "the last commit link wins, not the first", "the last commit link must win, not the first",
    )

    od = parse_outside_diff(outside)
    want(len(od) == 2, "each outside-diff finding is found", f"outside-diff count: got {len(od)}, want 2")
    want(od and od[0]["severity"] == "P2", "an outside-diff finding keeps its severity", "outside-diff severity must be P2")
    want(
        od and od[0]["path"] == "apps/functions/apis/cybersource/config/cybersource_create_plan_request.py:1",
        "an outside-diff finding keeps its path", f"outside-diff path: got {od[0]['path'] if od else None}",
    )
    want(od and od[0]["title"] == "Deleted builders remain documented", "an outside-diff title is the bold text", "outside-diff title must be the bold text")
    # Each body stops at the next bullet, and keeps its own lines, dedented.
    want(
        od and od[0]["body"] == "Removing these request builders leaves the docs stale.",
        "a finding's body stops at the next bullet", f"first body: got {od[0]['body'] if od else None!r}",
    )
    want(
        len(od) == 2 and od[1]["body"] == "Removing the class breaks the console utilities.\nThey fail at import.",
        "a finding's body keeps its own lines, dedented", f"last body: got {od[1]['body'] if len(od) == 2 else None!r}",
    )

    want(shas_match("38b7648", "38b76486df4d8980ce306f2515dab05d3f7f4753"), "an abbreviated sha matches its full form", "an abbreviated sha must match its full form")
    want(not shas_match("cd10c2c", "38b76486df4d8980"), "different shas do not match", "different shas must not match")
    want(not shas_match(None, "38b7648"), "a missing sha never matches", "a missing sha must never match")
    want(not shas_match("38b7648", None), "a missing head never matches", "a missing head must never match")
    # Seven hex characters is the shortest abbreviation git prints; below that a
    # prefix test would match unrelated commits.
    want(not shas_match("38b", "38b7648"), "a sha shorter than 7 characters does not match", "a sha shorter than 7 chars must not match")

    full = build(
        "38b76486df4d8980ce306f2515dab05d3f7f4753",
        [{"body": summary}, {"body": outside}],
    )
    want(full["score"] == 4 and full["max"] == 5, "build carries the score through", "build must carry the score through")
    want(full["at_max"] is False, "4/5 is not at max", "4/5 is not at_max")
    want(full["stale"] is False, "a score written for the head commit is not stale", "a score written for the head commit is not stale")
    want(full["outside_diff_count"] == 2, "build carries the outside-diff findings through", "build must carry the outside-diff findings through")

    moved = build("cd10c2cfeedfacefeedfacefeedfacefeedface0", [{"body": summary}, {"body": outside}])
    want(moved["stale"] is True, "a score written for an older commit reads stale", "a score written for an older commit must read stale")

    none_yet = build("cd10c2c", [])
    want(none_yet["score"] is None, "no summary means no score", "no summary means no score")
    want(none_yet["stale"] is True, "no score at all reads stale, never fresh", "no score at all must read stale, never fresh")
    want(none_yet["at_max"] is False, "a missing score is never at max", "a missing score is never at_max")

    maxed = build("38b7648", [{"body": summary.replace("4/5", "5/5")}])
    want(maxed["at_max"] is True, "5/5 reads at max", "5/5 must read at_max")

    # parse_ref returns a 3-tuple, not a dict. Testing only the pure folds left
    # main()'s unpack unguarded, and it shipped wrong once; assert the contract
    # here. The slug form needs no git remote, so this stays offline.
    want(
        parse_ref("Org/repo#123") == ("Org", "repo", "123"),
        "parse_ref returns a 3-tuple", f"parse_ref contract: got {parse_ref('Org/repo#123')}, want a 3-tuple",
    )

    return t.end()


def main(argv: "list[str]") -> int:
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    if len(argv) == 1 and argv[0] == "--self-test":
        return self_test()
    if not argv:
        print("Usage: gh-pr-bot-score.sh <pr-ref> [bot-login-substr ...] | --self-test", file=sys.stderr)
        return 1

    ref, bots = argv[0], (argv[1:] or ["greptile"])
    try:
        owner, repo, number = parse_ref(ref)
    except RefError as e:
        die(str(e))

    res = subprocess.run(
        [os.path.join(HERE, "gh-pr-bot-comments.sh"), ref, *bots],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        die(res.stderr.strip() or "gh-pr-bot-comments.sh failed")
    comments = json.loads(res.stdout)

    res = subprocess.run(
        ["gh", "pr", "view", str(number), "--repo", f"{owner}/{repo}", "--json", "headRefOid"],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        die(res.stderr.strip() or "gh pr view failed")
    head_sha = json.loads(res.stdout)["headRefOid"]

    out = {"owner": owner, "repo": repo, "number": number}
    out.update(build(head_sha, comments.get("summary", [])))
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
