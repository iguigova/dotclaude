#!/usr/bin/env bash
# Fetch a GitHub PR's metadata + diff + reviews + inline review comments in
# parallel, return them in one JSON blob. Wraps the call pattern used by
# /review:pr.
#
# Usage:
#   gh-pr-fetch.sh <pr-ref>
#   gh-pr-fetch.sh --self-test
#
# Where <pr-ref> is one of:
#   https://github.com/Org/repo/pull/123
#   Org/repo#123
#   #123                                     (uses CWD's git remote)
#
# Output JSON:
#   {
#     "owner": "...", "repo": "...", "number": 123,
#     "head_sha": "<meta.headRefOid>",
#     "ticket":   "<XYZ-1234, or empty when neither title nor branch names one>",
#     "gate":     { mergeable, merge_state, review_decision, checks },
#     "meta":     { <gh pr view --json output> },
#     "diff":     "<unified diff as a string>",
#     "reviews":  [ { author, state, body, commit, submitted_at }, ... ],
#     "review_comments": [ { id, in_reply_to, author, path, line, commit, body, created_at }, ... ]
#   }
#
# `head_sha` is the commit the diff describes: gh-pr-diff-index.sh records it and
# gh-pr-review-post.sh refuses to post a review whose index names a different
# one. `ticket` is the single owner of the ticket-key rule — the first
# `[A-Z]+-[0-9]+` in the title or head branch — so the review's billing step
# reads it from here instead of re-deriving it.
#
# `gate` answers "is this mergeable right now" without a second round trip:
# `checks` is {total, failed[], pending[]} folded from `statusCheckRollup`, whose
# entries come in two shapes (a CheckRun carries name/status/conclusion/detailsUrl,
# a StatusContext carries context/state/targetUrl) — reading only one shape
# silently scores half a PR's checks as absent. Each failed or pending entry is
# {name, url}: the url is the page that shows why, so no step needs `gh pr checks`
# to find it, and an Actions url carries the run id `gh run view` takes. A check that is SKIPPED or NEUTRAL is neither
# failed nor pending, because neither blocks a merge.
#
# Each review carries the `commit` it was submitted against, which is what makes
# a re-review possible: a review whose commit is not `head_sha` was written
# against code that has since moved. `review_comments` carries the inline threads
# with `in_reply_to`, so a prior finding can be read next to the author's answer
# to it.
#
# Exits non-zero if the ref is unrecognized or any of the gh calls fail.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The ticket-key rule, stated once: first XYZ-1234-shaped token in the PR title
# or the head branch name, empty string when there is none.
TICKET_JQ='[ (.title + " " + (.headRefName // "")) | scan("[A-Z]+-[0-9]+") ] | (.[0] // "")'

# The merge gate, folded from `gh pr view` meta. Split out so --self-test can
# drive it over both statusCheckRollup element shapes offline.
GATE_JQ='
{
  mergeable:       (.mergeable // "UNKNOWN"),
  merge_state:     (.mergeStateStatus // "UNKNOWN"),
  review_decision: (.reviewDecision // ""),
  checks: (
    [ (.statusCheckRollup // [])[]
      | { name: (.name // .context // "?"),
          url:  (.detailsUrl // .targetUrl // null),
          state: (
            if   ((.status // null) != null and .status != "COMPLETED") then "PENDING"
            elif ((.conclusion // null) != null)                        then .conclusion
            elif ((.state // null) != null)                             then .state
            else "PENDING" end
          ) } ]
    | { total:   length,
        failed:  [ .[] | select(.state as $s | ["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","ERROR","STARTUP_FAILURE","STALE"] | index($s)) | {name, url} ],
        pending: [ .[] | select(.state as $s | ["PENDING","EXPECTED","QUEUED","IN_PROGRESS","WAITING","REQUESTED"]                     | index($s)) | {name, url} ] }
  )
}'

if [[ "${1:-}" == "--self-test" ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  check() {  # <name> <meta-json> <want>
    tap_is "$1" "$(jq -r "$TICKET_JQ" <<<"$2")" "$3"
  }
  check "a key in the title is the ticket" '{"title":"XYZ-1234 fix the thing","headRefName":"feature/x"}' "XYZ-1234"
  check "a key in the branch is the ticket" '{"title":"Fix the thing","headRefName":"ABC-7213-scan-button"}' "ABC-7213"
  check "the title's key wins over the branch's" '{"title":"XYZ-1 a","headRefName":"ABC-2-b"}' "XYZ-1"
  check "no key in either is no ticket" '{"title":"Bump deps","headRefName":"chore/bump"}' ""
  check "a null branch still reads the title" '{"title":"XYZ-9 x","headRefName":null}' "XYZ-9"
  check "lowercase is not a key" '{"title":"xyz-1234 x","headRefName":"x"}' ""

  gate() {  # <label> <meta-json> <jq-filter-over-gate> <want>
    tap_is "$1" "$(jq -c "$GATE_JQ | ($3)" <<<"$2")" "$4"
  }
  # A CheckRun and a StatusContext in one rollup: both shapes must be counted.
  MIXED='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"test (1)","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"test (2)","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://gh/runs/7/job/8"},
    {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":null},
    {"__typename":"CheckRun","name":"skipme","status":"COMPLETED","conclusion":"SKIPPED"},
    {"__typename":"CheckRun","name":"unstarted","status":null,"conclusion":null},
    {"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE","targetUrl":"https://ci/legacy/1"},
    {"__typename":"StatusContext","context":"ci/waiting","state":"PENDING"},
    {"__typename":"StatusContext","context":"ci/ok","state":"SUCCESS"}]}'
  gate "the gate counts checks of both shapes"  "$MIXED" '.checks.total'   '8'
  gate "the gate lists failures of both shapes"  "$MIXED" '[.checks.failed[].name]'  '["test (2)","ci/legacy"]'
  gate "the gate lists pending checks of both shapes" "$MIXED" '[.checks.pending[].name]' '["lint","unstarted","ci/waiting"]'
  # Each shape names its link differently; both must reach the entry, and a
  # check that has none carries null rather than dropping the key.
  gate "a failure of either shape carries its link" "$MIXED" '[.checks.failed[].url]' '["https://gh/runs/7/job/8","https://ci/legacy/1"]'
  gate "a check with no link carries null" "$MIXED" '.checks.pending[0]' '{"name":"lint","url":null}'
  # SKIPPED and NEUTRAL block nothing, so they belong in neither bucket.
  gate "a skipped check is not failed"  "$MIXED" '[.checks.failed[].name] | index("skipme")'  'null'
  gate "a skipped check is not pending" "$MIXED" '[.checks.pending[].name] | index("skipme")' 'null'
  # A PR with no checks at all must fold to zero, not to null or an error.
  gate "no rollup folds to zero checks" '{"mergeable":"MERGEABLE"}' '.checks' '{"total":0,"failed":[],"pending":[]}'
  gate "no rollup keeps mergeable" '{"mergeable":"MERGEABLE"}' '.mergeable' '"MERGEABLE"'
  gate "an absent review decision is empty" '{}' '.review_decision' '""'

  # headRefOid must be requested, or the index has no commit to pin to.
  tap_run "headRefOid is in the --json field list" grep -q 'headRefOid' "${BASH_SOURCE[0]}"
  # The gate is only as good as the fields behind it.
  for f in statusCheckRollup mergeable mergeStateStatus reviewDecision; do
    tap_run "$f is in the --json field list" grep -q -- "$f" "${BASH_SOURCE[0]}"
  done
  # A review without its commit cannot be told apart from one written against
  # the current head, which is the whole basis of the re-review path.
  tap_run "reviews[] keeps .commit.oid" grep -q 'commit: .commit.oid' "${BASH_SOURCE[0]}"
  tap_run "reviews[] keeps .submittedAt" grep -q 'submitted_at: .submittedAt' "${BASH_SOURCE[0]}"
  tap_run "review_comments[] keeps in_reply_to_id" grep -q 'in_reply_to' "${BASH_SOURCE[0]}"
  # Structural, because the failure needs a network call to reproduce: a bare
  # `wait` returns 0 whatever the children did, so each job must be waited on
  # by pid or a 404 PR yields a clean exit and a null blob.
  tap_fails "no bare 'wait' hides a gh failure" grep -qE '^\s*wait\s*$' "${BASH_SOURCE[0]}"
  for v in META_PID DIFF_PID REVIEWS_PID COMMENTS_PID; do
    tap_run "$v is waited on by pid" grep -q "wait \"\$$v\"" "${BASH_SOURCE[0]}"
  done
  # The ref forms are gh_pr_ref.py's to define; this only checks delegation.
  tap_run "gh_pr_ref.py's self-test passes" "$HERE/gh_pr_ref.py" --self-test
  tap_end
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <pr-ref> | --self-test" >&2
  exit 1
fi

REFJSON=$("$HERE/gh_pr_ref.py" "$1") || exit 1
OWNER=$(jq -er .owner <<<"$REFJSON")
REPO=$(jq -er .repo <<<"$REFJSON")
NUMBER=$(jq -er .number <<<"$REFJSON")
RSLUG="${OWNER}/${REPO}"

META_FILE=$(mktemp); DIFF_FILE=$(mktemp)
REVIEWS_FILE=$(mktemp); COMMENTS_FILE=$(mktemp)
trap 'rm -f "$META_FILE" "$DIFF_FILE" "$REVIEWS_FILE" "$COMMENTS_FILE"' EXIT

gh pr view "$NUMBER" --repo "$RSLUG" \
  --json title,body,author,state,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,files,reviewDecision,labels,createdAt,updatedAt,mergeable,mergeStateStatus,statusCheckRollup \
  > "$META_FILE" & META_PID=$!

gh pr diff "$NUMBER" --repo "$RSLUG" > "$DIFF_FILE" & DIFF_PID=$!

gh pr view "$NUMBER" --repo "$RSLUG" \
  --json reviews \
  --jq '[.reviews[] | {author: .author.login, state: .state, body: .body, commit: .commit.oid, submitted_at: .submittedAt}]' \
  > "$REVIEWS_FILE" & REVIEWS_PID=$!

# Inline threads, which `gh pr view --json reviews` does not carry at all. A
# prior finding is only actionable next to the reply it drew, so the reply's
# `in_reply_to` is kept rather than flattened away.
gh api "repos/$RSLUG/pulls/$NUMBER/comments" --paginate \
  --jq '[.[] | {id, in_reply_to: .in_reply_to_id, author: .user.login, path, line: (.line // .original_line), commit: .commit_id, body, created_at}]' \
  > "$COMMENTS_FILE" & COMMENTS_PID=$!

# Each job is waited on by pid: a bare `wait` returns 0 however the children
# fared, which would emit `{"meta": null, "diff": ""}` for a PR that does not
# exist and let every later step run on it.
rc=0
wait "$META_PID"     || rc=1
wait "$DIFF_PID"     || rc=1
wait "$REVIEWS_PID"  || rc=1
wait "$COMMENTS_PID" || rc=1
if [[ "$rc" -ne 0 ]]; then
  echo "One or more gh calls for $RSLUG#$NUMBER failed (see above); not emitting a partial blob." >&2
  exit 1
fi

# --paginate emits one array per page; fold them into one before emitting.
jq -n \
  --arg owner "$OWNER" --arg repo "$REPO" --argjson number "$NUMBER" \
  --slurpfile meta "$META_FILE" \
  --rawfile diff "$DIFF_FILE" \
  --slurpfile reviews "$REVIEWS_FILE" \
  --slurpfile comments "$COMMENTS_FILE" \
  "{owner: \$owner, repo: \$repo, number: \$number,
    head_sha: (\$meta[0].headRefOid // null),
    ticket: (\$meta[0] | $TICKET_JQ),
    gate: (\$meta[0] | $GATE_JQ),
    meta: \$meta[0], diff: \$diff,
    reviews: \$reviews[0],
    review_comments: (\$comments | add // [])}"
