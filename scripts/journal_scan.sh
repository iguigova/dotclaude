#!/usr/bin/env bash
# Read-only reader for a project's session history: emits every entry, grouped by
# ticket, as JSON. The single source of truth for *parsing* the journal format
# that journal.sh *writes* — consumers (e.g. /timelog) call this instead of
# re-specifying the header regex, entry id and ticket token, so the read and write
# sides of the format can never drift apart.
#
# Target file: the nearest `.claude/session_history.md` at or above $PWD
# (override with JOURNAL_HIST).
#
# Usage:
#   journal_scan.sh [TICKET]      # optional: restrict to one ticket key
#   journal_scan.sh --self-test   # round-trips journal.sh entries through the scan
#   journal_scan.sh --help        # this header
#
# The scan reads the whole history every time. What a reader has already dealt
# with is recorded on the entry itself — a `**Billed:**` mark — never as a cutoff
# in time, so a run can never skip an entry it did not look at.
#
# journal.sh writes one `## ` heading per entry, and journal_lib.sh states the
# pattern both readers match. A heading neither matches is an error and this scan
# exits 1: a file it cannot fully read is never an empty result, because a caller
# that bills reads "no entries" as "nothing to bill" and says so.
#
# Output (stdout) — JSON:
#   {
#     "tickets":   { "XYZ-1234": [ {"ts","id","header","billed","session","block"} , … ] },
#     "no_ticket": [ {"ts","id","header","billed","session","block"} , … ]  # no ticket key
#   }
#
# `id` is the entry's minted id, or null for an entry written before ids existed.
# A mark can only name an id, so an entry without one can never be billed.
#
# `session` is the id on the entry's `**Session:**` line, or null for an entry
# written outside Claude Code or before the line existed. A caller filters on it
# to act on the work of one session — a bare `/timelog` bills only its own.
#
# `billed` holds the text of the entry's `**Billed:**` line, or null: the work is
# paid for, or was marked `skipped — <why>`. The scan reports it and never acts on
# it, because billing is one reader's concern — /timelog skips a billed entry to
# avoid a double-bill, and every other reader must still see it, since its notes
# and its `via` are facts about the work like any other.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=journal_lib.sh
. "$SCRIPTS_DIR/journal_lib.sh"

# ---------------------------------------------------------------- self-test

# Entries are written by journal.sh, never by hand, so the test proves the writer
# and this reader agree on the format rather than that the reader parses a guess.
self_test() {
  local h rc=0 got old
  h=$(mktemp)
  printf '# Log\n\n<!-- timelog 2026-01-01 00:00Z — baseline -->\n' > "$h"
  # Unset by default, so the fixture reads the same whether or not the test runs
  # inside a session; `ws` writes an entry that names one.
  w() { env -u CLAUDE_CODE_SESSION_ID JOURNAL_HIST="$h" "$SCRIPTS_DIR/journal.sh" "$@" >/dev/null; }
  ws() { JOURNAL_HIST="$h" CLAUDE_CODE_SESSION_ID="$1" "$SCRIPTS_DIR/journal.sh" "${@:2}" >/dev/null; }
  scan() {  # JQ
    JOURNAL_HIST="$h" "$0" | jq -r "$1"
  }
  check() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then echo "  ok   $1"
    else echo "  FAIL $1: want [$2] got [$3]" >&2; rc=1; fi
  }
  echo "journal_scan.sh --self-test"
  w -t "XYZ-9999 round-trip" -b b
  w -t "chore: no ticket" -b "a bullet naming XYZ-1234 does not group the entry"
  w -t "chore: radar row R-31" -b b
  got=$(scan '[(.tickets|keys|join(",")), (.no_ticket|length)] | @tsv')
  check "the header key groups; a key only mentioned in a bullet does not" \
    $'XYZ-9999\t2' "$got"
  bill() {  # TOPIC MARK — journal it, then mark it billed, as a caller does
    local e
    e=$(env -u CLAUDE_CODE_SESSION_ID JOURNAL_HIST="$h" "$SCRIPTS_DIR/journal.sh" -t "$1" -b b \
      | sed -nE 's/^journaled → ## [0-9: -]+ \[([a-z0-9]+)\].*/\1/p')
    JOURNAL_HIST="$h" "$SCRIPTS_DIR/journal.sh" --bill "$e: $2" >/dev/null
  }
  bill "PR Review: repo#1 (XYZ-9999 t)" "XYZ-9999 worklog 41233"
  bill "chore: billed, not billable" "skipped — chore work, not billed"
  got=$(scan '[(.tickets["XYZ-9999"]|length), (.no_ticket|length)] | @tsv')
  check "a billed entry stays in its bucket, for the readers that are not billing" \
    $'2\t3' "$got"
  got=$(scan '.tickets["XYZ-9999"] | map(.billed // "null") | join(",")')
  check "each entry reports its own Billed line, or null" "null,XYZ-9999 worklog 41233" "$got"
  got=$(scan '.tickets["XYZ-9999"] | map(.id | length) | join(",")')
  check "each entry reports its id" "4,4" "$got"
  ws s-1 -t "XYZ-9999 from a session" -b b
  got=$(scan '.tickets["XYZ-9999"] | map(.session // "null") | join(",")')
  check "each entry reports the session that wrote it, or null" "null,null,s-1" "$got"
  printf '<!-- timelog 2099-01-01 00:00Z — a watermark left by an older writer -->\n' >> "$h"
  got=$(scan '[(.tickets["XYZ-9999"]|length), (.no_ticket|length)] | @tsv')
  check "a watermark left in the file is text, and cuts nothing off" $'3\t3' "$got"
  # A history this scan cannot read must not read as a history with nothing in
  # it: every caller that bills takes an empty result as nothing left to bill.
  old=$(mktemp)
  printf '# Log\n\n## 2026-06-09 — an entry an older writer left\n\n- b\n' > "$old"
  check "a heading this scan cannot read is an error, not an empty result" fail \
    "$(JOURNAL_HIST="$old" "$0" >/dev/null 2>&1 && echo ok || echo fail)"
  printf '# Log\n' > "$old"
  check "a history with no entries yet scans clean" ok \
    "$(JOURNAL_HIST="$old" "$0" >/dev/null 2>&1 && echo ok || echo fail)"
  check "--help answers without a history to resolve" ok \
    "$(cd / && env -u JOURNAL_HIST "$SCRIPTS_DIR/journal_scan.sh" --help 2>/dev/null | grep -q '^Usage:' && echo ok || echo fail)"
  rm -f "$old" "$h"
  return $rc
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  --help)      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
esac

# ---------------------------------------------------------------- scan

HIST=$(journal_hist journal_scan.sh) || exit 1
ONLY="${1:-}"
journal_check_headings journal_scan.sh "$HIST" || exit 1

# Emit one JSON object per entry block (header + body; the title and any comment
# line an older writer left are skipped). The ticket is the first TICKET-NNN token
# on the header line, and nowhere else: the header is what the writer was given as
# the entry's subject, while a key in a bullet is something the work referred to.
# Grouping on a mention would offer a chore entry as billable work on a ticket it
# only talked about. String fields are JSON-escaped; newlines → \n.
awk -v ticket_re="$JOURNAL_TICKET_RE" -v header_re="$JOURNAL_HEADER_RE" '
  function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"",s); return s }
  function flush(){
    if (have) {
      tk = match(hdr, ticket_re) ? "\"" substr(hdr, RSTART, RLENGTH) "\"" : "null"
      bl = billed == "" ? "null" : "\"" esc(billed) "\""
      eid = entry_id == "" ? "null" : "\"" entry_id "\""
      se = session == "" ? "null" : "\"" esc(session) "\""
      printf "{\"ts\":\"%s\",\"id\":%s,\"ticket\":%s,\"billed\":%s,\"session\":%s,\"block\":\"%s\",\"header\":\"%s\"}\n",
        ts, eid, tk, bl, se, blk, esc(hdr)
    }
  }
  /^<!-- / { next }                              # skip watermark / comment lines
  /^# /    { next }                              # skip the title
  $0 ~ header_re {
    flush()
    have = 1; hdr = $0; ts = $2 " " $3
    billed = ""; session = ""
    entry_id = match(hdr, /\[[a-z0-9]+\]/) ? substr(hdr, RSTART + 1, RLENGTH - 2) : ""
    blk = esc($0); next
  }
  /^\*\*Billed:\*\* /  { if (have) billed = substr($0, length("**Billed:** ") + 1) }
  /^\*\*Session:\*\* / { if (have) session = $2 }
  { if (have) blk = blk "\\n" esc($0) }
  END { flush() }
' "$HIST" | jq -s --arg only "$ONLY" '
    (map(select($only == "" or .ticket == $only))) as $rows
    | { tickets:  ( $rows | map(select(.ticket != null))
                          | group_by(.ticket)
                          | map({ key: .[0].ticket, value: . }) | from_entries ),
        no_ticket: ( $rows | map(select(.ticket == null)) ) }
  '
