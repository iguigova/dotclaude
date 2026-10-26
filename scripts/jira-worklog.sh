#!/usr/bin/env bash
# Atomic Jira worklog with ADF description.
#
# Posts to /rest/api/3/issue/{key}/worklog with timeSpent + ADF comment +
# (optional) remaining-estimate adjustment, in ONE call.
#
# Usage:
#   jira-worklog.sh [--quiet] [--dry-run] [--edit <worklog-id>] <issue-key> <time-spent> [remaining-estimate] < items
#
# Items: one per line on stdin, rendered as a Jira numbered list. A leading
# `1.` or `1)` on a line is dropped, since the list numbers it. Use Markdown
# [text](url) for inline links. A Jira wiki link [text|url] would render
# literally, so a line holding one is refused before anything is sent.
# Blank lines ignored.
#
# --edit <worklog-id> replaces that worklog in place (PUT) instead of creating
# one: its time spent and its whole description become the ones given. With no
# remaining-estimate the ticket's remaining is left as it is; with one it is set.
#
# --dry-run prints the JSON payload and posts nothing.
#
# --quiet prints the created worklog's id on stdout instead of the whole JSON —
# use it in a batch, and to record the id in the journal as `journal.sh --bill`
# wants it, so a billed entry names the worklog that paid for it.
#
# Example:
#   ~/.claude/scripts/jira-worklog.sh XYZ-1235 2.5h 1.5h <<'EOF'
#   Smoke test harness — built smoke_test.py with three timed stages.
#   Confluence runbook authored at [page 2415788040](https://acme.atlassian.net/wiki/x/y).
#   Security finding — credential leak in DevicesController.cs:43.
#   EOF
#
# Time format: Jira REST v3 accepts `Xh`, `X.Yh`, `Xm`, or `Xh Xm` (e.g. `2.5h`,
# `45m`, `2h 30m`). Compound forms WITHOUT a space (`2h30m`) are rejected by the
# REST parser even though the Jira UI accepts them — prefer decimal hours
# (`2.5h`) or space-separated (`2h 30m`) to avoid surprises. The helper
# URL-encodes the remaining-estimate arg, so spaces are safe.
#
# Exit code 0 on HTTP 201/200; non-zero otherwise. Prints HTTP status to stderr,
# and to stdout the response body, or the worklog id under --quiet.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# --quiet must be consumed as a flag, not mistaken for the issue key. With it
# consumed, `--quiet AAA` leaves one positional and exits 1; unconsumed it would
# leave two and reach the network, so the exit code distinguishes the two.
if [[ "${1:-}" == "--self-test" ]]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  usage=$(timeout 10 "$self" 2>&1 </dev/null || true)
  short=$(timeout 10 "$self" --quiet AAA >/dev/null 2>&1 </dev/null; echo $?)
  texts=$(printf '1. One — done.\n\n2) Two [PR](https://x.test/1).\nThree.\n' \
    | timeout 10 "$self" --dry-run AAA-1 1h 2>/dev/null \
    | jq -c '[.comment.content[1].content[].content[0].content[0].text]')
  want='["One — done.","Two ","Three."]'
  wiki=$(echo 'See [PR #1|https://x.test/1].' | timeout 10 "$self" --dry-run AAA-1 1h >/dev/null 2>&1; echo $?)
  noid=$(timeout 10 "$self" --edit AAA-1 1h >/dev/null 2>&1 </dev/null; echo $?)
  edit=$(echo 'One.' | timeout 10 "$self" --dry-run --edit 52445 AAA-1 1h 2>/dev/null | jq -r '.timeSpent')
  if grep -q -- '\[--quiet\]' <<<"$usage" && [[ "$short" -eq 1 && "$texts" == "$want" \
       && "$wiki" -eq 1 && "$noid" -eq 1 && "$edit" == "1h" ]]; then
    echo "jira-worklog self-test: PASS (--quiet consumed before positionals; leading item numbers dropped; wiki link refused; --edit takes a numeric id)"
    exit 0
  fi
  echo "jira-worklog self-test: FAIL ('--quiet AAA' exit $short, want 1; item texts $texts, want $want; wiki link exit $wiki, want 1; '--edit AAA-1' exit $noid, want 1; --edit dry-run timeSpent '$edit', want 1h)" >&2
  exit 1
fi

QUIET=0
DRY_RUN=0
EDIT_ID=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --edit)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "$0: --edit takes a numeric worklog id, got '${2:-}'" >&2; exit 1; }
      EDIT_ID="$2"; shift ;;
    *) echo "$0: unknown flag $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 [--quiet] [--dry-run] [--edit <worklog-id>] <issue-key> <time-spent> [remaining-estimate] < items" >&2
  exit 1
fi

ISSUE="$1"
TIME_SPENT="$2"
REMAINING="${3:-}"

ITEMS_FILE=$(mktemp)
RESP=$(mktemp)
trap 'rm -f "$ITEMS_FILE" "$RESP"' EXIT
cat > "$ITEMS_FILE"

PAYLOAD=$(TIME_SPENT="$TIME_SPENT" ITEMS_FILE="$ITEMS_FILE" python3 <<'PY'
import json, os, re
LINK = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')
def parse(t):
    out, i = [], 0
    for m in LINK.finditer(t):
        if m.start() > i: out.append({"type":"text","text":t[i:m.start()]})
        out.append({"type":"text","text":m.group(1),
                    "marks":[{"type":"link","attrs":{"href":m.group(2)}}]})
        i = m.end()
    if i < len(t): out.append({"type":"text","text":t[i:]})
    return out or [{"type":"text","text":t}]
NUMBER = re.compile(r'^\s*\d+[.)]\s+')
WIKI = re.compile(r'\[[^\]|]+\|[a-z]+://[^\]]+\]')
items = [NUMBER.sub('', line.rstrip()) for line in open(os.environ["ITEMS_FILE"]) if line.strip()]
for s in items:
    if WIKI.search(s):
        raise SystemExit(f"jira-worklog.sh: wiki link would render literally; write [text](url): {s}")
print(json.dumps({
    "timeSpent": os.environ["TIME_SPENT"],
    "comment": {"type":"doc","version":1,"content":[
        {"type":"paragraph","content":[{"type":"text","text":"Work accomplished this session:"}]},
        {"type":"orderedList","content":[
            {"type":"listItem","content":[{"type":"paragraph","content":parse(s)}]}
            for s in items
        ]},
    ]},
}))
PY
)

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

HELPER_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${HELPER_DIR}/atlassian-auth.sh"

URL="${ATLASSIAN_SITE}/rest/api/3/issue/${ISSUE}/worklog"
METHOD=POST
if [[ -n "$EDIT_ID" ]]; then
  URL="${URL}/${EDIT_ID}"
  METHOD=PUT
fi
if [[ -n "$REMAINING" ]]; then
  REMAINING_ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$REMAINING")
  URL="${URL}?adjustEstimate=new&newEstimate=${REMAINING_ENC}"
elif [[ -n "$EDIT_ID" ]]; then
  # A PUT defaults to adjustEstimate=auto, which moves remaining by any change
  # in time spent; an edit leaves the burndown alone unless told otherwise.
  URL="${URL}?adjustEstimate=leave"
fi

HTTP_CODE=$(curl -s -o "$RESP" -w "%{http_code}" \
  -X "$METHOD" "$URL" \
  -H "Content-Type: application/json" \
  -u "${JIRA_USER}:${JIRA_TOKEN}" \
  -d "$PAYLOAD")

if [[ "$QUIET" -eq 1 ]]; then
  jq -r '.id // empty' "$RESP"
else
  cat "$RESP"
  echo
fi
echo "HTTP $HTTP_CODE" >&2

[[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]] || exit 1
