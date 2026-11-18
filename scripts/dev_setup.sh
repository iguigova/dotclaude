#!/usr/bin/env bash
# dev_setup.sh — the tree-is-current probe. Reports the git state a repo
# stands in: branch, drift from origin's default branch, uncommitted work.
# Read-only apart from `git fetch`. Universal across projects.
#
# Usage:
#   dev_setup.sh [path] [--dry-run] [--self-test]
#
#   --dry-run    report from local refs only; no fetch
#   --self-test  run built-in checks against scratch repos
#
# Exit:
#   0  ready to work
#   1  a decision is needed first (each one is printed)
#   2  not a git repo

set -uo pipefail

resolve_base() {
  local root=$1 b c
  b=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  b=${b#origin/}
  if [[ -z "$b" ]]; then
    for c in main master; do
      git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$c" && { b=$c; break; }
    done
  fi
  if [[ -z "$b" ]]; then
    for c in main master; do
      git -C "$root" show-ref --verify --quiet "refs/heads/$c" && { b=$c; break; }
    done
  fi
  printf '%s\n' "$b"
}

probe() {
  local target=$1 fetch=$2
  local root branch base baseref ahead behind dirty untracked

  root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || {
    echo "dev_setup: not a git repo: $target" >&2
    return 2
  }

  [[ "$fetch" == yes ]] && git -C "$root" fetch --quiet --prune 2>/dev/null

  branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)
  base=$(resolve_base "$root")
  baseref=$(base_ref "$root" "$base")
  read -r ahead behind < <(drift "$root" "$baseref")

  dirty=$(git -C "$root" status --porcelain 2>/dev/null | grep -vc '^??')
  untracked=$(git -C "$root" status --porcelain 2>/dev/null | grep -c '^??')

  printf 'repo      %s\n' "$root"
  printf 'branch    %s\n' "$branch"
  printf 'base      %s\n' "${baseref:-<none>}"
  if [[ -n "$baseref" ]]; then
    printf 'drift     %s ahead, %s behind%s\n' "$ahead" "$behind" \
      "$([[ "$fetch" == yes ]] || echo '  (local refs; --dry-run)')"
  fi
  printf 'uncommit  %s modified, %s untracked\n' "$dirty" "$untracked"

  echo
  decide "$branch" "$behind" "$baseref"
}

# base_ref ROOT BASE — the ref BASE is read at: origin's, else the local
# branch, else nothing.
base_ref() {
  [[ -n "$2" ]] || return 0
  if git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2"; then
    printf 'origin/%s\n' "$2"
  elif git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then
    printf '%s\n' "$2"
  fi
}

# drift ROOT BASEREF — "<ahead> <behind>" of HEAD against BASEREF; 0 0 with none.
drift() {
  local counts ahead behind
  [[ -n "$2" ]] || { echo "0 0"; return 0; }
  counts=$(git -C "$1" rev-list --left-right --count "$2...HEAD" 2>/dev/null)
  behind=${counts%%[[:space:]]*}
  ahead=${counts##*[[:space:]]}
  [[ "$behind" =~ ^[0-9]+$ ]] || behind=0
  [[ "$ahead"  =~ ^[0-9]+$ ]] || ahead=0
  printf '%s %s\n' "$ahead" "$behind"
}

# decide BRANCH BEHIND BASEREF — "ready", else each decision needed first, exit 1.
decide() {
  local -a decisions=()
  [[ "$1" == HEAD ]] && decisions+=("detached HEAD — check out a branch before working")
  (( $2 > 0 )) &&
    decisions+=("behind $3 by $2 — branch off the latest base or rebase")
  if (( ${#decisions[@]} == 0 )); then
    echo "ready"
    return 0
  fi
  printf 'decide first:\n'
  printf '  - %s\n' "${decisions[@]}"
  return 1
}

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local tmp rc
  tmp=$(mktemp -d) || return 2
  local -a G=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)

  git "${G[@]}" -c init.defaultBranch=main init --bare --quiet "$tmp/remote.git"
  git "${G[@]}" clone --quiet "$tmp/remote.git" "$tmp/w" 2>/dev/null
  local w="$tmp/w"
  echo a > "$w/a"; git "${G[@]}" -C "$w" add -A; git "${G[@]}" -C "$w" commit --quiet -m A
  git "${G[@]}" -C "$w" push --quiet -u origin HEAD:main 2>/dev/null
  git "${G[@]}" -C "$w" checkout --quiet -B main
  local first; first=$(git -C "$w" rev-parse HEAD)
  echo b > "$w/b"; git "${G[@]}" -C "$w" add -A; git "${G[@]}" -C "$w" commit --quiet -m B
  git "${G[@]}" -C "$w" push --quiet origin main 2>/dev/null
  git "${G[@]}" -C "$w" fetch --quiet 2>/dev/null

  check() {  # name expected_rc [args…]
    local name=$1 want=$2; shift 2
    probe "$@" >/dev/null 2>&1; rc=$?
    tap_is "$name" "exit $rc" "exit $want"
  }

  check "default branch at tip → ready" 0 "$w" no
  git "${G[@]}" -C "$w" checkout --quiet -b feat
  check "feature branch at tip → ready" 0 "$w" no
  check "feature branch, with fetch → ready" 0 "$w" yes
  git "${G[@]}" -C "$w" checkout --quiet -b stale "$first"
  check "behind base → decide"        1 "$w" no
  git "${G[@]}" -C "$w" checkout --quiet feat
  echo dirt > "$w/a"
  check "dirty tree alone → ready"    0 "$w" no
  git "${G[@]}" -C "$w" checkout --quiet --detach
  check "detached HEAD → decide"      1 "$w" no
  check "not a repo → exit 2"         2 "$tmp" no

  # probe is exercised above by calling it; the argument loop below is what a
  # user actually reaches, and it decides which repo is read and whether the
  # report describes fetched refs or stale ones.
  # The checks above leave the tree detached; these assert the CLI, not that state.
  git "${G[@]}" -C "$w" checkout --quiet feat
  cli() {  # name expected_rc [args…]
    local name=$1 want=$2; shift 2
    "$0" "$@" >/dev/null 2>&1; rc=$?
    tap_is "$name" "exit $rc" "exit $want"
  }
  cli "unknown argument → exit 2" 2 --bogus
  cli "a path that is not a repo → exit 2" 2 "$tmp"
  cli "a path argument is honoured" 0 "$w" --dry-run
  # Captured, then matched: piped into grep -q under pipefail, the writer is cut
  # off by SIGPIPE when grep stops reading, and the case fails on a match.
  out=$("$0" "$w" --dry-run 2>/dev/null)
  tap_like "--dry-run says the refs are local" "$out" "*(local refs; --dry-run)*"
  out=$("$0" "$w" 2>/dev/null)
  tap_fails "a fetching run does not claim local refs" grep -qF '(local refs' <<<"$out"
  local got want
  got=$("$0" "$w" --dry-run 2>/dev/null | sed -n 's/^repo  *//p')
  want=$(git -C "$w" rev-parse --show-toplevel)
  tap_is "it reports the repo it was pointed at" "$got" "$want"

  tap_is "no base names no ref, cleanly" "$(base_ref "$w" ""; echo "rc=$?")" "rc=0"
  tap_is "no base ref is no drift, cleanly" "$(drift "$w" ""; echo "rc=$?")" $'0 0\nrc=0'
  echo c > "$w/c"; git "${G[@]}" -C "$w" add -A; git "${G[@]}" -C "$w" commit --quiet -m C
  tap_is "a commit past the base is one ahead" "$(drift "$w" origin/main)" "1 0"

  rm -rf "$tmp"
}

path="$PWD" fetch=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   fetch=no ; shift ;;
    --self-test) self_test; tap_end ;;
    -*) echo "dev_setup: unknown argument: $1" >&2; exit 2 ;;
    *)  path="$1" ; shift ;;
  esac
done

probe "$path" "$fetch"
