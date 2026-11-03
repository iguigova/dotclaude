#!/usr/bin/env python3
"""block_gate.py — once auto mode blocks a call, no other tool runs until the user answers.

  block_gate.py denied        # PermissionDenied hook: record the blocked call
  block_gate.py gate          # PreToolUse hook: refuse every call while one is recorded
  block_gate.py clear         # UserPromptSubmit, PostToolUse(AskUserQuestion), SessionEnd
  block_gate.py --self-test   # offline

The user's rule is that a blocked call is a question: the turn ends on it,
before any other work. A rule read at session start loses to the denial's own
text, which says to carry on with whatever does not depend on the call. So the
harness enforces it here. ``denied`` writes the blocked call to
``~/.claude/state/blocked/<session_id>.json``. While that file exists, ``gate``
denies every tool call but ``AskUserQuestion``, and its reason tells the model
to end the turn asking for the grant. ``clear`` removes the file when the user
replies, answers that question, or the session ends.

Each mode reads the hook payload on stdin and exits 0. A payload it cannot
read gates nothing: a gate that failed closed would stop the whole session.
The ``PermissionDenied`` event fires for auto-mode denials only
(https://code.claude.com/docs/en/hooks#permissiondenied), so a deny rule, a
sandbox refusal or a 403 still rests on the rule in ``CLAUDE.md``.
BLOCK_GATE_DIR names another directory for the records.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

from tap import Tap

ASKS = {'AskUserQuestion'}
SUMMARY_LIMIT = 300


def record_dir():
    default = Path(__file__).resolve().parent.parent / 'state' / 'blocked'
    return Path(os.environ.get('BLOCK_GATE_DIR', default))


def record_path(payload):
    """The session's record file, or None when the payload names no session."""
    session = str(payload.get('session_id') or '')
    if not session or '/' in session or session.startswith('.'):
        return None
    return record_dir() / f'{session}.json'


def summary(tool_input):
    """What the blocked call was, in the words a person would grant."""
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    text = (tool_input.get('command') or tool_input.get('url')
            or tool_input.get('file_path') or json.dumps(tool_input))
    text = ' '.join(str(text).split())
    return text if len(text) <= SUMMARY_LIMIT else text[:SUMMARY_LIMIT] + '…'


def record(payload):
    return {'tool': payload.get('tool_name') or '?',
            'call': summary(payload.get('tool_input')),
            'reason': payload.get('reason') or 'no reason given'}


def denial(blocked):
    """The PreToolUse output that refuses a call while ``blocked`` stands."""
    reason = (f"Auto mode blocked {blocked['tool']} ({blocked['reason']}): "
              f"{blocked['call']}. The user's rule: a blocked call is a "
              f"question, never a skip. End this turn now on that question: "
              f"name the blocked call, why the task needs it, and how to "
              f"grant it (approve it on retry, a permission rule, or "
              f"`! <command>`). Every other tool call is refused until the "
              f"user replies; AskUserQuestion still runs.")
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                                   'permissionDecision': 'deny',
                                   'permissionDecisionReason': reason}}


def denied(payload):
    path = record_path(payload)
    if path is None:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record(payload)))
    return None


def gate(payload):
    path = record_path(payload)
    if path is None or payload.get('tool_name') in ASKS:
        return None
    try:
        blocked = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return denial(blocked)


def clear(payload):
    path = record_path(payload)
    if path is not None:
        path.unlink(missing_ok=True)
    return None


MODES = {'denied': denied, 'gate': gate, 'clear': clear}


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
    with tempfile.TemporaryDirectory() as tmp:
        os.environ['BLOCK_GATE_DIR'] = tmp
        blocked = json.dumps({'session_id': 's1', 'tool_name': 'Bash',
                              'tool_input': {'command': 'slack_post.py post U1 f.md'},
                              'reason': '[External System Writes]'})

        def call(tool, session='s1'):
            return json.dumps({'session_id': session, 'tool_name': tool})

        def decision(out):
            return json.loads(out)['hookSpecificOutput']['permissionDecision'] if out else None

        check('no record, nothing gated', None,
              decision(run('gate', call('Bash'))))
        run('denied', blocked)
        after = run('gate', call('Read'))
        check('after a block, the next call is refused', 'deny', decision(after))
        check('the refusal names the blocked call and the rule',
              (True, True),
              ('slack_post.py post U1 f.md' in after,
               'End this turn now' in after))
        check('the question tool still runs', None,
              decision(run('gate', call('AskUserQuestion'))))
        check('another session is not gated', None,
              decision(run('gate', call('Bash', 's2'))))
        run('clear', call('AskUserQuestion'))
        check('once the user answers, calls run again', None,
              decision(run('gate', call('Bash'))))
        check('clearing twice is harmless', '', run('clear', call('x')))
        check('an unreadable payload gates nothing', '', run('gate', 'not json'))
        check('a payload with no session gates nothing', '',
              run('gate', json.dumps({'tool_name': 'Bash'})))
        check('a session id cannot name a path outside the records', None,
              record_path({'session_id': '../x'}))
        check('a long call is cut to its limit',
              SUMMARY_LIMIT + 1, len(summary({'command': 'x' * 900})))
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
