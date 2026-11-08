#!/usr/bin/env bash
# SessionEnd hook: publish ~/.claude's public part whenever it has moved.
#
# The harness runs this when any session ends. When ~/.claude's HEAD is a
# commit no run has handled yet, it starts a detached run that exports it with
# `dotclaude_export.sh` into the public clone and pushes the clone, which
# publishes the page. A source commit is handled once, whatever the outcome:
# exported, nothing to export, or refused. So a commit that touches nothing
# public costs one export, and a refusal is reported once rather than on every
# session end. A run counts as handled only when it ends, so a run killed
# partway leaves its commit for the next session end to try again; if it died
# mid-export, the clone holds its half-made copy, so that retry is refused as a
# dirty clone and opens a note.
#
# Usage:
#   session_end_export.sh            # reads the hook payload on stdin
#   session_end_export.sh --dry-run  # same decision, prints it, runs nothing
#   session_end_export.sh --run SHA  # the detached half; not for direct use
#   session_end_export.sh --self-test
#
# A refused export or a failed push opens one note in the clone's session
# history, naming the source commit and the last line the failure printed.
# The next ~/.claude commit is a new source commit, so it tries again.
#
# The run is detached with detach.sh, because a SessionEnd hook is killed at
# 1500 ms and the export runs the copy's whole selftest. It holds a
# non-blocking lock for its whole life, so a second run exits rather than
# queueing, and it reads the handled commit again under the lock, so two
# session ends racing past the first check export once.
#
# Every firing leaves one line in $LOG, skips included; the export's and the
# push's output follow the run's start line. Read it with
# `tail ~/.claude/logs/session_end.log`.
#
# DOTCLAUDE_SRC overrides the source repo (default ~/.claude), DOTCLAUDE_CLONE
# the public clone (default ~/src/oceanhue/dotclaude).
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${DOTCLAUDE_SRC:-$HOME/.claude}"
CLONE="${DOTCLAUDE_CLONE:-$HOME/src/oceanhue/dotclaude}"
LOG="${SESSION_END_LOG:-$HOME/.claude/logs/session_end.log}"
STATE="${SESSION_END_EXPORT_STATE:-$HOME/.claude/state}"
EXPORT="${SESSION_END_EXPORT_CMD:-$SCRIPTS_DIR/dotclaude_export.sh}"
JOURNAL="${SESSION_END_EXPORT_JOURNAL:-$SCRIPTS_DIR/journal.sh}"

say() { printf '%s export %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }

handled() { cat "$STATE/dotclaude_export.handled" 2>/dev/null; }
done_with() { echo "$1" >"$STATE/dotclaude_export.handled"; }

decide() {  # -> "run <sha>" or "skip: <why>"
  local sha
  sha=$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null) \
    || { echo "skip: $SRC has no commit"; return; }
  [[ -d "$CLONE/.git" ]] || { echo "skip: $CLONE is not a clone"; return; }
  [[ "$sha" != "$(handled)" ]] || { echo "skip: $sha already handled"; return; }
  echo "run $sha"
}

# fail <sha> <what> <output> — log it and open the one note this commit gets.
fail() {
  local last
  last=$(grep -v '^[[:space:]]*$' <<<"$3" | tail -n 1)
  say "$1 $2: $last"
  (cd "$CLONE" && env -u CLAUDE_CODE_SESSION_ID "$JOURNAL" \
    -t "chore: dotclaude export" \
    -b "The session-end export of ~/.claude $1 stopped: $2." \
    -n "dotclaude $2 — ~/.claude $1: $last; see ~/.claude/logs/session_end.log") \
    >>"$LOG" 2>&1 || say "$1 the note could not be written"
}

run() {  # <sha> — the detached half
  local sha=$1 out
  exec 9>"$STATE/dotclaude_export.lock" || { say "$sha the lock could not be opened"; return 0; }
  flock -n 9 || { say "$sha another export holds the lock, skipped"; return 0; }
  [[ "$(handled)" != "$sha" ]] || { say "$sha handled by a racing run, skipped"; return 0; }
  say "$sha run started"
  out=$(DOTCLAUDE_SRC="$SRC" "$EXPORT" "$CLONE" 2>&1) \
    || { printf '%s\n' "$out" >>"$LOG"; done_with "$sha"; fail "$sha" "export refused" "$out"; return 0; }
  printf '%s\n' "$out" >>"$LOG"
  out=$(git -C "$CLONE" push -q origin HEAD 2>&1) \
    || { printf '%s\n' "$out" >>"$LOG"; done_with "$sha"; fail "$sha" "push failed" "$out"; return 0; }
  done_with "$sha"
  say "$sha run finished, $(git -C "$CLONE" rev-parse --short HEAD) is pushed"
}

start_run() {  # <sha>
  "$SCRIPTS_DIR/detach.sh" bash "$SCRIPTS_DIR/$(basename "$0")" --run "$1"
}

hook() {  # <dry>
  local reason verdict
  reason=$(jq -r '.reason // "other"' 2>/dev/null)
  verdict=$(decide)
  if [[ "$verdict" != run* ]]; then say "reason=${reason:-other} $verdict"; return; fi
  if (( $1 )); then
    say "reason=$reason dry-run, would export ${verdict#run }"
    echo "would export ${verdict#run }"
    return
  fi
  start_run "${verdict#run }"
}

# ---------------------------------------------------------------- self-test

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local tmp out sha
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  export SESSION_END_LOG="$tmp/log" SESSION_END_EXPORT_STATE="$tmp/state"
  export SESSION_END_EXPORT_CMD="$tmp/export" SESSION_END_EXPORT_JOURNAL="$tmp/journal"
  export DOTCLAUDE_SRC="$tmp/src" DOTCLAUDE_CLONE="$tmp/clone"
  LOG=$SESSION_END_LOG STATE=$SESSION_END_EXPORT_STATE EXPORT=$SESSION_END_EXPORT_CMD
  JOURNAL=$SESSION_END_EXPORT_JOURNAL SRC=$DOTCLAUDE_SRC CLONE=$DOTCLAUDE_CLONE
  mkdir -p "$STATE"; : >"$LOG"
  g() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }
  # The fake export commits one file in the clone, or refuses when the source
  # holds a file named refuse; the fake journal records its arguments.
  # shellcheck disable=SC2016  # the fake export expands their own variables
  printf '#!/usr/bin/env bash\n[[ -e $DOTCLAUDE_SRC/refuse ]] && { echo "x.sh:1 [denylist]"; echo "refused: hits"; exit 1; }\ndate +%%s%%N >"$1/f"; git -C "$1" add f; git -C "$1" -c user.name=t -c user.email=t@example.com commit -qm export; echo exported\n' >"$EXPORT"
  # shellcheck disable=SC2016  # the fake journal expands its own variables
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" "sid=${CLAUDE_CODE_SESSION_ID-unset}" >>"%s/notes"\n' "$tmp" >"$JOURNAL"
  chmod +x "$EXPORT" "$JOURNAL"
  check() {  # <description> <want prefix> <got>
    if [[ "$3" == "$2"* ]]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }

  check "a source with no commit is a skip" "skip: $SRC has no commit" "$(decide)"
  git init -q "$SRC"; g "$SRC" commit -q --allow-empty -m one
  git init -q --bare "$tmp/origin.git"; git clone -q "$tmp/origin.git" "$CLONE" 2>/dev/null
  g "$CLONE" commit -q --allow-empty -m root; g "$CLONE" push -q origin HEAD 2>/dev/null
  sha=$(git -C "$SRC" rev-parse --short HEAD)
  check "a commit never handled is a run" "run $sha" "$(decide)"
  out=$(flock -n "$STATE/dotclaude_export.lock" -c "bash '$0' --run '$sha'; tail -1 '$LOG'")
  # run holds its lock on fd 9 until its process exits, so each run below is
  # a subshell: one run in this shell would hold the lock against the next.
  check "a held lock skips the run" "1" "$(grep -c 'holds the lock' <<<"$out")"
  # The fake export kills the run that started it, as a unit's end would.
  # shellcheck disable=SC2016  # the fake export expands its own variables
  printf '#!/usr/bin/env bash\nkill -KILL "$(cat "%s/run.pid")"\n' "$tmp" >"$tmp/killer"
  chmod +x "$tmp/killer"
  { (echo "$BASHPID" >"$tmp/run.pid"; EXPORT="$tmp/killer" run "$sha"); } 2>/dev/null
  until flock -n "$STATE/dotclaude_export.lock" true; do sleep 0.05; done
  check "a run killed partway leaves its commit to run again" "run $sha" "$(decide)"
  (CLAUDE_CODE_SESSION_ID=ending run "$sha")
  check "a run exports and pushes the clone" "$(git -C "$CLONE" rev-parse HEAD)" \
    "$(git -C "$tmp/origin.git" rev-parse HEAD)"
  check "and logs that it is pushed" "1" "$(grep -c "$sha run finished" "$LOG")"
  check "a handled commit is a skip" "skip: $sha already handled" "$(decide)"
  (run "$sha")
  check "a racing run exports nothing more" "1" "$(grep -c '^exported' "$LOG")"

  touch "$SRC/refuse"; g "$SRC" add refuse; g "$SRC" commit -qm two
  sha=$(git -C "$SRC" rev-parse --short HEAD)
  (CLAUDE_CODE_SESSION_ID=ending run "$sha")
  check "a refused export opens a note naming the commit and the reason" \
    "dotclaude export refused — ~/.claude $sha: refused: hits" \
    "$(grep '^dotclaude' "$tmp/notes")"
  check "and journals it as no session, not the one that ended" "sid=unset" \
    "$(tail -1 "$tmp/notes")"
  check "and is handled, so the next session end opens no second note" \
    "skip: $sha already handled" "$(decide)"

  g "$SRC" rm -q refuse; g "$SRC" commit -qm three
  sha=$(git -C "$SRC" rev-parse --short HEAD)
  rm -rf "$tmp/origin.git"
  (run "$sha")
  check "a failed push opens a note" "dotclaude push failed — ~/.claude $sha" \
    "$(grep '^dotclaude push' "$tmp/notes")"

  g "$SRC" commit -q --allow-empty -m four
  sha=$(git -C "$SRC" rev-parse --short HEAD)
  out=$(printf '{"reason":"clear"}' | bash "$0" --dry-run)
  check "the dry run names the commit it would export" "would export $sha" "$out"
  out=$(printf 'not json' | bash "$0" --dry-run; echo "rc=$?")
  check "a payload that is not JSON still decides" "would export $sha" "$out"
  git init -q --bare "$tmp/origin.git"
  printf '{"reason":"clear"}' | bash "$0"
  for _ in $(seq 50); do grep -q "$sha run finished" "$LOG" && break; sleep 0.1; done
  check "the hook detaches a run that reaches the log" "1" \
    "$(grep -c "$sha run finished" "$LOG")"
}

case "${1:-}" in
  --self-test) self_test; tap_end ;;
  --run)       mkdir -p "$STATE" "$(dirname "$LOG")"; run "$2"; exit 0 ;;
  --dry-run)   mkdir -p "$STATE" "$(dirname "$LOG")"; hook 1; exit 0 ;;
  "")          mkdir -p "$STATE" "$(dirname "$LOG")"; hook 0; exit 0 ;;
  *)           sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
