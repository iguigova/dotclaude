#!/usr/bin/env bash
# secret_file.sh — print the path of one of the project's secrets: the file
# <project>/.secrets/<name>, where <project> is the directory above
# `project_file.sh session_history.md`. This is how a global script reads a
# credential only the project has (jira-token, slack-token), so no token sits
# loose in $HOME. The project's ignore rules keep .secrets/ out of git.
#
# Usage:
#   secret_file.sh <name>        # prints the path; exit 1, naming it, when absent or empty
#   secret_file.sh --self-test
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/p/.claude" "$fx/p/.secrets" "$fx/p/api/repo"
  : > "$fx/p/.claude/session_history.md"
  printf 'tok\n' > "$fx/p/.secrets/jira-token"
  : > "$fx/p/.secrets/empty"
  me="$HERE/$(basename "$0")"
  # shellcheck source=tap.sh
  . "$HERE/tap.sh"
  in_dir() { (cd "$1" && "$me" "$2"); }
  tap_is "a secret is found from below the project root" \
    "$(in_dir "$fx/p/api/repo" jira-token)" "$fx/p/.secrets/jira-token"
  tap_fails "a missing secret exits non-zero" in_dir "$fx/p" missing
  tap_fails "an empty secret exits non-zero" in_dir "$fx/p" empty
  tap_fails "outside a project exits non-zero" in_dir "$fx" jira-token
  tap_end
fi

[[ $# -eq 1 && -n "$1" && "$1" != */* ]] || { echo "Usage: $0 <name> | --self-test" >&2; exit 2; }
hist=$("$HERE/project_file.sh" session_history.md) || exit 1
f="$(dirname "$(dirname "$hist")")/.secrets/$1"
[[ -s "$f" ]] || { echo "secret_file.sh: no secret at $f" >&2; exit 1; }
printf '%s\n' "$f"
