#!/usr/bin/env bash
# Post one of the progress comments ticket hygiene requires, so no ticket goes
# from created to closed without its story: a comment when work starts, when it
# is blocked and unblocked, when it goes to review, and when it needs another
# team's input.
#
# Each moment has one shape, so every ticket's history reads the same way:
#
#   started    Work started. <--note>
#              Moves the ticket to In Progress and, when it has no
#              assignee, assigns it to the token's account first.
#   blocked    Blocked: <--by>. Owner: <--owner>. Expected: <--until>.
#              Moves the ticket to Blocked first.
#   unblocked  Unblocked: <--note>. Moves the ticket to In Progress first.
#   review     In review: <--pr>, one per PR. <--note>
#   input      Input needed from <--from>: <--question>
#
# The status moves before the comment posts, so a comment never claims a status
# the ticket does not have; a refused move posts nothing. The statuses are the
# workflow's In Progress and Blocked; a project whose workflow names them
# otherwise overrides this script.
#
# jira-assign.sh, jira-transition.sh and jira-comment.sh are resolved by name
# (project_file.sh --script).
#
# Usage:
#   jira-progress.sh [--dry-run] <KEY> started   [--note <text>]
#   jira-progress.sh [--dry-run] <KEY> blocked   --by <what> --owner <who> --until <YYYY-MM-DD>
#   jira-progress.sh [--dry-run] <KEY> unblocked --note <what cleared it>
#   jira-progress.sh [--dry-run] <KEY> review    --pr <url> [--pr <url>…] [--note <text>]
#   jira-progress.sh [--dry-run] <KEY> input     --from <who> --question <text>
#   jira-progress.sh --self-test
#
# Text is Jira wiki markup; mention a person as [~accountid:<id>].
# --dry-run prints the status move and the comment, and changes nothing.
#
# Prints "<KEY>: <moment> comment <id>". Exit 0 posted; 2 usage; 1 the status
# move or the post failed, with the helper's own message on stderr.

set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PF="$HOME/.claude/scripts/project_file.sh"

usage() { echo "jira-progress: $1" >&2; exit 2; }

# Each moment's comment, from NOTE BY OWNER UNTIL FROM QUESTION and PRS
# (newline-separated); each exits 2 naming the first option it needs.
started_body() { printf 'Work started.%s\n' "${NOTE:+ $NOTE}"; }

blocked_body() {
  [[ -n "$BY" ]] || usage "blocked needs --by"
  [[ -n "$OWNER" ]] || usage "blocked needs --owner"
  [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage "blocked needs --until YYYY-MM-DD"
  printf 'Blocked: %s. Owner: %s. Expected: %s.\n' "$BY" "$OWNER" "$UNTIL"
}

unblocked_body() {
  [[ -n "$NOTE" ]] || usage "unblocked needs --note"
  printf 'Unblocked: %s\n' "$NOTE"
}

review_body() {
  [[ -n "$PRS" ]] || usage "review needs --pr"
  printf 'In review:\n'
  printf '%s\n' "$PRS" | sed 's/^/* /'
  [[ -z "$NOTE" ]] || printf '\n%s\n' "$NOTE"
}

input_body() {
  [[ -n "$FROM" ]] || usage "input needs --from"
  [[ -n "$QUESTION" ]] || usage "input needs --question"
  printf 'Input needed from %s: %s\n' "$FROM" "$QUESTION"
}

body() {  # <moment>
  case "$1" in
    started|blocked|unblocked|review|input) "$1_body" ;;
    *) usage "unknown moment '$1' (started, blocked, unblocked, review, input)" ;;
  esac
}

status_for() {  # <moment> -> the status it moves the ticket to, or nothing
  case "$1" in
    started)   echo "In Progress" ;;
    blocked)   echo Blocked ;;
    unblocked) echo "In Progress" ;;
  esac
}

assigns() { [[ "$1" == started ]]; }  # <moment> -> whether it takes the ticket

# self_test_runs — the whole script in a project whose jira-assign.sh,
# jira-transition.sh and jira-comment.sh are fakes that log their arguments.
self_test_runs() {
  local fx me log f
  fx=$(mktemp -d); me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")"
  log="$fx/calls"
  mkdir -p "$fx/p/.claude/scripts"
  for f in jira-assign.sh jira-transition.sh; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> %q\n[[ "$*" != *refuse* ]]\n' "$f" "$log" > "$fx/p/.claude/scripts/$f"
  done
  # shellcheck disable=SC2016  # the fake expands its own $* and $(cat)
  printf '#!/usr/bin/env bash\necho "jira-comment.sh $* $(cat)" >> %q\necho %q\n' "$log" '{"id":"77"}' \
    > "$fx/p/.claude/scripts/jira-comment.sh"
  chmod +x "$fx/p/.claude/scripts/"*
  run() { (cd "$fx/$1" && "$me" "${@:2}") 2>&1; }  # <project> <args…>
  tap_is "started assigns, moves, then comments" "$(run p XYZ-1 started; cat "$log")" \
    "$(printf '%s\n' 'XYZ-1: started comment 77' 'jira-assign.sh --if-unassigned XYZ-1 me' \
      'jira-transition.sh XYZ-1 In Progress' 'jira-comment.sh XYZ-1 Work started.')"
  : > "$log"
  tap_is "review neither assigns nor moves" "$(run p XYZ-1 review --pr u1; cat "$log")" \
    "$(printf '%s\n' 'XYZ-1: review comment 77' 'jira-comment.sh XYZ-1 In review:' '* u1')"
  : > "$log"
  tap_is "a refused move posts nothing, exit 1" "$(run p refuse unblocked --note n; echo "exit $?"; cat "$log")" \
    "$(printf '%s\n' 'exit 1' 'jira-transition.sh refuse In Progress')"
  : > "$log"
  tap_is "a refused assign moves nothing, exit 1" "$(run p refuse started; echo "exit $?"; cat "$log")" \
    "$(printf '%s\n' 'exit 1' 'jira-assign.sh --if-unassigned refuse me')"
  : > "$log"
  tap_is "a dry run says what it would do and calls nothing" \
    "$(run p --dry-run XYZ-1 blocked --by b --owner o --until 2026-01-02; cat "$log")" \
    "$(printf '%s\n' 'would move XYZ-1 to: Blocked' 'would comment on XYZ-1:' 'Blocked: b. Owner: o. Expected: 2026-01-02.')"
  tap_is "a dry run of started says it would assign" "$(run p --dry-run XYZ-1 started | head -1)" \
    "would assign XYZ-1 to the token's account, if unassigned"
  : > "$log"
  tap_is "input only comments" "$(run p XYZ-1 input --from a --question q; cat "$log")" \
    "$(printf '%s\n' 'XYZ-1: input comment 77' 'jira-comment.sh XYZ-1 Input needed from a: q')"
  tap_is "a missing moment is a usage error, naming the usage" "$(run p XYZ-1; echo "exit $?")" \
    "$(printf '%s\n' 'jira-progress: usage: jira-progress.sh [--dry-run] <KEY> <moment> [options]' 'exit 2')"
  tap_is "an unknown option is a usage error" "$(run p XYZ-1 started --bogus >/dev/null; echo $?)" 2
  tap_is "a third word is a usage error" "$(run p XYZ-1 started extra >/dev/null; echo $?)" 2
  rm -rf "$fx"
}

if [[ "${1:-}" == "--self-test" ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  NOTE="" BY="" OWNER="" UNTIL="" FROM="" QUESTION="" PRS=""
  t() {  # <label> <want> <moment>
    local got; got=$(body "$3" 2>&1) || true
    tap_is "$1" "$got" "$2"
  }
  t "started, bare" "Work started." started
  NOTE="Plan on the ticket." t "started, with a note" "Work started. Plan on the ticket." started
  BY="PSI deploy" OWNER="[~accountid:1]" UNTIL=2026-10-23 \
    t "blocked" "Blocked: PSI deploy. Owner: [~accountid:1]. Expected: 2026-10-23." blocked
  BY="x" OWNER="y" UNTIL="Friday" t "blocked refuses a date that is not a date" \
    "jira-progress: blocked needs --until YYYY-MM-DD" blocked
  BY="x" t "blocked refuses a missing owner" "jira-progress: blocked needs --owner" blocked
  t "unblocked needs what cleared it" "jira-progress: unblocked needs --note" unblocked
  PRS=$'https://g/1\nhttps://g/2' t "review lists every PR" $'In review:\n* https://g/1\n* https://g/2' review
  PRS='https://g/1' NOTE="Two repos." t "review ends with its note" $'In review:\n* https://g/1\n\nTwo repos.' review
  t "review refuses no PR" "jira-progress: review needs --pr" review
  FROM="CS" QUESTION="which office?" t "input" "Input needed from CS: which office?" input
  t "an unknown moment is refused" \
    "jira-progress: unknown moment 'finished' (started, blocked, unblocked, review, input)" finished
  moves=""
  for m in started blocked unblocked review input; do moves+="$m=$(status_for "$m");"; done
  tap_is "started and unblocked move to In Progress, blocked to Blocked" "$moves" \
    "started=In Progress;blocked=Blocked;unblocked=In Progress;review=;input=;"
  takers=""
  for m in started blocked unblocked review input; do ! assigns "$m" || takers+="$m"; done
  tap_is "only started assigns" "$takers" started
  self_test_runs
  tap_end
fi

DRYRUN=0 KEY="" MOMENT=""
NOTE="" BY="" OWNER="" UNTIL="" FROM="" QUESTION="" PRS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRYRUN=1; shift ;;
    --note)     NOTE="$2"; shift 2 ;;
    --by)       BY="$2"; shift 2 ;;
    --owner)    OWNER="$2"; shift 2 ;;
    --until)    UNTIL="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    --question) QUESTION="$2"; shift 2 ;;
    --pr)       PRS+="${PRS:+$'\n'}$2"; shift 2 ;;
    -*)         usage "unknown option '$1'" ;;
    *)  if [[ -z "$KEY" ]]; then KEY="$1"; elif [[ -z "$MOMENT" ]]; then MOMENT="$1"
        else usage "unexpected argument '$1'"; fi; shift ;;
  esac
done
[[ -n "$KEY" && -n "$MOMENT" ]] || usage "usage: jira-progress.sh [--dry-run] <KEY> <moment> [options]"

TEXT=$(body "$MOMENT") || exit 2
STATUS=$(status_for "$MOMENT")

if [[ $DRYRUN == 1 ]]; then
  ! assigns "$MOMENT" || echo "would assign $KEY to the token's account, if unassigned"
  [[ -z "$STATUS" ]] || echo "would move $KEY to: $STATUS"
  printf 'would comment on %s:\n%s\n' "$KEY" "$TEXT"
  exit 0
fi

ASSIGN=$("$PF" --script jira-assign.sh) || exit 1
TRANSITION=$("$PF" --script jira-transition.sh) || exit 1
COMMENT=$("$PF" --script jira-comment.sh) || exit 1
if assigns "$MOMENT"; then
  "$ASSIGN" --if-unassigned "$KEY" me >&2 || exit 1
fi
if [[ -n "$STATUS" ]]; then
  "$TRANSITION" "$KEY" "$STATUS" >&2 || exit 1
fi
ID=$(printf '%s\n' "$TEXT" | "$COMMENT" "$KEY" | jq -r .id) || exit 1
echo "$KEY: $MOMENT comment $ID"
