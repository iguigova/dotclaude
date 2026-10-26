#!/usr/bin/env bash
# Record what an unattended SessionEnd run did, for the next session to read.
#
# Usage:
#   session_end_report.sh --session SID --rc N --after N --dir DIR \
#                         [--open ID]… [--commit "<one line>"]… \
#                         [--left "<one line>"]… [--log PATH] [--dry-run]
#   session_end_report.sh --self-test
#
# The record is DIR/.claude/session_end.last, read at the start of the next
# session — the same shape as memory_check.last, which a session already reads
# and reports: every note with its whole text, every commit, every path left
# uncommitted. --dry-run prints it instead of writing it.
#
# --open names each of the session's notes that was open when the run started,
# and only those can be the run's placements. A note another session closed
# while this one was alive is placed, but not by the run.
#
# Recording never fails the run. A run that placed work and could not say so
# still placed the work; an exit code here would turn a reporting problem into a
# lost one.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=journal_lib.sh
. "$SCRIPTS_DIR/journal_lib.sh"

SESSION="" ; RC="" ; AFTER="" ; DIR="" ; DRY=0
LOG="${SESSION_END_LOG:-$HOME/.claude/logs/session_end.log}"
OPEN=() ; COMMITS=() ; LEFT=() ; NOTES=""

say() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

# ---------------------------------------------------------------- reading

# read_notes — the notes the ending session opened, as journal_queue.sh --session
# lists them, so journal_note_lines renders them unchanged.
read_notes() {
  (cd "$DIR" && "$SCRIPTS_DIR/journal_queue.sh" --session "$SESSION" 2>/dev/null) |
    awk -F'\t' '$4 ~ /opened/'
}

# notes_by BY — the notes in one section. BY is `open`, `run` for a note open
# when the run started and closed now, or `before` for one closed before the
# run, by this session or another.
notes_by() {
  awk -F'\t' -v want="$1" -v open=" ${OPEN[*]-} " '{
    by = $5 == "open" ? "open" : (index(open, " " $1 " ") ? "run" : "before")
    if (by == want) print }' <<<"$NOTES"
}

# ---------------------------------------------------------------- the record

# compose_record — the full record, for the next session to read.
compose_record() {
  printf 'session_end %s: session %s ended\n' "$(date -u '+%Y-%m-%d %H:%M')" "$SESSION"
  printf '%s open at the end, %s placed by the run, %s still open. Run exit %s.\n' \
    "${#OPEN[@]}" "$(( ${#OPEN[@]} - AFTER ))" "$AFTER" "$RC"
  section 'Still open' "$(notes_by open | record_lines)"
  section 'Placed by the run' "$(notes_by run | record_lines)"
  section 'Placed before the run' "$(notes_by before | record_lines)"
  section Committed "$(indent ${COMMITS[@]+"${COMMITS[@]}"})"
  section 'Left uncommitted' "$(indent ${LEFT[@]+"${LEFT[@]}"})"
  [[ "$RC" -ne 0 || ${#LEFT[@]} -gt 0 ]] && printf 'Full log: %s\n' "$LOG"
  [[ "$AFTER" -gt 0 ]] && printf 'Run /notes --session %s to place what is still open.\n' "$SESSION"
  return 0
}

# record_lines — each note as journal_note_lines prints it, indented under its
# section. An empty section stays empty, so `section` can drop it.
record_lines() {
  local rows; rows=$(cat)
  [[ -n "$rows" ]] || return 0
  journal_note_lines <<<"$rows" | sed 's/^/  /'
}

indent() { [[ $# -gt 0 ]] && printf '  %s\n' "$@"; return 0; }

section() {  # TITLE BODY — a titled block, or nothing when BODY is empty
  [[ -n "$2" ]] && printf '%s:\n%s\n' "$1" "$2"
  return 0
}

# ---------------------------------------------------------------- self-test

self_test() {
  local rc=0 tmp out run hist ids long_note
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  check() {  # DESCRIPTION WANT GOT
    if [[ "$3" == "$2" ]]; then echo "  ok   $1"
    else printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3" >&2; rc=1; fi
  }
  jw() { JOURNAL_HIST="$hist" CLAUDE_CODE_SESSION_ID="$1" "$SCRIPTS_DIR/journal.sh" "${@:2}"; }
  echo "session_end_report.sh --self-test"

  DIR="$tmp/proj"; mkdir -p "$DIR/.claude"; hist="$DIR/.claude/session_history.md"
  : > "$hist"
  long_note="ci_gate.sh picks the wrong profile for this repository and runs without the region"
  jw s-1 -t "XYZ-7 x" -b b -n "Probe script — list servers and spaces" \
    -n "$long_note" -n "Placed here — by the session" >/dev/null
  ids=$(cd "$DIR" && "$SCRIPTS_DIR/journal_queue.sh" --ids)
  jw s-1 -t "XYZ-8 y" -b b --placed "$(sed -n 3p <<<"$ids"): rules — stated in the rule" >/dev/null
  jw s-run -t "chore: notes" -b b \
    --placed "$(sed -n 1p <<<"$ids"): skill:probe — the probe is a skill now" >/dev/null
  jw s-1 -t "XYZ-8 z" -b b -n "Swept stash — gone before the run" >/dev/null
  # Closed by another session while s-1 was alive: placed, but not by the run.
  local swept_id; swept_id=$(cd "$DIR" && "$SCRIPTS_DIR/journal_queue.sh" --ids |
                             grep -vxF -e "$(sed -n 2p <<<"$ids")")
  jw s-other -t "chore: git sweep" -b b --placed "$swept_id: - — no longer there" >/dev/null

  SESSION=s-1 RC=0 AFTER=1 LOG="$tmp/log"
  OPEN=("$(sed -n 1p <<<"$ids")" "$(sed -n 2p <<<"$ids")")
  COMMITS=("/repo abc1234 chore: placed") LEFT=()
  NOTES=$(read_notes)

  out=$(compose_record)
  check "placed is what the queue lost, not a number passed in" "1 placed by the run" \
    "$(grep -o '[0-9]\+ placed by the run' <<<"$out")"
  # Each section is a table: its rows are read by cell — id, status, resolution,
  # note — and journal_lib.sh's self-test checks the table itself.
  rows_of() { sed -n "/^$1:\$/,/^[A-Z][a-z ]*:\$/p" <<<"$out" | grep -E '^  [|] [a-z0-9]{4} ' |
    awk -F' *[|] *' '{ print $2 " | " $4 " | " $5 " | " $3 }'; }
  check "a note still open is listed with its whole text" \
    "$(sed -n 2p <<<"$ids") | open | - | $long_note" "$(rows_of 'Still open')"
  check "a note the run placed says where it went" \
    "$(sed -n 1p <<<"$ids") | closed | skill:probe — the probe is a skill now | Probe script — list servers and spaces" \
    "$(rows_of 'Placed by the run')"
  check "a note the session placed is not counted as the run's" "closed | rules — stated in the rule" \
    "$(rows_of 'Placed before the run' | grep -F "$(sed -n 3p <<<"$ids")" | awk -F' [|] ' '{print $2 " | " $3}')"
  check "nor is one another session closed before the run" \
    "$swept_id | closed | - — no longer there | Swept stash — gone before the run" \
    "$(rows_of 'Placed before the run' | grep -F "$swept_id")"
  check "and the run's section holds the run's note alone" "1" \
    "$(rows_of 'Placed by the run' | wc -l)"
  check "a commit line is carried through" "  /repo abc1234 chore: placed" \
    "$(grep '/repo' <<<"$out")"
  check "work left open names the command that reaches it" "1" \
    "$(grep -c 'notes --session s-1' <<<"$out")"
  check "a clean run names no log" "0" "$(grep -c '^Full log' <<<"$out")"

  RC=3 OPEN=(x) AFTER=1 COMMITS=() LEFT=("/repo: stray.txt")
  out=$(compose_record)
  check "a path left uncommitted is named" "  /repo: stray.txt" "$(grep stray <<<"$out")"
  check "a run that committed nothing has no Committed section" "0" \
    "$(grep -c '^Committed' <<<"$out")"
  check "and the record points at the log" "1" "$(grep -c '^Full log' <<<"$out")"

  # Everything above tests the functions. These drive the script itself, which is
  # where the flags, the required-flag check and the write actually live — the
  # half a self-test that only calls functions never reaches.
  run="$tmp/run"; mkdir -p "$run/.claude"; : > "$run/.claude/session_history.md"
  out=$("$0" --session s-e2e --rc 0 --open a --open b --open c --after 1 --dir "$run" \
        --log "$tmp/e2e.log" --commit "/r abc (2 paths)" --dry-run)
  # three --open and --after 1 means 2 were placed, computed here and nowhere else.
  check "a dry run prints the record, placed count and all" "3 open at the end, 2 placed" \
    "$(grep -o '3 open at the end, 2 placed' <<<"$out")"
  check "and leaves no file behind" "0" \
    "$([[ -e "$run/.claude/session_end.last" ]] && echo 1 || echo 0)"

  # The status is captured on the same line: read later, $? is the last check's.
  SESSION_END_LOG="$tmp/e2e.log" \
    "$0" --session s-e2e --rc 0 --open a --open b --open c --after 1 --dir "$run" >/dev/null 2>&1; local st=$?
  check "a real run writes the record the next session reads" "1" \
    "$(grep -c '^session_end ' "$run/.claude/session_end.last" 2>/dev/null || echo 0)"
  check "and exits 0" "0" "$st"

  check "a missing required flag is refused by name" "2" \
    "$("$0" --session s --rc 0 --open a --after 0 >/dev/null 2>&1; echo $?)"
  check "an unknown argument is refused" "2" \
    "$("$0" --session s --rc 0 --open a --after 0 --dir "$run" --nope >/dev/null 2>&1; echo $?)"
  return $rc
}

[[ "${1:-}" == --self-test ]] && { self_test; exit $?; }

# ---------------------------------------------------------------- main

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --rc)      RC="$2";      shift 2 ;;
    --open)    OPEN+=("$2");   shift 2 ;;
    --after)   AFTER="$2";   shift 2 ;;
    --dir)     DIR="$2";     shift 2 ;;
    --log)     LOG="$2";     shift 2 ;;
    --commit)  COMMITS+=("$2"); shift 2 ;;
    --left)    LEFT+=("$2");    shift 2 ;;
    --dry-run) DRY=1;        shift ;;
    *) echo "session_end_report.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
for v in SESSION RC AFTER DIR; do
  [[ -n "${!v}" ]] || { echo "session_end_report.sh: --${v,,} is required" >&2; exit 2; }
done

NOTES=$(read_notes)
RECORD=$(compose_record)

if [[ "$DRY" -eq 1 ]]; then
  printf '%s\n' "$RECORD"
  exit 0
fi

mkdir -p "$DIR/.claude"
printf '%s\n' "$RECORD" > "$DIR/.claude/session_end.last"
say "report: wrote $DIR/.claude/session_end.last"
exit 0
