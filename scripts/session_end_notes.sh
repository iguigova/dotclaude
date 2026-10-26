#!/usr/bin/env bash
# SessionEnd hook: place what the ending session noticed, unattended.
#
# The harness runs this with the hook payload on stdin — session_id, cwd and
# reason — when a session ends for any reason (clear, resume, logout,
# prompt_input_exit, other). It decides whether there is anything to place and,
# if so, starts a detached headless run of `/notes --session <id>`.
#
# Usage:
#   session_end_notes.sh            # reads the hook payload on stdin
#   session_end_notes.sh --dry-run  # same decision, prints the command, runs nothing
#   session_end_notes.sh --self-test
#
# It starts a model run, so it refuses to do so on anything but evidence:
#
#   1. The ending session opened at least one note that is still open.
#      Nothing open means nothing to place, so no run — this is the whole
#      threshold. There is no count, no age and no schedule.
#   2. No other end-run holds the lock. The lock is non-blocking: a second one
#      exits rather than queueing, because the notes it would place stay open
#      and the next session end reaches them.
#
# The notes are read, and the run started, in the project that holds the nearest
# .claude/session_history.md at or above the session's cwd — the history
# journal.sh wrote to — so a session inside a nested repo reaches its notes.
#
# The run is detached with setsid, not left as a child. The harness is exiting,
# so a child in its process group is killed with it, and the harness's own async
# hook mechanism defaults to a 15s timeout — shorter than any real run. Detaching
# is what lets the run outlive the session that triggered it.
#
# session_end_run.sh is the detached half: it holds the lock, runs the placer, and
# reports. The placer commits its own work through tooling_commit.sh, as /notes
# requires of every run.
#
# The deciding must finish in well under a second. A SessionEnd hook is killed at
# 1500 ms, and a `timeout:` in the hook config raises only the harness's outer
# wait, not that kill. This measures 40 ms over an 11,479-line history, so the
# budget is not close — but anything added here is spent against 1500 ms, not
# against the run, which is detached and unbounded.
#
# A failure here costs one line: the harness prints `SessionEnd hook [cmd] failed`
# to stderr and the session ends normally. SessionEnd is not wired for blocking,
# so exit code 2 means nothing special. Nothing is lost either way, because only
# `journal.sh --placed` closes a note: a run that dies leaves its notes open and
# the next session end reaches them.
#
# Output goes to $LOG, one line per decision, so every firing is accountable
# whether or not it ran anything. Read it with `tail ~/.claude/logs/session_end.log`.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${SESSION_END_LOG:-$HOME/.claude/logs/session_end.log}"
LOCK="${SESSION_END_LOCK:-$HOME/.claude/state/session_end_notes.lock}"
# shellcheck source=journal_lib.sh
. "$SCRIPTS_DIR/journal_lib.sh"

# The classifier mode, not bypass: an unattended run still gets a decision on each
# permission, and everything it writes is in a git repo that can be reverted.
PERMISSION_MODE="${SESSION_END_PERMISSION_MODE:-auto}"

say() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

# project_of CWD — the project whose history the session wrote: the directory
# holding the nearest .claude/session_history.md at or above CWD, found exactly
# as journal.sh finds it, so a session in a nested repo reaches the same notes.
project_of() {
  local hist
  hist=$(cd "$1" && journal_hist session_end_notes.sh 2>/dev/null) || return 1
  dirname "$(dirname "$hist")"
}

# decide CWD SESSION — echoes "run" or "skip: <why>"; writes nothing, starts nothing.
decide() {
  local cwd="$1" sid="$2" project
  [[ -n "$sid" ]] || { echo "skip: the payload carried no session id"; return; }
  [[ -d "$cwd" ]] || { echo "skip: cwd $cwd does not exist"; return; }
  project=$(project_of "$cwd") || {
    echo "skip: no .claude/session_history.md at or above $cwd"; return; }
  local ids status
  ids=$(cd "$project" && "$SCRIPTS_DIR/journal_queue.sh" --opened-by "$sid" --ids 2>/dev/null) && status=0 || status=$?
  [[ "$status" -eq 0 ]] || {
    echo "skip: the queue could not be read at $project (journal_queue.sh exit $status)"; return; }
  [[ -n "$ids" ]] || { echo "skip: session $sid has no open notes"; return; }
  echo "run"
}


# start_run PREFIX CMD… — detach the run. Everything it then does lives in
# session_end_run.sh, which holds the lock, runs CMD and reports.
# It is a file rather than a string passed to `bash -c` because a string cannot be
# read, linted or self-tested, which is how its first version came to redirect a
# whole run's output into a file named after a flag.
start_run() {
  setsid nohup "$SCRIPTS_DIR/session_end_run.sh" \
    "$LOCK" "$LOG" "$CWD" "$1" "${@:2}" </dev/null >/dev/null 2>&1 &
  disown || true
}

# ---------------------------------------------------------------- self-test

self_test() {
  local rc=0 tmp out repo e2e
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  # Every run started below, and every process it starts, inherits these, so no
  # case can snapshot the real repos.
  export SESSION_END_REPOS="$tmp"
  check() {  # DESCRIPTION WANT-PREFIX GOT
    if [[ "$3" == "$2"* ]]; then echo "  ok   $1"
    else printf '  FAIL %s\n    want prefix: %s\n    got:         %s\n' "$1" "$2" "$3" >&2; rc=1; fi
  }
  echo "session_end_notes.sh --self-test"

  check "no session id is a skip, never a run" "skip: the payload carried no session id" \
    "$(decide "$tmp" "")"
  check "a cwd that is gone is a skip" "skip: cwd" "$(decide "$tmp/absent" "s1")"
  check "a directory with no history above it is a skip" \
    "skip: no .claude/session_history.md at or above $tmp" "$(decide "$tmp" "s1")"

  repo="$tmp/project"; mkdir -p "$repo/.claude"
  printf '# Log\n' > "$repo/.claude/session_history.md"
  check "a project with an empty queue is a skip" \
    "skip: session s1 has no open notes" "$(decide "$repo" "s1")"

  JOURNAL_HIST="$repo/.claude/session_history.md" CLAUDE_CODE_SESSION_ID=s1 \
    "$SCRIPTS_DIR/journal.sh" -t "chore: x" -b b -n "something noticed" >/dev/null
  check "a project with one open note is a run" "run" "$(decide "$repo" "s1")"
  check "another session's open note does not make this one a run" \
    "skip: session s2 has no open notes" "$(decide "$repo" "s2")"

  # A session inside a nested repo journals to the history above it, so its
  # notes are reached from there: the repo it sat in is not the project.
  mkdir -p "$repo/api/product"; git -C "$repo/api/product" init -q 2>/dev/null
  check "a session in a nested repo reaches the project's notes" "run" \
    "$(decide "$repo/api/product" "s1")"
  check "and the run is started in the project, not the nested repo" "$repo" \
    "$(project_of "$repo/api/product")"

  # This is the case that reported "no open notes" for a queue it could not
  # read at all: absence of evidence read as evidence of absence.
  mkdir -p "$tmp/garbled/.claude"; printf '## not a heading journal.sh wrote\n' \
    > "$tmp/garbled/.claude/session_history.md"
  check "a history the queue cannot read is named as unreadable, not as empty" \
    "skip: the queue could not be read" "$(decide "$tmp/garbled" "s1")"

  # The lock is the last gate and it is non-blocking: a held lock must return,
  # not wait, or a session end would hang on a run that is already going.
  out=$(flock -n "$tmp/l" -c "flock -n '$tmp/l' -c true && echo taken || echo held")
  check "a held lock reports held rather than waiting" "held" "$out"

  # The regression test for the shift: a detached run's output must land in $LOG.
  # It once landed in a file named `-p`, because $2 was read after the shift that
  # made the positional parameters the command rather than the paths.
  LOCK="$tmp/lock"; LOG="$tmp/run.log"; CWD="$tmp"; : > "$LOG"
  start_run "probe" bash -c 'echo MARKER-FROM-THE-RUN'
  for _ in $(seq 40); do command grep -q 'run finished' "$LOG" 2>/dev/null && break; sleep 0.1; done
  check "the run's own output reaches the log" "MARKER-FROM-THE-RUN" \
    "$(command grep -m1 MARKER-FROM-THE-RUN "$LOG" || echo MISSING)"
  check "the log records the run starting and its exit status" "probe run finished rc=0" \
    "$(command grep -m1 'run finished' "$LOG" | cut -d' ' -f2-)"
  check "nothing was written to a file named after a flag" "0" \
    "$(find "$tmp" -maxdepth 1 -name '-*' | wc -l)"

  # Everything above calls decide() directly. These drive the script itself, so
  # the payload parsing and the dry-run branch — which live only in the main body
  # and which no case above reaches — are covered too.
  local e2e="$tmp/e2e"; mkdir -p "$e2e/.claude"
  git -C "$e2e" init -q 2>/dev/null
  printf '# Log\n' > "$e2e/.claude/session_history.md"
  JOURNAL_HIST="$e2e/.claude/session_history.md" CLAUDE_CODE_SESSION_ID=e-1 \
    "$SCRIPTS_DIR/journal.sh" -t "chore: x" -b b -n "noticed" >/dev/null

  drive() {  # PAYLOAD [FLAG] — the hook, invoked as the harness invokes it
    printf '%s' "$1" | SESSION_END_LOG="$tmp/e2e.log" \
      "$0" ${2:-} 2>&1
  }
  : > "$tmp/e2e.log"
  out=$(drive "{\"session_id\":\"e-1\",\"cwd\":\"$e2e\",\"reason\":\"clear\"}" --dry-run)
  check "a payload for a session with an open note would run" "1" \
    "$(grep -c 'would run' <<<"$out")"
  check "the command it would run names that session" "1" \
    "$(grep -c -- '--session e-1' <<<"$out")"

  out=$(drive "{\"session_id\":\"e-2\",\"cwd\":\"$e2e\",\"reason\":\"clear\"}" --dry-run)
  check "a session with nothing open prints nothing and exits 0" "" "$out"

  # Malformed stdin must skip, not crash: the harness sends what it sends.
  check "a payload that is not JSON is a skip, not a failure" "0" \
    "$(drive "not json at all" --dry-run >/dev/null 2>&1; echo $?)"
  check "every firing left a line in the log, skips included" "3" \
    "$(grep -c "^20" "$tmp/e2e.log")"
  return $rc
}

[[ "${1:-}" == --self-test ]] && { self_test; exit $?; }

DRY=0
[[ "${1:-}" == --dry-run ]] && DRY=1

mkdir -p "$(dirname "$LOG")" "$(dirname "$LOCK")"

payload=$(cat)
SID=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
CWD=$(jq -r '.cwd // empty'        <<<"$payload" 2>/dev/null || true)
REASON=$(jq -r '.reason // "other"' <<<"$payload" 2>/dev/null || echo other)

verdict=$(decide "$CWD" "$SID")
if [[ "$verdict" != run ]]; then
  say "reason=$REASON session=${SID:-none} $verdict"
  exit 0
fi
CWD=$(project_of "$CWD")

CMD=(claude -p "/notes --session $SID"
     --permission-mode "$PERMISSION_MODE"
     --append-system-prompt "You were started by the SessionEnd hook. Nobody is watching, so propose nothing: a close whose placement is - has no gate, so it is the user's call and the note stays open; a ticket placement writes to a shared tracker, so that note stays open too.")

if [[ "$DRY" -eq 1 ]]; then
  say "reason=$REASON session=$SID dry-run, would run: ${CMD[*]}"
  printf '%s\n' "would run (cwd=$CWD): ${CMD[*]}"
  exit 0
fi

start_run "reason=$REASON session=$SID" "${CMD[@]}"
exit 0
