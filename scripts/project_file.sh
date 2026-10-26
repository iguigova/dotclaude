#!/usr/bin/env bash
# project_file.sh — print the project's own copy of a .claude/ file: the nearest
# `.claude/<name>` at or above $PWD. This is how a global script reads a setting
# only the project has (atlassian_site, security_classes), and how it finds the
# project itself: the directory above `project_file.sh session_history.md`.
#
# Usage:
#   project_file.sh <name>        # prints the path; exit 1, naming $PWD, when none
#   project_file.sh --self-test
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

find_up() {  # <start dir> <name> -> nearest <dir>/.claude/<name>
  local d="$1"
  while :; do
    [[ -e "$d/.claude/$2" ]] && { printf '%s\n' "$d/.claude/$2"; return 0; }
    [[ "$d" == "/" ]] && return 1
    d=$(dirname "$d")
  done
}

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/p/.claude" "$fx/p/api/repo/.claude" "$fx/p/api/repo/src"
  : > "$fx/p/.claude/atlassian_site"
  fails=()
  [[ "$(find_up "$fx/p/api/repo/src" atlassian_site)" == "$fx/p/.claude/atlassian_site" ]] \
    || fails+=("a nearer .claude/ without the file is passed over")
  [[ "$(find_up "$fx/p" atlassian_site)" == "$fx/p/.claude/atlassian_site" ]] \
    || fails+=("the start directory itself is searched")
  find_up "$fx" atlassian_site >/dev/null && fails+=("a file only below the start is not found")
  if ((${#fails[@]})); then
    printf 'project_file self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "project_file self-test: PASS (nearest copy above \$PWD, nearer .claude/ without it skipped, never below)"
  exit 0
fi

[[ $# -eq 1 && -n "$1" ]] || { echo "Usage: $0 <name> | --self-test" >&2; exit 2; }
find_up "$PWD" "$1" || { echo "project_file.sh: no .claude/$1 at or above $PWD" >&2; exit 1; }
