#!/usr/bin/env bash
# Post or edit a Jira comment written in wiki markup, via REST v2.
#
# Jira converts wiki markup to ADF on the v2 endpoint, the same path
# jira-create.sh and jira-description.sh take. Markdown posted into a v3 ADF
# field renders mangled.
#
# Usage:
#   jira-comment.sh [--dry-run] [--edit <comment-id> | --reply <comment-id>] <issue-key> [file]
#   (flags may appear in any position)
#   jira-comment.sh --self-test
#
# The body comes from the file, or stdin if omitted. --edit replaces that
# comment's whole body in place; without it a new comment is created.
# --reply creates it threaded under that comment, as the UI's Reply does: the
# body carries parentId. A comment link's focusedCommentId is the id to pass.
# Jira threads one level deep, so a reply to a reply goes under the top
# comment of its thread, which the script resolves before posting.
#
# Examples:
#   jira-comment.sh XYZ-1273 /tmp/comment.wiki
#   printf 'Verified on staging; closing.' | jira-comment.sh XYZ-1273
#   jira-comment.sh --edit 75696 ABC-10785 /tmp/fixed.wiki
#   jira-comment.sh --reply 77752 ABC-10955 /tmp/answer.wiki
#
# Wiki markup reference: h3. heading, *bold*, {{code}}, [text|url], * bullet,
# # numbered, ||th||th|| / |td|td| tables, {code}…{code} blocks.
#
# Prints the comment JSON (its id is .id). Exit 0 on HTTP 200/201; non-zero
# otherwise, with the HTTP status and response on stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

DRY_RUN=0
EDIT_ID=""
REPLY_ID=""
SELF_TEST=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --edit) EDIT_ID="${2:?--edit needs a comment id}"; shift 2 ;;
    --reply) REPLY_ID="${2:?--reply needs a comment id}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    --*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ "$SELF_TEST" -eq 1 ]]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  out=$(printf 'h3. Update\n*State.* [PR|https://x/1]\n||a||b||\n|1|2|\n' \
    | "$self" --dry-run XYZ-0)
  sed -n 1p <<<"$out" | grep -qx 'POST /rest/api/2/issue/XYZ-0/comment' \
    || { echo "self-test: create does not POST to the v2 comment endpoint" >&2; exit 1; }
  sed 1d <<<"$out" | jq -e 'keys == ["body"]
      and (.body | test("^h3. Update\n\\*State.\\* \\[PR\\|https://x/1\\]\n\\|\\|a\\|\\|b\\|\\|"))' >/dev/null \
    || { echo "self-test: wiki markup not passed through verbatim" >&2; exit 1; }
  out=$(printf 'fixed' | "$self" --dry-run --edit 42 XYZ-0)
  sed -n 1p <<<"$out" | grep -qx 'PUT /rest/api/2/issue/XYZ-0/comment/42' \
    || { echo "self-test: --edit does not PUT to the comment" >&2; exit 1; }
  # An empty body is refused: an edit would erase the comment it replaces.
  if printf '' | "$self" --dry-run --edit 42 XYZ-0 >/dev/null 2>&1; then
    echo "self-test: an empty body was accepted" >&2; exit 1
  fi
  out=$(printf 'x' | "$self" XYZ-0 /dev/stdin --edit 42 --dry-run)
  sed -n 1p <<<"$out" | grep -qx 'PUT /rest/api/2/issue/XYZ-0/comment/42' \
    || { echo "self-test: a flag after the key is not honoured" >&2; exit 1; }
  out=$(printf 'answer' | "$self" --dry-run --reply 42 XYZ-0)
  sed -n 1p <<<"$out" | grep -qx 'POST /rest/api/2/issue/XYZ-0/comment' \
    || { echo "self-test: --reply does not POST to the v2 comment endpoint" >&2; exit 1; }
  sed 1d <<<"$out" | jq -e '. == {body: "answer", parentId: 42}' >/dev/null \
    || { echo "self-test: --reply does not carry parentId" >&2; exit 1; }
  if printf 'x' | "$self" --dry-run --reply 42 --edit 42 XYZ-0 >/dev/null 2>&1; then
    echo "self-test: --reply and --edit were accepted together" >&2; exit 1
  fi
  if printf 'x' | "$self" --dry-run --reply abc XYZ-0 >/dev/null 2>&1; then
    echo "self-test: a non-numeric --reply id was accepted" >&2; exit 1
  fi
  if printf 'x' | "$self" --dry-run XYZ-0 /dev/stdin extra >/dev/null 2>&1; then
    echo "self-test: a third positional argument was accepted" >&2; exit 1
  fi
  echo "jira-comment self-test: PASS"
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--dry-run] [--edit <comment-id> | --reply <comment-id>] <issue-key> [file]   (body via stdin if no file)" >&2
  exit 1
fi
if [[ $# -gt 2 ]]; then
  echo "Unexpected argument after <issue-key> [file]: ${*:3}" >&2
  exit 2
fi

[[ -z "$EDIT_ID" || -z "$REPLY_ID" ]] \
  || { echo "--edit and --reply cannot be combined" >&2; exit 2; }
[[ -z "$REPLY_ID" || "$REPLY_ID" =~ ^[0-9]+$ ]] \
  || { echo "--reply needs a numeric comment id, got: $REPLY_ID" >&2; exit 2; }

ISSUE="$1"
BODY_FILE="${2:-}"

if [[ -n "$BODY_FILE" ]]; then
  [[ -r "$BODY_FILE" ]] || { echo "Cannot read $BODY_FILE" >&2; exit 1; }
  PAYLOAD=$(jq -Rs '{body:.}' < "$BODY_FILE")
else
  PAYLOAD=$(jq -Rs '{body:.}')
fi

[[ -n "$(jq -r '.body | gsub("\\s"; "")' <<<"$PAYLOAD")" ]] \
  || { echo "Refusing to write an empty comment to ${ISSUE}" >&2; exit 1; }

if [[ -n "$EDIT_ID" ]]; then
  METHOD=PUT ENDPOINT=/rest/api/2/issue/${ISSUE}/comment/${EDIT_ID}
else
  METHOD=POST ENDPOINT=/rest/api/2/issue/${ISSUE}/comment
fi

if [[ -n "$REPLY_ID" ]]; then
  PAYLOAD=$(jq --argjson p "$REPLY_ID" '. + {parentId: $p}' <<<"$PAYLOAD")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "$METHOD $ENDPOINT"
  jq '.' <<<"$PAYLOAD"
  exit 0
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

# A reply to a reply belongs under the top comment of its thread.
if [[ -n "$REPLY_ID" ]]; then
  TOP_ID=$(atlassian_curl -sf "${ATLASSIAN_SITE}/rest/api/2/issue/${ISSUE}/comment/${REPLY_ID}" \
    | jq -r '.parentId // .id') \
    || { echo "Cannot read comment ${REPLY_ID} on ${ISSUE}" >&2; exit 1; }
  PAYLOAD=$(jq --argjson p "$TOP_ID" '.parentId = $p' <<<"$PAYLOAD")
fi

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(atlassian_curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X "$METHOD" "${ATLASSIAN_SITE}${ENDPOINT}" \
  -H "Content-Type: application/json" \
  --data "$PAYLOAD")

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" ]]; then
  echo "HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  exit 1
fi
cat "$RESP_FILE"
