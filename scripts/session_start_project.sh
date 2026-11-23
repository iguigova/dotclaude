#!/usr/bin/env bash
# session_start_project.sh — SessionStart hook: name the project a session
# resolved to, and say so when the session started where its records split.
#
# Claude Code keeps a session's transcript under the folder it starts in, and
# the tooling finds the project from there with `project_file.sh --root`. A
# session started at a root has no project: its values, secrets and records
# stop, and its transcript belongs to no project. One started below its
# project's folder, in a clone, has the project's layer, but its transcript
# lands apart from the project's. Both print a systemMessage, which the user
# sees, naming the folder to start in instead. A session started in its
# project's own folder gets one line naming the project, in its context.
#
# It exits 0 on every path, and an unattended run prints nothing: a session
# must start, and an unattended one has nobody to tell.
#
# Usage:
#   session_start_project.sh              # reads the hook payload on stdin
#   session_start_project.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SELF_DIR/project_file.sh"

# ssp_cwd — the payload's cwd, read from stdin, or nothing.
ssp_cwd() {
  python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null
}

ssp_warn() { python3 -c 'import json,sys; print(json.dumps({"systemMessage": sys.argv[1]}))' "$1"; }  # <text>

# ssp_report — what a session started in <cwd> is told.
ssp_report() {  # <cwd>
  local root
  if ! root=$(cd "$1" && "$PF" --root 2>/dev/null); then
    ssp_warn "No project: this session started in $1, which is in no project, so its values, secrets and records stop and its transcript belongs to no project. Quit and start it in a project's folder."
  elif [[ "$root" != "$1" ]]; then
    ssp_warn "This session started in $1, below the project $(cat "$root/.claude/project") at $root, so its transcript lands apart from the project's. Quit and start it in $root."
  else
    printf 'project: %s at %s\n' "$(cat "$root/.claude/project")" "$root"
  fi
}

if [[ "${1:-}" == --self-test ]]; then
  # shellcheck source=tap.sh
  . "$SELF_DIR/tap.sh"
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  fx=$(cd "$fx" && pwd -P)
  unset CLAUDE_TOOLING_UNATTENDED
  hook() { printf '{"cwd":"%s","source":"startup"}' "$1" | "$SELF_DIR/session_start_project.sh"; }  # <cwd>
  message() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])["systemMessage"])' "$1" 2>&1; }  # <json>
  tap_project "$fx/p"; mkdir -p "$fx/p/clone" "$fx/root"
  tap_is "a session in its project's folder is told the project" "$(hook "$fx/p")" "project: p at $fx/p"
  tap_like "a session below its project is told to start in the project's folder" \
    "$(message "$(hook "$fx/p/clone")")" "*below the project p at $fx/p,*Quit and start it in $fx/p."
  tap_like "a session at a root is told it has no project" "$(message "$(hook "$fx/root")")" "No project: *$fx/root*"
  tap_is "a session in a missing folder is told nothing" "$(hook "$fx/gone")" ""
  tap_is "an unattended run prints nothing" "$(printf '{"cwd":"%s"}' "$fx/root" | CLAUDE_TOOLING_UNATTENDED=1 "$SELF_DIR/session_start_project.sh")" ""
  tap_is "a payload without a cwd reports the current folder" \
    "$(cd "$fx/p" && echo '{}' | "$SELF_DIR/session_start_project.sh")" "project: p at $fx/p"
  tap_is "an unreadable payload reports the current folder" \
    "$(cd "$fx/p" && echo 'not json' | "$SELF_DIR/session_start_project.sh")" "project: p at $fx/p"
  tap_is "it exits 0 at a root" "$(hook "$fx/root" >/dev/null; echo $?)" 0
  tap_end
fi

[[ -n "${CLAUDE_TOOLING_UNATTENDED:-}" ]] && exit 0
cwd=$(timeout 2 cat 2>/dev/null | ssp_cwd)
[[ -n "$cwd" ]] || cwd="$PWD"
[[ -d "$cwd" ]] || exit 0
ssp_report "$cwd"
exit 0
