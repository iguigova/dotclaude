#!/usr/bin/env bash
# Read or write one web link on a Jira issue (a "remote link"), via REST v2.
#
# A remote link is a URL the issue lists under its links. Its global id is
# the caller's name for it: Jira keeps one link per issue and global id, so
# set replaces the link it names instead of adding a second.
#
# Usage:
#   jira-remote-link.sh get <KEY> <GLOBAL_ID>
#   jira-remote-link.sh set [--dry-run] <KEY> <GLOBAL_ID> <URL> <TITLE>
#   jira-remote-link.sh --self-test
#
# get prints the link's URL; exit 3 when the issue has no link of that id.
# set prints the URL it wrote; --dry-run prints the request and sends
# nothing. Exit 0 on success, 2 on a usage error, 1 on any other HTTP
# answer, with the status and response on stderr.
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_RE='^[A-Z][A-Z0-9]+-[0-9]+$'

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  cp "${HELPER_DIR}/jira-remote-link.sh" "$fx/jira-remote-link.sh"
  cat > "$fx/atlassian-auth.sh" <<'STUB'
# Stub transport: one stored link per run, in $RL_STORE; never opens a socket.
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local url="${!#}" data="" prev="" out="" a
  for a in "$@"; do
    [[ "$prev" == "--data" ]] && data="$a"
    [[ "$prev" == "-o" ]] && out="$a"
    prev="$a"
  done
  printf '%s\n' "$url" >> "$RL_LOG"
  if [[ -n "$data" ]]; then
    printf '%s' "$data" > "$RL_STORE"; printf '%s' "$RL_STATUS"; return
  fi
  if [[ -s "$RL_STORE" && "$url" == *"globalId=$(jq -r .globalId "$RL_STORE")" ]]; then
    printf '%s' "$(cat "$RL_STORE")" > "$out"; printf 200
  else
    printf '%s' '{"errorMessages":["The remote link does not exist."]}' > "$out"; printf 404
  fi
}
STUB
  export RL_STORE="$fx/store.json" RL_LOG="$fx/log" RL_STATUS=201
  : > "$RL_STORE"
  rl() { "$fx/jira-remote-link.sh" "$@"; }
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"

  st=0; rl get ABC-1 thread >/dev/null 2>&1 || st=$?
  tap_is "get of a link the issue lacks exits 3" "$st" 3
  out=$(rl set --dry-run ABC-1 thread https://x.invalid/p1 'Review thread')
  tap_is "a dry run names the v2 remotelink endpoint" "$(sed -n 1p <<<"$out")" \
    "POST /rest/api/2/issue/ABC-1/remotelink"
  tap_is "a dry run sends the global id, the URL and the title" \
    "$(sed 1d <<<"$out" | jq -c '[.globalId, .object.url, .object.title]')" \
    '["thread","https://x.invalid/p1","Review thread"]'
  tap_run "a dry run writes nothing" test ! -s "$RL_STORE"
  tap_is "set prints the URL it wrote" "$(rl set ABC-1 thread https://x.invalid/p1 'Review thread')" \
    https://x.invalid/p1
  tap_is "get prints the URL set wrote" "$(rl get ABC-1 thread)" https://x.invalid/p1
  tap_run "get asks for the link by its global id" grep -q 'remotelink?globalId=thread$' "$RL_LOG"
  RL_STATUS=200 rl set ABC-1 thread https://x.invalid/p2 'Review thread' >/dev/null
  tap_is "a second set replaces the link Jira answers 200 for" "$(rl get ABC-1 thread)" https://x.invalid/p2
  st=0; RL_STATUS=403 rl set ABC-1 thread https://x.invalid/p3 t >/dev/null 2>&1 || st=$?
  tap_is "a refused write exits 1" "$st" 1
  for bad in "" "get abc-1 thread" "get ABC-1" "set ABC-1 thread https://x.invalid" "put ABC-1 thread"; do
    read -ra args <<<"$bad"; st=0; rl "${args[@]}" >/dev/null 2>&1 || st=$?
    tap_is "a usage error exits 2: '$bad'" "$st" 2
  done
  tap_end
fi

usage() { echo "$1" >&2; echo "Usage: $0 get <KEY> <GLOBAL_ID> | set [--dry-run] <KEY> <GLOBAL_ID> <URL> <TITLE>" >&2; exit 2; }
CMD="${1:-}"; shift $(( $# > 0 ))
DRY_RUN=0
[[ "${1:-}" == --dry-run ]] && { DRY_RUN=1; shift; }
case "$CMD" in
  get) [[ $# -eq 2 ]] || usage "get takes a key and a global id." ;;
  set) [[ $# -eq 4 ]] || usage "set takes a key, a global id, a URL and a title." ;;
  *) usage "Unknown command: $CMD" ;;
esac
KEY="$1" GID="$2"
[[ "$KEY" =~ $KEY_RE ]] || usage "Not an issue key: $KEY"
ENDPOINT="/rest/api/2/issue/${KEY}/remotelink"

# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

if [[ "$CMD" == get ]]; then
  HTTP_CODE=$(atlassian_curl -o "$RESP_FILE" -w "%{http_code}" \
    "${ATLASSIAN_SITE}${ENDPOINT}?globalId=$(jq -rn --arg g "$GID" '$g | @uri')")
  case "$HTTP_CODE" in
    200) jq -r '.object.url' "$RESP_FILE"; exit 0 ;;
    404) exit 3 ;;
    *) echo "HTTP $HTTP_CODE" >&2; cat "$RESP_FILE" >&2; exit 1 ;;
  esac
fi

URL="$3" TITLE="$4"
PAYLOAD=$(jq -n --arg g "$GID" --arg u "$URL" --arg t "$TITLE" \
  '{globalId: $g, object: {url: $u, title: $t}}')
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "POST $ENDPOINT"
  jq '.' <<<"$PAYLOAD"
  exit 0
fi
HTTP_CODE=$(atlassian_curl -o "$RESP_FILE" -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  --data "$PAYLOAD" "${ATLASSIAN_SITE}${ENDPOINT}")
case "$HTTP_CODE" in
  200|201) echo "$URL" ;;
  *) echo "HTTP $HTTP_CODE" >&2; cat "$RESP_FILE" >&2; exit 1 ;;
esac
