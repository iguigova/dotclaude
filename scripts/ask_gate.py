#!/usr/bin/env python3
"""ask_gate.py — a reply asks nothing in prose; a question to the user is the dialog.

  ask_gate.py stop          # Stop hook: refuse to end on a question in prose
  ask_gate.py --self-test   # offline

The user's rule (CLAUDE.md, "A question to the user is the question dialog"):
every choice, approval or question put to the user goes through
AskUserQuestion and ends the turn on it. A numbered list of options or a
"Shall I …?" in the reply is not asking: the user answers "proceed" to prose
that offered two paths, and the model picks one. A rule read at session start
loses to the habit of a long turn, so the harness enforces it here.

``stop`` reads the Stop payload on stdin. ``last_assistant_message`` is the
reply's text (https://code.claude.com/docs/en/hooks#stop). When that text,
outside code, quotes and URLs, holds a sentence ending in "?", the hook
blocks the stop and its reason quotes the question and says to ask it with
AskUserQuestion. Any such sentence counts, wherever it sits in the reply: a
question put to the user and a rhetorical one share their syntax ("One
decision is yours: should it push?" against "it checks one thing: has the
repo moved?"), so the gate cannot tell them apart and a reply asks nothing
in prose; a sentence that asks the user nothing is written as a statement.
A reply that called AskUserQuestion carries the answer, not
the question, so it passes. ``stop_hook_active`` is true when the turn is
already continuing because of a stop hook; the hook then lets the turn end,
so a sentence it misread costs one continuation, never a loop.

A payload it cannot read blocks nothing: a gate that failed closed would
keep every turn from ending.
"""
import json
import re
import sys

from tap import Tap

QUOTE_LIMIT = 200

FENCE = re.compile(r'^\s*(```|~~~)')
INLINE_CODE = re.compile(r'`[^`\n]*`')
URL = re.compile(r'https?://\S+')
# A "?" that ends a sentence: followed by space, end, or closing markup.
QUESTION_END = re.compile(r'\?(?=[\s*_)"\'\]]|$)')


def prose_lines(text):
    """The reply's lines a reader takes as the author's own prose.

    Fenced code, block quotes (a draft for someone else is shown quoted) and
    table rows are left out."""
    fenced = False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
            continue
        stripped = line.strip()
        if fenced or stripped.startswith('>') or stripped.startswith('|'):
            continue
        yield line


def question(text):
    """The first question the reply asks in prose, or None."""
    for line in prose_lines(text or ''):
        bare = URL.sub('', INLINE_CODE.sub('', line))
        match = QUESTION_END.search(bare)
        if match:
            sentence = re.split(r'(?<=[.!?:])\s+', bare[:match.end()].strip())[-1]
            sentence = sentence.strip('*_ ')
            return (sentence if len(sentence) <= QUOTE_LIMIT
                    else sentence[:QUOTE_LIMIT] + '…')
    return None


def block(asked):
    reason = (f'This reply holds a question in prose: "{asked}". '
              f"The user's rule: every choice, approval or question put to "
              f"the user goes through AskUserQuestion and ends the turn on "
              f"it, the recommended option first. If it asks the user "
              f"something, ask it now with AskUserQuestion, and drop the "
              f"prose question and any numbered list of options from the "
              f"reply. If it asks the user nothing, it is rhetorical: say it "
              f"as a statement, since a reply asks nothing in prose.")
    return {'decision': 'block', 'reason': reason}


def stop(payload):
    if payload.get('stop_hook_active'):
        return None
    asked = question(payload.get('last_assistant_message'))
    return block(asked) if asked else None


MODES = {'stop': stop}


def run(mode, stdin_text):
    """What the hook prints for this payload, or '' for nothing."""
    try:
        payload = json.loads(stdin_text)
    except ValueError:
        return ''
    if not isinstance(payload, dict):
        return ''
    out = MODES[mode](payload)
    return json.dumps(out) if out else ''


# ── Self-test ────────────────────────────────────────────────────────

SELF_TEST = Tap()


def check(name, expected, actual):
    return SELF_TEST.check(
        expected == actual, name,
        f'expected {expected!r}', f'got      {actual!r}')


def self_test():
    def decide(message, active=False):
        out = run('stop', json.dumps({'session_id': 's1',
                                      'stop_hook_active': active,
                                      'last_assistant_message': message}))
        return json.loads(out)['decision'] if out else None

    check('a reply with no question ends the turn', None,
          decide('ABC-1 is in CS Acceptance. Journal entry njkm.'))
    check('a closing "Shall I …?" is refused', 'block',
          decide('The draft is below.\n\nShall I post this as written? '
                 "Once it's up I'll link it."))
    check('a bold heading question over numbered options is refused', 'block',
          decide('**Which status should ABC-1 move to?**\n'
                 '1. CS Acceptance\n2. Done'))
    check('the refusal quotes the question and names the dialog',
          (True, True),
          (lambda o: ('Which status should ABC-1 move to?' in o,
                      'AskUserQuestion' in o))(
              run('stop', json.dumps({'last_assistant_message':
                                      '**Which status should ABC-1 move to?**'}))))
    check('a rhetorical question mid-reply is refused, its reason says to '
          'state it', (True, True),
          (lambda o: ('has the repo moved?' in o, 'as a statement' in o))(
              run('stop', json.dumps({'last_assistant_message':
                                      'It checks one thing: has the repo '
                                      'moved?\n\nThe run passed.'}))))
    check('a question inside fenced code is not asked', None,
          decide('Run this:\n```\nread -p "Continue?" x\n```\nDone.'))
    check('a question in inline code is not asked', None,
          decide('The prompt `Continue? [y/N]` is the script\'s own.'))
    check('a question in a block-quoted draft is not asked', None,
          decide('Posted:\n> Can someone look into this?\nDone.'))
    check('a question in a table row is not asked', None,
          decide('| Question | Answer |\n|---|---|\n| Empty list? | No |'))
    check('a URL query string is not a question', None,
          decide('Link: https://x.slack.com/archives/C1/p1?thread_ts=1.2&cid=C1'))
    check('once a stop hook is continuing the turn, it may end', None,
          decide('Shall I post it?', active=True))
    check('an unreadable payload blocks nothing', '', run('stop', 'not json'))
    check('a payload with no message blocks nothing', '',
          run('stop', json.dumps({'session_id': 's1'})))
    check('a long question is cut to its limit', QUOTE_LIMIT + 1,
          len(question('x' * 900 + '?')))
    return SELF_TEST.end()


def main(argv):
    if argv[1:] == ['--self-test']:
        return self_test()
    if len(argv) != 2 or argv[1] not in MODES:
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    out = run(argv[1], sys.stdin.read())
    if out:
        print(out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
