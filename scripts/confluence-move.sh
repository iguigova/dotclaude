#!/usr/bin/env bash
# Move a Confluence page under, before or after another page (REST v1).
#
# Usage:
#   confluence-move.sh [--dry-run] [--position append|before|after] \
#     <page-id-or-url> <target-id-or-url>
#   confluence-move.sh --self-test
#
# append (the default) makes the page the target's last child; before and
# after make it the target's sibling. The page keeps its id, URL, body,
# comments and attachments; its children move with it.
#
# Example:
#   confluence-move.sh 2693660675 2337931284
#
# Prints the page id and its new ancestor path, read back after the move.
# Exit 0 on HTTP 200; non-zero otherwise, with the status and response on
# stderr. --dry-run prints the request and sends nothing.

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

# The whole script runs against a stubbed atlassian-auth.sh copied beside it,
# so the request it sends is the one asserted.
self_test() {
  local src out
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cp "$src" "$tmp/confluence-move.sh"
  cat > "$tmp/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local o="" a
  printf '%s\n' "$*" >> "$(dirname "${BASH_SOURCE[0]}")/calls"
  while [[ $# -gt 0 ]]; do a="$1"; shift; [[ "$a" == -o ]] && { o="$1"; shift; }; done
  if [[ -n "$o" ]]; then printf '{"pageId":"42"}' > "$o"; printf 200
  else printf '{"ancestors":[{"title":"Space"},{"title":"Ad Hoc"}]}'
  fi
}
STUB
  out=$("$tmp/confluence-move.sh" \
    "https://example.invalid/wiki/spaces/PA/pages/42/Title" 7 2>/dev/null)
  # shellcheck source=tap.sh
  . "$(dirname "$src")/tap.sh"
  tap_run "the move is a PUT to move/append/<target>" grep -q -- \
    '-X PUT https://example.invalid/wiki/rest/api/content/42/move/append/7' "$tmp/calls"
  tap_is "the page's new ancestor path is read back" "$out" "42 Space > Ad Hoc"
  tap_is "--position is honoured" \
    "$("$tmp/confluence-move.sh" --dry-run --position before 42 7)" \
    "PUT /wiki/rest/api/content/42/move/before/7"
  tap_fails "an unknown position is refused" \
    "$tmp/confluence-move.sh" --dry-run --position under 42 7
  tap_fails "a page is not moved relative to itself" \
    "$tmp/confluence-move.sh" --dry-run 42 42
  tap_fails "a non-page reference is refused" \
    "$tmp/confluence-move.sh" --dry-run not-a-page 7
}

DRY_RUN=0
POSITION=append
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --position) POSITION="${2:-}"; shift 2 ;;
    --self-test) self_test; tap_end ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 [--dry-run] [--position append|before|after]" \
    "<page-id-or-url> <target-id-or-url>" >&2
  exit 1
fi
case "$POSITION" in append|before|after) ;;
  *) echo "Position must be append, before or after: $POSITION" >&2; exit 1 ;;
esac
PAGE_ID="$(page_id "$1")"
TARGET_ID="$(page_id "$2")"
[[ "$PAGE_ID" != "$TARGET_ID" ]] \
  || { echo "A page cannot move relative to itself: $PAGE_ID" >&2; exit 1; }

ENDPOINT="/wiki/rest/api/content/${PAGE_ID}/move/${POSITION}/${TARGET_ID}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "PUT $ENDPOINT"
  exit 0
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT
HTTP_CODE=$(atlassian_curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X PUT "${ATLASSIAN_SITE}${ENDPOINT}")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  exit 1
fi

atlassian_curl -s "${ATLASSIAN_SITE}/wiki/rest/api/content/${PAGE_ID}?expand=ancestors" \
  | jq -r --arg id "$PAGE_ID" '"\($id) \([.ancestors[].title] | join(" > "))"'
