#!/usr/bin/env python3
"""A project's folder, value, script, file or secret, for a Python script.

Each is read through the shell resolvers, ~/.claude/scripts/project_file.sh
and secret_file.sh, so a Python script finds a name exactly as a shell one
does. A name the project lacks ends the run, exit 1, with the resolver's own
message naming where it looked; root() answers None at a folder with no
project.

Usage:
    resolve.py --self-test

    sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
    from resolve import root, value, script, project_path, secret_path
"""

import functools
import os
import subprocess
import sys

RESOLVERS = os.path.expanduser('~/.claude/scripts')
PROJECT_FILE = os.path.join(RESOLVERS, 'project_file.sh')
SECRET_FILE = os.path.join(RESOLVERS, 'secret_file.sh')


def resolved(*command):
    """What a resolver prints; its refusal ends the run, exit 1."""
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(result.stderr.strip()
                 or f'{" ".join(command)} exited {result.returncode}')
    return result.stdout.strip()


def root(start='.'):
    """The folder of the project start lies in, or None when it lies in none."""
    result = subprocess.run((PROJECT_FILE, '--root'), cwd=start,
                            capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


@functools.cache
def value(name):
    return resolved(PROJECT_FILE, '--value', name)


@functools.cache
def script(name):
    return resolved(PROJECT_FILE, '--script', name)


def project_path(name):
    return resolved(PROJECT_FILE, name)


def secret_path(name):
    return resolved(SECRET_FILE, name)


def self_test():
    import shutil
    import tempfile
    sys.path.insert(0, RESOLVERS)
    from tap import Tap
    t = Tap()
    fx = tempfile.mkdtemp()
    os.makedirs(os.path.join(fx, '.claude', 'scripts'))
    os.makedirs(os.path.join(fx, '.secrets'))
    os.makedirs(os.path.join(fx, 'clone', '.claude'))
    with open(os.path.join(fx, '.claude', 'project'), 'w') as f:
        f.write('p\n')
    open(os.path.join(fx, '.claude', 'session_history.md'), 'w').close()
    with open(os.path.join(fx, '.claude', 'colour'), 'w') as f:
        f.write('# the colour\nteal\n')
    with open(os.path.join(fx, '.secrets', 'token'), 'w') as f:
        f.write('t0k3n\n')
    mine = os.path.join(fx, '.claude', 'scripts', 'tap.py')
    with open(mine, 'w') as f:
        f.write('')
    here = os.getcwd()
    try:
        os.chdir(fx)
        t.check(root('clone') == fx, 'the project is found from a clone below it')
        t.check(root(os.path.dirname(fx)) is None, 'a folder holding the project lies in none')
        t.check(value('colour') == 'teal', 'a value is its file, comments dropped')
        t.check(script('tap.py') == mine, "the project's script wins over the global one")
        t.check(script('resolve.py') == os.path.join(RESOLVERS, 'resolve.py'),
                'a script the project lacks is the global one')
        t.check(project_path('colour') == os.path.join(fx, '.claude', 'colour'), 'a file resolves to its path')
        t.check(secret_path('token') == os.path.join(fx, '.secrets', 'token'), 'a secret resolves to its path')
        t.check(resolved('echo', 'yes') == 'yes', 'a resolver answer is returned, stripped')
        for call, label in ((lambda: script('nonesuch.sh'), 'a missing script'),
                            (lambda: value('nonesuch'), 'a missing value')):
            try:
                call()
                t.check(False, f'{label} ends the run, naming it')
            except SystemExit as stop:
                t.check('nonesuch' in str(stop.code), f'{label} ends the run, naming it', str(stop.code))
        try:
            resolved('false')
            t.check(False, 'a silent refusal names the command')
        except SystemExit as stop:
            t.check(stop.code == 'false exited 1', 'a silent refusal names the command', str(stop.code))
    finally:
        os.chdir(here)
        shutil.rmtree(fx)
    return t.end()


def main(args):
    if args == ['--self-test']:
        return self_test()
    print(__doc__)
    return 0 if args in (['-h'], ['--help']) else 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
