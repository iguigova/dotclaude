#!/usr/bin/env bash
# Write a page fetched by `confluence-page.sh --to` back to Confluence.
#
# Usage:
#   confluence-safe-update.sh --from <dir>/<id>.storage.html [--title "<new title>"]
#   confluence-safe-update.sh --self-test    # offline
#
# Example:
#   f=$(confluence-page.sh 2415788040 --to "$SCRATCH")
#   # …edit "$f"…
#   confluence-safe-update.sh --from "$f"
#
# The file is the whole Confluence STORAGE body (XHTML-ish): a PUT replaces the
# page, so whatever the file holds is the page afterwards. The page id is the
# file's name, and the version is the one `--to` recorded in <id>.version beside
# it. Sending one more than that version is what makes the write safe: an edit
# landing on the page since the fetch has already taken that number, so the
# write is refused, never laid over it. After a write <id>.version holds the new
# version, so the file can be edited and written again without a refetch.
#
# A body that is not well-formed is refused before anything is sent, by the
# check `confluence-create.sh` and `confluence-comment.sh` run.
#
# Mismatch is caught twice on purpose: against the fetched version, which names
# both numbers and costs nothing, and by the server, which is the only check that
# closes the race.
#
# Exits: 0 update applied · 1 fetch or request failed · 2 usage, or a file
#        `--to` did not write · 4 the page moved on (local check or 409)
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac


# The page id and the version recorded beside a fetched body, as "ID VERSION",
# or a message on stderr and 2.
csu_source() {  # BODY_FILE
  local file="$1" name id ver_file ver
  name=$(basename "$file")
  [[ "$name" =~ ^([0-9]+)\.storage\.html$ ]] || {
    echo "confluence-safe-update: $file is not <id>.storage.html — fetch it with confluence-page.sh --to" >&2
    return 2; }
  id="${BASH_REMATCH[1]}"
  ver_file="${file%.storage.html}.version"
  ver=$(cat "$ver_file" 2>/dev/null) || ver=""
  [[ -f "$file" && "$ver" =~ ^[0-9]+$ ]] || {
    echo "confluence-safe-update: no body or no version beside it at $file — fetch it with confluence-page.sh --to" >&2
    return 2; }
  echo "$id $ver"
}

# The version to send, or a message on stderr and 4. Sole owner of the rule, so
# the self-test exercises what the live path runs rather than a copy of it.
csu_next_version() {  # FETCHED CURRENT
  local fetched="$1" current="$2"
  if [[ "$fetched" != "$current" ]]; then
    echo "confluence-safe-update: page is at v${current}, the file was fetched at v${fetched} — refetch and reapply" >&2
    return 4
  fi
  echo $(( fetched + 1 ))
}

csu_payload() {  # TITLE SPACE BODY_FILE VERSION
  jq -n --arg title "$1" --arg space "$2" --rawfile body "$3" --argjson ver "$4" \
    '{ version: { number: $ver }, title: $title, type: "page",
       space: { key: $space },
       body: { storage: { value: $body, representation: "storage" } } }'
}

csu_self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local got st
  check() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }

  local fx; fx=$(mktemp -d)
  printf '<p>x</p>' > "$fx/42.storage.html"; printf '7\n' > "$fx/42.version"
  check "a fetched body names its page and version" "42 7" "$(csu_source "$fx/42.storage.html")"
  cp "$fx/42.storage.html" "$fx/page.html"
  got=$(csu_source "$fx/page.html" 2>/dev/null) && st=0 || st=$?
  check "a body not named <id>.storage.html is refused" '2/' "$st/$got"
  printf '<p>y</p>' > "$fx/43.storage.html"
  got=$(csu_source "$fx/43.storage.html" 2>/dev/null) && st=0 || st=$?
  check "a body with no version beside it is refused" '2/' "$st/$got"
  printf 'v7\n' > "$fx/43.version"
  got=$(csu_source "$fx/43.storage.html" 2>/dev/null) && st=0 || st=$?
  check "a version that is not a number is refused" '2/' "$st/$got"
  got=$(csu_source "$fx/44.storage.html" 2>/dev/null) && st=0 || st=$?
  check "a body that does not exist is refused" '2/' "$st/$got"
  rm -rf "$fx"

  check "the fetched version, still current, sends the next" 8 "$(csu_next_version 7 7)"

  # The case the version file exists for: someone else's edit has already taken v8.
  got=$(csu_next_version 7 8 2>/dev/null) && st=0 || st=$?
  check "a page that moved on is refused, not overwritten" '4/' "$st/$got"

  # Guarding only the low side would still clobber a page rolled back by hand.
  got=$(csu_next_version 9 8 2>/dev/null) && st=0 || st=$?
  check "an expectation ahead of the page is refused too" '4/' "$st/$got"

  local body payload
  body=$(mktemp)
  printf '<p>a & b</p>' > "$body"
  payload=$(csu_payload "T" "SP" "$body" 8)
  check "the body is carried verbatim, unescaped by the shell" '<p>a & b</p>' \
    "$(jq -r '.body.storage.value' <<<"$payload")"
  check "the version is a number, not a string" 'number' \
    "$(jq -r '.version.number | type' <<<"$payload")"

  # The whole script, over a stubbed page read and a curl that records the PUT and
  # answers with $STUB_CODE: what is sent, and what the version file holds after.
  local run self sent
  run=$(mktemp -d); trap 'rm -f "$body"; rm -rf "$run"' RETURN
  mkdir "$run/h" "$run/bin" "$run/page"
  cp "$0" "$run/h/confluence-safe-update.sh"
  cp "$(dirname "$0")/storage-well-formed.sh" "$run/h/"
  cat > "$run/h/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid JIRA_USER=u JIRA_TOKEN=t
atlassian_curl() { printf '{"version":{"number":%s},"space":{"key":"SP"},"title":"T"}' "$STUB_AT"; }
STUB
  cat > "$run/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out="$2"; shift 2 ;; -d) cp "${2#@}" "$STUB_SENT"; shift 2 ;; *) shift ;; esac
done
echo '{}' > "$out"; printf '%s' "$STUB_CODE"
STUB
  chmod +x "$run/bin/curl"
  self="$run/h/confluence-safe-update.sh" sent="$run/sent"
  printf '<p>new</p>' > "$run/page/42.storage.html"
  live() {  # AT CODE → "exit/version file/what was sent"
    rm -f "$sent"; printf '7\n' > "$run/page/42.version"
    local st=0
    STUB_AT="$1" STUB_CODE="$2" STUB_SENT="$sent" PATH="$run/bin:$PATH" \
      bash "$self" --from "$run/page/42.storage.html" >/dev/null 2>&1 || st=$?
    printf '%s/%s/%s' "$st" "$(cat "$run/page/42.version")" \
      "$( [[ -f "$sent" ]] && jq -c '[.version.number, .body.storage.value]' "$sent")"
  }
  check "a write sends the file at the next version and records it" \
    '0/8/[8,"<p>new</p>"]' "$(live 7 200)"
  check "a 409 keeps the fetched version" '4/7/[8,"<p>new</p>"]' "$(live 7 409)"
  check "a page that moved on sends nothing" '4/7/' "$(live 8 200)"
  printf '<p>new' > "$run/page/42.storage.html"
  check "a malformed body sends nothing" '2/7/' "$(live 7 200)"
}

[[ "${1:-}" == --self-test ]] && { csu_self_test; tap_end; }

usage() { echo "Usage: $0 --from <dir>/<id>.storage.html [--title \"<new title>\"]" >&2; exit 2; }
FROM=""
TITLE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)  FROM="${2:?--from needs a file}"; shift 2 ;;
    --title) TITLE_OVERRIDE="${2:?--title needs a value}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done
[[ -n "$FROM" ]] || usage
read -r PAGE_ID FETCHED_VER <<<"$(csu_source "$FROM")" && [[ -n "${PAGE_ID:-}" ]] || exit 2
"$(dirname "${BASH_SOURCE[0]}")/storage-well-formed.sh" "$FROM" || {
  echo "confluence-safe-update: $FROM is not well-formed storage; nothing was sent" >&2; exit 2; }

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
BASE="${ATLASSIAN_SITE}/wiki/rest/api/content"

CURRENT=$(atlassian_curl "${BASE}/${PAGE_ID}?expand=version,space")
CUR_VER=$(echo "$CURRENT" | jq -r '.version.number // empty')
SPACE_KEY=$(echo "$CURRENT" | jq -r '.space.key // empty')
CUR_TITLE=$(echo "$CURRENT" | jq -r '.title // empty')

if [[ -z "$CUR_VER" || -z "$SPACE_KEY" ]]; then
  echo "Failed to fetch current page $PAGE_ID (no version/space in response):" >&2
  echo "$CURRENT" | head -5 >&2
  exit 1
fi

NEW_VER=$(csu_next_version "$FETCHED_VER" "$CUR_VER") || exit 4
TITLE="${TITLE_OVERRIDE:-$CUR_TITLE}"

# The payload goes through a file, never argv — page bodies routinely exceed
# ARG_MAX, and passing them as arguments fails with "Argument list too long".
PAYLOAD_FILE=$(mktemp)
RESP_FILE=$(mktemp)
trap 'rm -f "$PAYLOAD_FILE" "$RESP_FILE"' EXIT

csu_payload "$TITLE" "$SPACE_KEY" "$FROM" "$NEW_VER" > "$PAYLOAD_FILE"

HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X PUT "${BASE}/${PAGE_ID}" \
  -u "${JIRA_USER}:${JIRA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @"$PAYLOAD_FILE")

cat "$RESP_FILE"
echo
echo "HTTP $HTTP_CODE  (was v${CUR_VER}, now v${NEW_VER})" >&2

case "$HTTP_CODE" in
  200) printf '%s\n' "$NEW_VER" > "${FROM%.storage.html}.version" ;;
  409) echo "confluence-safe-update: v${NEW_VER} was taken while writing — refetch and reapply" >&2; exit 4 ;;
  *)   exit 1 ;;
esac
