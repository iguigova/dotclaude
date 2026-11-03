#!/usr/bin/env bash
# Search Confluence with CQL and print the matches as one JSON array.
#
# Usage:
#   confluence-search.sh [--limit <n>] '<cql>'
#   confluence-search.sh --self-test   # pages over a stubbed API, no network
#
# Examples:
#   confluence-search.sh 'label = "engdocs-serverless-topic"'
#   confluence-search.sh --limit 50 'space = PA and title ~ "LPR"'
#
# Output: [{id, type, title, space, url}], in the order Confluence ranks them.
# --limit caps the total returned (default 100). The search pages by the
# opaque cursor Confluence puts in `_links.next`, followed until it is absent
# or the limit is reached; a `start` offset is not used, because the API
# ignores it once a cursor is in play.
#
# A query Confluence cannot parse answers HTTP 400; the script prints
# Confluence's message on stderr and exits 1, so an empty array always means
# the query ran and matched nothing.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# The paging is the contract, so the test runs this script against a stubbed
# atlassian_curl: three results over two pages, a limit that stops inside the
# second page, and a query the stub answers with 400.
if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  cp "$0" "$fx/confluence-search.sh"
  cat > "$fx/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local out="" url="" a
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      -w|--data-urlencode) [[ "$2" == cql=bad* ]] && url=bad; shift 2 ;;
      -G) shift ;;
      *) [[ -z "$url" ]] && url="$1"; shift ;;
    esac
  done
  local r='{"_links":{"base":"https://example.invalid/wiki"}'
  case "$url" in
    bad) printf '%s' '{"statusCode":400,"message":"Could not parse cql"}' > "$out"; echo 400; return ;;
    *cursor=two*) r+=',"results":[{"id":"3","type":"page","title":"c","space":{"key":"PA"},"_links":{"webui":"/p/3"}}]}' ;;
    *) r+=',"results":[{"id":"1","type":"page","title":"a\tb","space":{"key":"PA"},"_links":{"webui":"/p/1"}},{"id":"2","type":"blogpost","title":"b","space":{"key":"W2"},"_links":{"webui":"/p/2"}}]}'
       r=$(jq -c '._links.next = "/rest/api/content/search?cursor=two"' <<<"$r") ;;
  esac
  printf '%s' "$r" > "$out"; echo 200
}
STUB
  self="$fx/confluence-search.sh"
  all=$("$self" 'type = page' | jq -c 'map([.id, .type, .title, .space, .url])')
  capped=$("$self" --limit 2 'type = page' | jq -c 'map(.id)')
  if "$self" 'bad query' >/dev/null 2>"$fx/err"; then bad=accepted; else bad=$(cat "$fx/err"); fi
  want_all='[["1","page","a\tb","PA","https://example.invalid/wiki/p/1"],["2","blogpost","b","W2","https://example.invalid/wiki/p/2"],["3","page","c","PA","https://example.invalid/wiki/p/3"]]'
  want_capped='["1","2"]'
  # shellcheck source=tap.sh
  . "$(dirname "$0")/tap.sh"
  tap_is "the cursor is followed across pages" "$all" "$want_all"
  tap_is "--limit stops early" "$capped" "$want_capped"
  tap_like "a 400 exits 1 with Confluence's message" "$bad" "*Could not parse cql*"
  tap_end
fi

LIMIT=100
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done
[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || { echo "--limit must be a positive integer" >&2; exit 2; }
if [[ $# -ne 1 || -z "$1" ]]; then
  echo "Usage: $0 [--limit <n>] '<cql>'" >&2
  exit 1
fi
CQL="$1"

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

RESP=$(mktemp); MATCHES=$(mktemp)
trap 'rm -f "$RESP" "$MATCHES"' EXIT

# Each page's matches are appended as lines and assembled once at the end.
fetch() {
  local code
  code=$(atlassian_curl -o "$RESP" -w '%{http_code}' "$@")
  if [[ "$code" != "200" ]]; then
    echo "HTTP $code: $(jq -r '.message // empty' "$RESP" 2>/dev/null || cat "$RESP")" >&2
    exit 1
  fi
}

PAGE_SIZE=$(( LIMIT < 100 ? LIMIT : 100 ))
fetch -G "${ATLASSIAN_SITE}/wiki/rest/api/content/search" \
  --data-urlencode "cql=${CQL}" --data-urlencode "limit=${PAGE_SIZE}" \
  --data-urlencode "expand=space"
while :; do
  jq -c '._links.base as $base | .results[]
         | {id, type, title, space: .space.key, url: ($base + ._links.webui)}' \
    "$RESP" >> "$MATCHES"
  next=$(jq -r '._links.next // empty' "$RESP")
  [[ -n "$next" && $(wc -l < "$MATCHES") -lt "$LIMIT" ]] || break
  fetch "${ATLASSIAN_SITE}/wiki${next}&expand=space"
done

head -n "$LIMIT" "$MATCHES" | jq -s '.'
