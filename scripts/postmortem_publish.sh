#!/usr/bin/env bash
# postmortem_publish.sh — publish a post-mortem and link it from its ticket.
#
# Usage:
#   postmortem_publish.sh --ticket <KEY> --title "<KEY>: <symptom>" <storage-file>
#   postmortem_publish.sh --dry-run --ticket <KEY> --title "..." <storage-file>
#   postmortem_publish.sh --self-test
#
# A Claude session that has not loaded the draft skill is refused by
# draft_gate.py before step 1, so the page and its comment go out together or
# not at all.
#
# Three steps, each gated on the one before:
#   1. create the page under the project's post-mortem parent page
#      (confluence-create.sh, which refuses an empty, malformed or
#      already-used title)
#   2. read the page back as rendered and require every report section,
#      so a macro that failed to render is caught before anyone is told
#   3. comment the page link on the ticket
#
# The title must start with "<KEY>: ", the form every report under the parent
# uses. The storage file must match the structure of the standard template,
# skills/postmortem/template.storage.html, before step 1 runs: every <h2>
# heading, every summary row not marked data-optional, the info panel around
# the Executive summary, and the Timeline and Follow-up table header rows.
# The template is the only place the structure is defined.
#
# --dry-run checks the title and the structure, runs step 1 as a dry run, and
# prints the comment it would post. Nothing is written.
#
# The parent page is the project's value postmortem_parent, read through
# project_file.sh --value; the scripts it runs are resolved by name through
# project_file.sh --script. A project without them is refused, exit 1, naming
# what it lacks, before anything is checked or written.
#
# On success prints the page URL and the comment id.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$HOME/.claude/scripts/project_file.sh"
TEMPLATE="${HERE}/../skills/postmortem/template.storage.html"
[[ -r "$TEMPLATE" ]] || { echo "Template not found: $TEMPLATE" >&2; exit 1; }

# The template writes one row per line, which is what lets these read it.
sections() {
  grep -o '<h2>[^<]*</h2>' "$TEMPLATE" | sed 's/<[^>]*>//g'
}

summary_labels() {
  grep -E '^<tr><t[hd]><p><strong>' "$TEMPLATE" \
    | sed -E 's/^<tr><t[hd]><p><strong>([^<]*)<.*/\1/'
}

header_rows() {
  grep -E '^<tr><th>[^<]' "$TEMPLATE"
}

# Where a storage body departs from the template, one line per departure.
missing_structure() {
  local item
  while read -r item; do
    grep -qF "<h2>${item}</h2>" "$1" || echo "heading: ${item}"
  done < <(sections)
  while read -r item; do
    grep -qF "<strong>${item}</strong>" "$1" || echo "summary row: ${item}"
  done < <(summary_labels)
  while read -r item; do
    grep -qF "$item" "$1" || echo "table header: ${item}"
  done < <(header_rows)
  grep -qF 'ac:name="info"' "$1" \
    || echo "info panel around the Executive summary"
}

# Sections absent from a rendered page, one per line; tags are stripped first
# so a heading split by markup still counts.
missing_sections() {
  local text section
  text=$(sed 's/<[^>]*>/ /g' "$1" | tr -s ' ')
  while read -r section; do
    grep -qF "$section" <<<"$text" || echo "$section"
  done < <(sections)
}

# A rendered page carrying every section, as Confluence's view shows headings.
rendered_fixture() {
  local section
  while read -r section; do
    printf '<h3><ac:emoticon ac:name="x" /> %s</h3><p>text</p>' "$section"
  done < <(sections)
}

title_matches() {
  [[ "$2" == "$1: "?* ]]
}

comment_wiki() {
  printf 'Blameless post-mortem: [%s|%s]\n' "$1" "$2"
}

self_test() {
  source "$HOME/.claude/scripts/tap.sh"
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT  # dir is global: tap_end exits, and the trap reads it then

  tap_is "the template passes its own check" "$(missing_structure "$TEMPLATE")" ""

  grep -v 'data-optional' "$TEMPLATE" > "$dir/no-customer.html"
  tap_is "an optional summary row is not required" "$(missing_structure "$dir/no-customer.html")" ""

  sed 's|<h2>Timeline</h2>|<h2>Timeline (UTC)</h2>|' "$TEMPLATE" > "$dir/heading.html"
  tap_is "a renamed heading is reported" "$(missing_structure "$dir/heading.html")" "heading: Timeline"

  sed 's|<th>Task</th><th>Owner</th>|<th>What</th><th>Who</th>|' "$TEMPLATE" \
    > "$dir/header.html"
  tap_like "a changed table header is reported" "$(missing_structure "$dir/header.html")" "table header: *<th>Task</th>*"

  sed '/<strong>Symptom<\/strong>/d' "$TEMPLATE" > "$dir/row.html"
  tap_is "a missing summary row is reported" "$(missing_structure "$dir/row.html")" "summary row: Symptom"

  sed 's|ac:name="info"|ac:name="note"|' "$TEMPLATE" > "$dir/panel.html"
  tap_like "a missing info panel is reported" "$(missing_structure "$dir/panel.html")" "info panel*"

  rendered_fixture > "$dir/view.html"
  tap_is "a complete rendered page is not flagged" "$(missing_sections "$dir/view.html")" ""

  rendered_fixture | sed 's/Timeline/Timelime/' > "$dir/view-gap.html"
  tap_is "a section missing from the page is reported" "$(missing_sections "$dir/view-gap.html")" Timeline

  tap_run "a well-formed title is accepted" title_matches XYZ-1 "XYZ-1: Gates stuck"
  tap_fails "a title without its key is refused" title_matches XYZ-1 "Gates stuck"
  tap_fails "a title with a longer key is refused" title_matches XYZ-1 "XYZ-12: x"
  tap_fails "a title with nothing after its key is refused" title_matches XYZ-1 "XYZ-1: "

  tap_is "the comment links the page" "$(comment_wiki "XYZ-1: Gates stuck" "https://x/pages/1")" \
    "Blameless post-mortem: [XYZ-1: Gates stuck|https://x/pages/1]"

  self_test_e2e
  tap_end
}

# self_test_e2e — the script itself, run in a fixture project whose own scripts stand
# in for the global Confluence and Jira ones, so nothing is published.
self_test_e2e() {
  local fx out st
  # Most cases assert a non-zero exit, which errexit would turn into an early end.
  set +e
  fx=$(mktemp -d) || return 2
  mkdir -p "$fx/p/.claude/helpers" "$fx/bare/.claude"
  local self="$HERE/postmortem_publish.sh"
  echo 77001 > "$fx/p/.claude/postmortem_parent"
  cd "$fx/p" || return 2

  cat > "$fx/p/.claude/helpers/confluence-create.sh" <<'STUB'
#!/usr/bin/env bash
# Stub: records the call, and on a real run prints the id and URL the caller parses.
for a in "$@"; do [[ "$a" == --dry-run ]] && { echo "DRY: would create"; exit 0; }; done
echo "$*" >> "$PM_CREATED"
echo 90001
echo https://example.invalid/wiki/pages/90001
STUB
  cat > "$fx/p/.claude/helpers/jira-comment.sh" <<'STUB'
#!/usr/bin/env bash
cat > "$PM_COMMENT_BODY"
cat "$PM_COMMENT_RESP"
STUB
  cat > "$fx/p/.claude/helpers/atlassian-auth.sh" <<'STUB'
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() { jq -n --rawfile v "$PM_RENDERED" '{body:{view:{value:$v}}}'; }
STUB
  chmod +x "$fx/p/.claude/helpers/confluence-create.sh" "$fx/p/.claude/helpers/jira-comment.sh"
  mv "$fx/p/.claude/helpers" "$fx/p/.claude/scripts"
  export PM_CREATED="$fx/created" PM_COMMENT_BODY="$fx/comment.wiki" \
         PM_COMMENT_RESP="$fx/comment.json" PM_RENDERED="$fx/rendered.html"
  export CLAUDE_CODE_SESSION_ID=pm DRAFT_GATE_DIR="$fx/gate"
  mkdir -p "$fx/gate" && echo '["draft"]' > "$fx/gate/pm.json"

  cp "$TEMPLATE" "$fx/full.html"
  sed 's|<h2>Timeline</h2>|<h2>Timelime</h2>|' "$TEMPLATE" > "$fx/gap.html"
  rendered_fixture > "$PM_RENDERED"
  printf '{"id":"55501"}' > "$PM_COMMENT_RESP"
  : > "$PM_CREATED"

  check() { tap_is "$1" "$3" "$2"; }  # DESCRIPTION WANT GOT

  out=$("$self" --dry-run --ticket XYZ-1 --title "XYZ-1: Gates stuck" "$fx/full.html" 2>&1); st=$?
  check "a dry run exits 0" 0 "$st"
  check "a dry run publishes nothing" 'true' "$([[ ! -s "$PM_CREATED" ]] && echo true || echo false)"
  check "a dry run shows the comment it would post" 'true' \
    "$(grep -q 'Blameless post-mortem: \[XYZ-1: Gates stuck|' <<<"$out" && echo true || echo false)"

  out=$("$self" --ticket XYZ-1 --title "Gates stuck" "$fx/full.html" 2>&1); st=$?
  check "a title missing its ticket key is refused" 1 "$st"
  check "and nothing was created" 'true' "$([[ ! -s "$PM_CREATED" ]] && echo true || echo false)"

  out=$("$self" --ticket XYZ-1 --title "XYZ-1: x" "$fx/gap.html" 2>&1); st=$?
  check "a report missing a section is refused" 1 "$st"
  check "and the missing section is named" 'true' \
    "$(grep -q 'Timeline' <<<"$out" && echo true || echo false)"
  check "still nothing created" 'true' "$([[ ! -s "$PM_CREATED" ]] && echo true || echo false)"

  out=$("$self" --ticket XYZ-1 "$fx/full.html" 2>&1); st=$?
  check "a missing --title is a usage error" "1 Usage" "$st ${out:0:5}"
  out=$("$self" --title "XYZ-1: x" "$fx/full.html" 2>&1); st=$?
  check "a missing --ticket is a usage error" "1 Usage" "$st ${out:0:5}"
  "$self" --ticket XYZ-1 --title "XYZ-1: x" "$fx/nothere.html" >/dev/null 2>&1; st=$?
  check "an unreadable body is a usage error" 1 "$st"
  "$self" --bogus --ticket XYZ-1 --title "XYZ-1: x" "$fx/full.html" >/dev/null 2>&1; st=$?
  check "an unknown flag is refused" 2 "$st"

  out=$(CLAUDE_CODE_SESSION_ID=nodraft "$self" --ticket XYZ-1 --title "XYZ-1: Gates stuck" "$fx/full.html" 2>&1); st=$?
  check "a session that has not loaded draft is refused" "1 true" "$st $(grep -q 'draft_gate' <<<"$out" && echo true || echo false)"
  check "and no page was created" 'true' "$([[ ! -s "$PM_CREATED" ]] && echo true || echo false)"

  out=$("$self" --ticket XYZ-1 --title "XYZ-1: Gates stuck" "$fx/full.html" 2>&1); st=$?
  check "a full run exits 0" 0 "$st"
  check "the page goes under the project's parent" 'true' \
    "$(grep -q -- '--parent 77001 ' "$PM_CREATED" && echo true || echo false)"
  check "it prints the page and the comment id" 'true' \
    "$(grep -q 'page: https://example.invalid/wiki/pages/90001' <<<"$out" \
       && grep -q 'comment: XYZ-1 #55501' <<<"$out" && echo true || echo false)"
  check "the comment carries the page URL, not a placeholder" 'true' \
    "$(grep -q '|https://example.invalid/wiki/pages/90001\]' "$PM_COMMENT_BODY" && echo true || echo false)"

  # The step that exists so nobody is told about a page that renders wrong.
  rendered_fixture | sed 's/Timeline/Timelime/' > "$PM_RENDERED"
  : > "$PM_COMMENT_BODY"
  out=$("$self" --ticket XYZ-1 --title "XYZ-1: Gates stuck" "$fx/full.html" 2>&1); st=$?
  check "a page that does not render every section fails the run" 1 "$st"
  check "and says the page exists so it is not published twice" 'true' \
    "$(grep -q 'was created but does not render' <<<"$out" && echo true || echo false)"
  check "and no comment is posted" 'true' "$([[ ! -s "$PM_COMMENT_BODY" ]] && echo true || echo false)"

  rendered_fixture > "$PM_RENDERED"
  printf '{}' > "$PM_COMMENT_RESP"
  out=$("$self" --ticket XYZ-1 --title "XYZ-1: Gates stuck" "$fx/full.html" 2>&1); st=$?
  check "a comment that returns no id fails the run" 1 "$st"
  check "and says the page is already published" 'true' \
    "$(grep -q 'is published but the comment' <<<"$out" && echo true || echo false)"

  out=$(cd "$fx/bare" && "$self" --dry-run --ticket XYZ-1 --title "XYZ-1: x" "$fx/full.html" 2>&1); st=$?
  check "a project without postmortem_parent is refused" 1 "$st"
  check "and the refusal names it" 'true' \
    "$(grep -q 'postmortem_parent' <<<"$out" && echo true || echo false)"

  cd / && rm -rf "$fx"
}

DRY_RUN=0
TICKET=""
TITLE=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --self-test) self_test; exit $? ;;
    --dry-run) DRY_RUN=1; shift ;;
    --ticket) TICKET="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

BODY="${1:-}"
if [[ -z "$TICKET" || -z "$TITLE" || ! -r "$BODY" ]]; then
  echo "Usage: $0 [--dry-run] --ticket <KEY> --title \"<KEY>: <symptom>\" <storage-file>" >&2
  exit 1
fi

PARENT=$("$PF" --value postmortem_parent)
CREATE=$("$PF" --script confluence-create.sh)
AUTH=$("$PF" --script atlassian-auth.sh)
COMMENT=$("$PF" --script jira-comment.sh)

title_matches "$TICKET" "$TITLE" \
  || { echo "Title must start with \"${TICKET}: \"" >&2; exit 1; }

GAPS=$(missing_structure "$BODY")
[[ -z "$GAPS" ]] \
  || { printf 'Report departs from the template:\n%s\n' "$GAPS" >&2; exit 1; }

if [[ "$DRY_RUN" -eq 1 ]]; then
  "$CREATE" --dry-run --parent "$PARENT" --title "$TITLE" "$BODY"
  echo "Comment on ${TICKET}:"
  comment_wiki "$TITLE" "<page url>"
  exit 0
fi

"$("$PF" --script draft_gate.py)" check draft || exit 1

CREATED=$("$CREATE" --parent "$PARENT" --title "$TITLE" "$BODY")
PAGE_ID=$(sed -n 1p <<<"$CREATED")
PAGE_URL=$(sed -n 2p <<<"$CREATED")

# shellcheck source=atlassian-auth.sh
source "$AUTH"
VIEW=$(mktemp)
trap 'rm -f "$VIEW"' EXIT

atlassian_curl "${ATLASSIAN_SITE}/wiki/rest/api/content/${PAGE_ID}?expand=body.view" \
  | jq -r '.body.view.value' > "$VIEW"
GAPS=$(missing_sections "$VIEW")
if [[ -n "$GAPS" ]]; then
  printf 'Page %s was created but does not render these sections:\n%s\n' \
    "$PAGE_URL" "$GAPS" >&2
  echo "Fix the page, then comment the link on ${TICKET}." >&2
  exit 1
fi

COMMENT_ID=$(comment_wiki "$TITLE" "$PAGE_URL" | "$COMMENT" "$TICKET" \
  | jq -r '.id // empty')
[[ -n "$COMMENT_ID" ]] \
  || { echo "Page ${PAGE_URL} is published but the comment on ${TICKET} failed" >&2; exit 1; }

echo "page: ${PAGE_URL}"
echo "comment: ${TICKET} #${COMMENT_ID}"
