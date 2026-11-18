#!/usr/bin/env bash
# Start a PR review: resolve the PR, fetch it into its working directory and name
# the session after it. The first step of /review:pr (suffix PR) and /review:bot
# (suffix BOT), so both open the same way.
#
# Usage:
#   gh-pr-start.sh [<pr-ref>] [--suffix PR|BOT] [--no-name]
#   gh-pr-start.sh --self-test
#
# With no <pr-ref>, the PR is the one the session's title names
# (`gh_pr_ref.py --from-session`), so a resumed or re-run review needs no
# argument. Prints, on stdout:
#
#   pr:    <PR URL> (from the argument | from the session title)
#   dir:   <the PR's working directory, as gh-pr-workdir.sh prints it>
#   fetch: <dir>/pr.json at <head sha>, ticket <KEY | none>
#   title record written: <title> (shows once the session is resumed)
#
# The URL is the ref every later step takes. The fetch is gh-pr-fetch.sh's,
# written whole or not at all. The title is gh-pr-name-session.sh's, written
# after the fetch so it carries the ticket. --no-name skips it, for a run that
# must write nothing outside the working directory, and the last line says so.
#
# Exit: 0 done; 1 a bad ref or a failed fetch; 2 no ref given and the session
# title names no PR -- ask the user which PR; 4 fetched, but the title record was
# not written: the last line gives the reason and says the review can go on.
#
# GH_PR_START_FETCH replaces gh-pr-fetch.sh, for --self-test.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

start() {  # [<pr-ref>] [--suffix PR|BOT] [--no-name]
  local ref="" suffix=PR name=1
  while (($#)); do
    case "$1" in
      --suffix) suffix="${2:?--suffix needs PR or BOT}"; shift 2 ;;
      --no-name) name=0; shift ;;
      -*) echo "gh-pr-start.sh: unknown option $1" >&2; return 1 ;;
      *) [[ -z "$ref" ]] || { echo "gh-pr-start.sh: one PR ref only" >&2; return 1; }
         ref="$1"; shift ;;
    esac
  done
  review "$ref" "$suffix" "$name"
}

review() {  # REF SUFFIX NAME — REF empty for the session title's PR
  local source="the argument" url dir
  [[ -n "$1" ]] || source="the session title"
  url=$(pr_url "$1") || return
  dir=$("$HERE/gh-pr-workdir.sh" "$url") || return 1
  printf 'pr:    %s (from %s)\ndir:   %s\n' "$url" "$source" "$dir"
  fetch_pr "$url" "$dir" || return 1
  (($3)) || { echo "title: not written (--no-name)"; return 0; }
  name_session "$url" "$2"
}

# pr_url REF — the PR's URL; with REF empty, the PR the session title names.
pr_url() {
  local ref=$1 refjson
  if [[ -z "$ref" ]]; then
    ref=$("$HERE/gh_pr_ref.py" --from-session) || {
      echo "gh-pr-start.sh: no PR given and the session title names none -- ask the user which PR" >&2
      return 2; }
  fi
  refjson=$("$HERE/gh_pr_ref.py" "$ref") || return 1
  printf 'https://github.com/%s\n' "$(jq -r '"\(.owner)/\(.repo)/pull/\(.number)"' <<<"$refjson")"
}

# fetch_pr URL DIR — DIR/pr.json, written whole or not at all, and its line.
fetch_pr() {
  local url=$1 dir=$2 fetch tmp head ticket
  fetch="${GH_PR_START_FETCH:-$HERE/gh-pr-fetch.sh}"
  tmp=$(mktemp "$dir/pr.json.XXXXXX")
  if ! "$fetch" "$url" > "$tmp"; then
    rm -f "$tmp"; echo "gh-pr-start.sh: fetch failed for $url" >&2; return 1
  fi
  mv "$tmp" "$dir/pr.json"
  head=$(jq -r '.head_sha // empty' "$dir/pr.json")
  ticket=$(jq -r '.ticket // empty' "$dir/pr.json")
  printf 'fetch: %s/pr.json at %s, ticket %s\n' "$dir" "${head:-?}" "${ticket:-none}"
}

# name_session URL SUFFIX — the title record; exit 4 when it is not written.
name_session() {
  local out
  if ! out=$("$HERE/gh-pr-name-session.sh" "$1" "$2" 2>&1); then
    printf 'title: not written -- %s -- the review can go on\n' "$out"; return 4
  fi
  printf '%s\n' "$out"
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  export GH_PR_WORKDIR_BASE="$tmp/base" SESSION_RENAME_TRANSCRIPT="$tmp/t.jsonl"
  export CLAUDE_CODE_SESSION_ID=test-sid GH_PR_START_FETCH="$tmp/fetch"
  : > "$SESSION_RENAME_TRANSCRIPT"
  # shellcheck disable=SC2016  # $1 is the stub fetch's own argument
  printf '#!/bin/sh\necho "{\\"head_sha\\":\\"abc123\\",\\"ticket\\":\\"ABC-1\\",\\"ref\\":\\"$1\\"}"\n' \
    > "$tmp/fetch"
  chmod +x "$tmp/fetch"
  url=https://github.com/Org/repo/pull/7
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  run() { out=$(start "$@" 2>"$tmp/err") && code=0 || code=$?; }

  # No argument and no title naming a PR: ask, and fetch nothing.
  run
  tap_is "no ref in an unnamed session exits 2" "$code" 2
  tap_run "and says to ask the user" grep -q 'ask the user which PR' "$tmp/err"

  # A slug is resolved to the URL every later step takes; the title follows the fetch.
  run Org/repo#7
  tap_is "a slug ref exits 0" "$code" 0
  tap_like "a slug ref is resolved to its URL" "$out" "*pr:    $url (from the argument)*"
  dir="$GH_PR_WORKDIR_BASE/Org-repo-7"
  tap_like "the run names its directory" "$out" "*dir:   $dir*"
  tap_is "the fetch is given the URL" "$(jq -r .ref "$dir/pr.json")" "$url"
  tap_like "the fetch line names the head and the ticket" "$out" "*at abc123, ticket ABC-1*"
  tap_is "the title record carries the fetched ticket" \
    "$(tail -1 "$SESSION_RENAME_TRANSCRIPT" | jq -r .customTitle)" "ABC-1 PR $url"

  # No argument in a session named after a PR: that PR, said to come from the title.
  run --suffix BOT
  tap_is "no ref in a named session exits 0" "$code" 0
  tap_like "and takes the PR from the session title" "$out" "*(from the session title)*"
  tap_is "--suffix BOT reaches the title" \
    "$(tail -1 "$SESSION_RENAME_TRANSCRIPT" | jq -r .customTitle)" "ABC-1 BOT $url"

  # --no-name writes no record and says so.
  before=$(wc -l < "$SESSION_RENAME_TRANSCRIPT")
  run "$url" --no-name
  tap_is "--no-name exits 0" "$code" 0
  tap_like "--no-name says the title was not written" "$out" "*title: not written (--no-name)*"
  tap_is "--no-name writes no title record" "$(wc -l < "$SESSION_RENAME_TRANSCRIPT")" "$before"

  # A failed fetch leaves the previous pr.json whole and exits 1.
  printf '#!/bin/sh\necho partial; exit 1\n' > "$tmp/fetch"
  run "$url"
  tap_is "a failed fetch exits 1" "$code" 1
  tap_is "a failed fetch leaves pr.json whole" "$(jq -r .head_sha "$dir/pr.json")" abc123
  tap_fails "a failed fetch leaves no temp file" compgen -G "$dir/pr.json.*"

  # A title that cannot be written after a good fetch is exit 4, with the reason.
  printf '#!/bin/sh\necho "{\\"head_sha\\":\\"def456\\",\\"ticket\\":\\"\\"}"\n' > "$tmp/fetch"
  CLAUDE_CODE_SESSION_ID='' SESSION_RENAME_TRANSCRIPT='' run "$url"
  tap_is "a rename outside a session exits 4" "$code" 4
  tap_like "and says the review can go on" "$out" \
    "*title: not written -- *not inside a session* -- the review can go on"
  tap_like "an empty ticket shows as none" "$out" "*ticket none*"

  run "$url" "$url"
  tap_is "two refs exit 1" "$code" 1
  : > "$tmp/not-a-dir"
  GH_PR_WORKDIR_BASE="$tmp/not-a-dir" run "$url"
  tap_is "a working directory that cannot be made exits 1" "$code" 1
  tap_end
fi

start "$@"
