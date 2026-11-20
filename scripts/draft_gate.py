#!/usr/bin/env python3
"""draft_gate.py — no text is sent to people before its writing skill is loaded in that session.

  draft_gate.py loaded                # PostToolUse(Skill): record the skill loaded
  draft_gate.py clear                 # SessionStart(compact), SessionEnd: forget the loads
  draft_gate.py check <skill>...      # a writer, before it sends
  draft_gate.py post                  # retired PreToolUse(Bash) mode: exits 0
  draft_gate.py --self-test           # offline

Text a person reads is written with the draft skill, a reference page with
draft or normative. Stated only as an instruction, the load was often
skipped, so the writers enforce it here. ``loaded`` adds the skill the Skill
tool loaded to ``~/.claude/state/draft/<session_id>.json``. ``clear``
removes that record when the session ends, and after a compaction, since the
summary no longer holds the skill's text.

``check`` is run by each writer just before it sends, so a script that calls
a writer is held too. It exits 0 when the session in CLAUDE_CODE_SESSION_ID
has loaded one of the skills named, or when no Claude session is running the
writer. Otherwise it exits 1 and says on stderr which skill to load.

``loaded`` and ``clear`` read the hook payload on stdin and exit 0; a
payload they cannot read records nothing. ``post`` exits 0 without reading:
a session started while settings.json still ran it keeps that hook until it
ends, and a failing hook would block its every Bash call. DRAFT_GATE_DIR names another
directory for the records.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from tap import Tap

HOME = Path(__file__).resolve().parent.parent
SESSION_VAR = 'CLAUDE_CODE_SESSION_ID'


def record_path(session):
    """The session's record file, or None when the id names no session."""
    default = HOME / 'state' / 'draft'
    session = str(session or '')
    if not session or '/' in session or session.startswith('.'):
        return None
    return Path(os.environ.get('DRAFT_GATE_DIR', default)) / f'{session}.json'


def recorded(path):
    try:
        names = json.loads(path.read_text())
    except (OSError, ValueError):
        return set()
    return set(names) if isinstance(names, list) else set()


# ── Hook modes ───────────────────────────────────────────────────────

def loaded(payload):
    path = record_path(payload.get('session_id'))
    given = payload.get('tool_input')
    skill = given.get('skill') if isinstance(given, dict) else None
    if path and isinstance(skill, str) and skill:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(sorted(recorded(path) | {skill})))


def clear(payload):
    path = record_path(payload.get('session_id'))
    if path:
        path.unlink(missing_ok=True)


HOOKS = {'loaded': loaded, 'clear': clear}


def run_hook(mode, stdin_text):
    try:
        payload = json.loads(stdin_text)
    except ValueError:
        return
    if isinstance(payload, dict):
        HOOKS[mode](payload)


# ── Writer check ─────────────────────────────────────────────────────

def refusal(skills):
    """Why the send is refused, or None when it may go."""
    path = record_path(os.environ.get(SESSION_VAR))
    if not path or recorded(path) & set(skills):
        return None
    names = ' or '.join(skills)
    return (f'draft_gate: load the {names} skill with the Skill tool and check '
            f'this text against it before sending; nothing was sent.')


def check(skills):
    reason = refusal(skills)
    if reason:
        print(reason, file=sys.stderr)
        return 1
    return 0


# ── Self-test ────────────────────────────────────────────────────────

def self_test_hook(mode, session='s1', **given):
    run_hook(mode, json.dumps({'session_id': session, 'tool_input': given}))


def self_test_check(session, *skills):
    os.environ[SESSION_VAR] = session
    return refusal(skills)


def self_test():
    t = Tap()
    saved = os.environ.get(SESSION_VAR)
    with tempfile.TemporaryDirectory() as tmp:
        os.environ['DRAFT_GATE_DIR'] = str(Path(tmp) / 'deep' / 'state')
        self_test_records(t)
        self_test_payloads(t, Path(tmp) / 'deep' / 'state')
        self_test_main(t)
    if saved is None:
        os.environ.pop(SESSION_VAR, None)
    else:
        os.environ[SESSION_VAR] = saved
    return t.end()


def self_test_records(t):
    hook, refused = self_test_hook, self_test_check
    out = refused('s1', 'draft')
    t.check(bool(out) and 'draft' in out and 'nothing was sent' in out,
            'a send with nothing loaded is refused, naming the skill', out)
    hook('loaded', skill='review:pr')
    t.check(bool(refused('s1', 'draft')), 'loading another skill does not open the gate')
    hook('loaded', skill='draft')
    t.check(refused('s1', 'draft') is None, 'once draft is loaded, the send goes')
    t.check(refused('s1', 'review:pr') is None, 'every skill loaded stays recorded')
    t.check(bool(refused('s2', 'draft')), 'what one session loaded does not open another')
    hook('loaded', session='s2', skill='normative')
    out = refused('s2', 'draft')
    t.check(bool(out) and 'draft skill' in out, 'a writer that accepts only draft refuses normative')
    t.check(refused('s2', 'draft', 'normative') is None and 'draft or normative' in refused('s3', 'draft', 'normative'),
            'a writer that accepts either goes on either, and names both when refusing')
    t.check(refused('', 'draft') is None, 'outside a Claude session nothing is gated')
    t.check(refused('a/b', 'draft') is None and refused('.hidden', 'draft') is None,
            'a session id that could name another path gates nothing')
    hook('clear')
    hook('clear', session='none')
    t.check(bool(refused('s1', 'draft')), 'after a compaction or the session end, the loads are forgotten')


def self_test_payloads(t, state):
    hook = self_test_hook
    run_hook('loaded', 'not json')
    run_hook('loaded', '[1]')
    run_hook('loaded', json.dumps({'session_id': 's4', 'tool_input': 'x'}))
    hook('loaded', session='s4', skill='')
    hook('loaded', session='', skill='draft')
    t.check(not (state / 's4.json').exists() and not (state / '.json').exists(),
            'an unreadable payload, a missing skill or a missing session records nothing')
    (state / 's5.json').write_text('{')
    t.check(bool(self_test_check('s5', 'draft')), 'an unreadable record counts as nothing loaded')
    (state / 's6.json').write_text('{"a": 1}')
    t.check(bool(self_test_check('s6', 'draft')), 'a record that is not a list counts as nothing loaded')


def self_test_main(t):
    def status(*args, stdin='{}', session='s9'):
        env = {**os.environ, SESSION_VAR: session}
        return subprocess.run([sys.executable, __file__, *args], input=stdin, env=env,
                              capture_output=True, text=True).returncode
    t.check(status('loaded') == 0 and status('clear') == 0, 'a hook mode reads its payload and exits 0')
    t.check(status('post') == 0 and status('post', 'x') == 2, 'the retired post mode exits 0 and takes no arguments')
    t.check(status('check', 'draft') == 1 and status('check', 'draft', session='') == 0,
            'check exits 1 when refused and 0 when it may send')
    t.check(status() == 2 and status('nope') == 2 and status('loaded', 'x') == 2 and status('check') == 2,
            'no mode, an unknown one, a hook mode with arguments, or check with no skill is a usage error')


def main(argv):
    mode, rest = (argv[1], argv[2:]) if len(argv) > 1 else ('', [])
    if mode == '--self-test' and not rest:
        return self_test()
    if mode == 'check' and rest:
        return check(rest)
    if mode in HOOKS and not rest:
        run_hook(mode, sys.stdin.read())
        return 0
    if mode == 'post' and not rest:
        return 0
    print(__doc__.split('\n\n')[0], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
