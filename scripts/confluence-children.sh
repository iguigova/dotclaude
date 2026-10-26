#!/usr/bin/env bash
# List the children of a Confluence page. Optionally recurse and/or fetch each
# child's body in one shot, in place of listing and then fetching each page.
#
# Usage:
#   confluence-children.sh <parent-id-or-url> [--recurse] [--with-body]
#   confluence-children.sh --self-test   # walks a fixture tree, no network
#
# Output JSON: an array of { id, title, parent_id, body? } objects.
# Without --with-body, just {id, title, parent_id} — cheap inventory.
# With --with-body, each entry also includes the `storage` representation.
#
# Examples:
#   confluence-children.sh 2338029587                       # Tickets hub, one level
#   confluence-children.sh 2338029587 --recurse             # full tree, no bodies
#   confluence-children.sh 2338029587 --recurse --with-body # full tree, with bodies (slow)

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# The walk is the contract, so the test runs this script against a stubbed
# atlassian_curl: a two-level tree whose bodies are each over 128 KiB, the
# kernel's cap on one argument, so a body passed to jq as an argument fails it.
if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  cp "$0" "$fx/confluence-children.sh"
  head -c 200000 /dev/zero | tr '\0' x > "$fx/body"
  cat > "$fx/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local dir; dir="$(dirname "${BASH_SOURCE[0]}")"
  case "$1" in
    */1/child/page*) echo '{"results":[{"id":"2","title":"a"},{"id":"3","title":"b\tc"}]}' ;;
    */2/child/page*) echo '{"results":[{"id":"4","title":"d"}]}' ;;
    */child/page*)   echo '{"results":[]}' ;;
    *expand=body.storage) jq -Rs '{body: {storage: {value: .}}}' < "$dir/body" ;;
  esac
}
STUB
  self="$fx/confluence-children.sh"
  flat=$("$self" 1 | jq -c 'map([.id, .parent_id])')
  tree=$("$self" 1 --recurse | jq -c 'map([.id, .parent_id])')
  bodies=$("$self" 1 --recurse --with-body \
    | jq -c 'map([.id, .title, (.body | length)])') || bodies="exit $?"
  want_flat='[["2","1"],["3","1"]]'
  want_tree='[["2","1"],["3","1"],["4","2"]]'
  want_bodies='[["2","a",200000],["3","b\tc",200000],["4","d",200000]]'
  if [[ "$flat" == "$want_flat" && "$tree" == "$want_tree" \
        && "$bodies" == "$want_bodies" ]]; then
    echo "confluence-children self-test: PASS (one level, recursion, each body" \
      "over 128 KiB inlined, a tab in a title kept)"
    exit 0
  fi
  echo "confluence-children self-test: FAIL (want [$want_flat] got [$flat];" \
    "want [$want_tree] got [$tree]; want [$want_bodies] got [$bodies])" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <parent-id-or-url> [--recurse] [--with-body]" >&2
  exit 1
fi

REF="$1"; shift
RECURSE=0; WITH_BODY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recurse)   RECURSE=1; shift ;;
    --with-body) WITH_BODY=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ "$REF" =~ /pages/([0-9]+) ]]; then
  ROOT="${BASH_REMATCH[1]}"
elif [[ "$REF" =~ ^[0-9]+$ ]]; then
  ROOT="$REF"
else
  echo "Cannot extract page ID from: $REF" >&2
  exit 1
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

BASE="${ATLASSIAN_SITE}/wiki/rest/api/content"

# One JSON object per line for each child of the page. Pages travel between
# steps as lines on a pipe and are assembled once at the end: a page list or a
# body passed back to jq as an argument fails past the kernel's 128 KiB cap.
list_children () {
  local pid="$1"
  atlassian_curl "${BASE}/${pid}/child/page?limit=200" \
    | jq -c --arg pid "$pid" '.results[] | {id: .id, title: .title, parent_id: $pid}'
}

# BFS; every child page is one line of $pages.
pages="$(mktemp)"
trap 'rm -f "$pages"' EXIT
visited=" "
queue=("$ROOT")

while [[ ${#queue[@]} -gt 0 ]]; do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ "$visited" == *" $current "* ]] && continue
  visited+="$current "

  children=$(list_children "$current")
  [[ -n "$children" ]] || continue
  printf '%s\n' "$children" >> "$pages"

  if [[ "$RECURSE" -eq 1 ]]; then
    while IFS= read -r cid; do queue+=("$cid"); done < <(jq -r '.id' <<<"$children")
  fi
done

if [[ "$WITH_BODY" -eq 1 ]]; then
  while IFS= read -r page; do
    atlassian_curl "${BASE}/$(jq -r '.id' <<<"$page")?expand=body.storage" \
      | jq -c --argjson page "$page" '$page + {body: (.body.storage.value // "")}'
  done < "$pages" | jq -s '.'
else
  jq -s '.' "$pages"
fi
