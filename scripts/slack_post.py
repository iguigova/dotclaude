#!/usr/bin/env python3
"""slack_post.py — post or edit one Slack message written in Markdown.

  slack_post.py post CHANNEL FILE [--thread TS] [--broadcast] [--dry-run]
  slack_post.py edit CHANNEL TS FILE [--dry-run]
  slack_post.py --self-test        # offline, no network

FILE is standard Markdown: **bold**, _italic_, `code`, [text](url),
``- `` and ``1. `` lists, nested by two spaces. It is sent as one
``markdown`` block, which Slack turns into rich text on its side: a list
becomes a real ``rich_text_list``. A message's plain ``text`` field is
mrkdwn, which has no lists, so a ``•`` line sent there stays a
character. ``text`` carries a plain copy as the notification fallback.

``post`` sends the message, in the thread at TS with ``--thread``, also
to the channel with ``--broadcast``. CHANNEL may be a user id, which sends
a direct message; the read-back and the printed ``edit`` hint then use the
DM's own channel id. ``edit`` replaces the message at
TS whole. Either then reads the message back, checks that every list
item in FILE arrived as a list item, and prints its permalink. A
mismatch exits 1 and says so; the message is already posted, so the
fix is an ``edit``. ``--dry-run`` prints the payload and sends nothing.

Raw ``<``, ``>`` and ``&`` arrive as written, so FILE needs no escaping.
Slack caps all ``markdown`` blocks in one payload at 12,000 characters
(https://docs.slack.dev/reference/block-kit/blocks/markdown-block);
longer text is refused before sending, and so is a line that starts
with a typed ``•`` or ``–``, which would post as a character.

It writes with ``~/.slack-token-write`` (chat:write only) and reads back
with ``~/.slack-token``; ``SLACK_WRITE_TOKEN`` and ``SLACK_READ_TOKEN``
name other files.
"""
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

SLACK_API = 'https://slack.com/api'
WRITE_TOKEN = Path(os.environ.get(
    'SLACK_WRITE_TOKEN', Path.home() / '.slack-token-write'))
READ_TOKEN = Path(os.environ.get(
    'SLACK_READ_TOKEN', Path.home() / '.slack-token'))
MARKDOWN_LIMIT = 12000
TIMEOUT = 30

LIST_ITEM = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+\S')
FENCE = re.compile(r'^\s*(```|~~~)')
TYPED_BULLET = re.compile(r'(?m)^\s*[•–]\s')


class SlackError(Exception):
    """Slack answered ok: false, or the message did not render."""


# ── Pure steps ───────────────────────────────────────────────────────

def text_of(path):
    """FILE's Markdown, or SlackError when it cannot be sent."""
    text = Path(path).read_text().strip()
    if not text:
        raise SlackError(f'{path} is empty; nothing sent')
    if len(text) > MARKDOWN_LIMIT:
        raise SlackError(f'{path} is {len(text)} characters; a markdown '
                         f'block takes at most {MARKDOWN_LIMIT}')
    if TYPED_BULLET.search(text):
        raise SlackError(f'{path} has a line starting with a typed bullet; '
                         f'write a list item as "- " so it renders as one')
    return text


def fallback(markdown):
    """The plain copy a notification shows: links as their text, no
    emphasis or code marks, list markers as bullets."""
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', markdown)
    text = re.sub(r'(\*\*|__|`)', '', text)
    return re.sub(r'(?m)^(\s*)[-*+]\s+', r'\1• ', text)


def message(markdown):
    return {'text': fallback(markdown),
            'blocks': [{'type': 'markdown', 'text': markdown}],
            'unfurl_links': False, 'unfurl_media': False}


def post_payload(channel, markdown, thread=None, broadcast=False):
    payload = {'channel': channel, **message(markdown)}
    if thread:
        payload['thread_ts'] = thread
        if broadcast:
            payload['reply_broadcast'] = True
    return payload


def edit_payload(channel, ts, markdown):
    """chat.update replaces text and blocks together."""
    return {'channel': channel, 'ts': ts, **message(markdown)}


def expected_items(markdown):
    """List items in the Markdown, outside code fences."""
    count, fenced = 0, False
    for line in markdown.splitlines():
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced and LIST_ITEM.match(line):
            count += 1
    return count


def rendered_items(msg):
    """List items in a message as Slack stored it."""
    return sum(len(element.get('elements', []))
               for block in msg.get('blocks', [])
               if block.get('type') == 'rich_text'
               for element in block.get('elements', [])
               if element.get('type') == 'rich_text_list')


def verdict(markdown, msg):
    """None when every list item arrived as one, else what went wrong."""
    want, got = expected_items(markdown), rendered_items(msg)
    if want == got:
        return None
    return f'{want} list items written, {got} rendered'


def pick(messages, ts):
    return next((m for m in messages if m.get('ts') == ts), None)


# ── Slack ────────────────────────────────────────────────────────────

def call(method, token, payload=None, params=None):
    headers = {'Authorization': f'Bearer {token.read_text().strip()}'}
    url = f'{SLACK_API}/{method}'
    data = None
    if payload is not None:
        headers['Content-Type'] = 'application/json; charset=utf-8'
        data = json.dumps(payload).encode()
    if params:
        url += '?' + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        body = json.load(response)
    if not body.get('ok'):
        raise SlackError(f'{method}: {body.get("error")}')
    return body


def read_back(channel, ts):
    """The message at ts, a thread reply or not."""
    params = {'channel': channel, 'ts': ts, 'oldest': ts, 'latest': ts,
              'inclusive': 'true', 'limit': 1}
    msg = pick(call('conversations.replies', READ_TOKEN,
                    params=params)['messages'], ts)
    if msg is None:
        raise SlackError(f'message {ts} not found on read-back')
    return msg


def confirm(channel, ts, markdown):
    """Print the permalink; exit 1 when the message did not render."""
    link = call('chat.getPermalink', READ_TOKEN,
                params={'channel': channel, 'message_ts': ts})['permalink']
    print(link)
    problem = verdict(markdown, read_back(channel, ts))
    if problem:
        print(f'slack_post: sent but not rendered as written: {problem}; '
              f'fix it with: slack_post.py edit {channel} {ts} FILE',
              file=sys.stderr)
        return 1
    return 0


def send(method, payload, dry_run):
    if dry_run:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return None
    return call(method, WRITE_TOKEN, payload=payload)


def post(channel, path, thread, broadcast, dry_run):
    markdown = text_of(path)
    sent = send('chat.postMessage',
                post_payload(channel, markdown, thread, broadcast), dry_run)
    return 0 if sent is None else confirm(*posted_at(sent), markdown)


def posted_at(sent):
    """The channel and ts a post landed at: a user id resolves to a DM."""
    return sent['channel'], sent['ts']


def edit(channel, ts, path, dry_run):
    markdown = text_of(path)
    sent = send('chat.update', edit_payload(channel, ts, markdown), dry_run)
    return 0 if sent is None else confirm(channel, ts, markdown)


# ── Self-test ────────────────────────────────────────────────────────

SAMPLE = """**Outcome** with `pi_1` and [a link](https://x.invalid).

- first
  - nested, with snake_case
1. step

```
- not a list item
```
"""

STORED = {'blocks': [{'type': 'rich_text', 'elements': [
    {'type': 'rich_text_section', 'elements': []},
    {'type': 'rich_text_list', 'style': 'bullet', 'indent': 0,
     'elements': [{'type': 'rich_text_section'}]},
    {'type': 'rich_text_list', 'style': 'bullet', 'indent': 1,
     'elements': [{'type': 'rich_text_section'}]},
    {'type': 'rich_text_list', 'style': 'ordered', 'indent': 0,
     'elements': [{'type': 'rich_text_section'}]}]}]}


def check(name, expected, actual):
    ok = expected == actual
    print(f'  {"ok" if ok else "FAIL"}  {name}')
    if not ok:
        print(f'        expected {expected!r}\n        got      {actual!r}')
    return ok


def refused(path):
    try:
        text_of(path)
        return False
    except SlackError:
        return True


def refused_text(tmp, text):
    path = Path(tmp) / 'sample.md'
    path.write_text(text)
    return refused(path)


def self_test(tmp):
    plain = {'text': '• first', 'blocks': [{'type': 'rich_text', 'elements': [
        {'type': 'rich_text_section', 'elements': []}]}]}
    empty, long_ = Path(tmp) / 'empty.md', Path(tmp) / 'long.md'
    typed = Path(tmp) / 'typed.md'
    empty.write_text('\n')
    typed.write_text('Intro\n\n• a typed bullet\n')
    long_.write_text('x' * (MARKDOWN_LIMIT + 1))
    reply = post_payload('C1', 'x', thread='1.2', broadcast=True)
    results = [
        check('list items counted, nested ones too, fenced ones not',
              3, expected_items(SAMPLE)),
        check('stored list items counted across lists', 3,
              rendered_items(STORED)),
        check('a message that rendered its lists passes', None,
              verdict(SAMPLE, STORED)),
        check('bullets sent as text are caught',
              '3 list items written, 0 rendered', verdict(SAMPLE, plain)),
        check('the Markdown goes in one markdown block',
              [{'type': 'markdown', 'text': 'x'}], reply['blocks']),
        check('a thread reply can also go to the channel',
              ('1.2', True), (reply['thread_ts'], reply['reply_broadcast'])),
        check('a top-level post names no thread', False,
              'thread_ts' in post_payload('C1', 'x')),
        check('broadcast without a thread is ignored', False,
              'reply_broadcast' in post_payload('C1', 'x', broadcast=True)),
        check('an edit replaces text and blocks at ts',
              ('C1', '1.2', 'x'), tuple(edit_payload('C1', '1.2', 'x')[k]
                                       for k in ('channel', 'ts', 'text'))),
        check('the fallback drops marks and keeps the words',
              'Outcome with pi_1 and a link.\n\n• first\n  • nested',
              fallback('**Outcome** with `pi_1` and [a link](https://x)'
                       '.\n\n- first\n  - nested')),
        check('the read-back uses the channel the post landed in',
              ('D1', '1.2'), posted_at({'channel': 'D1', 'ts': '1.2'})),
        check('the read-back picks the message by ts', '2',
              pick([{'ts': '1'}, {'ts': '2'}], '2')['ts']),
        check('an empty file is refused', True, refused(empty)),
        check('text over the block limit is refused', True, refused(long_)),
        check('a typed bullet is refused', True, refused(typed)),
        check('the sample is accepted', False, refused_text(tmp, SAMPLE)),
    ]
    print('slack_post self-test:', 'PASS' if all(results) else 'FAIL')
    return 0 if all(results) else 1


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog='\n'.join(__doc__.splitlines()[1:]),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true')
    sub = parser.add_subparsers(dest='command')
    p = sub.add_parser('post')
    p.add_argument('channel')
    p.add_argument('file')
    p.add_argument('--thread')
    p.add_argument('--broadcast', action='store_true')
    p.add_argument('--dry-run', action='store_true')
    e = sub.add_parser('edit')
    e.add_argument('channel')
    e.add_argument('ts')
    e.add_argument('file')
    e.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            return self_test(tmp)
    try:
        if args.command == 'post':
            return post(args.channel, args.file, args.thread,
                        args.broadcast, args.dry_run)
        if args.command == 'edit':
            return edit(args.channel, args.ts, args.file, args.dry_run)
    except SlackError as error:
        print(f'slack_post: {error}', file=sys.stderr)
        return 1
    parser.error('give post CHANNEL FILE or edit CHANNEL TS FILE')


if __name__ == '__main__':
    sys.exit(main())
