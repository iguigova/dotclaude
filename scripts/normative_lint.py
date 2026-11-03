#!/usr/bin/env python3
"""List the evolution language in a document: phrases that describe how it
changed rather than what is true.

Usage:
    normative_lint.py <file>...
    normative_lint.py --self-test

Each hit prints as `<file>:<line>: <phrase> | <the text around it>`. A
Confluence storage body is read as its text: tags are dropped, so markup and
URLs never match, and entities are decoded.

A hit is a flagged pattern, not a verdict. Its benign case is text whose job
is history (a changelog section, a quoted example of the phrase itself), and
text where the phrase is about the subject, not the document ("the batch is
retried as of the next run").

The phrases it flags, each a case-insensitive pattern:
    previously · used to be · formerly · as of v2 / as of 2026 · since v1
    now supports / accepts / requires / returns / uses / includes
    has been / have been updated, changed, renamed, replaced, moved,
        removed, added, deprecated
    no longer (but not "no longer than") · migrated from / to
    replaces the old · deprecated in favour of
    added / introduced / changed / updated / removed in v1 or on 2026-04
    recently · newly · improved
    this page / document / section was / has been updated

Exit 0 with no hits, 1 with hits, 2 on a usage error or an unreadable file.
"""

import argparse
import html
import re
import sys

from tap import Tap

PHRASES = [
    r"previously",
    r"used to be",
    r"formerly",
    r"as of v?\d",
    r"since v\d",
    r"now (?:supports|accepts|requires|returns|uses|includes)",
    r"ha(?:s|ve) been (?:updated|changed|renamed|replaced|moved|removed"
    r"|added|deprecated)",
    r"no longer(?! than)",
    r"migrated (?:from|to)",
    r"replaces the old",
    r"deprecated in favou?r of",
    r"(?:added|introduced|changed|updated|removed) (?:in |on )?"
    r"(?:v\d|\d{4}-\d{2})",
    r"recently",
    r"newly",
    r"improved",
    r"this (?:page|document|section) (?:was|has been) updated",
]
# Any whitespace between words, so a storage body's &nbsp; still matches.
PATTERN = re.compile(r"\b(?:" + "|".join(PHRASES).replace(" ", r"\s+") + r")\b",
                     re.IGNORECASE)
TAG = re.compile(r"<[^>]*>")
CONTEXT = 30


def text_of(source):
    """The source with every tag blanked, keeping its newlines so line
    numbers still point into the file, and entities decoded."""
    blanked = TAG.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), source)
    return html.unescape(blanked)


def hits(source):
    """(line number, phrase, surrounding text) for each phrase found."""
    found = []
    for number, line in enumerate(text_of(source).splitlines(), 1):
        for m in PATTERN.finditer(line):
            around = line[max(0, m.start() - CONTEXT):m.end() + CONTEXT]
            found.append((number, m.group(0), " ".join(around.split())))
    return found


def lint(paths):
    status = 0
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
        except (OSError, UnicodeDecodeError) as exc:
            print(f"normative_lint: cannot read {path}: {exc}", file=sys.stderr)
            return 2
        for number, phrase, around in hits(source):
            print(f"{path}:{number}: {phrase} | {around}")
            status = 1
    return status


def self_test():
    flagged = [
        "Previously this was a list.", "The field used to be required.",
        "The id (formerly slug) is stable.", "As of v2 it pages.",
        "Since v1.3 the cap is 30.", "The API now supports cursors.",
        "The endpoint has been renamed.", "Keys have been replaced.",
        "It no longer requires a key.",
        "Clients migrated from v1.", "This replaces the old endpoint.",
        "Deprecated in favor of /v2.", "Field (added 2026-04-01).",
        "Introduced in v3.", "Recently the limit rose.",
        "A newly added flag.", "Improved error codes.",
        "This page was updated to reflect the change.",
    ]
    benign = [
        "The window is no longer than 30 days.",
        "The key is used to sign the request.",
        "Retry now, or wait.", "Added to the queue on arrival.",
        '<a href="https://x.invalid/previously-asked">FAQ</a>',
    ]
    t = Tap()
    for phrase in flagged:
        t.check(bool(hits(phrase)), f"flagged: {phrase}")
    for phrase in benign:
        t.check(not hits(phrase), f"cleared: {phrase}")
    storage = ('<p class="improved">Intro</p>\n<ac:structured-macro\n'
               'ac:name="info"><p>The cap &mdash; previously\n'
               '30, and it no&nbsp;longer pages.</p>')
    got = [(n, p.replace("\xa0", " ")) for n, p, _ in hits(storage)]
    t.check(got == [(3, "previously"), (4, "no longer")],
            "a storage body is read as its text: tags dropped, entities"
            " decoded, line numbers kept", f"got {got}")
    return t.end()


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", metavar="file")
    parser.add_argument("--self-test", action="store_true",
                        help="run offline checks and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.paths:
        parser.error("name at least one file (or --self-test)")
    return lint(args.paths)


if __name__ == "__main__":
    sys.exit(main())
