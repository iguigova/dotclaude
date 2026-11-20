#!/usr/bin/env python3
"""ticket_prs.py — where a ticket's code stands on GitHub, as Markdown.

A ticket's Jira record does not say which PRs carry it, how far each has
drifted from its base, which review findings nobody answered, or what
other tickets changed the same files since the PR forked. Each of those
changes what the next step is, and each was found by hand before this.

A PR or commit names the key when the key stands alone in its title, body
or message, so ABC-113 never matches ABC-1130 or XABC-113. The owners
searched are the project's ``github_orgs`` value (``project_file.sh
--value``), one owner a line; a project without it stops the run, exit 1,
naming it.

For every PR that names the key, open or not, it prints:

* state, head and base branch, and for an open PR how many commits it is
  behind and ahead of its base
* failed checks
* each unresolved review thread, its severity badge (a review bot's
  ``<img alt="P1">``) when it has one, its title, and whether the PR author ever replied in it
* each human PR comment and review body by someone other than the
  author, and whether the author spoke after it; and the author's own
  review bodies, a self-review being an ask too, each answered only by a
  later author comment that links it
* the commits on the base branch since the merge base that touch a file
  the PR changes and do not name the key: work shipped under another
  ticket, which the PR has not absorbed

then, for each --path, the commits on that repo's default branch since
--since that touch it and do not name the key: a fix shipped under another
ticket often touches the code the ticket is about without touching any file
its PRs change. Last, every commit, in the same orgs, whose message names
the key.

--open prints only the URLs of the open PRs that name the key, oldest
first, one a line: the list gh-ticket-prs.sh judges for review readiness.

  ticket_prs.py ABC-123 > evidence/prs.md
  ticket_prs.py ABC-123 --since 2026-09-25 \\
      --path acme/api:app/workers/move_worker.rb
  ticket_prs.py ABC-123 --open
  ticket_prs.py --self-test         # offline, no network

Exit 0 printed; 1 the project names no github_orgs; 2 usage; 75 a GitHub
call failed, with gh's own error on stderr.
"""
import os
import argparse
import json
import re
import subprocess
import sys
import tempfile

from resolve import value

BADGE = re.compile(r'<img alt="(P\d)"')
TAG = re.compile(r'<[^>]+>')


def gh(*args):
    out = subprocess.run(('gh',) + args, check=True, capture_output=True).stdout
    return json.loads(out) if out.strip() else None


def names_key(text, key):
    """Whether the key stands alone in the text."""
    return re.search(rf'(^|[^A-Za-z0-9-]){re.escape(key)}([^0-9]|$)', text or '') is not None


def severity(body):
    found = BADGE.search(body or '')
    return found.group(1) if found else ''


def title(body):
    """The finding's own title: its first text line, without heading or bold marks."""
    for line in TAG.sub('', body or '').splitlines():
        line = line.strip().lstrip('#').strip().strip('*').strip()
        if line:
            return line[:120]
    return '(empty)'


def thread_line(thread, author):
    comments = thread['comments']['nodes']
    first = comments[0] if comments else {'author': None, 'body': ''}
    by = (first['author'] or {}).get('login', 'ghost')
    replied = any((c['author'] or {}).get('login') == author
                  for c in comments[1:])
    badge = severity(first['body'])
    where = thread['path'] + (f":{thread['line']}" if thread.get('line') else '')
    flags = ['answered' if replied else 'UNANSWERED']
    if thread.get('isOutdated'):
        flags.append('outdated')
    return (f"- {' '.join(filter(None, [badge, title(first['body'])]))} — "
            f"`{where}` — {by} — {', '.join(flags)}")


def notes(comments, reviews):
    """PR comments and review bodies by people, oldest first."""
    said = [dict(c, at=c['createdAt'], review=False) for c in comments]
    said += [dict(r, at=r['submittedAt'], review=True) for r in reviews
             if r.get('submittedAt')]
    return sorted((n for n in said
                   if (n['author'] or {}).get('__typename') == 'User'
                   and (n['body'] or '').strip()), key=lambda n: n['at'])


def answered(note, later, author):
    """Another's note is answered by anything the author says after it; the
    author's own review only by a later author comment that links it."""
    by_author = [n for n in later if n['author']['login'] == author]
    if note['author']['login'] != author:
        return bool(by_author)
    anchor = note['url'].rpartition('#')[2]
    return any(not n['review'] and anchor in n['body'] for n in by_author)


def comment_lines(comments, reviews, author):
    """Every note by someone else and every review by the author, each marked
    by whether it was answered. The author's own PR comments are answers."""
    said = notes(comments, reviews)
    return [f"- {n['at'][:10]} — {n['author']['login']}"
            f"{' review' if n['review'] else ''} — {title(n['body'])} — "
            f"{'answered' if answered(n, said[i + 1:], author) else 'UNANSWERED'}"
            for i, n in enumerate(said)
            if n['review'] or n['author']['login'] != author]


def foreign_commits(commits, key, merge_base):
    """Base-branch commits that do not name the key, oldest first, deduped.
    A merge commit is dropped: the commits it brings in are listed themselves."""
    seen, rows = set(), []
    for c in commits:
        if (c['sha'] == merge_base or c['sha'] in seen
                or len(c.get('parents', ())) > 1):
            continue
        seen.add(c['sha'])
        message = c['commit']['message']
        if names_key(message, key):
            continue
        rows.append((c['commit']['committer']['date'], c['sha'][:9],
                     message.splitlines()[0]))
    return sorted(rows)


PR_QUERY = '''query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
pullRequest(number:$n){author{login} state baseRefName headRefName
files(first:100){nodes{path}}
commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{
 ... on CheckRun{name conclusion} ... on StatusContext{context state}}}}}}}
reviewThreads(first:100){nodes{isResolved isOutdated path line
 comments(first:50){nodes{author{login} body}}}}
comments(first:100){nodes{author{login __typename} createdAt body}}
reviews(last:50){nodes{author{login __typename} submittedAt body url}}}}}'''


def failed_checks(pr):
    nodes = pr['commits']['nodes']
    rollup = nodes[0]['commit']['statusCheckRollup'] if nodes else None
    bad = ('FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED')
    return [n.get('name') or n.get('context')
            for n in (rollup or {}).get('contexts', {}).get('nodes', [])
            if (n.get('conclusion') or n.get('state')) in bad]


def report_pr(key, hit):
    owner, repo = hit['repository']['nameWithOwner'].split('/')
    number = hit['number']
    pr = gh('api', 'graphql', '-f', f'query={PR_QUERY}', '-f', f'o={owner}',
            '-f', f'r={repo}', '-F', f'n={number}'
            )['data']['repository']['pullRequest']
    author = pr['author']['login']
    out = [f"## [{owner}/{repo}#{number}]({hit['url']}) — {hit['title']}", '',
           f"- {pr['state'].lower()}, `{pr['headRefName']}` → "
           f"`{pr['baseRefName']}`, by {author}"]
    if pr['state'] != 'OPEN':
        return out + ['']
    cmp = gh('api', f"repos/{owner}/{repo}/compare/"
             f"{pr['baseRefName']}...{pr['headRefName']}")
    merge_base = cmp['merge_base_commit']['sha']
    out.append(f"- {cmp['behind_by']} commits behind `{pr['baseRefName']}`, "
               f"{cmp['ahead_by']} ahead; merge base `{merge_base[:9]}` "
               f"({cmp['merge_base_commit']['commit']['committer']['date']})")
    failed = failed_checks(pr)
    out.append(f"- failed checks: {', '.join(failed) if failed else 'none'}")

    threads = pr['reviewThreads']['nodes']
    open_threads = [t for t in threads if not t['isResolved']]
    out += ['', f'### Review threads — {len(open_threads)} unresolved of '
            f'{len(threads)}', '']
    out += [thread_line(t, author) for t in open_threads] or ['- none']
    out += ['', '### Comments from reviewers', '']
    out += comment_lines(pr['comments']['nodes'], pr['reviews']['nodes'],
                         author) or ['- none']

    since = cmp['merge_base_commit']['commit']['committer']['date']
    rows = foreign_commits(
        commits_touching(owner, repo, pr['baseRefName'],
                         [f['path'] for f in pr['files']['nodes']], since),
        key, merge_base)
    out += ['', f"### On `{pr['baseRefName']}` since the merge base, touching "
            'this PR\'s files, under another ticket', '']
    out += commit_lines(rows)
    return out + ['']


def commits_touching(owner, repo, branch, paths, since):
    commits = []
    for path in paths:
        commits += gh('api', '--paginate', f'repos/{owner}/{repo}/commits',
                      '-X', 'GET', '-f', f'sha={branch}', '-f', f'path={path}',
                      '-f', f'since={since}') or []
    return commits


def commit_lines(rows):
    return [f'- {d[:10]} `{sha}` {msg}' for d, sha, msg in rows] or ['- none']


def report_paths(key, specs, since):
    """The mechanism's own files, which a fix under another ticket may touch
    without touching any file the PRs change."""
    by_repo = {}
    for spec in specs:
        repo, _, path = spec.partition(':')
        by_repo.setdefault(repo, []).append(path)
    out = [f'## Under another ticket since {since}, touching the mechanism', '']
    for slug, paths in sorted(by_repo.items()):
        owner, repo = slug.split('/')
        branch = gh('api', f'repos/{owner}/{repo}')['default_branch']
        out += [f'### {slug} `{branch}`', '']
        out += commit_lines(foreign_commits(
            commits_touching(owner, repo, branch, paths, since), key, None))
        out.append('')
    return out


def pr_hits(key, owners, *only):
    """The PRs naming the key, by repository and number; ``only`` narrows
    the search, as ``--state open`` does."""
    found = gh('search', 'prs', key, *owners, *only, '--limit', '100', '--json',
               'repository,number,title,body,url,createdAt') or []
    hits = [h for h in found if names_key(f"{h['title']}\n{h['body']}", key)]
    return sorted(hits, key=lambda h: (h['repository']['nameWithOwner'], h['number']))


def open_prs(key):
    """The URLs of the open PRs naming the key, oldest first."""
    hits = pr_hits(key, owner_args(), '--state', 'open')
    for hit in sorted(hits, key=lambda h: h['createdAt']):
        print(hit['url'])
    return 0


def report_prs(key, owners):
    hits = pr_hits(key, owners)
    out = [] if hits else ['No PR names this key.', '']
    for hit in hits:
        out += report_pr(key, hit)
    return out


def report_landed(key, owners):
    """Every commit whose message names the key."""
    found = gh('search', 'commits', key, *owners, '--limit', '100',
               '--json', 'repository,sha,commit') or []
    lines = [f"- {c['repository']['fullName']} `{c['sha'][:9]}` "
             f"{c['commit']['message'].splitlines()[0]}"
             for c in found if names_key(c['commit']['message'], key)]
    return ['## Commits naming the key', ''] + (lines or ['- none'])


def report(key, paths, since):
    owners = owner_args()
    out = [f'# {key} on GitHub', ''] + report_prs(key, owners)
    if paths:
        out += report_paths(key, paths, since)
    print('\n'.join(out + report_landed(key, owners)))
    return 0


def github_orgs():
    """The GitHub owners to search: the project's github_orgs value, one per
    line; its refusal ends the run, exit 1, naming the value."""
    return tuple(line.strip() for line in value('github_orgs').splitlines())


def owner_args():
    """gh's ``--owner`` argument for each of the project's owners."""
    return [a for o in github_orgs() for a in ('--owner', o)]


def self_test():
    sys.path.insert(0, os.path.expanduser('~/.claude/scripts'))
    from tap import Tap
    t = Tap()
    p1 = ('<a href="#"><img alt="P1" src="x.svg" align="top"></a> '
          '**Paid permits still request payment**\n\nmore')
    user = lambda login: {'login': login, '__typename': 'User'}
    bot = {'login': 'greptile-apps', '__typename': 'Bot'}
    open_thread = {'path': 'a.rb', 'line': 32, 'isOutdated': False,
                   'comments': {'nodes': [{'author': bot, 'body': p1}]}}
    replied = {'path': 'b.dart', 'line': None, 'isOutdated': True,
               'comments': {'nodes': [{'author': bot, 'body': 'plain\nx'},
                                      {'author': user('jp'), 'body': 'ok'}]}}
    comments = [
        {'author': bot, 'createdAt': '2026-10-08T00:00:00Z', 'body': 'summary'},
        {'author': user('diego'), 'createdAt': '2026-10-09T01:00:00Z',
         'body': '**Narrow catch**'},
        {'author': user('jp'), 'createdAt': '2026-10-09T02:00:00Z', 'body': 'x'},
        {'author': user('bea'), 'createdAt': '2026-10-10T01:00:00Z',
         'body': 'question'},
    ]
    reviews = [
        {'author': user('diego'), 'submittedAt': '2026-10-09T00:30:00Z',
         'body': 'please rename', 'url': 'u#pullrequestreview-1'},
        {'author': user('diego'), 'submittedAt': '2026-10-09T00:40:00Z',
         'body': '', 'url': 'u#pullrequestreview-2'},
        {'author': user('jp'), 'submittedAt': '2026-10-11T00:00:00Z',
         'body': 'Approve with nits', 'url': 'u#pullrequestreview-3'},
        {'author': user('jp'), 'submittedAt': '2026-10-11T06:00:00Z',
         'body': 'Nits', 'url': 'u#pullrequestreview-4'},
    ]
    self_answer = {'author': user('jp'), 'createdAt': '2026-10-12T00:00:00Z',
                   'body': 'Addressed: pull/1#pullrequestreview-3'}
    commit = lambda sha, date, msg: {'sha': sha, 'commit': {
        'message': msg, 'committer': {'date': date}}}
    commits = [commit('b' * 40, '2026-10-15T00:00:00Z', 'ABC-2 later\nbody'),
               commit('a' * 40, '2026-10-10T00:00:00Z', 'ABC-1 own work'),
               dict(commit('c' * 40, '2026-10-12T00:00:00Z', 'ABC-12 first'), parents=[{}]),
               commit('b' * 40, '2026-10-15T00:00:00Z', 'ABC-2 later\nbody'),
               commit('m' * 40, '2026-10-08T00:00:00Z', 'merge base'),
               dict(commit('d' * 40, '2026-10-13T00:00:00Z', 'Merge branch'),
                    parents=[{}, {}])]
    pr = {'commits': {'nodes': [{'commit': {'statusCheckRollup': {'contexts': {
        'nodes': [{'name': 'test', 'conclusion': 'SUCCESS'},
                  {'name': 'UAT', 'conclusion': 'FAILURE'},
                  {'context': 'qlty', 'state': 'ERROR'}]}}}}]}}
    checks = {
        'badge read': (severity(p1), 'P1'),
        'no badge is empty': (severity('plain'), ''),
        'title drops badge and bold': (title(p1),
                                       'Paid permits still request payment'),
        'title drops heading marks': (title('## Review: X\n\n**Verdict:** 0'),
                                      'Review: X'),
        'title skips blank lines': (title('\n plain \nx'), 'plain'),
        'unanswered thread': (thread_line(open_thread, 'jp'),
                              '- P1 Paid permits still request payment — '
                              '`a.rb:32` — greptile-apps — UNANSWERED'),
        'answered and outdated': (thread_line(replied, 'jp'),
                                  '- plain — `b.dart` — greptile-apps — '
                                  'answered, outdated'),
        'humans only, author skipped, answer is a later author comment': (
            comment_lines(comments, [], 'jp'),
            ['- 2026-10-09 — diego — Narrow catch — answered',
             '- 2026-10-10 — bea — question — UNANSWERED']),
        'review bodies listed; own review open until a comment links it': (
            comment_lines(comments + [self_answer], reviews, 'jp'),
            ['- 2026-10-09 — diego review — please rename — answered',
             '- 2026-10-09 — diego — Narrow catch — answered',
             '- 2026-10-10 — bea — question — answered',
             '- 2026-10-11 — jp review — Approve with nits — answered',
             '- 2026-10-11 — jp review — Nits — UNANSWERED']),
        'foreign commits: own key, merge base, merges and repeats dropped; one parent kept': (
            foreign_commits(commits, 'ABC-1', 'm' * 40),
            [('2026-10-12T00:00:00Z', 'ccccccccc', 'ABC-12 first'),
             ('2026-10-15T00:00:00Z', 'bbbbbbbbb', 'ABC-2 later')]),
        'failed checks over both shapes': (failed_checks(pr), ['UAT', 'qlty']),
        'no rollup is no failures': (
            failed_checks({'commits': {'nodes': [{'commit': {
                'statusCheckRollup': None}}]}}), []),
    }
    for label, (was, want) in checks.items():
        t.check(was == want, label, f'got {was!r}', f'want {want!r}')
    for text, want in (('ABC-113: fix', True), ('see ABC-113.', True), ('ABC-113', True),
                       ('ABC-1130: fix', False), ('XABC-113', False), ('ABC-113a', True),
                       ('x-ABC-113', False), ('', False), (None, False)):
        t.check(names_key(text, 'ABC-113') is want, f'names_key({text!r}) is {want}')
    self_test_report(t)
    return t.end()


def self_test_thread(resolved, body):
    return {'isResolved': resolved, 'isOutdated': False, 'path': 'y.rb', 'line': 2,
            'comments': {'nodes': [{'author': {'login': 'bot'}, 'body': body}]}}


def self_test_answers(pr_state):
    """gh's answer to each call the report makes, keyed by its arguments."""
    review = {'author': {'login': 'jp'}, 'state': pr_state, 'baseRefName': 'main',
              'headRefName': 'f', 'files': {'nodes': [{'path': 'a.rb'}]},
              'commits': {'nodes': []},
              'reviewThreads': {'nodes': [self_test_thread(True, 'old'),
                                          self_test_thread(False, '**Open finding**')]},
              'comments': {'nodes': [{'author': {'login': 'rev', '__typename': 'User'},
                                      'createdAt': '2026-10-03T00:00:00Z', 'body': 'Looks off'}]},
              'reviews': {'nodes': []}}
    hit = lambda n, title, body: {'repository': {'nameWithOwner': 'acme/api'}, 'number': n,
                                  'title': title, 'body': body, 'url': f'u/{n}',
                                  'createdAt': f'2026-10-{20 - n:02}T00:00:00Z'}
    commit = lambda sha, msg: {'sha': sha * 40, 'repository': {'fullName': 'acme/api'},
                               'commit': {'message': msg, 'committer': {'date': '2026-10-02T00:00:00Z'}}}
    return {
        ('search', 'prs'): [hit(7, 'ABC-1: fix', None), hit(8, 'ABC-12: other', 'x')],
        ('api', 'graphql'): {'data': {'repository': {'pullRequest': review}}},
        ('api', 'repos/acme/api/compare/main...f'): {
            'behind_by': 3, 'ahead_by': 1, 'merge_base_commit': {
                'sha': 'm' * 40, 'commit': {'committer': {'date': '2026-10-01T00:00:00Z'}}}},
        ('api', '--paginate'): [commit('d', 'ABC-9 elsewhere')],
        ('api', 'repos/acme/api'): {'default_branch': 'main'},
        ('search', 'commits'): [commit('e', 'ABC-1 landed'), commit('f', 'ABC-12 not this')],
    }


def self_test_report(t):
    """report() end to end over a fake gh, in a project naming its owners;
    a project naming none stops, exit 1."""
    root = self_test_project()
    self_test_open(t, root)
    self_test_open_only(t, root)
    self_test_quiet(t, root)
    self_test_gh(t, root)
    self_test_cli(t, root)


def self_test_project():
    root = tempfile.mkdtemp()
    os.makedirs(os.path.join(root, 'p', '.claude'))
    os.makedirs(os.path.join(root, 'bare', '.claude'))
    with open(os.path.join(root, 'p', '.claude', 'github_orgs'), 'w') as f:
        f.write('# owners\nacme\n\nbeta\n')
    return root


def self_test_run(root, state, paths, override=None, only_open=False):
    """run() for ABC-1 in the project over a fake gh: its exit, what it
    printed, and each call gh got."""
    import contextlib
    import io
    answers = {**self_test_answers(state), **(override or {})}
    calls, real, here, out = [], gh, os.getcwd(), io.StringIO()

    def fake(*args):
        calls.append(args)
        return answers[args[:2]]
    try:
        os.chdir(os.path.join(root, 'p'))
        globals()['gh'] = fake
        with contextlib.redirect_stdout(out):
            code = run(argparse.Namespace(key='ABC-1', path=paths, since='2026-09-01', open=only_open))
    finally:
        globals()['gh'] = real
        os.chdir(here)
    return code, out.getvalue(), calls


def self_test_open(t, root):
    code, text, calls = self_test_run(root, 'OPEN', ['acme/api:a.rb'])
    lines = text.splitlines()
    t.check(code == 0 and lines[0] == '# ABC-1 on GitHub', 'a report opens with the key', text[:80])
    t.check(calls[0] == ('search', 'prs', 'ABC-1', '--owner', 'acme', '--owner', 'beta',
                         '--limit', '100', '--json', 'repository,number,title,body,url,createdAt'),
            'every owner the project names is searched', str(calls[0]))
    t.check('## [acme/api#7](u/7) — ABC-1: fix' in lines and not any('#8' in l for l in lines),
            'a PR naming a longer key is left out', text)
    t.check('- open, `f` → `main`, by jp' in lines, 'the PR line names state, branches and author', text)
    t.check('- 3 commits behind `main`, 1 ahead; merge base `mmmmmmmmm` (2026-10-01T00:00:00Z)' in lines,
            'an open PR states its drift', text)
    t.check('- failed checks: none' in lines, 'an open PR states its failed checks', text)
    t.check('### Review threads — 1 unresolved of 2' in lines
            and '- Open finding — `y.rb:2` — bot — UNANSWERED' in lines and '- old' not in text,
            'only unresolved threads are listed, counted against all', text)
    t.check('- 2026-10-03 — rev — Looks off — UNANSWERED' in lines,
            'a reviewer\'s comment is listed with its answer state', text)
    t.check(lines.count('- 2026-10-02 `ddddddddd` ABC-9 elsewhere') == 2,
            'another ticket\'s commit is listed under the PR and under the path', text)
    t.check('### acme/api `main`' in lines, 'a path is read on its repo\'s default branch', text)
    t.check('- acme/api `eeeeeeeee` ABC-1 landed' in lines and 'ABC-12 not this' not in text,
            'a commit naming a longer key is left out', text)
    t.check(('api', '--paginate', 'repos/acme/api/commits', '-X', 'GET', '-f', 'sha=main',
             '-f', 'path=a.rb', '-f', 'since=2026-10-01T00:00:00Z') in calls,
            'the PR\'s files are read since its merge base', str(calls))


def self_test_open_only(t, root):
    newer = {'repository': {'nameWithOwner': 'acme/web'}, 'number': 2, 'title': 'ABC-1 web',
             'body': '', 'url': 'u/web2', 'createdAt': '2026-10-30T00:00:00Z'}
    hits = self_test_answers('OPEN')[('search', 'prs')] + [newer]
    code, text, calls = self_test_run(root, 'OPEN', [], {('search', 'prs'): hits}, only_open=True)
    t.check(code == 0 and text == 'u/7\nu/web2\n',
            '--open prints the open PRs naming the key, oldest first, and no report', text)
    t.check(calls == [('search', 'prs', 'ABC-1', '--owner', 'acme', '--owner', 'beta', '--state', 'open',
                       '--limit', '100', '--json', 'repository,number,title,body,url,createdAt')],
            '--open searches only open PRs, once', str(calls))


def self_test_quiet(t, root):
    _, text, _ = self_test_run(root, 'MERGED', [])
    t.check('behind' not in text and '- merged, `f` → `main`, by jp' in text.splitlines(),
            'a closed PR states only its state', text)
    t.check('## Under another ticket' not in text, 'no path, no path section', text)
    _, text, _ = self_test_run(root, 'OPEN', [], {('search', 'prs'): [], ('search', 'commits'): []})
    t.check(text.splitlines()[2:] == ['No PR names this key.', '', '## Commits naming the key', '', '- none'],
            'a key no PR or commit names says so', text)


def self_test_cli(t, root):
    failing = os.path.join(root, 'failing')
    os.makedirs(failing)
    with open(os.path.join(failing, 'gh'), 'w') as f:
        f.write('#!/usr/bin/env bash\necho "HTTP 502" >&2\nexit 1\n')
    os.chmod(os.path.join(failing, 'gh'), 0o755)

    def run(folder, *args):
        env = {**os.environ, 'PATH': f"{failing}:{os.environ['PATH']}"}
        return subprocess.run([sys.executable, os.path.abspath(__file__), *args],
                              cwd=os.path.join(root, folder), capture_output=True, text=True, env=env)
    with_none = run('bare', 'ABC-1')
    t.check(with_none.returncode == 1 and 'github_orgs' in with_none.stderr,
            'a project naming no owners stops, exit 1, naming the value',
            f'{with_none.returncode} {with_none.stderr}')
    unread = run('p', 'ABC-1', '--open')
    t.check(unread.returncode == 75 and 'ticket_prs: HTTP 502' in unread.stderr,
            'a failed GitHub call exits 75 with gh\'s own error', f'{unread.returncode} {unread.stderr}')
    for args, label in ((['--open', '--path', 'acme/api:a.rb', '--since', '2026-01-01', 'ABC-1'], '--open with --path'),
                        (['--path', 'acme/api:a.rb', 'ABC-1'], '--path without --since'),
                        (['--since', '2026-01-01', '--path', 'a.rb', 'ABC-1'], '--path without a repository'),
                        (['--since', '2026-01-01', '--path', 'acme:a.rb', 'ABC-1'], '--path without an owner'),
                        ([], 'no key')):
        t.check(run('p', *args).returncode == 2, f'{label} is a usage error')


def self_test_gh(t, root):
    """gh() parses what gh prints, reads nothing as None, and raises when
    gh fails."""
    fake = os.path.join(root, 'bin')
    os.makedirs(fake)
    with open(os.path.join(fake, 'gh'), 'w') as f:
        f.write('#!/usr/bin/env bash\n[[ "$1" == fail ]] && exit 1\n[[ "$1" == none ]] && exit 0\necho \'{"a": [1]}\'\n')
    os.chmod(os.path.join(fake, 'gh'), 0o755)
    path = os.environ['PATH']
    os.environ['PATH'] = f'{fake}:{path}'
    try:
        t.check(gh('x') == {'a': [1]}, 'gh output is parsed')
        t.check(gh('none') is None, 'no gh output is None')
        try:
            gh('fail')
            t.check(False, 'a failed gh call raises')
        except subprocess.CalledProcessError:
            t.check(True, 'a failed gh call raises')
    finally:
        os.environ['PATH'] = path


def parse():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('key', nargs='?')
    parser.add_argument('--path', action='append', default=[],
                        metavar='ORG/REPO:PATH',
                        help='a file the mechanism runs through; repeatable')
    parser.add_argument('--since', metavar='YYYY-MM-DD',
                        help='with --path: the ticket\'s created date')
    parser.add_argument('--open', action='store_true',
                        help='only the URLs of the open PRs naming the key')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return args
    if not args.key:
        parser.error('an issue key is required')
    if args.open and args.path:
        parser.error('--open takes no --path')
    if args.path and not args.since:
        parser.error('--path needs --since')
    if any(':' not in p or '/' not in p.split(':')[0] for p in args.path):
        parser.error('--path takes ORG/REPO:PATH')
    return args


def run(args):
    return open_prs(args.key) if args.open else report(args.key, args.path, args.since)


def main():
    args = parse()
    if args.self_test:
        return self_test()
    try:
        return run(args)
    except subprocess.CalledProcessError as failed:
        sys.stderr.write(f'ticket_prs: {failed.stderr.decode().strip()}\n')
        return 75


if __name__ == '__main__':
    sys.exit(main())
