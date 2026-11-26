#!/usr/bin/env python3
"""slack_post.py — post, edit, delete or react to one Slack message.

  slack_post.py post CHANNEL FILE [--thread TS] [--broadcast]
                [--image PATH] [--dry-run]
  slack_post.py edit CHANNEL TS FILE [--dry-run]
  slack_post.py delete CHANNEL TS [--dry-run]
  slack_post.py react CHANNEL TS EMOJI [--dry-run]
  slack_post.py unreact CHANNEL TS EMOJI [--dry-run]
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

``react`` adds the reaction EMOJI, a name with or without its colons
(``white_check_mark``, ``:white_check_mark:``), to the message at TS, a
thread's parent or a reply, and reads the message back to confirm the
reaction is on it. A reaction already there counts as added, so a second
run changes nothing. ``unreact`` removes the write token's own reaction
EMOJI from the message at TS and reads back to confirm that user's
reaction is gone; another person's reaction of the same name stays, and
none to remove counts as removed. Both need the ``reactions:write`` scope
on the write token; without it Slack answers ``missing_scope`` and
nothing changes.

Raw ``<``, ``>`` and ``&`` arrive as written, so FILE needs no escaping.
Slack caps all ``markdown`` blocks in one payload at 12,000 characters
(https://docs.slack.dev/reference/block-kit/blocks/markdown-block);
longer text is refused before sending. So is a table over Slack's
limits of 100 rows, 20 cells a row and 10,000 characters of cells across
the message
(https://docs.slack.dev/reference/block-kit/blocks/table-block), and a
line that starts with a typed ``•`` or ``–``, which would post as a
character. So is a bare ``@name`` outside code: Slack posts it as text and
tags nobody. A tag is ``<@U…>``, the form ``slack_thread.py`` lists for each
person in its People block; a literal ``@`` goes in backticks.
A ``post`` or ``edit`` from a Claude session that has not loaded the
draft skill is refused by ``draft_gate.py`` and exits 1; ``--dry-run``,
``delete``, ``react`` and ``unreact`` are never refused.

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

from resolve import script, secret_path
from tap import Tap

SLACK_API = 'https://slack.com/api'
MARKDOWN_LIMIT = 12000
TIMEOUT = 30
# conversations.replies answers this for a message that no longer exists.
GONE = 'thread_not_found'
# The refusal each reaction method answers when the change is already made:
# the token's user has that reaction on, or has none to remove.
SETTLED = {'reactions.add': 'already_reacted',
           'reactions.remove': 'no_reaction'}
EMOJI_NAME = re.compile(r'^:?([a-z0-9_+\-]+(?:::skin-tone-[2-6])?):?$')

LIST_ITEM = re.compile(r'^\s*(?:[-*+]|\d+[.)])\s+\S')
FENCE = re.compile(r'^\s*(```|~~~)')
TYPED_BULLET = re.compile(r'(?m)^\s*[•–]\s')
TABLE_ROW = re.compile(r'^\s*\|.*\|\s*$')
TABLE_RULE = re.compile(r'^:?-+:?$')
TABLE_ROWS, TABLE_CELLS, TABLE_CHARS = 100, 20, 10000
# An @ that starts a word: not an email's, a URL path's, or a <@U…> tag's.
BARE_MENTION = re.compile(r'(?<![\w<@/.])@[A-Za-z](?:[\w.-]*\w)?')
INLINE_CODE = re.compile(r'`[^`\n]*`')


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
    bare = bare_mentions(text)
    if bare:
        raise SlackError(f'{path} has {", ".join(bare)}, which Slack posts as '
                         f'text and tags nobody; write <@U…> from '
                         f'slack_thread.py\'s People block, or put a literal '
                         f'@ in backticks')
    over = over_limits(table_rows(text))
    if over:
        raise SlackError(f'{path} has {"; ".join(over)}; Slack refuses '
                         f'such a table, so split it across messages')
    return text


def bare_mentions(markdown):
    """Each bare @name outside fenced and inline code, in order."""
    found, fenced = [], False
    for line in markdown.splitlines():
        if FENCE.match(line):
            fenced = not fenced
        elif not fenced:
            found += BARE_MENTION.findall(INLINE_CODE.sub('', line))
    return found


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


def emoji_name(raw):
    """The reaction's name without colons, or SlackError for one Slack
    could not name."""
    named = EMOJI_NAME.match(raw.strip())
    if not named:
        raise SlackError(f'{raw!r} is no emoji name; give one such as '
                         f'white_check_mark')
    return named.group(1)


def react_payload(channel, ts, name):
    return {'channel': channel, 'timestamp': ts, 'name': name}


def reacted(msg, name):
    """True when the message as Slack stored it carries the reaction."""
    return any(r.get('name') == name for r in (msg or {}).get('reactions', []))


def mine(msg, name, user):
    """True when user's own reaction of that name is on the message."""
    return any(r.get('name') == name and user in r.get('users', [])
               for r in (msg or {}).get('reactions', []))


# ── Slack ────────────────────────────────────────────────────────────

def token_file(env, name):
    """The token file: the path ``env`` names, else the project's
    ``.secrets/<name>`` (secret_file.sh)."""
    if os.environ.get(env):
        return Path(os.environ[env])
    return Path(secret_path(name))


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


def drafted():
    """True when draft_gate.py lets this session send text to people."""
    return subprocess.run([script('draft_gate.py'), 'check', 'draft']).returncode == 0


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


def tolerated(method, error):
    """True for the one refusal that means the change is already made."""
    return error.code == SETTLED[method]


def reaction_sender(method):
    return lambda payload: call(method, write_token(), payload=payload)


def change_reaction(method, payload, send=None):
    """Send the change, with one already made taken as done."""
    try:
        (send or reaction_sender(method))(payload)
    except SlackError as error:
        if not tolerated(method, error):
            raise


def confirm_reaction(msg, name, ts):
    """SlackError unless the read-back message carries the reaction."""
    if not reacted(msg, name):
        raise SlackError(f':{name}: not on message {ts} after react')


def confirm_unreacted(msg, name, ts, user):
    """SlackError while the read-back message carries user's reaction."""
    if mine(msg, name, user):
        raise SlackError(f':{name}: still on message {ts} after unreact')


def write_user():
    return call('auth.test', write_token())['user_id']


def react(channel, ts, emoji, dry_run):
    """Add the reaction to the message at ts, then confirm it is on it."""
    payload = react_payload(channel, ts, emoji_name(emoji))
    if dry_run:
        print(json.dumps(payload, indent=2))
        return 0
    change_reaction('reactions.add', payload)
    confirm_reaction(read_back(channel, ts), payload['name'], ts)
    print(f'reacted :{payload["name"]}: on {channel} {ts}')
    return 0


def unreact(channel, ts, emoji, dry_run):
    """Remove the write token's reaction from the message at ts, then
    confirm it is gone."""
    payload = react_payload(channel, ts, emoji_name(emoji))
    if dry_run:
        print(json.dumps(payload, indent=2))
        return 0
    change_reaction('reactions.remove', payload)
    confirm_unreacted(read_back(channel, ts), payload['name'], ts,
                      write_user())
    print(f'unreacted :{payload["name"]}: on {channel} {ts}')
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
    check('a bare @name is refused', True, refused_text(tmp, '@alex hi'))
    check('a bare @name mid-sentence is found', ['@alex'],
          bare_mentions('Thanks, @alex.'))
    check('a tag, an email, a URL and code are no bare @name', [],
          bare_mentions('<@U00000000> a@example.com https://x.io/@u `@x`\n'
                        '```\n@y\n```'))
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
    self_test_react()
    self_test_gate(tmp)
    return SELF_TEST.end()


def self_test_react():
    def name_refused(raw):
        try:
            emoji_name(raw)
            return False
        except SlackError:
            return True
    check('an emoji name loses its colons', 'white_check_mark',
          emoji_name(':white_check_mark:'))
    check('a bare emoji name is kept', 'white_check_mark',
          emoji_name('white_check_mark'))
    check('a skin tone stays part of the name', '+1::skin-tone-2',
          emoji_name(':+1::skin-tone-2:'))
    check('a name with a space is refused', True, name_refused('check mark'))
    check('a typed emoji is refused', True, name_refused('✅'))
    check('a reaction names channel, timestamp and emoji',
          {'channel': 'C1', 'timestamp': '1.2', 'name': 'x'},
          react_payload('C1', '1.2', 'x'))
    check('a message carrying the reaction reads back as reacted', True,
          reacted({'reactions': [{'name': 'eyes'}, {'name': 'x'}]}, 'x'))
    check('a message with other reactions is not reacted', False,
          reacted({'reactions': [{'name': 'eyes'}]}, 'x'))
    check('a message with no reactions is not reacted', False,
          reacted({'ts': '1.2'}, 'x'))
    check('a reaction already there counts as added', None,
          refusal_of(lambda: change_reaction(
              'reactions.add', {}, refusing('already_reacted'))))
    check('no reaction to remove counts as removed', None,
          refusal_of(lambda: change_reaction(
              'reactions.remove', {}, refusing('no_reaction'))))
    check("one method's settled code is raised by the other", 'no_reaction',
          refusal_of(lambda: change_reaction(
              'reactions.add', {}, refusing('no_reaction'))))
    check('any other refusal is raised', 'missing_scope',
          refusal_of(lambda: change_reaction(
              'reactions.remove', {}, refusing('missing_scope'))))
    sent = []
    change_reaction('reactions.add', {'name': 'x'}, sent.append)
    check('the change is sent once, as given', [{'name': 'x'}], sent)
    check('a read-back carrying the reaction confirms it', None,
          refusal_of(lambda: confirm_reaction(
              {'reactions': [{'name': 'x'}]}, 'x', '1.2')))
    check('a read-back without the reaction is refused', 'not on',
          refusal_of(lambda: confirm_reaction({'ts': '1.2'}, 'x', '1.2')))
    others = {'reactions': [{'name': 'x', 'users': ['U2']}]}
    check("another user's reaction is not mine", False, mine(others, 'x', 'U1'))
    check('my reaction of that name is mine', True,
          mine({'reactions': [{'name': 'x', 'users': ['U2', 'U1']}]}, 'x', 'U1'))
    check('my reaction of another name is not mine', False,
          mine({'reactions': [{'name': 'y', 'users': ['U1']}]}, 'x', 'U1'))
    check("a read-back with only others' reaction confirms the removal", None,
          refusal_of(lambda: confirm_unreacted(others, 'x', '1.2', 'U1')))
    check('a read-back still carrying mine is refused', 'not on',
          refusal_of(lambda: confirm_unreacted(
              {'reactions': [{'name': 'x', 'users': ['U1']}]}, 'x', '1.2',
              'U1')))


def refusing(code):
    """A sender that Slack refuses with code."""
    def send(_payload):
        raise SlackError(f'reactions: {code}', code)
    return send


def refusal_of(step):
    """None when step runs clean, else the SlackError's code, or 'not on'
    for a refusal without one."""
    try:
        step()
        return None
    except SlackError as error:
        return error.code or 'not on'


def self_test_gate(tmp):
    note = Path(tmp) / 'note.md'
    note.write_text('hello\n')
    gate = Path(tmp) / 'gate'
    gate.mkdir()
    (gate / 'drafted.json').write_text('["draft"]')
    refusal = ('draft_gate: load the draft skill with the Skill tool and check '
               'this text against it before sending; nothing was sent.\n')

    def run(session, *args):
        env = {**os.environ, 'CLAUDE_CODE_SESSION_ID': session,
               'DRAFT_GATE_DIR': str(gate),
               'SLACK_WRITE_TOKEN': '/nonexistent', 'SLACK_READ_TOKEN': '/nonexistent'}
        done = subprocess.run([sys.executable, __file__, *args], env=env,
                              capture_output=True, text=True)
        return done.returncode, done.stderr
    check('a post from a session without draft is refused before sending',
          (1, refusal), run('st', 'post', 'C1', str(note)))
    check('an edit from a session without draft is refused before sending',
          (1, refusal), run('st', 'edit', 'C1', '1.2', str(note)))
    allowed = run('drafted', 'post', 'C1', str(note))[1]
    check('a session that loaded draft goes on to send', (True, False),
          (bool(allowed), 'draft_gate:' in allowed))
    check('a dry run is never refused', 0,
          run('st', 'post', 'C1', str(note), '--dry-run')[0])
    check('a react is never refused by the draft gate', False,
          'draft_gate:' in run('st', 'react', 'C1', '1.2', 'x')[1])
    dry = subprocess.run([sys.executable, __file__, 'react', 'C1', '1.2',
                          ':x:', '--dry-run'], capture_output=True, text=True)
    check('a react dry run prints the payload and sends nothing',
          (0, {'channel': 'C1', 'timestamp': '1.2', 'name': 'x'}),
          (dry.returncode, json.loads(dry.stdout or 'null')))
    check('an unreact is never refused by the draft gate', False,
          'draft_gate:' in run('st', 'unreact', 'C1', '1.2', 'x')[1])
    undo = subprocess.run([sys.executable, __file__, 'unreact', 'C1', '1.2',
                           ':x:', '--dry-run'], capture_output=True, text=True)
    check('an unreact dry run prints the payload and sends nothing',
          (0, {'channel': 'C1', 'timestamp': '1.2', 'name': 'x'}),
          (undo.returncode, json.loads(undo.stdout or 'null')))


COMMANDS = {
    'post': lambda a: post(a.channel, a.file, a.thread, a.broadcast, a.image,
                           a.dry_run),
    'edit': lambda a: edit(a.channel, a.ts, a.file, a.dry_run),
    'delete': lambda a: delete(a.channel, a.ts, a.dry_run),
    'react': lambda a: react(a.channel, a.ts, a.emoji, a.dry_run),
    'unreact': lambda a: unreact(a.channel, a.ts, a.emoji, a.dry_run),
}


def run_command(args):
    """The command's exit code, with a Slack refusal printed as 1."""
    try:
        return COMMANDS[args.command](args)
    except SlackError as error:
        print(f'slack_post: {error}', file=sys.stderr)
        return 1


def parser_of():
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
    for name in ('react', 'unreact'):
        r = sub.add_parser(name)
        r.add_argument('channel')
        r.add_argument('ts')
        r.add_argument('emoji')
        r.add_argument('--dry-run', action='store_true')
    return parser


def main():
    parser = parser_of()
    args = parser.parse_args()
    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            return self_test(tmp)
    if args.command is None:
        parser.error('give post CHANNEL FILE, edit CHANNEL TS FILE, '
                     'delete CHANNEL TS, react CHANNEL TS EMOJI or '
                     'unreact CHANNEL TS EMOJI')
    sends_text = args.command in ('post', 'edit') and not args.dry_run
    if sends_text and not drafted():
        return 1
    return run_command(args)


if __name__ == '__main__':
    sys.exit(main())
