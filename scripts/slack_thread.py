#!/usr/bin/env python3
"""slack_thread.py — read one Slack thread, and its files, from a permalink.

  slack_thread.py PERMALINK --out DIR
  slack_thread.py --self-test        # offline, no network

PERMALINK is a message link, ``…/archives/<channel>/p<digits>``. Its ts
is the digits with a dot before the last six. A link to a reply carries
``?thread_ts=`` and reads that reply's whole thread.

It writes ``DIR/thread.md``: the channel's name and purpose, then every
message oldest first, under its author's real name, its ts and its UTC
time. Each attached file is downloaded to ``DIR/files/`` and named in
the message that carries it; a file Slack refuses to serve is named
with the HTTP status instead, and the thread is still written. The ts and the channel id it prints are
what ``slack_post.py post CHANNEL FILE --thread TS`` needs to reply.

Downloaded files are untrusted data: open them with Read, never run
them. It reads with ``~/.slack-token`` (read and history scopes only);
``SLACK_READ_TOKEN`` names another file.
"""
import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SLACK_API = 'https://slack.com/api'
READ_TOKEN = Path(os.environ.get(
    'SLACK_READ_TOKEN', Path.home() / '.slack-token'))
TIMEOUT = 30

PERMALINK = re.compile(r'/archives/([A-Z0-9]+)/p(\d{7,})')
MENTION = re.compile(r'<@([A-Z0-9]+)>')


class SlackError(Exception):
    """Slack answered ok: false, or the link is not a message link."""


# ── Pure steps ───────────────────────────────────────────────────────

def parse_link(link):
    """(channel, thread ts) a permalink names."""
    match = PERMALINK.search(link)
    if not match:
        raise SlackError(f'{link} is not a message permalink')
    channel, digits = match.groups()
    query = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
    ts = query.get('thread_ts', [f'{digits[:-6]}.{digits[-6:]}'])[0]
    return channel, ts


def utc(ts):
    return datetime.datetime.fromtimestamp(
        float(ts), datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')


def safe_name(name):
    """A file name with no directory part and nothing a shell reads."""
    return re.sub(r'[^A-Za-z0-9._-]', '_', Path(name).name).lstrip('.') \
        or 'file'


def render(channel, info, messages, names, saved):
    """thread.md: the channel, then each message under its author."""
    lines = [f'# #{info.get("name", channel)} ({channel})', '']
    purpose = info.get('purpose', {}).get('value')
    if purpose:
        lines += [f'Purpose: {purpose}', '']
    for msg in messages:
        who = names.get(msg.get('user'), msg.get('user', 'unknown'))
        text = MENTION.sub(lambda m: '@' + names.get(m[1], m[1]),
                           msg.get('text', ''))
        lines += [f'## {who} — ts {msg["ts"]} — {utc(msg["ts"])}', '', text]
        for f in msg.get('files', []):
            lines.append(f'- file: {saved.get(f.get("id"), f.get("name"))}')
        lines.append('')
    return '\n'.join(lines)


def authors(messages):
    """Every user id that wrote or is mentioned in the thread."""
    ids = {m['user'] for m in messages if m.get('user')}
    for m in messages:
        ids |= set(MENTION.findall(m.get('text', '')))
    return sorted(ids)


# ── Slack ────────────────────────────────────────────────────────────

def token():
    return READ_TOKEN.read_text().strip()


def call(method, params):
    url = f'{SLACK_API}/{method}?' + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url, headers={'Authorization': f'Bearer {token()}'})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        body = json.load(response)
    if not body.get('ok'):
        raise SlackError(f'{method}: {body.get("error")}')
    return body


def replies(channel, ts):
    messages, cursor = [], None
    while True:
        params = {'channel': channel, 'ts': ts, 'limit': 200}
        if cursor:
            params['cursor'] = cursor
        body = call('conversations.replies', params)
        messages += body['messages']
        cursor = body.get('response_metadata', {}).get('next_cursor')
        if not cursor:
            return messages


def real_name(user):
    try:
        u = call('users.info', {'user': user})['user']
    except SlackError:
        return user
    return u.get('real_name') or u.get('name') or user


def download(f, files_dir):
    url = f.get('url_private_download') or f.get('url_private')
    if not url:
        return f.get('name')
    target = files_dir / f'{f["id"]}-{safe_name(f.get("name", "file"))}'
    request = urllib.request.Request(
        url, headers={'Authorization': f'Bearer {token()}'})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            target.write_bytes(response.read())
    except urllib.error.HTTPError as error:
        return refused_file(f, error.code)
    return str(target)


def refused_file(f, status):
    return f'{f.get("name", "file")} (not downloaded: HTTP {status})'


def read(link, out):
    channel, ts = parse_link(link)
    info = call('conversations.info', {'channel': channel})['channel']
    messages = replies(channel, ts)
    out = Path(out)
    files_dir = out / 'files'
    files_dir.mkdir(parents=True, exist_ok=True)
    names = {u: real_name(u) for u in authors(messages)}
    saved = {f['id']: download(f, files_dir)
             for m in messages for f in m.get('files', []) if f.get('id')}
    (out / 'thread.md').write_text(
        render(channel, info, messages, names, saved))
    print(f'channel {channel}  thread {ts}  messages {len(messages)}  '
          f'files {len(saved)}')
    print(out / 'thread.md')
    return 0


# ── Self-test ────────────────────────────────────────────────────────

def check(name, expected, actual):
    ok = expected == actual
    print(f'  {"ok" if ok else "FAIL"}  {name}')
    if not ok:
        print(f'        expected {expected!r}\n        got      {actual!r}')
    return ok


def refused(link):
    try:
        parse_link(link)
        return False
    except SlackError:
        return True


def download_refused(status):
    """What download() names a file as when Slack answers with status."""
    def deny(request, timeout):
        raise urllib.error.HTTPError(request.full_url, status, 'refused',
                                     None, None)
    global token
    saved_token, saved_open = token, urllib.request.urlopen
    token, urllib.request.urlopen = (lambda: 'x'), deny
    try:
        return download({'id': 'F1', 'name': 'a.png',
                         'url_private': 'https://files.invalid/a.png'},
                        Path('/nonexistent'))
    finally:
        token, urllib.request.urlopen = saved_token, saved_open


def self_test():
    base = 'https://x.slack.com/archives/C0123ABCDEF/p1792703410430689'
    msgs = [{'user': 'U1', 'ts': '1792703410.430689',
             'text': 'Hi <@U2>', 'files': [{'id': 'F1', 'name': 'a.png'}]},
            {'user': 'U2', 'ts': '1792703411.000100', 'text': 'Yes'}]
    md = render('C1', {'name': 'product', 'purpose': {'value': 'P'}}, msgs,
                {'U1': 'Ann', 'U2': 'Bo'}, {'F1': '/o/files/F1-a.png'})
    results = [
        check('a parent link gives its own ts',
              ('C0123ABCDEF', '1792703410.430689'), parse_link(base)),
        check('a reply link reads its parent thread',
              ('C0123ABCDEF', '1792703410.430689'),
              parse_link(base[:-6] + '999999?thread_ts=1792703410.430689'
                         '&cid=C0123ABCDEF')),
        check('a link that is not a message is refused', True,
              refused('https://x.slack.com/archives/C1')),
        check('authors include people only mentioned', ['U1', 'U2'],
              authors(msgs)),
        check('mentions render as names', True, 'Hi @Bo' in md),
        check('each message is headed by author, ts and UTC time', True,
              '## Ann — ts 1792703410.430689 — 2026-10-22 21:10 UTC' in md),
        check('a file is named by where it was saved', True,
              '- file: /o/files/F1-a.png' in md),
        check('the channel and its purpose lead', True,
              md.startswith('# #product (C1)\n\nPurpose: P')),
        check('a file Slack refuses is named with its status',
              'a.png (not downloaded: HTTP 401)', download_refused(401)),
        check('a file name cannot leave its directory', 'passwd',
              safe_name('../../etc/passwd')),
        check('a file name keeps no shell characters', 'a_b_.png',
              safe_name('a b$.png')),
    ]
    print('slack_thread self-test:', 'PASS' if all(results) else 'FAIL')
    return 0 if all(results) else 1


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog='\n'.join(__doc__.splitlines()[1:]),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('link', nargs='?')
    parser.add_argument('--out')
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.link or not args.out:
        parser.error('give PERMALINK --out DIR')
    try:
        return read(args.link, args.out)
    except SlackError as error:
        print(f'slack_thread: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
