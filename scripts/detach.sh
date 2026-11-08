#!/usr/bin/env bash
# detach.sh — start a command that outlives whatever started it, and return at once.
#
# Usage:
#   detach.sh CMD [ARG…]
#   detach.sh --self-test
#
# A SessionEnd hook is killed at 1500 ms, so its real work runs detached. setsid
# leaves the process group, which is enough when the harness runs in a terminal.
# It is not enough when the harness runs in a systemd unit, such as a timer's
# oneshot service running `claude -p`: when the unit's main process exits,
# systemd kills every process left in the unit's cgroup, and a setsid child is
# still in it. So when the user's systemd manager answers, the command runs in a
# transient scope of its own (`systemd-run --user --scope`), a cgroup the unit's
# end does not reach, and keeps the caller's environment and working directory.
# Where no user manager answers, setsid alone is used.
#
# The command's stdin, stdout and stderr are /dev/null: it writes its own log.
# DETACH_SCOPE=0 forces the setsid-only path.
set -uo pipefail

scope_ok() {
  [[ "${DETACH_SCOPE:-1}" != 0 ]] && command -v systemd-run >/dev/null \
    && systemd-run --user --scope --quiet --collect true >/dev/null 2>&1
}

detach() {
  if scope_ok; then set -- systemd-run --user --scope --quiet --collect "$@"; fi
  setsid nohup "$@" </dev/null >/dev/null 2>&1 &
  disown || true
}

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local tmp self start
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  wait_for() { for _ in $(seq 60); do [[ -s "$1" ]] && return; sleep 0.1; done; }

  start=$(date +%s%N)
  FOO=kept bash "$self" bash -c 'sleep 1; echo "$FOO $PWD" >"$1"' _ "$tmp/env"
  tap_is "it returns before the command ends" \
    "$(( ($(date +%s%N) - start) / 1000000 < 900 ))" 1
  wait_for "$tmp/env"
  tap_is "the command keeps the caller's environment and directory" \
    "$(cat "$tmp/env" 2>/dev/null)" "kept $PWD"

  DETACH_SCOPE=0 bash "$self" bash -c 'echo ran >"$1"' _ "$tmp/plain"
  wait_for "$tmp/plain"
  tap_is "without a user manager it still runs the command" \
    "$(cat "$tmp/plain" 2>/dev/null)" ran

  tap_fails "no command is a usage error" bash "$self"

  # The case this script exists for, where a user manager runs here: a oneshot
  # unit starts the command and exits, and systemd kills what is left in its
  # cgroup. A runner with no user manager has no such unit to escape.
  if scope_ok; then
    # shellcheck disable=SC2016  # the unit's bash expands its own arguments
    systemd-run --user --quiet --wait -p Type=oneshot -E "PATH=$PATH" \
      bash -c '"$1" bash -c "sleep 1; echo alive >$2"; sleep 0.2' _ "$self" "$tmp/unit" \
      >/dev/null 2>&1
    sleep 1.2; wait_for "$tmp/unit"
    tap_is "a command started by a systemd unit outlives the unit" \
      "$(cat "$tmp/unit" 2>/dev/null)" alive
  else
    echo "detach.sh: no user systemd manager, so the unit case does not run" >&2
  fi
}

case "${1:-}" in
  --self-test) self_test; tap_end ;;
  ""|-h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
  *) detach "$@" ;;
esac
