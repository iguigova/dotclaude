#!/usr/bin/env bash
# Read a Jira issue as one flat JSON object: summary, status, time tracking,
# description, comments, links and the last 5 worklog entries.
#
# Usage:
#   jira-issue.sh <issue-key>
#   jira-issue.sh --self-test   # runs the output shape over a fixture, no network
#
# Example:
#   jira-issue.sh XYZ-1235 | jq '.timetracking.remainingEstimate'
#   jira-issue.sh XYZ-1235 | jq -r '.description'
#
# The issue is read over REST v2, so `description` and each comment `body` are
# wiki markup — the form a Jira write takes, so a body read here can be edited
# and written back.
#
# `statusCategory` is Jira's own key, stable when a project renames its
# workflow statuses.
#
# Comments are read from the issue's comment endpoint, page by page, because
# that is where Jira carries a threaded reply's `parentId`; the issue's own
# `comment` field returns it null for every comment. `parentId` is the id of
# the comment replied to, null on a top-level comment.
#
# Time tracking appears both flat and nested under `timetracking`. An absent
# value is null, never dropped.
#
#   {
#     "key": "...",
#     "summary": "...",
#     "status": "...",                    // the workflow status name
#     "statusCategory": "new|indeterminate|done",
#     "assignee": "...",
#     "timeOriginalEstimate": "...",      // null if unset
#     "timeRemainingEstimate": "...",     // null if unset
#     "timeSpent": "...",                 // total logged on the issue; null if none
#     "timetracking": { "originalEstimate": "...", "remainingEstimate": "...", "timeSpent": "..." },
#     "description": "...",               // null if empty
#     "comments": [ { "id": "...", "parentId": "...", "author": "...", "created": "...", "body": "..." }, ... ],
#     "links": [ { "type": "...", "key": "...", "summary": "..." }, ... ],
#     "worklog": [ { "id": "...", "started": "...", "author": "...", "timeSpent": "..." }, ... ]
#   }
#
# A link's `type` is the phrase read from this issue: "blocks" for an outward
# link, "is blocked by" for an inward one.
#
# Exit 0 with the object; exit 1 on a malformed key or a failed read, with the
# reason on stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

KEY_PATTERN='^[A-Z][A-Z0-9]*-[0-9]+$'
FIELDS="summary,status,assignee,timetracking,description,issuelinks"
COMMENT_PAGE=100

SHAPE='{
  key: $i.key,
  summary: $i.fields.summary,
  status: $i.fields.status.name,
  statusCategory: $i.fields.status.statusCategory.key,
  assignee: ($i.fields.assignee.displayName // null),
  timeOriginalEstimate: ($i.fields.timetracking.originalEstimate // null),
  timeRemainingEstimate: ($i.fields.timetracking.remainingEstimate // null),
  timeSpent: ($i.fields.timetracking.timeSpent // null),
  timetracking: ($i.fields.timetracking // {}),
  description: ($i.fields.description // null),
  comments: [ $c.comments[] | {
    id: .id,
    parentId: (if .parentId then (.parentId | tostring) else null end),
    author: .author.displayName,
    created: .created,
    body: .body
  } ],
  links: [ ($i.fields.issuelinks // [])[] | {
    type: (if .outwardIssue then .type.outward else .type.inward end),
    key: (.outwardIssue // .inwardIssue).key,
    summary: (.outwardIssue // .inwardIssue).fields.summary
  } ],
  worklog: [ $w.worklogs[-5:][] | {
    id: .id,
    started: .started,
    author: .author.displayName,
    timeSpent: .timeSpent
  } ]
}'

usage() { echo "Usage: $0 <issue-key>" >&2; exit 1; }

# shape <issue-json> <comments-json> <worklog-json> — the documents reach jq on stdin, never
# as arguments: the kernel caps one argument at 128 KiB, which a long
# description or comment thread passes.
shape() {
  printf '%s\n%s\n%s\n' "$1" "$2" "$3" \
    | jq -s ".[0] as \$i | .[1] as \$c | .[2] as \$w | ${SHAPE}"
}

# A Jira error body carries errorMessages and no key; anything else is the
# resource asked for.
read_or_fail() {
  local json
  json=$(atlassian_curl "$1")
  if ! jq -e 'has("errorMessages") | not' <<<"$json" >/dev/null 2>&1; then
    echo "jira-issue: $1: $(jq -rc '.errorMessages // .' <<<"$json" 2>/dev/null \
      || echo "$json")" >&2
    exit 1
  fi
  printf '%s' "$json"
}

# read_comments <comment-url> — every page of the comment endpoint, as one
# {"comments": [...]} document. A page shorter than asked for, or reaching
# `total`, is the last.
read_comments() {
  local start=0 page all='[]' got
  while :; do
    page=$(read_or_fail "$1?startAt=${start}&maxResults=${COMMENT_PAGE}")
    all=$(printf '%s\n%s\n' "$all" "$page" | jq -sc '.[0] + .[1].comments')
    got=$(jq '.comments | length' <<<"$page")
    start=$((start + got))
    (( got < COMMENT_PAGE || start >= $(jq '.total' <<<"$page") )) && break
  done
  jq -c '{comments: .}' <<<"$all"
}

# The shape is the contract its readers use, so the test runs the real jq
# program over a fixture, then drives the script's own argument gate.
if [[ "${1:-}" == "--self-test" ]]; then
  issue='{"key":"AAA-1","fields":{"summary":"s",
    "status":{"name":"To Do","statusCategory":{"key":"new"}},
    "assignee":null,"timetracking":{},
    "description":"h3. Goal",
    "issuelinks":[
      {"type":{"outward":"blocks","inward":"is blocked by"},
       "outwardIssue":{"key":"AAA-2","fields":{"summary":"o"}}},
      {"type":{"outward":"blocks","inward":"is blocked by"},
       "inwardIssue":{"key":"AAA-3","fields":{"summary":"i"}}}]}}'
  bare='{"key":"AAA-4","fields":{"summary":"s",
    "status":{"name":"To Do","statusCategory":{"key":"new"}}}}'
  logs='{"worklogs":[{"id":"1","started":"t","author":{"displayName":"a"},"timeSpent":"1h"},
    {"id":"2","started":"t","author":{"displayName":"a"},"timeSpent":"1h"},
    {"id":"3","started":"t","author":{"displayName":"a"},"timeSpent":"1h"},
    {"id":"4","started":"t","author":{"displayName":"a"},"timeSpent":"1h"},
    {"id":"5","started":"t","author":{"displayName":"a"},"timeSpent":"1h"},
    {"id":"6","started":"t","author":{"displayName":"a"},"timeSpent":"1h"}]}'
  comments='{"comments":[{"id":"9","author":{"displayName":"a"},
      "created":"t","body":"*done*"},{"id":"10","parentId":9,
      "author":{"displayName":"a"},"created":"t","body":"r"}]}'
  got=$(shape "$issue" "$comments" "$logs" \
    | jq -r '[.summary, (.timeRemainingEstimate // "null"), (.worklog|length|tostring),
              .worklog[0].id, (.timetracking|type), .statusCategory, .description,
              .comments[0].body, (.comments|map(.parentId // "-")|join(",")),
              (.links|map("\(.type) \(.key)")|join(","))]
             | join("|")')
  want='s|null|5|2|object|new|h3. Goal|*done*|-,9|blocks AAA-2,is blocked by AAA-3'
  got_bare=$(shape "$bare" '{"comments":[]}' '{"worklogs":[]}' \
    | jq -r '[(.description|tostring), (.comments|length), (.links|length)]
             | join("|")')
  want_bare='null|0|0'
  big=$(head -c 200000 /dev/zero | tr '\0' x | jq -Rs '{"key":"AAA-5",
    "fields":{"summary":"s","status":{"name":"To Do","statusCategory":{"key":"new"}},
    "description":.}}')
  got_big=$(shape "$big" '{"comments":[]}' '{"worklogs":[]}' | jq -r '.description | length')
  # Paging, offline: a stub endpoint of 3 comments served 2 to a page.
  COMMENT_PAGE=2
  atlassian_curl() {
    local start=${1#*startAt=}; start=${start%%&*}
    jq -nc --argjson s "$start" '{total: 3,
      comments: [range($s; [$s + 2, 3] | min) | {id: (. | tostring)}]}'
  }
  got_paged=$(read_comments x | jq -r '.comments | map(.id) | join(",")')
  flag_rc=0; "$0" --bogus >/dev/null 2>&1 </dev/null || flag_rc=$?
  usage=$(timeout 10 "$0" 2>&1 </dev/null || true)
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  names=("the summary is a flat key" "an absent estimate is null"
         "the last 5 worklogs are kept" "the worklogs kept are the latest"
         "an empty timetracking stays an object" "the status category is kept"
         "the description is kept" "a comment keeps its body"
         "a reply keeps its parentId" "links read in both directions")
  IFS='|' read -ra g <<<"$got"; IFS='|' read -ra w <<<"$want"
  for i in "${!names[@]}"; do tap_is "${names[$i]}" "${g[$i]:-}" "${w[$i]}"; done
  tap_is "an issue with no description, comments or links reads null or empty" \
    "$got_bare" "$want_bare"
  tap_is "a description over 128 KiB is kept whole" "$got_big" 200000
  tap_is "comments are read across pages" "$got_paged" 0,1,2
  tap_is "an unknown flag is refused offline" "$flag_rc" 1
  tap_run "a call with no key prints the usage" grep -q '<issue-key>' <<<"$usage"
  tap_end
fi

[[ $# -eq 1 && "$1" =~ $KEY_PATTERN ]] || usage

ISSUE="$1"

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
BASE="${ATLASSIAN_SITE}/rest/api/2"

ISSUE_JSON=$(read_or_fail "${BASE}/issue/${ISSUE}?fields=${FIELDS}")
COMMENTS_JSON=$(read_comments "${BASE}/issue/${ISSUE}/comment")
WORKLOG_JSON=$(read_or_fail "${BASE}/issue/${ISSUE}/worklog")

shape "$ISSUE_JSON" "$COMMENTS_JSON" "$WORKLOG_JSON"
