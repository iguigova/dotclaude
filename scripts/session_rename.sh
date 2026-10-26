#!/usr/bin/env bash
# session_rename.sh — write a title record to the current Claude Code session.
#
# A session title is derived state, not a field: the CLI resolves it from the
# LAST {"type":"custom-title"} record in the session transcript, so a rename is
# one appended line and an undo is another. A custom-title outranks any
# ai-title record the auto-titler appends after it. The CLI reads the record
# when it loads the session, so the running session's header keeps its old
# title until the session is resumed. Requires CLAUDE_CODE_SESSION_ID,
# which the harness exports into every Bash tool call.
#
# SESSION_RENAME_TRANSCRIPT overrides the target file, for --self-test.
#
#   session_rename.sh <title>
#   session_rename.sh --self-test   # renames a scratch transcript twice
set -euo pipefail

# The last record is the one the CLI resolves, so the test reads the last one
# after two renames, and drives the refusal of a call made outside a session.
if [ "${1:-}" = --self-test ]; then
  rt=$(mktemp); trap 'rm -f "$rt"' EXIT
  printf '{"type":"mode","mode":"normal"}\n' > "$rt"
  CLAUDE_CODE_SESSION_ID=test-sid SESSION_RENAME_TRANSCRIPT="$rt" \
    bash "$0" 'XYZ-9999 PR "quoted"' >/dev/null
  CLAUDE_CODE_SESSION_ID=test-sid SESSION_RENAME_TRANSCRIPT="$rt" \
    bash "$0" 'XYZ-9999 PR' >/dev/null
  got=$(grep '"type":"custom-title"' "$rt" | jq -r '.customTitle + "|" + .sessionId' | paste -sd'/')
  CLAUDE_CODE_SESSION_ID='' SESSION_RENAME_TRANSCRIPT="$rt" bash "$0" x >/dev/null 2>&1 \
    && nosid=written || nosid=refused
  want='XYZ-9999 PR "quoted"|test-sid/XYZ-9999 PR|test-sid'
  if [ "$got" = "$want" ] && [ "$nosid" = refused ]; then
    echo "session_rename self-test: PASS (each rename appends one record, the" \
      "last is the newest, quotes survive, a call outside a session is refused)"
    exit 0
  fi
  echo "session_rename self-test: FAIL (want [$want] got [$got]; no session id: $nosid)" >&2
  exit 1
fi

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: session_rename.sh <title>" >&2
  exit 2
fi
title=$1

sid=${CLAUDE_CODE_SESSION_ID:-}
if [ -z "$sid" ]; then
  echo "session_rename.sh: CLAUDE_CODE_SESSION_ID is unset — not inside a session" >&2
  exit 1
fi

transcript=${SESSION_RENAME_TRANSCRIPT:-}
if [ -z "$transcript" ]; then
  for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do
    if [ -f "$f" ]; then transcript=$f; break; fi
  done
fi
if [ ! -f "$transcript" ]; then
  echo "session_rename.sh: no transcript found for session $sid" >&2
  exit 1
fi

jq -cn --arg t "$title" --arg s "$sid" \
  '{type: "custom-title", customTitle: $t, sessionId: $s}' >> "$transcript"

echo "title record written: $title (shows once the session is resumed)"
