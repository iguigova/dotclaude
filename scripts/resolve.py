#!/usr/bin/env python3
"""A project's folder, value, script, clone, file or secret, for a Python script.

Each is read through the shell resolvers, ~/.claude/scripts/project_file.sh
and secret_file.sh, so a Python script finds a name exactly as a shell one
does. A name the project lacks ends the run, exit 1, with the resolver's own
message naming where it looked; root() answers None at a folder with no
project.

Usage:
    resolve.py --self-test

    sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
    from resolve import root, value, script, clone, clones, module, project_path, secret_path

module(name) imports the Python library name.py found as script() finds it,
the project's over the global one, once per process.
"""

import functools
import importlib.util
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


@functools.cache
def module(name):
    """The library name.py, resolved as a script is, imported under its own name."""
    spec = importlib.util.spec_from_file_location(name, script(f'{name}.py'))
    found = importlib.util.module_from_spec(spec)
    sys.modules[name] = found
    spec.loader.exec_module(found)
    return found


def clone(name):
    """The folder of the clone the project's .claude/clones lists as name."""
    return resolved(PROJECT_FILE, '--clone', name)


def clones():
    """Each clone the project's .claude/clones lists, its name to its folder, cloned or not."""
    rows = resolved(PROJECT_FILE, '--clones').splitlines()
    return {name: folder for name, folder, _ in (row.split('\t') for row in rows)}


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
    subprocess.run(('git', 'init', '-q', os.path.join(fx, 'clone')), check=True)
    subprocess.run(('git', '-C', os.path.join(fx, 'clone'), 'remote', 'add', 'origin', 'git@h:o/clone.git'),
                   check=True)
    with open(os.path.join(fx, '.claude', 'clones'), 'w') as f:
        f.write('clone clone git@h:o/clone.git\n')
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
        with open(os.path.join(fx, '.claude', 'scripts', 'mine.py'), 'w') as f:
            f.write('WHO = "project"\n')
        t.check(module('mine').WHO == 'project' and sys.modules['mine'] is module('mine'),
                "a library resolves as a script does, imported once under its own name")
        t.check(module('group_run').__file__ == os.path.join(RESOLVERS, 'group_run.py'),
                'a library the project lacks is the global one')
        t.check(clone('clone') == os.path.join(fx, 'clone'), 'a clone resolves to its folder by name')
        with open(os.path.join(fx, '.claude', 'clones'), 'a') as f:
            f.write('gone api/gone git@h:o/gone.git\n')
        t.check(clones() == {'clone': os.path.join(fx, 'clone'), 'gone': os.path.join(fx, 'api', 'gone')},
                'every listed clone maps its name to its folder, cloned or not')
        t.check(project_path('colour') == os.path.join(fx, '.claude', 'colour'), 'a file resolves to its path')
        t.check(secret_path('token') == os.path.join(fx, '.secrets', 'token'), 'a secret resolves to its path')
        t.check(resolved('echo', 'yes') == 'yes', 'a resolver answer is returned, stripped')
        for call, label in ((lambda: script('nonesuch.sh'), 'a missing script'),
                            (lambda: value('nonesuch'), 'a missing value'),
                            (lambda: clone('nonesuch'), 'an unlisted clone')):
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
