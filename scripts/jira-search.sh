#!/usr/bin/env bash
# Search Jira by JQL and return the shaped issues as a JSON array. This is the
# read counterpart to the write helpers: with it there is a REST path for every
# Jira read, so no read needs an MCP tool.
#
# Usage:
#   jira-search.sh <JQL> [--max N] [--fields a,b,c] [--all]
#   jira-search.sh --self-test   # shapes a fixture, no network
#
# Example:
#   jira-search.sh 'project = ABC AND status = "In Progress"'
#   jira-search.sh 'key = ABC-10785' | jq -r '.[].summary'
#   jira-search.sh 'assignee = currentUser() ORDER BY updated DESC' --max 20
#
# `/rest/api/3/search` answers 410 Gone — Atlassian removed it (CHANGE-2046) in
# favour of `/rest/api/3/search/jql`, which is what this calls. The new endpoint
# reports neither a total nor a start offset: it pages by opaque `nextPageToken`
# and says `isLast` when there is no next. `--all` follows those tokens, and
# without it one page comes back however many pages exist.
#
# The JQL is sent with --data-urlencode, so it carries quotes, spaces and
# operators unmangled and no caller escapes anything by hand.
#
# Output is a JSON array, `[]` when nothing matched — a search that found
# nothing is an answer, not a failure:
#   [ { "key": "...", "summary": "...", "status": "...",
#       "statusCategory": "new|indeterminate|done", "assignee": "...",
#       "updated": "..." }, ... ]
#
# `statusCategory` is Jira's own key, stable across workflow renames, so a caller
# asking "is this finished" never matches on a name a project is free to change.
# `assignee` is null when unassigned, never the string "null".
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIELDS=summary,status,assignee,updated
MAX=50

# One shape, used by the live path and the self-test alike, so the fixture proves
# the mapping the real call uses rather than a copy of it.
SHAPE='[ .issues[] | {
  key,
  summary:        .fields.summary,
  status:         .fields.status.name,
  statusCategory: .fields.status.statusCategory.key,
  assignee:       (.fields.assignee.displayName // null),
  updated:        .fields.updated
} ]'

js_self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local got fixture
  fixture='{"isLast":true,"issues":[
    {"key":"ABC-1","fields":{"summary":"first","updated":"2026-09-01T00:00:00.000+0000",
      "status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},
      "assignee":{"displayName":"Ada"}}},
    {"key":"ABC-2","fields":{"summary":"second","updated":"2026-09-02T00:00:00.000+0000",
      "status":{"name":"Done","statusCategory":{"key":"done"}},
      "assignee":null}}
  ]}'
  got=$(jq -c "$SHAPE" <<<"$fixture")
  tap_is "every issue is shaped, in order" "$(jq -r 'map(.key)|join(",")' <<<"$got")" 'ABC-1,ABC-2'
  tap_is "the workflow name and the stable category both survive" \
    "$(jq -r '.[0] | "\(.status)/\(.statusCategory)"' <<<"$got")" 'In Progress/indeterminate'
  tap_is "an unassigned issue is null, not the string null" "$(jq -r '.[1].assignee == null' <<<"$got")" \
    'true'
  tap_is "no result is an empty array, not an error" "$(jq -c "$SHAPE" <<<'{"isLast":true,"issues":[]}')" \
    '[]'
  # A missing field must not become the string "null": /timelog and friends test
  # for null, and a string is truthy everywhere they look.
  tap_is "an absent assignee key behaves the same as an explicit null" "$(jq -r '.[0].assignee == null' <<<"$(jq -c "$SHAPE" <<<'{"issues":[{"key":"P-1","fields":{"summary":"s","updated":"u","status":{"name":"n","statusCategory":{"key":"new"}}}}]}')")" \
    'true'
  local flag_rc=0
  "$0" --max >/dev/null 2>&1 </dev/null || flag_rc=$?
  tap_is "a leading flag is refused offline with the usage, not sent as JQL" "$flag_rc" 2
}

[[ "${1:-}" == --self-test ]] && { js_self_test; tap_end; }

# A leading flag is never JQL: sent to Jira it comes back as HTTP 400, so it is
# refused here, offline, with the usage.
JQL="${1:-}"
[[ -n "$JQL" && "$JQL" != -* ]] || { echo "usage: jira-search.sh <JQL> [--max N] [--fields a,b] [--all]" >&2; exit 2; }
shift

ALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)    MAX="${2:?--max needs a number}"; shift 2 ;;
    --fields) FIELDS="${2:?--fields needs a comma-separated list}"; shift 2 ;;
    --all)    ALL=1; shift ;;
    *) echo "jira-search.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=./atlassian-auth.sh
. "$HELPERS/atlassian-auth.sh"
BASE="${ATLASSIAN_SITE}/rest/api/3/search/jql"

# js_page TOKEN — one page of raw JSON, or a non-zero exit with the body shown.
# A page is captured, never piped: a pipeline's status is the reader's, and a
# failed request would otherwise read as an empty result.
js_page() {
  local body code out
  out=$(mktemp); trap 'rm -f "$out"' RETURN
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time 60 \
    -u "$JIRA_USER:$JIRA_TOKEN" -H "Accept: application/json" \
    --get --data-urlencode "jql=$JQL" --data "maxResults=$MAX" --data "fields=$FIELDS" \
    ${1:+--data "nextPageToken=$1"} "$BASE") || code=000
  body=$(cat "$out")
  [[ "$code" == 200 ]] || { echo "jira-search: HTTP $code from search/jql: $body" >&2; return 1; }
  printf '%s' "$body"
}

pages=$(mktemp); trap 'rm -f "$pages"' EXIT
token=""
while :; do
  page=$(js_page "$token") || exit 1
  printf '%s\n' "$page" >> "$pages"
  [[ "$ALL" -eq 1 ]] || break
  [[ "$(jq -r '.isLast' <<<"$page")" == false ]] || break
  token=$(jq -r '.nextPageToken // empty' <<<"$page")
  [[ -n "$token" ]] || break
done

jq -s "map($SHAPE) | add // []" "$pages"
