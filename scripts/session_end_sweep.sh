#!/usr/bin/env bash
# SessionEnd hook: sweep the project's git clones and the machine's strays, at most once a day, and report what the ending session leaves running.
#
# The harness runs this with the hook payload on stdin — session_id, cwd and
# reason — when a session ends. Every time, it starts a detached
# `stray_sweep.py --after <pid> --write ~/.claude/stray_sweep.last`, the pid
# being the Claude Code process it runs under: once that process has exited,
# whatever the session left running is re-parented, and the next session start
# shows it. It then decides whether a daily sweep is due and, if so,
# starts a detached `git_sweep.sh <project> --apply`, which deletes what is
# proven finished and opens a note for the rest, and then
# `stray_sweep.py --apply --write ~/.claude/stray_sweep.last`, which removes
# the stale temp folders and reports what else this user left running or
# lying around, the report removed once nothing is.
#
# Usage:
#   session_end_sweep.sh            # reads the hook payload on stdin
#   session_end_sweep.sh --dry-run  # same decision, prints the command, runs nothing
#   session_end_sweep.sh --run PROJECT   # the detached half; not for direct use
#   session_end_sweep.sh --self-test
#
# The project is the one the session's cwd lies in (project_file.sh --root),
# whose history git_sweep.sh journals into. A
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
# The run is detached with detach.sh, because a SessionEnd hook is killed at
# 1500 ms and a sweep makes one PR lookup per branch. It holds a
# non-blocking lock for its whole life, so a second run exits rather than
# queueing, and it checks the stamp again under the lock, so two session
# ends racing past the first check sweep once.
#
# Every firing leaves one line in $LOG, skips included; the sweep's own
# output follows its start line. Read it with
# `tail ~/.claude/logs/session_end.log`.
#
# A run also adds its record to <project>/.claude/git_sweep.last, which the
# next session start shows and moves aside: its start line, the sweep's TSV
# lines and its exit status. A record with no `run finished` line is a run
# that was killed.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${SESSION_END_LOG:-$HOME/.claude/logs/session_end.log}"
STATE="${SESSION_END_SWEEP_STATE:-$HOME/.claude/state}"
SWEEP="${SESSION_END_SWEEP_CMD:-$SCRIPTS_DIR/git_sweep.sh}"
STRAYS="${SESSION_END_STRAYS_CMD:-$SCRIPTS_DIR/stray_sweep.py}"
STRAY_REPORT="${SESSION_END_STRAY_REPORT:-$HOME/.claude/stray_sweep.last}"
CLAUDE_COMM="${SESSION_END_CLAUDE_COMM:-claude}"
SWEEP_HOURS=24
# shellcheck source=journal_lib.sh
. "$SCRIPTS_DIR/journal_lib.sh"

say() { printf '%s sweep %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }

project_of() {  # <cwd> -> the project whose history the session wrote
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
    || { echo "skip: no project history at or above $1"; return; }
  due "$project" || { echo "skip: $project swept within ${SWEEP_HOURS}h"; return; }
  echo "run $project"
}

start_run() {  # <project>
  "$SCRIPTS_DIR/detach.sh" bash "$SCRIPTS_DIR/$(basename "$0")" --run "$1"
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
  "$STRAYS" --apply --write "$STRAY_REPORT" >>"$LOG" 2>&1
  say "strays rc=$? (0 none, 1 reported in $STRAY_REPORT)"
}

report_of() {  # <project> -> the record the next session reads
  printf '%s/.claude/git_sweep.last' "$1"
}

report() {  # <project> <what> — starts this run's record, after any unread one
  local f; f=$(report_of "$1")
  { [[ -s "$f" ]] && echo; printf 'git_sweep %s: %s %s\n' "$(date -u '+%Y-%m-%d %H:%M')" "$1" "$2"; } >>"$f"
}

claude_pid() {  # -> the nearest ancestor that is Claude Code
  local p=$PPID comm
  while [[ "$p" -gt 1 ]]; do  # mutation: equivalent — pid 1 is init, never Claude Code
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || break
    [[ "$comm" == "$CLAUDE_COMM" ]] && { echo "$p"; return 0; }
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  return 1
}

watch_session() {  # <dry> — sweep the strays once the session's process has exited
  local pid
  pid=$(claude_pid) || { say "strays: no $CLAUDE_COMM process above the hook"; return; }
  if (( $1 )); then say "strays: dry-run, would watch $pid"; return; fi
  "$SCRIPTS_DIR/detach.sh" "$STRAYS" --after "$pid" --write "$STRAY_REPORT"
  say "strays: watching $pid"
}

hook() {  # <dry> — reads the payload on stdin
  local payload cwd reason verdict
  payload=$(cat)
  cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
  reason=$(jq -r '.reason // "other"' <<<"$payload" 2>/dev/null)
  if [[ -n "${CLAUDE_TOOLING_UNATTENDED:-}" ]]; then say "reason=${reason:-other} skip: an unattended run's own end"; return; fi
  watch_session "$1"
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
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local tmp out p watched
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  unset CLAUDE_TOOLING_UNATTENDED
  export SESSION_END_LOG="$tmp/log" SESSION_END_SWEEP_STATE="$tmp/state"
  export SESSION_END_SWEEP_CMD="$tmp/sweep" SESSION_END_STRAYS_CMD="$tmp/strays"
  export SESSION_END_STRAY_REPORT="$tmp/strays.last" SESSION_END_CLAUDE_COMM=bash
  LOG="$tmp/log" STATE="$tmp/state" SWEEP="$tmp/sweep" STRAYS="$tmp/strays" STRAY_REPORT="$tmp/strays.last"
  mkdir -p "$STATE"; : >"$LOG"
  # shellcheck disable=SC2016  # the fake sweep expands its own arguments
  printf '#!/usr/bin/env bash\necho "SWEPT $1 $2 sid=${CLAUDE_CODE_SESSION_ID-unset}"; exit 1\n' >"$SWEEP"
  # shellcheck disable=SC2016  # the fake expands its own arguments
  printf '#!/usr/bin/env bash\necho "STRAYS $*"; echo "$*" >> %s/strays.args; echo stray > "${@: -1}"; exit 1\n' "$tmp" >"$STRAYS"
  chmod +x "$SWEEP" "$STRAYS"
  check() {  # <description> <want prefix> <got>
    if [[ "$3" == "$2"* ]]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }

  p="$tmp/project"; mkdir -p "$p/.claude" "$p/api/repo"; tap_project "$p"
  : >"$p/.claude/session_history.md"
  check "a cwd that is gone is a skip" "skip: cwd" "$(decide "$tmp/absent")"
  check "no history above the cwd is a skip" "skip: no project history" "$(decide "$tmp")"
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
  check "then sweeps the machine's strays, removing the stale temp and writing the report" \
    "STRAYS --apply --write $STRAY_REPORT" "$(grep '^STRAYS' "$LOG")"
  check "which the next session reads" "stray" "$(cat "$STRAY_REPORT")"
  check "and logs that sweep's exit status" "1" "$(grep -c 'strays rc=1 ' "$LOG")"
  report "$p" again
  check "a later run's record is added after the unread one" "2" \
    "$(grep -c '^git_sweep ' "$p/.claude/git_sweep.last")"
  check "and stamps the project, failure included" "skip: $p swept" \
    "$(decide "$p")"
  (run "$p")
  check "a second run under a fresh stamp sweeps nothing" "1" \
    "$(grep -c '^SWEPT' "$LOG")"

  rm "$(stamp_of "$p")"
  out=$(printf '{"cwd":"%s","reason":"clear"}' "$p" | bash "$0" --dry-run)
  check "the hook reads cwd from the payload" "would run: $SWEEP $p --apply" "$out"
  check "and would watch the Claude Code process it runs under" "1" "$(grep -cE 'strays: dry-run, would watch [0-9]+$' "$LOG")"
  out=$(printf '{"cwd":"%s"}' "$p" | SESSION_END_CLAUDE_COMM=none bash "$0" --dry-run)
  check "with none above it, the hook says so and still sweeps" "would run: $SWEEP $p --apply" "$out"
  check "in the log" "1" "$(grep -c 'strays: no none process above the hook' "$LOG")"
  watched=$(grep -c 'would watch' "$LOG")
  out=$(printf '{"cwd":"%s","reason":"clear"}' "$p" | CLAUDE_TOOLING_UNATTENDED=1 bash "$0" --dry-run)
  check "an unattended run's own end sweeps nothing" "" "$out"
  check "and watches no session" "$watched" "$(grep -c 'would watch' "$LOG")"
  check "and says so in the log" "skip: an unattended run's own end" "$(tail -1 "$LOG" | sed 's/.*reason=clear //')"
  out=$(printf 'not json' | bash "$0"; echo "rc=$?")
  check "a payload that is not JSON exits 0" "rc=0" "$out"
  rm -f "$(stamp_of "$p")"
  printf '{"cwd":"%s","reason":"clear"}' "$p" | bash "$0"
  for _ in $(seq 50); do grep -q 'run finished' "$LOG" && \
    [[ "$(grep -c 'run finished' "$LOG")" -ge 2 ]] && break; sleep 0.1; done
  check "the hook detaches a run that reaches the log" "2" \
    "$(grep -c '^SWEPT' "$LOG")"
  for _ in $(seq 50); do grep -q -- '--after' "$tmp/strays.args" 2>/dev/null && break; sleep 0.1; done
  check "and a stray sweep after the session's process, into the report" "1" \
    "$(grep -cx -- "--after $$ --write $STRAY_REPORT" "$tmp/strays.args")"
}

case "${1:-}" in
  --self-test) self_test; tap_end ;;
  --run)       mkdir -p "$STATE" "$(dirname "$LOG")"; run "$2"; exit 0 ;;
  --dry-run)   mkdir -p "$STATE" "$(dirname "$LOG")"; hook 1; exit 0 ;;
  "")          mkdir -p "$STATE" "$(dirname "$LOG")"; hook 0; exit 0 ;;
  *)           sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
