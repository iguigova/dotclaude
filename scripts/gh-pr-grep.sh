#!/usr/bin/env bash
# List or search the PR's repository **at its head commit**. Used by /review:pr
# for the codebase-consistency step, where a finding turns on how the rest of
# the repo does the same thing the diff does.
#
# Usage:
#   gh-pr-grep.sh <pr-ref> --list [<glob>]        # paths at head_sha
#   gh-pr-grep.sh <pr-ref> <ere-pattern> [<glob>] # grep -nE over those paths
#   gh-pr-grep.sh --self-test
#
# Output: `--list` prints one repo-relative path per line; a search prints
# `path:line:text`, the shape grep -n prints, so a hit can be cited directly.
#
# Why this exists rather than Grep/Glob or an Explore agent: those read the
# working tree, which is not the PR. The tree sits on whatever branch the
# session left it on, and the repo may not be cloned at all — in which case a
# search returns "no matches", which reads as "checked, consistent" and is the
# worst possible answer. Everything here comes from head_sha or it fails loudly.
#
# <glob> restricts the search to matching paths (shell glob against the whole
# repo-relative path, e.g. 'apps/**' or '*.py'). Omitted, it defaults to the
# extensions the PR's own diff touches, which is the comparison the consistency
# step is actually making. Pass '*' to mean every file.
#
# Fetched blobs are cached under `<workdir>/head/<path>` — the same layout
# gh-pr-file.sh uses, so a grep hit is already on disk to read in full. The
# directory belongs to gh-pr-head-dir.sh, which drops it whole when the head
# moves.
#
# A search fetches one blob per candidate path, so it refuses above --max
# (default 120) rather than pulling a whole repo; narrow the glob instead. The
# tree listing is one call and is never capped.
#
# A search exits like grep: 0 when a line matched, 1 when every candidate was
# read and none matched. 1 means exactly that and nothing else; every other
# outcome that is not a match exits 2:
#   - a candidate could not be fetched: the matches it did find are printed,
#     then each failed path with gh's error. Fetched blobs stay cached, so a
#     re-run fetches only the paths that failed;
#   - the candidates exceed the cap, the ref is unrecognized, the tree listing
#     failed or is truncated (it would be silently short), or no path matches
#     the glob;
#   - any other step failed.
# A scan with a hole in it, or one that never ran, is never reported as "no
# match". `--list` exits 0 with its paths, or 2.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_FILES_DEFAULT=120

# Derive `*.ext` globs from a list of repo paths. This is what makes a bare
# search compare like against like: a Python PR searches Python files.
globs_from_paths() {  # paths on stdin -> one glob per line
  sed -n 's#.*/##; s#^[^.]*$##; s#.*\.#*.#p' | sort -u | grep -v '^\*\.$' || true
}

# Match a path against a newline-separated glob list. A glob with no '/' is
# matched against the basename too, so '*.py' finds 'apps/libs/x.py'.
path_matches() {  # <path> <globs>
  local p="$1" g
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    # shellcheck disable=SC2254  # $g is a glob on purpose
    case "$p" in
      $g) return 0 ;;
    esac
    if [[ "$g" != */* ]]; then
      # shellcheck disable=SC2254
      case "${p##*/}" in
        $g) return 0 ;;
      esac
    fi
  done <<<"$2"
  return 1
}

# Keep the paths a glob list matches. `|| continue` rather than `&& printf`: a
# while loop exits with its last iteration's status, so a final non-matching
# path made the command substitution fail under `set -e` and discarded every
# match found before it.
candidates() {  # <newline-separated paths> <newline-separated globs>
  local p
  while IFS= read -r p; do
    path_matches "$p" "$2" || continue
    printf '%s\n' "$p"
  done <<<"$1"
}

# Write one blob at head into <dest>; on failure print gh's error and return
# non-zero. Reads RSLUG and HEAD_SHA. The self-test replaces it.
fetch_blob() {  # <path> <dest>
  local err
  if ! err=$(gh api "repos/$RSLUG/contents/$1?ref=$HEAD_SHA" \
      -H "Accept: application/vnd.github.raw" 2>&1 > "$2"); then
    printf '%s\n' "${err:-gh api exited non-zero with no message}" | head -1
    return 1
  fi
}

# grep -nE <pattern> over each candidate, fetching the ones not cached under
# HEADDIR. Returns 0 on a match, 1 when every file was read and none matched,
# 2 when any fetch failed. A failed fetch must not fall through to the 0/1
# verdict: "no match" over a scan with a hole in it is a false clean result.
search_blobs() {  # <pattern> <newline-separated paths>
  local pattern="$1" path dest why rc=1
  local -a unread=()
  while IFS= read -r path; do
    dest="$HEADDIR/$path"
    if [[ ! -s "$dest" ]]; then
      mkdir -p "$(dirname "$dest")"
      if ! why=$(fetch_blob "$path" "$dest"); then
        rm -f "$dest"
        echo "could not fetch at $HEAD_SHA: $path — $why" >&2
        unread+=("$path")
        continue
      fi
    fi
    if grep -nE "$pattern" "$dest" 2>/dev/null | sed "s#^#$path:#"; then
      rc=0
    fi
  done <<<"$2"
  if ((${#unread[@]})); then
    echo "${#unread[@]} of $(wc -l <<<"$2") files were not read, so the result above is incomplete; re-run to fetch only those" >&2
    return 2
  fi
  return "$rc"
}

# Refuse a search over more than <max> candidates: one blob fetch each.
check_cap() {  # <count> <max> <globs>
  (( $1 <= $2 )) && return 0
  echo "$1 files match $(tr '\n' ' ' <<<"$3") — above the $2 cap." >&2
  echo "Narrow the glob (e.g. 'apps/libs/**') or raise GH_PR_GREP_MAX deliberately." >&2
  echo "Use --list to see what matched." >&2
  return 2
}

if [[ "${1:-}" == "--self-test" ]]; then
  fails=()

  # Every refusal is 2: a 1 there reads as "searched, nothing found".
  check_cap 121 120 '*.ts' 2>/dev/null && st=0 || st=$?
  [[ "$st" == 2 ]] || fails+=("over-cap refusal exited $st, want 2")
  check_cap 120 120 '*.ts' 2>/dev/null || fails+=("a count at the cap was refused")
  "${BASH_SOURCE[0]}" not-a-ref needle >/dev/null 2>&1 && st=0 || st=$?
  [[ "$st" == 2 ]] || fails+=("unrecognized ref exited $st, want 2")
  "${BASH_SOURCE[0]}" only-one-arg >/dev/null 2>&1 && st=0 || st=$?
  [[ "$st" == 2 ]] || fails+=("usage error exited $st, want 2")

  # search_blobs against a stub fetch: a.ts holds a match, b.ts fetches with no
  # match, bad.ts fails. The exit must be 2 with a.ts's match still printed,
  # and 1/0 only once every file was read.
  HEADDIR=$(mktemp -d); HEAD_SHA=deadbeef
  trap 'rm -rf "$HEADDIR"' EXIT
  fetch_blob() {
    case "$1" in
      a.ts) echo 'needle here' > "$2" ;;
      b.ts) echo 'nothing' > "$2" ;;
      *) echo 'HTTP 502: Bad Gateway'; return 1 ;;
    esac
  }
  out=$(search_blobs needle $'a.ts\nbad.ts\nb.ts' 2>"$HEADDIR/err") && st=0 || st=$?
  [[ "$st" == 2 ]] || fails+=("search with a failed fetch exited $st, want 2")
  [[ "$out" == "a.ts:1:needle here" ]] || fails+=("search with a failed fetch printed '$out', want a.ts's match")
  grep -q 'bad.ts — HTTP 502' "$HEADDIR/err" || fails+=("failed fetch did not report the path with gh's error")
  [[ ! -e "$HEADDIR/bad.ts" ]] || fails+=("failed fetch left a cache file behind")
  search_blobs needle 'b.ts' >/dev/null 2>&1 && st=0 || st=$?
  [[ "$st" == 1 ]] || fails+=("clean no-match exited $st, want 1")
  search_blobs needle $'b.ts\na.ts' >/dev/null 2>&1 && st=0 || st=$?
  [[ "$st" == 0 ]] || fails+=("match exited $st, want 0")

  got=$(printf 'apps/x.py\nlib/y.py\nsrc/a.tsx\nREADME.md\nMakefile\n' | globs_from_paths | tr '\n' ' ')
  [[ "$got" == "*.md *.py *.tsx " ]] || fails+=("globs_from_paths: got '$got', want '*.md *.py *.tsx '")

  # An extensionless path contributes no glob rather than a bare '*.'; a '*.'
  # would match nothing and silently shrink the candidate set.
  got=$(printf 'Makefile\nDockerfile\n' | globs_from_paths | tr '\n' ' ')
  [[ "$got" == "" ]] || fails+=("extensionless paths yielded globs: '$got'")

  m()  { path_matches "$1" "$2" || fails+=("should match: $1 vs $2"); }
  nm() { path_matches "$1" "$2" && fails+=("should not match: $1 vs $2"); return 0; }
  m  "apps/libs/x.py"   '*.py'
  m  "x.py"             '*.py'
  m  "apps/libs/x.py"   'apps/*'
  m  "src/a.tsx"        $'*.py\n*.tsx'
  nm "apps/libs/x.py"   '*.ts'
  nm "docs/readme.md"   'apps/*'
  m  "anything/at/all"  '*'

  # The last path must be a miss: that is the only arrangement the `&& printf`
  # form got wrong, and it lost the matches before it as well as its own status.
  got=$(candidates $'apps/x.py\nREADME.md' '*.py') \
    || fails+=("candidates exited non-zero because the last path missed")
  [[ "$got" == "apps/x.py" ]] || fails+=("candidates: got '$got', want 'apps/x.py'")

  # The whole value of the helper is the pin; losing it reintroduces the
  # working-tree bug it exists to prevent.
  grep -q 'ref=\$HEAD_SHA' "${BASH_SOURCE[0]}" || fails+=("blob fetch does not pin ?ref=\$HEAD_SHA")
  grep -q 'recursive=1'    "${BASH_SOURCE[0]}" || fails+=("tree listing is not recursive")
  grep -q 'truncated'      "${BASH_SOURCE[0]}" || fails+=("does not check the tree's truncated flag")
  grep -q 'vnd.github.raw' "${BASH_SOURCE[0]}" || fails+=("not requesting raw media type (base64 caps at 1MB)")
  "$HERE/gh_pr_ref.py" --self-test >/dev/null 2>&1 || fails+=("gh_pr_ref.py self-test fails")

  if ((${#fails[@]})); then
    printf 'gh-pr-grep self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-grep self-test: PASS (search exits 2 with partial matches on a failed fetch, 1 on a clean miss, 0 on a match; over-cap, bad-ref and usage refusals exit 2; glob derivation over 2 cases, path matching over 7, candidate filter survives a trailing miss, head_sha pin and truncation check asserted)"
  exit 0
fi

# From here on an unexpected failure exits 2, never set -e's 1 (which would
# read as a clean miss). Statuses consumed by `||`, `&&` and `if` do not fire it.
trap 'exit 2' ERR

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <pr-ref> --list [<glob>] | <pr-ref> <ere-pattern> [<glob>] | --self-test" >&2
  exit 2
fi

REF="$1"; shift
MODE="$1"; shift
GLOB="${1:-}"
MAX_FILES="${GH_PR_GREP_MAX:-$MAX_FILES_DEFAULT}"

REFJSON=$("$HERE/gh_pr_ref.py" "$REF") || exit 2
RSLUG=$(jq -er .slug <<<"$REFJSON")
WORKDIR=$("$HERE/gh-pr-workdir.sh" "$REF")

# The head directory's owner resolves head_sha and drops files fetched at an
# older commit, so a cached blob never mixes two trees.
HEADOUT=$("$HERE/gh-pr-head-dir.sh" "$REF") || exit 2
IFS=$'\t' read -r HEAD_SHA HEADDIR <<<"$HEADOUT"

# Written beside the cache and moved in only on success: gh prints an error
# body to stdout, and a cached error body would be read as the tree forever.
TREE="$WORKDIR/tree-$HEAD_SHA.json"
if [[ ! -s "$TREE" ]]; then
  if ! gh api "repos/$RSLUG/git/trees/$HEAD_SHA?recursive=1" > "$TREE.part"; then
    rm -f "$TREE.part"
    echo "could not list the tree of $RSLUG@$HEAD_SHA" >&2
    exit 2
  fi
  mv "$TREE.part" "$TREE"
fi
# A truncated tree lists some of the repo and says so only in a flag. Treating
# it as the whole repo is how a consistency check reports "no precedent found"
# for a precedent that exists.
if [[ "$(jq -r '.truncated // false' "$TREE")" == "true" ]]; then
  echo "tree listing for $RSLUG@$HEAD_SHA is truncated — narrow with a glob and re-run; a partial listing would under-report precedent" >&2
  exit 2
fi

ALL_PATHS=$(jq -r '.tree[] | select(.type=="blob") | .path' "$TREE")

if [[ -z "$GLOB" ]]; then
  if [[ -s "$WORKDIR/pr.json" ]]; then
    GLOBS=$(jq -r '.meta.files[].path' "$WORKDIR/pr.json" | globs_from_paths)
  else
    GLOBS='*'
  fi
  [[ -n "$GLOBS" ]] || GLOBS='*'
else
  GLOBS="$GLOB"
fi

CANDIDATES=$(candidates "$ALL_PATHS" "$GLOBS")

if [[ -z "$CANDIDATES" ]]; then
  echo "no path at $HEAD_SHA matches: $(tr '\n' ' ' <<<"$GLOBS")" >&2
  exit 2
fi

if [[ "$MODE" == "--list" ]]; then
  printf '%s\n' "$CANDIDATES"
  exit 0
fi

check_cap "$(wc -l <<<"$CANDIDATES")" "$MAX_FILES" "$GLOBS" || exit 2

# `|| rc=$?` so a clean miss's 1 is returned as 1, not turned into 2 by the trap.
rc=0
search_blobs "$MODE" "$CANDIDATES" || rc=$?
exit "$rc"
