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
  local root branch base baseref counts ahead behind dirty untracked
  local -a decisions=()

  root=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || {
    echo "dev_setup: not a git repo: $target" >&2
    return 2
  }

  [[ "$fetch" == yes ]] && git -C "$root" fetch --quiet --prune 2>/dev/null

  branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)
  base=$(resolve_base "$root")

  baseref=""
  if [[ -n "$base" ]]; then
    if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$base"; then
      baseref="origin/$base"
    elif git -C "$root" show-ref --verify --quiet "refs/heads/$base"; then
      baseref="$base"
    fi
  fi

  ahead=0 behind=0
  if [[ -n "$baseref" ]]; then
    counts=$(git -C "$root" rev-list --left-right --count "$baseref...HEAD" 2>/dev/null)
    behind=${counts%%[[:space:]]*}
    ahead=${counts##*[[:space:]]}
    [[ "$behind" =~ ^[0-9]+$ ]] || behind=0
    [[ "$ahead"  =~ ^[0-9]+$ ]] || ahead=0
  fi

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

  [[ "$branch" == HEAD ]] && decisions+=("detached HEAD — check out a branch before working")
  (( behind > 0 )) &&
    decisions+=("behind $baseref by $behind — branch off the latest base or rebase")

  echo
  if (( ${#decisions[@]} == 0 )); then
    echo "ready"
    return 0
  fi
  printf 'decide first:\n'
  printf '  - %s\n' "${decisions[@]}"
  return 1
}

self_test() {
  local tmp rc fail=0
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
    if [[ "$rc" == "$want" ]]; then
      echo "  ok  $name (exit $rc)"
    else
      echo "  FAIL $name: want exit $want, got $rc"; fail=1
    fi
  }

  echo "== dev_setup self-test =="
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
    if [[ "$rc" == "$want" ]]; then echo "  ok  $name (exit $rc)"
    else echo "  FAIL $name: want exit $want, got $rc"; fail=1; fi
  }
  cli "unknown argument → exit 2" 2 --bogus
  cli "a path that is not a repo → exit 2" 2 "$tmp"
  cli "a path argument is honoured" 0 "$w" --dry-run
  if "$0" "$w" --dry-run 2>/dev/null | grep -q '(local refs; --dry-run)'; then
    echo "  ok  --dry-run says the refs are local"
  else echo "  FAIL --dry-run did not mark its refs as local"; fail=1; fi
  if "$0" "$w" 2>/dev/null | grep -q '(local refs'; then
    echo "  FAIL a fetching run still claimed local refs"; fail=1
  else echo "  ok  a fetching run does not claim local refs"; fi
  local got want
  got=$("$0" "$w" --dry-run 2>/dev/null | sed -n 's/^repo  *//p')
  want=$(git -C "$w" rev-parse --show-toplevel)
  if [[ "$got" == "$want" ]]; then echo "  ok  it reports the repo it was pointed at"
  else echo "  FAIL it reported $got, not $want"; fail=1; fi

  rm -rf "$tmp"
  echo
  [[ "$fail" -eq 0 ]] && echo "dev_setup self-test: PASS" || echo "dev_setup self-test: FAIL"
  return "$fail"
}

path="$PWD" fetch=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   fetch=no ; shift ;;
    --self-test) self_test; exit $? ;;
    -*) echo "dev_setup: unknown argument: $1" >&2; exit 2 ;;
    *)  path="$1" ; shift ;;
  esac
done

probe "$path" "$fetch"
