#!/usr/bin/env bash
# The remaining-estimate argument for jira-worklog.sh, decided rather than
# guessed. jira-worklog.sh posts `adjustEstimate=new&newEstimate=<arg>`, which
# SETS remaining rather than decrementing it, so a number worked out in passing
# silently rewrites a burndown.
#
# Usage:
#   jira-remaining.sh <issue-key> <effort>   # e.g. jira-remaining.sh ABC-7703 2h
#   jira-remaining.sh --self-test            # decides over fixtures, no network
#
# stdout is the argument to pass, or EMPTY when it must be omitted. Capture it
# and expand it conditionally, so an omit stays an omit:
#
#   REM=$(jira-remaining.sh ABC-7703 2h)
#   jira-worklog.sh --quiet ABC-7703 2h ${REM:+"$REM"} < items
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


# ---------------------------------------------------------------- decide

# ISSUE_JSON is jira-issue.sh's flat object. Prints "<arg>\t<rendering>", and
# exits 2 when the effort is not a duration — billing against a misread number
# is worse than not billing, so the caller stops before the worklog is posted.
# The issue is cut to the fields the decision reads before it enters the
# environment: the kernel caps one environment string at 128 KiB, which a long
# description or comment thread passes.
decide() {  # ISSUE_JSON EFFORT HOURS_PER_DAY DAYS_PER_WEEK
  local fields
  fields=$(jq -c '{status, statusCategory, timeOriginalEstimate,
                   timeRemainingEstimate, timeSpent}' <<<"$1") || return 2
  ISSUE_JSON="$fields" EFFORT="$2" HPD="$3" DPW="$4" python3 <<'PY'
import json, os, re, sys

HPD = float(os.environ["HPD"])
DPW = float(os.environ["DPW"])
UNIT = {"m": 1.0, "h": 60.0, "d": HPD * 60.0, "w": DPW * HPD * 60.0}
TOKEN = re.compile(r"(\d+(?:\.\d+)?)([wdhm])", re.I)
# Tokens must be whitespace-separated. `2h30m` is unambiguous arithmetic and
# still refused, because REST v3 refuses it: reading it here would only move
# the failure to the POST, where a worklog is already half-made.
SPACED = re.compile(r"^\s*\d+(?:\.\d+)?[wdhm](?:\s+\d+(?:\.\d+)?[wdhm])*\s*$", re.I)


def minutes(s):
    """A Jira duration in minutes, or None when the whole string is not one.
    A partial reading is a wrong estimate, and a wrong estimate is the thing
    this script exists to stop."""
    if s is None or not SPACED.match(str(s)):
        return None
    return sum(float(m.group(1)) * UNIT[m.group(2).lower()]
               for m in TOKEN.finditer(str(s)))


def render(mins):
    """Minutes as the spaced Jira form, in this instance's days and hours."""
    mins = int(round(mins))
    if mins <= 0:
        return "0h"
    d, rest = divmod(mins, int(HPD * 60))
    h, m = divmod(rest, 60)
    return " ".join(p for p in (f"{d}d" if d else "", f"{h}h" if h else "",
                                f"{m}m" if m else "") if p)


def out(arg, text):
    print(f"{arg}\t{text}")
    sys.exit(0)


i = json.loads(os.environ["ISSUE_JSON"])
effort = minutes(os.environ["EFFORT"])
if effort is None or effort <= 0:
    print("jira-remaining.sh: effort is not a Jira duration: %r"
          % os.environ["EFFORT"], file=sys.stderr)
    sys.exit(2)

orig_s = i.get("timeOriginalEstimate")
rem_s = i.get("timeRemainingEstimate")
spent_s = i.get("timeSpent")
status = i.get("status") or "?"
cat = (i.get("statusCategory") or "").lower()
orig, rem, spent = minutes(orig_s), minutes(rem_s), minutes(spent_s)

over = ""
if orig is not None and (spent or 0) + effort > orig:
    over = (" — OVER: %s spent plus %s exceeds the %s original"
            % (spent_s or "0h", os.environ["EFFORT"], orig_s))

if orig is None and rem is None:
    out("", "not set — no estimate on this ticket, so logging leaves it at 0h. "
            "Suggest a real original estimate if it is sprint-bound.")

if cat == "done":
    out("0h", "0h — %s is a Done status, so the clock closes with the worklog.%s"
              % (status, over))

if rem is None:
    out("", "unreadable (%r) — argument omitted, so Jira subtracts from the "
            "original.%s" % (rem_s, over))

if rem <= 0:
    out("", "0h already — %s is open but the burndown is spent (%s logged against "
            "an original of %s). Argument omitted: any number would raise it.%s"
            % (status, spent_s or "0h", orig_s or "none", over))

left = rem - effort
if left <= 0:
    out("", "this effort exhausts the %s left — argument omitted so Jira floors it "
            "at 0h. Set a real estimate if the work is not finished.%s" % (rem_s, over))

out(render(left), "%s (was %s; original %s)%s"
                  % (render(left), rem_s, orig_s or "not set", over))
PY
}

HELPER_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------- self-test

# The decision is the contract, so the test drives `decide` over fixtures: no
# network, and every state that omits the argument is named here.
self_test() {
  local rc=0
  check() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then echo "  ok   $1"
    else printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3" >&2; rc=1; fi
  }
  arg() {  # ISSUE_JSON EFFORT [HPD] [DPW] — the argument alone
    local row; row=$(decide "$1" "$2" "${3:-8}" "${4:-5}") || return 2
    printf '%s' "${row%%$'\t'*}"
  }
  why() {  # ISSUE_JSON EFFORT — the rendering alone
    local row; row=$(decide "$1" "$2" 8 5) || return 2
    printf '%s' "${row#*$'\t'}"
  }
  local none='{"status":"Backlog","statusCategory":"new","timeOriginalEstimate":null,"timeRemainingEstimate":null,"timeSpent":null}'
  local spent='{"status":"Testing","statusCategory":"indeterminate","timeOriginalEstimate":"8h","timeRemainingEstimate":"0h","timeSpent":"81h"}'
  local live='{"status":"In Progress","statusCategory":"indeterminate","timeOriginalEstimate":"8h","timeRemainingEstimate":"4h","timeSpent":"4h"}'
  local day='{"status":"In Progress","statusCategory":"indeterminate","timeOriginalEstimate":"2d","timeRemainingEstimate":"1d","timeSpent":"1d"}'
  local week='{"status":"In Progress","statusCategory":"indeterminate","timeOriginalEstimate":"2w","timeRemainingEstimate":"1w","timeSpent":"1w"}'
  local done='{"status":"Done","statusCategory":"done","timeOriginalEstimate":"8h","timeRemainingEstimate":"2h","timeSpent":"6h"}'
  local junk='{"status":"In Progress","statusCategory":"indeterminate","timeOriginalEstimate":"8h","timeRemainingEstimate":"about a day","timeSpent":"4h"}'

  echo "jira-remaining.sh --self-test"
  check "a ticket with no estimate omits the argument" "" "$(arg "$none" 2h)"
  check "remaining already 0h on an open ticket omits it" "" "$(arg "$spent" 1h)"
  check "and says the burndown is spent, with the overrun" \
    "0h already — Testing is open but the burndown is spent (81h logged against an original of 8h). Argument omitted: any number would raise it. — OVER: 81h spent plus 1h exceeds the 8h original" \
    "$(why "$spent" 1h)"
  check "effort that exhausts what is left omits it" "" "$(arg "$live" 4h)"
  check "an unreadable remaining omits it rather than guessing" "" "$(arg "$junk" 1h)"
  check "an ordinary subtraction" "2h" "$(arg "$live" 2h)"
  check "a decimal effort" "2h 30m" "$(arg "$live" 1.5h)"
  check "days use this instance's working day, not 24h" "6h" "$(arg "$day" 2h)"
  check "a six-hour working day gives a different answer" "5h" "$(arg "$day" 1h 6)"
  check "weeks carry the working week" "4d 5h 30m" "$(arg "$week" 2.5h)"
  check "a Done ticket closes the clock" "0h" "$(arg "$done" 1h)"
  local big
  big=$(head -c 200000 /dev/zero | tr '\0' x \
    | jq -Rs --argjson l "$live" '$l + {description: .}')
  check "an issue over 128 KiB is decided, not refused by the kernel" "2h" \
    "$(arg "$big" 2h)"
  check "the rendering names what it was and the original" \
    "2h (was 4h; original 8h)" "$(why "$live" 2h)"
  check "an effort that is not a duration is refused" 2 \
    "$(decide "$live" "two hours" 8 5 >/dev/null 2>&1; echo $?)"
  check "an unspaced compound is refused, as REST v3 refuses it" 2 \
    "$(decide "$live" "2h30m" 8 5 >/dev/null 2>&1; echo $?)"

  # The split matters as much as the decision: /timelog reads the argument off
  # stdout and shows the reasoning from stderr, so a line on the wrong stream
  # becomes part of a worklog request.
  local fx self
  fx=$(mktemp -d); trap 'rm -rf "$fx"' RETURN
  cp "$HELPER_SELF" "$fx/jira-remaining.sh"
  self="$fx/jira-remaining.sh"
  printf '#!/usr/bin/env bash\ncat "$JR_ISSUE"\n' > "$fx/jira-issue.sh"
  chmod +x "$fx/jira-issue.sh"
  printf 'ATLASSIAN_SITE=https://example.invalid\natlassian_curl() { cat "$JR_CONFIG"; }\n' > "$fx/atlassian-auth.sh"
  export JR_ISSUE="$fx/issue.json" JR_CONFIG="$fx/config.json"
  printf '%s' "$live" > "$JR_ISSUE"
  printf '{"timeTrackingConfiguration":{"workingHoursPerDay":8,"workingDaysPerWeek":5}}' > "$JR_CONFIG"

  check "the argument alone goes to stdout" '2h' "$("$self" ABC-1 2h 2>/dev/null)"
  check "the reasoning goes to stderr" 'true' \
    "$("$self" ABC-1 2h 2>&1 >/dev/null | grep -q 'was 4h; original 8h' && echo true || echo false)"
  printf '%s' "$none" > "$JR_ISSUE"
  check "a ticket with no estimate prints nothing on stdout" '' "$("$self" ABC-1 2h 2>/dev/null)"
  check "and still explains itself on stderr" 'true' \
    "$([ -n "$("$self" ABC-1 2h 2>&1 >/dev/null)" ] && echo true || echo false)"
  check "the wrong number of arguments is a usage error" 1 \
    "$("$self" ABC-1 >/dev/null 2>&1; echo $?)"
  # Assuming an eight-hour day would silently rewrite a burndown on an instance
  # configured otherwise.
  printf '{"timeTrackingConfiguration":{}}' > "$JR_CONFIG"
  check "a configuration with no working day is refused, not assumed" 1 \
    "$("$self" ABC-1 2h >/dev/null 2>&1; echo $?)"
  return $rc
}

# ---------------------------------------------------------------- main

[[ "${1:-}" == "--self-test" ]] && { self_test; exit $?; }

[[ $# -eq 2 ]] || { echo "Usage: $0 <issue-key> <effort>" >&2 ; exit 1 ; }

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
BASE="${ATLASSIAN_SITE}/rest/api/3"

ISSUE_JSON=$("${HELPER_DIR}/jira-issue.sh" "$1")
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
