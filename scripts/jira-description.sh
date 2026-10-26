#!/usr/bin/env bash
# Replace a Jira issue description with wiki markup via REST v2, and
# optionally its summary (title) in the same PUT.
#
# Jira converts wiki markup to ADF cleanly on the v2 endpoint, so this is the
# path for authored prose. Markdown posted into a v3 ADF field renders mangled
# (bold and tables in particular).
#
# Usage:
#   jira-description.sh <issue-key> [file]   # body from file, or stdin if omitted
#   jira-description.sh --dry-run <issue-key> [file]
#   jira-description.sh --summary "<title>" <issue-key> [file]
#   jira-description.sh --summary "<title>" --summary-only <issue-key>
#   jira-description.sh --label repo:mobile-app <issue-key> [file]
#   jira-description.sh --self-test
#
# Examples:
#   jira-description.sh XYZ-1303 /tmp/desc.wiki
#   printf 'h2. Goal\n\nExport the monthly report.\n' | jira-description.sh XYZ-1303
#
# Wiki markup reference: h2. heading, *bold*, {{code}}, [text|url], * bullet,
# # numbered, ||th||th|| / |td|td| tables.
#
# PUT replaces the whole description — fetch the current body with
# jira-issue.sh first if you intend to amend rather than replace.
# --summary sets the title with the description, in one write; with
# --summary-only it sets the title alone and reads no body.
# --label adds one label, and may repeat; it keeps the labels already there.
#
# Exit 0 on HTTP 204; non-zero otherwise. Prints HTTP status to stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

DRY_RUN=0
SELF_TEST=0
SUMMARY=""
SUMMARY_ONLY=0
LABELS='[]'
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --summary) SUMMARY="${2:?--summary takes the new title}"; shift 2 ;;
    --summary-only) SUMMARY_ONLY=1; shift ;;
    --label) LABELS=$(jq -c --arg l "${2:?--label takes a label}" '. + [$l]' <<<"$LABELS"); shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Offline check of payload shape — no network, no credentials.
if [[ "$SELF_TEST" -eq 1 ]]; then
  payload=$(printf 'h2. Goal\n\n*bold* and [link|https://example.com]\n' \
    | jq -Rs '{fields:{description:.}}')
  echo "$payload" | jq -e '.fields.description | test("h2. Goal")' >/dev/null \
    || { echo "self-test: heading not preserved" >&2; exit 1; }
  echo "$payload" | jq -e '.fields.description | test("\\[link\\|https://example.com\\]")' >/dev/null \
    || { echo "self-test: wiki link mangled" >&2; exit 1; }
  echo "$payload" | jq -e 'keys == ["fields"]' >/dev/null \
    || { echo "self-test: unexpected top-level keys" >&2; exit 1; }
  # An empty stdin is refused rather than published: a description is replaced
  # whole, so an accidental empty body would erase the ticket's definition.
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  if printf '' | "$self" --dry-run XYZ-0 >/dev/null 2>&1; then
    echo "self-test: an empty description was accepted" >&2; exit 1
  fi
  both=$(printf 'h2. Goal\n' | "$self" --dry-run --summary 'New title' XYZ-0 | tail -n +2)
  echo "$both" | jq -e '.fields == {summary:"New title", description:"h2. Goal\n"}' >/dev/null \
    || { echo "self-test: summary and description not set together" >&2; exit 1; }
  only=$("$self" --dry-run --summary 'New title' --summary-only XYZ-0 </dev/null | tail -n +2)
  echo "$only" | jq -e '.fields == {summary:"New title"}' >/dev/null \
    || { echo "self-test: --summary-only touched more than the title" >&2; exit 1; }
  if "$self" --dry-run --summary-only XYZ-0 </dev/null >/dev/null 2>&1; then
    echo "self-test: --summary-only without --summary was accepted" >&2; exit 1
  fi
  labelled=$(printf 'h2. Goal\n' | "$self" --dry-run --label a --label b XYZ-0 | tail -n +2)
  echo "$labelled" | jq -e '.update == {labels:[{add:"a"},{add:"b"}]}' >/dev/null \
    || { echo "self-test: labels not added one by one" >&2; exit 1; }
  echo "jira-description self-test: PASS"
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--dry-run] [--summary <title> [--summary-only]] <issue-key> [file]   (body via stdin if no file)" >&2
  exit 1
fi

ISSUE="$1"
BODY_FILE="${2:-}"

if [[ "$SUMMARY_ONLY" -eq 1 ]]; then
  [[ -n "$SUMMARY" ]] || { echo "--summary-only needs --summary <title>" >&2; exit 2; }
  [[ -z "$BODY_FILE" ]] || { echo "--summary-only takes no body file" >&2; exit 2; }
  PAYLOAD=$(jq -n --arg s "$SUMMARY" '{fields:{summary:$s}}')
else
  if [[ -n "$BODY_FILE" ]]; then
    [[ -r "$BODY_FILE" ]] || { echo "Cannot read $BODY_FILE" >&2; exit 1; }
    PAYLOAD=$(jq -Rs '{fields:{description:.}}' < "$BODY_FILE")
  else
    PAYLOAD=$(jq -Rs '{fields:{description:.}}')
  fi
  [[ "$(echo "$PAYLOAD" | jq -r '.fields.description | length')" -gt 0 ]] \
    || { echo "Refusing to write an empty description to ${ISSUE}" >&2; exit 1; }
  if [[ -n "$SUMMARY" ]]; then
    PAYLOAD=$(echo "$PAYLOAD" | jq --arg s "$SUMMARY" '.fields.summary = $s')
  fi
fi

# An add per label, so the labels already on the issue stay.
if [[ "$LABELS" != '[]' ]]; then
  PAYLOAD=$(jq --argjson ls "$LABELS" '.update.labels = [$ls[] | {add: .}]' <<<"$PAYLOAD")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "PUT /rest/api/2/issue/${ISSUE}"
  echo "$PAYLOAD" | jq '.'
  exit 0
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X PUT "${ATLASSIAN_SITE}/rest/api/2/issue/${ISSUE}" \
  -H "Content-Type: application/json" \
  -u "${JIRA_USER}:${JIRA_TOKEN}" \
  -d "$PAYLOAD")

echo "HTTP $HTTP_CODE" >&2
if [[ "$HTTP_CODE" != "204" ]]; then
  cat "$RESP_FILE" >&2
  exit 1
fi
