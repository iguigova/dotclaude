#!/usr/bin/env bash
# The open notes in a project's session history — everything captured with
# `journal.sh -n` that no `--placed` has closed. A note is one line a session
# wrote about something it noticed: something learned, something worth
# automating, friction to remove, or work no ticket tracks. The ticket column is
# the ticket of the entry that captured it, kept for reference, never one that
# tracks the note.
#
# There is one queue, not one per flavour of note, because every note has the
# same lifecycle — opened with a minted id, closed by a line naming that id — and
# only the exit differs. `journal_lib.sh` names the on-disk markers, so the
# writer's close-validation (journal.sh calls `--ids`) and this listing can never
# disagree.
#
# Target file: the nearest `.claude/session_history.md` at or above $PWD
# (override with JOURNAL_HIST).
#
# Usage:
#   journal_queue.sh                 # TSV, oldest first: id, opened (UTC), age, ticket, text
#   journal_queue.sh --ids           # open ids only, one per line
#   journal_queue.sh --opened-by ID  # narrow the open listing to what session ID opened
#   journal_queue.sh --ticket KEY    # narrow it to notes captured under that ticket
#   journal_queue.sh --topic PREFIX  # narrow it to notes captured under a topic opening PREFIX
#   journal_queue.sh --closed [...]  # the closed notes instead, in the session shape,
#                                    #   `here` `-`; composes with the three narrowings
#   journal_queue.sh --session ID    # TSV, the notes session ID opened or closed:
#                                    #   id, opened (UTC), ticket, here, status, text
#   journal_queue.sh --show [...]    # either listing as the table a person reads
#                                    #   (journal_lib.sh's journal_note_lines)
#   journal_queue.sh --self-test     # checks the listing against a fixed history
#   journal_queue.sh --help          # this header
#
# `--opened-by`, `--ticket` and `--topic` narrow the open listing and compose with
# each other and with `--ids`, so a caller scopes without re-implementing the
# filter. The topic is the capturing entry's, everything after its header's
# em-dash, so a project whose notes include work items, captured under a topic
# kind of its own (journal.sh's topic_kinds), lists that kind alone. They
# answer "what is still open, and mine" — which is the question /notes asks, and
# a different one from `--session`, which reports everything one session touched
# whether it is open or not. `--closed` turns the same narrowings on the closed
# notes, so a project whose work items are notes asks "was this one ever here"
# of the open listing and the closed one together.
#
# Open = an id carrying a `**TODO:**` line and no `**TODO-DONE:**` line. That is a
# set difference, and the listing is ordered by the opened time, so file order is
# irrelevant. The age is whole days since the opened time, as `<n>d`. The ticket
# is the first ticket key on the entry's header, or `-` when it has none: the
# context the note was captured in, never a ticket that tracks it.
#
# A session's notes are those opened or closed in an entry whose `**Session:**`
# line names it (journal.sh writes that line). `here` says which — opened,
# closed, or opened, closed — and `status` is `open` or the close as written, as
# it stands now, whichever session closed it. A close is `<placement> — <reason>`
# (journal_lib.sh states the grammar), shown verbatim because the history is
# append-only and holds closes older than it.
#
# journal.sh writes one `## ` heading per entry, and journal_lib.sh states the
# pattern both readers match. A heading neither matches makes this exit 1: its
# notes would otherwise be listed with no opened time, and an empty time sorts
# first, so they would head every oldest-first slice for good.
#
# Output is TSV, not the JSON journal_scan.sh emits, because the answer is a flat
# list with no grouping or cutoff to express — and TSV needs no jq. TSV is for
# scripts; `--show` is for people, and every report of a note prints it verbatim
# rather than rendering the TSV itself. It composes with every scope and not
# with `--ids`, which is already one bare column.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=journal_lib.sh
. "$SCRIPTS_DIR/journal_lib.sh"

# ---------------------------------------------------------------- listing

# `opened` and `ticket` belong to the entry the note was captured in — awk carries
# the most recent `## <ts>` header forward, since a body line has neither. A
# stable sort on `opened` keeps capture order within one entry. The age is taken
# against NOW, epoch seconds, and the opened time is read as UTC.
#
# An entry's session line comes last, so the ids an entry opens and closes wait
# in `eo`/`ec` until the entry ends, and are credited to SESSION only if it
# matched. With SESSION set the rows are that session's notes, open or not.
list_items() {  # IDS_ONLY HIST NOW [SESSION] [OPENED_BY] [TICKET] [TOPIC] [CLOSED]
  local rows open_m="$JOURNAL_OPEN_MARK [" done_m="$JOURNAL_CLOSE_MARK ["

  rows=$(TZ=UTC awk -v ticket_re="$JOURNAL_TICKET_RE" -v header_re="$JOURNAL_HEADER_RE" \
                 -v now="$3" -v want="${4:-}" -v ob="${5:-}" -v tk_want="${6:-}" -v tp_want="${7:-}" -v cl="${8:-0}" \
                 -v open_m="$open_m" -v done_m="$done_m" '
    function id_of(line,   m) {
      if (!match(line, /\[[a-z0-9]+\]/)) return ""
      return substr(line, RSTART + 1, RLENGTH - 2)
    }
    function age_of(ts,   t) {
      t = ts; gsub(/[-:]/, " ", t)
      return int((now - mktime(t " 00")) / 86400) "d"
    }
    function ticket_of(line) {
      return match(line, ticket_re) ? substr(line, RSTART, RLENGTH) : "-"
    }
    function end_entry(   i) {
      # The session line closes the entry, so a note learns which session opened
      # it only here, once the whole entry has been read.
      for (i = 1; i <= no; i++) osess[eo[i]] = sess
      if (want != "" && sess == want) {
        for (i = 1; i <= no; i++) did_open[eo[i]] = 1
        for (i = 1; i <= nc; i++) did_close[ec[i]] = 1
      }
      no = nc = 0; sess = ""
    }
    $0 ~ header_re {
      end_entry(); ts = $2 " " $3; tk = ticket_of($0)
      tp = substr($0, index($0, " — ") + length(" — ")); next
    }
    index($0, open_m) == 1 {
      id = id_of($0)
      if (id != "" && !(id in opened)) {
        order[++n] = id; opened[id] = ts; ticket[id] = tk; topic[id] = tp
        txt[id] = substr($0, index($0, "] ") + 2); eo[++no] = id
      }
      next
    }
    index($0, done_m) == 1 {
      id = id_of($0)
      if (id != "") { closed[id] = substr($0, index($0, "] ") + 2); ec[++nc] = id }
      next
    }
    /^\*\*Session:\*\* / { sess = $2; next }
    END {
      end_entry()
      for (k = 1; k <= n; k++) {
        id = order[k]
        if (want == "") {
          if (cl ? !(id in closed) : (id in closed)) continue
          if (ob != "" && osess[id] != ob) continue
          if (tk_want != "" && ticket[id] != tk_want) continue
          if (tp_want != "" && index(topic[id], tp_want) != 1) continue
          if (cl) printf "%s\t%s\t%s\t-\t%s\t%s\n", id, opened[id], ticket[id], closed[id], txt[id]
          else printf "%s\t%s\t%s\t%s\t%s\n", id, opened[id], age_of(opened[id]), ticket[id], txt[id]
        } else if ((id in did_open) || (id in did_close)) {
          here = (id in did_open) ? ((id in did_close) ? "opened, closed" : "opened") : "closed"
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, opened[id], ticket[id], here,
            (id in closed) ? closed[id] : "open", txt[id]
        }
      }
    }
  ' "$2" | LC_ALL=C sort -s -t $'\t' -k2,2)
  [[ -n "$rows" ]] || return 0
  if [[ "$1" == 1 ]]; then cut -f1 <<<"$rows"; else printf '%s\n' "$rows"; fi
}

# ---------------------------------------------------------------- self-test

# Out of time order on purpose: the listing orders by opened time, never position.
FIXTURE='# Log

## 2026-01-02 00:00 — R-31 note for XYZ-2
- b
**TODO:** [dddd] fourth
**TODO:** [eeee] fifth

## 2026-01-01 00:00 — chore: first
- b
**TODO:** [bbbb] second
**TODO:** [cccc] third
**Session:** s1

## 2026-01-03 00:00 — chore: closes
- b
**TODO-DONE:** [cccc] done
**Session:** s2

## 2026-01-03 01:00 — chore: opens and later drops
- b
**TODO:** [ffff] sixth
**Session:** s2

## 2026-01-03 02:00 — chore: drops
- b
**TODO-DONE:** [ffff] dropped — superseded
**Session:** s2

## 2026-01-02 12:00 — chore: a note that became a fact
- b
**TODO:** [gggg] seventh
**Session:** s3

## 2026-01-02 13:00 — chore: places it
- b
**TODO-DONE:** [gggg] memory:aws-profile — checked and written
**Session:** s3
'

# 2026-01-03 12:00 UTC: two and a half days after the first note, one and a half after the rest.
NOW=1767441600

EXPECTED=$'bbbb\t2026-01-01 00:00\t2d\t-\tsecond
dddd\t2026-01-02 00:00\t1d\tXYZ-2\tfourth
eeee\t2026-01-02 00:00\t1d\tXYZ-2\tfifth'

EXPECTED_S2=$'cccc\t2026-01-01 00:00\t-\tclosed\tdone\tthird
ffff\t2026-01-03 01:00\t-\topened, closed\tdropped — superseded\tsixth'

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local h old
  h=$(mktemp)
  printf '%s' "$FIXTURE" > "$h"
  check() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }
  check "oldest opened first, whole days old, capture order within an entry, closed left out" \
    "$EXPECTED" "$(list_items 0 "$h" "$NOW")"
  check "--ids lists the same open set" \
    "$(cut -f1 <<<"$EXPECTED")" "$(list_items 1 "$h" "$NOW")"
  # `cccc` closes as a bare `done`: a shape the writer refuses and the history holds.
  check "a session lists what it opened, open or not, a close predating the grammar included" \
    $'bbbb\t2026-01-01 00:00\t-\topened\topen\tsecond\ncccc\t2026-01-01 00:00\t-\topened\tdone\tthird' \
    "$(list_items 0 "$h" "$NOW" s1)"
  check "a session lists what it closed, with the close as written" \
    "$EXPECTED_S2" "$(list_items 0 "$h" "$NOW" s2)"
  check "a session that wrote nothing lists nothing" "" "$(list_items 0 "$h" "$NOW" s9)"
  check "a close naming the placement is listed as that" \
    $'gggg\t2026-01-02 12:00\t-\topened, closed\tmemory:aws-profile — checked and written\tseventh' \
    "$(list_items 0 "$h" "$NOW" s3)"
  check "and it is no longer open" "" \
    "$(list_items 1 "$h" "$NOW" | grep -x gggg || true)"
  # The two filters narrow the open listing and compose. Each is checked against a
  # match and against a miss, because a filter that always returns nothing looks
  # exactly like a filter that works until the day something should have matched.
  check "--opened-by lists only what that session opened, and only what is open" \
    $'bbbb\t2026-01-01 00:00\t2d\t-\tsecond' "$(list_items 0 "$h" "$NOW" "" s1)"
  check "a session whose notes were all closed lists nothing" "" \
    "$(list_items 0 "$h" "$NOW" "" s2)"
  check "an entry with no session line is nobody's, so --opened-by skips it" "" \
    "$(list_items 0 "$h" "$NOW" "" s-none)"
  check "--ticket lists the open notes captured under that ticket" \
    $'dddd\t2026-01-02 00:00\t1d\tXYZ-2\tfourth\neeee\t2026-01-02 00:00\t1d\tXYZ-2\tfifth' \
    "$(list_items 0 "$h" "$NOW" "" "" XYZ-2)"
  check "a ticket nothing was captured under lists nothing" "" \
    "$(list_items 0 "$h" "$NOW" "" "" NOPE-9)"
  check "the two filters compose, and an empty intersection is empty" "" \
    "$(list_items 0 "$h" "$NOW" "" s1 XYZ-2)"
  check "--ids narrows with them" $'dddd\neeee' "$(list_items 1 "$h" "$NOW" "" "" XYZ-2)"
  check "--topic lists the open notes captured under a topic opening the prefix" \
    $'dddd\t2026-01-02 00:00\t1d\tXYZ-2\tfourth\neeee\t2026-01-02 00:00\t1d\tXYZ-2\tfifth' \
    "$(list_items 0 "$h" "$NOW" "" "" "" "R-31 ")"
  check "a prefix found later in a topic, not at its start, lists nothing" "" \
    "$(list_items 0 "$h" "$NOW" "" "" "" "note for")"
  check "--topic composes with --ticket" "" "$(list_items 0 "$h" "$NOW" "" "" NOPE-9 "R-31 ")"
  check "--session with --topic is refused rather than silently narrowed" fail \
    "$(JOURNAL_HIST="$h" "$0" --session s1 --topic x >/dev/null 2>&1 && echo ok || echo fail)"
  check "--closed lists the closed notes, oldest opened first, each close as written" \
    $'cccc\t2026-01-01 00:00\t-\t-\tdone\tthird\ngggg\t2026-01-02 12:00\t-\t-\tmemory:aws-profile — checked and written\tseventh\nffff\t2026-01-03 01:00\t-\t-\tdropped — superseded\tsixth' \
    "$(list_items 0 "$h" "$NOW" "" "" "" "" 1)"
  check "--closed composes with --topic, matching and missing" \
    $'ffff\t2026-01-03 01:00\t-\t-\tdropped — superseded\tsixth' \
    "$(list_items 0 "$h" "$NOW" "" "" "" "chore: opens" 1)"
  check "--closed with a topic no closed note has lists nothing" "" \
    "$(list_items 0 "$h" "$NOW" "" "" "" "R-31 " 1)"
  check "--closed --ids lists the closed ids" $'cccc\ngggg\nffff' "$(list_items 1 "$h" "$NOW" "" "" "" "" 1)"
  check "--session with --closed is refused rather than silently narrowed" fail \
    "$(JOURNAL_HIST="$h" "$0" --session s1 --closed >/dev/null 2>&1 && echo ok || echo fail)"
  check "--session with --opened-by is refused rather than silently narrowed" fail \
    "$(JOURNAL_HIST="$h" "$0" --session s1 --opened-by s1 >/dev/null 2>&1 && echo ok || echo fail)"
  # --show is the TSV through journal_note_lines, so these check the wiring by
  # the cells of each row and journal_lib.sh's self-test checks the table. The
  # age column is left out because the script ages a note against the real clock.
  cells() { tail -n +3 | awk -F' *[|] *' -v f="$1" '{ n = split(f, k, ","); o = $k[1]
    for (i = 2; i <= n; i++) o = o " | " $k[i]; print o }'; }
  check "--show prints the open listing as id and whole text" \
    $'dddd | XYZ-2 | fourth\neeee | XYZ-2 | fifth' \
    "$(JOURNAL_HIST="$h" "$0" --show --ticket XYZ-2 | cells 2,3,5)"
  check "--show prints a session's notes with where each went" \
    $'cccc | closed | done | third\nffff | closed | dropped — superseded | sixth' \
    "$(JOURNAL_HIST="$h" "$0" --session s2 --show | cells 2,4,5,3)"
  check "--show --closed prints each closed note with where it went" \
    $'ffff | closed | dropped — superseded | sixth' \
    "$(JOURNAL_HIST="$h" "$0" --show --closed --topic "chore: opens" | cells 2,4,5,3)"
  check "--show with --ids is refused" fail \
    "$(JOURNAL_HIST="$h" "$0" --show --ids >/dev/null 2>&1 && echo ok || echo fail)"

  # A heading this reader cannot parse is refused rather than listed: its rows
  # would carry no opened time, and an empty time sorts first: the row would head
  # every oldest-first slice.
  old=$(mktemp)
  printf '# Log\n\n## 2026-06-09 — an entry an older writer left\n\n- b\n**TODO:** [aaaa] work\n' > "$old"
  check "a heading this reader cannot parse is an error, not a row with no date" fail \
    "$(JOURNAL_HIST="$old" "$0" >/dev/null 2>&1 && echo ok || echo fail)"
  check "--ids refuses it too, so a close cannot be validated against a short list" fail \
    "$(JOURNAL_HIST="$old" "$0" --ids >/dev/null 2>&1 && echo ok || echo fail)"
  printf '# Log\n' > "$old"
  check "a history with no entries yet lists nothing and succeeds" ok \
    "$(JOURNAL_HIST="$old" "$0" >/dev/null 2>&1 && echo ok || echo fail)"
  rm -f "$old" "$h"
}

# ---------------------------------------------------------------- main

SESSION="" ; OPENED_BY="" ; TICKET="" ; TOPIC="" ; IDS_ONLY=0 ; SHOW=0 ; CLOSED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) self_test; tap_end ;;
    --help)    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ; exit 0 ;;
    --ids)     IDS_ONLY=1 ; shift ;;
    --show)    SHOW=1 ; shift ;;
    --closed)  CLOSED=1 ; shift ;;
    --session) SESSION="${2:-}" ; shift 2
               [[ -n "$SESSION" ]] || { echo "journal_queue.sh: --session needs a session id" >&2 ; exit 2 ; } ;;
    --opened-by) OPENED_BY="${2:-}" ; shift 2
               [[ -n "$OPENED_BY" ]] || { echo "journal_queue.sh: --opened-by needs a session id" >&2 ; exit 2 ; } ;;
    --ticket)  TICKET="${2:-}" ; shift 2
               [[ -n "$TICKET" ]] || { echo "journal_queue.sh: --ticket needs a ticket key" >&2 ; exit 2 ; } ;;
    --topic)   TOPIC="${2:-}" ; shift 2
               [[ -n "$TOPIC" ]] || { echo "journal_queue.sh: --topic needs a prefix" >&2 ; exit 2 ; } ;;
    *) echo "journal_queue.sh: unknown argument: $1 (--help lists them)" >&2 ; exit 2 ;;
  esac
done

# --session reports one session's notes whether open or not, so a filter on the
# open listing would be read and then ignored. Refusing beats narrowing silently.
if [[ -n "$SESSION" && ( -n "$OPENED_BY" || -n "$TICKET" || -n "$TOPIC" || "$CLOSED" -eq 1 ) ]]; then
  echo "journal_queue.sh: --session lists open and closed notes, so --opened-by, --ticket, --topic and --closed do not apply to it" >&2
  exit 2
fi

if [[ "$SHOW" -eq 1 && "$IDS_ONLY" -eq 1 ]]; then
  echo "journal_queue.sh: --show renders whole notes and --ids lists bare ids; pick one" >&2
  exit 2
fi

HIST=$(journal_hist journal_queue.sh) || exit 1
journal_check_headings journal_queue.sh "$HIST" || exit 1
rows=$(list_items "$IDS_ONLY" "$HIST" "$(date -u +%s)" "$SESSION" "$OPENED_BY" "$TICKET" "$TOPIC" "$CLOSED")
[[ -n "$rows" ]] || exit 0
if [[ "$SHOW" -eq 1 ]]; then journal_note_lines <<<"$rows"; else printf '%s\n' "$rows"; fi
