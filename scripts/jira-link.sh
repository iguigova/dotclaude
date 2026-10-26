#!/usr/bin/env bash
# Link two Jira issues, via REST v2.
#
# The link reads as a sentence: a key, a phrase, a key. The phrase is a link
# type's outward or inward description, or its name, which reads as the
# outward one. The types are the site's own, read from
# /rest/api/2/issueLinkType on every call, and matched ignoring case.
#
# Jira stores "A blocks B" as inwardIssue A and outwardIssue B. The script maps
# the sentence onto that shape, so no caller handles the two fields.
#
# --delete removes the link the same sentence names. It reads the inward
# issue's links, finds the one of that type to the outward issue, and deletes
# it by id.
#
# Usage:
#   jira-link.sh [--dry-run] [--delete] <KEY> <phrase...> <KEY>
#   jira-link.sh --self-test
#
# Examples:
#   jira-link.sh ABC-7489 relates to ABC-10968
#   jira-link.sh ABC-10970 is blocked by ABC-10968
#   jira-link.sh ABC-10970 Blocks ABC-10971
#   jira-link.sh --delete ABC-10974 relates to ABC-10877
#
# Prints the link as Jira shows it from the inward issue, e.g.
# "ABC-10968 blocks ABC-10970"; a delete prints it after "deleted: ".
# --dry-run prints the request instead and changes nothing. Exit 0 on HTTP 201
# (204 for a delete); 2 on a usage error or a phrase that names no single link
# type; 1 when a delete finds no such link, or otherwise, with the HTTP status
# and response on stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_RE='^[A-Z][A-Z0-9]+-[0-9]+$'
ENDPOINT=/rest/api/2/issueLink

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  cp "${HELPER_DIR}/jira-link.sh" "$fx/jira-link.sh"
  cat > "$fx/atlassian-auth.sh" <<'STUB'
# Stub transport. Answers the link-type read from a fixture, records what
# would be POSTed, and never opens a socket.
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local url="${!#}" data="" prev="" a
  for a in "$@"; do [[ "$prev" == "--data" ]] && data="$a"; prev="$a"; done
  case "$url" in
    */issueLinkType) printf '%s' '{"issueLinkTypes":[
      {"name":"Blocks","inward":"is blocked by","outward":"blocks"},
      {"name":"Relates","inward":"relates to","outward":"relates to"},
      {"name":"Twin A","inward":"pairs with","outward":"twins"},
      {"name":"Twin B","inward":"pairs with","outward":"mirrors"}]}' ;;
    */issueLink) printf '%s' "$data" > "$JL_POSTED"; printf '%s' "$JL_STATUS" ;;
    */issueLink/*) printf '%s' "${url##*/}" > "$JL_DELETED"; printf '%s' "$JL_DEL_STATUS" ;;
    */issue/ABC-2\?fields=issuelinks) printf '%s' '{"fields":{"issuelinks":[
      {"id":"901","type":{"name":"Relates"},"outwardIssue":{"key":"ABC-3"}},
      {"id":"902","type":{"name":"Blocks"},"outwardIssue":{"key":"ABC-1"}},
      {"id":"903","type":{"name":"Blocks"},"inwardIssue":{"key":"ABC-1"}}]}}' ;;
  esac
}
STUB
  export JL_POSTED="$fx/posted.json" JL_STATUS=201
  jl() { "$fx/jira-link.sh" "$@"; }
  fail() { echo "self-test: $1" >&2; exit 1; }
  sides() { jq -r '[.inwardIssue.key, .outwardIssue.key, .type.name] | join(" ")'; }

  out=$(jl --dry-run ABC-1 blocks ABC-2)
  [[ "$(sed -n 1p <<<"$out")" == "POST $ENDPOINT" ]] \
    || fail "a dry run does not name the v2 issueLink endpoint"
  [[ "$(sed 1d <<<"$out" | sides)" == "ABC-1 ABC-2 Blocks" ]] \
    || fail "an outward phrase does not make the first key the inward issue"
  [[ "$(jl --dry-run ABC-1 is blocked by ABC-2 | sed 1d | sides)" == "ABC-2 ABC-1 Blocks" ]] \
    || fail "an inward phrase does not swap the two keys"
  [[ "$(jl --dry-run ABC-1 'IS BLOCKED BY' ABC-2 | sed 1d | sides)" == "ABC-2 ABC-1 Blocks" ]] \
    || fail "a quoted, upper-case phrase is not matched"
  [[ "$(jl --dry-run ABC-1 Relates ABC-2 | sed 1d | sides)" == "ABC-1 ABC-2 Relates" ]] \
    || fail "a type name does not read as its outward phrase"
  [[ ! -e "$JL_POSTED" ]] || fail "a dry run posted"

  [[ "$(jl ABC-1 is blocked by ABC-2)" == "ABC-2 blocks ABC-1" ]] \
    || fail "a post does not print the link as Jira shows it"
  [[ "$(sides < "$JL_POSTED")" == "ABC-2 ABC-1 Blocks" ]] \
    || fail "the posted body is not the one the dry run shows"

  for bad in "ABC-1 duplicates ABC-2" "ABC-1 pairs with ABC-2" "abc-1 blocks ABC-2" \
             "ABC-1 blocks ABC-1" "ABC-1 ABC-2" "ABC-1 blocks"; do
    st=0; jl --dry-run $bad >/dev/null 2>&1 || st=$?
    [[ "$st" == 2 ]] || fail "'$bad' exited $st, not 2"
  done
  st=0; JL_STATUS=404 jl ABC-1 blocks ABC-2 >/dev/null 2>&1 || st=$?
  [[ "$st" == 1 ]] || fail "an HTTP 404 exited $st, not 1"

  export JL_DELETED="$fx/deleted" JL_DEL_STATUS=204
  [[ "$(jl --dry-run --delete ABC-1 is blocked by ABC-2)" == "DELETE $ENDPOINT/902" ]] \
    || fail "a delete dry run does not name the link id from the inward issue"
  [[ ! -e "$JL_DELETED" ]] || fail "a delete dry run deleted"
  [[ "$(jl --delete ABC-1 is blocked by ABC-2)" == "deleted: ABC-2 blocks ABC-1" ]] \
    || fail "a delete does not print the link it removed"
  [[ "$(cat "$JL_DELETED")" == 902 ]] || fail "a delete removed the wrong link"
  st=0; jl --delete ABC-3 blocks ABC-2 >/dev/null 2>&1 || st=$?
  [[ "$st" == 1 ]] || fail "a delete of an absent link exited $st, not 1"
  st=0; JL_DEL_STATUS=404 jl --delete ABC-1 is blocked by ABC-2 >/dev/null 2>&1 || st=$?
  [[ "$st" == 1 ]] || fail "a delete answered HTTP 404 exited $st, not 1"

  echo "jira-link self-test: PASS"
  exit 0
fi

DRY_RUN=0 DELETE=0
while [[ "${1:-}" == --dry-run || "${1:-}" == --delete ]]; do
  [[ "$1" == --dry-run ]] && DRY_RUN=1 || DELETE=1
  shift
done

usage() { echo "$1" >&2; echo "Usage: $0 [--dry-run] [--delete] <KEY> <phrase...> <KEY>" >&2; exit 2; }
[[ $# -ge 3 ]] || usage "Need a key, a phrase and a key."
FROM="$1"; TO="${!#}"
PHRASE="${*:2:$#-2}"
[[ "$FROM" =~ $KEY_RE && "$TO" =~ $KEY_RE ]] || usage "Not an issue key: $FROM or $TO"
[[ "$FROM" != "$TO" ]] || usage "An issue cannot be linked to itself: $FROM"

# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

TYPES=$(atlassian_curl -f "${ATLASSIAN_SITE}/rest/api/2/issueLinkType") \
  || { echo "Cannot read the link types" >&2; exit 1; }

# One row per type the phrase names: name, outward phrase, and which side of
# the sentence the first key is on.
MATCHES=$(jq -r --arg p "$PHRASE" '
  ($p | ascii_downcase) as $p
  | .issueLinkTypes[]
  | if (.outward | ascii_downcase) == $p or (.name | ascii_downcase) == $p
      then [.name, .outward, "outward"]
    elif (.inward | ascii_downcase) == $p
      then [.name, .outward, "inward"]
    else empty end
  | @tsv' <<<"$TYPES")

case "$(grep -c . <<<"$MATCHES" || true)" in
  1) IFS=$'\t' read -r TYPE OUTWARD SIDE <<<"$MATCHES" ;;
  0) usage "No link type reads '$PHRASE'. Phrases: $(jq -r '[.issueLinkTypes[] | .outward, .inward] | unique | join(", ")' <<<"$TYPES")" ;;
  *) usage "'$PHRASE' names more than one link type: $(cut -f1 <<<"$MATCHES" | paste -sd, -)" ;;
esac

if [[ "$SIDE" == outward ]]; then INWARD="$FROM" OUTWARD_KEY="$TO"
else INWARD="$TO" OUTWARD_KEY="$FROM"; fi

if [[ "$DELETE" -eq 1 ]]; then
  # On the inward issue, the link carries the other side as outwardIssue.
  LINK_ID=$(atlassian_curl -f "${ATLASSIAN_SITE}/rest/api/2/issue/${INWARD}?fields=issuelinks" \
    | jq -r --arg t "$TYPE" --arg o "$OUTWARD_KEY" \
      'first(.fields.issuelinks[] | select(.type.name == $t and .outwardIssue.key == $o) | .id) // empty') \
    || { echo "Cannot read the links of $INWARD" >&2; exit 1; }
  [[ -n "$LINK_ID" ]] || { echo "No link: $INWARD $OUTWARD $OUTWARD_KEY" >&2; exit 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "DELETE $ENDPOINT/$LINK_ID"; exit 0; fi
  RESP_FILE=$(mktemp)
  trap 'rm -f "$RESP_FILE"' EXIT
  HTTP_CODE=$(atlassian_curl -o "$RESP_FILE" -w "%{http_code}" \
    -X DELETE "${ATLASSIAN_SITE}${ENDPOINT}/${LINK_ID}")
  if [[ "$HTTP_CODE" != "204" ]]; then
    echo "HTTP $HTTP_CODE" >&2
    cat "$RESP_FILE" >&2
    exit 1
  fi
  echo "deleted: $INWARD $OUTWARD $OUTWARD_KEY"
  exit 0
fi

PAYLOAD=$(jq -n --arg t "$TYPE" --arg i "$INWARD" --arg o "$OUTWARD_KEY" \
  '{type: {name: $t}, inwardIssue: {key: $i}, outwardIssue: {key: $o}}')

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "POST $ENDPOINT"
  jq '.' <<<"$PAYLOAD"
  exit 0
fi

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(atlassian_curl -o "$RESP_FILE" -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  --data "$PAYLOAD" "${ATLASSIAN_SITE}${ENDPOINT}")

if [[ "$HTTP_CODE" != "201" ]]; then
  echo "HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  exit 1
fi
echo "$INWARD $OUTWARD $OUTWARD_KEY"
