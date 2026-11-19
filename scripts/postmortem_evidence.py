#!/usr/bin/env python3
"""postmortem_evidence.py — gather a ticket's post-mortem evidence into files.

A post-mortem is written from the ticket's own record: its description,
every comment, and the dates it changed status, owner and priority. Jira
returns those as one large payload stamped in the author's local offset,
which is too large for the MCP reader and has to be converted to UTC by
hand. This writes them as readable Markdown with every time in UTC.

Writes into ``--out`` (default ``./postmortem-<KEY>``):

* ``<KEY>.md`` — fields, description, attachments, linked issues, every
  comment, the field history, all in UTC, and every issue key the text mentions
  resolved to its current key. A moved issue still answers to its old key,
  so two keys in the text can be one issue; the resolution says so.
* ``<LINKED>.md`` — the same for each directly linked issue, one hop only
* ``attachments/<id>-<filename>`` — every file attached to ``<KEY>``, as
  uploaded. A reporter's log or export is evidence to match against our
  own data; a linked issue's attachments are listed, not downloaded
* ``siblings.md`` — the reports already under the project's post-mortem
  parent page, newest first; the newest one's body is ``latest-sibling.storage.html``,
  an example of a finished report. The structure comes from the skill's
  template, not from this file
* ``slack.md`` — every Slack thread the issues' text links, each read by
  ``slack_thread.py`` into ``slack/<channel>-<ts>/``
  (``thread.md`` and its ``files/``), or the reason it could not be read.
  Two links into one thread read it once. The thread is often where the
  customer's report and the screenshots are; the ticket only points at it

Comments and history are paginated in full.

The project names its tracker and its parent page, each a value read by
``project_file.sh --value``: ``atlassian_site`` and ``postmortem_parent``.
The credentials are its ``jira-email`` and ``jira-token`` secrets
(``secret_file.sh``), and the Slack reader is resolved by name
(``project_file.sh --script``). A project without one of them stops the run
before any call, exit 1, naming it.

  postmortem_evidence.py XYZ-7669
  postmortem_evidence.py XYZ-7669 --out /tmp/pm --no-linked
  postmortem_evidence.py --self-test         # offline, no network
"""
import argparse
import base64
import contextlib
import functools
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

RESOLVERS = os.path.expanduser('~/.claude/scripts')
PAGE_SIZE = 100
TIMEOUT = 30
HISTORY_FIELDS = ('status', 'assignee', 'priority', 'summary',
                  'resolution', 'Link', 'Fix Version', 'labels')
ISSUE_KEY = re.compile(r'\b[A-Z][A-Z0-9]+-\d+\b')
SLACK_LINK = re.compile(
    r'https://[a-z0-9-]+\.slack\.com/archives/[A-Z0-9]+/p\d+'
    r'(?:\?[^\s|\]\)]*)?')


def resolved(command):
    """What a resolver prints; its refusal ends the run, exit 1, naming
    what the project lacks."""
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(result.stderr.strip()
                 or f'postmortem_evidence: {" ".join(command)} exited {result.returncode}')
    return result.stdout.strip()


@functools.cache
def value(name):
    return resolved([os.path.join(RESOLVERS, 'project_file.sh'), '--value', name])


@functools.cache
def script(name):
    return resolved([os.path.join(RESOLVERS, 'project_file.sh'), '--script', name])


@functools.cache
def secret(name):
    with open(resolved([os.path.join(RESOLVERS, 'secret_file.sh'), name])) as handle:
        return handle.read().strip()


def site():
    return value('atlassian_site')


def utc(stamp):
    """A Jira or Confluence timestamp, as 'YYYY-MM-DD HH:MM UTC'."""
    if not stamp:
        return ''
    parsed = datetime.strptime(stamp.replace('Z', '+0000'),
                               '%Y-%m-%dT%H:%M:%S.%f%z')
    return parsed.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')


def name(person):
    return (person or {}).get('displayName', 'unassigned')


def history_lines(histories):
    """One line per changed field worth a timeline, oldest first."""
    lines = [(h['created'], name(h.get('author')), item)
             for h in histories for item in h.get('items', [])
             if item.get('field') in HISTORY_FIELDS]
    lines.sort(key=lambda line: utc(line[0]))
    return [f"- {utc(at)} — {who} — {item['field']}: "
            f"{item.get('fromString')} → {item.get('toString')}"
            for at, who, item in lines]


def link_lines(links):
    def one(link):
        other = link.get('outwardIssue') or link.get('inwardIssue') or {}
        verb = (link['type']['outward'] if 'outwardIssue' in link
                else link['type']['inward'])
        fields = other.get('fields', {})
        return (f"- {verb} {other.get('key')} "
                f"[{fields.get('status', {}).get('name')}] "
                f"{fields.get('summary')}")
    return [one(link) for link in links]


def comment_blocks(comments):
    return [f"### {name(c.get('author'))} — {utc(c['created'])}\n\n"
            f"{c.get('body', '')}\n" for c in comments]


def mentioned_keys(issue, comments):
    """Issue keys the description and comments name, other than its own."""
    text = ' '.join([issue['fields'].get('description') or '']
                    + [c.get('body', '') for c in comments])
    return sorted(set(ISSUE_KEY.findall(text)) - {issue['key']})


def slack_links(issue, comments):
    """Slack message links the description and comments carry, in order."""
    text = ' '.join([issue['fields'].get('description') or '']
                    + [c.get('body', '') for c in comments])
    return list(dict.fromkeys(SLACK_LINK.findall(text)))


def slack_threads(links, parse_link):
    """Each thread once, as (folder, link, issue keys), in first-seen order.
    ``links`` is (issue key, link) pairs; a reply link names its thread."""
    threads = {}
    for key, link in links:
        channel, ts = parse_link(link)
        folder = f'{channel}-{ts}'
        _, _, keys = threads.setdefault(folder, (folder, link, []))
        if key not in keys:
            keys.append(key)
    return list(threads.values())


def slack_lines(results):
    """``results`` is (folder, link, keys, error or None) per thread."""
    return [f"- {link} (from {', '.join(keys)}) → "
            + (f'not read: {error}' if error
               else f'slack/{folder}/thread.md')
            for folder, link, keys, error in results]


def resolution_lines(resolved):
    """``resolved`` maps a mentioned key to its current key, or None when
    it names no issue (UTF-8 matches the key pattern too)."""
    return [f'- {key} → {now} (moved)' if now != key else f'- {key}'
            for key, now in sorted(resolved.items()) if now]


def listed(lines):
    """Lines as one block, or 'none' when there are none."""
    return '\n'.join(lines) or 'none'


def dossier_header(issue):
    f = issue['fields']
    return [
        f"# {issue['key']}: {f.get('summary')}",
        '',
        f"- type: {f.get('issuetype', {}).get('name')}",
        f"- status: {f.get('status', {}).get('name')}",
        f"- priority: {(f.get('priority') or {}).get('name')}",
        f"- created: {utc(f.get('created'))}",
        f"- resolved: {utc(f.get('resolutiondate')) or 'unresolved'}",
        f"- reporter: {name(f.get('reporter'))}",
        f"- assignee: {name(f.get('assignee'))}",
        f"- labels: {', '.join(f.get('labels') or []) or 'none'}",
        f"- url: {site()}/browse/{issue['key']}",
    ]


def dossier(issue, comments, histories, resolved):
    """The Markdown evidence file for one issue."""
    f = issue['fields']
    sections = [
        '\n'.join(dossier_header(issue)),
        '## Description\n\n' + (f.get('description') or '(empty)'),
        '## Attachments\n\n' + listed(attachment_lines(f.get('attachment') or [])),
        '## Linked issues\n\n' + listed(link_lines(f.get('issuelinks') or [])),
        '## Issues mentioned in the text\n\n' + listed(resolution_lines(resolved)),
        '## Comments\n\n' + listed(comment_blocks(comments)),
        '## History (UTC)\n\n' + listed(history_lines(histories)),
    ]
    return '\n\n'.join(sections) + '\n'


def attachment_lines(attachments):
    """One line per attached file, oldest first."""
    return [f"- {attachment_name(a)} — {name(a.get('author'))}, "
            f"{utc(a['created'])}, {a['size']} bytes"
            for a in sorted(attachments, key=lambda a: utc(a['created']))]


def attachment_name(attachment):
    """The saved file's name: the id keeps two uploads of one name apart,
    and the basename keeps a crafted name inside the folder."""
    return f"{attachment['id']}-{os.path.basename(attachment['filename'])}"


def sibling_lines(pages):
    """Existing reports, newest first."""
    ordered = sorted(pages, key=lambda p: p['history']['createdDate'],
                     reverse=True)
    return [f"- {utc(p['history']['createdDate'])} — {p['title']} — "
            f"{site()}/wiki/pages/viewpage.action?pageId={p['id']}"
            for p in ordered], ordered


def auth_header():
    raw = base64.b64encode(
        f"{secret('jira-email')}:{secret('jira-token')}".encode()).decode()
    return {'Authorization': f'Basic {raw}', 'Accept': 'application/json'}


def get(path, **params):
    query = f'?{urllib.parse.urlencode(params)}' if params else ''
    request = urllib.request.Request(f'{site()}{path}{query}',
                                     headers=auth_header())
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)


def paged(path, key):
    """Every element of a startAt/maxResults collection."""
    items, start = [], 0
    while True:
        page = get(path, startAt=start, maxResults=PAGE_SIZE)
        items += page.get(key, [])
        start += len(page.get(key, []))
        if not page.get(key) or start >= page.get('total', 0):
            return items


def fetch_issue(key):
    issue = get(f'/rest/api/2/issue/{key}', fields='*all')
    comments = paged(f'/rest/api/2/issue/{key}/comment', 'comments')
    histories = paged(f'/rest/api/2/issue/{key}/changelog', 'values')
    return issue, comments, histories


def current_key(key):
    try:
        return get(f'/rest/api/2/issue/{key}', fields='key')['key']
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def linked_keys(issue):
    return [(link.get('outwardIssue') or link.get('inwardIssue'))['key']
            for link in issue['fields'].get('issuelinks') or []]


def download(out, attachment):
    folder = os.path.join(out, 'attachments')
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, attachment_name(attachment))
    request = urllib.request.Request(attachment['content'],
                                     headers=auth_header())
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response, \
            open(path, 'wb') as handle:
        handle.write(response.read())
    print(path)


def write(out, filename, text):
    path = os.path.join(out, filename)
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)
    print(path)


def gather_issue(out, key):
    issue, comments, histories = fetch_issue(key)
    resolved = {k: current_key(k) for k in mentioned_keys(issue, comments)}
    write(out, f"{issue['key']}.md",
          dossier(issue, comments, histories, resolved))
    return issue, [(issue['key'], link)
                   for link in slack_links(issue, comments)]


def slack_reader():
    """The global Slack thread reader, loaded as a module.

    Its imports, such as tap, are siblings in its own directory.
    """
    path = script('slack_thread.py')
    here = os.path.dirname(path)
    if here not in sys.path:
        sys.path.insert(0, here)
    spec = importlib.util.spec_from_file_location('slack_thread', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def gather_slack(out, links):
    """Read each linked thread; one that cannot be read is listed, not
    fatal, since the token reaches only channels its user is in."""
    reader = slack_reader()
    results = []
    for folder, link, keys in slack_threads(links, reader.parse_link):
        try:
            reader.read(link, os.path.join(out, 'slack', folder))
            error = None
        except (reader.SlackError, urllib.error.URLError, OSError) as e:
            error = str(e)
        results.append((folder, link, keys, error))
    write(out, 'slack.md', '# Slack threads the issues link\n\n'
          + ('\n'.join(slack_lines(results)) or 'none') + '\n')


def gather_siblings(out):
    pages = get(f"/wiki/rest/api/content/{value('postmortem_parent')}/child/page",
                expand='history', limit=PAGE_SIZE)['results']
    lines, ordered = sibling_lines(pages)
    write(out, 'siblings.md',
          '# Reports under the post-mortem parent page\n\n'
          + ('\n'.join(lines) or 'none') + '\n')
    if ordered:
        page = get(f"/wiki/rest/api/content/{ordered[0]['id']}",
                   expand='body.storage')
        write(out, 'latest-sibling.storage.html',
              page['body']['storage']['value'])


def gather(key, out, linked):
    for need in (site, lambda: value('postmortem_parent'), auth_header,
                 lambda: script('slack_thread.py')):
        need()
    os.makedirs(out, exist_ok=True)
    issue, links = gather_issue(out, key)
    for attachment in issue['fields'].get('attachment') or []:
        download(out, attachment)
    if linked:
        for other in linked_keys(issue):
            links += gather_issue(out, other)[1]
    gather_slack(out, links)
    gather_siblings(out)
    return 0


FAKE_READER = """import os, re, urllib.parse
class SlackError(Exception):
    pass
def parse_link(link):
    m = re.search(r'/archives/([A-Z0-9]+)/p(\\d+)(\\d{6})', link)
    query = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
    return m[1], query.get('thread_ts', [f'{m[2]}.{m[3]}'])[0]
def read(link, out):
    if '/C2/' in link:
        raise SlackError('not_in_channel')
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'thread.md'), 'w') as handle:
        handle.write(link)
"""


def self_test_project(root):
    """A project holding the values, the secrets and a fake Slack reader;
    the run moves into it."""
    claude = os.path.join(root, 'p', '.claude')
    os.makedirs(os.path.join(claude, 'scripts'))
    os.makedirs(os.path.join(root, 'p', '.secrets'))
    os.makedirs(os.path.join(root, 'bare', '.claude'))
    for path, text in ((('.claude', 'atlassian_site'), 'https://site.example\n'),
                       (('.claude', 'postmortem_parent'), '# reports\n77001\n'),
                       (('.claude', 'session_history.md'), '# history\n'),
                       (('.claude', 'scripts', 'slack_thread.py'), FAKE_READER),
                       (('.secrets', 'jira-email'), 'me@example.com\n'),
                       (('.secrets', 'jira-token'), 'tok\n')):
        with open(os.path.join(root, 'p', *path), 'w') as handle:
            handle.write(text)
    os.chdir(os.path.join(root, 'p'))


def self_test_http(routes):
    """urlopen over a dict of URL to JSON, bytes or an HTTP status; it
    records each request's URL and headers in its ``seen``."""
    def urlopen(request, timeout=None):
        url = request.full_url
        urlopen.seen.append((url, dict(request.header_items())))
        answer = routes[url]
        if isinstance(answer, int):
            raise urllib.error.HTTPError(url, answer, 'no', {}, None)
        return io.BytesIO(answer if isinstance(answer, bytes)
                          else json.dumps(answer).encode())
    urlopen.seen, urlopen.routes = [], routes
    return urlopen


def self_test_issue(key, link_to=None, attach=False, text=''):
    links = ([{'type': {'inward': 'relates to', 'outward': 'relates to'},
               'outwardIssue': {'key': link_to, 'fields': {
                   'summary': 'L', 'status': {'name': 'Done'}}}}]
             if link_to else [])
    files = ([{'id': n, 'filename': 'log.txt', 'size': 3,
               'content': f'https://site.example/att/{n}',
               'author': {'displayName': 'K'},
               'created': '2026-08-04T10:00:00.000+0000'} for n in ('7', '8')]
             if attach else [])
    return {'key': key, 'fields': {'summary': key, 'description': text,
                                   'issuelinks': links, 'attachment': files}}


def self_test_routes():
    api = 'https://site.example/rest/api/2/issue'
    wiki = 'https://site.example/wiki/rest/api/content'
    slack = 'https://w.slack.com/archives'
    routes = {
        f'{api}/XYZ-1?fields=%2Aall': self_test_issue(
            'XYZ-1', 'XYZ-2', True,
            f'see XYZ-9 and {slack}/C1/p1792703410430689 and {slack}/C2/p1792703410430690'),
        f'{api}/XYZ-2?fields=%2Aall': self_test_issue('XYZ-2'),
        f'{api}/XYZ-9?fields=key': {'key': 'XYZ-9'},
        f'{api}/XYZ-1?fields=key': {'key': 'XYZ-1'},
        'https://site.example/att/7': b'log',
        'https://site.example/att/8': b'log 2',
        f'{wiki}/77001/child/page?expand=history&limit=100': {'results': [
            {'id': '5', 'title': 'old', 'history': {'createdDate': '2026-08-01T10:00:00.000Z'}},
            {'id': '6', 'title': 'new', 'history': {'createdDate': '2026-09-01T10:00:00.000Z'}}]},
        f'{wiki}/6?expand=body.storage': {'body': {'storage': {'value': '<p>newest</p>'}}},
    }
    for key in ('XYZ-1', 'XYZ-2'):
        routes[f'{api}/{key}/comment?startAt=0&maxResults=100'] = {
            'comments': [{'author': {'displayName': 'A'}, 'created': '2026-09-02T10:00:00.000+0000',
                          'body': f'{key} c1'}], 'total': 2}
        routes[f'{api}/{key}/comment?startAt=1&maxResults=100'] = {
            'comments': [{'author': {'displayName': 'A'}, 'created': '2026-09-03T10:00:00.000+0000',
                          'body': f'{key} c2'}], 'total': 2}
        routes[f'{api}/{key}/changelog?startAt=0&maxResults=100'] = {'values': []}
    return routes


def self_test_calls(t, root):
    """The steps that call out, over a fake Jira, Confluence and Slack."""
    def check(label, was, want):
        t.check(was == want, label, f'got {was!r}', f'want {want!r}')
    http = self_test_http(self_test_routes())
    real, urllib.request.urlopen = urllib.request.urlopen, http
    out = os.path.join(root, 'out')
    try:
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            gather('XYZ-1', out, True)
        check('the auth header is the project credentials',
              http.seen[0][1].get('Authorization'),
              'Basic ' + base64.b64encode(b'me@example.com:tok').decode())
        check('every request asks for JSON', {h.get('Accept') for _, h in http.seen}, {'application/json'})
        with open(os.path.join(out, 'XYZ-1.md')) as handle:
            dossier_text = handle.read()
        check('comments are read across pages',
              ('XYZ-1 c1' in dossier_text, 'XYZ-1 c2' in dossier_text), (True, True))
        check('a mentioned key is resolved', '- XYZ-9\n' in dossier_text, True)
        check('a linked issue gets its own file', os.path.exists(os.path.join(out, 'XYZ-2.md')), True)
        with open(os.path.join(out, 'attachments', '7-log.txt'), 'rb') as handle:
            check('an attachment is saved as uploaded', handle.read(), b'log')
        with open(os.path.join(out, 'attachments', '8-log.txt'), 'rb') as handle:
            check('a second attachment joins the first', handle.read(), b'log 2')
        check('an issue with no labels, history or description says so',
              ('- labels: none' in dossier_text, '## History (UTC)\n\nnone' in dossier_text,
               '## Description\n\n(empty)' in self_test_dossier_of(out, 'XYZ-2')), (True, True, True))
        with open(os.path.join(out, 'slack.md')) as handle:
            slack_text = handle.read()
        check('a readable thread is read',
              'C1-1792703410.430689/thread.md' in slack_text, True)
        check('an unreadable thread is listed with its reason', 'not read: not_in_channel' in slack_text, True)
        with open(os.path.join(out, 'siblings.md')) as handle:
            check('siblings are listed newest first, under the parent',
                  handle.read().splitlines()[2].startswith('- 2026-09-01 10:00 UTC — new'), True)
        with open(os.path.join(out, 'latest-sibling.storage.html')) as handle:
            check('the newest sibling\'s body is saved', handle.read(), '<p>newest</p>')
        check('each file written is printed', os.path.join(out, 'XYZ-1.md') in printed.getvalue(), True)
        lone = os.path.join(root, 'lone')
        os.makedirs(lone)
        with contextlib.redirect_stdout(io.StringIO()):
            gather('XYZ-1', lone, False)
        check('--no-linked writes no linked issue', os.path.exists(os.path.join(lone, 'XYZ-2.md')), False)
        http.routes['https://site.example/rest/api/2/issue/GONE-1?fields=key'] = 404
        http.routes['https://site.example/rest/api/2/issue/ERR-1?fields=key'] = 500
        check('a key Jira does not hold resolves to none', current_key('GONE-1'), None)
        try:
            current_key('ERR-1')
            check('any other HTTP error is raised', None, 500)
        except urllib.error.HTTPError as error:
            check('any other HTTP error is raised', error.code, 500)
        http.routes['https://site.example/x?startAt=0&maxResults=100'] = {'v': [1]}
        check('a page with no total ends the collection', paged('/x', 'v'), [1])
        http.routes['https://site.example/y?startAt=0&maxResults=100'] = {'v': [], 'total': 5}
        check('an empty page ends the collection', paged('/y', 'v'), [])
        http.routes['https://site.example/z'] = {'ok': 1}
        check('a call with no parameters has no query', get('/z'), {'ok': 1})
        argv, sys.argv = sys.argv, ['postmortem_evidence.py', 'XYZ-1']
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                main()
        finally:
            sys.argv = argv
        check('the default folder is postmortem-<KEY>, with the linked issues',
              os.path.exists(os.path.join('postmortem-XYZ-1', 'XYZ-2.md')), True)
        check('a silent resolver refusal names the command and its status',
              self_test_exit(resolved, ['sh', '-c', 'exit 3']),
              'postmortem_evidence: sh -c exit 3 exited 3')
        check('a link with no issue on either side renders, not fails',
              link_lines([{'type': {'inward': 'is hit by', 'outward': 'hits'}}]),
              ['- is hit by None [None] None'])
    finally:
        urllib.request.urlopen = real


def self_test_dossier_of(out, key):
    with open(os.path.join(out, f'{key}.md')) as handle:
        return handle.read()


def self_test_exit(call, *args):
    """The message call exits with, or None when it returns."""
    try:
        call(*args)
    except SystemExit as stop:
        return str(stop.code)
    return None


def self_test_missing(t, root):
    """A project without the values stops the run before any call."""
    run = subprocess.run([sys.executable, os.path.abspath(__file__), 'XYZ-1', '--out',
                          os.path.join(root, 'none')],
                         cwd=os.path.join(root, 'bare'), capture_output=True, text=True,
                         env={**os.environ, 'HTTPS_PROXY': 'http://127.0.0.1:9'})
    t.check(run.returncode == 1, 'a project without the values stops the run, exit 1',
            f'got {run.returncode}')
    t.check('atlassian_site' in run.stderr, 'and names the value it lacks', run.stderr.strip())
    t.check(not os.path.exists(os.path.join(root, 'none')), 'and writes nothing')
    usage = subprocess.run([sys.executable, os.path.abspath(__file__)], capture_output=True, text=True)
    t.check(usage.returncode == 2, 'no key is a usage error', f'got {usage.returncode}')


def self_test():
    """Every conversion over a hand-built issue, and every call over fakes,
    in a fixture project."""
    sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
    from tap import Tap
    t = Tap()
    here = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        self_test_project(tmp)
        try:
            self_test_pure(t)
            self_test_calls(t, tmp)
            self_test_missing(t, tmp)
        finally:
            os.chdir(here)
    return t.end()


def self_test_pure(t):
    """Render a hand-built issue and check every conversion it needs."""
    issue = {'key': 'XYZ-1', 'fields': {
        'summary': 'Thing broke', 'issuetype': {'name': 'Bug'},
        'status': {'name': 'Done'}, 'priority': {'name': 'P2'},
        'created': '2026-08-04T15:57:19.995+0100',
        'resolutiondate': None, 'reporter': {'displayName': 'R'},
        'assignee': None, 'labels': ['client:X'],
        'description': 'h2. Mechanism',
        'attachment': [
            {'id': '9', 'filename': '../log.xlsx', 'size': 10,
             'author': {'displayName': 'K'},
             'created': '2026-08-05T10:00:00.000+0000'},
            {'id': '8', 'filename': 'log.xlsx', 'size': 20,
             'author': {'displayName': 'K'},
             'created': '2026-08-04T10:00:00.000+0000'}],
        'issuelinks': [{'type': {'inward': 'relates to',
                                 'outward': 'relates to'},
                        'outwardIssue': {'key': 'WC-2', 'fields': {
                            'summary': 'Incident',
                            'status': {'name': 'Done'}}}}]}}
    comments = [{'author': {'displayName': 'A'},
                 'created': '2026-09-02T22:18:02.470+0100',
                 'body': 'measured'}]
    histories = [
        {'created': '2026-09-04T19:47:00.000+0100',
         'author': {'displayName': 'B'},
         'items': [{'field': 'status', 'fromString': 'Review',
                    'toString': 'Testing'},
                   {'field': 'description', 'fromString': 'x',
                    'toString': 'y'}]},
        {'created': '2026-08-06T19:09:45.586+0100',
         'author': {'displayName': 'C'},
         'items': [{'field': 'assignee', 'fromString': 'C',
                    'toString': None}]},
    ]
    issue['fields']['description'] += ' see WC-2, WC-9 and UTF-8; XYZ-1'
    parent = 'https://w.slack.com/archives/C1/p1792703410430689'
    reply = ('https://w.slack.com/archives/C1/p1792761492970659'
             '?thread_ts=1792703410.430689&cid=C1')
    comments.append({'author': {'displayName': 'A'},
                     'created': '2026-09-03T10:00:00.000+0100',
                     'body': f'[thread|{parent}] and {reply} and {parent}'})
    links = slack_links(issue, comments)
    threads = slack_threads([('XYZ-1', link) for link in links]
                            + [('WC-2', parent)], slack_reader().parse_link)
    resolved = {'WC-2': 'WC-2', 'WC-9': 'XYZ-5', 'UTF-8': None}
    text = dossier(issue, comments, histories, resolved)
    siblings, ordered = sibling_lines([
        {'id': '1', 'title': 'old',
         'history': {'createdDate': '2026-08-01T10:00:00.000Z'}},
        {'id': '2', 'title': 'new',
         'history': {'createdDate': '2026-09-01T10:00:00.000Z'}}])

    checks = {
        'offset converted to UTC': (
            utc('2026-08-04T15:57:19.995+0100'), '2026-08-04 14:57 UTC'),
        'Z suffix accepted': (
            utc('2026-09-01T10:00:00.000Z'), '2026-09-01 10:00 UTC'),
        'history oldest first, untracked fields dropped': (
            history_lines(histories),
            ['- 2026-08-06 18:09 UTC — C — assignee: C → None',
             '- 2026-09-04 18:47 UTC — B — status: Review → Testing']),
        'comment time in UTC': ('A — 2026-09-02 21:18 UTC' in text, True),
        'link rendered': ('- relates to WC-2 [Done] Incident' in text, True),
        'attachments oldest first, path stripped, ids keep names apart': (
            attachment_lines(issue['fields']['attachment']),
            ['- 8-log.xlsx — K, 2026-08-04 10:00 UTC, 20 bytes',
             '- 9-log.xlsx — K, 2026-08-05 10:00 UTC, 10 bytes']),
        'attachments rendered': ('## Attachments\n\n- 8-log.xlsx' in text,
                                 True),
        'unresolved stated': ('- resolved: unresolved' in text, True),
        'unassigned stated': ('- assignee: unassigned' in text, True),
        'siblings newest first': ([p['id'] for p in ordered], ['2', '1']),
        'sibling line': (siblings[0].startswith('- 2026-09-01 10:00 UTC — new'),
                         True),
        'linked keys': (linked_keys(issue), ['WC-2']),
        'mentioned keys exclude its own': (
            mentioned_keys(issue, comments), ['UTF-8', 'WC-2', 'WC-9']),
        'moved key flagged, non-issue dropped': (
            resolution_lines(resolved), ['- WC-2', '- WC-9 → XYZ-5 (moved)']),
        'Slack links found once each, wiki-link markup stripped': (
            links, [parent, reply]),
        'a reply link and its parent are one thread, from both issues': (
            threads, [('C1-1792703410.430689', parent, ['XYZ-1', 'WC-2'])]),
        'a thread read or not read is listed with its reason': (
            slack_lines([('C1-1.2', parent, ['XYZ-1'], None),
                         ('C2-3.4', reply, ['WC-2'], 'not_in_channel')]),
            [f'- {parent} (from XYZ-1) → slack/C1-1.2/thread.md',
             f'- {reply} (from WC-2) → not read: not_in_channel']),
    }
    for label, (was, want) in checks.items():
        t.check(was == want, label, f'got {was!r}', f'want {want!r}')


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('key', nargs='?')
    parser.add_argument('--out')
    parser.add_argument('--no-linked', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.key:
        parser.error('an issue key is required')
    return gather(args.key, args.out or f'postmortem-{args.key}',
                  not args.no_linked)


if __name__ == '__main__':
    sys.exit(main())
