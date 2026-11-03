#!/usr/bin/env bash
# SessionStart hook: say how much is in the note queue, before the session forgets to ask.
#
# The harness runs this with the hook payload on stdin and puts what it prints
# into the session's context. Every line therefore costs tokens in every session
# in that project, so this prints a count and the three oldest notes, never the
# queue: the number is what prompts a session to run /notes, and the listing
# is only there so the number is not an abstraction. The three are whole, as
# journal_note_lines prints every note: a cut note is a paraphrase.
#
# Usage:
#   session_start_notes.sh              # reads the hook payload on stdin
#   session_start_notes.sh --self-test
#
# It exits 0 on every path. A session must start whether or not its history is
# readable, so a missing file, an unparseable one and a project that keeps no
# history all produce silence rather than an error the user has to read.
#
# SESSION_START_NOTES_N overrides how many items are listed (default 3).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE="$SELF_DIR/journal_queue.sh"
# shellcheck source=journal_lib.sh
. "$SELF_DIR/journal_lib.sh"

# The report, or nothing. Sole owner of the format, so the self-test asserts what
# a session is actually shown.
ssn_report() {
  local rows count oldest n="${SESSION_START_NOTES_N:-3}"
  rows=$("$QUEUE" 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  count=$(printf '%s\n' "$rows" | wc -l)
  oldest=$(printf '%s\n' "$rows" | head -1 | cut -f3)
  printf 'notes: %s open · oldest %s · /notes to place them\n' "$count" "$oldest"
  printf '%s\n' "$rows" | head -n "$n" | journal_note_lines
}

ssn_self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local fx out
  check() {  # DESCRIPTION WANT GOT
    if [ "$2" = "$3" ]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }
  fx=$(mktemp -d); trap 'rm -rf "$fx"' RETURN

  {
    printf '# Log\n\n## 2026-01-01 00:00 — chore: one\n\n- b\n'
    printf '**TODO:** [aaaa] first thing\n**Session:** s1\n\n'
    printf '## 2026-01-02 00:00 — chore: two\n\n- b\n'
    printf '**TODO:** [bbbb] %s\n**Session:** s1\n\n' "$(printf 'x%.0s' $(seq 1 200))"
    printf '## 2026-01-03 00:00 — chore: three\n\n- b\n'
    printf '**TODO:** [cccc] third thing\n**TODO:** [dddd] fourth thing\n**Session:** s1\n'
  } > "$fx/open.md"
  out=$(JOURNAL_HIST="$fx/open.md" ssn_report)
  check "the count is every open note, not the listed ones" 'notes: 4 open' \
    "$(printf '%s\n' "$out" | head -1 |  sed 's/ ·.*//' | sed 's/ *$//')"
  check "the oldest age is reported as whole days" 'true' \
    "$(printf '%s\n' "$out" | head -1 | grep -Eq 'oldest [0-9]+d ' && echo true || echo false)"
  # Line 1 is the count, lines 2 and 3 the table's header and rule, then a row a note.
  check "three are listed by default" 3 "$(printf '%s\n' "$out" | tail -n +4 | wc -l)"
  check "the oldest is listed first" 'aaaa' \
    "$(printf '%s\n' "$out" | sed -n '4p' | awk -F' *[|] *' '{print $2}')"
  check "a long note is listed whole, never cut to a paraphrase" 'true' \
    "$(printf '%s\n' "$out" | sed -n '5p' | grep -Eq 'x{200} [|]$' && echo true || echo false)"
  check "the count is honoured" 1 \
    "$(SESSION_START_NOTES_N=1 JOURNAL_HIST="$fx/open.md" ssn_report | tail -n +4 | wc -l)"

  # Silence, not noise, is the answer to every unhappy path: a session must start.
  printf '# Log\n\n## 2026-01-01 00:00 — chore: none\n\n- b\n**Session:** s1\n' > "$fx/empty.md"
  check "an empty queue prints nothing" '' "$(JOURNAL_HIST="$fx/empty.md" ssn_report)"
  check "a missing history prints nothing" '' "$(JOURNAL_HIST="$fx/gone.md" ssn_report)"
  printf 'not a session history at all\n' > "$fx/junk.md"
  check "an unreadable history prints nothing" '' "$(JOURNAL_HIST="$fx/junk.md" ssn_report)"
  check "and still exits 0, so the session starts" 0 \
    "$(JOURNAL_HIST="$fx/junk.md" ssn_report >/dev/null 2>&1; echo $?)"

  # The hook is handed a cwd and must report that project, not the one it is
  # installed in — the whole point of a per-project queue.
  mkdir -p "$fx/proj/.claude"
  cp "$fx/open.md" "$fx/proj/.claude/session_history.md"
  out=$(printf '{"cwd":"%s","source":"startup"}' "$fx/proj" | bash "$SELF_DIR/session_start_notes.sh")
  check "the payload's cwd selects the project" 'notes: 4 open' \
    "$(printf '%s\n' "$out" | head -1 |  sed 's/ ·.*//' | sed 's/ *$//')"
}

[ "${1:-}" = "--self-test" ] && { ssn_self_test; tap_end; }

# The payload names the session's directory; without one, this process's own.
payload=$(timeout 2 cat 2>/dev/null || true)
cwd=$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
# A directory that cannot be entered is reported on by no one: exit quiet and 0,
# because the alternative is a session that fails to start over a stale cwd.
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || exit 0; fi

ssn_report
exit 0
