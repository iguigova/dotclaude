#!/usr/bin/env python3
"""draft_gate.py — no PR review is posted before the draft skill is loaded in that session.

  draft_gate.py loaded       # PostToolUse(Skill): record that draft was loaded
  draft_gate.py post         # PreToolUse(Bash): refuse a review post until it was
  draft_gate.py clear        # SessionStart(compact), SessionEnd: forget the load
  draft_gate.py --self-test  # offline

/review:pr writes text a colleague reads, so it is written with the draft
skill. Stated only as an instruction, the load was often skipped, so the
harness enforces it here. ``loaded`` creates
``~/.claude/state/draft/<session_id>`` when the Skill tool loads ``draft``.
``post`` refuses a Bash command with a segment that runs
gh-pr-review-post.sh with ``--body-file`` and without ``--dry-run`` until
that file exists. ``clear`` removes it when the session ends, and after a
compaction, since the summary no longer holds the skill's text.

Each mode reads the hook payload on stdin and exits 0; a payload it cannot
read gates nothing, since a gate that failed closed would stop every command.
DRAFT_GATE_DIR names another directory for the records.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from tap import Tap

HOME = Path(__file__).resolve().parent.parent
SKILL = 'draft'
POSTER = 'gh-pr-review-post.sh'
SEGMENT_BREAK = re.compile(r'&&|\|\||[;|\n]')


def record_path(payload):
    """The session's record file, or None when the payload names no session."""
    default = HOME / 'state' / 'draft'
    session = str(payload.get('session_id') or '')
    if not session or '/' in session or session.startswith('.'):
        return None
    return Path(os.environ.get('DRAFT_GATE_DIR', default)) / session


def tool_input(payload):
    found = payload.get('tool_input')
    return found if isinstance(found, dict) else {}


def posts(segment):
    """True when this shell segment posts a review rather than validating one."""
    return POSTER in segment and '--body-file' in segment and '--dry-run' not in segment


def posts_review(command):
    return any(posts(segment) for segment in SEGMENT_BREAK.split(command))


def loaded(payload):
    path = record_path(payload)
    if path and tool_input(payload).get('skill') == SKILL:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    return None


def post(payload):
    path = record_path(payload)
    command = str(tool_input(payload).get('command') or '')
    if not path or path.exists() or not posts_review(command):
        return None
    reason = (f'Load the {SKILL} skill with the Skill tool and check the review '
              f'body and every inline comment and reply against it before posting: '
              f'what /review:pr posts is written with {SKILL}. Then post again.')
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                                   'permissionDecision': 'deny',
                                   'permissionDecisionReason': reason}}


def clear(payload):
    path = record_path(payload)
    if path:
        path.unlink(missing_ok=True)
    return None


MODES = {'loaded': loaded, 'post': post, 'clear': clear}


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

def self_test_call(mode, session='s1', **given):
    return run(mode, json.dumps({'session_id': session, 'tool_input': given}))


def self_test_denied(out):
    return bool(out) and json.loads(out)['hookSpecificOutput']['permissionDecision'] == 'deny'


def self_test():
    t = Tap()
    with tempfile.TemporaryDirectory() as tmp:
        os.environ['DRAFT_GATE_DIR'] = str(Path(tmp) / 'deep' / 'state')
        self_test_commands(t)
        self_test_records(t)
        self_test_payloads(t)
        self_test_main(t)
    return t.end()


def self_test_commands(t):
    call, denied = self_test_call, self_test_denied
    real = f'D=/w; ~/.claude/scripts/{POSTER} o/r#1 --event COMMENT --body-file "$D/b.md"'
    out = call('post', command=real)
    t.check(denied(out) and SKILL in out, 'a review post with draft not loaded is refused, naming the skill', out)
    t.check(call('post', command=real + ' --dry-run') == '', 'a dry run is not a post and runs')
    t.check(denied(call('post', command=f'{real} --dry-run && {real}')),
            'a dry run chained before a real post does not let the post through')
    t.check(call('post', command=f'{POSTER} --help') == '' and call('post', command=f'grep body-file {POSTER}; ls') == '',
            'help, and a command that only names the script, run')
    t.check(call('post', command='gh pr comment 1 --body-file b.md') == '', 'another writer is not gated')


def self_test_records(t):
    call, denied = self_test_call, self_test_denied
    real = f'{POSTER} o/r#1 --event APPROVE --body-file b.md'
    call('loaded', skill='review:pr')
    t.check(denied(call('post', command=real)), 'loading another skill does not open the gate')
    call('loaded', skill=SKILL)
    t.check(call('post', command=real) == '', 'once draft is loaded, the post runs')
    t.check(denied(call('post', session='s2', command=real)), 'what one session loaded does not open another')
    call('loaded', session='s2', skill=SKILL)
    t.check(call('post', session='s2', command=real) == '', 'a second session records its load beside the first')
    call('clear')
    t.check(call('clear', session='none') == '', 'clearing a session with no record does nothing')
    t.check(denied(call('post', command=real)), 'after a compaction or the session end, the load is forgotten')


def self_test_payloads(t):
    call = self_test_call
    real = f'{POSTER} o/r#1 --event COMMENT --body-file b.md'
    t.check(run('post', 'not json') == '' and run('post', '[1]') == '' and call('post', session='', command=real) == '',
            'an unreadable payload, or one naming no session, gates nothing')
    t.check(all(call('post', session=bad, command=real) == '' for bad in ('a/b', '.hidden')),
            'a session id that could name another path gates nothing')
    t.check(run('post', json.dumps({'session_id': 's9', 'tool_input': 'x'})) == '',
            'a tool input that is not an object gates nothing')


def self_test_main(t):
    def status(*args, stdin='{}'):
        return subprocess.run([sys.executable, __file__, *args], input=stdin, capture_output=True, text=True).returncode
    t.check(status('post') == 0, 'a known mode reads its payload and exits 0')
    t.check(status() == 2 and status('nope') == 2 and status('post', 'extra') == 2,
            'no mode, an unknown one, or one too many arguments is a usage error')


def main(argv):
    if argv[1:] == ['--self-test']:
        return self_test()
    if len(argv) != 2 or argv[1] not in MODES:
        print(__doc__.split('\n\n')[0], file=sys.stderr)
        return 2
    out = run(argv[1], sys.stdin.read())
    if out:
        print(out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
