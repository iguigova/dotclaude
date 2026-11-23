#!/usr/bin/env python3
"""hook_lib.py — what the hook gates share: a session's record file and a payload's dispatch.

Usage:
    hook_lib.py --help
    hook_lib.py --self-test

    from hook_lib import record_file, recorded, dispatch

record_file(directory, session) is the session's record, <directory>/<session>.json,
or None when the id is empty or could name another path. recorded(path) is
the set of names a record lists, empty when it is missing, unreadable or not
a list. dispatch(modes, mode, stdin_text) runs modes[mode] on the hook payload
and returns what the hook prints, its JSON, or '' for nothing. A payload that
is not a JSON object gates nothing, since a gate that failed closed would stop
every call.
"""
import json
import sys
import tempfile
from pathlib import Path

from tap import Tap


def record_file(directory, session):
    """The session's record file, or None when the id names no session."""
    session = str(session or '')
    if not session or '/' in session or session.startswith('.'):
        return None
    return Path(directory) / f'{session}.json'


def recorded(path):
    """The names a record lists; nothing when it cannot be read as a list."""
    try:
        names = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return set()
    return set(names) if isinstance(names, list) else set()


def dispatch(modes, mode, stdin_text):
    """What the hook prints for this payload, or '' for nothing."""
    try:
        payload = json.loads(stdin_text)
    except ValueError:
        return ''
    if not isinstance(payload, dict):
        return ''
    out = modes[mode](payload)
    return json.dumps(out) if out else ''


def self_test():
    t = Tap()
    t.check(record_file('/d', 's1') == Path('/d/s1.json'), 'a session id names its record')
    t.check(all(record_file('/d', bad) is None for bad in ('', None, 'a/b', '.x')),
            'an empty id, or one that could name another path, names no record')
    with tempfile.TemporaryDirectory() as tmp:
        good, bad, other = Path(tmp) / 'g.json', Path(tmp) / 'b.json', Path(tmp) / 'o.json'
        good.write_text('["a", "b"]')
        bad.write_text('{')
        other.write_text('{"a": 1}')
        t.check(recorded(good) == {'a', 'b'}, 'a record lists its names')
        t.check(recorded(bad) == set() and recorded(other) == set() and recorded(Path(tmp) / 'none') == set(),
                'an unreadable record, one that is not a list, or none at all lists nothing')
    modes = {'echo': lambda p: {'got': p['x']}, 'quiet': lambda p: None}
    t.check(dispatch(modes, 'echo', '{"x": 1}') == '{"got": 1}', 'a mode answers with JSON')
    t.check(dispatch(modes, 'quiet', '{"x": 1}') == '', 'a mode with nothing to say prints nothing')
    t.check(dispatch(modes, 'echo', 'not json') == '' and dispatch(modes, 'echo', '[1]') == '',
            'a payload that is not a JSON object gates nothing')
    return t.end()


if __name__ == '__main__':
    if sys.argv[1:2] in (['-h'], ['--help']):
        print(__doc__.strip())
        sys.exit(0)
    if sys.argv[1:] == ['--self-test']:
        sys.exit(self_test())
    print('hook_lib.py: import it; run, it takes only --help or --self-test', file=sys.stderr)
    sys.exit(2)
