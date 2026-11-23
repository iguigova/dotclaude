#!/usr/bin/env bash
# project_file.sh — resolve a name in the project layer, then the global one.
#
# The project is the nearest folder at or above $PWD whose `.claude/` holds
# `project`, the marker project_init.sh writes; its `.claude/` is the project
# layer. A `.claude/` without the marker, such as a clone's own, is passed over,
# and ~/.claude is the global layer, never a project. This is how a script
# finds the project, reads a setting only the project has (atlassian_site), and
# calls another script by name.
#
#   --root           the project's folder
#   <name>           the path of the project's .claude/<name>
#   --value <name>   that file's value: its lines, less blank and `#` lines.
#                    A value is never read from the global layer.
#   --script <name>  the project's .claude/scripts/<name>, else
#                    ~/.claude/scripts/<name>
#
#   0   printed
#   1   no project, not found, or the value file holds no value; stderr names
#       where it looked. With no project, --script finds the global script alone.
#   2   usage
#
# Usage:
#   project_file.sh --root
#   project_file.sh <name>
#   project_file.sh --value <name>
#   project_file.sh --script <name>
#   project_file.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# root_of — the nearest folder at or above $PWD whose .claude/ holds the
# project marker, skipping $HOME.
root_of() {
  local d="$PWD"
  while :; do
    [[ "$d" != "$HOME" && -f "$d/.claude/project" ]] && { printf '%s\n' "$d"; return 0; }
    [[ "$d" == "/" ]] && return 1
    d=$(dirname "$d")
  done
}

root() {
  root_of || { echo "project_file.sh: no .claude/project at or above $PWD" >&2; return 1; }
}

path_of() {  # <name>
  local r
  r=$(root) || return 1
  [[ -e "$r/.claude/$1" ]] || { echo "project_file.sh: no $r/.claude/$1" >&2; return 1; }
  printf '%s\n' "$r/.claude/$1"
}

value_of() {  # <name>
  local f value
  f=$(path_of "$1") || return 1
  value=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$f")
  [[ -n "$value" ]] || { echo "project_file.sh: $f holds no value" >&2; return 1; }
  printf '%s\n' "$value"
}

script_of() {  # <name>
  local r mine="" global="$HOME/.claude/scripts/$1"
  r=$(root_of) && mine="$r/.claude/scripts/$1"
  [[ -n "$mine" && -e "$mine" ]] && { printf '%s\n' "$mine"; return 0; }
  [[ -e "$global" ]] && { printf '%s\n' "$global"; return 0; }
  echo "project_file.sh: no ${mine:-project at or above $PWD}, and no $global" >&2
  return 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")"
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  # p is a project holding a clone with its own .claude/; n is a nested project;
  # r is a root holding none; home is the global layer.
  tap_project "$fx/p"; tap_project "$fx/p/n"; tap_project "$fx/home"
  mkdir -p "$fx/home/.claude/scripts" "$fx/p/.claude/scripts" "$fx/p/api/repo/.claude" "$fx/p/api/repo/src" \
    "$fx/home/q" "$fx/r/.claude"
  : > "$fx/p/.claude/atlassian_site"; : > "$fx/p/api/repo/.claude/clone_only"; : > "$fx/r/.claude/root_only"
  printf '# the owners\norg-a\n\n  # indented comment\norg-b\n' > "$fx/p/.claude/github_orgs"
  printf '# only a comment\n\n' > "$fx/p/.claude/empty_value"
  : > "$fx/home/.claude/scripts/shared.sh"; : > "$fx/home/.claude/scripts/both.sh"
  : > "$fx/p/.claude/scripts/both.sh"; : > "$fx/home/.claude/global_only"
  at() { (cd "$1" && HOME="$fx/home" "$me" "${@:2}"); }  # <dir> <args…>
  tap_is "the project is the nearest marked folder" "$(at "$fx/p/api/repo/src" --root)" "$fx/p"
  tap_is "the start folder itself can be the project" "$(at "$fx/p" --root)" "$fx/p"
  tap_is "a nested project is nearer than the one holding it" "$(at "$fx/p/n" --root)" "$fx/p/n"
  tap_is "a folder with no project names where it looked" "$(at "$fx/r" --root 2>&1)" \
    "project_file.sh: no .claude/project at or above $fx/r"
  tap_fails "a root has no project" at "$fx/r" --root
  tap_fails "the global layer is never the project" at "$fx/home/q" --root
  tap_is "a name resolves in the project's .claude/" \
    "$(at "$fx/p/api/repo/src" atlassian_site)" "$fx/p/.claude/atlassian_site"
  tap_fails "a clone's own .claude/ is never a layer" at "$fx/p/api/repo/src" clone_only
  tap_fails "an unmarked .claude/ at a root is never a layer" at "$fx/r" root_only
  tap_fails "a nested project never falls through to the one holding it" at "$fx/p/n" atlassian_site
  tap_fails "the global layer is never the project layer" at "$fx/home/q" global_only
  tap_is "a value drops blank and comment lines" "$(at "$fx/p" --value github_orgs)" "$(printf 'org-a\norg-b')"
  tap_fails "a file holding only comments is no value" at "$fx/p" --value empty_value
  tap_fails "an empty file is no value" at "$fx/p" --value atlassian_site
  tap_fails "a value never falls back to the global layer" at "$fx/home/q" --value global_only
  tap_is "a project script wins over the global one" "$(at "$fx/p" --script both.sh)" "$fx/p/.claude/scripts/both.sh"
  tap_is "the global script serves a project without one" \
    "$(at "$fx/p/api/repo/src" --script shared.sh)" "$fx/home/.claude/scripts/shared.sh"
  tap_is "the global script serves a root" "$(at "$fx/r" --script both.sh)" "$fx/home/.claude/scripts/both.sh"
  tap_run "a project script found exits 0" at "$fx/p" --script both.sh
  tap_run "a global script found exits 0" at "$fx/p" --script shared.sh
  tap_fails "a script in neither layer is not found" at "$fx/p" --script none.sh
  tap_is "a missing script names both places" \
    "$(at "$fx/p" --script none.sh 2>&1)" \
    "project_file.sh: no $fx/p/.claude/scripts/none.sh, and no $fx/home/.claude/scripts/none.sh"
  tap_is "a missing script at a root names the global place" \
    "$(at "$fx/r" --script none.sh 2>&1)" \
    "project_file.sh: no project at or above $fx/r, and no $fx/home/.claude/scripts/none.sh"
  tap_is "a name with a slash is a usage error" "$(at "$fx/p" --script a/b.sh 2>/dev/null; echo $?)" 2
  tap_is "a bare flag is a usage error" "$(at "$fx/p" --value 2>/dev/null; echo $?)" 2
  tap_is "--root takes no name" "$(at "$fx/p" --root x 2>/dev/null; echo $?)" 2
  tap_end
fi

usage() { echo "Usage: project_file.sh --root | [--value|--script] <name> | --self-test" >&2; exit 2; }
if [[ "${1:-}" == --root ]]; then [[ $# -eq 1 ]] || usage; root; exit; fi
case "${1:-}" in --value|--script) mode=$1; shift ;; *) mode=--path ;; esac
[[ $# -eq 1 && -n "$1" && "$1" != */* ]] || usage
case "$mode" in
  --value)  value_of "$1" ;;
  --script) script_of "$1" ;;
  *)        path_of "$1" ;;
esac
