#!/usr/bin/env python3
"""guideline_gate.py — no code is edited before its guidelines are read in that session.

  guideline_gate.py read         # PostToolUse(Read): record a guidelines file read
  guideline_gate.py edit         # PreToolUse(Edit|Write|NotebookEdit): refuse an unread one
  guideline_gate.py clear        # SessionStart(compact), SessionEnd: forget the reads
  guideline_gate.py --self-test  # offline

The user's rule is that code is edited only after coding_guidelines.md,
style_guidelines.md and that language's <language>_coding_guidelines.md are
read. Read at session start as an instruction, it was often skipped, so the
harness enforces it here. ``read`` adds a guidelines file the Read tool
opened whole, with no offset or limit, to
``~/.claude/state/guidelines/<session_id>.json``. ``edit`` refuses an edit to
a file whose extension names a language with a guidelines file until the
three are in that record, and its reason names the ones still unread. ``clear`` removes the record when the session ends, and after a
compaction, since the summary no longer holds the text that was read.

A file of a language with no guidelines file, or with no extension, is not
gated. Each mode reads the hook payload on stdin and exits 0; a payload it
cannot read gates nothing, since a gate that failed closed would stop every
edit. GUIDELINE_GATE_DIR names another directory for the records, and
GUIDELINES_DIR another folder for the guidelines.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from tap import Tap

HOME = Path(__file__).resolve().parent.parent
ALWAYS = ('coding_guidelines.md', 'style_guidelines.md')
LANGUAGES = {
    'python': ('.py', '.pyi'),
    'shell': ('.sh', '.bash', '.zsh'),
    'javascript': ('.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx'),
    'ruby': ('.rb', '.rake', '.erb', '.gemspec'),
    'go': ('.go',),
    'csharp': ('.cs', '.csx'),
    'clojure': ('.clj', '.cljs', '.cljc', '.bb'),
    'haskell': ('.hs', '.lhs'),
    'dart': ('.dart',),
}
LANGUAGE_OF = {ext: lang for lang, exts in LANGUAGES.items() for ext in exts}


def guides_dir():
    return Path(os.environ.get('GUIDELINES_DIR', HOME))


def record_path(payload):
    """The session's record file, or None when the payload names no session."""
    default = HOME / 'state' / 'guidelines'
    session = str(payload.get('session_id') or '')
    if not session or '/' in session or session.startswith('.'):
        return None
    return Path(os.environ.get('GUIDELINE_GATE_DIR', default)) / f'{session}.json'


def path_of(payload):
    tool_input = payload.get('tool_input')
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    return str(tool_input.get('file_path') or tool_input.get('notebook_path') or '')


def needed(file_path):
    """The guidelines an edit to this file needs, or () when it is not gated."""
    lang = LANGUAGE_OF.get(Path(file_path).suffix.lower())
    guide = f'{lang}_coding_guidelines.md'
    if not lang or not (guides_dir() / guide).is_file():
        return ()
    return (*ALWAYS, guide)


def recorded(path):
    try:
        names = json.loads(path.read_text())
    except (OSError, ValueError):
        return set()
    return set(names) if isinstance(names, list) else set()


def whole(payload):
    """True when the Read covered the whole file: no offset and no limit."""
    tool_input = payload.get('tool_input')
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    return not tool_input.get('offset') and not tool_input.get('limit')


def read(payload):
    path, name = record_path(payload), path_of(payload)
    if not path or not name or not whole(payload):
        return None
    opened = Path(name).expanduser()
    if opened.name.endswith('guidelines.md') and opened.parent.resolve() == guides_dir().resolve():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(sorted(recorded(path) | {opened.name})))
    return None


def edit(payload):
    path, name = record_path(payload), path_of(payload)
    unread = [g for g in needed(name) if g not in recorded(path)] if path else []
    if not unread:
        return None
    files = ', '.join(str(guides_dir() / g) for g in unread)
    reason = (f'Read {files} with the Read tool before editing {name}: the '
              f"user's rule is that code is edited only after its guidelines "
              f'are read in this session. Then make this edit again.')
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                                   'permissionDecision': 'deny',
                                   'permissionDecisionReason': reason}}


def clear(payload):
    path = record_path(payload)
    if path:
        path.unlink(missing_ok=True)
    return None


MODES = {'read': read, 'edit': edit, 'clear': clear}


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

def self_test_call(mode, session='s1', **tool_input):
    return run(mode, json.dumps({'session_id': session, 'tool_input': tool_input}))


def self_test_denied(out):
    return bool(out) and json.loads(out)['hookSpecificOutput']['permissionDecision'] == 'deny'


def self_test():
    t = Tap()
    with tempfile.TemporaryDirectory() as tmp:
        guides, state = Path(tmp) / 'g', Path(tmp) / 's' / 'deep'
        guides.mkdir()
        for name in (*ALWAYS, 'python_coding_guidelines.md', 'shell_coding_guidelines.md'):
            (guides / name).write_text('x\n')
        os.environ['GUIDELINES_DIR'], os.environ['GUIDELINE_GATE_DIR'] = str(guides), str(state)
        self_test_edits(t, guides, state)
        self_test_payloads(t, guides, state)
        self_test_main(t)
    return t.end()


def self_test_edits(t, guides, state):
    call, denied = self_test_call, self_test_denied
    out = call('edit', file_path='/w/a.py')
    t.check(denied(out) and all(g in out for g in (*ALWAYS, 'python_coding_guidelines.md')),
            'a Python edit with nothing read is refused, naming the three files to read', out)
    call('read', file_path=str(guides / 'coding_guidelines.md'))
    call('read', file_path=str(guides / 'style_guidelines.md'))
    call('read', file_path=str(guides / 'python_coding_guidelines.md'), limit=1)
    call('read', file_path=str(guides / 'python_coding_guidelines.md'), offset=5)
    out = call('edit', file_path='/w/a.py')
    t.check(denied(out) and 'python_coding_guidelines.md' in out and 'style_guidelines.md' not in out,
            'a read with a limit or an offset is no read, and the refusal names only the files still unread', out)
    call('read', file_path=str(guides / 'python_coding_guidelines.md'))
    t.check(call('edit', file_path='/w/a.py') == '', 'once all three are read, the edit runs')
    t.check(call('edit', file_path='/w/B.PY') == '', 'an extension is matched in any case')
    t.check(denied(call('edit', file_path='/w/run.sh')), 'another language needs its own file read')
    t.check(call('edit', file_path='/w/notes.md') == '' and call('edit', file_path='/w/Makefile') == '',
            'prose and a file with no extension are not gated')
    t.check(call('edit', file_path='/w/main.go') == '' and call('edit', file_path='/w/Main.java') == '',
            'a language whose guidelines file is missing, or that has none, is not gated')
    t.check(denied(call('edit', session='nb', notebook_path='/w/n.py')), 'a notebook edit is matched by its path')
    t.check(denied(call('edit', session='s2', file_path='/w/a.py')), 'what one session read does not open another')
    call('read', file_path=str(guides.parent / 'coding_guidelines.md'), session='s3')
    call('read', file_path=str(guides / 'README.md'), session='s3')
    t.check(not (state / 's3.json').exists(), 'a file of the same name elsewhere, or another file, is no read')
    call('clear')
    t.check(call('clear', session='none') == '', 'clearing a session with no record does nothing')
    t.check(denied(call('edit', file_path='/w/a.py')), 'after a compaction or the session end, the reads are forgotten')


def self_test_payloads(t, guides, state):
    call, denied = self_test_call, self_test_denied
    t.check(run('edit', 'not json') == '' and run('edit', '[1]') == '' and call('edit', session='', file_path='/w/a.py') == '',
            'an unreadable payload, or one naming no session, gates nothing')
    t.check(all(call('edit', session=bad, file_path='/w/a.py') == '' for bad in ('a/b', '.hidden')),
            'a session id that could name another path gates nothing')
    t.check(call('read', session='', file_path=str(guides / 'coding_guidelines.md')) == '',
            'a read naming no session records nothing')
    t.check(call('read', file_path='') == '', 'a read naming no file records nothing')
    (state / 's4.json').write_text('{')
    t.check(denied(call('edit', session='s4', file_path='/w/a.py')), 'an unreadable record counts as nothing read')
    (state / 's5.json').write_text('{"a": 1}')
    t.check(denied(call('edit', session='s5', file_path='/w/a.py')), 'a record that is not a list counts as nothing read')


def self_test_main(t):
    def status(*args, stdin='{}'):
        return subprocess.run([sys.executable, __file__, *args], input=stdin, capture_output=True, text=True).returncode
    t.check(status('edit') == 0, 'a known mode reads its payload and exits 0')
    t.check(status() == 2 and status('nope') == 2 and status('edit', 'extra') == 2,
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
