#!/usr/bin/env bash
# Move a Jira issue to another status, via REST v2.
#
# A workflow moves an issue by transition, not by status: each transition has
# an id and leads to one status, and which ones an issue offers depends on the
# status it is in. The script reads the issue's transitions on every call and
# takes the one whose target status, or whose own name, is the one asked for,
# ignoring case. So a caller names where the issue should end up ("Done") and
# never handles a transition id.
#
# --list prints the transitions the issue offers now, one per line:
# "<transition name> -> <target status>".
#
# Usage:
#   jira-transition.sh [--dry-run] <KEY> <status...>
#   jira-transition.sh --list <KEY>
#   jira-transition.sh --self-test
#
# Examples:
#   jira-transition.sh ABC-7725 Done
#   jira-transition.sh ABC-10905 in progress
#   jira-transition.sh --list ABC-10905
#
# Prints "<KEY>: <from> -> <to>". --dry-run prints the request instead and
# changes nothing. Exit 0 on HTTP 204; 2 on a usage error, or a status no
# single transition leads to (the ones on offer are named); 1 otherwise, with
# the HTTP status and response on stderr. Fields a transition screen requires
# are not set: Jira's refusal is printed as it states them.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_RE='^[A-Z][A-Z0-9]+-[0-9]+$'

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  cp "${HELPER_DIR}/jira-transition.sh" "$fx/jira-transition.sh"
  cat > "$fx/atlassian-auth.sh" <<'STUB'
# Stub transport. Answers the issue and transition reads from fixtures,
# records what would be POSTed, and never opens a socket.
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local url="${!#}" data="" prev="" a
  for a in "$@"; do [[ "$prev" == "--data" ]] && data="$a"; prev="$a"; done
  case "$url" in
    */issue/ABC-1\?fields=status) printf '%s' '{"fields":{"status":{"name":"Backlog"}}}' ;;
    */issue/ABC-1/transitions)
      if [[ -n "$data" ]]; then printf '%s' "$data" > "$JT_POSTED"; printf '%s' "$JT_STATUS"
      else printf '%s' '{"transitions":[
        {"id":"11","name":"Start","to":{"name":"In Progress"}},
        {"id":"31","name":"Close","to":{"name":"Done"}},
        {"id":"41","name":"Not Doing","to":{"name":"Done"}},
        {"id":"51","name":"Block","to":{"name":"Blocked"}}]}'; fi ;;
  esac
}
STUB
  export JT_POSTED="$fx/posted.json" JT_STATUS=204
  jt() { "$fx/jira-transition.sh" "$@"; }
  fail() { echo "self-test: $1" >&2; exit 1; }

  out=$(jt --dry-run ABC-1 in progress)
  [[ "$(sed -n 1p <<<"$out")" == "POST /rest/api/2/issue/ABC-1/transitions" ]] \
    || fail "a dry run does not name the v2 transitions endpoint"
  [[ "$(sed 1d <<<"$out" | jq -r .transition.id)" == 11 ]] \
    || fail "a target status, any case, does not pick its transition"
  [[ "$(jt --dry-run ABC-1 Close | sed 1d | jq -r .transition.id)" == 31 ]] \
    || fail "a transition's own name does not pick it"
  [[ "$(jt --dry-run ABC-1 'not doing' | sed 1d | jq -r .transition.id)" == 41 ]] \
    || fail "a transition name shared with no status is not matched"
  [[ ! -e "$JT_POSTED" ]] || fail "a dry run posted"

  [[ "$(jt ABC-1 blocked)" == "ABC-1: Backlog -> Blocked" ]] \
    || fail "a transition does not print the move"
  [[ "$(jq -r .transition.id < "$JT_POSTED")" == 51 ]] \
    || fail "the posted body is not the one the dry run shows"

  [[ "$(jt --list ABC-1 | sed -n 2p)" == "Close -> Done" ]] \
    || fail "--list does not print name -> target"

  for bad in "ABC-1 Done" "ABC-1 Testing" "abc-1 Blocked" "ABC-1"; do
    st=0; jt --dry-run $bad >/dev/null 2>&1 || st=$?
    [[ "$st" == 2 ]] || fail "'$bad' exited $st, not 2"
  done
  st=0; JT_STATUS=400 jt ABC-1 Blocked >/dev/null 2>&1 || st=$?
  [[ "$st" == 1 ]] || fail "an HTTP 400 exited $st, not 1"

  echo "jira-transition self-test: PASS"
  exit 0
fi

usage() { echo "$1" >&2; echo "Usage: $0 [--dry-run] <KEY> <status...> | --list <KEY>" >&2; exit 2; }

DRY_RUN=0 LIST=0
case "${1:-}" in --dry-run) DRY_RUN=1; shift ;; --list) LIST=1; shift ;; esac
KEY="${1:-}"
[[ "$KEY" =~ $KEY_RE ]] || usage "Not an issue key: ${KEY:-<none>}"
shift
WANT="$*"
[[ "$LIST" -eq 1 || -n "$WANT" ]] || usage "Name the status to move $KEY to."

# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
ENDPOINT="/rest/api/2/issue/${KEY}/transitions"

OFFERED=$(atlassian_curl -f "${ATLASSIAN_SITE}${ENDPOINT}") \
  || { echo "Cannot read the transitions of $KEY" >&2; exit 1; }

if [[ "$LIST" -eq 1 ]]; then
  jq -r '.transitions[] | "\(.name) -> \(.to.name)"' <<<"$OFFERED"
  exit 0
fi

# A transition's own name is matched first, so two transitions leading to one
# status stay reachable by name; a status is matched only when no name is.
MATCHES=$(jq -r --arg w "$WANT" '
  ($w | ascii_downcase) as $w
  | [.transitions[] | select((.name | ascii_downcase) == $w)] as $by_name
  | (if ($by_name | length) > 0 then $by_name
     else [.transitions[] | select((.to.name | ascii_downcase) == $w)] end)[]
  | [.id, .to.name] | @tsv' <<<"$OFFERED")

case "$(grep -c . <<<"$MATCHES" || true)" in
  1) IFS=$'\t' read -r ID TO <<<"$MATCHES" ;;
  0) usage "$KEY offers no transition to '$WANT'. On offer: $(jq -r '[.transitions[] | "\(.name) -> \(.to.name)"] | join("; ")' <<<"$OFFERED")" ;;
  *) usage "'$WANT' is reached by more than one transition; name one: $(jq -r --arg w "$WANT" '[.transitions[] | select((.to.name | ascii_downcase) == ($w | ascii_downcase)) | .name] | join(", ")' <<<"$OFFERED")" ;;
esac

PAYLOAD=$(jq -n --arg id "$ID" '{transition: {id: $id}}')

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "POST $ENDPOINT"
  jq '.' <<<"$PAYLOAD"
  exit 0
fi

FROM=$(atlassian_curl -f "${ATLASSIAN_SITE}/rest/api/2/issue/${KEY}?fields=status" | jq -r '.fields.status.name') \
  || { echo "Cannot read the status of $KEY" >&2; exit 1; }

RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(atlassian_curl -o "$RESP_FILE" -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  --data "$PAYLOAD" "${ATLASSIAN_SITE}${ENDPOINT}")

if [[ "$HTTP_CODE" != "204" ]]; then
  echo "HTTP $HTTP_CODE" >&2
  cat "$RESP_FILE" >&2
  exit 1
fi
echo "$KEY: $FROM -> $TO"
