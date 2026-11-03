#!/usr/bin/env bash
# The single writer for a project's session history. An entry is appended at the
# end, stamped with UTC time, so the file reads oldest-first.
# Lines are only ever added: `--bill` adds one line to an entry already written,
# and no line in the file is changed or removed. Callers never track order,
# formatting, timestamps, or the path.
#
# Target file: the nearest `.claude/session_history.md` at or above $PWD
# (override with JOURNAL_HIST). Universal across projects. The readers,
# journal_scan.sh and journal_queue.sh, parse exactly what this writes and select
# by timestamp, never by position.
#
# Usage:
#   journal.sh -t "<TICKET> <topic>" -b "<outcome bullet>" [-b "<bullet>" …] \
#              [--via /skill] [-n "<title> — <detail>" …] \
#              [--placed "<id>: <placement> — <reason>" …] \
#              [-c "<commit summary>" | --sha <sha>]
#   journal.sh --bill "<entry-id>: <TICKET> worklog <id>|skipped — <why>" [--bill …]
#   journal.sh --self-test   exercises the writer against a scratch history.
#
# Each entry carries a minted id in its header — `## <UTC> [<id>] — <topic>` — so a
# later line can name it: billing marks the entry it paid for, and a correction
# names the entry it corrects. Ids are unique across the history and never reused.
#
# Entry, required:
#   -t/--topic   everything after the em-dash: "<TICKET> <topic>", or a
#                "PR Review: <repo>#<NN> (<TICKET> <title>)" line, or "chore:"/"docs:".
#                The key is the ticket the work is for, never the session's:
#                /timelog bills the entry to it. Work on the tooling itself
#                (.claude/, a skill, a script, the journal, a /timelog run) is
#                chore:, even when a ticket's session surfaced it.
#                A project whose work has no tickets lists its own topic kinds,
#                one per line, in `topic_kinds` beside its history; a topic
#                opening "<kind>:" then needs no ticket key.
#   -b/--bullet  one outcome + why, ~20 words, changelog tone. Repeatable.
#
# Entry, optional:
#   --via        the skill/command that drove the turn (e.g. /review:pr) — records
#                usage as ground truth so it is never inferred. Renders "(via /skill)".
#   -n/--note    one thing noticed and not yet placed: something learned, worth
#                automating, a skill gap, friction, or work no ticket tracks.
#                Written "<title> — <detail>": the title, at most 60 characters,
#                is what a one-line listing such as the session-end report shows.
#                A note with no " — " is listed by its text, cut short.
#                Repeatable. Each gets a minted id, printed with the topic's ticket
#                and its text, and stays open until --placed says where it went.
#   --placed     "<id>: <placement> — <reason>" — closes an open note. The
#                placement is a kind from inventory_kinds.txt, optionally naming
#                which one (skill:review:pr, memory:aws-profile, rules); or
#                ticket:<KEY>; or `-` for work that produced nothing we author.
#                The reason is prose and required. Repeatable. Rejected unless the
#                id is open and not already closed by this call, so the queue
#                cannot lie.
#   -c/--commit  the message for a commit the user is to make. Renders
#                `**Suggested commit:** \`<message>\``.
#   --sha        the short sha of a commit this round already made. Renders
#                `**Committed:** \`<sha>\` …`. Hex, 7 to 40 characters, so the claim
#                can be checked against the repo. Repeatable, because one call is
#                one commit: a round that committed in two repos, or split one
#                change per commit, names each. Refused beside -c: a commit is
#                taken or suggested, never both, and a round that took one has no
#                suggestion left to make. Where tooling_commit.sh committed, this
#                is the field that records it.
#
# Billing:
#   --bill       "<entry-id>: <mark>" — adds `**Billed:** <mark>` to that entry,
#                which is how an entry stops being offered for billing. The mark
#                names the Jira worklog that paid for it, `<TICKET> worklog <id>`,
#                so the claim can be checked, or `skipped — <why>` for work that
#                will not be billed. Post the worklog first: a mark is a record
#                of money already logged. Takes no other field, so a failed bill
#                cannot lose an entry.
#
#                Repeatable, and each mark stands alone: one that is malformed,
#                names an already-billed entry, names an id not in the file, or
#                repeats an id from this call is refused by name, the rest are
#                written, and the exit code is 1. The worklogs exist whatever
#                the journal says, so an unwritten mark is work that gets
#                offered, and paid, a second time.
#
#                The whole call is refused when the history holds a `## ` heading
#                this writer did not write: a mark is placed after the last line
#                of the entry it names, and such a heading reads as that entry's
#                body, so the mark would land under it.
#
# Session: an entry written inside Claude Code ends with `**Session:** <id>`, from
# CLAUDE_CODE_SESSION_ID, which holds across compaction. journal_queue.sh --session
# reads it to list the notes one session opened or closed. An entry written with
# the variable unset carries no session line.
#
# Every field is one line. The history is line-oriented, so a newline in a field
# would write lines no reader can tell from real records — a bullet could open or
# close a note. -n and --placed also refuse a tab, since each becomes a TSV
# field of journal_queue.sh.
#
# No field may carry a credential. The history is versioned, so a secret written
# here is a secret in git history, which no later edit removes. The shapes below
# are refused by name and never echoed — printing the field to say it was refused
# would put the secret in the terminal and the transcript as well. The check is
# on shape, not on the word: `ATATT` alone is the vendor's prefix and passes;
# twenty more token characters after it do not.
#
# A lock on the history file serialises writers, from reading the open ids to the
# append, so concurrent sessions never lose or interleave an entry.
#
# Commit: every write — an entry or a bill — ends by committing the history file,
# and only that path, through tooling_commit.sh, on whatever branch is checked
# out. Anything else staged or dirty is left exactly as it was. The history is
# append-only, so entries another session left uncommitted in the file go in too:
# they belong in it. A history outside a repo, or ignored by it, is not
# committed. A refused commit — a repo with a remote the user has not opted in
# with `git config tooling.commit true`; a merge in progress; a held index
# lock — leaves the entry written and names the reason; the next write in a repo
# the script accepts commits it.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=journal_lib.sh
. "$SCRIPTS_DIR/journal_lib.sh"

# ---------------------------------------------------------------- self-test

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local h h2 out opened id id2 n entry i old
  h=$(mktemp)
  printf '# Log\n\n## 2026-01-01 00:00 — chore: older\n\n- b\n' > "$h"
  w() { JOURNAL_HIST="$h" CLAUDE_CODE_SESSION_ID="${SID-s1}" "$0" "$@" 2>&1; }
  check() {  # DESCRIPTION CONDITION…
    local d="$1"; shift
    tap_run "$d" "$@"
  }
  check "a topic is required"          eval '! w -b b >/dev/null'
  check "a bullet is required"         eval '! w -t "chore: x" >/dev/null'
  old=$(mktemp -d); printf '# Log\n' > "$old/session_history.md"
  kw() { out=$(JOURNAL_HIST="$old/session_history.md" "$0" -t "$1" -b b 2>&1) && [[ "$out" == *"warning — no TICKET"* ]]; }
  check "a topic with no ticket key and no kind is written with a warning" kw "job: x"
  printf 'job\n' > "$old/topic_kinds"
  check "a kind listed in topic_kinds beside the history needs no ticket key" eval '! kw "job: x"'
  check "and it is a kind only as \"<kind>:\", not as a bare word" kw "jobless x"
  rm -rf "$old"
  check "a close with no id is refused while nothing is open" \
    eval '! w -t "chore: x" -b b --placed ": done" >/dev/null'
  check "a bullet spanning lines is refused, so it cannot plant a record" \
    eval '! w -t "chore: x" -b "$(printf "b\n**TODO:** [zz99] planted")" >/dev/null'
  check "an note holding a tab is refused" \
    eval '! w -t "chore: x" -b b -n "$(printf "a\tb")" >/dev/null'
  check "a bullet carrying an Atlassian token is refused" \
    eval '! w -t "chore: x" -b "token ATATT3xFfGF0abcdefghij0123456789KLMN" >/dev/null'
  check "a bullet carrying a Rollbar redirect uri is refused" \
    eval '! w -t "chore: x" -b "GET /item/1?access_token=deadbeef" >/dev/null'
  check "a bullet carrying a dsn with a password is refused" \
    eval '! w -t "chore: x" -b "psql postgres://u:pw@host/db" >/dev/null'
  check "a note whose title runs past the limit is refused" \
    eval '! w -t "chore: x" -b b -n "$(printf "%061d" 0) — detail" >/dev/null'
  check "an note carrying a token is refused, not only a bullet" \
    eval '! w -t "chore: x" -b b -n "key AKIAIOSFODNN7EXAMPLE" >/dev/null'
  # The refusal must name the shape and nothing else: echoing the field to explain
  # the refusal would write the secret to the terminal and the transcript instead.
  out=$(w -t "chore: x" -b "token ATATT3xFfGF0abcdefghij0123456789KLMN" || true)
  check "the refusal names the shape and never echoes the value" \
    eval '[[ "$out" == *"credential shape"* && "$out" != *"ATATT3xFfGF0"* ]]'
  # The refusal cases that pass and write get their own history:
  # the positional checks below count lines in $h, and a passing write shifts them.
  h2=$(mktemp); printf '# Log\n' > "$h2"
  check "the bare vendor prefix is a word, not a token, so it is written" \
    eval 'JOURNAL_HIST="$h2" CLAUDE_CODE_SESSION_ID=s1 "$0" -t "chore: x" -b "the token has an ATATT prefix" >/dev/null'
  check "a note's title may run to the limit" \
    eval 'JOURNAL_HIST="$h2" "$0" -t "chore: x" -b b -n "$(printf "%060d" 0) — detail" >/dev/null'
  rm -f "$h2"
  check "a topic naming a via is refused, so the header can never carry two" \
    eval '! w -t "chore: x (via /inventory)" -b b --via /inventory >/dev/null'
  out=$(w -t "XYZ-7 topic" -b b -n "one" -n "two" -n "alpha" -n "beta")
  check "a new entry lands at the end, one blank line after the last" \
    eval '[[ -z "$(sed -n 6p "$h")" && "$(sed -n 7p "$h")" == "## "*" — XYZ-7 topic" ]]'
  check "the header carries a minted id" \
    eval '[[ "$(sed -n 7p "$h")" =~ ^\#\#\ [0-9-]{10}\ [0-9:]{5}\ \[[a-z0-9]{4}\]\ —\ XYZ-7\ topic$ ]]'
  check "an entry ends with its session" \
    eval '[[ "$(tail -n1 "$h")" == "**Session:** s1" ]]'
  SID="" w -t "chore: outside" -b b >/dev/null
  check "an entry written outside a session has no session line" \
    eval '[[ "$(tail -n1 "$h")" == "- b" ]]'
  check "a session id holding a space is refused" \
    eval '! SID="a b" w -t "chore: x" -b b >/dev/null'
  check "each note is its own line, carrying a minted id" \
    eval '[[ $(grep -cE "^\*\*TODO:\*\* \[[a-z0-9]{4}\] (one|two|alpha|beta)$" "$h") -eq 4 ]]'
  opened=$(grep -c '^note opened: [a-z0-9]\{4\} XYZ-7 \(one\|two\|alpha\|beta\)$' <<<"$out")
  check "each opened note prints with its ticket and text, so its id reaches the caller" \
    test "$opened" -eq 4
  id=$(JOURNAL_HIST="$h" "$SCRIPTS_DIR/journal_queue.sh" --ids | head -1)
  # The message is asserted, not only the exit: any refusal exits non-zero, so an
  # exit check alone passes on a misspelt flag without reaching the id lookup.
  out=$(w -t "chore: x" -b b --placed "zzzz: - — nothing to author" || true)
  check "an unknown id is refused" \
    eval '[[ "$out" == *"no open note with id"*zzzz* ]]'
  check "a placement outside the set is refused" \
    eval '! w -t "chore: x" -b b --placed "$id: promoted — x" >/dev/null'
  check "a kind that is not one of ours is refused" \
    eval '! w -t "chore: x" -b b --placed "$id: wiki:page — x" >/dev/null'
  check "a close with no space after the colon is refused" \
    eval '! w -t "chore: x" -b b --placed "$id:rules — x" >/dev/null'
  check "a placement that merely starts with a kind is refused" \
    eval '! w -t "chore: x" -b b --placed "$id: rules_ish — x" >/dev/null'
  check "a reason following anything but an em-dash is refused" \
    eval '! w -t "chore: x" -b b --placed "$id: rules - raised XYZ-8" >/dev/null'
  check "a placement with no reason is refused" \
    eval '! w -t "chore: x" -b b --placed "$id: rules" >/dev/null'
  check "a reason with no placement is refused" \
    eval '! w -t "chore: x" -b b --placed "$id: fixed it" >/dev/null'
  check "a ticket key too short for the reader to recognise is refused" \
    eval '! w -t "chore: x" -b b --placed "$id: ticket:R-31 — x" >/dev/null'
  out=$(w -t "chore: x" -b b --placed "$id: - — a" --placed "$id: - — b" || true)
  check "one id closed twice in one call is refused as such" \
    eval '[[ "$out" == *"closed twice in this call"* ]]'
  w -t "chore: x" -b b --placed "$id: ticket:XYZ-8 — raised as its own ticket" >/dev/null
  check "a note tracked elsewhere names the ticket" \
    grep -qxF "**TODO-DONE:** [$id] ticket:XYZ-8 — raised as its own ticket" "$h"
  check "a closed id cannot be closed again" \
    eval '! w -t "chore: x" -b b --placed "$id: - — x" >/dev/null'

  # Each placement takes a fresh open id, because a closed one cannot be closed
  # again.
  nextid() { JOURNAL_HIST="$h" "$SCRIPTS_DIR/journal_queue.sh" --ids | head -1; }
  id2=$(nextid)
  w -t "chore: x" -b b --placed "$id2: memory:aws-profile — checked and written" >/dev/null
  check "a note placed as a memory fact records which fact" \
    grep -qxF "**TODO-DONE:** [$id2] memory:aws-profile — checked and written" "$h"
  check "and it leaves the queue" eval '[[ "$(nextid)" != "$id2" ]]'
  id2=$(nextid)
  w -t "chore: x" -b b --placed "$id2: skill:review:pr — the trap is in the skill now" >/dev/null
  check "a placement can name a skill, colon in the name and all" \
    grep -qxF "**TODO-DONE:** [$id2] skill:review:pr — the trap is in the skill now" "$h"
  id2=$(nextid)
  w -t "chore: x" -b b --placed "$id2: rules — the sweep is the rename gate" >/dev/null
  check "a kind needs no name, only a reason" \
    grep -qxF "**TODO-DONE:** [$id2] rules — the sweep is the rename gate" "$h"
  w -t "chore: x" -b b -n "an operation nothing will hold" >/dev/null
  id2=$(nextid)
  w -t "chore: x" -b b --placed "$id2: - — 214 tables freed, 218 slots now open" >/dev/null
  check "work that produced nothing we author closes as -" \
    grep -qxF "**TODO-DONE:** [$id2] - — 214 tables freed, 218 slots now open" "$h"

  # A commit is taken or suggested. The two fields are separate so a reader can
  # tell which, and so a committed round can be checked for recording its sha.
  w -t "chore: took one" -b b --sha 54509c8 >/dev/null
  check "a taken commit records its sha" grep -qxF '**Committed:** `54509c8`' "$h"
  w -t "chore: took two" -b b --sha 54509c8 --sha 325c74d >/dev/null
  check "a round that committed twice names both, on one line" \
    grep -qxF '**Committed:** `54509c8` `325c74d`' "$h"
  w -t "chore: suggest one" -b b -c "XYZ-7: do the thing" >/dev/null
  check "a suggested commit records its message" \
    grep -qxF '**Suggested commit:** `XYZ-7: do the thing`' "$h"
  check "a sha that is not one is refused" eval '! w -t "chore: x" -b b --sha deadbeefz >/dev/null'
  check "a sha too short to name a commit is refused" \
    eval '! w -t "chore: x" -b b --sha abc123 >/dev/null'
  check "a commit cannot be both taken and suggested" \
    eval '! w -t "chore: x" -b b --sha 54509c8 -c "XYZ-7: x" >/dev/null'
  check "--sha alongside a bill is refused" \
    eval '! w --bill "zzzz: skipped — x" --sha 54509c8 >/dev/null'

  # Billing writes into an entry already in the file, so what it must not do is
  # as important as what it does: every other line survives, byte for byte.
  entry=$(w -t "XYZ-7 bill me" -b b | sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p')
  cp "$h" "$h.before"
  check "an entry id is printed in the header line" eval '[[ -n "$entry" ]]'
  check "an unknown entry id is refused"  eval '! w --bill "zzzz: XYZ-7 worklog 1" >/dev/null'
  check "a mark that names no worklog is refused" \
    eval '! w --bill "$entry: XYZ-7 2h" >/dev/null'
  check "a refused bill leaves the history untouched" cmp -s "$h.before" "$h"
  check "--bill alongside an entry field is refused" \
    eval '! w --bill "$entry: XYZ-7 worklog 1" -t "chore: x" -b b >/dev/null'
  w --bill "$entry: XYZ-7 worklog 41233" >/dev/null
  check "the mark lands in the entry it names" \
    eval '[[ "$(grep -A4 "\[$entry\]" "$h" | tail -n1)" == "**Billed:** XYZ-7 worklog 41233" ]]'
  check "billing adds one line and changes nothing else" \
    eval '[[ "$(diff "$h.before" "$h" | grep -c "^[<>]")" -eq 1 ]]'
  check "an entry cannot be billed twice" \
    eval '! w --bill "$entry: XYZ-7 worklog 9" >/dev/null'
  entry=$(w -t "chore: not billable" -b b | sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p')
  w --bill "$entry: skipped — chore work, not billed" >/dev/null
  check "skipped is a mark like any other" \
    grep -qxF "**Billed:** skipped — chore work, not billed" "$h"
  # An unwritten mark is work that gets billed twice, so one bad mark in a call
  # must not cancel the good ones.
  bill_pair() {  # BAD_MARK — one refusable mark beside one good one
    local good
    good=$(w -t "XYZ-7 pair" -b b | sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p')
    ! w --bill "$1" --bill "$good: XYZ-7 worklog 777" >/dev/null 2>&1 &&
      [[ "$(grep -A4 "\[$good\]" "$h" | tail -n1)" == "**Billed:** XYZ-7 worklog 777" ]]
  }
  check "an already-billed entry beside a good mark: the good one still lands" \
    bill_pair "$entry: XYZ-7 worklog 8"
  check "a malformed mark beside a good mark: the good one still lands" \
    bill_pair "zzzz: XYZ-7 worklog"
  check "an unknown id beside a good mark: the good one still lands" \
    bill_pair "zzzz: XYZ-7 worklog 8"
  entry=$(w -t "XYZ-7 twice" -b b | sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p')
  out=$(w --bill "$entry: XYZ-7 worklog 1" --bill "$entry: XYZ-7 worklog 2" 2>&1 || true)
  check "one id marked twice in one call is written once, from the first mark" \
    eval '[[ "$out" == *"marked twice in this call"* &&
             "$(grep -c "^\*\*Billed:\*\* XYZ-7 worklog 1$" "$h")" -eq 1 &&
             "$(grep -c "worklog 2$" "$h")" -eq 0 ]]'
  # A `## ` heading this writer did not write is body text to the bill awk, so
  # the mark would be written under it while the entry still reads unbilled —
  # and the next run would bill that work a second time.
  old=$(mktemp)
  printf '# Log\n' > "$old"
  entry=$(env -u CLAUDE_CODE_SESSION_ID JOURNAL_HIST="$old" "$0" -t "XYZ-7 stranded" -b b \
    | sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p')
  printf '\n## 2026-06-09 — an entry an older writer left\n\n- b\n' >> "$old"
  cp "$old" "$old.before"
  check "a heading this writer cannot parse refuses the bill" \
    eval '! JOURNAL_HIST="$old" "$0" --bill "$entry: XYZ-7 worklog 1" >/dev/null 2>&1'
  check "and leaves the history exactly as it was" cmp -s "$old.before" "$old"
  rm -f "$old" "$old.before"
  rm -f "$h.before"
  for i in $(seq 10); do w -t "chore: race $i" -b b >/dev/null & done
  wait
  n=$(grep -c -e '^## .* — chore: race ' "$h")
  check "ten entries written at once all land" test "$n" -eq 10
  # Minted ids: entry headers and note openings, which share one namespace. A
  # close repeats the id it closes, so only openings are counted.
  minted_ids() {
    grep -hoE '^(## [0-9-]{10} [0-9:]{5}|\*\*TODO:\*\*) \[[a-z0-9]{4}\]' "$h" | tr -dc 'a-z0-9\n'
  }
  check "every id is still unique after a race" \
    eval '[[ $(minted_ids | sort -u | wc -l) -eq $(minted_ids | wc -l) ]]'
  rm -f "$h"

  # Commit: the history, and nothing beside it, lands in the repo that holds it.
  local repo head0 me="$SCRIPTS_DIR/journal.sh"
  repo=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  mkdir "$repo/.claude"; printf '# Log\n' > "$repo/.claude/session_history.md"
  printf 'a\n' > "$repo/staged"; printf 'a\n' > "$repo/dirty"
  git -C "$repo" add -A; git -C "$repo" commit -qm init
  printf 'b\n' > "$repo/staged"; git -C "$repo" add staged
  printf 'b\n' > "$repo/dirty"
  head0=$(git -C "$repo" rev-parse HEAD)
  out=$( (cd "$repo" && CLAUDE_CODE_SESSION_ID=s1 "$me" -t "XYZ-7 committed" -b b) 2>&1)
  check "an entry is committed, and the commit is reported" \
    eval '[[ "$(git -C "$repo" rev-parse HEAD)" != "$head0" && "$out" == *"committed → "* ]]'
  check "the commit holds the history and nothing else" \
    eval '[[ "$(git -C "$repo" show --name-only --format= HEAD)" == ".claude/session_history.md" ]]'
  check "the commit subject names the topic" \
    eval '[[ "$(git -C "$repo" log -1 --format=%s)" == "chore(journal): XYZ-7 committed" ]]'
  check "the history is clean after the write" \
    eval '[[ -z "$(git -C "$repo" status --porcelain -- .claude/session_history.md)" ]]'
  check "a staged path stays staged and uncommitted" \
    eval '[[ "$(git -C "$repo" diff --cached --name-only)" == "staged" ]]'
  check "a dirty path stays dirty and unstaged" \
    eval '[[ "$(git -C "$repo" diff --name-only)" == "dirty" ]]'
  (cd "$repo" && "$me" -t "chore: tidy" -b b >/dev/null 2>&1)
  check "a chore topic is not prefixed twice" \
    eval '[[ "$(git -C "$repo" log -1 --format=%s)" == "chore(journal): tidy" ]]'
  entry=$(sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p' <<<"$out")
  head0=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && "$me" --bill "$entry: XYZ-7 worklog 5" >/dev/null 2>&1)
  check "a bill is committed too" \
    eval '[[ "$(git -C "$repo" rev-parse HEAD)" != "$head0" &&
             "$(git -C "$repo" log -1 --format=%s)" == "chore(journal): bill $entry" ]]'
  # A held index lock is what a concurrent git command looks like: the entry
  # must still land, with a warning, and the next write commits both.
  : > "$repo/.git/index.lock"
  head0=$(git -C "$repo" rev-parse HEAD)
  out=$( (cd "$repo" && "$me" -t "XYZ-7 locked" -b b) 2>&1) && i=0 || i=$?
  check "a refused commit leaves the entry written, warns, and exits 0" \
    eval '[[ $i -eq 0 && "$out" == *"not committed"* && "$(git -C "$repo" rev-parse HEAD)" == "$head0" ]] &&
          grep -q "XYZ-7 locked" "$repo/.claude/session_history.md"'
  rm -f "$repo/.git/index.lock"
  (cd "$repo" && "$me" -t "XYZ-7 after" -b b >/dev/null 2>&1)
  check "the next write commits the entry the refused one left" \
    eval 'git -C "$repo" show HEAD -- .claude/session_history.md | grep -q "^+.*XYZ-7 locked"'
  git -C "$repo" remote add origin https://example.invalid/r.git
  head0=$(git -C "$repo" rev-parse HEAD)
  out=$( (cd "$repo" && "$me" -t "XYZ-7 remote" -b b) 2>&1)
  check "a repo with a remote is not committed, and the reason is named" \
    eval '[[ "$(git -C "$repo" rev-parse HEAD)" == "$head0" && "$out" == *"has a remote"* ]]'
  git -C "$repo" remote remove origin
  printf '.claude/session_history.md\n' > "$repo/.git/info/exclude"
  git -C "$repo" rm -q --cached .claude/session_history.md
  git -C "$repo" commit -qm untrack
  # shellcheck disable=SC2034  # read inside the check below, which shellcheck cannot see
  head0=$(git -C "$repo" rev-parse HEAD)
  out=$( (cd "$repo" && "$me" -t "XYZ-7 ignored" -b b) 2>&1)
  check "an ignored history is written and not committed, without a warning" \
    eval '[[ "$(git -C "$repo" rev-parse HEAD)" == "$head0" && "$out" != *"not committed"* ]]'
  rm -rf "$repo"
}

if [[ "${1:-}" == "--self-test" ]]; then self_test; tap_end; fi

# ---------------------------------------------------------------- arguments

if [[ "${1:-}" == --help ]]; then
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
  exit 0
fi

HIST=$(journal_hist journal.sh) || exit 1
[[ -f "$HIST" ]] || { echo "journal.sh: no history at $HIST" >&2 ; exit 1 ; }

topic="" ; via="" ; commit=""
bullets=() ; notes=() ; closes=() ; bills=() ; shas=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--topic)    topic="$2"       ; shift 2 ;;
    -b|--bullet)   bullets+=("$2")  ; shift 2 ;;
    --via)         via="$2"         ; shift 2 ;;
    -n|--note)    notes+=("$2")    ; shift 2 ;;
    --placed)      closes+=("$2")   ; shift 2 ;;
    --bill)        bills+=("$2")    ; shift 2 ;;
    -c|--commit)   commit="$2"      ; shift 2 ;;
    --sha)         shas+=("$2")     ; shift 2 ;;
    *) echo "journal.sh: unknown argument: $1" >&2 ; exit 2 ;;
  esac
done

fields=("$topic" "$via" "$commit" "${shas[@]+"${shas[@]}"}"
        "${bullets[@]+"${bullets[@]}"}" "${notes[@]+"${notes[@]}"}"
        "${closes[@]+"${closes[@]}"}" "${bills[@]+"${bills[@]}"}")
for f in "${fields[@]}"; do
  [[ "$f" != *$'\n'* ]] || { echo "journal.sh: every field is one line, got: $f" >&2 ; exit 1 ; }
done
# A queue field becomes a TSV column in journal_queue.sh's listing.
for f in "${notes[@]+"${notes[@]}"}" "${closes[@]+"${closes[@]}"}"; do
  [[ "$f" != *$'\t'* ]] || { echo "journal.sh: a queue field takes no tabs, got: $f" >&2 ; exit 1 ; }
done
for f in "${notes[@]+"${notes[@]}"}"; do
  title="${f%%"$JOURNAL_NOTE_SEP"*}"
  [[ "$title" == "$f" || ${#title} -le $JOURNAL_NOTE_TITLE_MAX ]] || {
    echo "journal.sh: a note's title, before \"$JOURNAL_NOTE_SEP\", is at most $JOURNAL_NOTE_TITLE_MAX characters, got: $f" >&2
    exit 1 ; }
done

# Each shape is a vendor's own token format, anchored tightly enough that the
# name of a credential still passes and the credential itself does not.
secret_shapes=(
  'ATATT[A-Za-z0-9_=.+/-]{20,}'                            # Atlassian API token
  'xox[baprse]-[A-Za-z0-9-]{10,}'                          # Slack token
  'gh[pousr]_[A-Za-z0-9]{36}'                              # GitHub PAT
  'AKIA[0-9A-Z]{16}'                                       # AWS access key id
  'PMAK-[0-9a-f]{24}-[0-9a-f]{34}'                         # Postman API key
  'access_token=[A-Za-z0-9]'                               # Rollbar redirect URI
  'BEGIN [A-Z ]*PRIVATE KEY'                               # PEM private key
  '(postgres|postgresql|mysql|redis|amqp)://[^ ]*:[^ @]+@' # DSN carrying a password
)
for f in "${fields[@]}"; do
  for p in "${secret_shapes[@]}"; do
    [[ ! "$f" =~ $p ]] || {
      echo "journal.sh: a field matches the credential shape /$p/ and was not written;" >&2
      echo "            name the mode-600 file that holds it instead of the value" >&2
      exit 1 ; }
  done
done

# --via is the one way an entry names what drove it: it renders onto the header,
# so a topic naming one too renders it twice, and a topic naming one instead
# leaves the field the readers count unset.
[[ "$topic" != *"(via "* ]] || {
  echo "journal.sh: the topic must not name a via; pass it once, as --via" >&2 ; exit 1 ; }

entry_fields="${topic}${via}${commit}${shas[*]-}${bullets[*]-}${notes[*]-}${closes[*]-}"

# A sha is checkable only if it is one, and a round either took its commits or has
# one to suggest — carrying both says the commit is and is not yet made.
for sha in "${shas[@]+"${shas[@]}"}"; do
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || {
    echo "journal.sh: --sha takes 7 to 40 hex characters, got: $sha" >&2 ; exit 1 ; }
done
[[ ${#shas[@]} -eq 0 || -z "$commit" ]] || {
  echo "journal.sh: --sha is a commit taken and -c one to make; pass one" >&2 ; exit 1 ; }

if [[ ${#bills[@]} -gt 0 ]]; then
  [[ -z "$entry_fields" ]] || {
    echo "journal.sh: --bill takes no other field; bill in its own call" >&2 ; exit 1 ; }
  # A mark names its worklog, so a billed entry can be checked against Jira, or
  # says the work was skipped and why, so nothing is offered for billing twice.
  # A bad mark is dropped and named here; the rest go on to be written.
  bill_failed=0 ; ok_bills=() ; seen_ids=" "
  for bl in "${bills[@]}"; do
    id="${bl%%: *}" ; mark="${bl#*: }"
    if [[ "$id" == "$bl" || ! "$id" =~ ^[a-z0-9]+$ ]]; then
      echo "journal.sh: --bill needs \"<entry-id>: <mark>\", got: $bl" >&2
      bill_failed=1 ; continue
    fi
    if [[ ! "$mark" =~ ^${JOURNAL_TICKET_RE}\ worklog\ [0-9]+$ && ! "$mark" =~ ^skipped\ —\ .+$ ]]; then
      echo "journal.sh: --bill mark is \"<TICKET> worklog <id>\" or \"skipped — <why>\", got: $mark" >&2
      bill_failed=1 ; continue
    fi
    if [[ "$seen_ids" == *" ${id} "* ]]; then
      echo "journal.sh: --bill: entry $id is marked twice in this call; kept the first" >&2
      bill_failed=1 ; continue
    fi
    seen_ids="${seen_ids}${id} " ; ok_bills+=("$bl")
  done
  [[ ${#ok_bills[@]} -gt 0 ]] || exit 1
else
  [[ -n "$topic" ]]          || { echo "journal.sh: -t/--topic is required" >&2 ; exit 1 ; }
  [[ ${#bullets[@]} -gt 0 ]] || { echo "journal.sh: at least one -b/--bullet is required" >&2 ; exit 1 ; }

  # Non-blocking integrity nudge: every entry should carry a ticket key or be an
  # explicit chore/docs/PR-Review entry (the shapes consumers parse), or open with
  # a kind the project lists in topic_kinds beside its history.
  kinds="chore|docs|PR Review"
  if [[ -f "$(dirname "$HIST")/topic_kinds" ]]; then
    while IFS= read -r k; do [[ -n "$k" ]] && kinds="$kinds|$k:"; done < "$(dirname "$HIST")/topic_kinds"
  fi
  if ! grep -qE "${JOURNAL_TICKET_RE}|^(${kinds})" <<<"$topic"; then
    echo "journal.sh: warning — no TICKET key, chore/docs/PR-Review marker or project topic kind in topic" >&2
  fi

  session="${CLAUDE_CODE_SESSION_ID:-}"
  [[ -z "$session" || "$session" =~ ^[A-Za-z0-9-]+$ ]] || {
    echo "journal.sh: CLAUDE_CODE_SESSION_ID is not an id, got: $session" >&2 ; exit 1 ; }
fi

# ---------------------------------------------------------------- write

# Held from here to exit: the close checks and the id minting read the history,
# and what they read must still be true when the append lands.
exec 9>>"$HIST"
flock 9

ts=$(date -u +'%Y-%m-%d %H:%M')

# commit_hist SUBJECT — commit the history file through tooling_commit.sh, under
# the lock, so two writers never race for the index. A failure costs the commit,
# never the entry, and names the reason.
commit_hist() {
  local dir file sha err
  dir=$(dirname "$HIST") ; file=$(basename "$HIST")
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$dir" check-ignore -q -- "$file" && return 0
  err=$(mktemp)
  if sha=$("$SCRIPTS_DIR/tooling_commit.sh" -m "$1" -- "$HIST" 2>"$err"); then
    echo "committed → $sha $1"
  else
    echo "journal.sh: written but not committed — $(tail -1 "$err")" >&2
  fi
  rm -f "$err"
}

# Billing is the one write that touches an entry already in the file: the entry
# is written before the worklog exists, so the mark cannot be part of it. The
# write only ADDS a line to the named entry — awk rebuilds the file, and the
# result is compared with the original line by line, so a run that would change
# or drop anything is refused and the history is left as it was.
#
# awk applies the marks it can, names the rest, and records what it applied in
# `app`; the comparison below expects exactly those lines added.
if [[ ${#bills[@]} -gt 0 ]]; then
  # A mark goes after the last line of the entry it names. A `## ` heading this
  # writer did not write is body text to the awk below, so the mark lands under
  # that heading instead, the add-only check passes because a line was only
  # added, and the entry still reads unbilled — the next run bills it again.
  journal_check_headings journal.sh "$HIST" || exit 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/journal_bill.XXXXXX")
  app=$(mktemp "${TMPDIR:-/tmp}/journal_bill_applied.XXXXXX")
  trap 'rm -f "$tmp" "$app"' EXIT
  printf '%s\n' "${ok_bills[@]}" | awk -v hist="$HIST" -v app="$app" -v header_re="$JOURNAL_HEADER_RE" '
    NR == FNR { p = index($0, ": "); mark[substr($0, 1, p - 1)] = substr($0, p + 2); next }
    function flush(   i, last) {
      if (!have) return
      last = k; while (last > 0 && buf[last] ~ /^[[:space:]]*$/) last--
      for (i = 1; i <= last; i++) print buf[i]
      if ((cur in mark) && !(cur in already)) {
        print "**Billed:** " mark[cur]
        printf "%s\t%s\n", cur, mark[cur] > app
        done[cur] = 1
      }
      for (i = last + 1; i <= k; i++) print buf[i]
      have = 0; k = 0
    }
    $0 ~ header_re {
      flush()
      have = 1; cur = ""
      if (match($0, /\[[a-z0-9]+\]/)) cur = substr($0, RSTART + 1, RLENGTH - 2)
    }
    /^\*\*Billed:\*\* / {
      if (have && (cur in mark)) {
        printf "journal.sh: --bill: entry %s is already billed: %s\n", cur, $0 > "/dev/stderr"
        already[cur] = 1
      }
    }
    have { buf[++k] = $0; next }
    { print }
    END {
      flush()
      for (id in mark)
        if (!(id in done) && !(id in already))
          printf "journal.sh: --bill: no entry with id %s in %s\n", id, hist > "/dev/stderr"
      close(app)
    }
  ' - "$HIST" > "$tmp"

  # Nothing to write: every mark this call carried was refused above.
  [[ -s "$app" ]] || exit 1
  [[ $(wc -l < "$app") -eq ${#ok_bills[@]} ]] || bill_failed=1

  # Add-only: every line of the history survives, in order, and the only new
  # lines are the marks that applied.
  added=$(diff --unchanged-line-format= --old-line-format='-%L' --new-line-format='+%L' \
    "$HIST" "$tmp" | LC_ALL=C sort || true)
  expected=$(cut -f2 "$app" | sed 's/^/+**Billed:** /' | LC_ALL=C sort)
  [[ "$added" == "$expected" ]] || {
    echo "journal.sh: --bill would change the history beyond the marks; refused" >&2
    printf '%s\n' "$added" >&2 ; exit 1 ; }

  cat "$tmp" > "$HIST"
  cmp -s "$tmp" "$HIST" || {
    echo "journal.sh: --bill: the write did not land; recover from $tmp" >&2
    trap - EXIT ; exit 1 ; }
  while IFS=$'\t' read -r id mark; do echo "billed → ${id}: ${mark}"; done < "$app"
  commit_hist "chore(journal): bill $(cut -f1 "$app" | paste -sd' ')"
  exit "$bill_failed"
fi

# A close names an id journal_queue.sh reports open and that this call has not
# already closed; anything else is a typo or a double-close.
close_lines=()
if [[ ${#closes[@]} -gt 0 ]]; then
  re=$(journal_close_re)
  open_ids=$(JOURNAL_HIST="$HIST" "$SCRIPTS_DIR/journal_queue.sh" --ids)
  closed_here=" "
  for c in "${closes[@]}"; do
    id="${c%%: *}" ; close="${c#*: }"
    [[ "$id" != "$c" && "$id" =~ ^[a-z0-9]+$ && "$close" =~ $re ]] || {
      echo "journal.sh: --placed needs \"<id>: <placement> — <reason>\", got: $c" >&2
      echo "  placement: $(journal_kinds | paste -sd' ') ticket:<KEY> -" >&2
      echo "  each kind takes an optional :<name>; the reason is required" >&2
      exit 1 ; }
    [[ "$closed_here" != *" $id "* ]] || {
      echo "journal.sh: --placed: '$id' is closed twice in this call" >&2 ; exit 1 ; }
    grep -qxF "$id" <<<"$open_ids" || {
      echo "journal.sh: --placed: no open note with id '$id'" >&2
      echo "  open ids: ${open_ids//$'\n'/ }" >&2 ; exit 1 ; }
    closed_here="${closed_here}${id} "
    close_lines+=("$JOURNAL_CLOSE_MARK [${id}] ${close}")
  done
fi

# An id is never reused, even once closed: the open set is a set difference, so
# a recycled id would inherit the earlier close and be born closed. Entry ids and
# TODO ids share one namespace, so an id names one thing in the whole history.
ID_ALPHABET=abcdefghijklmnopqrstuvwxyz0123456789
mint_id() {
  local id
  while :; do
    id=""
    while [[ ${#id} -lt 4 ]]; do id="${id}${ID_ALPHABET:$((RANDOM % 36)):1}"; done
    grep -qF "[${id}]" "$HIST" && continue
    [[ " ${minted} " == *" ${id} "* ]] && continue
    minted="${minted} ${id}"
    printf '%s' "$id"
    return
  done
}
minted=""
entry_id=$(mint_id)
note_lines=()
opened_lines=()
ticket=$(grep -oE "$JOURNAL_TICKET_RE" <<<"$topic" | head -1 || true)
for t in "${notes[@]+"${notes[@]}"}"; do
  id=$(mint_id)
  note_lines+=("$JOURNAL_OPEN_MARK [${id}] ${t}")
  opened_lines+=("note opened: ${id} ${ticket:--} ${t}")
done

label="## ${ts} [${entry_id}] — ${topic}"
[[ -n "$via" ]] && label="${label} (via ${via})"
block="${label}"$'\n'
for b in "${bullets[@]}"; do block+=$'\n'"- ${b}"; done
for l in "${note_lines[@]+"${note_lines[@]}"}"; do block+=$'\n'"$l"; done
for l in "${close_lines[@]+"${close_lines[@]}"}"; do block+=$'\n'"$l"; done
[[ -n "$commit" ]] && block+=$'\n'"**Suggested commit:** \`${commit}\`"
if [[ ${#shas[@]} -gt 0 ]]; then
  block+=$'\n'"**Committed:**"
  for sha in "${shas[@]}"; do block+=" \`${sha}\`"; done
fi
[[ -n "$session" ]] && block+=$'\n'"**Session:** ${session}"

# Blocks are separated by one blank line, whatever the file's ending is now.
lead=""
[[ -n "$(tail -c1 "$HIST")" ]] && lead=$'\n'
[[ -n "$(tail -n1 "$HIST")" ]] && lead+=$'\n'
printf '%s%s\n' "$lead" "$block" >&9

echo "journaled → $label  [$HIST]"
# The minted id is the only handle on a note, so it must reach the caller.
for ol in "${opened_lines[@]+"${opened_lines[@]}"}"; do echo "$ol"; done
# A chore:/docs: topic already says what chore(journal) says; it is not repeated.
subject="${topic#chore: }" ; subject="${subject#docs: }"
commit_hist "chore(journal): ${subject}"
exit 0
