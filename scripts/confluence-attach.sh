#!/usr/bin/env bash
# Attach files to a Confluence page, replacing any attachment of the same
# name with a new version of it (REST v1).
#
# A page body embeds an attachment by filename, e.g.
# <ac:image><ri:attachment ri:filename="flow.png" /></ac:image>, so attach
# first and then write the body that shows it. Re-attaching a file under the
# same name updates the image in place on every page version that embeds it.
#
# Usage:
#   confluence-attach.sh [--dry-run] <page-id-or-url> <file>...
#   confluence-attach.sh --self-test
#
# Example:
#   confluence-attach.sh 2691989506 diagram/lpr-read-to-visit.png
#
# Prints one line per attachment: "<id> <filename> v<version>". Every file is
# checked for readability before anything is sent, so a typo attaches nothing.
# Exit 0 on HTTP 200; non-zero otherwise, with the HTTP status and response on
# stderr. --dry-run prints the endpoint and files and sends nothing.

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
  cp "$src" "$tmp/confluence-attach.sh"
  printf 'x' > "$tmp/a.png"; printf 'y' > "$tmp/b.png"
  cat > "$tmp/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local o="" a
  printf '%s\n' "$*" >> "$(dirname "${BASH_SOURCE[0]}")/calls"
  while [[ $# -gt 0 ]]; do a="$1"; shift; [[ "$a" == -o ]] && { o="$1"; shift; }; done
  printf '{"results":[{"id":"att1","title":"a.png","version":{"number":1}},{"id":"att2","title":"b.png","version":{"number":3}}]}' > "$o"
  printf 200
}
STUB
  out=$("$tmp/confluence-attach.sh" \
    "https://example.invalid/wiki/spaces/PA/pages/42/Title" "$tmp/a.png" "$tmp/b.png")
  # PUT, not POST: POST refuses a filename the page already has.
  grep -q -- "-X PUT https://example.invalid/wiki/rest/api/content/42/child/attachment" "$tmp/calls" \
    || { echo "self-test: does not PUT to child/attachment" >&2; exit 1; }
  grep -q -- "X-Atlassian-Token: no-check" "$tmp/calls" \
    || { echo "self-test: XSRF header missing" >&2; exit 1; }
  grep -q -- "-F file=@$tmp/a.png -F minorEdit=true -F file=@$tmp/b.png -F minorEdit=true" "$tmp/calls" \
    || { echo "self-test: not every file is sent, in order, each with its minorEdit" >&2; exit 1; }
  [[ "$out" == $'att1 a.png v1\natt2 b.png v3' ]] \
    || { echo "self-test: output not '<id> <name> v<n>': $out" >&2; exit 1; }
  if "$tmp/confluence-attach.sh" --dry-run 42 "$tmp/a.png" "$tmp/missing.png" >/dev/null 2>&1; then
    echo "self-test: a missing file was accepted" >&2; exit 1
  fi
  if "$tmp/confluence-attach.sh" --dry-run not-a-page "$tmp/a.png" >/dev/null 2>&1; then
    echo "self-test: a non-page reference was accepted" >&2; exit 1
  fi
  echo "confluence-attach self-test: PASS"
}

DRY_RUN=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --self-test) self_test; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 [--dry-run] <page-id-or-url> <file>..." >&2
  exit 1
fi
PAGE_ID="$(page_id "$1")"; shift
for f in "$@"; do
  [[ -r "$f" && -f "$f" ]] || { echo "Cannot read $f; nothing attached" >&2; exit 1; }
done

ENDPOINT="/wiki/rest/api/content/${PAGE_ID}/child/attachment"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "PUT $ENDPOINT"
  printf '%s\n' "$@"
  exit 0
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

# Confluence pairs each file with its own minorEdit field, and refuses an
# upload whose two counts differ.
FORM=()
for f in "$@"; do FORM+=(-F "file=@${f}" -F "minorEdit=true"); done

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT
# Confluence refuses a multipart upload without this header (XSRF check).
HTTP_CODE=$(atlassian_curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X PUT "${ATLASSIAN_SITE}${ENDPOINT}" \
  -H "X-Atlassian-Token: no-check" "${FORM[@]}")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  exit 1
fi
jq -r '.results[] | "\(.id) \(.title) v\(.version.number)"' "$RESP_FILE"
