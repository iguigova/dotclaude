#!/usr/bin/env bash
# Assign a Jira issue to a person, via REST v2.
#
# WHO is an Atlassian account id, or "me" for the account the token belongs
# to, read from /myself on every call. --if-unassigned leaves an issue that
# already has an assignee as it is and says who holds it, so a caller taking
# up a ticket never takes it from someone else.
#
# Usage:
#   jira-assign.sh [--dry-run] [--if-unassigned] <KEY> <me|accountId>
#   jira-assign.sh --self-test
#
# Examples:
#   jira-assign.sh ABC-7725 me
#   jira-assign.sh --if-unassigned ABC-7725 me
#
# Prints "<KEY>: assigned to <name>", or "<KEY>: kept, assigned to <name>"
# when --if-unassigned found an assignee. --dry-run prints the request instead
# and changes nothing. Exit 0 on HTTP 204 or a kept assignee; 2 on a usage
# error; 1 otherwise, with the HTTP status and response on stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_RE='^[A-Z][A-Z0-9]+-[0-9]+$'

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  cp "${HELPER_DIR}/jira-assign.sh" "$fx/jira-assign.sh"
  cat > "$fx/atlassian-auth.sh" <<'STUB'
# Stub transport. Answers /myself and the assignee reads from fixtures,
# records what would be PUT, and never opens a socket.
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local url="${!#}" data="" prev="" a
  for a in "$@"; do [[ "$prev" == "--data" ]] && data="$a"; prev="$a"; done
  case "$url" in
    */myself) printf '%s' '{"accountId":"acc-me","displayName":"Me Myself"}' ;;
    */issue/ABC-1\?fields=assignee) printf '%s' '{"fields":{"assignee":null}}' ;;
    */issue/ABC-2\?fields=assignee)
      printf '%s' '{"fields":{"assignee":{"accountId":"acc-x","displayName":"Someone Else"}}}' ;;
    */issue/ABC-*/assignee) printf '%s' "$data" > "$JA_PUT"; printf '%s' "$JA_STATUS" ;;
  esac
}
STUB
  export JA_PUT="$fx/put.json" JA_STATUS=204
  ja() { "$fx/jira-assign.sh" "$@"; }
  # shellcheck source=tap.sh
  . "$HELPER_DIR/tap.sh"

  out=$(ja --dry-run ABC-1 me)
  tap_is "a dry run names the v2 assignee endpoint" \
    "$(sed -n 1p <<<"$out")" "PUT /rest/api/2/issue/ABC-1/assignee"
  tap_is "'me' resolves to the token's account" \
    "$(sed 1d <<<"$out" | jq -r .accountId)" acc-me
  tap_run "a dry run assigns nothing" test ! -e "$JA_PUT"

  tap_is "an assignment prints who" "$(ja ABC-1 me)" "ABC-1: assigned to Me Myself"
  tap_is "the PUT body is the one the dry run shows" \
    "$(jq -r .accountId < "$JA_PUT")" acc-me
  rm -f "$JA_PUT"

  tap_is "--if-unassigned keeps an assignee" \
    "$(ja --if-unassigned ABC-2 me)" "ABC-2: kept, assigned to Someone Else"
  tap_run "--if-unassigned does not reassign an assigned issue" test ! -e "$JA_PUT"
  tap_is "--if-unassigned assigns an unassigned issue" \
    "$(ja --if-unassigned ABC-1 me)" "ABC-1: assigned to Me Myself"

  tap_is "an account id is sent as given" \
    "$(ja --dry-run ABC-1 acc-9 | sed 1d | jq -r .accountId)" acc-9

  for bad in "abc-1 me" "ABC-1" ""; do
    read -ra args <<<"$bad"
    st=0; ja --dry-run "${args[@]}" >/dev/null 2>&1 || st=$?
    tap_is "a usage error exits 2: '$bad'" "$st" 2
  done
  st=0; JA_STATUS=400 ja ABC-1 me >/dev/null 2>&1 || st=$?
  tap_is "an HTTP 400 exits 1" "$st" 1
  tap_end
fi

usage() { echo "$1" >&2; echo "Usage: $0 [--dry-run] [--if-unassigned] <KEY> <me|accountId>" >&2; exit 2; }

DRY_RUN=0 IF_UNASSIGNED=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --if-unassigned) IF_UNASSIGNED=1; shift ;;
    *)               usage "Unknown option: $1" ;;
  esac
done
KEY="${1:-}" WHO="${2:-}"
[[ "$KEY" =~ $KEY_RE ]] || usage "Not an issue key: ${KEY:-<none>}"
[[ -n "$WHO" ]] || usage "Name the assignee: me or an account id."

# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
ENDPOINT="/rest/api/2/issue/${KEY}/assignee"

if [[ "$IF_UNASSIGNED" -eq 1 ]]; then
  HOLDER=$(atlassian_curl -f "${ATLASSIAN_SITE}/rest/api/2/issue/${KEY}?fields=assignee" \
    | jq -r '.fields.assignee.displayName // empty') \
    || { echo "Cannot read the assignee of $KEY" >&2; exit 1; }
  if [[ -n "$HOLDER" ]]; then echo "$KEY: kept, assigned to $HOLDER"; exit 0; fi
fi

if [[ "$WHO" == me ]]; then
  MYSELF=$(atlassian_curl -f "${ATLASSIAN_SITE}/rest/api/2/myself") \
    || { echo "Cannot read the token's own account" >&2; exit 1; }
  ACCOUNT=$(jq -r .accountId <<<"$MYSELF") NAME=$(jq -r .displayName <<<"$MYSELF")
else
  ACCOUNT="$WHO" NAME="$WHO"
fi

PAYLOAD=$(jq -n --arg a "$ACCOUNT" '{accountId: $a}')

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "PUT $ENDPOINT"
  jq '.' <<<"$PAYLOAD"
  exit 0
fi

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(atlassian_curl -o "$RESP_FILE" -w "%{http_code}" \
  -X PUT -H "Content-Type: application/json" \
  --data "$PAYLOAD" "${ATLASSIAN_SITE}${ENDPOINT}")

if [[ "$HTTP_CODE" != "204" ]]; then
  echo "HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  exit 1
fi
echo "$KEY: assigned to $NAME"
