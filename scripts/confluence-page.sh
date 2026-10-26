#!/usr/bin/env bash
# Fetch a single Confluence page by ID or URL. Normalizes URL→ID extraction
# so callers don't have to.
#
# Usage:
#   confluence-page.sh <id-or-url> [--expand <fields>]
#   confluence-page.sh <id-or-url> --to <dir>
#   confluence-page.sh --self-test   # runs against a stubbed API, no network
#
# Examples:
#   confluence-page.sh 2415788040
#   confluence-page.sh 2415788040 --expand body.storage,version,space
#   confluence-page.sh "https://acme.atlassian.net/wiki/spaces/X/pages/2415788040/Foo"
#
# Default expand: body.storage,version,space,ancestors.
# Output is the raw Confluence REST v1 page JSON.
#
# `--to <dir>` fetches the page for editing: it writes the storage body to
# <dir>/<id>.storage.html and the version that body is at to <dir>/<id>.version,
# then prints the body's path. `confluence-safe-update.sh --from` writes that
# file back against that version. Exit 1, writing nothing, when the response
# lacks either.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# The id taken from a reference and the URL asked are the contract, so the test
# runs a copy of this script beside a stubbed atlassian_curl that prints its URL.
if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  cp "$0" "$fx/confluence-page.sh"
  cat > "$fx/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  if [[ -n "${STUB_PAGE:-}" ]]; then printf '%s\n' "$*" > "$STUB_LOG"; cat "$STUB_PAGE"
  else printf '%s\n' "$*"; fi
}
STUB
  self="$fx/confluence-page.sh"
  base=https://example.invalid/wiki/rest/api/content
  by_id=$(bash "$self" 2415788040)
  by_url=$(bash "$self" "https://x.atlassian.net/wiki/spaces/X/pages/2415788040/Foo")
  expand=$(bash "$self" 7 --expand body.storage)
  word_rc=0; bash "$self" Foo >/dev/null 2>&1 || word_rc=$?
  arg_rc=0; bash "$self" 7 --bogus >/dev/null 2>&1 || arg_rc=$?
  # --to: the body lands byte for byte, with no newline added, beside its version.
  export STUB_LOG="$fx/asked" STUB_PAGE="$fx/page.json"
  jq -n '{version: {number: 12}, body: {storage: {value: "<p>a &amp; b</p>\n<p>c</p>"}}}' > "$STUB_PAGE"
  to_out=$(bash "$self" 7 --to "$fx/out")
  to_body=$(od -An -c "$fx/out/7.storage.html" | tr -s ' ' | tr -d '\n')
  to_ver=$(cat "$fx/out/7.version"); to_asked=$(cat "$STUB_LOG")
  both_rc=0; bash "$self" 7 --to "$fx/out" --expand version >/dev/null 2>&1 || both_rc=$?
  jq -n '{body: {storage: {value: "<p>x</p>"}}}' > "$STUB_PAGE"
  nover_rc=0; bash "$self" 8 --to "$fx/out" >/dev/null 2>&1 || nover_rc=$?
  jq -n '{version: {number: 3}}' > "$STUB_PAGE"
  nobody_rc=0; bash "$self" 9 --to "$fx/out" >/dev/null 2>&1 || nobody_rc=$?
  left=$(cd "$fx/out" && ls | paste -sd' ')
  unset STUB_PAGE
  want_body=' < p > a & a m p ; b < / p > \n < p > c < / p >'
  if [[ "$by_id" == "$base/2415788040?expand=body.storage,version,space,ancestors" \
        && "$by_url" == "$by_id" && "$expand" == "$base/7?expand=body.storage" \
        && "$word_rc" == 1 && "$arg_rc" == 1 \
        && "$to_out" == "$fx/out/7.storage.html" && "$to_body" == "$want_body" \
        && "$to_ver" == 12 && "$to_asked" == "$base/7?expand=body.storage,version" \
        && "$both_rc" == 1 && "$nover_rc" == 1 && "$nobody_rc" == 1 \
        && "$left" == "7.storage.html 7.version" ]]; then
    echo "confluence-page self-test: PASS (an id and a page URL ask the same" \
      "page, default and given --expand, a reference with no id and an" \
      "unknown argument are refused; --to writes the body verbatim beside its" \
      "version and prints its path, refuses --expand, and writes nothing for a" \
      "response missing the version or the body)"
    exit 0
  fi
  echo "confluence-page self-test: FAIL (id [$by_id] url [$by_url]" \
    "expand [$expand]; no id exit $word_rc; unknown arg exit $arg_rc;" \
    "--to printed [$to_out] body [$to_body] version [$to_ver] asked [$to_asked];" \
    "--to with --expand exit $both_rc; no version exit $nover_rc;" \
    "no body exit $nobody_rc; files [$left])" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <id-or-url> [--expand <fields> | --to <dir>]" >&2
  exit 1
fi

REF="$1"; shift
EXPAND=""
TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expand) EXPAND="${2:?--expand needs fields}"; shift 2 ;;
    --to)     TO="${2:?--to needs a directory}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$TO" && -n "$EXPAND" ]] && {
  echo "confluence-page: --to fetches the body and version itself; drop --expand" >&2; exit 1; }

# Pull the ID out of a URL like .../pages/<id>/... or use the literal if numeric.
if [[ "$REF" =~ /pages/([0-9]+) ]]; then
  PAGE_ID="${BASH_REMATCH[1]}"
elif [[ "$REF" =~ ^[0-9]+$ ]]; then
  PAGE_ID="$REF"
else
  echo "Cannot extract page ID from: $REF" >&2
  exit 1
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

if [[ -z "$TO" ]]; then
  atlassian_curl "${ATLASSIAN_SITE}/wiki/rest/api/content/${PAGE_ID}?expand=${EXPAND:-body.storage,version,space,ancestors}"
  exit
fi

PAGE=$(atlassian_curl "${ATLASSIAN_SITE}/wiki/rest/api/content/${PAGE_ID}?expand=body.storage,version")
VERSION=$(jq -r '.version.number // empty' <<<"$PAGE" 2>/dev/null || true)
if [[ ! "$VERSION" =~ ^[0-9]+$ ]] \
     || ! jq -e '.body.storage.value | type == "string"' <<<"$PAGE" >/dev/null 2>&1; then
  echo "confluence-page: no storage body and version for page $PAGE_ID:" >&2
  head -5 <<<"$PAGE" >&2
  exit 1
fi
# Both land through temporaries, body first: a run cut off between the two moves
# leaves an older version beside a newer body, which the write refuses, never a
# newer version beside an older body, which it would accept.
mkdir -p "$TO"
BODY="$TO/$PAGE_ID.storage.html"
jq -j '.body.storage.value' <<<"$PAGE" > "$BODY.tmp"
printf '%s\n' "$VERSION" > "$TO/$PAGE_ID.version.tmp"
mv "$BODY.tmp" "$BODY"
mv "$TO/$PAGE_ID.version.tmp" "$TO/$PAGE_ID.version"
printf '%s\n' "$BODY"
