#!/usr/bin/env python3
"""review_request_state.py — a ticket's review request: its one Slack thread and its PRs.

  review_request_state.py KEY
  review_request_state.py send KEY FILE --expect post|reply
  review_request_state.py pr-thread PR-URL
  review_request_state.py --self-test        # offline, no network

A ticket has one review thread, in the channel ``.claude/review_channel``
names (project_file.sh). The ticket records it: a web link on the Jira issue
with the global id ``slack-review-thread`` (jira-remote-link.sh). A ticket
with no such link is searched for in Slack: your messages in the channel that
name KEY and start their thread. A reply naming KEY inside another thread,
such as a standup, is not one. The newest of those threads is used, and
``recorded`` is false until ``send`` records it.

The open PRs come from ``gh-ticket-prs.sh KEY``. A PR is ``announced`` once
any message in the thread links it.

KEY prints one JSON object:

  {"key", "ticket_url", "channel",
   "thread": null | {"ts", "permalink", "recorded", "last_mine": ts | null,
                     "replies": [{"ts", "utc", "user", "name", "text"}]},
   "earlier": [permalink, …],
   "prs": [<gh-ticket-prs.sh object> + {"announced"}],
   "new": [url, …],
   "rereview": [{"url", "reviewers": [{"login", "name", "slack"}]}, …],
   "waiting": [{"url", "why"}, …],
   "next": "post" | "reply" | "none"}

- ``ticket_url``: the ticket's page on the site ``.claude/atlassian_site``
  names, for the message to link the key to.
- ``earlier``: other threads of yours in the channel that name KEY, the
  duplicates a ticket had before it recorded its thread.
- ``new``: ready, not approved, and not yet linked in the thread.
- ``rereview``: announced PRs with a reviewer who has not approved and
  reviewed another commit than the head, pushed after your last message in
  the thread. Once you have written in the thread after the push, the PR
  leaves the list until it is pushed again. ``slack`` is the ``<@U…>`` tag of
  the one Slack member whose name is the reviewer's GitHub profile name,
  ignoring case; null when no member or several match.
- ``waiting``: PRs that are not ready, each with why.
- ``next``: ``post`` starts the thread, ``reply`` writes in it, ``none`` means
  there is nothing to ask for.

``send`` reads the state again and posts FILE with slack_post.py only when
``next`` is still the one the approved text was written for (``--expect``),
as a new message for ``post`` or in the thread for ``reply``, a reply
also sent to the channel so the request shows there too. It then
records the thread on the ticket when the ticket has no record yet, and
prints {"permalink", "thread"}.

``pr-thread`` is the reviewer's side: the threads in the channel where anyone
linked PR-URL, so a review's outcome can be told where the review was asked
for. A request often names no ticket, so the PR is what is searched. It
prints {"pr", "channel", "thread", "earlier"}: ``thread`` is the one whose
latest message linking the PR is newest, with ``parent`` (the first
message's text) beside ``ts``, ``permalink``, ``last_mine`` and ``replies``;
null when no message links it. ``earlier`` holds the other threads, newest
first, each as {"ts", "permalink"}. A thread is read, never written: the reply goes
through slack_post.py to the thread the user approves.

Exit 0: done. Exit 1: a usage error, or the project names no review channel.
Exit 2: Slack, GitHub or Jira could not be read or written. Exit 4: ``send``
found ``next`` changed, and posted nothing. It reads Slack with the
project's ``.secrets/slack-token`` (slack_thread.py).
"""
import argparse
import contextlib
import datetime
import io
import json
import re
import subprocess
import sys
from pathlib import Path

from tap import Tap, scratch

HERE = Path(__file__).resolve().parent
KEY = re.compile(r'^[A-Z][A-Z0-9]*-[0-9]+$')
PR_LINK = re.compile(r'https?://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)')
GLOBAL_ID = 'slack-review-thread'


class Changed(Exception):
    """send found next changed since the text was approved."""


# ── Pure steps ───────────────────────────────────────────────────────

def linked_prs(texts):
    """Every PR url the texts link, normalised to https://github.com/o/r/pull/n."""
    return {f'https://github.com/{repo}/pull/{n}'
            for text in texts for repo, n in PR_LINK.findall(text)}


def threads_of(matches, channel, parse_link):
    """Ts of each search match in the channel that starts its thread, newest first.

    A reply naming the key sits in a thread about something else, such as a
    standup; only a message whose permalink's parent is itself starts one.
    """
    roots = {m['ts'] for m in matches
             if m.get('channel', {}).get('id') == channel
             and parse_link(m['permalink'])[1] == m['ts']}
    return sorted(roots, key=float, reverse=True)


def threads_linking(matches, channel, url, parse_link):
    """Ts of each thread in the channel holding a message that links url.

    Ordered by each thread's latest such message, newest first; a reply
    counts for the thread it sits in.
    """
    latest = {}
    for m in matches:
        if m.get('channel', {}).get('id') != channel or url not in linked_prs([m.get('text', '')]):
            continue
        root = parse_link(m['permalink'])[1]
        latest[root] = max(latest.get(root, 0.0), float(m['ts']))
    return sorted(latest, key=latest.get, reverse=True)


def pr_url(text):
    """text as https://github.com/o/r/pull/n when it is one PR link, else None."""
    found = linked_prs([text])
    return found.pop() if len(found) == 1 and PR_LINK.fullmatch(text.rstrip('/')) else None


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


def slack_tag(name, members):
    """<@U…> of the one live member whose real name is name, ignoring case."""
    if not name:
        return None
    hits = [m['id'] for m in members
            if not m.get('deleted') and not m.get('is_bot')
            and (m.get('real_name') or m.get('profile', {}).get('real_name') or '').lower()
            == name.lower()]
    return f'<@{hits[0]}>' if len(hits) == 1 else None


def bare(permalink):
    """A permalink without its query string."""
    return permalink.split('?', 1)[0]


# ── Slack, GitHub and Jira ───────────────────────────────────────────

class World:
    """Every read and write outside this process, so a test can stand in."""

    def __init__(self, st=None, here=HERE, gh=None):
        if st is None:
            import slack_thread as st
        self.st, self.here, self.gh = st, here, gh or 'gh'

    def run(self, *cmd):
        return subprocess.run([str(c) for c in cmd], capture_output=True, text=True)

    def project_line(self, name):
        """The first line of the project's .claude/<name> that is not blank or a comment."""
        found = self.run(self.here / 'project_file.sh', name)
        if found.returncode:
            sys.exit(f'review_request_state: the project names no .claude/{name}')
        lines = [l.strip() for l in Path(found.stdout.strip()).read_text().splitlines()
                 if l.strip() and not l.startswith('#')]
        return lines[0]

    def channel(self):
        return self.project_line('review_channel')

    def ticket_url(self, key):
        return f"{self.project_line('atlassian_site').rstrip('/')}/browse/{key}"

    def open_prs(self, key):
        out = self.run(self.here / 'gh-ticket-prs.sh', key)
        if out.returncode:
            raise RuntimeError(out.stderr.strip() or 'gh-ticket-prs.sh failed')
        return [json.loads(l) for l in out.stdout.splitlines() if l.strip()]

    def recorded(self, key):
        """The thread permalink the ticket records, or None."""
        out = self.run(self.here / 'jira-remote-link.sh', 'get', key, GLOBAL_ID)
        if out.returncode == 3:
            return None
        if out.returncode:
            raise RuntimeError(out.stderr.strip() or 'jira-remote-link.sh get failed')
        return out.stdout.strip()

    def record(self, key, permalink):
        out = self.run(self.here / 'jira-remote-link.sh', 'set', key, GLOBAL_ID,
                       permalink, 'Review thread in Slack')
        if out.returncode:
            raise RuntimeError(out.stderr.strip() or 'jira-remote-link.sh set failed')

    def github_name(self, login):
        out = self.run(self.gh, 'api', f'users/{login}', '--jq', '.name // ""')
        if out.returncode:
            raise RuntimeError(out.stderr.strip() or f'gh could not read {login}')
        return out.stdout.strip()

    def members(self):
        found, cursor = [], None
        while True:
            params = {'limit': 200}
            if cursor:
                params['cursor'] = cursor
            body = self.st.call('users.list', params)
            found += body['members']
            cursor = body.get('response_metadata', {}).get('next_cursor')
            if not cursor:
                return found

    def post(self, ch, path, thread_ts):
        cmd = [self.here / 'slack_post.py', 'post', ch, path]
        if thread_ts:
            cmd += ['--thread', thread_ts, '--broadcast']
        out = self.run(*cmd)
        if out.returncode:
            raise RuntimeError(out.stderr.strip() or out.stdout.strip() or 'slack_post.py failed')
        return out.stdout.strip().splitlines()[-1]


def search(world, query):
    return world.st.call('search.messages',
                         {'query': query, 'count': 100, 'sort': 'timestamp'})['messages']['matches']


def search_threads(world, ch, key, me):
    return threads_of(search(world, f'{key} from:<@{me}> in:<#{ch}>'), ch, world.st.parse_link)


def read_thread(world, ch, key):
    """(thread or None, earlier permalinks): the recorded thread, else the newest found."""
    st = world.st
    me = st.call('auth.test', {})['user_id']
    found = search_threads(world, ch, key, me)
    link = world.recorded(key)
    ts = st.parse_link(link)[1] if link else (found[0] if found else None)
    permalink = lambda t: bare(st.call('chat.getPermalink',
                                       {'channel': ch, 'message_ts': t})['permalink'])
    earlier = [permalink(t) for t in found if t != ts]
    if not ts:
        return None, earlier
    return dict(thread_messages(st, ch, ts, me), ts=ts, permalink=link or permalink(ts),
                recorded=bool(link)), earlier


def thread_messages(st, ch, ts, me):
    """The parent's text, each reply under its author, and your last message's ts."""
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
    return {'last_mine': mine[-1] if mine else None,
            'parent': msgs[0].get('text', ''), 'replies': replies}


def tag_reviewers(world, rereview):
    """Each re-review login with its GitHub name and Slack tag."""
    if not rereview:
        return []
    members = world.members()
    names = {}
    for item in rereview:
        for login in item['logins']:
            if login not in names:
                names[login] = world.github_name(login)
    return [{'url': item['url'],
             'reviewers': [{'login': l, 'name': names[l], 'slack': slack_tag(names[l], members)}
                           for l in item['logins']]}
            for item in rereview]


def state(key, world=None):
    world = world or World()
    ch = world.channel()
    prs = world.open_prs(key)
    thread, earlier = read_thread(world, ch, key)
    steps = plan(prs, thread)
    steps['rereview'] = tag_reviewers(world, steps['rereview'])
    if thread:
        thread = {k: v for k, v in thread.items() if k != 'parent'}
    return dict({'key': key, 'ticket_url': world.ticket_url(key), 'channel': ch,
                 'thread': thread, 'earlier': earlier, 'prs': prs}, **steps)


def send(key, path, expect, world=None):
    world = world or World()
    now = state(key, world)
    if now['next'] != expect:
        raise Changed(f"next is {now['next']}, not {expect}: new {now['new']}, "
                      f"rereview {[r['url'] for r in now['rereview']]}, waiting {now['waiting']}")
    thread = now['thread']
    permalink = world.post(now['channel'], path, thread['ts'] if thread else None)
    parent = bare(permalink) if expect == 'post' else thread['permalink']
    if expect == 'post' or not thread['recorded']:
        world.record(key, parent)
    return {'permalink': permalink, 'thread': parent}


def pr_thread(url, world=None):
    """The threads in the review channel where anyone linked the PR, newest first."""
    world = world or World()
    st, ch = world.st, world.channel()
    roots = threads_linking(search(world, f'"{url.split("://", 1)[1]}" in:<#{ch}>'), ch, url, st.parse_link)
    permalink = lambda t: bare(st.call('chat.getPermalink', {'channel': ch, 'message_ts': t})['permalink'])
    thread = None
    if roots:
        me = st.call('auth.test', {})['user_id']
        thread = dict(thread_messages(st, ch, roots[0], me), ts=roots[0], permalink=permalink(roots[0]))
    return {'pr': url, 'channel': ch, 'thread': thread,
            'earlier': [{'ts': t, 'permalink': permalink(t)} for t in roots[1:]]}


# ── Self-test ────────────────────────────────────────────────────────

def pr(n, **kw):
    base = {'url': f'https://github.com/o/r/pull/{n}', 'ready': True, 'draft': False,
            'mergeable': 'MERGEABLE', 'review': 'REVIEW_REQUIRED',
            'checks': {'pass': 1, 'fail': 0, 'pending': 0},
            'pushed': '2026-01-02T00:00:00Z', 'reviewers': []}
    base.update(kw)
    return base


class FakeSlack:
    """slack_thread as read_thread uses it: canned answers, no network."""

    def __init__(self, permalinks, thread, members=(), texts=None):
        self.permalinks, self.thread, self.queries = permalinks, thread, []
        self.texts = texts or {}
        self.pages = [list(members[:1]), list(members[1:])] if members else [[]]

    def call(self, method, params):
        if method == 'auth.test':
            return {'user_id': 'UME'}
        if method == 'search.messages':
            self.queries.append(params['query'])
            return {'messages': {'matches': [{'channel': {'id': 'C1'}, 'permalink': p,
                                              'ts': self.parse_link(p)[1], 'text': self.texts.get(p, '')}
                                             for p in self.permalinks]}}
        if method == 'users.list':
            page = int(params.get('cursor', 0))
            more = page + 1 < len(self.pages)
            return {'members': self.pages[page],
                    'response_metadata': {'next_cursor': str(page + 1) if more else ''}}
        return {'permalink': f'link/{params["message_ts"]}?thread_ts=x'}

    @staticmethod
    def parse_link(link):
        return 'C1', link.rsplit('/', 1)[1].split('?')[0]

    def replies(self, ch, ts):
        return self.thread

    @staticmethod
    def real_name(user):
        return f'name-{user}'

    @staticmethod
    def utc(ts):
        return f'utc-{ts}'


def fake_dir(prs_out='', prs_rc=0, recorded=None, link_rc=None, post_rc=0, set_rc=0):
    """A scripts dir whose helpers are canned shell scripts that log their arguments."""
    import tempfile
    d = Path(tempfile.mkdtemp())
    (d / 'review_channel').write_text('# the channel\n\nC1\n')
    (d / 'atlassian_site').write_text('https://jira.invalid/\n')
    (d / 'prs.out').write_text(prs_out)
    get_rc = link_rc if link_rc is not None else (0 if recorded else 3)
    scripts = {
        'project_file.sh': f'echo {d}/$1',
        'gh-ticket-prs.sh': f'[ "$1" = A-1 ] || exit 9\ncat {d}/prs.out\n'
                            f'[ {prs_rc} = 0 ] || {{ echo boom >&2; exit {prs_rc}; }}',
        'jira-remote-link.sh': f'echo "$@" >> {d}/jira.log\n'
                               f'if [ "$1" = get ]; then echo {recorded or ""}; '
                               f'[ {get_rc} = 1 ] && echo jira down >&2; exit {get_rc}; fi\n'
                               f'[ {set_rc} = 0 ] || {{ echo refused >&2; exit 1; }}',
        'slack_post.py': f'echo "$@" >> {d}/post.log\n'
                         f'[ {post_rc} = 0 ] || {{ echo not posted; exit 1; }}\n'
                         'echo ok\necho https://s/archives/C1/p9000000000000009',
        'gh': 'case "$2" in users/a) echo "Ann Lee" ;; users/z) exit 1 ;; *) echo "" ;; esac',
    }
    for name, body in scripts.items():
        (d / name).write_text(f'#!/bin/sh\n{body}\n')
        (d / name).chmod(0o755)
    return d


def log(d, name):
    p = d / name
    return p.read_text().splitlines() if p.exists() else []


def pure_tests(t):
    t.check(linked_prs(['<http://github.com/o/r/pull/7|github.com/o/r/pull/7> and '
                        'https://github.com/a/b-c/pull/12'])
            == {'https://github.com/o/r/pull/7', 'https://github.com/a/b-c/pull/12'},
            'a Slack-wrapped http link and a bare https link both name their PR')

    def parse(link):
        m = re.search(r'p(\d+)(?:\?thread_ts=([\d.]+))?$', link)
        return 'C1', m.group(2) or f'{m.group(1)[:-6]}.{m.group(1)[-6:]}'
    matches = [{'channel': {'id': 'C1'}, 'ts': '1000000000.000001',
                'permalink': 'x/p1000000000000001'},
               {'channel': {'id': 'C1'}, 'ts': '2000000000.000002',
                'permalink': 'x/p2000000000000002?thread_ts=2000000000.000002'},
               {'channel': {'id': 'C1'}, 'ts': '3000000000.000003',
                'permalink': 'x/p3000000000000003?thread_ts=2500000000.000025'},
               {'channel': {'id': 'C9'}, 'ts': '4000000000.000004',
                'permalink': 'x/p4000000000000004'}]
    t.check(threads_of(matches, 'C1', parse) == ['2000000000.000002', '1000000000.000001'],
            "a message starting its thread counts, with or without replies, newest first")
    t.check('2500000000.000025' not in threads_of(matches, 'C1', parse),
            "a reply naming the key leaves the thread it sits in out")
    t.check('4000000000.000004' not in threads_of(matches, 'C1', parse),
            "another channel's match is left out")

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
    t.check(plan([pr(1, reviewers=behind)], asked)['next'] == 'none',
            'once you have written in the thread after the push, nobody is asked again')
    t.check(plan([pr(1)], dict(thread))['next'] == 'none',
            'an announced PR with nobody behind asks for nothing')
    same = dict(thread, last_mine=str(iso_ts('2026-01-02T00:00:00Z')))
    t.check(plan([pr(1, reviewers=behind)], same)['rereview'] == [],
            'a message in the same second as the push counts as asked')
    t.check(plan([pr(1, reviewers=behind)], dict(thread, last_mine=None))['next'] == 'reply',
            'a thread with no message of yours asks a reviewer behind the head')
    t.check(plan([pr(1, reviewers=behind, pushed=None)], dict(thread))['next'] == 'none',
            'a PR with no push time asks nobody')
    t.check([why_waiting(pr(1, draft=True)), why_waiting(pr(1, mergeable='CONFLICTING')),
             why_waiting(pr(1, checks={'pass': 0, 'fail': 2, 'pending': 0}))]
            == ['draft', 'mergeable is CONFLICTING', '2 failing'],
            'a draft, a conflict and failing checks each say why the PR waits')

    members = [{'id': 'U1', 'real_name': 'Ann Lee'},
               {'id': 'U2', 'profile': {'real_name': 'Bo Ray'}},
               {'id': 'U3', 'real_name': 'Cy Dee'}, {'id': 'U4', 'real_name': 'cy dee'},
               {'id': 'U5', 'real_name': 'Old Hand', 'deleted': True},
               {'id': 'U6', 'real_name': 'Bot Thing', 'is_bot': True}]
    t.check([slack_tag(n, members) for n in ('ann LEE', 'Bo Ray', 'Cy Dee', 'Old Hand',
                                             'Bot Thing', 'Nobody', '')]
            == ['<@U1>', '<@U2>', None, None, None, None, None],
            'a name tags its one live person, ignoring case; two matches, none, a deleted member or a bot tag nobody')
    t.check(bare('https://s/archives/C1/p1?thread_ts=1.0&cid=C1') == 'https://s/archives/C1/p1',
            'a permalink loses its query string')


def thread_tests(t):
    d = fake_dir(json.dumps(pr(1)) + '\n\n')
    w = World(FakeSlack([], []), d, gh=d / 'gh')
    t.check(w.channel() == 'C1', 'the channel is the first line that is not a comment or blank')
    t.check(w.open_prs('A-1') == [pr(1)], 'each line gh-ticket-prs.sh prints is one PR')
    failures = []
    for call in (lambda: World(FakeSlack([], []), fake_dir(prs_rc=2)).open_prs('A-1'),
                 lambda: World(FakeSlack([], []), fake_dir(link_rc=1)).recorded('A-1'),
                 lambda: World(FakeSlack([], []), fake_dir(set_rc=1)).record('A-1', 'u'),
                 lambda: World(FakeSlack([], []), fake_dir(post_rc=1)).post('C1', 'f', None),
                 lambda: w.github_name('z')):
        try:
            call()
            failures.append(None)
        except RuntimeError as error:
            failures.append(str(error))
    t.check(failures == ['boom', 'jira down', 'refused', 'not posted', 'gh could not read z'],
            'a failed read or write raises with what the helper said, on stderr or else stdout',
            f'{failures}')

    slack = FakeSlack([], [])
    t.check(read_thread(World(slack, d), 'C1', 'A-1') == (None, []),
            'no record and no message naming the key is no thread')
    t.check(slack.queries == ['A-1 from:<@UME> in:<#C1>'],
            'the search asks for your messages in the channel that name the key', f'{slack.queries}')
    msgs = [{'ts': '2.0', 'user': 'UME', 'text': 'Team https://github.com/o/r/pull/1'},
            {'ts': '2.5', 'user': 'U2', 'text': 'looks good'},
            {'ts': '3.0', 'user': 'UME', 'text': 'thanks'},
            {'ts': '4.0', 'user': 'U2', 'text': 'done'}]
    thread, earlier = read_thread(World(FakeSlack(['x/1.0', 'x/2.0'], msgs), d), 'C1', 'A-1')
    t.check((thread['ts'], thread['permalink'], thread['recorded'], thread['last_mine'], earlier)
            == ('2.0', 'link/2.0', False, '3.0', ['link/1.0']),
            'with no record the newest thread found is read, your last message found, older ones earlier')
    t.check(thread['replies'][0] == {'ts': '2.5', 'utc': 'utc-2.5', 'user': 'U2',
                                     'name': 'name-U2', 'text': 'looks good'},
            'each reply carries its author, name and time')
    rec = fake_dir(recorded='x/1.0')
    thread, earlier = read_thread(World(FakeSlack(['x/1.0', 'x/2.0'], msgs), rec), 'C1', 'A-1')
    t.check((thread['ts'], thread['permalink'], thread['recorded'], earlier)
            == ('1.0', 'x/1.0', True, ['link/2.0']),
            'the recorded thread wins over a newer one found, which is listed as earlier')
    t.check(log(rec, 'jira.log') == [f'get A-1 {GLOBAL_ID}'], 'the record is read by its global id')
    only = read_thread(World(FakeSlack(['x/1.0'], [{'ts': '1.0', 'user': 'U2'}]), fake_dir()),
                       'C1', 'A-1')[0]
    t.check((only['ts'], only['last_mine'], only['parent'], only['replies']) == ('1.0', None, '', []),
            'a thread none of whose messages is yours has no last message of yours')


def state_tests(t):
    behind = [{'login': 'a', 'state': 'COMMENTED', 'behind': True},
              {'login': 'q', 'state': 'CHANGES_REQUESTED', 'behind': True}]
    msgs = [{'ts': '2.0', 'user': 'UME', 'text': 'Team https://github.com/o/r/pull/1'}]
    d = fake_dir(json.dumps(pr(1, reviewers=behind)) + '\n', recorded='x/2.0')
    members = [{'id': 'U7', 'real_name': 'Zed'}, {'id': 'U1', 'real_name': 'Ann Lee'}]
    out = state('A-1', World(FakeSlack(['x/2.0'], msgs, members), d, gh=d / 'gh'))
    t.check(('parent' not in out['thread'], out['prs'][0]['announced'], out['next'])
            == (True, True, 'reply'),
            'the state hides the parent text, marks a linked PR announced, and asks for the re-review')
    t.check(out['rereview'] == [{'url': 'https://github.com/o/r/pull/1', 'reviewers': [
        {'login': 'a', 'name': 'Ann Lee', 'slack': '<@U1>'},
        {'login': 'q', 'name': '', 'slack': None}]}],
        'a reviewer is tagged through a member on any page whose name is theirs; one with no GitHub name is not',
        json.dumps(out['rereview']))
    out = state('A-1', World(FakeSlack([], []), fake_dir(json.dumps(pr(1)) + '\n'), gh=d / 'gh'))
    t.check((out['thread'], out['next']) == (None, 'post'), 'with no thread the state says post')
    t.check(out['ticket_url'] == 'https://jira.invalid/browse/A-1',
            "the ticket's link is the project's Atlassian site's browse page for the key",
            out['ticket_url'])

    d = fake_dir(json.dumps(pr(1)) + '\n')
    sent = send('A-1', 'f.md', 'post', World(FakeSlack([], []), d))
    t.check(sent == {'permalink': 'https://s/archives/C1/p9000000000000009',
                     'thread': 'https://s/archives/C1/p9000000000000009'},
            'a post prints its permalink, which is the thread')
    t.check((log(d, 'post.log'), log(d, 'jira.log')[-1])
            == (['post C1 f.md'], f'set A-1 {GLOBAL_ID} https://s/archives/C1/p9000000000000009 '
                                  'Review thread in Slack'),
            'a post goes to the channel, and the new thread is recorded on the ticket')

    d = fake_dir(json.dumps(pr(1)) + '\n' + json.dumps(pr(2)) + '\n', recorded='x/2.0')
    sent = send('A-1', 'f.md', 'reply', World(FakeSlack(['x/2.0'], msgs), d))
    t.check((log(d, 'post.log'), sent['thread'], len(log(d, 'jira.log')))
            == (['post C1 f.md --thread 2.0 --broadcast'], 'x/2.0', 1),
            'a reply goes in the recorded thread and to the channel, and a recorded thread is not recorded again')
    d = fake_dir(json.dumps(pr(1)) + '\n' + json.dumps(pr(2)) + '\n')
    send('A-1', 'f.md', 'reply', World(FakeSlack(['x/2.0'], msgs), d))
    t.check(log(d, 'jira.log')[-1] == f'set A-1 {GLOBAL_ID} link/2.0 Review thread in Slack',
            'a reply in a thread found only by search records that thread')
    d = fake_dir(json.dumps(pr(1)) + '\n')
    try:
        send('A-1', 'f.md', 'reply', World(FakeSlack([], []), d))
        changed = None
    except Changed as error:
        changed = str(error)
    t.check(str(changed).startswith('next is post, not reply'), 'a changed next says what it is now',
            f'{changed}')
    t.check(log(d, 'post.log') == [], 'a changed next posts nothing')


def reviewer_tests(t):
    url = 'https://github.com/o/r/pull/1'

    def parse(link):
        m = re.search(r'/([\d.]+)(?:\?thread_ts=([\d.]+))?$', link)
        return 'C1', m.group(2) or m.group(1)
    match = lambda ts, text, root=None, ch='C1': {
        'channel': {'id': ch}, 'ts': ts, 'text': text,
        'permalink': f'x/{ts}' + (f'?thread_ts={root}' if root else '')}
    matches = [match('9.0', f'<{url}|x>', root='1.0'), match('8.0', url), match('7.0', f'{url}0'),
               match('6.0', url, ch='C9'), match('5.0', f'{url} again', root='1.0'), match('4.0', url)]
    t.check(threads_linking(matches, 'C1', url, parse) == ['1.0', '8.0', '4.0'],
            "threads are ordered by their newest message linking the PR, a reply counting for its thread;"
            " another PR's link and another channel are left out")
    t.check([pr_url(u) for u in (url, f'{url}/', 'http://github.com/o/r/pull/1',
                                 f'{url}/files', 'ABC-1', f'{url} {url}0')]
            == [url, url, url, None, None, None],
            'a PR link alone is read as its https url; a longer path, a key or two links are not')

    msgs = [{'ts': '1.0', 'user': 'U2', 'text': f'ready for review {url}'},
            {'ts': '1.5', 'user': 'UME', 'text': 'left comments'}]
    slack = FakeSlack(['x/2.0', 'x/1.0'], msgs, texts={'x/2.0': f'{url}0', 'x/1.0': f'<{url}>'})
    out = pr_thread(url, World(slack, fake_dir()))
    t.check(slack.queries == ['"github.com/o/r/pull/1" in:<#C1>'],
            "the search asks for anyone's messages in the channel quoting the PR's link", f'{slack.queries}')
    t.check((out['pr'], out['channel'], out['thread']['ts'], out['thread']['permalink'], out['earlier'])
            == (url, 'C1', '1.0', 'link/1.0', []),
            'the thread linking the PR is read, one linking another PR left out')
    t.check((out['thread']['parent'], out['thread']['last_mine'], out['thread']['replies'][0]['text'])
            == (f'ready for review {url}', '1.5', 'left comments'),
            "the reviewer sees the request's text, their own last message and each reply")
    two = FakeSlack(['x/3.0', 'x/1.0'], msgs, texts={'x/3.0': url, 'x/1.0': url})
    out = pr_thread(url, World(two, fake_dir()))
    t.check((out['thread']['ts'], out['earlier']) == ('3.0', [{'ts': '1.0', 'permalink': 'link/1.0'}]),
            'with two threads the newest is read and the other listed as earlier')
    out = pr_thread(url, World(FakeSlack([], []), fake_dir()))
    t.check((out['thread'], out['earlier']) == (None, []), 'a PR nobody linked has no thread')


def main_tests(t):
    global state, send, pr_thread
    real = state, send, pr_thread
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            state = lambda key: (_ for _ in ()).throw(RuntimeError('down'))
            codes = [main(a) for a in (['-h'], [], ['abc-1'], ['A-1', 'B-2'], ['A-1'],
                                       ['send', 'A-1', 'f'], ['send', 'A-1', 'f', '--expect', 'none'])]
            state = lambda key: {'key': key}
            codes.append(main(['A-1']))
            send = lambda key, path, expect: (_ for _ in ()).throw(Changed('next is none'))
            codes.append(main(['send', 'A-1', 'f', '--expect', 'post']))
            send = lambda key, path, expect: {'permalink': f'{key} {path} {expect}'}
            codes.append(main(['send', 'A-1', 'f', '--expect', 'reply']))
            pr_thread = lambda url: {'thread-of': url}
            codes += [main(['pr-thread', 'http://github.com/o/r/pull/3/']), main(['pr-thread', 'A-1']),
                      main(['pr-thread'])]
    finally:
        state, send, pr_thread = real
    t.check(codes == [0, 1, 1, 1, 2, 1, 1, 0, 4, 0, 0, 1, 1],
            'help is 0, a bad key, send without --expect or pr-thread without a PR link is 1,'
            ' a failed read 2, a changed next 4', f'{codes}')
    t.check('"thread-of": "https://github.com/o/r/pull/3"' in out.getvalue(),
            "pr-thread prints the threads of the PR's https url", out.getvalue()[-200:])
    t.check('{\n "key": "A-1"\n}' in out.getvalue(), 'the state is printed as JSON', out.getvalue()[-200:])
    t.check('"permalink": "A-1 f reply"' in out.getvalue(), 'send prints what it posted', out.getvalue()[-200:])
    t.check('review_request_state: down' in err.getvalue(), 'a failed read names its error', err.getvalue())
    t.check('review_request_state: next is none' in err.getvalue(), 'a changed next says so', err.getvalue())


def self_test():
    t = Tap()
    pure_tests(t)
    thread_tests(t)
    state_tests(t)
    reviewer_tests(t)
    main_tests(t)
    return t.end()


def parse(argv):
    if argv and argv[0] == 'send':
        p = argparse.ArgumentParser(prog='review_request_state.py send')
        p.add_argument('key')
        p.add_argument('file')
        p.add_argument('--expect', required=True, choices=['post', 'reply'])
        args = p.parse_args(argv[1:])
        args.cmd = 'send'
    elif argv and argv[0] == 'pr-thread':
        url = pr_url(argv[1]) if len(argv) == 2 else None
        if not url:
            raise SystemExit(1)
        return argparse.Namespace(cmd='pr-thread', url=url)
    else:
        if len(argv) != 1:
            raise SystemExit(1)
        args = argparse.Namespace(cmd='state', key=argv[0])
    if not KEY.match(args.key):
        raise SystemExit(1)
    return args


def run(args):
    """The command's result; each is looked up at call time, so a test can stand in."""
    if args.cmd == 'send':
        return send(args.key, args.file, args.expect)
    if args.cmd == 'pr-thread':
        return pr_thread(args.url)
    return state(args.key)


def main(argv):
    if argv == ['--self-test']:
        with scratch():
            return self_test()
    if argv and argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    try:
        args = parse(argv)
    except SystemExit:
        print('usage: review_request_state.py KEY | send KEY FILE --expect post|reply'
              ' | pr-thread PR-URL | --self-test', file=sys.stderr)
        return 1
    try:
        result = run(args)
    except Changed as error:
        print(f'review_request_state: {error}', file=sys.stderr)
        return 4
    except Exception as error:  # a Slack, GitHub or Jira call failed: nothing is whole
        print(f'review_request_state: {error}', file=sys.stderr)
        return 2
    print(json.dumps(result, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
