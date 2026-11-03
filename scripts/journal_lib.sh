# shellcheck shell=bash
# Sourced by journal.sh, journal_queue.sh and journal_scan.sh: the rules every
# reader and the writer of a session history must agree on, stated once.

# A ticket key: two or more capitals, a dash, digits. One capital is too few,
# because a one-letter id such as R-31 labels a row, not a ticket.
# POSIX ERE, so the same string serves grep -E, [[ =~ ]] and awk.
# shellcheck disable=SC2034  # read by the scripts that source this file
JOURNAL_TICKET_RE='[A-Z][A-Z]+-[0-9]+'

# The note queue: one queue of things noticed and not yet placed. `journal.sh -n`
# opens a note with a minted id; a close names the id, where it went and why.
#
# A `**TODO:**` line is a note and a `**TODO-DONE:**` line its placement. The
# spelling is historical and frozen: the history is append-only, so renaming a
# marker would hide every line already written with it. Every reader takes the
# marker from here rather than restating it.
# shellcheck disable=SC2034  # read by the scripts that source this file
JOURNAL_OPEN_MARK='**TODO:**'
# shellcheck disable=SC2034
JOURNAL_CLOSE_MARK='**TODO-DONE:**'

# A note reads `<title> — <detail>`: the title leads every listing, so it is what
# a reader scans first, and a note with no ` — ` is all detail. A title is a
# handle, so it is short.
# shellcheck disable=SC2034
JOURNAL_NOTE_SEP=' — '
# shellcheck disable=SC2034
JOURNAL_NOTE_TITLE_MAX=60

# journal_note_lines — journal_queue.sh's TSV on stdin, as the table a person
# reads. Every report of a note prints this and nothing of its own, because a
# note is reported by its id and its whole text: an id alone is nothing the
# reader can weigh, and a paraphrase is a different claim from the one written.
#
#   open listing (5 columns)  | id | ticket | age | note |
#   one session's (6 columns) | id | note | status | resolution | ticket |
#                             status is `open` or `closed`; resolution is the
#                             close as written, `<placement> — <reason>`, or `-`
#
# A markdown table, so it renders where a terminal renders markdown. Each column
# before the note is padded to its widest cell, so the short columns stay aligned
# where nothing renders it; the note and every column after it go unpadded, so a
# long note widens nothing. A `|` in a cell is
# escaped, so it renders as itself rather than as a column. Width is counted in
# characters, not bytes — notes are full of em dashes — by running awk in the C
# locale and not counting UTF-8 continuation bytes, which every awk does alike. The shape is read
# from the column count, so either listing pipes straight in; empty input
# prints nothing, header included.
journal_note_lines() {
  LC_ALL=C awk -F'\t' '
    function esc(v) { gsub(/\|/, "\\|", v); return v }
    function width(v,  t) { t = v; return length(v) - gsub(/[\200-\277]/, "", t) }
    function pad(v, n) { while (width(v) < n) v = v " "; return v }
    NF != 5 && NF != 6 {
      printf "journal_note_lines: a row of %d columns: %s\n", NF, $0 > "/dev/stderr"; bad = 1; next }
    shape && NF != shape {
      printf "journal_note_lines: a %d-column row in a %d-column listing: %s\n", NF, shape, $0 > "/dev/stderr"
      bad = 1; next }
    {
      shape = NF; n++
      if (NF == 5) { c[n,1] = $1; c[n,2] = $4; c[n,3] = $3; c[n,4] = $5 }
      else { c[n,1] = $1; c[n,2] = $6; c[n,3] = $5 == "open" ? "open" : "closed"
             c[n,4] = $5 == "open" ? "-" : $5; c[n,5] = $3 }
    }
    END {
      if (!n) exit bad
      cols = shape == 5 ? 4 : 5
      note = shape == 5 ? 4 : 2
      if (shape == 5) split("id ticket age note", h, " ")
      else split("id note status resolution ticket", h, " ")
      for (j = 1; j <= cols; j++) { w[j] = width(h[j])
        for (i = 1; i <= n; i++) { c[i,j] = esc(c[i,j]); if (width(c[i,j]) > w[j]) w[j] = width(c[i,j]) } }
      line = "|"; sep = "|"
      for (j = 1; j <= cols; j++) {
        line = line " " (j < note ? pad(h[j], w[j]) : h[j]) " |"
        sep = sep (j < note ? sprintf("%" w[j] + 2 "s", "") : "---") "|" }
      gsub(/ /, "-", sep); print line; print sep
      for (i = 1; i <= n; i++) { line = "|"
        for (j = 1; j <= cols; j++) line = line " " (j < note ? pad(c[i,j], w[j]) : c[i,j]) " |"
        print line }
      exit bad
    }'
}

# journal_kinds — the things we author and control, from the one list
# `inventory_kinds.txt`. /inventory censuses these; a note is placed by becoming one.
journal_kinds() {
  grep -v '^#' "$(dirname "${BASH_SOURCE[0]}")/inventory_kinds.txt" | grep -v '^$'
}

# journal_close_re — the grammar a close must match: `<placement> — <reason>`.
#
# The placement is a closed set, so closes group and count. `ticket` is named
# here rather than in inventory_kinds.txt because /inventory cannot census Jira;
# `-` is work that produced nothing we author.
#
# The reason is required: a `-` placement points at nothing, so the reason is the
# note's only account of itself.
journal_close_re() {
  local kinds
  kinds=$(journal_kinds | paste -sd'|')
  printf '^((%s)(:[a-z0-9][a-z0-9:._-]*)?|ticket:%s|-) — .+$' "$kinds" "$JOURNAL_TICKET_RE"
}

# journal_hist CALLER — the history file: $JOURNAL_HIST, else the nearest
# `.claude/session_history.md` at or above $PWD. Fails naming CALLER.
journal_hist() {
  if [[ -n "${JOURNAL_HIST:-}" ]]; then printf '%s\n' "$JOURNAL_HIST"; return 0; fi
  local d="$PWD"
  while :; do
    [[ -f "$d/.claude/session_history.md" ]] && { printf '%s\n' "$d/.claude/session_history.md"; return 0; }
    [[ "$d" == "/" ]] && break
    d=$(dirname "$d")
  done
  echo "$1: no .claude/session_history.md at or above $PWD (set JOURNAL_HIST)" >&2
  return 1
}

# An entry header: `## <YYYY-MM-DD> <HH:MM> …`. journal.sh writes one per entry
# and both readers key on it. POSIX ERE, so the same string serves grep -E and awk.
# shellcheck disable=SC2034  # read by the scripts that source this file
JOURNAL_HEADER_RE='^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] '

# journal_check_headings CALLER HIST — fails when the file holds a `## ` heading
# JOURNAL_HEADER_RE does not match. A heading a reader cannot parse is an error,
# never a quieter result: journal_scan.sh drops that entry, so /timelog reads a
# short history as nothing left to bill, and journal_queue.sh lists the items
# under it with no opened time, which sorts first and pins them to the top of
# the oldest-first slice for good.
journal_check_headings() {
  local all parsed
  all=$(grep -c '^## ' "$2" || true)
  parsed=$(grep -cE "$JOURNAL_HEADER_RE" "$2" || true)
  [[ "$all" -eq "$parsed" ]] && return 0
  echo "$1: $2 holds $all '## ' headings and $parsed this reader can parse; journal.sh did not write the rest — move them out of the file before a reader can report on it" >&2
  return 1
}

# Executed rather than sourced, the file takes one argument, --self-test, and
# runs every rule above over fixtures. The guard compares this file with the
# script being run, so a script sourcing it with its own --self-test in $1 never
# reaches the branch. It runs last, once every function is defined.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${1:-}" == "--self-test" ]] || {
    echo "journal_lib.sh: source this file; executed, it takes only --self-test" >&2; exit 2; }
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  matches() { [[ "$1" =~ $2 ]]; }
  for k in ABC-1 XYZ-12345; do
    tap_run "a ticket key with two capitals is a ticket: $k" matches "$k" "^$JOURNAL_TICKET_RE$"
  done
  for k in R-31 abc-1 ABC-; do
    tap_fails "a key with one capital, lower case or no number is not: $k" \
      matches "$k" "^$JOURNAL_TICKET_RE$"
  done
  re=$(journal_close_re)
  for c in 'skill — r' 'script:memory_lib.sh — r' 'ticket:ABC-7 — r' '- — r'; do
    tap_run "a close with a known placement and a reason is accepted: $c" matches "$c" "$re"
  done
  for c in 'skill:x' 'skill:x — ' 'wiki — r' 'ticket:R-31 — r' 'ticket — r'; do
    tap_fails "a close missing a reason, a known placement or a ticket is refused: $c" \
      matches "$c" "$re"
  done
  mkdir -p "$fx/a/.claude" "$fx/a/b/c" "$fx/none"
  touch "$fx/a/.claude/session_history.md"
  tap_is "the history is found by walking up" \
    "$(cd "$fx/a/b/c" && JOURNAL_HIST='' journal_hist t)" "$fx/a/.claude/session_history.md"
  tap_is "JOURNAL_HIST overrides the walk" \
    "$(cd "$fx/none" && JOURNAL_HIST=/x journal_hist t)" /x
  walk_none() { (cd "$fx/none" && JOURNAL_HIST='' journal_hist t) 2>"$fx/err"; }
  tap_fails "no history above is an error" walk_none
  tap_run "and the error names the caller" \
    grep -q '^t: no .claude/session_history.md' "$fx/err"
  printf '## 2026-10-14 09:00 a\n## 2026-10-14 09:01 b\n' > "$fx/ok.md"
  printf '## 2026-10-14 09:00 a\n## Notes\n' > "$fx/bad.md"
  tap_run "a parseable history passes the heading check" \
    journal_check_headings t "$fx/ok.md"
  check_bad() { journal_check_headings t "$fx/bad.md" 2>"$fx/err"; }
  tap_fails "an unparseable heading fails it" check_bad
  tap_run "with both counts" grep -q '2 .## . headings and 1' "$fx/err"
  tap_is "an open listing renders as a table row of its id and whole text" \
    "$(journal_note_lines < <(printf 'ab12\t2026-01-01 00:00\t3d\tABC-1\tTitle — the whole detail\n'))" \
    $'| id   | ticket | age | note |\n|------|--------|-----|---|\n| ab12 | ABC-1  | 3d  | Title — the whole detail |'
  tap_is "a session's open and closed notes render as rows" \
    "$(journal_note_lines < <(printf 'cd34\t2026-01-01 00:00\t-\topened\topen\tstill here\nef56\t2026-01-01 00:00\tABC-2\topened, closed\tskill — r\tgone\n'))" \
    $'| id   | note | status | resolution | ticket |\n|------|---|---|---|---|\n| cd34 | still here | open | - | - |\n| ef56 | gone | closed | skill — r | ABC-2 |'
  tap_is "a pipe in a note is escaped" \
    "$(journal_note_lines < <(printf 'gh78\t2026-01-01 00:00\t3d\t-\ta | b\n') | tail -1)" \
    '| gh78 | -      | 3d  | a \| b |'
  tap_is "empty input prints nothing, header included" \
    "$(journal_note_lines < <(printf ''))" ""
  tap_fails "a listing of mixed shapes is refused" \
    journal_note_lines < <(printf 'a\t1\t2\t3\t4\nb\t1\t2\t3\t4\t5\n')
  tap_fails "a short row is refused" journal_note_lines < <(printf 'a\tb\n')
  tap_end
fi
