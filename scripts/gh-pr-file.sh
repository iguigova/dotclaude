#!/usr/bin/env bash
# Fetch one or more repo paths **at the PR's head commit** into the per-PR
# working directory and print where each landed. Used by /review:pr whenever a
# review claim depends on code outside the diff. With --base, fetch them at the
# PR's merge base instead, which /review:bot uses to tell what the PR broke
# from what was broken before it.
#
# Usage:
#   gh-pr-file.sh [--base] <pr-ref> <path> [<path>...]
#   gh-pr-file.sh --self-test
#
# The working tree is not the PR. A local checkout sits on whatever branch the
# session left it on, so reading `apps/<name>.py` from disk to judge a PR can read
# entirely different code and produce a confident, wrong finding. Every file
# this prints came from `head_sha`, so a line number quoted from it is the line
# number the author and GitHub will see.
#
# Files land under `<workdir>/head/<path>` (or `<workdir>/base/<path>`),
# keeping their repo-relative layout, and the local path is printed one per
# line in argument order. A path missing at the merge base is a file the PR
# added, reported as not found like any other missing path. Re-fetching is
# cheap and always overwrites, so a second call after the author pushes cannot
# leave a stale copy behind.
#
# The commit and the directory come from gh-pr-head-dir.sh, which both this and
# gh-pr-grep.sh call, so neither deletes what the other just fetched.
#
# Exit 1: the ref is unrecognized, or a path is unsafe or absent at the commit
# (GitHub answered 404). Exit 2: a fetch failed for any other reason — auth,
# network, rate limit — so whether that path exists is unknown. Exit 2 wins
# when both occur.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A path is the repo-relative one the diff names. Anything that could escape the
# working directory is refused rather than normalised: the caller has made a
# mistake, and silently rewriting it would hide which file was actually read.
path_is_safe() {  # <path>
  local p="$1"
  [[ -n "$p" ]]            || return 1
  [[ "$p" != /* ]]         || return 1
  [[ "$p" != *$'\n'* ]]    || return 1
  local IFS=/ seg
  for seg in $p; do
    [[ "$seg" != ".." ]] || return 1
  done
  return 0
}

# A missing path and a failed fetch both exit gh non-zero; only GitHub's 404
# says the path is absent at the commit. Anything else — auth, network, rate
# limit — leaves the answer unknown, and reporting it as "not found" tells a
# caller the file does not exist.
fetch_failure() {  # <gh stderr> -> missing | failed
  [[ "$1" == *"(HTTP 404)"* ]] && echo missing || echo failed
}

if [[ "${1:-}" == "--self-test" ]]; then
  fails=()
  [[ "$(fetch_failure 'gh: Not Found (HTTP 404)')" == missing ]] \
    || fails+=("a 404 is not classed missing")
  [[ "$(fetch_failure 'proxyconnect tcp: connection refused')" == failed ]] \
    || fails+=("a network error is not classed failed")
  [[ "$(fetch_failure 'gh: Bad credentials (HTTP 401)')" == failed ]] \
    || fails+=("a 401 is not classed failed")
  ok()  { path_is_safe "$1" || fails+=("should accept: $1"); }
  bad() { path_is_safe "$1" && fails+=("should reject: $1"); return 0; }
  ok  "apps/libs/services/x.py"
  ok  "README.md"
  ok  "a/b..c/d.py"            # '..' only inside a segment is an ordinary name
  bad "/etc/passwd"
  bad "../outside.py"
  bad "apps/../../etc/passwd"
  bad "apps/libs/../../../x"
  bad ""
  # The point of the helper is the ref; losing it would silently reintroduce
  # exactly the working-tree bug it exists to prevent.
  grep -q 'ref=' "${BASH_SOURCE[0]}" || fails+=("the contents call does not pin ?ref=")
  grep -q 'vnd.github.raw' "${BASH_SOURCE[0]}" || fails+=("not requesting raw media type (base64 caps at 1MB)")
  # --base is only a merge-base fetch if the directory owner is told so.
  grep -qF "gh-pr-head-dir.sh\" \"\${AT[@]}\"" "${BASH_SOURCE[0]}" || fails+=("--base is not passed to gh-pr-head-dir.sh")
  "$HERE/gh_pr_ref.py" --self-test >/dev/null 2>&1 || fails+=("gh_pr_ref.py self-test fails")
  if ((${#fails[@]})); then
    printf 'gh-pr-file self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-file self-test: PASS (404 vs other fetch failures, path safety over 8 cases, ref pinning, --base routing and raw media type asserted)"
  exit 0
fi

AT=()
if [[ "${1:-}" == "--base" ]]; then AT=(--base); shift; fi
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 [--base] <pr-ref> <path> [<path>...] | --self-test" >&2
  exit 1
fi

REF="$1"; shift

REFJSON=$("$HERE/gh_pr_ref.py" "$REF") || exit 1
OWNER=$(jq -er .owner <<<"$REFJSON")
REPO=$(jq -er .repo <<<"$REFJSON")
RSLUG="${OWNER}/${REPO}"

# The directory's owner resolves the commit and drops files fetched at another
# one, so a file written here survives gh-pr-grep.sh's next call.
DIROUT=$("$HERE/gh-pr-head-dir.sh" "${AT[@]}" "$REF") || exit 1
IFS=$'\t' read -r SHA DIR <<<"$DIROUT"

rc=0
for path in "$@"; do
  if ! path_is_safe "$path"; then
    echo "unsafe or empty path refused: $path" >&2; rc=1; continue
  fi
  dest="$DIR/$path"
  mkdir -p "$(dirname "$dest")"
  if err=$(gh api "repos/$RSLUG/contents/$path?ref=$SHA" \
             -H "Accept: application/vnd.github.raw" 2>&1 > "$dest"); then
    echo "$dest"
  else
    rm -f "$dest"
    if [[ "$(fetch_failure "$err")" == missing ]]; then
      echo "not found at $SHA: $path" >&2; [[ $rc -eq 2 ]] || rc=1
    else
      echo "fetch failed at $SHA: $path: $err" >&2; rc=2
    fi
  fi
done
exit "$rc"
