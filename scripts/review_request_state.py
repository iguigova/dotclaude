#!/usr/bin/env python3
"""review_request_state.py — where a ticket's review request stands in Slack.

  review_request_state.py KEY
  review_request_state.py --self-test        # offline, no network

The review channel is the one ``.claude/review_channel`` names
(project_file.sh). The ticket's thread is found in Slack itself, not in a
local record. A Slack search lists the messages you sent in that channel
that name KEY. Each belongs to a thread, either as its parent or as a reply,
and the thread with the newest parent is the ticket's thread. Older ones are
listed under ``earlier``. Slack indexes a new message for search within
seconds to a minute, so a post made just before this runs can be missing.

The open PRs come from ``gh-ticket-prs.sh KEY``. A PR is ``announced`` once
any message in the thread links it.

Output is one JSON object:

  {"key", "channel",
   "thread": null | {"ts", "permalink", "last_mine": ts | null,
                     "replies": [{"ts", "utc", "user", "name", "text"}]},
   "earlier": [permalink, …],
   "prs": [<gh-ticket-prs.sh object> + {"announced"}],
   "new": [url, …],
   "rereview": [{"url", "logins": [login, …]}, …],
   "waiting": [{"url", "why"}, …],
   "next": "post" | "reply" | "none"}

- ``new``: ready, not approved, and not yet linked in the thread.
- ``rereview``: announced PRs that have a reviewer who has not approved and
  has not seen the head commit, and whose head commit is newer than your last
  message in the thread. Once you have asked, the PR leaves the list until
  it is pushed again.
- ``waiting``: PRs that are not ready, each with why: a draft, a conflict,
  failing checks or pending checks.
- ``next``: ``post`` starts a thread (no thread yet, and a PR in ``new``),
  ``reply`` writes in the thread (``new`` or ``rereview`` holds a PR), and
  ``none`` means there is nothing to ask for.

Exit 0: the state is printed. Exit 1: no key, or the project names no
review channel. Exit 2: Slack or GitHub could not be read, so nothing is
printed. It reads Slack with the project's ``.secrets/slack-token``
(slack_thread.py).
"""
import contextlib
import datetime
import io
import json
import re
import subprocess
import sys
from pathlib import Path

from tap import Tap

HERE = Path(__file__).resolve().parent
KEY = re.compile(r'^[A-Z][A-Z0-9]*-[0-9]+$')
PR_LINK = re.compile(r'https?://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)')


# ── Pure steps ───────────────────────────────────────────────────────

def linked_prs(texts):
    """Every PR url the texts link, normalised to https://github.com/o/r/pull/n."""
    return {f'https://github.com/{repo}/pull/{n}'
            for text in texts for repo, n in PR_LINK.findall(text)}


def threads_of(matches, channel, parse_link):
    """Thread parent ts of each search match in the channel, newest first."""
    seen = {parse_link(m['permalink'])[1] for m in matches
            if m.get('channel', {}).get('id') == channel}
    return sorted(seen, key=float, reverse=True)


def iso_ts(iso):
    """A GitHub ISO time as a Slack-comparable epoch float."""
    return datetime.datetime.fromisoformat(iso.replace('Z', '+00:00')).timestamp()


def why_waiting(pr):
    if pr['draft']:
        return 'draft'
    if pr['mergeable'] != 'MERGEABLE':
        return f"mergeable is {pr['mergeable']}"
    c = pr['checks']
    return f"{c['fail']} failing" if c['fail'] else f"{c['pending']} pending checks"


def reviewers_behind(pr):
    """Logins of the reviewers who have not approved and not seen the head."""
    return [r['login'] for r in pr['reviewers']
            if r['behind'] and r['state'] != 'APPROVED']


def classify(pr, announced, last_mine):
    """(list name, entry) for one PR, or None when it asks for nothing."""
    if not pr['ready']:
        return 'waiting', {'url': pr['url'], 'why': why_waiting(pr)}
    if not announced:
        return ('new', pr['url']) if pr['review'] != 'APPROVED' else None
    if not pr['pushed'] or iso_ts(pr['pushed']) <= last_mine:
        return None
    logins = reviewers_behind(pr)
    return ('rereview', {'url': pr['url'], 'logins': logins}) if logins else None


def next_step(thread, lists):
    if not thread:
        return 'post' if lists['new'] else 'none'
    return 'reply' if lists['new'] or lists['rereview'] else 'none'


def plan(prs, thread):
    """new, rereview, waiting and next from the PRs and the thread."""
    texts = [thread['parent']] + [r['text'] for r in thread['replies']] if thread else []
    announced = linked_prs(texts)
    last_mine = float(thread['last_mine'] or 0) if thread else 0.0
    lists = {'new': [], 'rereview': [], 'waiting': []}
    for pr in prs:
        pr['announced'] = pr['url'] in announced
        found = classify(pr, pr['announced'], last_mine)
        if found:
            lists[found[0]].append(found[1])
    return dict(lists, next=next_step(thread, lists))


# ── Slack and GitHub ─────────────────────────────────────────────────

def channel(here=HERE):
    found = subprocess.run([str(here / 'project_file.sh'), 'review_channel'],
                           capture_output=True, text=True)
    if found.returncode:
        sys.exit('review_request_state: the project names no .claude/review_channel')
    lines = [l.strip() for l in Path(found.stdout.strip()).read_text().splitlines()
             if l.strip() and not l.startswith('#')]
    return lines[0]


def open_prs(key, here=HERE):
    out = subprocess.run([str(here / 'gh-ticket-prs.sh'), key],
                         capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(out.stderr.strip() or 'gh-ticket-prs.sh failed')
    return [json.loads(l) for l in out.stdout.splitlines() if l.strip()]


def read_thread(st, ch, key):
    me = st.call('auth.test', {})['user_id']
    query = f'{key} from:<@{me}> in:<#{ch}>'
    matches = st.call('search.messages',
                      {'query': query, 'count': 100, 'sort': 'timestamp'})['messages']['matches']
    tss = threads_of(matches, ch, st.parse_link)
    if not tss:
        return None, []
    ts = tss[0]
    msgs = st.replies(ch, ts)
    names = {}
    def name(u):
        if u not in names:
            names[u] = st.real_name(u)
        return names[u]
    replies = [{'ts': m['ts'], 'utc': st.utc(m['ts']), 'user': m.get('user'),
                'name': name(m.get('user')), 'text': m.get('text', '')}
               for m in msgs[1:]]
    mine = [m['ts'] for m in msgs if m.get('user') == me]
    link = st.call('chat.getPermalink', {'channel': ch, 'message_ts': ts})['permalink']
    earlier = [st.call('chat.getPermalink', {'channel': ch, 'message_ts': t})['permalink']
               for t in tss[1:]]
    return ({'ts': ts, 'permalink': link, 'last_mine': mine[-1] if mine else None,
             'parent': msgs[0].get('text', ''), 'replies': replies}, earlier)


def state(key, st=None, here=HERE):
    if st is None:
        import slack_thread as st
    ch = channel(here)
    prs = open_prs(key, here)
    thread, earlier = read_thread(st, ch, key)
    result = {'key': key, 'channel': ch}
    steps = plan(prs, thread)
    if thread:
        thread = {k: v for k, v in thread.items() if k != 'parent'}
    result.update({'thread': thread, 'earlier': earlier, 'prs': prs})
    result.update(steps)
    return result


# ── Self-test ────────────────────────────────────────────────────────

def pr(n, **kw):
    base = {'url': f'https://github.com/o/r/pull/{n}', 'ready': True, 'draft': False,
            'mergeable': 'MERGEABLE', 'review': 'REVIEW_REQUIRED',
            'checks': {'pass': 1, 'fail': 0, 'pending': 0},
            'pushed': '2026-01-02T00:00:00Z', 'reviewers': []}
    base.update(kw)
    return base


def self_test():
    t = Tap()
    t.check(linked_prs(['<http://github.com/o/r/pull/7|github.com/o/r/pull/7> and '
                        'https://github.com/a/b-c/pull/12'])
            == {'https://github.com/o/r/pull/7', 'https://github.com/a/b-c/pull/12'},
            'a Slack-wrapped http link and a bare https link both name their PR')

    def parse(link):
        m = re.search(r'p(\d+)(?:\?thread_ts=([\d.]+))?$', link)
        return 'C1', m.group(2) or f'{m.group(1)[:-6]}.{m.group(1)[-6:]}'
    matches = [{'channel': {'id': 'C1'}, 'permalink': 'x/p1000000000000001'},
               {'channel': {'id': 'C1'}, 'permalink': 'x/p3000000000000003?thread_ts=2000000000.000002'},
               {'channel': {'id': 'C9'}, 'permalink': 'x/p4000000000000004'}]
    t.check(threads_of(matches, 'C1', parse) == ['2000000000.000002', '1000000000.000001'],
            "a reply counts as its parent's thread, another channel's match is left out, newest first")

    s = plan([pr(1)], None)
    t.check((s['next'], s['new']) == ('post', ['https://github.com/o/r/pull/1']),
            'with no thread a ready PR is new and the next step is a post')
    s = plan([pr(1, review='APPROVED')], None)
    t.check((s['next'], s['new']) == ('none', []), 'an approved PR is never asked for')
    s = plan([pr(1, ready=False, checks={'pass': 0, 'fail': 0, 'pending': 2})], None)
    t.check((s['next'], s['waiting']) == ('none', [{'url': 'https://github.com/o/r/pull/1',
                                                    'why': '2 pending checks'}]),
            'a PR that is not ready waits, with why')

    thread = {'parent': 'Team: https://github.com/o/r/pull/1', 'replies': [],
              'last_mine': str(iso_ts('2026-01-01T00:00:00Z'))}
    s = plan([pr(1), pr(2)], dict(thread))
    t.check((s['next'], s['new']) == ('reply', ['https://github.com/o/r/pull/2']),
            'a PR the thread has not linked is new, and the next step is a reply')
    behind = [{'login': 'a', 'state': 'CHANGES_REQUESTED', 'behind': True},
              {'login': 'b', 'state': 'APPROVED', 'behind': True},
              {'login': 'c', 'state': 'COMMENTED', 'behind': False}]
    s = plan([pr(1, reviewers=behind)], dict(thread))
    t.check((s['next'], s['rereview']) == ('reply', [{'url': 'https://github.com/o/r/pull/1',
                                                      'logins': ['a']}]),
            'a reviewer behind the head who has not approved is asked to re-review')
    asked = dict(thread, last_mine=str(iso_ts('2026-01-03T00:00:00Z')))
    s = plan([pr(1, reviewers=behind)], asked)
    t.check((s['next'], s['rereview']) == ('none', []),
            'once you have written in the thread after the push, nobody is asked again')
    s = plan([pr(1)], dict(thread))
    t.check(s['next'] == 'none', 'an announced PR with nobody behind asks for nothing')
    same = dict(thread, last_mine=str(iso_ts('2026-01-02T00:00:00Z')))
    t.check(plan([pr(1, reviewers=behind)], same)['rereview'] == [],
            'a message in the same second as the push counts as asked')
    t.check(plan([pr(1, reviewers=behind)], dict(thread, last_mine=None))['next'] == 'reply',
            'a thread with no message of yours asks a reviewer behind the head')
    t.check(plan([pr(1, reviewers=behind, pushed=None)], dict(thread))['next'] == 'none',
            'a PR with no head commit time asks nobody')
    t.check([why_waiting(pr(1, draft=True)), why_waiting(pr(1, mergeable='CONFLICTING')),
             why_waiting(pr(1, checks={'pass': 0, 'fail': 2, 'pending': 0}))]
            == ['draft', 'mergeable is CONFLICTING', '2 failing'],
            'a draft, a conflict and failing checks each say why the PR waits')
    io_tests(t)
    return t.end()


class FakeSlack:
    """slack_thread as read_thread uses it: canned answers, no network."""
    def __init__(self, permalinks, thread):
        self.permalinks, self.thread, self.queries = permalinks, thread, []

    def call(self, method, params):
        if method == 'auth.test':
            return {'user_id': 'UME'}
        if method == 'search.messages':
            self.queries.append(params['query'])
            return {'messages': {'matches': [{'channel': {'id': 'C1'}, 'permalink': p}
                                             for p in self.permalinks]}}
        return {'permalink': f'link/{params["message_ts"]}'}

    @staticmethod
    def parse_link(link):
        return 'C1', link.rsplit('/', 1)[1]

    def replies(self, ch, ts):
        return self.thread

    @staticmethod
    def real_name(user):
        return f'name-{user}'

    @staticmethod
    def utc(ts):
        return f'utc-{ts}'


def fake_dir(channel_file, prs_out, prs_rc=0):
    """A scripts dir whose project_file.sh and gh-ticket-prs.sh are canned."""
    import tempfile
    d = Path(tempfile.mkdtemp())
    (d / 'review_channel').write_text(channel_file)
    (d / 'prs.out').write_text(prs_out)
    (d / 'project_file.sh').write_text(f'#!/bin/sh\necho {d}/review_channel\n')
    (d / 'gh-ticket-prs.sh').write_text(
        f'#!/bin/sh\n[ "$1" = A-1 ] || exit 9\ncat {d}/prs.out\n'
        f'[ {prs_rc} = 0 ] || {{ echo boom >&2; exit {prs_rc}; }}\n')
    for f in ('project_file.sh', 'gh-ticket-prs.sh'):
        (d / f).chmod(0o755)
    return d


def io_tests(t):
    global state
    d = fake_dir('# the channel\n\nC1\n', json.dumps(pr(1)) + '\n\n')
    t.check(channel(d) == 'C1', 'the channel is the first line that is not a comment or blank')
    t.check(open_prs('A-1', d) == [pr(1)], 'each line gh-ticket-prs.sh prints is one PR')
    try:
        open_prs('A-1', fake_dir('C1', '', prs_rc=2))
        failed = None
    except RuntimeError as error:
        failed = str(error)
    t.check(failed == 'boom', "a failed PR read raises with gh-ticket-prs.sh's own message", f'got {failed!r}')

    slack = FakeSlack([], [])
    t.check(read_thread(slack, 'C1', 'A-1') == (None, []), 'no message naming the key is no thread')
    t.check(slack.queries == ['A-1 from:<@UME> in:<#C1>'],
            'the search asks for your messages in the channel that name the key', f'{slack.queries}')
    msgs = [{'ts': '2.0', 'user': 'UME', 'text': 'Team https://github.com/o/r/pull/1'},
            {'ts': '2.5', 'user': 'U2', 'text': 'looks good'},
            {'ts': '3.0', 'user': 'UME', 'text': 'thanks'},
            {'ts': '4.0', 'user': 'U2', 'text': 'done'}]
    thread, earlier = read_thread(FakeSlack(['x/1.0', 'x/2.0'], msgs), 'C1', 'A-1')
    t.check((thread['ts'], thread['permalink'], thread['last_mine'], earlier)
            == ('2.0', 'link/2.0', '3.0', ['link/1.0']),
            'the newest thread is read, your last message in it is found, older threads are earlier')
    t.check(thread['replies'][0] == {'ts': '2.5', 'utc': 'utc-2.5', 'user': 'U2',
                                     'name': 'name-U2', 'text': 'looks good'},
            'each reply carries its author, name and time')

    out = state('A-1', FakeSlack(['x/2.0'], msgs), fake_dir('C1', json.dumps(pr(1)) + '\n'))
    t.check(('parent' not in out['thread'], out['prs'][0]['announced'], out['next'])
            == (True, True, 'none'),
            'the state hides the parent text and marks a PR the thread linked as announced')

    real = state
    try:
        state = lambda key: (_ for _ in ()).throw(RuntimeError('down'))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            codes = [main(a) for a in (['-h'], [], ['abc-1'], ['A-1', 'B-2'], ['A-1'])]
            state = lambda key: {'key': key}
            codes.append(main(['A-1']))
    finally:
        state = real
    t.check(codes == [0, 1, 1, 1, 2, 0],
            'help is 0, a missing, lower-case or second key is 1, a failed read is 2', f'{codes}')
    t.check(out.getvalue().endswith('{\n "key": "A-1"\n}\n'), 'the state is printed as JSON',
            out.getvalue()[-80:])
    t.check('review_request_state: down' in err.getvalue(), 'a failed read names its error',
            err.getvalue())


def main(argv):
    if argv == ['--self-test']:
        return self_test()
    if argv and argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    if len(argv) != 1 or not KEY.match(argv[0]):
        print('usage: review_request_state.py KEY | --self-test', file=sys.stderr)
        return 1
    try:
        print(json.dumps(state(argv[0]), indent=1))
    except Exception as error:  # a Slack or GitHub read failed: nothing is whole
        print(f'review_request_state: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
