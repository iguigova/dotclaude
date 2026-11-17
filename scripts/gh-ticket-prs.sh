#!/usr/bin/env bash
# List a ticket's open pull requests, each with what decides whether it is
# ready to ask for a review: draft or not, the review decision, mergeability
# and its checks counted as pass, fail and pending.
#
# A PR belongs to the ticket when its title or body names the key, in any of
# the GitHub owners the project lists in .claude/github_orgs (project_file.sh),
# one owner per line. The key must stand alone, so ABC-113 never matches
# ABC-1130.
#
# Usage:
#   gh-ticket-prs.sh <KEY>
#   gh-ticket-prs.sh --self-test
#
# Output, one JSON object per line, oldest first:
#   {"url", "repo", "number", "title", "draft", "review", "mergeable",
#    "checks": {"pass", "fail", "pending"}, "ready", "pushed",
#    "reviewers": [{"login", "state", "behind"}]}
# "ready" is true when the PR is not a draft, is mergeable, and no check is
# failing or pending. A check that was skipped or neutral counts as a pass.
# "pushed" is when the head commit reached GitHub: the earliest check suite on
# it, which GitHub creates for each installed app on push, else its commit
# time when no app ran. "reviewers" holds each person's latest review, the PR
# author's own and a bot's (Greptile) left out; "behind" is true when that
# review was made on another commit than the head, so the reviewer has not
# seen it. Reviews are read over GraphQL, the one API that marks a bot.
#
# Exit 0: listed, possibly nothing. Exit 1: no key, or the project names no
# .claude/github_orgs. Exit 2: a GitHub read failed, so the list is not whole.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One statusCheckRollup entry is a check run (status, conclusion) or a commit
# status (state). Each counts as exactly one of pass, fail or pending.
# shellcheck disable=SC2016  # jq program, not shell
SUMMARY='
  def verdict:
    if has("state") then
      ({"SUCCESS": "pass", "PENDING": "pending", "EXPECTED": "pending"}[.state] // "fail")
    elif .status != "COMPLETED" then "pending"
    else ({"SUCCESS": "pass", "SKIPPED": "pass", "NEUTRAL": "pass"}[.conclusion] // "fail")
    end;
  ([.statusCheckRollup[]? | verdict]) as $v
  | {pass: 0, fail: 0, pending: 0} as $zero
  | {draft: .isDraft, review: (.reviewDecision // "NONE"), mergeable,
     checks: (reduce $v[] as $x ($zero; .[$x] += 1))}
  | .ready = ((.draft | not) and .mergeable == "MERGEABLE"
              and .checks.fail == 0 and .checks.pending == 0)'

# Each reviewer but the author and bots, and whether they reviewed another commit than the head.
# shellcheck disable=SC2016
REVIEWERS='
  (.commits[-1] // {}) as $c
  | (([$c.checkSuites[]?] | min) // $c.committedDate // null) as $pushed
  | (.author.login // "") as $me
  | .head as $head
  | {pushed: $pushed,
     reviewers: [.latestReviews[]? | select(.author.login != $me and .author.__typename != "Bot")
                 | {login: .author.login, state, behind: (.commit.oid != $head)}]}'

# The head commit, the author and each latest review, as REVIEWERS reads them.
# shellcheck disable=SC2016
REVIEWS_QUERY='query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) {
  pullRequest(number: $n) { author { login } headRefOid
    commits(last: 1) { nodes { commit { committedDate checkSuites(first: 50) { nodes { createdAt } } } } }
    latestReviews(first: 50) { nodes { author { __typename login } state commit { oid } } } } } }'
# shellcheck disable=SC2016
REVIEWS_SHAPE='.data.repository.pullRequest
  | {author, head: .headRefOid, latestReviews: .latestReviews.nodes,
     commits: [.commits.nodes[].commit | {committedDate, checkSuites: [.checkSuites.nodes[].createdAt]}]}'

# Whether a title or body names the key as a whole token.
# shellcheck disable=SC2016
NAMES_KEY='(.title + "\n" + (.body // "")) | test("(^|[^A-Za-z0-9-])" + $k + "([^0-9]|$)")'

if [[ "${1:-}" == "--self-test" ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  sum() { jq -c "$SUMMARY | [.checks.pass, .checks.fail, .checks.pending, .ready]" <<<"$1"; }
  tap_is "passing, skipped and neutral checks count as passes" \
    "$(sum '{"isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[
      {"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"SKIPPED"},
      {"status":"COMPLETED","conclusion":"NEUTRAL"},{"state":"SUCCESS"}]}')" '[4,0,0,true]'
  tap_is "a running check or a pending status is pending, and not ready" \
    "$(sum '{"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[
      {"status":"IN_PROGRESS","conclusion":null},{"state":"PENDING"}]}')" '[0,0,2,false]'
  tap_is "a failed check or a failed status is a failure" \
    "$(sum '{"isDraft":false,"mergeable":"MERGEABLE","statusCheckRollup":[
      {"status":"COMPLETED","conclusion":"FAILURE"},{"state":"FAILURE"},{"status":"COMPLETED","conclusion":"CANCELLED"}]}')" \
    '[0,3,0,false]'
  tap_is "a draft is never ready" \
    "$(sum '{"isDraft":true,"mergeable":"MERGEABLE","statusCheckRollup":[]}')" '[0,0,0,false]'
  tap_is "a conflicting PR is never ready" \
    "$(sum '{"isDraft":false,"mergeable":"CONFLICTING","statusCheckRollup":[]}')" '[0,0,0,false]'
  tap_is "no review decision reads as NONE" \
    "$(jq -r "$SUMMARY | .review" <<<'{"isDraft":false,"mergeable":"MERGEABLE"}')" NONE
  revs() { jq -c "$REVIEWERS" <<<"$1"; }
  tap_is "a review of another commit is behind, one of the head is not, the author's and a bot's are left out" \
    "$(revs '{"author":{"login":"me"},"head":"h2","commits":[{"committedDate":"2026-01-01T00:00:00Z","checkSuites":[]}],"latestReviews":[
      {"author":{"login":"a"},"state":"CHANGES_REQUESTED","commit":{"oid":"h1"}},
      {"author":{"login":"b"},"state":"APPROVED","commit":{"oid":"h2"}},
      {"author":{"login":"me"},"state":"COMMENTED","commit":{"oid":"h1"}},
      {"author":{"login":"greptile-apps","__typename":"Bot"},"state":"COMMENTED","commit":{"oid":"h1"}}]}')" \
    '{"pushed":"2026-01-01T00:00:00Z","reviewers":[{"login":"a","state":"CHANGES_REQUESTED","behind":true},{"login":"b","state":"APPROVED","behind":false}]}'
  tap_is "the push time is the earliest check suite, not the commit time" \
    "$(revs '{"author":{"login":"me"},"head":"h","commits":[{"committedDate":"2026-01-01T00:00:00Z",
      "checkSuites":["2026-01-05T00:00:09Z","2026-01-05T00:00:03Z"]}],"latestReviews":[]}')" \
    '{"pushed":"2026-01-05T00:00:03Z","reviewers":[]}'
  tap_is "a PR with no commit has no push time" \
    "$(revs '{"author":{"login":"me"},"head":"h","commits":[],"latestReviews":[]}')" \
    '{"pushed":null,"reviewers":[]}'
  names() { jq -r --arg k ABC-113 "$NAMES_KEY" <<<"$1"; }
  tap_is "a key in the title names the ticket" "$(names '{"title":"ABC-113: fix"}')" true
  tap_is "a key in the body names the ticket" "$(names '{"title":"fix","body":"Jira: ABC-113."}')" true
  tap_is "a longer key does not name the ticket" "$(names '{"title":"ABC-1130: fix"}')" false
  tap_is "a key inside another key does not name the ticket" "$(names '{"title":"XABC-113: fix"}')" false

  # The whole script, against a fake gh and a project whose github_orgs holds
  # a comment, a blank line and two owners. The fake logs each search's owner.
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/bin" "$T/p/.claude"
  printf '# owners\n\nacme\nbeta\n' > "$T/p/.claude/github_orgs"
  cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1 $2" == "search prs" ]]; then
  echo "$5" >> "$FAKE_LOG"
  [[ "$5" == "$FAKE_FAIL_ORG" ]] && exit 1
  [[ "$5" == acme ]] && echo '[{"url":"https://github.com/acme/api/pull/7","title":"ABC-1: fix","body":"","createdAt":"2026-01-01"},
                              {"url":"https://github.com/acme/api/pull/8","title":"ABC-10: other","body":"","createdAt":"2026-01-02"}]' \
                     || echo '[]'
  exit 0
fi
if [[ "$1 $2" == "api graphql" ]]; then
  [[ -n "$FAKE_FAIL_REVIEWS" ]] && exit 1
  echo '{"author":{"login":"me"},"head":"h","commits":[{"committedDate":"2026-01-02T00:00:00Z","checkSuites":[]}],"latestReviews":[]}'
  exit 0
fi
[[ "$3" == "$FAKE_FAIL_URL" ]] && exit 1
echo '{"url":"'"$3"'","number":7,"title":"ABC-1: fix","isDraft":false,"reviewDecision":"APPROVED","mergeable":"MERGEABLE",
       "statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
FAKE
  chmod +x "$T/bin/gh"
  run() { (cd "$T/p" && PATH="$T/bin:$PATH" FAKE_LOG="$T/log" "$@" bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "${ARGS[@]}" 2>/dev/null); }
  ARGS=(ABC-1)
  : > "$T/log"; out=$(run env; echo "exit $?")
  tap_is "a ticket's open PR is listed with its state" "${out//$'\n'/ }" \
    '{"url":"https://github.com/acme/api/pull/7","repo":"acme/api","number":7,"title":"ABC-1: fix","draft":false,"review":"APPROVED","mergeable":"MERGEABLE","checks":{"pass":1,"fail":0,"pending":0},"ready":true,"pushed":"2026-01-02T00:00:00Z","reviewers":[]} exit 0'
  tap_is "every owner is searched, and comments and blank lines are not" "$(paste -sd' ' "$T/log")" "acme beta"
  rc=0; run env FAKE_FAIL_ORG=beta >/dev/null || rc=$?
  tap_is "a failed search exits 2" "$rc" 2
  rc=0; run env FAKE_FAIL_URL=https://github.com/acme/api/pull/7 >/dev/null || rc=$?
  tap_is "a PR that cannot be read exits 2" "$rc" 2
  rc=0; run env FAKE_FAIL_REVIEWS=1 >/dev/null || rc=$?
  tap_is "a PR whose reviews cannot be read exits 2" "$rc" 2
  ARGS=(); rc=0; run env >/dev/null || rc=$?; tap_is "no key exits 1" "$rc" 1
  ARGS=(ABC-1 ABC-2); rc=0; run env >/dev/null || rc=$?; tap_is "two keys exit 1" "$rc" 1
  ARGS=(abc-1); rc=0; run env >/dev/null || rc=$?; tap_is "a lower-case key exits 1" "$rc" 1
  rm "$T/p/.claude/github_orgs"; ARGS=(ABC-1); rc=0; run env >/dev/null || rc=$?
  tap_is "a project with no github_orgs exits 1" "$rc" 1
  tap_end
fi

if [[ $# -ne 1 || ! "$1" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
  echo "Usage: $0 <KEY> | --self-test" >&2
  exit 1
fi
KEY="$1"

if ! ORGS_FILE=$("$HERE/project_file.sh" github_orgs 2>/dev/null); then
  echo "gh-ticket-prs: the project names no .claude/github_orgs (one GitHub owner per line)" >&2
  exit 1
fi

urls=()
while read -r org; do
  [[ -z "$org" || "$org" == \#* ]] && continue
  found=$(gh search prs "$KEY" --owner "$org" --state open --limit 100 \
            --json url,title,body,createdAt) || { echo "gh-ticket-prs: search failed in $org" >&2; exit 2; }
  while read -r u; do [[ -n "$u" ]] && urls+=("$u"); done < <(
    jq -r --arg k "$KEY" "sort_by(.createdAt)[] | select($NAMES_KEY) | .url" <<<"$found")
done < "$ORGS_FILE"

for url in "${urls[@]}"; do
  pr=$(gh pr view "$url" --json url,number,title,isDraft,reviewDecision,mergeable,statusCheckRollup) \
    || { echo "gh-ticket-prs: could not read $url" >&2; exit 2; }
  IFS=/ read -r _ _ _ owner repo _ number <<<"$url"
  reviews=$(gh api graphql -f query="$REVIEWS_QUERY" -f o="$owner" -f r="$repo" -F n="$number" --jq "$REVIEWS_SHAPE") \
    || { echo "gh-ticket-prs: could not read the reviews of $url" >&2; exit 2; }
  pr=$(jq -c --argjson rv "$reviews" '. + $rv' <<<"$pr")
  jq -c "{url, number, title, repo: (.url | split(\"/\")[3:5] | join(\"/\"))} + ($SUMMARY) + ($REVIEWERS)
         | {url, repo, number, title, draft, review, mergeable, checks, ready, pushed, reviewers}" <<<"$pr"
done
