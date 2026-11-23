#!/usr/bin/env python3
"""hook_list.py — the hooks settings.json runs, each said in its script's own words.

Usage:
    hook_list.py                     # print the list
    hook_list.py --check <doc>       # exit 1 when the doc's list is not the list
    hook_list.py --write <doc>       # put the list in the doc
    hook_list.py --help
    hook_list.py --self-test

One line per script a hook runs: the script, each event it runs on with the
matcher and the arguments that event passes, and the first sentence of the
script's own header, less a leading "<script> — ". The doc holds the list between the lines
<!-- hooks:begin --> and <!-- hooks:end -->, so what a page says a gate does is
what the gate says it does, and selftest.sh refuses a page that has drifted.

The tree is the doc's folder: its settings.json and its scripts/. With no
doc, it is the folder above this script. A command that names no script under
$HOME/.claude/scripts/ is listed as it is written.

Exit 0 listed, written or in step; 1 the doc has drifted, or holds no markers;
2 usage.
"""
import ast
import contextlib
import json
import re
import sys
import tempfile
from pathlib import Path

from tap import Tap

TREE = Path(__file__).resolve().parent.parent
BEGIN, END = '<!-- hooks:begin -->', '<!-- hooks:end -->'
SCRIPT_RE = re.compile(r'^\$HOME/\.claude/scripts/(\S+)\s*(.*)$')


def runs(settings):
    """(script, event, matcher, args) for every hook command, in file order."""
    for event, entries in settings.get('hooks', {}).items():
        for entry in entries:
            for hook in entry.get('hooks', []):
                command = hook.get('command', '')
                m = SCRIPT_RE.match(command)
                script, args = (m.group(1), m.group(2)) if m else (command, '')
                yield script, event, entry.get('matcher', ''), args


def header(path):
    """A script's header: its docstring, or its comment lines after the shebang."""
    text = path.read_text()
    if path.suffix == '.py':
        return ast.get_docstring(ast.parse(text)) or ''
    lines = text.split('\n')[1:]
    comments = [ln for ln in lines[:next((i for i, ln in enumerate(lines) if not ln.startswith('#')), len(lines))]]
    return '\n'.join(re.sub(r'^# ?', '', ln) for ln in comments)


def summary(path):
    """The first sentence of a script's header, less a leading '<script> — '."""
    paragraph = ' '.join(header(path).split('\n\n')[0].split())
    sentence = re.match(r'(.*?[.!?])(\s|$)', paragraph)
    said = sentence.group(1) if sentence else paragraph
    return re.sub(r'^' + re.escape(path.name) + r' — ', '', said)


def when(event, matcher, args):
    """One event a script runs on: its matcher in brackets, then its arguments."""
    return ' '.join(p for p in (f'{event}[{matcher}]' if matcher else event, args) if p)


def listing(tree):
    """The markdown list, one line per script, in the order settings.json first names them."""
    settings = json.loads((tree / 'settings.json').read_text())
    order, events = [], {}
    for script, event, matcher, args in runs(settings):
        if script not in events:
            order.append(script)
            events[script] = []
        events[script].append(when(event, matcher, args))
    lines = []
    for script in order:
        path = tree / 'scripts' / script
        said = summary(path) if path.is_file() else 'no such script'
        lines.append(f'- `scripts/{script}` ({"; ".join(events[script])}): {said}')
    return '\n'.join(lines)


def block_of(doc):
    """The text between the markers, or None when the doc holds no pair."""
    m = re.search(re.escape(BEGIN) + r'\n(.*?)\n?' + re.escape(END), doc, re.S)
    return m.group(1).strip('\n') if m else None


def written(doc, text):
    """The doc with its list replaced by text."""
    return re.sub(re.escape(BEGIN) + r'.*?' + re.escape(END),
                  lambda _: f'{BEGIN}\n{text}\n{END}', doc, count=1, flags=re.S)


def check(doc_path):
    want, got = listing(Path(doc_path).resolve().parent), block_of(Path(doc_path).read_text())
    if got is None:
        print(f'hook_list.py: {doc_path} holds no {BEGIN} … {END} pair', file=sys.stderr)
        return 1
    if got != want:
        print(f'hook_list.py: {doc_path} lists the hooks differently; '
              f'run hook_list.py --write {doc_path}\nwant:\n{want}\ngot:\n{got}', file=sys.stderr)
        return 1
    print(f'ok  {doc_path} lists the {len(want.splitlines())} hook scripts as their headers say')
    return 0


def write(doc_path):
    doc = Path(doc_path).read_text()
    if block_of(doc) is None:
        print(f'hook_list.py: {doc_path} holds no {BEGIN} … {END} pair', file=sys.stderr)
        return 1
    Path(doc_path).write_text(written(doc, listing(Path(doc_path).resolve().parent)))
    return 0


DOC_MODES = {'--check': check, '--write': write}


def main(argv):
    if argv[:1] in (['-h'], ['--help']):
        print(__doc__.strip())
        return 0
    if argv == ['--self-test']:
        return self_test()
    if not argv:
        print(listing(TREE))
        return 0
    if len(argv) == 2 and argv[0] in DOC_MODES:
        return DOC_MODES[argv[0]](argv[1])
    print(__doc__.split('\n\n')[1], file=sys.stderr)
    return 2


# ── Self-test ────────────────────────────────────────────────────────

def self_test():
    t = Tap()
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp)
        (tree / 'scripts').mkdir()
        (tree / 'scripts' / 'g.py').write_text('"""g.py — no step runs\nunread. Ever.\n\nMore.\n"""\n')
        (tree / 'scripts' / 'h.sh').write_text('#!/usr/bin/env bash\n# SessionEnd hook: the end hook\n# for each session\n#\n# More.\nset -u\n')
        settings = {'hooks': {
            'PreToolUse': [{'matcher': 'Edit', 'hooks': [{'command': '$HOME/.claude/scripts/g.py edit'}]}],
            'SessionEnd': [{'hooks': [{'command': '$HOME/.claude/scripts/h.sh'},
                                      {'command': '$HOME/.claude/scripts/g.py clear'},
                                      {'command': 'echo other'}]}]}}
        (tree / 'settings.json').write_text(json.dumps(settings))
        want = ('- `scripts/g.py` (PreToolUse[Edit] edit; SessionEnd clear): no step runs unread.\n'
                '- `scripts/h.sh` (SessionEnd): SessionEnd hook: the end hook for each session\n'
                '- `scripts/echo other` (SessionEnd): no such script')
        t.check(listing(tree) == want,
                'each script is one line: its events with matcher and arguments, then its header\'s first sentence',
                listing(tree))
        doc = tree / 'doc.md'
        doc.write_text(f'Intro.\n\n{BEGIN}\n- stale\n{END}\n\nAfter.\n')
        t.check(self_test_quiet(main, ['--check', str(doc)]) == 1, 'a doc whose list has drifted fails the check')
        t.check(self_test_quiet(main, ['--write', str(doc)]) == 0 and self_test_quiet(main, ['--check', str(doc)]) == 0,
                'a written doc passes the check, the tree being the doc\'s folder')
        t.check(doc.read_text() == f'Intro.\n\n{BEGIN}\n{want}\n{END}\n\nAfter.\n',
                'writing replaces only the text between the markers')
        bare = tree / 'bare.md'
        bare.write_text('No markers.\n')
        t.check(self_test_quiet(check, bare) == 1 and self_test_quiet(write, bare) == 1
                and bare.read_text() == 'No markers.\n', 'a doc with no markers fails, and is not written')
        t.check(self_test_quiet(main, ['--check']) == 2 and self_test_quiet(main, ['--bogus', 'x']) == 2,
                'a flag with no doc, or an unknown one, is a usage error')
    return t.end()


def self_test_quiet(fn, *args):
    """fn's result, with what it prints kept out of the TAP."""
    with open('/dev/null', 'w') as null, contextlib.redirect_stdout(null), contextlib.redirect_stderr(null):
        return fn(*args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
