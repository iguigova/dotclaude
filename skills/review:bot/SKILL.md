---
name: review:bot
description: "Address the review-bot comments on a GitHub PR (any `[bot]` login; the confidence score is Greptile's) and every human reviewer's comment beside them: clear every red gate, fix or reasoned-decline each finding, post a threaded reply per thread, then drive the bot's score to its maximum. Auto-posts replies. Use when the user says \"address the greptile/bot comments on PR X and reply\"."
argument-hint: "<PR-URL | Org/repo#N | #N>   (omit to reuse the PR named in the session title)"
---

Address the review comments on this PR and reply to each: $ARGUMENTS

## Mission

Leave the PR green, the bot satisfied and every reviewer answered, with an honest reply behind every change.

Four things stand between a PR and that state, and a bot review is only the first:

1. **Inline bot threads** — comments anchored to diff lines.
2. **Findings the bot could not post inline** — raised as prose in an issue comment, counted by nothing.
3. **Human reviewer comments** — a colleague's inline thread, review body or PR comment, and on your own PR the review you posted on it.
4. **Red gates** — a failing check no thread mentions.

Each is fixed, declined with a reason, or shown to be already handled; each gets a reply; and the bot is then re-run so its verdict reflects the fixed code.

## 1. Start, and fetch the bot's findings

```bash
~/.claude/scripts/gh-pr-start.sh [<pr-ref>] --suffix BOT
```

Show what it prints; its `pr:` URL is `<pr-ref>` below.

Under plan mode, pass `--no-name`; its header states when else.

```bash
~/.claude/scripts/gh-pr-bot-fetch.sh <pr-ref> [bot-login-substr …]
```

Show what it prints. It writes `$D/bot.json` and `$D/score.json` beside `$D/pr.json`, `$D` being the directory `gh-pr-workdir.sh <pr-ref>` prints; `gh-pr-bot-comments.sh --help` and `gh-pr-bot-score.sh --help` state their JSON. Pass a login substring, such as `greptile`, only when the user names one bot. A non-zero exit means neither file was written: stop, and say why.

## 2. Read the gates

Read the gate before the threads, because a red one often *is* the ask. Each step recomputes `$D`:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)
jq -c '.gate' "$D/pr.json"
```

`gh-pr-fetch.sh --help` states `.gate`.

**Every red gate is in scope.** Treat a failing check exactly as you would a P0 thread: diagnose it, fix it or decline it with a reason, and report the outcome.

For each failing check:

- **Read the actual failure**, never the check's name. A GitHub Actions job: `gh run view <run-id> --log-failed`, the run id being the number that follows "runs" in its `url`. A third-party status: open its `url`.
- **Reproduce it locally** with the tool the check runs, so the fix is verified rather than hoped for. `.github/workflows/*.yml` names the tool for Actions checks; a status posted by an app (`qlty`, Codecov, …) is configured in the repo — `.qlty/qlty.toml`, `<repo>/codecov.yml` — and its CLI usually reproduces it.
- **Separate what this PR broke from what was already broken.** A cloud checker typically blames a PR only for issues it *introduces*, while running the same tool locally flags every file the diff touches. The two counts disagree, and the local one is the overcount. Settle it by measuring: fetch each flagged file at the merge base and run the same tool on it.

  ```bash
  ~/.claude/scripts/gh-pr-file.sh --base <pr-ref> <path> [<path>...]
  ```

  It prints where each file landed, under `$D/base/`; run the tool on those. A file clean at the base and dirty now is yours. A file dirty at the base is pre-existing: leave it, and say in the reply that you did and why. A file the helper reports not found at the merge base is one the PR added, so everything in it is yours. Compare the two runs by exit status and error output, never by counting lines of stdout: a run that refused its arguments prints a usage error, which a count reads as zero issues.
- **A pending check is not a pass.** Say the evidence is incomplete rather than implying green.
- **`mergeable: CONFLICTING`** blocks the merge whatever the code looks like. Report it; do not resolve conflicts unasked.

## 3. Confirm you're on the right branch

The fix must land on the PR's head branch. Find where that branch is checked out:

```bash
~/.claude/scripts/gh-pr-local-tree.sh <pr-ref>
```

It finds the clone whose `origin` is the PR's repo, under the project (`gh-pr-local-tree.sh --help` states where it looks), and checks that clone's branch. Every edit, test and commit for this PR happens in the directory it prints. Act on its exit:

- **0** — the printed clone is on the head branch at the PR's head commit. Work there.
- **5** — the printed clone is on the branch but not at the head commit. Fetch, and pull if it is behind, before editing; if it carries local commits, ask.
- **3** — the branch is checked out nowhere. Ask before running `gh pr checkout <n>` in the clone it names: the switch moves whatever that tree was on.
- **4** — no clone of the repo. Ask; never edit a different repo's files.

A companion PR in another repo (a fix that belongs where the behaviour is decided) is located the same way, with its own ref.

## 4. Triage every finding

**Inline threads** — `$D/bot.json` → `threads[]`. Act only on those with `already_replied == false`.

**Out-of-diff findings** — `$D/score.json` → `outside_diff[]`. The bot raises these on lines the diff does not cover and posts them as prose in an issue comment. They are **not** review threads: they never appear in `threads[]` and never count towards `open_count`. **`open_count == 0` therefore does not mean the PR is clear** — check `outside_diff_count` and the gate before saying there is nothing to do. Read the `summary[]` bodies too, for context the inline comments assume.

An out-of-diff finding is a worklist entry, not a blocker. Reconcile `outside_diff[]` against the replies you have already posted, not against its length, and do not re-fix an entry you have already answered; `gh-pr-bot-score.sh --help` says why one can stay listed after its fix.

**Human threads** — `$D/bot.json` → `human_threads[]`. A reviewer's inline comment, triaged exactly like a bot thread. Act on those with `already_replied == false`; `human_open_count` counts them. A reviewer's "not a blocker" or "worth considering" is still an ask, and gets a reply saying what was done about it.

**Human notes** — `$D/bot.json` → `human_notes[]`. A review body or PR comment from a person. Read every one with `answered == false` and decide whether it asks anything. An automated status post under a person's login — a CI deploy notice, a coverage report — asks nothing: note it and move on, with no reply. A note that asks something is triaged like a thread.

**Your own review** — `$D/bot.json` → `own_review`, set only on a PR the `gh` user authored, where the review that user posted (typically by `/review:pr`) is an ask like a colleague's; elsewhere it is null, because there you only answer. Every other list leaves the `gh` user's comments out, since they are replies. Its `findings[]` are your own inline comments, open while `already_replied == false` (`own_open_count`). Its `body` is open while `asks` is true and `answered == false`, and a clean approve, holding none of those sections, asks nothing: triage each item under **Must fix**, **Should fix**, **Open questions** and **Nits** like a thread. An open question is settled with a measurement or a read of the code it names, and the reply states what was found.

A human comment often asks about something outside the diff — rollout, other environments, live state. Answer it with a measurement, not a guess: read the live resource, list the open PRs, query the system the comment is about.

For each finding, read the cited file at the cited line (`diff_hunk` shows the bot's context; open the real file for current state) and classify it into exactly one of:

- **Fix** — the bot is right. Make the smallest change that resolves it, in the surrounding code's conventions (§5).
- **Already addressed** — a later commit fixed it, or it does not apply to the current code. Verify against the actual file before claiming this.
- **Decline with rationale** — it conflicts with a deliberate decision, a house convention, or a documented constraint. Declining is legitimate; a vague decline is not. Cite the precedent (file/line, CLAUDE.md rule, doc).

Two judgements worth making explicitly:

- **Behaviour vs observability.** A bot may flag a cryptic log or a bare exception where the observable behaviour is already correct and tested. Apply it — it is a real, low-risk improvement — but say so in the reply rather than implying a bug fix, and strengthen the existing test rather than adding a near-duplicate.
- **Read the code before accepting the premise.** A finding about deleted symbols does not mean the feature is gone; a finding about a regression does not mean the old version was right. Confirm what the code does now, and let that decide the fix. A documentation finding is usually wider than the line cited: fix every place that repeats the same false claim, not only the one the bot could point at.

## 5. Make the fix in the house style

- **Match the file you are editing**, not a global ideal — quote style, indentation, naming, error-message vocabulary. A four-line fix should not drag in unrelated reformatting.
- **Never run a formatter across a repo that is not already formatted.** It rewrites untouched lines and buries the fix. The exception is a single file that the §2 base measurement proved clean before this PR: reformatting that one file restores the prior state rather than imposing a new style. Read the formatter's diff before keeping it: a formatter can change content, not just layout, as `qlty fmt`'s markdownlint pass did to a README, dropping a heading and cutting a word.
- When the bot pastes a ```suggestion``` block, treat it as a starting point. Reconcile it with the surrounding patterns — reuse an existing message or exception type so a new branch matches its neighbours.
- **Lock the fix in with a test** where feasible. Extend the nearest existing test rather than adding a near-duplicate, and assert the thing the bot cared about — the log line, the status code, the message — not just "does not crash".

## 6. Verify

Run the repo's gate, plus the tool behind every check that was red in §2 that the gate does not run. The gate is `<project>/.claude/scripts/ci_gate.sh <repo>` where the project keeps one; elsewhere it is the commands the repo's CI workflow runs.

```bash
<project>/.claude/scripts/ci_gate.sh <repo>     # or the CI workflow's commands
<the failing check's own tool>
```

The gate must pass (the project's gate prints `gate: PASS`), and each §2 failure must be resolved locally **before** you post a reply claiming a fix.

## 7. Post a reply per finding (auto-post)

Write each reply body to a file in the PR's working directory first — multi-line markdown survives the shell cleanly and the drafts stay keyed to the PR:

```bash
D=$(~/.claude/scripts/gh-pr-workdir.sh <pr-ref>)

# An inline thread: the replies endpoint guarantees correct nesting.
gh api -X POST repos/<owner>/<repo>/pulls/<number>/comments/<thread-id>/replies \
  -f body="$(cat "$D/reply-<thread-id>.md")"

# An out-of-diff finding or a human note: an issue comment has no in_reply_to,
# so there is no thread to nest under. Post one top-level comment, quoting the
# finding or note it answers and @-mentioning a human author. A reply to your
# own review links it (its html_url), which is what marks own_review answered.
gh api -X POST repos/<owner>/<repo>/issues/<number>/comments \
  -f body="$(cat "$D/reply-outside-diff.md")"
```

A good reply:

- **States the outcome first**: *applied* / *already addressed in `<sha>`* / *declined because …*.
- **Shows the change** — a short snippet or the key line.
- **Names any divergence** from the bot's literal suggestion, and why.
- **Distinguishes behaviour from observability** where it applies.
- **Cites verification**: the gate's counts, e.g. "1140 passed; changed files 100% covered; `ruff check` and `qlty check` clean".
- **Says what a gate fix did and did not touch** — which file was reformatted, which pre-existing ones were left, and why.
- Stays factual. No fabricated SHAs: if nothing is committed yet, describe the change, not a commit that does not exist.

Address the reviewer by name and answer their point, not the bot's.

Reply to **every** finding, declines included, and report the list back: `Replied to N findings: r<id1>, r<id2>, comment <id>` with each outcome.

## 8. Push, then drive the bot to its top score

The score is Greptile's: with any other review bot the `score:` line says `none from this bot`, so this section ends at the push and the re-read gates. The bot scores the **pushed head commit**. Until the fixes are on GitHub, the score and the gates both describe the old code, however green the working tree is.

Commit the fixes in ticket-first house style (`XYZ-1234: <summary>`), one message covering every fix including the gate fixes, push, and report the sha.

Once the new head is on GitHub, fetch again everything §2 and §4 read, since the files §1 wrote describe the old code:

```bash
~/.claude/scripts/gh-pr-bot-fetch.sh <pr-ref> --wait [bot-login-substr …] &&
~/.claude/scripts/gh-pr-start.sh <pr-ref> --no-name
```

Show what it prints, and act on it:

- **Exit 3** — the bot has not re-run on the pushed head. **Never quote the old score**, and never call it green. Run the block again; when runs keep ending here, the retrigger link in the bot's own summary is the manual fallback.
- **`(at max)`** — the bot is satisfied. Report the score and the gate as §2 reads it now: a push re-runs the checks, and that run is the only one worth reporting. The bot's verdict says nothing about people: the run is done only once the `bot:` line shows no human thread open, no own review unanswered and no own thread open, and every unanswered human note has been read and asks nothing (§4).
- **`(below max)`** — the bot is holding something back. Loop back to §2 and §4.

Stop looping after two rounds that fail to move the score, or when what remains is something you have declined with a reason. Then say plainly where the score stands and why, rather than reporting a maximum that was not reached. A score below maximum with a stated reason is a fine outcome; an unexplained one is not.

## 9. Wrap up

- Journal the run, its `--sha` the §8 commit:

```bash
~/.claude/scripts/journal.sh -t "<TICKET> PR #<n> — address bot review (<repo>)" --via /review:bot \
  -b "<per-finding: P<n> <file> — fixed/declined/already-addressed, one line>" \
  -b "<per-human-comment: <author> <file or PR> — outcome, one line>" \
  -b "<per-red-gate: <check> — cause and fix>" \
  -b "Verification: <N/N tests, linters, gate state>" \
  -b "Bot score: <n>/<max> against <sha>" \
  -b "Replies posted: r<id…>" \
  --sha <sha>
```

- Re-assert the session title, so the ticket is the last record written:

```bash
~/.claude/scripts/gh-pr-name-session.sh <pr-ref> BOT
```

Show the line it prints.

## Notes

- Replies are **auto-posted** (the user's standing choice for this skill, for bot and human comments alike) to a public PR. Keep them professional and accurate: a wrong "Fixed" is worse than no reply.
- If a finding needs a judgement you cannot make confidently (an ambiguous requirement, a cross-cutting refactor), reply asking the question in-thread rather than guessing, and flag it to the user.
