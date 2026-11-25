#!/usr/bin/env bash
# confluence-download.sh — download the attachments of a Confluence page or
# comment into a folder (REST v1).
#
# A comment is content with its own id, so a file attached to a comment is
# reached by the comment's id, not the page's.
#
#   0   every asked attachment was written; one path per line on stdout
#   1   no attachment has the asked name, or a title is not a plain file name
#   2   usage error
#   75  the attachment listing or a download failed
#
# Usage:
#   confluence-download.sh <content-id-or-url> <dir> [<filename>]
#   confluence-download.sh --self-test
#
# Examples:
#   confluence-download.sh 2790162491 /tmp/doc
#   confluence-download.sh 2790162491 /tmp/doc "API Documentation.pdf"
#
# With no <filename> it writes every attachment. A title holding a slash, or
# one that is "." or "..", is refused before anything is written.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PF="$HOME/.claude/scripts/project_file.sh"
PAGE_URL_ID='/pages/([0-9]+)'
NUMERIC_ID='^[0-9]+$'

content_id() {  # <id-or-url>
  if [[ "$1" =~ $PAGE_URL_ID ]]; then printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ $NUMERIC_ID ]]; then printf '%s\n' "$1"
  else echo "confluence-download: no content id in: $1" >&2; return 1; fi
}

plain_name() {  # <title>
  [[ "$1" != */* && "$1" != "." && "$1" != ".." && -n "$1" ]]
}

# One "<title>\t<download path>" line per attachment, or exit 75.
attachments() {  # <id>
  local listing
  listing=$(atlassian_curl "${ATLASSIAN_SITE}/wiki/rest/api/content/$1/child/attachment?limit=200") \
    || { echo "confluence-download: listing the attachments of $1 failed" >&2; return 75; }
  jq -er '.results[] | [.title, ._links.download] | @tsv' <<<"$listing" 2>/dev/null \
    || { echo "confluence-download: no attachment listing for $1:" >&2; head -3 <<<"$listing" >&2; return 75; }
}

fetch() {  # <dir> <title> <download path>
  atlassian_curl -f -L -o "$1/$2" "${ATLASSIAN_SITE}/wiki$3" \
    || { echo "confluence-download: downloading $2 failed" >&2; rm -f "$1/$2"; return 75; }
  printf '%s\n' "$1/$2"
}

# Every title is checked before the first download, so a bad one writes nothing.
download() {  # <id> <dir> [<filename>]
  local id=$1 dir=$2 want=${3:-} list title path found=0
  list=$(attachments "$id") || return $?
  while IFS=$'\t' read -r title path; do
    plain_name "$title" || { echo "confluence-download: refusing title: $title" >&2; return 1; }
  done <<<"$list"
  mkdir -p "$dir" || return 2
  while IFS=$'\t' read -r title path; do
    [[ -z "$want" || "$title" == "$want" ]] || continue
    fetch "$dir" "$title" "$path" || return $?
    found=1
  done <<<"$list"
  [[ "$found" -eq 1 ]] || { echo "confluence-download: $id has no attachment named: $want" >&2; return 1; }
}

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # shellcheck source=tap.sh
  . "$(dirname "$self")/tap.sh"
  mkdir -p "$fx/.claude/scripts"
  tap_project "$fx"
  # The stub serves $STUB_LIST for a listing and writes the URL it was asked
  # into the -o file for a download, failing a URL that holds "broken".
  cat > "$fx/.claude/scripts/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local out="" url
  for url in "$@"; do :; done
  while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out=$2; shift; done
  [[ "$url" == *broken* ]] && return 22
  if [[ -n "$out" ]]; then printf '%s' "$url" > "$out"; else cat "$STUB_LIST"; fi
}
STUB
  cd "$fx" || exit 2
  export STUB_LIST="$fx/list.json"
  run() { bash "$self" "$@" >/dev/null 2>&1; echo $?; }
  listing() { jq -n --argjson r "$1" '{results: $r}' > "$STUB_LIST"; }  # <results json>
  two='[{"title":"a b (1).pdf","_links":{"download":"/download/a.pdf"}},
        {"title":"c.txt","_links":{"download":"/download/c.txt"}}]'
  listing "$two"
  all=$(bash "$self" 7 "$fx/all")
  one=$(bash "$self" "https://x.atlassian.net/wiki/spaces/X/pages/7/Foo" "$fx/one" c.txt)
  tap_is "with no name every attachment is written, one path a line" \
    "$all" "$fx/all/a b (1).pdf
$fx/all/c.txt"
  tap_is "a download asks the site's wiki path for the file" \
    "$(cat "$fx/all/a b (1).pdf")" "https://example.invalid/wiki/download/a.pdf"
  tap_is "a page URL reaches the same content, and a name writes only that file" \
    "$one" "$fx/one/c.txt"
  tap_is "only the named file lands" "$(ls "$fx/one")" "c.txt"
  tap_is "a run that writes what was asked exits 0" "$(run 7 "$fx/ok" c.txt)" 0
  tap_is "a name no attachment has is refused" "$(run 7 "$fx/none" nope.pdf)" 1
  tap_is "a reference with no id is a usage error" "$(run Foo "$fx/x")" 2
  tap_is "a missing folder is a usage error" "$(run 7)" 2
  listing '[{"title":"../evil","_links":{"download":"/download/e"}},
            {"title":"ok.txt","_links":{"download":"/download/ok"}}]'
  tap_is "a title with a slash is refused" "$(run 7 "$fx/bad")" 1
  tap_is "a refused title writes nothing" "$(ls "$fx/bad" 2>/dev/null)" ""
  listing '[{"title":"..","_links":{"download":"/download/d"}}]'
  tap_is "a title of two dots is refused" "$(run 7 "$fx/dots")" 1
  listing '[{"title":".","_links":{"download":"/download/d"}}]'
  tap_is "a title of one dot is refused" "$(run 7 "$fx/dot")" 1
  listing '[{"title":"x.pdf","_links":{"download":"/download/broken"}}]'
  tap_is "a failed download is no answer" "$(run 7 "$fx/fail")" 75
  tap_is "a failed download leaves no partial file" "$(ls "$fx/fail")" ""
  printf 'not json' > "$STUB_LIST"
  tap_is "a listing that is not JSON is no answer" "$(run 7 "$fx/nojson")" 75
  tap_is "plain_name accepts a name with spaces" "$(plain_name "a b.pdf"; echo $?)" 0
  tap_is "plain_name refuses an empty title" "$(plain_name ""; echo $?)" 1
  tap_end
fi

[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: confluence-download.sh <content-id-or-url> <dir> [<filename>]" >&2; exit 2; }
ID=$(content_id "$1") || exit 2
# shellcheck disable=SC1091
# shellcheck source=atlassian-auth.sh
source "$("$PF" --script atlassian-auth.sh)" || exit 75
download "$ID" "$2" "${3:-}"
