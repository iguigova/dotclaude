#!/usr/bin/env bash
# Post a footer comment on a Confluence page, in storage format (XHTML).
#
# Usage:
#   confluence-comment.sh [--dry-run] [--reply-to <comment-id>] \
#     <page-id-or-url> [storage.html]
#   confluence-comment.sh [--dry-run] --edit <comment-id> [storage.html]
#   confluence-comment.sh --self-test
#
# The body comes from the file, or from stdin when no file is given.
# --reply-to threads the comment under an existing comment on that page.
# --edit replaces an existing comment's body in place, as the next version
# of it; its page and its replies stay as they are.
# --dry-run prints the request payload instead of posting it.
#
# Examples:
#   confluence-comment.sh 2613510170 /tmp/comment.html
#   printf '<p>Reviewed.</p>' | confluence-comment.sh 2613510170
#   confluence-comment.sh --reply-to 2634973186 2613510170 /tmp/reply.html
#   confluence-comment.sh --edit 2694021121 /tmp/corrected.html
#
# Prints the comment's id and link. Exit 0 on HTTP 200; non-zero
# otherwise.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PAGE_URL_ID='/pages/([0-9]+)'
NUMERIC_ID='^[0-9]+$'

page_id() {
  if [[ "$1" =~ $PAGE_URL_ID ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ $NUMERIC_ID ]]; then echo "$1"
  else echo "Cannot extract page ID from: $1" >&2; return 1
  fi
}

# A rejected comment surfaces only as a generic 400; checking first names
# the fault.
well_formed() {
  "$(dirname "${BASH_SOURCE[0]}")/storage-well-formed.sh" 2>/dev/null
}

payload() {
  jq -n --arg id "$1" --arg v "$2" --arg parent "${3:-}" \
    '{type:"comment", container:{id:$id, type:"page"},
      body:{storage:{value:$v, representation:"storage"}}}
     + if $parent == "" then {} else {ancestors:[{id:$parent}]} end'
}

# An edit sends the next version number; Confluence refuses any other.
edit_payload() {
  jq -n --arg v "$1" --argjson n "$2" \
    '{type:"comment", version:{number:($n + 1)},
      body:{storage:{value:$v, representation:"storage"}}}'
}

self_test() {
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")"
  [[ "$(page_id "https://example.invalid/wiki/spaces/PA/pages/42/Title")" == 42 ]] \
    || { echo "self-test: page id not taken from URL" >&2; exit 1; }
  if page_id "not-a-page" >/dev/null 2>&1; then
    echo "self-test: a non-page reference was accepted" >&2; exit 1
  fi
  printf '<p>a&nbsp;<strong>b</strong></p>' | well_formed \
    || { echo "self-test: well-formed storage refused" >&2; exit 1; }
  if printf '<p>unclosed' | well_formed; then
    echo "self-test: malformed storage accepted" >&2; exit 1
  fi
  printf '<p><ac:link><ri:user ri:account-id="x" /></ac:link> &mdash;</p>' \
    | well_formed \
    || { echo "self-test: a mention or named entity was refused" >&2; exit 1; }
  payload 42 '<p>x</p>' | jq -e '.container.id == "42"
    and .body.storage.representation == "storage"' >/dev/null \
    || { echo "self-test: payload shape wrong" >&2; exit 1; }
  payload 42 '<p>x</p>' | jq -e 'has("ancestors") | not' >/dev/null \
    || { echo "self-test: a top-level comment carries a parent" >&2; exit 1; }
  payload 42 '<p>x</p>' 7 | jq -e '.ancestors == [{id:"7"}]' >/dev/null \
    || { echo "self-test: reply parent missing" >&2; exit 1; }
  if printf '<p>x</p>' | "$self" --dry-run --reply-to x 42 \
    >/dev/null 2>&1; then
    echo "self-test: a non-numeric parent was accepted" >&2; exit 1
  fi
  edit_payload '<p>x</p>' 3 | jq -e '.version.number == 4
    and .type == "comment" and (has("container") | not)' >/dev/null \
    || { echo "self-test: edit payload does not send the next version" >&2; exit 1; }
  if printf '<p>x</p>' | "$self" --dry-run --edit x >/dev/null 2>&1; then
    echo "self-test: a non-numeric comment id was accepted for --edit" >&2; exit 1
  fi
  if printf '<p>x</p>' | "$self" --dry-run --edit 7 --reply-to 8 42 >/dev/null 2>&1; then
    echo "self-test: --edit was combined with --reply-to" >&2; exit 1
  fi
  if printf '' | "$self" --dry-run 42 >/dev/null 2>&1; then
    echo "self-test: an empty comment was accepted" >&2; exit 1
  fi
  echo "confluence-comment self-test: PASS"
}

DRY_RUN=0
PARENT=""
EDIT=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --reply-to) PARENT="${2:-}"; shift 2 ;;
    --edit) EDIT="${2:-}"; shift 2 ;;
    --self-test) self_test; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$EDIT" ]]; then
  [[ "$EDIT" =~ $NUMERIC_ID ]] \
    || { echo "Comment id must be numeric: $EDIT" >&2; exit 1; }
  [[ -z "$PARENT" ]] \
    || { echo "--edit keeps the comment's place; drop --reply-to" >&2; exit 1; }
  BODY="$(cat "${1:-/dev/stdin}")"
  [[ -n "${BODY//[[:space:]]/}" ]] \
    || { echo "Refusing to write an empty comment" >&2; exit 1; }
  printf '%s' "$BODY" | well_formed \
    || { echo "Body is not well-formed storage XHTML" >&2; exit 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "PUT /wiki/rest/api/content/$EDIT"
    edit_payload "$BODY" 0
    exit 0
  fi
  HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck disable=SC1091
  source "${HELPER_DIR}/atlassian-auth.sh"
  BASE="${ATLASSIAN_SITE}/wiki"
  VERSION="$(atlassian_curl "$BASE/rest/api/content/$EDIT?expand=version" \
    | jq -er '.version.number')" \
    || { echo "Cannot read comment $EDIT" >&2; exit 1; }
  RESPONSE="$(mktemp)"
  trap 'rm -f "$RESPONSE"' EXIT
  STATUS="$(atlassian_curl -o "$RESPONSE" -w '%{http_code}' -X PUT \
    -H "Content-Type: application/json" \
    --data "$(edit_payload "$BODY" "$VERSION")" \
    "$BASE/rest/api/content/$EDIT")"
  echo "HTTP $STATUS" >&2
  [[ "$STATUS" == 200 ]] || { cat "$RESPONSE" >&2; exit 1; }
  jq -r '"\(.id) v\(.version.number) '"$BASE"'\(._links.webui)"' "$RESPONSE"
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--dry-run] [--reply-to <comment-id>]" \
    "<page-id-or-url> [storage.html]" >&2
  exit 1
fi
[[ -z "$PARENT" || "$PARENT" =~ $NUMERIC_ID ]] \
  || { echo "Comment id must be numeric: $PARENT" >&2; exit 1; }

PAGE_ID="$(page_id "$1")"
BODY="$(cat "${2:-/dev/stdin}")"

[[ -n "${BODY//[[:space:]]/}" ]] \
  || { echo "Refusing to post an empty comment" >&2; exit 1; }
printf '%s' "$BODY" | well_formed \
  || { echo "Body is not well-formed storage XHTML" >&2; exit 1; }

if [[ "$DRY_RUN" -eq 1 ]]; then
  payload "$PAGE_ID" "$BODY" "$PARENT"
  exit 0
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
BASE="${ATLASSIAN_SITE}/wiki"

RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT
STATUS="$(atlassian_curl -o "$RESPONSE" -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  --data "$(payload "$PAGE_ID" "$BODY" "$PARENT")" \
  "$BASE/rest/api/content")"

echo "HTTP $STATUS" >&2
[[ "$STATUS" == 200 ]] || { cat "$RESPONSE" >&2; exit 1; }
jq -r '"\(.id) '"$BASE"'\(._links.webui)"' "$RESPONSE"
