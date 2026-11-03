#!/usr/bin/env bash
# Create a Confluence page as a child of an existing page, from a body in
# storage format.
#
# Usage:
#   confluence-create.sh --parent <id-or-url> --title "<title>" [--label <name>]... [file]
#   confluence-create.sh --dry-run --parent <id-or-url> --title "<title>" [file]
#   confluence-create.sh --self-test
#
# The body comes from the file, or stdin when no file is given. The page lands
# in the parent's space.
#
# Each --label adds one global label to the new page, in a second call once the
# page exists — a docsys quadrant page joins its section through an
# `engdocs-<slug>-<quadrant>` label. A label name is letters, digits, `-` and
# `_`; Confluence stores it lowercased.
#
# Refused before anything is written:
#   - an empty body
#   - a body that is not well-formed storage XHTML — Confluence rejects it or
#     stores it mangled
#   - a title that already exists in the parent's space — Confluence titles are
#     unique per space, and a retry must never create a second page
#   - a label name with any other character
#
# --dry-run runs every check, including the read-only parent and title lookups,
# and prints the payload without creating anything.
#
# On success prints the new page id and URL on stdout and exits 0. Prints the
# HTTP status to stderr. When the page is created but the labels are not, the
# id and URL are still printed and the exit is 4: the page exists, so a retry
# is refused on its title, and the labels are added to that page by hand.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac


well_formed() {
  "$(dirname "${BASH_SOURCE[0]}")/storage-well-formed.sh" "$1"
}

page_id_of() {
  if [[ "$1" =~ /pages/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "$1"
  else
    echo "Cannot extract page ID from: $1" >&2
    return 1
  fi
}

payload_of() {
  jq -n --arg title "$1" --arg space "$2" --arg parent "$3" \
    --rawfile body "$4" \
    '{type: "page", title: $title, space: {key: $space},
      ancestors: [{id: $parent}],
      body: {storage: {value: $body, representation: "storage"}}}'
}

labels_payload_of() {
  jq -n '$ARGS.positional | map({prefix: "global", name: .})' --args "$@"
}

valid_label() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local dir self
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' RETURN
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  printf '%s' '<h2>A &mdash; B</h2><p><ac:link><ri:user ri:account-id="x" /></ac:link> &lt;id&gt; &amp;</p>' \
    > "$dir/good.html"
  tap_run "valid storage with entities and macros is accepted" \
    well_formed "$dir/good.html"

  printf '%s' '<p><strong>unclosed</p>' > "$dir/bad.html"
  tap_fails "malformed storage is refused" well_formed "$dir/bad.html"

  payload_of "T" "PA" "123" "$dir/good.html" > "$dir/payload.json"
  tap_run "the payload names its parent, its space and the storage body" \
    jq -e '.ancestors == [{id: "123"}] and .space.key == "PA"
           and .body.storage.representation == "storage"
           and (.body.storage.value | test("&mdash;"))' "$dir/payload.json"

  tap_run "each label is sent with the global prefix" \
    jq -e '. == [{prefix: "global", name: "engdocs-serverless-topic"},
                 {prefix: "global", name: "x_1"}]' \
    < <(labels_payload_of engdocs-serverless-topic x_1)

  # Every refusal happens before any network call, so they run offline.
  tap_fails "an empty body is refused" \
    "$self" --dry-run --parent 1 --title T < <(printf '')
  tap_fails "a malformed body is refused on the argument path" \
    "$self" --dry-run --parent 1 --title T "$dir/bad.html"
  local bad
  for bad in "two words" "a:b" ""; do
    tap_fails "the label '$bad' is refused" \
      "$self" --dry-run --parent 1 --title T --label "$bad" "$dir/good.html"
  done
}

DRY_RUN=0
PARENT=""
TITLE=""
LABELS=()
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --self-test) self_test; tap_end ;;
    --dry-run) DRY_RUN=1; shift ;;
    --parent) PARENT="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --label) LABELS+=("$2"); shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PARENT" || -z "$TITLE" ]]; then
  echo "Usage: $0 [--dry-run] --parent <id-or-url> --title \"<title>\" [--label <name>]... [file]" >&2
  exit 1
fi
for label in "${LABELS[@]}"; do
  valid_label "$label" \
    || { echo "Refusing label \"$label\": use letters, digits, - and _ only" >&2; exit 1; }
done

# Body and payload go through files, never argv — page bodies routinely exceed
# ARG_MAX.
BODY_FILE=$(mktemp)
PAYLOAD_FILE=$(mktemp)
RESP_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$PAYLOAD_FILE" "$RESP_FILE"' EXIT

if [[ -n "${1:-}" ]]; then
  [[ -r "$1" ]] || { echo "Cannot read $1" >&2; exit 1; }
  cat "$1" > "$BODY_FILE"
else
  cat > "$BODY_FILE"
fi

[[ -s "$BODY_FILE" ]] || { echo "Refusing to create a page with an empty body" >&2; exit 1; }
well_formed "$BODY_FILE" || exit 1

PARENT_ID=$(page_id_of "$PARENT")

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"
BASE="${ATLASSIAN_SITE}/wiki"

SPACE_KEY=$(atlassian_curl "${BASE}/rest/api/content/${PARENT_ID}?expand=space" \
  | jq -r '.space.key // empty')
[[ -n "$SPACE_KEY" ]] || { echo "Parent page ${PARENT_ID} not found" >&2; exit 1; }

EXISTING=$(atlassian_curl -G "${BASE}/rest/api/content" \
  --data-urlencode "spaceKey=${SPACE_KEY}" --data-urlencode "title=${TITLE}" \
  | jq -r '.results[0].id // empty')
if [[ -n "$EXISTING" ]]; then
  echo "A page titled \"${TITLE}\" already exists in ${SPACE_KEY}: ${BASE}/pages/viewpage.action?pageId=${EXISTING}" >&2
  exit 1
fi

payload_of "$TITLE" "$SPACE_KEY" "$PARENT_ID" "$BODY_FILE" > "$PAYLOAD_FILE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "POST /rest/api/content  (space ${SPACE_KEY}, parent ${PARENT_ID})"
  jq '.body.storage.value |= "<\(length) chars of storage>"' "$PAYLOAD_FILE"
  if [[ ${#LABELS[@]} -gt 0 ]]; then
    echo "POST /rest/api/content/<new id>/label"
    labels_payload_of "${LABELS[@]}"
  fi
  exit 0
fi

HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "${BASE}/rest/api/content" \
  -u "${JIRA_USER}:${JIRA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @"$PAYLOAD_FILE")

echo "HTTP $HTTP_CODE" >&2
if [[ "$HTTP_CODE" != "200" ]]; then
  cat "$RESP_FILE" >&2
  exit 1
fi
jq -r '"\(.id)\n\(._links.base)\(._links.webui)"' "$RESP_FILE"

[[ ${#LABELS[@]} -gt 0 ]] || exit 0
PAGE_ID=$(jq -r '.id' "$RESP_FILE")
labels_payload_of "${LABELS[@]}" > "$PAYLOAD_FILE"
HTTP_CODE=$(curl -s -o "$RESP_FILE" -w "%{http_code}" \
  -X POST "${BASE}/rest/api/content/${PAGE_ID}/label" \
  -u "${JIRA_USER}:${JIRA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @"$PAYLOAD_FILE")
echo "HTTP $HTTP_CODE (labels)" >&2
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Page ${PAGE_ID} was created, but its labels were not added:" >&2
  cat "$RESP_FILE" >&2
  exit 4
fi
