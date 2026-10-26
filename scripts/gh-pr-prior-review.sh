#!/usr/bin/env bash
# Answer "have I reviewed this PR before, and has it moved since?" from a
# gh-pr-fetch.sh blob on stdin. Used by /review:pr to tell a first pass from a
# re-review without improvising the comparison each time.
#
# Usage:
#   gh-pr-fetch.sh <pr-ref> | gh-pr-prior-review.sh [--as <login>]
#   gh-pr-prior-review.sh --self-test
#
# `--as` defaults to $GH_PR_REVIEWER, else the authenticated `gh` user. Only
# that resolution touches the network; the comparison itself is pure jq.
#
# Output JSON:
#   {
#     "reviewer": "<login>",
#     "head_sha": "<current head>",
#     "prior": null | { state, commit, submitted_at, body, stale },
#     "delta_range": null | "<prior commit>..<head>",
#     "findings": [ { id, path, line, commit, body, replies: [ {author, body, created_at} ] } ],
#     "others_threads": [ { id, author, path, line, commit, body, replies: [ ... ] } ],
#     "blocking_others": [ { author, state, commit, submitted_at } ]
#   }
#
# `prior` is your own latest review; `stale` is true when it was submitted
# against a commit that is no longer head. A reply in a review thread is
# recorded by GitHub as a COMMENTED review with an empty body, so such a review
# is not a review here: replying to a thread on a new head would otherwise mark
# the PR as already reviewed there — the signal that a re-review is due,
# and that every finding in it was written against code that has since moved.
# `delta_range` is what to read; it is null on a first pass and on a re-review
# of an unchanged PR.
#
# `findings` are your own top-level inline comments, each with the replies it
# drew. An author's reply is a *claim* that something was fixed, which is why it
# is carried next to the finding rather than summarised: the point of the
# re-review is to check the claim against the head, not to accept it.
#
# `others_threads` are every other reviewer's top-level inline comments, bots
# included, each with its replies. A finding this review shares with one of them
# is acknowledged as a reply in that thread rather than posted a second time, so
# the author answers one thread per defect; `id` is what the reply names.
#
# `blocking_others` is every *other* reviewer whose latest review is
# CHANGES_REQUESTED — the blocks that still gate the merge and that approving
# will not clear. GitHub scores reviewDecision on each reviewer's latest review
# only, so the per-author fold here matches what the merge button sees.
#
# Exits non-zero if stdin is not a gh-pr-fetch.sh blob.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# The whole comparison, stated once so --self-test can drive it over fixtures.
PRIOR_JQ='
  def thread($rc): . as $f
    | { id: $f.id, author: $f.author, path: $f.path, line: $f.line,
        commit: $f.commit, body: $f.body,
        replies: [ $rc[] | select(.in_reply_to == $f.id) | { author, body, created_at } ] };
  (.reviews // [])         as $rv
| (.review_comments // []) as $rc
| (.head_sha)              as $head
| ( [ $rv[] | select(.author == $me)
           | select(.state != "COMMENTED" or ((.body // "") | length) > 0) ]
    | sort_by(.submitted_at // "") | last ) as $mine
| { reviewer: $me,
    head_sha: $head,
    prior: (
      if $mine == null then null
      else { state:        $mine.state,
             commit:       $mine.commit,
             submitted_at: $mine.submitted_at,
             body:         $mine.body,
             stale:        ($mine.commit != $head) }
      end
    ),
    delta_range: (
      if ($mine != null and ($mine.commit // null) != null and $mine.commit != $head)
      then ($mine.commit + ".." + $head) else null end
    ),
    findings: [ $rc[] | select(.author == $me and .in_reply_to == null) | thread($rc) ],
    others_threads: [ $rc[] | select(.author != $me and .in_reply_to == null) | thread($rc) ],
    blocking_others: [
      $rv | group_by(.author)[]
      | sort_by(.submitted_at // "") | last
      | select(.author != $me and .state == "CHANGES_REQUESTED")
      | { author, state, commit, submitted_at }
    ] }'

if [[ "${1:-}" == "--self-test" ]]; then
  fails=()
  run() {  # <blob> <me> <jq-filter> -> stdout
    jq -c --arg me "$2" "$PRIOR_JQ | ($3)" <<<"$1"
  }
  want() {  # <label> <blob> <me> <filter> <want>
    local got; got=$(run "$2" "$3" "$4")
    [[ "$got" == "$5" ]] || fails+=("$1: got $got, want $5")
  }

  # A second pass: my review sits on an older commit, the author replied to one
  # of my findings, and another reviewer's block still stands.
  SECOND='{
    "head_sha":"ccc",
    "reviews":[
      {"author":"me","state":"CHANGES_REQUESTED","commit":"aaa","submitted_at":"2026-01-01T00:00:00Z","body":"must fix"},
      {"author":"dev","state":"COMMENTED","commit":"bbb","submitted_at":"2026-01-02T00:00:00Z"},
      {"author":"other","state":"CHANGES_REQUESTED","commit":"ccc","submitted_at":"2026-01-03T00:00:00Z"}],
    "review_comments":[
      {"id":1,"in_reply_to":null,"author":"me","path":"a.py","line":10,"commit":"aaa","body":"boom"},
      {"id":2,"in_reply_to":1,"author":"dev","path":"a.py","line":10,"commit":"bbb","body":"Fixed.","created_at":"2026-01-02T00:00:00Z"},
      {"id":3,"in_reply_to":null,"author":"other","path":"b.py","line":2,"commit":"ccc","body":"theirs"}]}'
  want "stale prior"     "$SECOND" me '.prior.stale'            'true'
  want "prior body"      "$SECOND" me '.prior.body'             '"must fix"'
  want "delta range"     "$SECOND" me '.delta_range'            '"aaa..ccc"'
  want "my findings only" "$SECOND" me '[.findings[].id]'       '[1]'
  want "reply carried"   "$SECOND" me '.findings[0].replies[0].body' '"Fixed."'
  want "others block"    "$SECOND" me '[.blocking_others[].author]'  '["other"]'
  want "others threads"  "$SECOND" me '[.others_threads[] | [.id, .author, .path, .line]]' '[[3,"other","b.py",2]]'
  # A reply is part of its thread, never a thread of its own — the author's
  # "Fixed." on my finding must not surface as someone else's finding.
  want "reply is not a thread" "$SECOND" me '[.others_threads[].id]' '[3]'

  # A first pass: no review of mine, so nothing is stale and there is no delta.
  FIRST='{"head_sha":"ccc","reviews":[{"author":"other","state":"COMMENTED","commit":"ccc","submitted_at":"2026-01-01T00:00:00Z"}],"review_comments":[]}'
  want "no prior"        "$FIRST" me '.prior'        'null'
  want "no delta"        "$FIRST" me '.delta_range'  'null'
  want "no findings"     "$FIRST" me '.findings'     '[]'
  want "commented is not a block" "$FIRST" me '.blocking_others' '[]'

  # A re-review of an unchanged PR: prior exists, but there is nothing to read.
  SAME='{"head_sha":"ccc","reviews":[{"author":"me","state":"COMMENTED","commit":"ccc","submitted_at":"2026-01-01T00:00:00Z","body":"looks fine"}],"review_comments":[]}'
  want "fresh prior"     "$SAME" me '.prior.stale'   'false'
  want "no delta when unmoved" "$SAME" me '.delta_range' 'null'

  # Only the latest review per author counts, exactly as reviewDecision scores
  # it — a block that its author later withdrew must not be reported as live.
  WITHDRAWN='{"head_sha":"ccc","reviews":[
      {"author":"other","state":"CHANGES_REQUESTED","commit":"aaa","submitted_at":"2026-01-01T00:00:00Z"},
      {"author":"other","state":"APPROVED","commit":"ccc","submitted_at":"2026-01-02T00:00:00Z"}],
    "review_comments":[]}'
  want "withdrawn block is not live" "$WITHDRAWN" me '.blocking_others' '[]'
  # ...and the reverse: an approval later replaced by a block still blocks.
  REBLOCKED='{"head_sha":"ccc","reviews":[
      {"author":"other","state":"APPROVED","commit":"aaa","submitted_at":"2026-01-01T00:00:00Z"},
      {"author":"other","state":"CHANGES_REQUESTED","commit":"ccc","submitted_at":"2026-01-02T00:00:00Z"}],
    "review_comments":[]}'
  want "re-blocked counts" "$REBLOCKED" me '[.blocking_others[].author]' '["other"]'

  # My own latest review wins over my earlier one, so a second pass compares
  # against what I last said, not what I said first.
  TWOMINE='{"head_sha":"ccc","reviews":[
      {"author":"me","state":"CHANGES_REQUESTED","commit":"aaa","submitted_at":"2026-01-01T00:00:00Z"},
      {"author":"me","state":"APPROVED","commit":"bbb","submitted_at":"2026-01-02T00:00:00Z"}],
    "review_comments":[]}'
  want "latest of mine wins" "$TWOMINE" me '.prior.state' '"APPROVED"'
  want "delta from latest"   "$TWOMINE" me '.delta_range' '"bbb..ccc"'

  # Replying in a thread on a new head records an empty-body COMMENTED review
  # there; the review being answered is still the prior one.
  REPLIED='{"head_sha":"ccc","reviews":[
      {"author":"me","state":"COMMENTED","commit":"aaa","submitted_at":"2026-01-01T00:00:00Z","body":"must fix"},
      {"author":"me","state":"COMMENTED","commit":"ccc","submitted_at":"2026-01-02T00:00:00Z","body":""}],
    "review_comments":[]}'
  want "a reply is not a review" "$REPLIED" me '.prior.commit' '"aaa"'
  want "delta past a reply"      "$REPLIED" me '.delta_range'  '"aaa..ccc"'

  if ((${#fails[@]})); then
    printf 'gh-pr-prior-review self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-prior-review self-test: PASS (first/second/unchanged pass, reply threading, other reviewers' threads, latest-review-per-author fold, thread replies)"
  exit 0
fi

ME="${GH_PR_REVIEWER:-}"
if [[ "${1:-}" == "--as" ]]; then
  ME="${2:-}"
  [[ -n "$ME" ]] || { echo "--as needs a login" >&2; exit 1; }
fi
if [[ -z "$ME" ]]; then
  ME=$(gh api user --jq .login) || { echo "cannot resolve the reviewer login; pass --as <login>" >&2; exit 1; }
fi

BLOB=$(cat)
jq -e 'has("reviews") and has("head_sha")' <<<"$BLOB" >/dev/null 2>&1 || {
  echo "stdin is not a gh-pr-fetch.sh blob (no .reviews/.head_sha)" >&2; exit 1; }

jq --arg me "$ME" "$PRIOR_JQ" <<<"$BLOB"
