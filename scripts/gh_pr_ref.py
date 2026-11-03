#!/usr/bin/env python3
"""The one parser for a PR reference, shared by every gh-pr-* helper.

A PR reference is one of:
    https://github.com/Org/repo/pull/123
    Org/repo#123
    #123                 (owner/repo inferred from the CWD git remote 'origin')

A session that has already been named after a PR carries the fourth form in its
own title: `gh-pr-name-session.sh` writes `<TICKET> PR <PR URL>` for /review:pr
and `<TICKET> BOT <PR URL>` for /review:bot, so a review
resumed or re-run without an argument recovers its PR from the transcript
instead of asking. `--from-session` is that lookup.

Importable (``from gh_pr_ref import parse_ref``) and runnable:

    gh_pr_ref.py <pr-ref>     -> {"owner","repo","number","slug"} on stdout
    gh_pr_ref.py --from-session  -> the PR URL in the session title, on stdout
    gh_pr_ref.py --self-test

A bad ref exits 1 with the reason on stderr; `#N` outside a GitHub clone says
so rather than guessing a repo, and `--from-session` outside a session, or in
one whose title names no PR, says which of the two it was.
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys

from tap import Tap

# One definition of the URL shape, used two ways: anchored to parse a ref that
# should be nothing but a URL, and unanchored to pick one out of a session title.
_URL_BODY = r"https?://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/pull/(\d+)"
URL_RE = re.compile(r"^" + _URL_BODY)
URL_IN_TEXT_RE = re.compile(_URL_BODY)
TITLE_TYPE = "custom-title"
SLUG_RE = re.compile(r"^([^/\s]+)/([^/#\s]+?)(?:\.git)?#(\d+)$")
NUM_RE = re.compile(r"^#?(\d+)$")
REMOTE_RE = re.compile(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$")


class RefError(ValueError):
    """A reference that does not name a PR."""


def _origin_url() -> str:
    res = subprocess.run(["git", "remote", "get-url", "origin"],
                         capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else ""


def parse_ref(ref: str) -> "tuple[str, str, str]":
    """(owner, repo, number-as-string). Raises RefError on anything else."""
    ref = (ref or "").strip()
    m = URL_RE.match(ref)
    if m:
        return m.group(1), m.group(2), m.group(3)
    m = SLUG_RE.match(ref)
    if m:
        return m.group(1), m.group(2), m.group(3)
    m = NUM_RE.match(ref)
    if m:
        remote = _origin_url()
        rm = REMOTE_RE.search(remote)
        if not rm:
            raise RefError(
                f"'{ref}' needs a GitHub 'origin' remote in the CWD to name a repo "
                f"(git remote get-url origin gave: '{remote}'). "
                f"Pass Org/repo#{m.group(1)} or the full PR URL instead.")
        return rm.group(1), rm.group(2), m.group(1)
    raise RefError(f"Unrecognized PR ref: '{ref}' "
                   f"(want a PR URL, Org/repo#N, or #N inside the repo's clone)")


def parse_slug(ref: str) -> "tuple[str, str, str, str]":
    """(owner, repo, number, 'owner/repo')."""
    owner, repo, number = parse_ref(ref)
    return owner, repo, number, f"{owner}/{repo}"


def _transcript_path() -> str:
    """The current session's JSONL transcript. Raises RefError when there is none.

    Resolved the way session_rename.sh resolves it — the same
    SESSION_RENAME_TRANSCRIPT override, so one env var names the transcript for
    the script that writes a title and the one that reads it back.
    """
    override = os.environ.get("SESSION_RENAME_TRANSCRIPT", "")
    if override:
        if not os.path.isfile(override):
            raise RefError(f"SESSION_RENAME_TRANSCRIPT points at no file: '{override}'")
        return override
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not sid:
        raise RefError("CLAUDE_CODE_SESSION_ID is unset — not inside a Claude Code "
                       "session, so there is no session title to read. "
                       "Pass the PR ref explicitly.")
    home = os.environ.get("HOME", "")
    for path in sorted(glob.glob(os.path.join(home, ".claude", "projects", "*", f"{sid}.jsonl"))):
        if os.path.isfile(path):
            return path
    raise RefError(f"no transcript found for session {sid} — "
                   f"pass the PR ref explicitly.")


def session_ref() -> str:
    """The PR URL this session was named after, e.g. from `ABC-10810 PR <url>`.

    A session title is the last `custom-title` record in the transcript, which
    is what session_rename.sh appends and gh-pr-name-session.sh fills with the
    PR URL. This reads back the most recent title that carries a URL: a later
    rename that drops it (a hand-written title, another skill's) hides the PR
    from the header but does not erase it from the session's history.

    Only `custom-title` is read. The CLI's auto-titler appends `ai-title`
    records, which a custom-title outranks and which never carry a PR URL.

    Raises RefError when the session, or a PR in its title, is missing — the
    caller asks for the ref rather than guessing one.
    """
    path = _transcript_path()
    found = ""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            # Cheap reject first: a transcript is mostly multi-KB message records.
            if TITLE_TYPE not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue  # a truncated or partly-written line is not a title
            if not isinstance(rec, dict) or rec.get("type") != TITLE_TYPE:
                continue
            m = URL_IN_TEXT_RE.search(str(rec.get("customTitle", "")))
            if m:
                found = m.group(0)
    if not found:
        raise RefError(f"no PR URL in any session title in {path} — "
                       f"this session has not been named after a PR. "
                       f"Pass the PR ref explicitly.")
    return found


def _self_test() -> int:
    t = Tap()
    cases = [
        ("a PR URL parses",
         "https://github.com/Acme/sensor-connector/pull/456",
         ("Acme", "sensor-connector", "456")),
        ("a PR URL whose repo ends in .git parses",
         "https://github.com/AcmeLabs/py-sdk.git/pull/7",
         ("AcmeLabs", "py-sdk", "7")),
        ("an owner/repo and number parse",
         "Acme/web-app#5236", ("Acme", "web-app", "5236")),
        ("a ref padded with spaces parses",
         "  AcmeLabs/web-hub#12  ", ("AcmeLabs", "web-hub", "12")),
    ]
    bad = [("an empty ref is refused", ""),
           ("a word is refused", "not-a-ref"),
           ("an owner/repo with no number is refused", "Org/repo"),
           ("an owner/repo with an empty number is refused", "Org/repo#"),
           ("a bare number sign is refused", "#"),
           ("a three-part path is refused", "a/b/c#1"),
           ("a URL off GitHub is refused", "https://gitlab.com/o/r/pull/1")]
    for name, ref, want in cases:
        try:
            got = parse_ref(ref)
        except RefError as exc:
            got = f"RefError: {exc}"
        t.check(got == want, name, f"{ref!r} -> {got}, want {want}")
    # '#N' forms are the only ones allowed to consult the remote; none of
    # these are that form, so a parse here is a real over-acceptance.
    for name, ref in bad:
        try:
            got = parse_ref(ref)
        except RefError:
            got = None
        t.check(got is None, name, f"{ref!r} parsed as {got}")

    # --- session titles, offline, against a transcript built here ---------
    import tempfile

    def title(text):
        return json.dumps({"type": "custom-title", "customTitle": text,
                           "sessionId": "s"})

    def read_back():
        try:
            return session_ref()
        except RefError:
            return None

    lines = [
        json.dumps({"type": "user", "text": "irrelevant"}),
        title("XYZ-1234 PR https://github.com/Acme/web-app/pull/5236"),
        json.dumps({"type": "ai-title", "title": "https://github.com/x/y/pull/999"}),
        "{ not json",
        # The latest title is /review:bot's form, the earlier one /review:pr's.
        title("ABC-10810 BOT https://github.com/Acme/events-service/pull/13"),
        title("a hand-written title with no PR in it"),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        tpath = os.path.join(tmp, "t.jsonl")
        with open(tpath, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        saved = os.environ.get("SESSION_RENAME_TRANSCRIPT")
        os.environ["SESSION_RENAME_TRANSCRIPT"] = tpath
        try:
            got = read_back()
            want = "https://github.com/Acme/events-service/pull/13"
            # The later URL-less title must not hide it, the ai-title must not
            # win it, and the malformed line must not stop the scan.
            t.check(got == want,
                    "the session's PR is read back past a later title-less"
                    " rename, an ai-title and a malformed line",
                    f"got {got!r}, want {want!r}")
            t.check(got is not None and parse_ref(got)
                    == ("Acme", "events-service", "13"),
                    "the PR read back parses again")
            # A transcript with no PR in any title must raise, never return "".
            empty = os.path.join(tmp, "empty.jsonl")
            with open(empty, "w", encoding="utf-8") as fh:
                fh.write(title("ABC-10810 no link here") + "\n")
            os.environ["SESSION_RENAME_TRANSCRIPT"] = empty
            got = read_back()
            t.check(got is None, "a transcript with no PR title is refused",
                    f"returned {got!r}")
            os.environ["SESSION_RENAME_TRANSCRIPT"] = os.path.join(tmp, "nope.jsonl")
            got = read_back()
            t.check(got is None, "a missing transcript is refused",
                    f"returned {got!r}")
        finally:
            if saved is None:
                os.environ.pop("SESSION_RENAME_TRANSCRIPT", None)
            else:
                os.environ["SESSION_RENAME_TRANSCRIPT"] = saved
    return t.end()


def main() -> None:
    args = sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        raise SystemExit(0)
    if args and args[0] == "--self-test":
        raise SystemExit(_self_test())
    if args and args[0] == "--from-session":
        try:
            print(session_ref())
        except RefError as exc:
            print(str(exc), file=sys.stderr)
            raise SystemExit(1)
        return
    if len(args) != 1:
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        raise SystemExit(1)
    try:
        owner, repo, number, slug = parse_slug(args[0])
    except RefError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps({"owner": owner, "repo": repo,
                      "number": int(number), "slug": slug}))


if __name__ == "__main__":
    main()
