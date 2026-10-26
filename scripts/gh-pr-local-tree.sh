#!/usr/bin/env bash
# Print the clone that has a PR's head branch checked out, so a fix lands on
# that branch without a checkout that would move the tree.
#
# Usage:
#   gh-pr-local-tree.sh <pr-ref>       # prints the directory
#   gh-pr-local-tree.sh --self-test
#
# The clone is the git repository named after the repo, at most three levels
# under the source root, whose origin is the PR's owner/repo. The root is
# $GH_PR_SRC_ROOT, else the project: the directory whose .claude/ holds the
# session history nearest $PWD (project_file.sh session_history.md). The origin decides, not the path: a directory of the same name
# cloned from another org is not the PR's repo.
#
# A clone has no linked worktrees, so the branch is checked out in the clone
# or nowhere.
#
# Exit:
#   0  printed the directory; its HEAD is the PR's head commit
#   3  the branch is not checked out anywhere; the clone's path is on stderr,
#      and `gh pr checkout <n>` there is the way in, after the user agrees
#   4  no clone of the PR's repo under the source root
#   5  printed the directory, but its HEAD is not the PR's head commit; pull
#      or fetch before editing
#   1  the ref or the PR could not be resolved

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_clone() {  # <root> <owner> <repo> -> the clone whose origin is owner/repo
  local root="$1" owner="$2" repo="$3" dir url
  for dir in "$root/$repo" "$root"/*/"$repo" "$root"/*/*/"$repo"; do
    [[ -d "$dir" ]] || continue
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
    if [[ "${url,,}" =~ [:/]${owner,,}/${repo,,}(\.git)?/?$ ]]; then
      printf '%s\n' "$dir"; return 0
    fi
  done
  return 1
}

on_branch() {  # <clone> <branch> -> the clone has the branch checked out
  [[ "$(git -C "$1" branch --show-current)" == "$2" ]]
}

locate() {  # <root> <owner> <repo> <branch> <head_sha> -> dir, exit per header
  local root="$1" owner="$2" repo="$3" branch="$4" sha="$5" clone
  clone=$(find_clone "$root" "$owner" "$repo") || {
    echo "gh-pr-local-tree: no clone of $owner/$repo under $root" >&2; return 4; }
  on_branch "$clone" "$branch" || {
    echo "gh-pr-local-tree: $branch is not checked out; the clone is $clone" >&2; return 3; }
  printf '%s\n' "$clone"
  if [[ "$(git -C "$clone" rev-parse HEAD)" != "$sha" ]]; then
    echo "gh-pr-local-tree: $clone is at $(git -C "$clone" rev-parse --short HEAD), the PR head is ${sha:0:9}" >&2
    return 5
  fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fails=()
  export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
         GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  mkrepo() {  # <dir> <origin-url>
    git init -q -b main "$1"
    git -C "$1" commit -q --allow-empty -m init
    git -C "$1" remote add origin "$2"
  }
  run() {  # <expected-exit> <description> <locate args...>
    local want="$1" desc="$2" got=0; shift 2
    out=$(locate "$@" 2>"$tmp/err") || got=$?
    [[ "$got" == "$want" ]] || fails+=("$desc: exit $got, want $want ($(cat "$tmp/err"))")
  }

  root="$tmp/api"
  mkrepo "$root/web-app" git@github.com:Acme/web-app.git
  rp="$root/web-app"
  main_sha=$(git -C "$rp" rev-parse main)

  run 0 "a branch the main clone has checked out" "$root" Acme web-app main "$main_sha"
  [[ "$out" == "$rp" ]] || fails+=("main clone: printed '$out'")

  git -C "$rp" branch other
  run 3 "a branch checked out nowhere" "$root" Acme web-app other "$main_sha"
  grep -q "$rp" "$tmp/err" || fails+=("checked out nowhere: stderr does not name the clone")

  git -C "$rp" commit -q --allow-empty -m local
  run 5 "a clone behind or ahead of the PR head" "$root" Acme web-app main "$main_sha"
  [[ "$out" == "$rp" ]] || fails+=("stale head: directory not printed")

  mkrepo "$root/2.0/web-hub" https://github.com/AcmeLabs/web-hub.git
  run 0 "a 2.0 clone over HTTPS" "$root" AcmeLabs web-hub main "$(git -C "$root/2.0/web-hub" rev-parse main)"
  [[ "$out" == "$root/2.0/web-hub" ]] || fails+=("2.0 clone: printed '$out'")

  run 4 "a same-named clone from another org" "$root" AcmeLabs web-app main "$main_sha"
  run 4 "no clone at all" "$root" Acme absent main "$main_sha"

  grep -q 'gh-pr-local-tree.sh' "$HERE/../skills/review:bot/SKILL.md" \
    || fails+=("review:bot does not locate the tree through gh-pr-local-tree.sh")

  if ((${#fails[@]})); then
    printf 'gh-pr-local-tree self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-local-tree self-test: PASS (main clone, nowhere, stale head, 2.0 clone, origin decides, absent)"
  exit 0
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pr-ref> | --self-test" >&2
  exit 1
fi

refjson=$("$HERE/gh_pr_ref.py" "$1") || exit 1
head=$(gh pr view "$(jq -er .number <<<"$refjson")" --repo "$(jq -er .slug <<<"$refjson")" \
  --json headRefName,headRefOid --jq '[.headRefName, .headRefOid] | @tsv') || exit 1
IFS=$'\t' read -r branch sha <<<"$head"
if [[ -n "${GH_PR_SRC_ROOT:-}" ]]; then root=$GH_PR_SRC_ROOT
else hist=$("$HERE/project_file.sh" session_history.md) || exit 1; root=$(dirname "$(dirname "$hist")")
fi
locate "$root" \
  "$(jq -er .owner <<<"$refjson")" "$(jq -er .repo <<<"$refjson")" "$branch" "$sha"
