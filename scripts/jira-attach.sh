#!/usr/bin/env bash
# Attach files to a Jira issue, via REST v2.
#
# A comment embeds an attachment by filename, e.g. !shot.png|thumbnail!, so
# attach first and then post the comment that shows it.
#
# Usage:
#   jira-attach.sh [--dry-run] <issue-key> <file>...
#   jira-attach.sh [--dry-run] --list <issue-key>      # "<id> <filename>" per attachment
#   jira-attach.sh [--dry-run] --delete <attachment-id>...
#   jira-attach.sh --self-test
#
# Example:
#   jira-attach.sh ABC-90876 .playwright-mcp/a.png .playwright-mcp/b.png
#
# Prints one line per attachment: "<id> <filename>". Every file is checked
# for readability before anything is sent, so a typo attaches nothing. Exit 0
# on HTTP 200; non-zero otherwise, with the HTTP status and response on stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PF="$HOME/.claude/scripts/project_file.sh"

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
  tap_is "a listing reads the issue's attachment field" \
    "$("$self" --dry-run --list XYZ-0)" 'GET /rest/api/2/issue/XYZ-0?fields=attachment'
  tap_is "each id is DELETEd on the v2 attachment endpoint" \
    "$("$self" --dry-run --delete 11 12)" 'DELETE /rest/api/2/attachment/11'$'\n''DELETE /rest/api/2/attachment/12'
  tap_fails "a non-numeric attachment id is refused" \
    "$self" --dry-run --delete 11 abc
  tap_is "a single attachment id is accepted" \
    "$("$self" --dry-run --delete 11)" 'DELETE /rest/api/2/attachment/11'
  tap_fails "--delete with no id is refused" "$self" --dry-run --delete
  # The fake's $FAKE_CODE expands when the fake runs, not here.
  # shellcheck disable=SC2016
  printf '%s\n' 'ATLASSIAN_SITE=https://jira.invalid' \
    'atlassian_curl() { printf %s "$FAKE_CODE"; }' > "$tmp/auth.sh"
  tap_is "a 204 reports the attachment deleted" \
    "$(JIRA_AUTH_LIB="$tmp/auth.sh" FAKE_CODE=204 "$self" --delete 11)" 'deleted 11'
  tap_fails "any other status fails the delete" \
    env JIRA_AUTH_LIB="$tmp/auth.sh" FAKE_CODE=404 "$self" --delete 11
  tap_end
fi
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=1; shift; }

# JIRA_AUTH_LIB stands in for the auth library in the self-test only.
AUTH_LIB="${JIRA_AUTH_LIB:-$("$PF" --script atlassian-auth.sh)}"
case "${1:-}" in
  --list)
    [[ "${2:-}" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || { echo "Not an issue key: ${2:-}" >&2; exit 1; }
    path="/rest/api/2/issue/$2?fields=attachment"
    [[ "$DRY_RUN" -eq 1 ]] && { echo "GET $path"; exit 0; }
    # shellcheck source=atlassian-auth.sh
    source "$AUTH_LIB"
    atlassian_curl -sf "${ATLASSIAN_SITE}${path}" | jq -r '.fields.attachment[] | "\(.id) \(.filename)"'
    exit 0 ;;
  --delete)
    shift
    [[ $# -ge 1 ]] || { echo "Usage: $0 --delete <attachment-id>..." >&2; exit 1; }
    for id in "$@"; do [[ "$id" =~ ^[0-9]+$ ]] || { echo "Not an attachment id: $id; nothing deleted" >&2; exit 1; }; done
    if [[ "$DRY_RUN" -eq 1 ]]; then printf 'DELETE /rest/api/2/attachment/%s\n' "$@"; exit 0; fi
    # shellcheck source=atlassian-auth.sh
    source "$AUTH_LIB"
    for id in "$@"; do
      code=$(atlassian_curl -s -o /dev/null -w "%{http_code}" -X DELETE "${ATLASSIAN_SITE}/rest/api/2/attachment/${id}")
      [[ "$code" == "204" ]] || { echo "HTTP $code deleting $id" >&2; exit 1; }
      echo "deleted $id"
    done
    exit 0 ;;
esac

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

# shellcheck source=atlassian-auth.sh
source "$AUTH_LIB"

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
