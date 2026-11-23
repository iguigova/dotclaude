#!/usr/bin/env python3
"""gh_pr_reply.py — post one reply on a GitHub PR, from a body file.

Usage:
    gh_pr_reply.py <pr-ref> --thread <comment-id> <body-file>
    gh_pr_reply.py <pr-ref> --issue <body-file>
    gh_pr_reply.py --dry-run <pr-ref> (--thread <comment-id> | --issue) <body-file>
    gh_pr_reply.py --self-test

--thread replies under an inline review thread: the comment id is the
thread's top-level comment, and the replies endpoint nests the reply there.
--issue posts one top-level comment on the PR, for a finding outside the diff
or a reviewer's note, which has no thread to nest under.

A Claude session that has not loaded the draft skill is refused by
draft_gate.py before anything is read or sent; --dry-run prints the call and
the body and is never refused. The call runs as whatever `gh` account the
environment names, so GH_TOKEN picks the account for a personal repo.

Prints the posted comment's URL. Exit 0 posted, 1 refused or the call failed,
2 usage.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gh_pr_ref import RefError, parse_ref  # noqa: E402
from resolve import script  # noqa: E402
from tap import Tap  # noqa: E402

USAGE = __doc__.split('\n\n')[1]


class Usage(ValueError):
    """The arguments name no single reply."""


def parsed(argv):
    """(dry_run, ref, thread, body_path) from the arguments, thread None for --issue."""
    args = list(argv)
    dry_run = '--dry-run' in args
    args = [a for a in args if a != '--dry-run']
    if len(args) == 4 and args[1] == '--thread' and args[2].isdigit():
        return dry_run, args[0], args[2], args[3]
    if len(args) == 3 and args[1] == '--issue':
        return dry_run, args[0], None, args[2]
    raise Usage(USAGE)


def endpoint(owner, repo, number, thread):
    """The REST path a reply is posted to."""
    if thread:
        return f'repos/{owner}/{repo}/pulls/{number}/comments/{thread}/replies'
    return f'repos/{owner}/{repo}/issues/{number}/comments'


def body_of(path):
    """The body text; an empty one is refused, since GitHub posts nothing useful."""
    text = Path(path).read_text()
    if not text.strip():
        raise Usage(f'gh_pr_reply: {path} is empty; nothing was sent')
    return text


def drafted():
    """True when draft_gate.py lets this session send text to people."""
    return subprocess.run([script('draft_gate.py'), 'check', 'draft']).returncode == 0


def post(path, body):
    """The posted comment's URL; a failed call raises with gh's own message."""
    done = subprocess.run(['gh', 'api', '-X', 'POST', path, '--input', '-'],
                          input=json.dumps({'body': body}),
                          capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip() or f'gh api exited {done.returncode}')
    return json.loads(done.stdout)['html_url']


def run(argv):
    """The exit status, after printing the result or the reason."""
    dry_run, ref, thread, body_path = parsed(argv)
    if not dry_run and not drafted():
        return 1
    owner, repo, number = parse_ref(ref)
    path, body = endpoint(owner, repo, number, thread), body_of(body_path)
    if dry_run:
        print(f'POST {path}\n{body}')
        return 0
    print(post(path, body))
    return 0


def main(argv):
    if argv[:1] in (['-h'], ['--help']):
        print(__doc__.strip())
        return 0
    if argv[:1] == ['--self-test']:
        return self_test()
    try:
        return run(argv)
    except Usage as e:
        print(e, file=sys.stderr)
        return 2
    except (RefError, OSError, RuntimeError) as e:
        print(f'gh_pr_reply: {e}', file=sys.stderr)
        return 1


# ── Self-test ────────────────────────────────────────────────────────

def self_test():
    t = Tap()
    with tempfile.TemporaryDirectory() as tmp:
        body, empty = Path(tmp) / 'b.md', Path(tmp) / 'e.md'
        body.write_text('applied in abc123\n')
        empty.write_text(' \n')
        gate = Path(tmp) / 'gate'
        gate.mkdir()
        (gate / 'drafted.json').write_text('["draft"]')
        self_test_parse(t, body)
        self_test_runs(t, body, empty, gate)
    return t.end()


def self_test_parse(t, body):
    t.check(parsed(['O/r#7', '--thread', '42', str(body)]) == (False, 'O/r#7', '42', str(body)),
            'a thread reply names its comment id')
    t.check(parsed(['--dry-run', 'O/r#7', '--issue', str(body)]) == (True, 'O/r#7', None, str(body)),
            'an issue comment has no thread, and --dry-run may come first')
    bad = (['O/r#7', '--thread', 'x', str(body)], ['O/r#7', str(body)], ['O/r#7', '--issue'], [])
    t.check(all(self_test_usage(a) for a in bad),
            'a non-numeric thread, no kind, no body or no arguments is a usage error')
    t.check(endpoint('O', 'r', '7', '42') == 'repos/O/r/pulls/7/comments/42/replies'
            and endpoint('O', 'r', '7', None) == 'repos/O/r/issues/7/comments',
            'a thread reply goes to the replies endpoint, an issue comment to the issue')


def self_test_usage(args):
    try:
        parsed(args)
    except Usage:
        return True
    return False


def self_test_runs(t, body, empty, gate):
    def call(session, *args):
        env = {**os.environ, 'CLAUDE_CODE_SESSION_ID': session, 'DRAFT_GATE_DIR': str(gate)}
        done = subprocess.run([sys.executable, __file__, *args], env=env,
                              capture_output=True, text=True)
        return done.returncode, done.stdout, done.stderr
    st, _, err = call('st', 'O/r#7', '--issue', str(body))
    t.check(st == 1 and err.startswith('draft_gate:'),
            'a session that has not loaded draft is refused before anything is sent', err)
    st, out, err = call('st', '--dry-run', 'O/r#7', '--thread', '42', str(body))
    t.check(st == 0 and out == 'POST repos/O/r/pulls/7/comments/42/replies\napplied in abc123\n\n',
            'a dry run prints the call and the body and is never refused', out, err)
    st, _, err = call('drafted', 'not a ref', '--issue', str(body))
    t.check(st == 1 and 'draft_gate' not in err and 'Unrecognized PR ref' in err,
            'a session that loaded draft goes on, and a bad ref is refused', err)
    st, _, err = call('drafted', '--dry-run', 'O/r#7', '--issue', str(empty))
    t.check(st == 2 and 'is empty' in err, 'an empty body is refused and nothing is sent', err)
    st, out, _ = call('st', '--help')
    t.check(st == 0 and out.startswith('gh_pr_reply.py'), '--help prints the header')
    self_test_post(t, call, body, gate)


def self_test_post(t, call, body, gate):
    """A stub gh on PATH: it records its arguments and stdin, then answers or fails."""
    bin_dir = gate.parent / 'bin'
    bin_dir.mkdir()
    stub = bin_dir / 'gh'
    stub.write_text('#!/usr/bin/env bash\nprintf "%s " "$@" > "$GH_ARGS"; cat > "$GH_IN"\n'
                    '[[ -n "${GH_FAIL:-}" ]] && { echo "HTTP 404" >&2; exit 1; }\n'
                    'echo \'{"html_url": "https://github.com/O/r/pull/7#c1"}\'\n')
    stub.chmod(0o755)
    seen, sent = gate.parent / 'args', gate.parent / 'in'
    os.environ.update(PATH=f'{bin_dir}:{os.environ["PATH"]}', GH_ARGS=str(seen), GH_IN=str(sent))
    st, out, err = call('drafted', 'O/r#7', '--thread', '42', str(body))
    t.check(st == 0 and out == 'https://github.com/O/r/pull/7#c1\n'
            and seen.read_text() == 'api -X POST repos/O/r/pulls/7/comments/42/replies --input - '
            and json.loads(sent.read_text()) == {'body': 'applied in abc123\n'},
            'a post sends the body as JSON to the endpoint and prints the URL', out, err)
    os.environ['GH_FAIL'] = '1'
    st, out, err = call('drafted', 'O/r#7', '--issue', str(body))
    del os.environ['GH_FAIL']
    t.check(st == 1 and out == '' and 'HTTP 404' in err, "a failed call exits 1 with gh's message", err)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
