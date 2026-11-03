#!/usr/bin/env bash
# Print (creating it) the private working directory for one PR review.
#
# Every /review:pr step writes its intermediates here — pr.json, pr.diff,
# pr-index.json, review-body.md, review-findings.json — so the files are keyed
# to the PR rather than to fixed /tmp names two concurrent reviews would share.
# Any step can recompute the path from the PR ref alone, which is what lets a
# later step find an earlier step's output without a shell variable surviving
# in between.
#
# Usage:
#   gh-pr-workdir.sh <pr-ref>          # prints the directory, creates it 0700
#   gh-pr-workdir.sh --self-test
#
# <pr-ref> is any form gh_pr_ref.py accepts. The path is
#   ${GH_PR_WORKDIR_BASE:-/tmp/gh-pr-review-$(id -u)}/<owner>-<repo>-<number>
# and both it and its base are mode 700: a PR diff is private-repo source and
# the default base sits in a world-readable /tmp.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workdir() {
  local ref="$1" refjson owner repo number base dir
  # `|| return 1` rather than set -e: set -e is suppressed inside an `if`
  # condition, and this function is called from one in the self-test.
  refjson=$("$HERE/gh_pr_ref.py" "$ref") || return 1
  owner=$(jq -er .owner <<<"$refjson") || return 1
  repo=$(jq -er .repo <<<"$refjson") || return 1
  number=$(jq -er .number <<<"$refjson") || return 1
  base="${GH_PR_WORKDIR_BASE:-/tmp/gh-pr-review-$(id -u)}"
  dir="$base/${owner}-${repo}-${number}"
  mkdir -p "$dir"
  chmod 700 "$base" "$dir"
  printf '%s\n' "$dir"
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  export GH_PR_WORKDIR_BASE="$tmp/base"
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"

  a=$(workdir "Acme/web-app#5236")
  b=$(workdir "https://github.com/Acme/web-app/pull/5236")
  c=$(workdir "Acme/web-app#5237")
  d=$(workdir "AcmeLabs/web-hub#5236")

  tap_is "the slug and URL forms of one PR share a directory" "$b" "$a"
  tap_fails "two PR numbers get two directories" test "$a" = "$c"
  tap_fails "two repos get two directories" test "$a" = "$d"
  tap_run "the directory is created" test -d "$a"
  tap_is "the directory is mode 700" "$(stat -c %a "$a")" 700
  tap_is "the base is mode 700" "$(stat -c %a "$GH_PR_WORKDIR_BASE")" 700
  # Re-running must be idempotent, so a resumed review finds its own files.
  echo marker > "$a/probe"
  tap_is "a second call names the same directory" "$(workdir "Acme/web-app#5236")" "$a"
  tap_run "and keeps its contents" test -f "$a/probe"
  # A ref that names no PR must fail rather than yield a directory.
  tap_fails "a bad ref is refused" workdir "not-a-ref"
  tap_end
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pr-ref> | --self-test" >&2
  exit 1
fi

workdir "$1"
