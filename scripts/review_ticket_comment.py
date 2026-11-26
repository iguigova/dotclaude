#!/usr/bin/env python3
"""review_ticket_comment.py — the ticket comment a PR review ends with.

  review_ticket_comment.py PR-REF VERDICT [--review URL] [--must-fix TEXT]...
                           < ticket-prs.jsonl
  review_ticket_comment.py --self-test     # offline, no network

Prints the comment in Jira wiki markup, for jira-comment.sh to post. It
states the review's verdict on the PR, linked to the posted review, and
what the ticket waits on now, so every fact in it comes from an argument
or from GitHub and none from prose written by hand.

PR-REF is any form gh_pr_ref.py parses. VERDICT is one of ``approve``,
``nits``, ``follow-up`` or ``comment``: Approve, Approve with Nits,
Approve with follow-up and Comment. ``--review`` is the URL
gh_pr_review_post.py printed; without it the review was given in chat and
never posted, the comment says so and links the PR, and nothing is said
of what the ticket waits on. ``--must-fix`` is one fix the author owes
before the merge, in a line, and is given once per fix: a ``comment``
verdict needs at least one, and the approving verdicts take none.

Standard input is gh-ticket-prs.sh's output for the PR's ticket, read
after the review was posted: one JSON object per line, of which ``url``
and ``review`` are read. Each open PR other than the reviewed one whose
``review`` is not ``APPROVED`` is named as holding the ticket after an
approving verdict; a ``comment`` verdict sends the ticket back to the
author and reads no PR. An approving verdict whose input does not list
the reviewed PR is refused: the PR is open while it is reviewed, so such
input is a failed read, never a ticket with nothing left to approve.

Exit 0: printed. Exit 1: a usage error, a bad PR-REF, or must-fix lines
that do not fit the verdict. Exit 2: standard input is no JSON lines, or
does not list the reviewed PR.
"""
import argparse
import json
import sys

from gh_pr_ref import parse_ref
from tap import Tap

APPROVED = 'APPROVED'
OPENINGS = {
    'approve': 'I approved {link}.',
    'nits': 'I approved {link}, with nits only.',
    'follow-up': 'I approved {link}, with follow-ups that can land after '
                 'the merge.',
    'comment': 'I reviewed {link}. These need fixing before it merges:',
}
LABELS = {'approve': 'Approve', 'nits': 'Approve with nits',
          'follow-up': 'Approve with follow-up', 'comment': 'Comment'}
UNPOSTED = 'My review of {link} was given in chat and not posted on GitHub: {label}.'
BACK_TO_AUTHOR = 'The ticket is back with the author for these fixes.'
ALL_APPROVED = 'Every open PR on the ticket is approved.'
WAITS_ON = 'The ticket waits on an approving review of {links} too.'


class UsageError(Exception):
    """The arguments do not make a comment."""


class InputError(Exception):
    """Standard input is not the ticket's open PRs."""


# ── The comment ──────────────────────────────────────────────────────

def pr_of(ref):
    """The PR's URL and its short label, repo#number."""
    owner, repo, number = parse_ref(ref)
    return f'https://github.com/{owner}/{repo}/pull/{number}', f'{repo}#{number}'


def link(label, url):
    return f'[{label}|{url}]'


def label_of(url):
    """repo#number for a PR URL."""
    return pr_of(url)[1]


def holders(prs, url):
    """The open PRs other than url that no approving review clears yet."""
    return [pr['url'] for pr in prs
            if pr['url'] != url and pr.get('review') != APPROVED]


def joined(items):
    """a, b and c."""
    return ' and '.join(filter(None, [', '.join(items[:-1]), items[-1]]))


def listed(prs, url):
    """InputError unless the PRs read include the reviewed one, which is
    open while its review is: a list without it is no answer."""
    if url not in [pr['url'] for pr in prs]:
        raise InputError(f'standard input does not list {url}; '
                         f'give gh-ticket-prs.sh output for its ticket')


def waits(verdict, prs, url):
    """What the ticket waits on once the review is posted."""
    if verdict == 'comment':
        return BACK_TO_AUTHOR
    listed(prs, url)
    held = holders(prs, url)
    if not held:
        return ALL_APPROVED
    return WAITS_ON.format(links=joined([link(label_of(h), h) for h in held]))


def opening(verdict, pr_link, review):
    if review is None:
        return UNPOSTED.format(link=pr_link, label=LABELS[verdict])
    return OPENINGS[verdict].format(link=pr_link)


def checked(verdict, must_fix):
    """UsageError unless the must-fix lines fit the verdict."""
    if (verdict == 'comment') != bool(must_fix):
        raise UsageError('a comment verdict takes one --must-fix per fix, '
                         'and an approving verdict takes none')


def comment(ref, verdict, review, must_fix, prs):
    """The comment's wiki markup."""
    checked(verdict, must_fix)
    url, label = pr_of(ref)
    head = opening(verdict, link(label, review or url), review)
    fixes = [f'* {fix}' for fix in must_fix]
    tail = [] if review is None else ['', waits(verdict, prs, url)]
    return '\n'.join([head, *fixes, *tail]) + '\n'


def ticket_prs(stream):
    """gh-ticket-prs.sh's lines as dicts."""
    return [json.loads(line) for line in stream if line.strip()]


# ── Self-test ────────────────────────────────────────────────────────

def self_test():
    t = Tap()
    pr = 'https://github.com/o/api/pull/7'
    other = {'url': 'https://github.com/o/web/pull/9', 'review': 'REVIEW_REQUIRED'}
    third = {'url': 'https://github.com/o/app/pull/3', 'review': 'CHANGES_REQUESTED'}
    mine = {'url': pr, 'review': APPROVED}
    done = {'url': 'https://github.com/o/web/pull/2', 'review': APPROVED}
    review = pr + '#pullrequestreview-1'

    def case(name, expected, actual):
        t.check(expected == actual, name, f'expected {expected!r}',
                f'got      {actual!r}')

    def refusal(step):
        try:
            step()
            return None
        except UsageError as error:
            return str(error)[:30]

    def input_refusal(step):
        try:
            step()
            return None
        except InputError as error:
            return str(error).split(' https')[0]

    case('an approve with nits links the review and names the PR holding it',
         '[api#7|' + review + '], with nits only.',
         comment('o/api#7', 'nits', review, [], [mine, other]).split(
             'I approved ')[1].split('\n')[0])
    case('a PR still unapproved holds the ticket',
         'The ticket waits on an approving review of '
         '[web#9|https://github.com/o/web/pull/9] too.',
         comment('o/api#7', 'nits', review, [], [mine, other]).split('\n')[2])
    case('two holders are joined with and',
         'The ticket waits on an approving review of '
         '[web#9|https://github.com/o/web/pull/9] and '
         '[app#3|https://github.com/o/app/pull/3] too.',
         waits('approve', [mine, other, third], pr))
    case('an approve read against no PRs is refused, never all approved',
         'standard input does not list',
         input_refusal(lambda: waits('approve', [], pr)))
    case('an approve read against PRs without the reviewed one is refused',
         'standard input does not list',
         input_refusal(lambda: waits('nits', [other], pr)))
    case('a comment reads no PR', BACK_TO_AUTHOR, waits('comment', [], pr))
    case('three holders are listed with commas and a final and',
         'a, b and c', joined(['a', 'b', 'c']))
    case('one item is itself', 'a', joined(['a']))
    case('the reviewed PR and approved PRs hold nothing', ALL_APPROVED,
         waits('follow-up', [mine, done], pr))
    case('the reviewed PR unapproved by others still holds nothing',
         ALL_APPROVED, waits('approve', [{'url': pr, 'review': 'X'}], pr))
    case('the PR listed exactly is accepted', None, listed([mine], pr))
    case('a PR with no review decision holds the ticket',
         [other['url']], holders([{'url': other['url']}], pr))
    case('a comment lists each fix and sends the ticket back',
         'I reviewed [api#7|' + review + ']. These need fixing before it '
         'merges:\n* a\n* b\n\n' + BACK_TO_AUTHOR + '\n',
         comment(pr, 'comment', review, ['a', 'b'], [other]))
    case('a plain approve opens without qualifier',
         'I approved [api#7|' + review + '].',
         comment(pr, 'approve', review, [], [mine]).split('\n')[0])
    case('a follow-up approve says the follow-ups can wait',
         'I approved [api#7|' + review + '], with follow-ups that can land '
         'after the merge.',
         comment(pr, 'follow-up', review, [], [mine]).split('\n')[0])
    case('an unposted review links the PR and says nothing of the ticket',
         'My review of [api#7|' + pr + '] was given in chat and not posted '
         'on GitHub: Comment.\n* a\n',
         comment(pr, 'comment', None, ['a'], [other]))
    case('a comment without a fix is refused',
         'a comment verdict takes one --', refusal(
             lambda: comment(pr, 'comment', review, [], [])))
    case('an approve with a fix is refused',
         'a comment verdict takes one --', refusal(
             lambda: comment(pr, 'approve', review, ['a'], [])))
    case('JSON lines are read, blank ones skipped', [mine, other],
         ticket_prs([json.dumps(mine) + '\n', '\n', json.dumps(other)]))
    return t.end()


# ── Entry ────────────────────────────────────────────────────────────

def parser_of():
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog='\n'.join(__doc__.splitlines()[1:]),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('ref', nargs='?')
    parser.add_argument('verdict', nargs='?', choices=sorted(OPENINGS))
    parser.add_argument('--review')
    parser.add_argument('--must-fix', action='append', default=[])
    return parser


def main():
    parser = parser_of()
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.verdict is None:
        parser.error('give PR-REF and VERDICT')
    try:
        prs = ticket_prs(sys.stdin)
        sys.stdout.write(comment(args.ref, args.verdict, args.review,
                                 args.must_fix, prs))
    except (json.JSONDecodeError, InputError) as error:
        print(f'review_ticket_comment: {error}', file=sys.stderr)
        return 2
    except (UsageError, ValueError) as error:
        print(f'review_ticket_comment: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
