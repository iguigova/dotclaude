#!/usr/bin/env bash
# git_fact.sh — the verify command for a memory fact claiming something about a
# file in a repository. Reads each file at a named ref and matches a pattern.
#
# One command, one exit code, so a verdict never depends on how a check was spelled:
#   0   every pattern matched
#   1   a file was read and its pattern is absent
#   75  the repo, the ref, or a path is not there — nothing learned
#
# 75 is EX_TEMPFAIL: memory_check.sh reports it unchecked and never deletes on it.
# A path absent at a ref says nothing about the claim, because the file may have moved.
#
# Patterns are basic regular expressions, as `grep -q` reads them.
#
# Usage:
#   git_fact.sh <repo> <ref> <path> <pattern> [<path> <pattern> ...]
#   git_fact.sh --self-test
# <repo> is relative to the working directory, or absolute. memory_fact.sh and
# memory_check.sh run every verify from the project root.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

ROOT="$PWD"

# Every exit is one of the three the header names.
gf_check() {  # REPO REF PATH PATTERN [PATH PATTERN ...]
  local repo="$1" ref="$2" dir path pat content
  shift 2
  dir="$repo"; [[ "$dir" == /* ]] || dir="$ROOT/$repo"

  [[ -d "$dir/.git" ]] || { echo "git_fact: no repository at $repo; nothing learned" >&2; exit 75; }
  git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 \
    || { echo "git_fact: $repo has no ref $ref; nothing learned" >&2; exit 75; }

  while (( $# )); do
    path="$1"; pat="$2"; shift 2
    # Captured, not piped: a pipeline's verdict is the reader's, and `grep -q`
    # kills its producer with SIGPIPE.
    content=$(git -C "$dir" show "$ref:$path" 2>/dev/null) \
      || { echo "git_fact: $path is not at $ref in $repo; nothing learned" >&2; exit 75; }
    grep -q -- "$pat" <<<"$content" \
      || { echo "git_fact: $repo $ref:$path does not match: $pat" >&2; exit 1; }
  done
}

# ---------------------------------------------------------------- self-test
# A real repository: a path absent at a ref exists only in git.
self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local d self out
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN

  git init -q "$d/repo"
  printf 'PLUGIN_TABLE: dict\nMAX(t.peak_count)\n' > "$d/repo/kept.py"
  git -C "$d/repo" add kept.py
  git -C "$d/repo" -c user.email=t@t -c user.name=t commit -qm init

  run() { "$self" "$@" >/dev/null 2>&1; echo $?; }
  check() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }

  check "a matching pattern holds" 0 \
    "$(run "$d/repo" HEAD kept.py '^PLUGIN_TABLE: dict')"
  check "two pairs both matching hold" 0 \
    "$(run "$d/repo" HEAD kept.py '^PLUGIN_TABLE' kept.py 'peak_count')"
  check "a parenthesised pattern is literal, not a group" 0 \
    "$(run "$d/repo" HEAD kept.py 'MAX(t.peak_count)')"
  check "a file read whose pattern is absent contradicts" 1 \
    "$(run "$d/repo" HEAD kept.py 'NOT_IN_THE_FILE')"
  check "a path absent at the ref learns nothing" 75 \
    "$(run "$d/repo" HEAD gone.py 'anything')"
  check "a second pair whose path is gone learns nothing" 75 \
    "$(run "$d/repo" HEAD kept.py '^PLUGIN_TABLE' gone.py 'x')"
  check "an unknown ref learns nothing" 75 \
    "$(run "$d/repo" origin/nope kept.py 'x')"
  check "a missing repository learns nothing" 75 \
    "$(run "$d/nosuchrepo" HEAD kept.py 'x')"
  check "too few arguments is a usage error" 2 "$(run "$d/repo" HEAD kept.py)"
  check "an odd trailing argument is a usage error" 2 \
    "$(run "$d/repo" HEAD kept.py 'x' extra)"

  out=$("$self" "$d/repo" HEAD gone.py 'x' 2>&1)
  check "and says which path was not there" 0 \
    "$([[ "$out" == *"gone.py is not at HEAD"* ]] && echo 0 || echo 1)"
}

# ---------------------------------------------------------------- main
if [[ "${1:-}" == "--self-test" ]]; then self_test; tap_end; fi
(( $# >= 4 && ($# - 2) % 2 == 0 )) || {
  echo "usage: git_fact.sh <repo> <ref> <path> <pattern> [<path> <pattern> ...]" >&2; exit 2; }
gf_check "$@"
