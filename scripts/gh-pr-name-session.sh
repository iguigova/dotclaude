#!/usr/bin/env bash
# Name the current session after the PR under review, so `claude --resume`
# lists it by ticket rather than by first prompt. Prints the title record it wrote.
#
# Usage:
#   gh-pr-name-session.sh <pr-ref> [suffix]
#   gh-pr-name-session.sh --self-test
#
# The title is `<TICKET> <SUFFIX> <PR URL>` (e.g.
# `XYZ-1234 PR https://github.com/Org/repo/pull/12`), falling back to
# `<repo>#<N> <SUFFIX> <PR URL>` when the PR names no ticket in its title or
# head branch. The URL makes the PR one click away from `claude --resume`.
#
# `suffix` defaults to `PR`, which is what /review:pr writes. /review:bot passes
# `BOT`, so a review session and a bot-response session on the same ticket are
# told apart in `claude --resume` instead of showing as two identical rows.
#
# Both skills run this twice — from gh-pr-start.sh at the start, so a run
# abandoned mid-flight is still named, and directly at the end, so the ticket is
# the last title record written, ahead of whatever the CLI's auto-titler appended
# in between.
#
# `.ticket` comes from gh-pr-fetch.sh, which owns the extraction; this never
# re-derives it from the title. Without a saved fetch only the ref is known, so
# the fallback title is used and the ticket is not guessed.
#
# session_rename.sh appends a title record the CLI reads when it loads the
# session: a zero exit means the record was written, and the running session's
# header keeps its old title until the session is resumed.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENAME="$HOME/.claude/scripts/session_rename.sh"

# <ticket> <owner> <repo> <number> <suffix> -> the title. A ticket that is empty, or the literal
# "null" a `jq -r` prints for a missing key, takes the fallback: "null PR" is a
# session title nobody would recognise and no ticket key ever looks like that.
session_title() {
  local ticket="$1" owner="$2" repo="$3" number="$4" suffix="$5"
  local url="https://github.com/$owner/$repo/pull/$number"
  if [[ -n "$ticket" && "$ticket" != "null" ]]; then
    printf '%s %s %s\n' "$ticket" "$suffix" "$url"
  else
    printf '%s#%s %s %s\n' "$repo" "$number" "$suffix" "$url"
  fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  fails=()
  check() { # <want> <ticket> <owner> <repo> <number> <suffix> <label>
    local got; got=$(session_title "$2" "$3" "$4" "$5" "$6")
    [[ "$got" == "$1" ]] || fails+=("$7: got '$got', want '$1'")
  }
  check "XYZ-1234 PR https://github.com/Acme/web-app/pull/5236" \
    "XYZ-1234" "Acme" "web-app" "5236" "PR" "ticket title"
  check "events-service#13 PR https://github.com/acme-internal/events-service/pull/13" \
    "" "acme-internal" "events-service" "13" "PR" "fallback title"
  check "events-service#13 PR https://github.com/acme-internal/events-service/pull/13" \
    "null" "acme-internal" "events-service" "13" "PR" "literal 'null' ticket"
  # The suffix is what keeps /review:bot's session apart from /review:pr's.
  check "ABC-10785 BOT https://github.com/Acme/billing-service/pull/194" \
    "ABC-10785" "Acme" "billing-service" "194" "BOT" "BOT suffix"
  check "billing-service#194 BOT https://github.com/Acme/billing-service/pull/194" \
    "" "Acme" "billing-service" "194" "BOT" "BOT fallback"
  grep -q '\.ticket // empty' "${BASH_SOURCE[0]}" || fails+=("the ticket read does not use '// empty'")
  [[ -x "$RENAME" ]] || fails+=("$RENAME is missing or not executable — the rename would fail silently")
  "$HERE/gh_pr_ref.py" --self-test >/dev/null 2>&1 || fails+=("gh_pr_ref.py self-test fails")
  if ((${#fails[@]})); then
    printf 'gh-pr-name-session self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-name-session self-test: PASS (ticket, fallback and literal-null titles, PR and BOT suffixes, PR URL, jq guard and rename script asserted)"
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <pr-ref> [suffix] | --self-test" >&2
  exit 1
fi

REF="$1"
SUFFIX="${2:-PR}"
REFJSON=$("$HERE/gh_pr_ref.py" "$REF") || exit 1
OWNER=$(jq -er .owner <<<"$REFJSON")
REPO=$(jq -er .repo <<<"$REFJSON")
NUMBER=$(jq -er .number <<<"$REFJSON")
WORKDIR=$("$HERE/gh-pr-workdir.sh" "$REF")

# `// empty` rather than `// ""`: a missing key must arrive as an empty string,
# not the text "null", or the session is named "null PR".
TICKET=""
if [[ -s "$WORKDIR/pr.json" ]]; then
  TICKET=$(jq -r '.ticket // empty' "$WORKDIR/pr.json")
fi

TITLE=$(session_title "$TICKET" "$OWNER" "$REPO" "$NUMBER" "$SUFFIX")
"$RENAME" "$TITLE" >/dev/null
printf 'title record written: %s (shows once the session is resumed)\n' "$TITLE"
