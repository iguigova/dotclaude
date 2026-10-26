#!/usr/bin/env bash
# Resolve the commit a PR's fetched files come from and print it with the
# directory that holds them, dropping the directory first when it holds another
# commit's files. gh-pr-file.sh and gh-pr-grep.sh both write under it, and both
# call this, so the directory has one owner.
#
# Usage:
#   gh-pr-head-dir.sh <pr-ref>          # prints "<head_sha>\t<workdir>/head"
#   gh-pr-head-dir.sh --base <pr-ref>   # prints "<merge_base_sha>\t<workdir>/base"
#   gh-pr-head-dir.sh --self-test
#
# `<dir>/.sha` records the commit its files came from. A file is cached by
# path, not by content, so it is valid for one commit only: when the commit has
# moved since the stamp was written, or there is no stamp, the directory is
# removed whole rather than left holding a mix of two trees. A caller that writes into the directory
# without calling this first leaves the stamp naming an older commit, and the
# next caller deletes its files.
#
# The head is always the PR's live head, from `gh pr view`. When
# `<workdir>/pr.json` names a different one, this refuses rather than choose:
# for the PR under review the diff describes pr.json's commit and every file
# must come from that one too, and for any other PR a pr.json left by an
# earlier review is simply stale. Either way re-running gh-pr-fetch.sh is the
# fix, and serving one of the two commits silently is the defect.
#
# The merge base is the commit GitHub's compare of the PR's recorded base
# commit (`baseRefOid`) with its head reports, so it needs no local clone. The
# recorded commit, not the base branch's name: once a PR is merged with a merge
# commit, the branch contains the head, the branch's merge base with the head
# is the head itself, and every file would read as unchanged. The recorded
# commit stays fixed after the merge. A file at the merge base is the one the
# PR started from: what is wrong in it was wrong before the PR.
#
# Exits non-zero if the ref is unrecognized, the commit cannot be resolved, or
# pr.json names a head other than the live one.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pinned_head() {  # <pr.json head or ""> <live head> -> the live head, or refuse
  local cached="$1" live="$2"
  if [[ -n "$cached" && "$cached" != "$live" ]]; then
    echo "pr.json is at ${cached:0:9}, the PR head is ${live:0:9} — re-run gh-pr-fetch.sh" >&2
    return 1
  fi
  printf '%s\n' "$live"
}

stamped_dir() {  # <dir> <sha> -> "<sha>\t<dir>", the dir emptied unless it is this sha's
  local dir="$1" sha="$2"
  # A directory with no stamp holds files of an unknown commit, so it goes too.
  if [[ -d "$dir" ]] && [[ "$(cat "$dir/.sha" 2>/dev/null)" != "$sha" ]]; then
    rm -rf "$dir"
  fi
  mkdir -p "$dir"
  printf '%s\n' "$sha" > "$dir/.sha"
  printf '%s\t%s\n' "$sha" "$dir"
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fails=()
  dir="$tmp/head"

  # pr.json absent or at the live head gives the live head; at another commit
  # it is refused, and the refusal names both.
  [[ "$(pinned_head "" bbb)" == bbb ]] || fails+=("no pr.json: did not take the live head")
  [[ "$(pinned_head bbb bbb)" == bbb ]] || fails+=("pr.json at the live head: not accepted")
  if pinned_head aaa bbb >/dev/null 2>"$tmp/err"; then
    fails+=("pr.json at another commit was served instead of refused")
  fi
  grep -q 'aaa.*bbb' "$tmp/err" || fails+=("the refusal does not name both commits: $(cat "$tmp/err")")

  IFS=$'\t' read -r sha got <<<"$(stamped_dir "$dir" aaa)"
  [[ "$sha" == aaa && "$got" == "$dir" ]] || fails+=("first call: got '$sha' '$got'")
  [[ "$(cat "$dir/.sha")" == aaa ]] || fails+=("stamp not written")

  # Same commit: a file fetched by one caller survives the next caller.
  mkdir -p "$dir/lib"; echo x > "$dir/lib/a.dart"
  stamped_dir "$dir" aaa >/dev/null
  [[ -f "$dir/lib/a.dart" ]] || fails+=("same commit dropped a cached file")

  # Moved commit: the old commit's files go, and the stamp names the new one.
  stamped_dir "$dir" bbb >/dev/null
  [[ ! -e "$dir/lib/a.dart" ]] || fails+=("moved commit kept the old commit's file")
  [[ "$(cat "$dir/.sha")" == bbb ]] || fails+=("moved commit: stamp not rewritten")

  # An unstamped directory, as an older version of this helper left one, holds
  # files of no known commit and is dropped rather than adopted.
  mkdir -p "$tmp/old/lib"; echo z > "$tmp/old/lib/b.py"; echo bbb > "$tmp/old/.head_sha"
  stamped_dir "$tmp/old" bbb >/dev/null
  [[ ! -e "$tmp/old/lib/b.py" ]] || fails+=("an unstamped directory was adopted with its files")

  # A file written at the new commit after the stamp was refreshed must
  # survive a later call at that same commit.
  echo y > "$dir/README.md"
  stamped_dir "$dir" bbb >/dev/null
  [[ -f "$dir/README.md" ]] || fails+=("file fetched at the current commit was dropped by the next caller")

  for caller in gh-pr-file.sh gh-pr-grep.sh; do
    grep -q 'gh-pr-head-dir.sh' "$HERE/$caller" || fails+=("$caller does not resolve its directory through gh-pr-head-dir.sh")
  done
  grep -q 'merge_base_commit' "${BASH_SOURCE[0]}" || fails+=("--base does not read compare's merge_base_commit")
  # The base branch's name moves past a merged PR's head; only the recorded
  # base commit keeps a merged PR's merge base where the PR started.
  grep -qF 'compare/$base_oid...' "${BASH_SOURCE[0]}" || fails+=("--base compares the base branch's name, not the recorded base commit")

  if ((${#fails[@]})); then
    printf 'gh-pr-head-dir self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-head-dir self-test: PASS (stale pr.json refused, live head taken, stamp written, kept at the same commit, dropped whole on a moved one or with no stamp, both callers routed through it, the merge base taken from the recorded base commit)"
  exit 0
fi

MODE="head"
if [[ "${1:-}" == "--base" ]]; then MODE="base"; shift; fi
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--base] <pr-ref> | --self-test" >&2
  exit 1
fi

refjson=$("$HERE/gh_pr_ref.py" "$1") || exit 1
slug=$(jq -er .slug <<<"$refjson")
workdir=$("$HERE/gh-pr-workdir.sh" "$1")
live=$(gh pr view "$(jq -er .number <<<"$refjson")" --repo "$slug" \
  --json headRefOid,baseRefOid --jq '[.headRefOid, .baseRefOid] | @tsv') || exit 1
IFS=$'\t' read -r live_head base_oid <<<"$live"
[[ -n "$live_head" ]] || { echo "could not resolve the head of $1" >&2; exit 1; }

cached=""
if [[ -s "$workdir/pr.json" ]]; then
  cached=$(jq -r '.head_sha // empty' "$workdir/pr.json")
fi
head=$(pinned_head "$cached" "$live_head") || exit 1

if [[ "$MODE" == head ]]; then
  stamped_dir "$workdir/head" "$head"
else
  base=$(gh api "repos/$slug/compare/$base_oid...$head" --jq .merge_base_commit.sha) || exit 1
  [[ -n "$base" ]] || { echo "could not resolve the merge base of $1" >&2; exit 1; }
  stamped_dir "$workdir/base" "$base"
fi
