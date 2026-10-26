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
    cases = [
        ("https://github.com/Acme/sensor-connector/pull/456",
         ("Acme", "sensor-connector", "456")),
        ("https://github.com/AcmeLabs/py-sdk.git/pull/7",
         ("AcmeLabs", "py-sdk", "7")),
        ("Acme/web-app#5236", ("Acme", "web-app", "5236")),
        ("  AcmeLabs/web-hub#12  ", ("AcmeLabs", "web-hub", "12")),
    ]
    bad = ["", "not-a-ref", "Org/repo", "Org/repo#", "#", "a/b/c#1",
           "https://gitlab.com/o/r/pull/1"]
    fails = []
    for ref, want in cases:
        try:
            got = parse_ref(ref)
        except RefError as exc:
            fails.append(f"{ref!r} raised {exc}")
            continue
        if got != want:
            fails.append(f"{ref!r} -> {got}, want {want}")
    for ref in bad:
        try:
            got = parse_ref(ref)
        except RefError:
            continue
        # '#N' forms are the only ones allowed to consult the remote; none of
        # these are that form, so a parse here is a real over-acceptance.
        fails.append(f"{ref!r} parsed as {got}, want a RefError")

    # --- session titles, offline, against a transcript built here ---------
    import tempfile

    def title(text):
        return json.dumps({"type": "custom-title", "customTitle": text,
                           "sessionId": "s"})

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
            got = session_ref()
            want = "https://github.com/Acme/events-service/pull/13"
            if got != want:
                # The later URL-less title must not hide it, the ai-title must not
                # win it, and the malformed line must not stop the scan.
                fails.append(f"session_ref -> {got!r}, want {want!r}")
            else:
                owner, repo, number = parse_ref(got)
                if (owner, repo, number) != ("Acme", "events-service", "13"):
                    fails.append(f"session_ref output does not re-parse: {got!r}")
            # A transcript with no PR in any title must raise, never return "".
            empty = os.path.join(tmp, "empty.jsonl")
            with open(empty, "w", encoding="utf-8") as fh:
                fh.write(title("ABC-10810 no link here") + "\n")
            os.environ["SESSION_RENAME_TRANSCRIPT"] = empty
            try:
                got = session_ref()
                fails.append(f"a title-less transcript returned {got!r}, want a RefError")
            except RefError:
                pass
            os.environ["SESSION_RENAME_TRANSCRIPT"] = os.path.join(tmp, "nope.jsonl")
            try:
                got = session_ref()
                fails.append(f"a missing transcript returned {got!r}, want a RefError")
            except RefError:
                pass
        finally:
            if saved is None:
                os.environ.pop("SESSION_RENAME_TRANSCRIPT", None)
            else:
                os.environ["SESSION_RENAME_TRANSCRIPT"] = saved

    if fails:
        print("gh_pr_ref self-test: FAIL\n  " + "\n  ".join(fails), file=sys.stderr)
        return 1
    print(f"gh_pr_ref self-test: PASS ({len(cases)} refs parsed, "
          f"{len(bad)} rejected incl. 'a/b/c#1', session title read back "
          f"past a later title-less rename, an ai-title and a malformed line)")
    return 0


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
