#!/usr/bin/env bash
# Attach files to a Jira issue, via REST v2.
#
# A comment embeds an attachment by filename, e.g. !shot.png|thumbnail!, so
# attach first and then post the comment that shows it.
#
# Usage:
#   jira-attach.sh [--dry-run] <issue-key> <file>...
#   jira-attach.sh --self-test
#
# Example:
#   jira-attach.sh ABC-10876 .playwright-mcp/a.png .playwright-mcp/b.png
#
# Prints one line per attachment: "<id> <filename>". Every file is checked
# for readability before anything is sent, so a typo attaches nothing. Exit 0
# on HTTP 200; non-zero otherwise, with the HTTP status and response on stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

DRY_RUN=0
if [[ "${1:-}" == "--self-test" ]]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  printf 'x' > "$tmp/a.png"; printf 'y' > "$tmp/b.png"
  out=$("$self" --dry-run XYZ-0 "$tmp/a.png" "$tmp/b.png")
  # shellcheck source=tap.sh
  . "$(dirname "$self")/tap.sh"
  tap_is "the files are POSTed to the v2 attachments endpoint" \
    "$(sed -n 1p <<<"$out")" 'POST /rest/api/2/issue/XYZ-0/attachments'
  tap_is "a dry run lists every file in order" \
    "$(sed 1d <<<"$out")" "$tmp/a.png"$'\n'"$tmp/b.png"
  # One unreadable file refuses the whole call, so nothing is half-attached.
  tap_fails "a missing file is refused" \
    "$self" --dry-run XYZ-0 "$tmp/a.png" "$tmp/missing.png"
  tap_fails "a malformed issue key is refused" \
    "$self" --dry-run not-a-key "$tmp/a.png"
  tap_end
fi
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=1; shift; }

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 [--dry-run] <issue-key> <file>..." >&2
  exit 1
fi

ISSUE="$1"; shift
[[ "$ISSUE" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || { echo "Not an issue key: $ISSUE" >&2; exit 1; }
for f in "$@"; do
  [[ -r "$f" && -f "$f" ]] || { echo "Cannot read $f; nothing attached" >&2; exit 1; }
done

ENDPOINT=/rest/api/2/issue/${ISSUE}/attachments
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "POST $ENDPOINT"
  printf '%s\n' "$@"
  exit 0
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

FORM=()
for f in "$@"; do FORM+=(-F "file=@${f}"); done

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

# Jira refuses a multipart upload without this header (XSRF check).
HTTP_CODE=$(atlassian_curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "${ATLASSIAN_SITE}${ENDPOINT}" \
  -H "X-Atlassian-Token: no-check" "${FORM[@]}")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  exit 1
fi
jq -r '.[] | "\(.id) \(.filename)"' "$RESP_FILE"
