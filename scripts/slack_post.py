#!/usr/bin/env python3
"""slack_post.py — post, edit or delete one Slack message written in Markdown.

  slack_post.py post CHANNEL FILE [--thread TS] [--broadcast]
                [--image PATH] [--dry-run]
  slack_post.py edit CHANNEL TS FILE [--dry-run]
  slack_post.py delete CHANNEL TS [--dry-run]
  slack_post.py --self-test        # offline, no network

FILE is standard Markdown: **bold**, _italic_, `code`, [text](url),
``- `` and ``1. `` lists, nested by two spaces. It is sent as one
``markdown`` block, which Slack turns into rich text on its side: a list
becomes a real ``rich_text_list``. A message's plain ``text`` field is
mrkdwn, which has no lists, so a ``•`` line sent there stays a
character. ``text`` carries a plain copy as the notification fallback.
A pipe table (``| a | b |``, a ``|---|--:|`` line under its header)
becomes a ``table`` block, its alignment kept; a fenced block stays
monospace text.

``post`` sends the message, in the thread at TS with ``--thread``, also
to the channel with ``--broadcast``. A TS that is itself a reply is
refused, naming its thread's TS. CHANNEL may be a user id, which sends
a direct message; the read-back and the printed ``edit`` hint then use the
DM's own channel id. ``edit`` replaces the message at
TS whole. Either then reads the message back, checks that every list
item in FILE arrived as a list item and every table row as a table row,
and prints its permalink. A
mismatch exits 1 and says so; the message is already posted, so the
fix is an ``edit``. ``--dry-run`` prints the payload and sends nothing.

``--image PATH`` uploads that file once the message has rendered, as the
next reply in the same thread (under the new message when it is not
itself a reply), and prints the file's permalink. Uploading needs the
``files:write`` scope on the write token. ``delete`` removes the message
at TS, one the write token's user posted, and reads back to confirm it
is gone: absent, or the ``tombstone`` Slack leaves in place of a deleted
message that has replies.

Raw ``<``, ``>`` and ``&`` arrive as written, so FILE needs no escaping.
Slack caps all ``markdown`` blocks in one payload at 12,000 characters
(https://docs.slack.dev/reference/block-kit/blocks/markdown-block);
longer text is refused before sending. So is a table over Slack's
limits of 100 rows, 20 cells a row and 10,000 characters of cells across
the message
(https://docs.slack.dev/reference/block-kit/blocks/table-block), and a
line that starts with a typed ``•`` or ``–``, which would post as a
character.

It writes with the project's ``.secrets/slack-token-write`` (chat:write
only) and reads back with ``.secrets/slack-token``;
``SLACK_WRITE_TOKEN`` and ``SLACK_READ_TOKEN`` name other files.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from tap import Tap

SLACK_API = 'https://slack.com/api'
MARKDOWN_LIMIT = 12000
TIMEOUT = 30
# conversations.replies answers this for a message that no longer exists.
GONE = 'thread_not_found'

LIST_ITEM = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+\S')
FENCE = re.compile(r'^\s*(```|~~~)')
TYPED_BULLET = re.compile(r'(?m)^\s*[•–]\s')
TABLE_ROW = re.compile(r'^\s*\|.*\|\s*$')
TABLE_RULE = re.compile(r'^:?-+:?$')
TABLE_ROWS, TABLE_CELLS, TABLE_CHARS = 100, 20, 10000


class SlackError(Exception):
    """Slack answered ok: false, or the message did not render.
    ``code`` is Slack's own error string when Slack sent one."""

    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


# ── Pure steps ───────────────────────────────────────────────────────

def text_of(path):
    """FILE's Markdown, or SlackError when it cannot be sent."""
    try:
        text = Path(path).read_text().strip()
    except OSError as error:
        raise SlackError(f'{path} cannot be read: {error.strerror}')
    if not text:
        raise SlackError(f'{path} is empty; nothing sent')
    if len(text) > MARKDOWN_LIMIT:
        raise SlackError(f'{path} is {len(text)} characters; a markdown '
                         f'block takes at most {MARKDOWN_LIMIT}')
    if TYPED_BULLET.search(text):
        raise SlackError(f'{path} has a line starting with a typed bullet; '
                         f'write a list item as "- " so it renders as one')
    over = over_limits(table_rows(text))
    if over:
        raise SlackError(f'{path} has {"; ".join(over)}; Slack refuses '
                         f'such a table, so split it across messages')
    return text


def over_limits(rows):
    """Each table limit the rows exceed."""
    chars = sum(len(cell) for row in rows for cell in row)
    return [problem for problem, exceeded in [
        (f'{len(rows)} table rows, over {TABLE_ROWS}', len(rows) > TABLE_ROWS),
        (f'a table row of over {TABLE_CELLS} cells',
         any(len(row) > TABLE_CELLS for row in rows)),
        (f'{chars} characters of table cells, over {TABLE_CHARS}',
         chars > TABLE_CHARS)] if exceeded]


def cells(line):
    """The cells of one pipe-table line."""
    return [cell.strip() for cell in line.strip().strip('|').split('|')]


def table_rows(markdown):
    """Each pipe-table row outside code fences, as its cells; the rule
    line under a header is not a row."""
    rows, fenced = [], False
    for line in markdown.splitlines():
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced and TABLE_ROW.match(line):
            row = cells(line)
            if not all(TABLE_RULE.match(cell) for cell in row):
                rows.append(row)
    return rows


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


def rendered_rows(msg):
    """Table rows in a message as Slack stored it."""
    return sum(len(block.get('rows', []))
               for block in msg.get('blocks', [])
               if block.get('type') == 'table')


def verdict(markdown, msg):
    """None when every list item and table row arrived as one, else
    what went wrong."""
    counts = [('list items', expected_items(markdown), rendered_items(msg)),
              ('table rows', len(table_rows(markdown)), rendered_rows(msg))]
    problems = [f'{want} {what} written, {got} rendered'
                for what, want, got in counts if want != got]
    return '; '.join(problems) or None


def pick(messages, ts):
    return next((m for m in messages if m.get('ts') == ts), None)


def reply_parent(msg, ts):
    """The thread a message at ts sits in when it is itself a reply, else
    None. A search hit or a thread file gives a reply its own ts, and Slack
    files a post sent with that ts as thread_ts under the reply's parent."""
    parent = (msg or {}).get('thread_ts')
    return parent if parent and parent != ts else None


def image_of(path):
    """PATH's bytes, or SlackError when there is nothing to upload."""
    path = Path(path)
    if not path.is_file():
        raise SlackError(f'{path} is not a file; nothing sent')
    data = path.read_bytes()
    if not data:
        raise SlackError(f'{path} is empty; nothing sent')
    return data


def image_thread(thread, ts):
    """The parent an image replies under: the thread, else the post."""
    return thread or ts


def upload_fields(name, data):
    return {'filename': name, 'length': len(data)}


def complete_fields(file_id, name, channel, thread):
    return {'files': json.dumps([{'id': file_id, 'title': name}]),
            'channel_id': channel, 'thread_ts': thread}


def delete_payload(channel, ts):
    return {'channel': channel, 'ts': ts}


# ── Slack ────────────────────────────────────────────────────────────

def token_file(env, name):
    """The token file: the path ``env`` names, else the project's
    ``.secrets/<name>`` (secret_file.sh)."""
    if os.environ.get(env):
        return Path(os.environ[env])
    found = subprocess.run(
        [str(Path(__file__).resolve().parent / 'secret_file.sh'), name],
        capture_output=True, text=True)
    if found.returncode:
        sys.exit(found.stderr.strip())
    return Path(found.stdout.strip())


def read_token():
    return token_file('SLACK_READ_TOKEN', 'slack-token')


def write_token():
    return token_file('SLACK_WRITE_TOKEN', 'slack-token-write')


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
        return answer(method, json.load(response))


def answer(method, body):
    """The body of an ok answer, else SlackError with Slack's code."""
    if not body.get('ok'):
        raise SlackError(f'{method}: {body.get("error")}', body.get('error'))
    return body


def call_form(method, token, fields):
    """A method that takes form fields rather than JSON."""
    headers = {'Authorization': f'Bearer {token.read_text().strip()}',
               'Content-Type': 'application/x-www-form-urlencoded'}
    data = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(f'{SLACK_API}/{method}', data=data,
                                     headers=headers)
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return answer(method, json.load(response))


def put_bytes(url, data):
    """Send the file's bytes to the upload URL; Slack answers 200."""
    request = urllib.request.Request(
        url, data=data, headers={'Content-Type': 'application/octet-stream'})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        if response.status != 200:
            raise SlackError(f'upload answered HTTP {response.status}')


def found(channel, ts):
    """The message at ts, a thread reply or not, or None."""
    params = {'channel': channel, 'ts': ts, 'oldest': ts, 'latest': ts,
              'inclusive': 'true', 'limit': 1}
    try:
        messages = call('conversations.replies', read_token(),
                        params=params)['messages']
    except SlackError as error:
        if error.code == GONE:
            return None
        raise
    return pick(messages, ts)


def read_back(channel, ts):
    """The message at ts, a thread reply or not."""
    msg = found(channel, ts)
    if msg is None:
        raise SlackError(f'message {ts} not found on read-back')
    return msg


def confirm(channel, ts, markdown):
    """Print the permalink; exit 1 when the message did not render."""
    link = call('chat.getPermalink', read_token(),
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
    return call(method, write_token(), payload=payload)


def post(channel, path, thread, broadcast, image, dry_run):
    markdown = text_of(path)
    data = image_of(image) if image else None
    parent = reply_parent(found(channel, thread), thread) if thread else None
    if parent:
        raise SlackError(f'--thread {thread} is a reply in thread {parent}; '
                         f'pass --thread {parent} to post in that thread')
    sent = send('chat.postMessage',
                post_payload(channel, markdown, thread, broadcast), dry_run)
    if sent is None:
        if data:
            print(json.dumps(upload_fields(Path(image).name, data)))
        return 0
    landed, ts = posted_at(sent)
    status = confirm(landed, ts, markdown)
    if status or not data:
        return status
    attach(landed, image_thread(thread, ts), Path(image).name, data)
    return 0


def attach(channel, thread, name, data):
    """Upload the image as a reply under thread and print its permalink."""
    target = call_form('files.getUploadURLExternal', write_token(),
                       upload_fields(name, data))
    put_bytes(target['upload_url'], data)
    done = call_form('files.completeUploadExternal', write_token(),
                     complete_fields(target['file_id'], name, channel, thread))
    print(done['files'][0].get('permalink', target['file_id']))


def posted_at(sent):
    """The channel and ts a post landed at: a user id resolves to a DM."""
    return sent['channel'], sent['ts']


def edit(channel, ts, path, dry_run):
    markdown = text_of(path)
    sent = send('chat.update', edit_payload(channel, ts, markdown), dry_run)
    return 0 if sent is None else confirm(channel, ts, markdown)


def gone(msg):
    """True when a read-back shows no message: none, or the tombstone
    Slack keeps in a deleted message's place while it has replies."""
    return msg is None or msg.get('subtype') == 'tombstone'


def delete(channel, ts, dry_run):
    """Remove the message at ts, then confirm it is gone."""
    if send('chat.delete', delete_payload(channel, ts), dry_run) is None:
        return 0
    if not gone(found(channel, ts)):
        raise SlackError(f'message {ts} still there after delete')
    print(f'deleted {channel} {ts}')
    return 0


# ── Self-test ────────────────────────────────────────────────────────

SAMPLE = """**Outcome** with `pi_1` and [a link](https://x.invalid).

- first
  - nested, with snake_case
1. step

```
- not a list item
| not | a row |
```

| group | count |
|---|--:|
| Surgery | 24 |
"""

STORED_TABLE = {'type': 'table', 'rows': [[{}, {}], [{}, {}]],
                'column_settings': [{}, {'align': 'right'}]}

STORED = {'blocks': [{'type': 'rich_text', 'elements': [
    {'type': 'rich_text_section', 'elements': []},
    {'type': 'rich_text_list', 'style': 'bullet', 'indent': 0,
     'elements': [{'type': 'rich_text_section'}]},
    {'type': 'rich_text_list', 'style': 'bullet', 'indent': 1,
     'elements': [{'type': 'rich_text_section'}]},
    {'type': 'rich_text_list', 'style': 'ordered', 'indent': 0,
     'elements': [{'type': 'rich_text_section'}]}]}, STORED_TABLE]}


SELF_TEST = Tap()


def check(name, expected, actual):
    return SELF_TEST.check(
        expected == actual, name,
        f'expected {expected!r}', f'got      {actual!r}')


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


def image_refused(tmp, data):
    path = Path(tmp) / 'image.png'
    path.unlink(missing_ok=True)
    if data is not None:
        path.write_bytes(data)
    try:
        image_of(path)
        return False
    except SlackError:
        return True


def error_code(body):
    try:
        answer('m', body)
        return None
    except SlackError as error:
        return error.code


def self_test(tmp):
    plain = {'text': '• first', 'blocks': [{'type': 'rich_text', 'elements': [
        {'type': 'rich_text_section', 'elements': []}]}]}
    empty, long_ = Path(tmp) / 'empty.md', Path(tmp) / 'long.md'
    typed = Path(tmp) / 'typed.md'
    empty.write_text('\n')
    typed.write_text('Intro\n\n• a typed bullet\n')
    long_.write_text('x' * (MARKDOWN_LIMIT + 1))
    reply = post_payload('C1', 'x', thread='1.2', broadcast=True)
    check('list items counted, nested ones too, fenced ones not',
          3, expected_items(SAMPLE))
    check('stored list items counted across lists', 3,
          rendered_items(STORED))
    check('a message that rendered its lists passes', None,
          verdict(SAMPLE, STORED))
    check('bullets and a table sent as text are caught',
          '3 list items written, 0 rendered; '
          '2 table rows written, 0 rendered', verdict(SAMPLE, plain))
    check('table rows counted, the rule line and fenced ones not',
          [['group', 'count'], ['Surgery', '24']], table_rows(SAMPLE))
    check('stored table rows counted', 2, rendered_rows(STORED))
    check('a table within the limits passes', [],
          over_limits([['a'] * TABLE_CELLS] * TABLE_ROWS))
    check('a table over each limit is refused, each named', 3,
          len(over_limits([['x' * 100] * (TABLE_CELLS + 1)]
                          * (TABLE_ROWS + 1))))
    check('a missing file is refused', True,
          refused(Path(tmp) / 'absent.md'))
    check('the Markdown goes in one markdown block',
          [{'type': 'markdown', 'text': 'x'}], reply['blocks'])
    check('a thread reply can also go to the channel',
          ('1.2', True), (reply['thread_ts'], reply['reply_broadcast']))
    check('a top-level post names no thread', False,
          'thread_ts' in post_payload('C1', 'x'))
    check('broadcast without a thread is ignored', False,
          'reply_broadcast' in post_payload('C1', 'x', broadcast=True))
    check('an edit replaces text and blocks at ts',
          ('C1', '1.2', 'x'), tuple(edit_payload('C1', '1.2', 'x')[k]
                                   for k in ('channel', 'ts', 'text')))
    check('the fallback drops marks and keeps the words',
          'Outcome with pi_1 and a link.\n\n• first\n  • nested',
          fallback('**Outcome** with `pi_1` and [a link](https://x)'
                   '.\n\n- first\n  - nested'))
    check('the read-back uses the channel the post landed in',
          ('D1', '1.2'), posted_at({'channel': 'D1', 'ts': '1.2'}))
    check('the read-back picks the message by ts', '2',
          pick([{'ts': '1'}, {'ts': '2'}], '2')['ts'])
    check('an empty file is refused', True, refused(empty))
    check('text over the block limit is refused', True, refused(long_))
    check('a typed bullet is refused', True, refused(typed))
    check('the sample is accepted', False, refused_text(tmp, SAMPLE))
    check('a missing image is refused', True, image_refused(tmp, None))
    check('an empty image is refused', True, image_refused(tmp, b''))
    check('an image with bytes is read', False,
          image_refused(tmp, b'\x89PNG'))
    check('an image replies in the thread it was posted to', '1.2',
          image_thread('1.2', '3.4'))
    check('an image replies under a top-level post', '3.4',
          image_thread(None, '3.4'))
    check('the upload names the file and its size',
          {'filename': 'a.png', 'length': 4},
          upload_fields('a.png', b'\x89PNG'))
    check('the upload is shared in the thread it names',
          {'files': '[{"id": "F1", "title": "a.png"}]',
           'channel_id': 'C1', 'thread_ts': '1.2'},
          complete_fields('F1', 'a.png', 'C1', '1.2'))
    check('a delete names the channel and ts',
          {'channel': 'C1', 'ts': '1.2'}, delete_payload('C1', '1.2'))
    check('a deleted message with replies reads back as gone', True,
          gone({'ts': '1.2', 'subtype': 'tombstone'}))
    check('a missing message reads back as gone', True, gone(None))
    check('a message still posted is not gone', False,
          gone({'ts': '1.2', 'text': 'x'}))
    check('a reply names the thread it sits in', '1.0',
          reply_parent({'ts': '1.2', 'thread_ts': '1.0'}, '1.2'))
    check('a thread parent is no reply', None,
          reply_parent({'ts': '1.0', 'thread_ts': '1.0'}, '1.0'))
    check('a message outside any thread is no reply', None,
          reply_parent({'ts': '1.2'}, '1.2'))
    check('a message not found is no reply', None, reply_parent(None, '1.2'))
    check("an error keeps Slack's code", 'thread_not_found',
          error_code({'ok': False, 'error': 'thread_not_found'}))
    return SELF_TEST.end()


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
    p.add_argument('--image')
    p.add_argument('--dry-run', action='store_true')
    e = sub.add_parser('edit')
    e.add_argument('channel')
    e.add_argument('ts')
    e.add_argument('file')
    e.add_argument('--dry-run', action='store_true')
    d = sub.add_parser('delete')
    d.add_argument('channel')
    d.add_argument('ts')
    d.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            return self_test(tmp)
    try:
        if args.command == 'post':
            return post(args.channel, args.file, args.thread,
                        args.broadcast, args.image, args.dry_run)
        if args.command == 'edit':
            return edit(args.channel, args.ts, args.file, args.dry_run)
        if args.command == 'delete':
            return delete(args.channel, args.ts, args.dry_run)
    except SlackError as error:
        print(f'slack_post: {error}', file=sys.stderr)
        return 1
    parser.error('give post CHANNEL FILE, edit CHANNEL TS FILE '
                 'or delete CHANNEL TS')


if __name__ == '__main__':
    sys.exit(main())
