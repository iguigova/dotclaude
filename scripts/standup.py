#!/usr/bin/env python3
"""standup.py — gather and post the async standup update.

The update is a reply in the standup thread in the user's self-DM. It
covers the work since the previous update, which is the newest message
in that thread by the token's own user: a reply, or the thread's parent
before the first reply.

  standup.py gather           # evidence since the previous update
  standup.py post FILE        # post FILE's Markdown as the reply
  standup.py post FILE --dry-run
  standup.py edit FILE TS     # replace the posted reply TS with FILE
  standup.py --self-test      # offline, no network

``gather`` prints Markdown on stdout: the previous update verbatim, the
session-history entries written since it, the current Jira status and
summary and issue URL of every issue key those entries name that Jira
holds, in any project, and the user's own Slack messages outside the thread since it. Session history stamps
UTC, and so does everything this prints.

``post`` and ``edit`` send through ``slack_post.py``, which renders the
Markdown as Slack rich text, reads the message back and prints its
permalink. ``post`` then names the session ``standup <posted time>``
through ``session_rename.sh``, so ``claude --resume`` lists the run by the
update it posted. ``--dry-run`` prints the payload, posts nothing and
names nothing.

``edit`` is how a posted update is corrected: it replaces the reply at
``TS`` in place, so the thread keeps one update.

The project names its standup thread and its tracker, each a value read by
``project_file.sh --value``: ``standup_channel`` (the channel or DM id),
``standup_thread`` (the thread's parent ts) and ``atlassian_site``.
``gather`` reads with the project's ``slack-token`` secret
(``secret_file.sh``) and the project's ``session_history.md``. Every script
it runs is resolved by name (``project_file.sh --script``). A value,
secret or script the project lacks stops the run before any call, exit 1,
naming it.
"""
import contextlib
import argparse
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from resolve import project_path, script, secret_path, value

SLACK_API = 'https://slack.com/api'
TIMEOUT = 30
SNIPPET = 500

ENTRY_HEAD = re.compile(r'^## (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) ')
# Any project's key shape. It also matches UTF-8 or ISO-8601; Jira answers
# a key it does not hold with nothing, so the search drops those.
ISSUE_KEY = re.compile(r'\b[A-Z][A-Z0-9]+-\d+\b')
BOOKKEEPING = re.compile(
    r'^\*\*(Session|Billed|Suggested commit|Committed)\b')


# ── The project ──────────────────────────────────────────────────

def history_file():
    return Path(project_path('session_history.md'))


def token_file():
    return Path(secret_path('slack-token'))


def channel():
    return value('standup_channel')


def thread_ts():
    return value('standup_thread')


# ── Slack ────────────────────────────────────────────────────────────

class SlackError(Exception):
    """Slack answered ok: false."""


def answer(request, method):
    """The body of a Slack response, or SlackError when it is not ok."""
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        body = json.load(response)
    if not body.get('ok'):
        raise SlackError(f'{method}: {body.get("error")}')
    return body


def bearer(token_file):
    return {'Authorization': f'Bearer {token_file.read_text().strip()}'}


def slack_get(method, params):
    """A read method, with the read token and a query string."""
    url = f'{SLACK_API}/{method}?{urllib.parse.urlencode(params)}'
    request = urllib.request.Request(url, headers=bearer(token_file()))
    return answer(request, method)


def own_user():
    return slack_get('auth.test', {})['user_id']


def thread_replies():
    params = {'channel': channel(), 'ts': thread_ts(), 'limit': 1000}
    return slack_get('conversations.replies', params)['messages']


def latest_own(messages, user):
    """The newest message by user, or None when there is none."""
    own = [m for m in messages if m.get('user') == user]
    return max(own, key=lambda m: float(m['ts']), default=None)


def own_messages_since(user, since):
    """The user's own messages after since, as written() keeps them."""
    day = (since - timedelta(days=1)).strftime('%Y-%m-%d')
    params = {'query': f'from:<@{user}> after:{day}', 'count': 100,
              'sort': 'timestamp', 'sort_dir': 'asc'}
    matches = slack_get('search.messages', params)['messages']['matches']
    return [m for m in matches if written(m, user, since)]


def written(match, user, since):
    """Said by hand after since: not in the thread, not a note to self."""
    in_thread = thread_ts().replace('.', '') in match.get('permalink', '')
    to_self = match.get('channel', {}).get('name') == user
    return stamp(match['ts']) > since and not in_thread and not to_self


def stamp(ts):
    return datetime.fromtimestamp(float(ts), timezone.utc)


# ── Session history ──────────────────────────────────────────────────

def entries(text):
    """The history split into (UTC time, entry text) pairs."""
    blocks = re.split(r'(?m)^(?=## \d{4}-)', text)
    return [(entry_time(b), b.strip()) for b in blocks
            if ENTRY_HEAD.match(b)]


def entry_time(block):
    head = ENTRY_HEAD.match(block).group(1)
    return datetime.strptime(head, '%Y-%m-%d %H:%M').replace(
        tzinfo=timezone.utc)


def entries_since(text, since):
    """The entries stamped after since, minus billing bookkeeping."""
    return [strip_bookkeeping(body) for when, body in entries(text)
            if when > since]


def strip_bookkeeping(body):
    lines = body.splitlines()
    return '\n'.join(ln for ln in lines if not BOOKKEEPING.match(ln))


def issue_keys(texts):
    """Every key-shaped word the texts name, sorted and unique."""
    found = {k for t in texts for k in ISSUE_KEY.findall(t)}
    return sorted(found, key=lambda k: (k.split('-')[0],
                                        int(k.split('-')[1])))


# ── Jira ─────────────────────────────────────────────────────────────

def jira_issues(keys):
    """Status and summary of each key, by the search helper."""
    if not keys:
        return []
    out = subprocess.run(
        [script('jira-search.sh'), jql_of(keys), '--max', '100'],
        capture_output=True, check=True).stdout
    return json.loads(out)


def jql_of(keys):
    """The search for keys, each quoted so AND-1 is a value, not a keyword."""
    return 'key in ({})'.format(','.join(f'"{k}"' for k in keys))


# ── Report ───────────────────────────────────────────────────────────

def report(previous, history, issues, messages):
    """The gathered evidence as one Markdown document."""
    return '\n\n'.join([
        '# Previous update',
        f'Posted {when(previous["ts"])}\n\n{previous["text"]}',
        '# Session history since then',
        '\n\n'.join(history) or '(none)',
        '# Tickets named, as Jira has them now',
        '\n'.join(issue_line(i) for i in issues) or '(none)',
        '# Your Slack messages since then, outside the thread',
        '\n\n'.join(message_block(m) for m in messages) or '(none)',
    ]) + '\n'


def when(ts):
    return stamp(ts).strftime('%Y-%m-%d %H:%M UTC')


def issue_line(issue):
    return (f'- {issue["key"]} | {issue["status"]} | {issue["summary"]}'
            f' | {value("atlassian_site")}/browse/{issue["key"]}')


def message_block(match):
    channel = match.get('channel', {}).get('name', '?')
    text = match.get('text', '')[:SNIPPET]
    return (f'- {when(match["ts"])} #{channel} {match["permalink"]}\n'
            f'  {text}')


def gather():
    for need in (channel, thread_ts, lambda: value('atlassian_site'),
                 history_file, token_file, lambda: script('jira-search.sh')):
        need()
    user = own_user()
    previous = latest_own(thread_replies(), user)
    if previous is None:
        sys.exit('standup: no earlier update of yours in the thread')
    since = stamp(previous['ts'])
    history = entries_since(history_file().read_text(), since)
    issues = jira_issues(issue_keys(history))
    messages = own_messages_since(user, since)
    sys.stdout.write(report(previous, history, issues, messages))
    return 0


# ── Post ─────────────────────────────────────────────────────────────

def post_command(path, dry_run):
    """The writer call for a reply in the standup thread."""
    return ([script('slack_post.py'), 'post', channel(), str(path),
             '--thread', thread_ts()]
            + (['--dry-run'] if dry_run else []))


def edit_command(path, ts, dry_run):
    """The writer call that replaces the reply at ``ts`` whole."""
    return ([script('slack_post.py'), 'edit', channel(), ts, str(path)]
            + (['--dry-run'] if dry_run else []))


def ts_of(link):
    """The message ts a Slack permalink names, or None."""
    found = re.search(r'/p(\d+)(\d{6})(?:\?|$)', link)
    return f'{found[1]}.{found[2]}' if found else None


def session_title(ts):
    """The session title for the update posted at Slack ``ts``."""
    return f'standup {when(ts)}'


def name_session(ts):
    """Write the session's title record. The update is already posted,
    so a failure here warns and leaves the exit status alone."""
    rename = script('session_rename.sh')
    result = subprocess.run([rename, session_title(ts)],
                            capture_output=True, text=True)
    out = result.stdout if result.returncode == 0 else result.stderr
    stream = sys.stdout if result.returncode == 0 else sys.stderr
    print(out.strip() or f'standup: {rename} exited '
          f'{result.returncode}', file=stream)


def write(command):
    """Run the writer, pass its output through, return it and its code."""
    result = subprocess.run(command, capture_output=True, text=True)
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    return result.stdout, result.returncode


def post(path, dry_run):
    out, code = write(post_command(path, dry_run))
    ts = None if dry_run else ts_of(out.strip().splitlines()[0] if out.strip() else '')
    if ts:
        name_session(ts)
    return code


def edit(path, ts, dry_run):
    return write(edit_command(path, ts, dry_run))[1]


# ── Self-test ────────────────────────────────────────────────────────

HISTORY_FIXTURE = """# Session history

## 2026-09-25 16:00 [aaaa] — XYZ-1 before the update

- not reported

## 2026-09-28 10:25 [bbbb] — XYZ-10764 scope agreed

- fixed UTF-8 handling for ABC-1273, DEF-369 and XYZ-7702
**Session:** abc
**Billed:** XYZ-10764 worklog 1

## 2026-09-28 11:00 [cccc] — chore: notes

- nothing billable
"""


# The project's own scripts override the global ones of the same name, so
# the fixture's fakes stand in for Jira, Slack and the session title.
FAKES = {
    'jira-search.sh': '[ -n "$FAKE_FAIL" ] && exit 1\n'
                      'echo \'[{"key": "XYZ-1", "status": "Done", "summary": "S"}]\'\n',
    'slack_post.py': 'for f in "$@"; do :; done\n'
                     '[ "$1" = post ] && f=$3 || f=$4\n'
                     '[ -s "$f" ] || exit 1\n'
                     '[ "$1" = post ] && echo https://x/archives/D1/p1791480100356959'
                     ' || echo "edited $3"\n',
    'session_rename.sh': '[ -n "$FAKE_FAIL" ] && exit 3\necho "titled $1"\n',
}


def captured(call, *args):
    """What call printed to stdout and stderr, and what it returned."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        got = call(*args)
    return out.getvalue(), err.getvalue(), got


def exits(call, *args):
    """The message call exits with, or None when it returns."""
    try:
        call(*args)
    except SystemExit as stop:
        return str(stop.code)
    return None


def raises(call, *args):
    try:
        call(*args)
    except Exception as error:  # noqa: BLE001 — the type is the answer
        return type(error).__name__
    return None


def run_main(*args):
    """standup.py's exit status and stdout, run in the fixture project."""
    run = subprocess.run([sys.executable, str(Path(__file__).resolve()), *args],
                         capture_output=True, text=True)
    return run.returncode, run.stdout


def self_test_calls(t, root):
    """The steps that call out, over the fixture project's fakes."""
    def check(name, want, got):
        return t.check(got == want, name, f'got {got!r}', f'want {want!r}')
    note = root / 'note.md'
    note.write_text('- done\n')
    check('Slack ok: false is an error', 'SlackError',
          raises(answer, 'data:application/json,{"ok":false,"error":"x"}', 'm'))
    check('Slack ok: true is the body', {'ok': True}, answer('data:application/json,{"ok":true}', 'm'))
    check('Jira answers each key', [{'key': 'XYZ-1', 'status': 'Done', 'summary': 'S'}], jira_issues(['XYZ-1']))
    os.environ['FAKE_FAIL'] = '1'
    try:
        check('a failed Jira search is an error, never no issues', 'CalledProcessError', raises(jira_issues, ['XYZ-1']))
        check('a failed rename warns on stderr, naming the script', ('', f'standup: {script("session_rename.sh")} exited 3\n', None),
              captured(name_session, '1791480100.356959'))
    finally:
        del os.environ['FAKE_FAIL']
    check('a rename prints its line on stdout', ('titled standup 2026-10-08 17:21 UTC\n', '', None),
          captured(name_session, '1791480100.356959'))
    check('a post prints the permalink and names the session',
          ('https://x/archives/D1/p1791480100356959\ntitled standup 2026-10-08 17:21 UTC\n', '', 0),
          captured(post, note, False))
    check('an edit prints what the writer said', ('edited 1.2\n', '', 0), captured(edit, note, '1.2', False))
    check('post FILE runs the post', (0, 'https://x/archives/D1/p1791480100356959\ntitled standup 2026-10-08 17:21 UTC\n'),
          run_main('post', str(note)))
    check('edit FILE TS runs the edit', (0, 'edited 1.2\n'), run_main('edit', str(note), '1.2'))
    check('post without a file is a usage error', 2, run_main('post')[0])
    check('edit without a ts is a usage error', 2, run_main('edit', str(note))[0])


def self_test_project(root):
    """A project holding the values and the secret; the run moves into it."""
    claude = root / 'p' / '.claude'
    (root / 'p' / '.secrets').mkdir(parents=True)
    claude.mkdir()
    for name, text in (('standup_channel', '# the DM\nD1\n'),
                       ('standup_thread', '100.000200\n'),
                       ('atlassian_site', 'https://site.example\n'),
                       ('session_history.md', HISTORY_FIXTURE)):
        (claude / name).write_text(text)
    (root / 'p' / '.secrets' / 'slack-token').write_text('xoxp-test\n')
    (claude / 'scripts').mkdir()
    for name, body in FAKES.items():
        (claude / 'scripts' / name).write_text('#!/bin/sh\n' + body)
        (claude / 'scripts' / name).chmod(0o755)
    (root / 'bare' / '.claude').mkdir(parents=True)
    os.chdir(root / 'p')


def self_test_missing(t, root):
    """A project without the values stops gather before any call."""
    run = subprocess.run([sys.executable, str(Path(__file__).resolve()), 'gather'],
                         cwd=root / 'bare', capture_output=True, text=True,
                         env={**os.environ, 'HTTPS_PROXY': 'http://127.0.0.1:9'})
    t.check(run.returncode == 1, 'a project without the values stops gather, exit 1',
            f'got {run.returncode}')
    t.check('standup_channel' in run.stderr, 'and names the value it lacks',
            run.stderr.strip())


def self_test():
    """Drive every pure step over fixtures, in a fixture project."""
    sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
    from tap import Tap
    t = Tap()
    here = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        self_test_project(Path(tmp))
        try:
            self_test_cases(t)
            self_test_calls(t, Path(tmp))
            self_test_missing(t, Path(tmp))
        finally:
            os.chdir(here)
    return t.end()


def self_test_cases(t):

    def check(name, want, got):
        return t.check(got == want, name, f'got {got!r}', f'want {want!r}')

    since = datetime(2026, 9, 25, 16, 43, tzinfo=timezone.utc)
    history = entries_since(HISTORY_FIXTURE, since)
    thread = [{'user': 'U1', 'ts': '100.0'}, {'user': 'U2', 'ts': '300.0'},
              {'user': 'U1', 'ts': '200.0'}]
    issue = {'key': 'XYZ-1', 'status': 'Done', 'summary': 'S'}
    previous = {'ts': '0', 'text': 'Hi'}
    later = str(since.timestamp() + 60)
    thread_link = 'https://x/p100000200?thread_ts=1'
    matches = [
        {'ts': later, 'text': 'keep', 'permalink': 'https://x/p1',
         'channel': {'name': 'general'}},
        {'ts': later, 'text': 'thread', 'permalink': thread_link,
         'channel': {'name': 'standup'}},
        {'ts': later, 'text': 'self', 'permalink': 'https://x/p2',
         'channel': {'name': 'U1'}},
        {'ts': '0', 'text': 'old', 'permalink': 'https://x/p3',
         'channel': {'name': 'general'}},
    ]
    cases = [
        ('only entries after the previous update', 2, len(history)),
        ('an entry stamped at the previous update is not after it', 1,
              len(entries_since(HISTORY_FIXTURE, datetime(2026, 9, 28, 10, 25, tzinfo=timezone.utc)))),
        ('a message sent at the previous update is not after it', False,
              written({'ts': str(since.timestamp()), 'permalink': 'https://x/p9',
                       'channel': {'name': 'general'}}, 'U1', since)),
        ('bookkeeping lines dropped',
              False, any('**Billed' in h or '**Session' in h
                         for h in history)),
        ('bullets kept', True, '- nothing billable' in history[1]),
        ('keys of every project found, sorted by number',
              ['ABC-1273', 'DEF-369', 'UTF-8', 'XYZ-7702', 'XYZ-10764'],
              issue_keys(history)),
        ('each key quoted in the search', 'key in ("XYZ-1","AND-1")',
              jql_of(['XYZ-1', 'AND-1'])),
        ('no keys, no Jira call', [], jira_issues([])),
        ('newest own message chosen', '200.0',
              latest_own(thread, 'U1')['ts']),
        ('no own message is None', None, latest_own(thread, 'U3')),
        ('the reply goes to the thread alone',
              [script('slack_post.py'), 'post', 'D1', 'f', '--thread', '100.000200'],
              post_command('f', dry_run=False)),
        ('issue line', '- XYZ-1 | Done | S | https://site.example/browse/XYZ-1',
              issue_line(issue)),
        ('thread, self-DM and older messages dropped',
              ['keep'], [m['text'] for m in matches if written(
                  m, 'U1', since)]),
        ('edit targets the reply in the standup channel',
              [script('slack_post.py'), 'edit', 'D1', '1.2', 'f', '--dry-run'],
              edit_command('f', '1.2', dry_run=True)),
        ('a permalink gives its message ts', '1791480100.356959',
              ts_of('https://x.slack.com/archives/C1/p1791480100356959'
                    '?thread_ts=1.2&cid=C1')),
        ('the writer is executable', True, os.access(script('slack_post.py'), os.X_OK)),
        ('a value drops its comment lines', 'D1', channel()),
        ('the token is the project secret', 'xoxp-test', token_file().read_text().strip()),
        ('the history is the project\'s', 2,
              len(entries_since(history_file().read_text(),
                                datetime(2026, 9, 25, 16, 43, tzinfo=timezone.utc)))),
        ('session title is the posted time in UTC',
              'standup 2026-09-25 16:43 UTC',
              session_title(str(since.timestamp()))),
        ('session rename script is executable', True,
              os.access(script('session_rename.sh'), os.X_OK)),
        ('empty sections say none', 3,
              report(previous, [], [], []).count('(none)')),
    ]
    for name, want, got in cases:
        check(name, want, got)
    with tempfile.NamedTemporaryFile('w', suffix='.md') as empty:
        with contextlib.redirect_stdout(sys.stderr):
            refused = post(empty.name, dry_run=True) != 0
            edit_refused = edit(empty.name, '1.2', dry_run=True) != 0
    check('empty file refused before posting', True, refused)
    check('empty file refused before editing', True, edit_refused)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog='\n'.join(__doc__.splitlines()[1:]),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', nargs='?', choices=('gather', 'post', 'edit'))
    parser.add_argument('file', nargs='?')
    parser.add_argument('ts', nargs='?')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.command == 'gather':
        return gather()
    if args.command == 'post' and args.file:
        return post(args.file, args.dry_run)
    if args.command == 'edit' and args.ts:
        return edit(args.file, args.ts, args.dry_run)
    parser.error('give gather, post FILE, or edit FILE TS')


if __name__ == '__main__':
    sys.exit(main())
