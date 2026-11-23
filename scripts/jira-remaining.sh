#!/usr/bin/env bash
# The remaining-estimate argument for jira-worklog.sh, decided rather than
# guessed. jira-worklog.sh posts `adjustEstimate=new&newEstimate=<arg>`, which
# SETS remaining rather than decrementing it, so a number worked out in passing
# silently rewrites a burndown.
#
# Usage:
#   jira-remaining.sh <issue-key> <effort>   # e.g. jira-remaining.sh ABC-123 2h
#   jira-remaining.sh --self-test            # decides over fixtures, no network
#
# stdout is the argument to pass, or EMPTY when it must be omitted. Capture it
# and expand it conditionally, so an omit stays an omit:
#
#   REM=$(jira-remaining.sh ABC-123 2h)
#   jira-worklog.sh --quiet ABC-123 2h ${REM:+"$REM"} < items
#
# stderr is one line naming the decision and why. That line is the confirmation
# text, so what the user approves is what was computed.
#
# Four states omit the argument, each one a case where any number is invented:
#   - the ticket carries no estimate at all (original and remaining both unset);
#   - remaining is already 0h on a ticket that is not Done — the burndown is
#     spent, and a positive number would raise it;
#   - the effort exhausts what is left;
#   - the remaining estimate is unreadable.
# Omitting leaves Jira's default `adjustEstimate=auto`, which subtracts from the
# original and floors at zero. That is the honest result: an exhausted estimate
# reads as exhausted instead of being topped up to keep a burndown looking live.
#
# A Done-category status takes `0h`: the work is finished, whatever is left on
# the clock.
#
# Jira durations are `Nw`, `Nd`, `Nh`, `Nm`, decimal or whole, whitespace-
# separated — `2h 30m`, never `2h30m`, which REST v3 refuses and so does this.
# A day and a week are THIS instance's working day and week, read
# from /rest/api/3/configuration and never assumed — the arithmetic is wrong on
# an instance configured differently, and a missing configuration is an error
# rather than a default. Output is the spaced form (`1d 3h`); REST v3 rejects
# the unspaced compound `2h30m`.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PF="$HOME/.claude/scripts/project_file.sh"

# ---------------------------------------------------------------- decide

# ISSUE_JSON is jira-issue.sh's flat object. Prints "<arg>\t<rendering>", and
# exits 2 when the effort is not a duration — billing against a misread number
# is worse than not billing, so the caller stops before the worklog is posted.
# jira_remaining_decide.py decides; the issue reaches it on stdin, which has no
# size cap, as a long description or comment thread would pass the kernel's for
# an environment string.
decide() {  # ISSUE_JSON EFFORT HOURS_PER_DAY DAYS_PER_WEEK
  "$("$PF" --script jira_remaining_decide.py)" "$2" "$3" "$4" <<<"$1"
}

# ---------------------------------------------------------------- self-test

# jira_remaining_decide.py's own self-test holds the decision's cases. This one
# holds the script around it: the stream each line goes to, an issue too large
# for an environment string, a refused effort, and the instance's configuration.
self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local none='{"status":"Backlog","statusCategory":"new","timeOriginalEstimate":null,"timeRemainingEstimate":null,"timeSpent":null}'
  local live='{"status":"In Progress","statusCategory":"indeterminate","timeOriginalEstimate":"8h","timeRemainingEstimate":"4h","timeSpent":"4h"}'
  local big
  big=$(head -c 200000 /dev/zero | tr '\0' x \
    | jq -Rs --argjson l "$live" '$l + {description: .}')
  tap_is "an issue over 128 KiB is decided, not refused by the kernel" "$(decide "$big" 2h 8 5)" \
    $'2h\t2h (was 4h; original 8h)'
  tap_is "an effort that is not a duration is refused" "$(decide "$live" "two hours" 8 5 >/dev/null 2>&1; echo $?)" \
    2

  # The split matters as much as the decision: /timelog reads the argument off
  # stdout and shows the reasoning from stderr, so a line on the wrong stream
  # becomes part of a worklog request.
  local fx self
  fx=$(mktemp -d); trap 'rm -rf "$fx"' RETURN
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  mkdir -p "$fx/.claude/scripts"
  tap_project "$fx"
  printf '#!/usr/bin/env bash\ncat "$JR_ISSUE"\n' > "$fx/.claude/scripts/jira-issue.sh"
  chmod +x "$fx/.claude/scripts/jira-issue.sh"
  printf 'ATLASSIAN_SITE=https://example.invalid\natlassian_curl() { cat "$JR_CONFIG"; }\n' > "$fx/.claude/scripts/atlassian-auth.sh"
  export JR_ISSUE="$fx/issue.json" JR_CONFIG="$fx/config.json"
  printf '%s' "$live" > "$JR_ISSUE"
  printf '{"timeTrackingConfiguration":{"workingHoursPerDay":8,"workingDaysPerWeek":5}}' > "$JR_CONFIG"
  cd "$fx" || return 1

  tap_is "the argument alone goes to stdout" "$("$self" ABC-1 2h 2>/dev/null)" '2h'
  tap_like "the reasoning goes to stderr" "$("$self" ABC-1 2h 2>&1 >/dev/null)" \
    '*was 4h; original 8h*'
  printf '%s' "$none" > "$JR_ISSUE"
  tap_is "a ticket with no estimate prints nothing on stdout" "$("$self" ABC-1 2h 2>/dev/null)" ''
  tap_is "and still explains itself on stderr" "$([ -n "$("$self" ABC-1 2h 2>&1 >/dev/null)" ] && echo true || echo false)" \
    'true'
  tap_is "the wrong number of arguments is a usage error" "$("$self" ABC-1 >/dev/null 2>&1; echo $?)" \
    1
  # Assuming an eight-hour day would silently rewrite a burndown on an instance
  # configured otherwise.
  printf '{"timeTrackingConfiguration":{}}' > "$JR_CONFIG"
  tap_is "a configuration with no working day is refused, not assumed" "$("$self" ABC-1 2h >/dev/null 2>&1; echo $?)" \
    1
}

# ---------------------------------------------------------------- main

[[ "${1:-}" == "--self-test" ]] && { self_test; tap_end; }

[[ $# -eq 2 ]] || { echo "Usage: $0 <issue-key> <effort>" >&2 ; exit 1 ; }

# shellcheck disable=SC1091
# shellcheck source=atlassian-auth.sh
source "$("$PF" --script atlassian-auth.sh)"
BASE="${ATLASSIAN_SITE}/rest/api/3"

ISSUE_JSON=$("$("$PF" --script jira-issue.sh)" "$1")
CONFIG=$(atlassian_curl "${BASE}/configuration")
HPD=$(jq -er '.timeTrackingConfiguration.workingHoursPerDay' <<<"$CONFIG") || {
  echo "jira-remaining.sh: no workingHoursPerDay at ${BASE}/configuration; refusing to assume one" >&2
  exit 1 ; }
DPW=$(jq -er '.timeTrackingConfiguration.workingDaysPerWeek' <<<"$CONFIG") || {
  echo "jira-remaining.sh: no workingDaysPerWeek at ${BASE}/configuration; refusing to assume one" >&2
  exit 1 ; }

ROW=$(decide "$ISSUE_JSON" "$2" "$HPD" "$DPW")
printf '%s\n' "${ROW#*$'\t'}" >&2
ARG="${ROW%%$'\t'*}"
[[ -z "$ARG" ]] || printf '%s\n' "$ARG"
