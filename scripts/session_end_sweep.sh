#!/usr/bin/env bash
# SessionEnd hook: sweep the project's git clones, at most once a day.
#
# The harness runs this with the hook payload on stdin — session_id, cwd and
# reason — when a session ends. It decides whether a sweep is due and, if so,
# starts a detached `git_sweep.sh <project> --apply`, which deletes what is
# proven finished and opens a note for the rest.
#
# Usage:
#   session_end_sweep.sh            # reads the hook payload on stdin
#   session_end_sweep.sh --dry-run  # same decision, prints the command, runs nothing
#   session_end_sweep.sh --run PROJECT   # the detached half; not for direct use
#   session_end_sweep.sh --self-test
#
# The project is the directory holding the nearest .claude/session_history.md
# at or above the session's cwd, the history git_sweep.sh journals into. A
# sweep is due when that project's stamp is missing or older than
# SWEEP_HOURS. The stamp is written when a run starts, so a run that fails
# waits a day like one that succeeds: the failure is in the log, and a
# sweep that fails on every session end would only repeat it.
#
# The run journals with CLAUDE_CODE_SESSION_ID unset. The hook inherits the
# ending session's id, and a sweep entry carrying it would make every note
# the sweep opens or closes that session's, so the session's end report
# would list them as its own.
#
# The run is detached with setsid, because a SessionEnd hook is killed at
# 1500 ms and a sweep makes one PR lookup per branch. It holds a
# non-blocking lock for its whole life, so a second run exits rather than
# queueing, and it checks the stamp again under the lock, so two session
# ends racing past the first check sweep once.
#
# Every firing leaves one line in $LOG, skips included; the sweep's own
# output follows its start line. Read it with
# `tail ~/.claude/logs/session_end.log`.
#
# A run also rewrites <project>/.claude/git_sweep.last, read at the start of
# the next session: its start line, the sweep's TSV lines and its exit
# status. A record with no `run finished` line is a run that was killed.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${SESSION_END_LOG:-$HOME/.claude/logs/session_end.log}"
STATE="${SESSION_END_SWEEP_STATE:-$HOME/.claude/state}"
SWEEP="${SESSION_END_SWEEP_CMD:-$SCRIPTS_DIR/git_sweep.sh}"
SWEEP_HOURS=24
# shellcheck source=journal_lib.sh
. "$SCRIPTS_DIR/journal_lib.sh"

say() { printf '%s sweep %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }

project_of() {  # <cwd> -> the directory holding the nearest session history
  local hist
  hist=$(cd "$1" && journal_hist session_end_sweep.sh 2>/dev/null) || return 1
  dirname "$(dirname "$hist")"
}

stamp_of() {  # <project> -> its stamp file
  printf '%s/git_sweep%s.last' "$STATE" "${1//\//_}"
}

due() {  # <project> -> succeeds when the stamp is missing or stale
  local f
  f=$(stamp_of "$1")
  [[ ! -f "$f" ]] || (( $(date +%s) - $(stat -c %Y "$f") >= SWEEP_HOURS * 3600 ))
}

decide() {  # <cwd> -> "run <project>" or "skip: <why>"
  local project
  [[ -d "$1" ]] || { echo "skip: cwd $1 does not exist"; return; }
  project=$(project_of "$1") \
    || { echo "skip: no .claude/session_history.md at or above $1"; return; }
  due "$project" || { echo "skip: $project swept within ${SWEEP_HOURS}h"; return; }
  echo "run $project"
}

start_run() {  # <project>
  setsid nohup bash "$SCRIPTS_DIR/$(basename "$0")" --run "$1" \
    </dev/null >/dev/null 2>&1 &
  disown || true
}

run() {  # <project> — the detached half
  local rc
  exec 9>"$STATE/git_sweep.lock" || { say "$1 the lock could not be opened"; return 0; }
  flock -n 9 || { say "$1 another sweep holds the lock, skipped"; return 0; }
  due "$1" || { say "$1 swept by a racing run, skipped"; return 0; }
  touch "$(stamp_of "$1")"
  say "$1 run started"
  report "$1" "run started"
  env -u CLAUDE_CODE_SESSION_ID "$SWEEP" "$1" --apply 2>&1 \
    | tee -a "$LOG" >>"$(report_of "$1")"
  rc=${PIPESTATUS[0]}
  say "$1 run finished rc=$rc"
  printf 'run finished rc=%s\n' "$rc" >>"$(report_of "$1")"
}

report_of() {  # <project> -> the record the next session reads
  printf '%s/.claude/git_sweep.last' "$1"
}

report() {  # <project> <what> — starts the record afresh
  printf 'git_sweep %s: %s %s\n' "$(date -u '+%Y-%m-%d %H:%M')" "$1" "$2" \
    >"$(report_of "$1")"
}

hook() {  # <dry> — reads the payload on stdin
  local payload cwd reason verdict
  payload=$(cat)
  cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
  reason=$(jq -r '.reason // "other"' <<<"$payload" 2>/dev/null)
  verdict=$(decide "$cwd")
  if [[ "$verdict" != run* ]]; then say "reason=${reason:-other} $verdict"; return; fi
  if (( $1 )); then
    say "reason=$reason dry-run, would run: $SWEEP ${verdict#run } --apply"
    echo "would run: $SWEEP ${verdict#run } --apply"
    return
  fi
  start_run "${verdict#run }"
}

# ---------------------------------------------------------------- self-test

self_test() {
  local tmp rc=0 out p
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  export SESSION_END_LOG="$tmp/log" SESSION_END_SWEEP_STATE="$tmp/state"
  export SESSION_END_SWEEP_CMD="$tmp/sweep"
  LOG="$tmp/log" STATE="$tmp/state" SWEEP="$tmp/sweep"
  mkdir -p "$STATE"; : >"$LOG"
  # shellcheck disable=SC2016  # the fake sweep expands its own arguments
  printf '#!/usr/bin/env bash\necho "SWEPT $1 $2 sid=${CLAUDE_CODE_SESSION_ID-unset}"; exit 1\n' >"$SWEEP"
  chmod +x "$SWEEP"
  check() {  # <description> <want prefix> <got>
    if [[ "$3" == "$2"* ]]; then echo "  ok   $1"
    else printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3"; rc=1; fi
  }
  echo "session_end_sweep.sh --self-test"

  p="$tmp/project"; mkdir -p "$p/.claude" "$p/api/repo"
  : >"$p/.claude/session_history.md"
  check "a cwd that is gone is a skip" "skip: cwd" "$(decide "$tmp/absent")"
  check "no history above the cwd is a skip" "skip: no .claude" "$(decide "$tmp")"
  check "a project never swept is a run, from a nested cwd" "run $p" \
    "$(decide "$p/api/repo")"
  touch "$(stamp_of "$p")"
  check "a project swept today is a skip" "skip: $p swept" "$(decide "$p")"
  touch -d '25 hours ago' "$(stamp_of "$p")"
  check "a project swept yesterday is a run" "run $p" "$(decide "$p")"

  out=$(flock -n "$STATE/git_sweep.lock" -c "bash '$0' --run '$p'; tail -1 '$LOG'")
  # run holds its lock on fd 9 until its process exits, so each run below is
  # a subshell: one run in this shell would hold the lock against the next.
  check "a held lock skips the run" "$(date -u +%Y)" "$out"
  check "and says so" "1" "$(grep -c 'holds the lock' "$LOG")"
  (CLAUDE_CODE_SESSION_ID=ending run "$p")
  check "a run sweeps the project with --apply" "1" \
    "$(grep -c "^SWEPT $p --apply" "$LOG")"
  check "and journals as no session, not the one that ended" "1" \
    "$(grep -c "^SWEPT $p --apply sid=unset" "$LOG")"
  check "and logs the sweep's exit status" "1" "$(grep -c 'finished rc=1' "$LOG")"
  check "and records the run for the next session" "git_sweep $(date -u +%Y)" \
    "$(head -1 "$p/.claude/git_sweep.last")"
  check "with the sweep's output" "1" \
    "$(grep -c "^SWEPT $p --apply" "$p/.claude/git_sweep.last")"
  check "and its exit status last" "run finished rc=1" \
    "$(tail -1 "$p/.claude/git_sweep.last")"
  check "and stamps the project, failure included" "skip: $p swept" \
    "$(decide "$p")"
  (run "$p")
  check "a second run under a fresh stamp sweeps nothing" "1" \
    "$(grep -c '^SWEPT' "$LOG")"

  rm "$(stamp_of "$p")"
  out=$(printf '{"cwd":"%s","reason":"clear"}' "$p" | bash "$0" --dry-run)
  check "the hook reads cwd from the payload" "would run: $SWEEP $p --apply" "$out"
  out=$(printf 'not json' | bash "$0"; echo "rc=$?")
  check "a payload that is not JSON exits 0" "rc=0" "$out"
  rm -f "$(stamp_of "$p")"
  printf '{"cwd":"%s","reason":"clear"}' "$p" | bash "$0"
  for _ in $(seq 50); do grep -q 'run finished' "$LOG" && \
    [[ "$(grep -c 'run finished' "$LOG")" -ge 2 ]] && break; sleep 0.1; done
  check "the hook detaches a run that reaches the log" "2" \
    "$(grep -c '^SWEPT' "$LOG")"
  return "$rc"
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  --run)       mkdir -p "$STATE" "$(dirname "$LOG")"; run "$2"; exit 0 ;;
  --dry-run)   mkdir -p "$STATE" "$(dirname "$LOG")"; hook 1; exit 0 ;;
  "")          mkdir -p "$STATE" "$(dirname "$LOG")"; hook 0; exit 0 ;;
  *)           sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
