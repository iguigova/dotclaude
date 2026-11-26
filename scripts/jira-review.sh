#!/usr/bin/env bash
# jira-review.sh — move a ticket through code review from the reviewer's side,
# so its status and first reviewer follow the review without a hand edit.
#
#   start      Sets the first-reviewer field to the token's account when it is
#              empty, and keeps whoever it names otherwise. Moves the ticket
#              from the in-progress status to the code-review status.
#   approved   Moves the ticket from the code-review status to the testing
#              status, then comments "Code review approved: <--review>".
#   commented  Moves the ticket from the code-review status to the in-progress
#              status, then comments "Code review: changes needed before
#              merge. <--review>".
#
# A move starts only from the status named above. A ticket already in the
# target status stays; one anywhere else is kept where it is, and nothing is
# posted, so a review never moves a ticket backwards on its own. The status
# comparison ignores case.
#
# The field and the statuses are project values (project_file.sh --value):
# jira_first_reviewer_field, a user-picker field id, read by start alone;
# jira_status_in_progress, jira_status_code_review and jira_status_testing.
# A moment whose value the project lacks stops, exit 1, naming it, before
# anything is read, a dry run included.
#
# atlassian-auth.sh, jira-transition.sh and jira-comment.sh are resolved by
# name (project_file.sh --script).
#
# Usage:
#   jira-review.sh [--dry-run] <KEY> start
#   jira-review.sh [--dry-run] <KEY> approved  --review <url>
#   jira-review.sh [--dry-run] <KEY> commented --review <url>
#   jira-review.sh --self-test
#
# --dry-run reads the ticket, prints what it would change, and changes nothing.
#
# Prints a line per outcome:
#   <KEY>: first reviewer set to <name>
#   <KEY>: first reviewer is <name>, kept
#   <KEY>: <from> -> <to>                          (jira-transition.sh's line)
#   <KEY>: already in <to>
#   <KEY>: kept in <status>, only <from> moves to <to>
#   <KEY>: <moment> comment <id>
#
# Exit 0 done, a kept status included; 1 a write failed or a value is
# missing; 2 usage; 75 the ticket or the token's account could not be read.

set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PF="$HOME/.claude/scripts/project_file.sh"
KEY_RE='^[A-Z][A-Z0-9]+-[0-9]+$'
# shellcheck source=flag_value.sh
. "$(dirname "${BASH_SOURCE[0]}")/flag_value.sh" || exit 1

usage() { echo "jira-review: $1" >&2; exit 2; }

# ---- What each moment does: pure, by project value name ----

from_value() {  # <moment>
  case "$1" in
    start)              echo jira_status_in_progress ;;
    approved|commented) echo jira_status_code_review ;;
  esac
}

to_value() {  # <moment>
  case "$1" in
    start)     echo jira_status_code_review ;;
    approved)  echo jira_status_testing ;;
    commented) echo jira_status_in_progress ;;
  esac
}

comment_text() {  # <moment> <review url>
  case "$1" in
    approved)  printf 'Code review approved: %s\n' "$2" ;;
    commented) printf 'Code review: changes needed before merge. %s\n' "$2" ;;
  esac
}

# plan_move — move, already or kept, for a ticket in <status>.
plan_move() {  # <status> <from> <to>
  if [[ "${1,,}" == "${3,,}" ]]; then echo already
  elif [[ "${1,,}" == "${2,,}" ]]; then echo move
  else echo kept; fi
}

# ---- Jira reads and writes ----

read_issue() {  # <key> [<field id>]
  atlassian_curl -f "${ATLASSIAN_SITE}/rest/api/2/issue/$1?fields=status${2:+,$2}"
}

holder_of() { jq -r --arg f "$FIELD" '.fields[$f].displayName // empty' <<<"$ISSUE"; }

# set_reviewer — PUT the token's account into the field.
set_reviewer() {
  local me id name body resp
  me=$(atlassian_curl -f "${ATLASSIAN_SITE}/rest/api/2/myself") \
    || { echo "jira-review: cannot read the token's own account" >&2; return 75; }
  id=$(jq -r .accountId <<<"$me") name=$(jq -r .displayName <<<"$me")
  if [[ "$DRYRUN" -eq 1 ]]; then echo "would set $KEY first reviewer to $name"; return 0; fi
  body=$(jq -nc --arg f "$FIELD" --arg a "$id" '{fields: {($f): {accountId: $a}}}')
  resp=$(atlassian_curl -w $'\n%{http_code}' -X PUT \
    -H 'Content-Type: application/json' --data "$body" "${ATLASSIAN_SITE}/rest/api/2/issue/$KEY")
  if [[ "${resp##*$'\n'}" != 204 ]]; then
    echo "jira-review: setting the first reviewer on $KEY got HTTP ${resp##*$'\n'}: ${resp%$'\n'*}" >&2
    return 1
  fi
  echo "$KEY: first reviewer set to $name"
}

first_reviewer() {
  local holder
  holder=$(holder_of)
  if [[ -n "$holder" ]]; then echo "$KEY: first reviewer is $holder, kept"; return 0; fi
  set_reviewer
}

move_and_comment() {
  local text id
  text=$(comment_text "$MOMENT" "$REVIEW")
  if [[ "$DRYRUN" -eq 1 ]]; then
    echo "would move $KEY from $FROM to $TO"
    [[ -z "$text" ]] || printf 'would comment on %s:\n%s\n' "$KEY" "$text"
    return 0
  fi
  "$("$PF" --script jira-transition.sh)" "$KEY" "$TO" || return 1
  [[ -n "$text" ]] || return 0
  id=$(printf '%s\n' "$text" | "$("$PF" --script jira-comment.sh)" "$KEY" | jq -r .id) || return 1
  echo "$KEY: $MOMENT comment $id"
}

step_status() {
  local status
  status=$(jq -r .fields.status.name <<<"$ISSUE")
  case "$(plan_move "$status" "$FROM" "$TO")" in
    already) echo "$KEY: already in $TO" ;;
    kept)    echo "$KEY: kept in $status, only $FROM moves to $TO" ;;
    move)    move_and_comment ;;
  esac
}

# ---- Self-test ----

# The whole script runs in a project whose Jira is a stub and whose
# jira-transition.sh and jira-comment.sh are fakes that log their calls.
if [[ "${1:-}" == "--self-test" ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  tap_is "a ticket in the from status moves" "$(plan_move "In Progress" "In Progress" "Code Review")" move
  tap_is "a ticket in the target status is already there" "$(plan_move "Code Review" "In Progress" "Code Review")" already
  tap_is "a ticket anywhere else is kept" "$(plan_move "Testing" "In Progress" "Code Review")" kept
  tap_is "start has no comment" "$(comment_text start u)" ""

  fx=$(mktemp -d); me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")"
  log="$fx/calls"; : > "$log"
  s="$fx/p/.claude/scripts"
  mkdir -p "$s"; tap_project "$fx/p"
  cat > "$s/atlassian-auth.sh" <<'STUB'
  # Stub transport: fixture issues, a fixture account, and a PUT that is logged.
  ATLASSIAN_SITE=https://example.invalid
  atlassian_curl() {
    local url="${!#}" data="" prev="" a
    for a in "$@"; do [[ "$prev" == "--data" ]] && data="$a"; prev="$a"; done
    issue() { printf '{"fields":{"status":{"name":"%s"},"customfield_1":%s}}' "$1" "$2"; }
    case "$url" in
      */myself) [[ -z "${JR_NO_ME:-}" ]] && printf '%s' '{"accountId":"acc-me","displayName":"Me Myself"}' ;;
      */issue/ABC-1\?fields=*) issue "In Progress" null ;;
      */issue/ABC-2\?fields=*) issue "Code Review" '{"accountId":"acc-x","displayName":"Someone Else"}' ;;
      */issue/ABC-3\?fields=*) issue "Testing" null ;;
      */issue/ABC-4\?fields=*) issue "CODE REVIEW" null ;;
      */issue/ABC-5\?fields=status) issue "Testing" null ;;
      */issue/ABC-6\?fields=*) issue "Code Review" null ;;
      */issue/ABC-*\?fields=*) return 22 ;;
      */issue/ABC-*) echo "PUT $data" >> "$JR_LOG"; printf '%s' "${JR_STATUS:-204}" ;;
    esac
  }
STUB
  printf '#!/usr/bin/env bash\necho "jira-transition.sh $*" >> %q\n[[ "$*" != *ABC-4* ]] || exit 1\necho "$1: x -> ${*:2}"\n' \
    "$log" > "$s/jira-transition.sh"
  # shellcheck disable=SC2016  # the fake expands its own $* and $(cat)
  printf '#!/usr/bin/env bash\necho "jira-comment.sh $* $(cat)" >> %q\n[[ "$*" != *ABC-6* ]] || exit 1\necho %q\n' \
    "$log" '{"id":"77"}' > "$s/jira-comment.sh"
  chmod +x "$s/jira-transition.sh" "$s/jira-comment.sh"
  tap_project "$fx/bare"; cp -r "$s" "$fx/bare/.claude/"
  echo "In Progress" > "$fx/p/.claude/jira_status_in_progress"
  echo "Code Review" > "$fx/p/.claude/jira_status_code_review"
  echo "Testing" > "$fx/p/.claude/jira_status_testing"
  echo customfield_1 > "$fx/p/.claude/jira_first_reviewer_field"
  # run <project> <args…> — the script's output, then its exit status
  run() { (cd "$fx/$1" && JR_LOG="$log" "$me" "${@:2}") 2>&1; echo "exit $?"; }
  calls() { cat "$log"; : > "$log"; }

  tap_is "start sets an empty first reviewer, then moves In Progress to Code Review" \
    "$(run p ABC-1 start; calls)" "$(printf '%s\n' \
      'ABC-1: first reviewer set to Me Myself' 'ABC-1: x -> Code Review' 'exit 0' \
      'PUT {"fields":{"customfield_1":{"accountId":"acc-me"}}}' 'jira-transition.sh ABC-1 Code Review')"
  tap_is "start keeps a first reviewer someone holds, and a ticket in Code Review" \
    "$(run p ABC-2 start; calls)" "$(printf '%s\n' \
      'ABC-2: first reviewer is Someone Else, kept' 'ABC-2: already in Code Review' 'exit 0')"
  tap_is "start never moves a ticket out of Testing, and still fills an empty first reviewer" \
    "$(run p ABC-3 start | tail -2; calls)" "$(printf '%s\n' \
      'ABC-3: kept in Testing, only In Progress moves to Code Review' 'exit 0' \
      'PUT {"fields":{"customfield_1":{"accountId":"acc-me"}}}')"
  tap_is "approved moves Code Review to Testing, then comments" \
    "$(run p ABC-2 approved --review u; calls)" "$(printf '%s\n' \
      'ABC-2: x -> Testing' 'ABC-2: approved comment 77' 'exit 0' \
      'jira-transition.sh ABC-2 Testing' 'jira-comment.sh ABC-2 Code review approved: u')"
  tap_is "commented moves Code Review to In Progress, then comments" \
    "$(run p ABC-2 commented --review u; calls)" "$(printf '%s\n' \
      'ABC-2: x -> In Progress' 'ABC-2: commented comment 77' 'exit 0' \
      'jira-transition.sh ABC-2 In Progress' 'jira-comment.sh ABC-2 Code review: changes needed before merge. u')"
  tap_is "approved keeps a ticket outside Code Review and posts nothing" \
    "$(run p ABC-1 approved --review u; calls)" \
    "$(printf '%s\n' 'ABC-1: kept in In Progress, only Code Review moves to Testing' 'exit 0')"
  tap_is "approved leaves a ticket already in Testing" "$(run p ABC-3 approved --review u; calls)" \
    "$(printf '%s\n' 'ABC-3: already in Testing' 'exit 0')"
  tap_is "the verdict moments read no first-reviewer field" "$(run p ABC-5 approved --review u)" \
    "$(printf '%s\n' 'ABC-5: already in Testing' 'exit 0')"
  tap_is "a status in another case still moves, and a refused move posts nothing, exit 1" \
    "$(run p ABC-4 approved --review u | tail -1; calls)" \
    "$(printf '%s\n' 'exit 1' 'jira-transition.sh ABC-4 Testing')"
  tap_is "a refused comment after the move is exit 1" "$(run p ABC-6 commented --review u | tail -1; calls)" \
    "$(printf '%s\n' 'exit 1' 'jira-transition.sh ABC-6 In Progress' \
      'jira-comment.sh ABC-6 Code review: changes needed before merge. u')"
  tap_is "a dry run of start says what it would do and writes nothing" \
    "$(run p --dry-run ABC-1 start; calls)" "$(printf '%s\n' \
      'would set ABC-1 first reviewer to Me Myself' 'would move ABC-1 from In Progress to Code Review' 'exit 0')"
  tap_is "a dry run of approved shows the comment" "$(run p --dry-run ABC-2 approved --review u; calls)" \
    "$(printf '%s\n' 'would move ABC-2 from Code Review to Testing' 'would comment on ABC-2:' \
      'Code review approved: u' 'exit 0')"
  tap_is "a refused first-reviewer write moves nothing, exit 1" \
    "$(JR_STATUS=400 run p ABC-1 start | tail -1; calls)" "$(printf '%s\n' \
      'exit 1' 'PUT {"fields":{"customfield_1":{"accountId":"acc-me"}}}')"
  tap_is "an unreadable account is no answer, exit 75" \
    "$(JR_NO_ME=1 run p ABC-1 start | tail -1; calls)" "exit 75"
  tap_is "an unreadable ticket is no answer, exit 75" "$(run p ABC-9 start | tail -1)" "exit 75"
  tap_like "a project naming no code-review status stops before any read" \
    "$(run bare ABC-2 approved --review u; calls)" "*jira_status_code_review*exit 1"
  echo "Code Review" > "$fx/bare/.claude/jira_status_code_review"
  tap_like "approved needs the testing status" "$(run bare --dry-run ABC-2 approved --review u)" \
    "*jira_status_testing*exit 1"
  echo "In Progress" > "$fx/bare/.claude/jira_status_in_progress"
  tap_like "start needs the first-reviewer field" "$(run bare --dry-run ABC-1 start)" \
    "*jira_first_reviewer_field*exit 1"
  tap_is "a verdict needs the review link" "$(run p ABC-2 approved)" \
    "$(printf '%s\n' 'jira-review: approved needs --review' 'exit 2')"
  tap_is "an unknown moment is a usage error" "$(run p ABC-2 finished | tail -1)" "exit 2"
  tap_is "a key that is no key is a usage error" "$(run p abc-2 start | tail -1)" "exit 2"
  tap_is "a third word is a usage error" "$(run p ABC-2 start extra | tail -1)" "exit 2"
  tap_is "an unknown option is a usage error" "$(run p ABC-2 start --bogus | tail -1)" "exit 2"
  tap_is "a last --review with no link is a usage error, not a hang" \
    "$(run p ABC-2 approved --review)" "$(printf '%s\n' 'jira-review.sh: --review needs a value' 'exit 2')"
  rm -rf "$fx"
  tap_end
fi

# ---- Arguments, then the body ----

DRYRUN=0 KEY="" MOMENT="" REVIEW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRYRUN=1; shift ;;
    --review)  flag_value "$@"; REVIEW="$2"; shift 2 ;;
    -*)        usage "unknown option '$1'" ;;
    *)  if [[ -z "$KEY" ]]; then KEY="$1"; elif [[ -z "$MOMENT" ]]; then MOMENT="$1"
        else usage "unexpected argument '$1'"; fi; shift ;;
  esac
done
[[ "$KEY" =~ $KEY_RE ]] || usage "not an issue key: '${KEY}'"
case "$MOMENT" in
  start) ;;
  approved|commented) [[ -n "$REVIEW" ]] || usage "$MOMENT needs --review" ;;
  *) usage "unknown moment '$MOMENT' (start, approved, commented)" ;;
esac

FROM=$("$PF" --value "$(from_value "$MOMENT")") || exit 1
TO=$("$PF" --value "$(to_value "$MOMENT")") || exit 1
FIELD=""
if [[ "$MOMENT" == start ]]; then FIELD=$("$PF" --value jira_first_reviewer_field) || exit 1; fi

# shellcheck source=atlassian-auth.sh
source "$("$PF" --script atlassian-auth.sh)" || exit 1
ISSUE=$(read_issue "$KEY" "$FIELD") || { echo "jira-review: cannot read $KEY" >&2; exit 75; }
if [[ -n "$FIELD" ]]; then first_reviewer || exit $?; fi
step_status || exit 1
