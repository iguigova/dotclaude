#!/usr/bin/env bash
# project_file.sh — resolve a name in the project layer, then the global one.
#
# The project layer is the nearest `.claude/` at or above $PWD that holds the
# name; ~/.claude is the global layer and never counts as a project. This is
# how a script reads a setting only the project has (atlassian_site), finds the
# project itself (the directory above `project_file.sh session_history.md`),
# and calls another script by name.
#
#   <name>           the path of the project's .claude/<name>
#   --value <name>   that file's value: its lines, less blank and `#` lines.
#                    A value is never read from the global layer.
#   --script <name>  the project's .claude/scripts/<name>, else
#                    ~/.claude/scripts/<name>
#
#   0   printed
#   1   not found, or the value file holds no value; stderr names where it looked
#   2   usage
#
# Usage:
#   project_file.sh <name>
#   project_file.sh --value <name>
#   project_file.sh --script <name>
#   project_file.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# find_up — nearest <dir>/.claude/<name> at or above <start>, skipping $HOME.
find_up() {  # <start dir> <name>
  local d="$1"
  while :; do
    [[ "$d" != "$HOME" && -e "$d/.claude/$2" ]] && { printf '%s\n' "$d/.claude/$2"; return 0; }
    [[ "$d" == "/" ]] && return 1
    d=$(dirname "$d")
  done
}

path_of() {  # <name>
  find_up "$PWD" "$1" || { echo "project_file.sh: no .claude/$1 at or above $PWD" >&2; return 1; }
}

value_of() {  # <name>
  local f value
  f=$(path_of "$1") || return 1
  value=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$f")
  [[ -n "$value" ]] || { echo "project_file.sh: $f holds no value" >&2; return 1; }
  printf '%s\n' "$value"
}

script_of() {  # <name>
  local global="$HOME/.claude/scripts/$1"
  find_up "$PWD" "scripts/$1" && return 0
  [[ -e "$global" ]] && { printf '%s\n' "$global"; return 0; }
  echo "project_file.sh: no .claude/scripts/$1 at or above $PWD, and no $global" >&2
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")"
  mkdir -p "$fx/home/.claude/scripts" "$fx/p/.claude/scripts" "$fx/p/api/repo/.claude" "$fx/p/api/repo/src" \
    "$fx/home/q/.claude"
  : > "$fx/p/.claude/atlassian_site"
  printf '# the owners\norg-a\n\n  # indented comment\norg-b\n' > "$fx/p/.claude/github_orgs"
  printf '# only a comment\n\n' > "$fx/p/.claude/empty_value"
  : > "$fx/home/.claude/scripts/shared.sh"; : > "$fx/home/.claude/scripts/both.sh"
  : > "$fx/p/.claude/scripts/both.sh"; : > "$fx/home/.claude/global_only"
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  at() { (cd "$1" && HOME="$fx/home" "$me" "${@:2}"); }  # <dir> <args…>
  tap_is "a nearer .claude/ without the file is passed over" \
    "$(at "$fx/p/api/repo/src" atlassian_site)" "$fx/p/.claude/atlassian_site"
  tap_is "the start directory itself is searched" "$(at "$fx/p" atlassian_site)" "$fx/p/.claude/atlassian_site"
  tap_fails "a file only below the start is not found" at "$fx" atlassian_site
  tap_fails "the global layer is never the project layer" at "$fx/home/q" global_only
  tap_is "a value drops blank and comment lines" "$(at "$fx/p" --value github_orgs)" "$(printf 'org-a\norg-b')"
  tap_fails "a file holding only comments is no value" at "$fx/p" --value empty_value
  tap_fails "an empty file is no value" at "$fx/p" --value atlassian_site
  tap_fails "a value never falls back to the global layer" at "$fx/home/q" --value global_only
  tap_is "a project script wins over the global one" "$(at "$fx/p" --script both.sh)" "$fx/p/.claude/scripts/both.sh"
  tap_is "the global script serves a project without one" \
    "$(at "$fx/p/api/repo/src" --script shared.sh)" "$fx/home/.claude/scripts/shared.sh"
  tap_run "a project script found exits 0" at "$fx/p" --script both.sh
  tap_run "a global script found exits 0" at "$fx/p" --script shared.sh
  tap_fails "a script in neither layer is not found" at "$fx/p" --script none.sh
  tap_is "a missing script names both places" \
    "$(at "$fx/p" --script none.sh 2>&1)" \
    "project_file.sh: no .claude/scripts/none.sh at or above $fx/p, and no $fx/home/.claude/scripts/none.sh"
  tap_is "a name with a slash is a usage error" "$(at "$fx/p" --script a/b.sh 2>/dev/null; echo $?)" 2
  tap_is "a bare flag is a usage error" "$(at "$fx/p" --value 2>/dev/null; echo $?)" 2
  tap_end
fi

usage() { echo "Usage: project_file.sh [--value|--script] <name> | --self-test" >&2; exit 2; }
case "${1:-}" in --value|--script) mode=$1; shift ;; *) mode=--path ;; esac
[[ $# -eq 1 && -n "$1" && "$1" != */* ]] || usage
case "$mode" in
  --value)  value_of "$1" ;;
  --script) script_of "$1" ;;
  *)        path_of "$1" ;;
esac
