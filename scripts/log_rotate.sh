#!/usr/bin/env bash
# log_rotate.sh — keep an append-only log bounded: past a size, it becomes
# <log>.1, replacing the one before, and the next line starts a new log.
#
# Usage:
#   log_rotate.sh <log> [<max-bytes>]   # default 2000000
#   log_rotate.sh --help
#   log_rotate.sh --self-test
#
# A writer that still holds the old file open finishes its lines there, in
# <log>.1. So the two files together hold everything since the rotation before.
# It is quick enough for a SessionEnd hook: one stat and, at most, one rename.
#
# Exit 0 rotated or nothing to do, 2 usage.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

MAX_DEFAULT=2000000

# rotate <log> <max> — the log moves to <log>.1 once it is larger than max.
rotate() {
  local size
  size=$(stat -c %s -- "$1" 2>/dev/null) || return 0
  [[ "$size" -gt "$2" ]] && mv -f -- "$1" "$1.1"
  return 0
}

if [[ "${1:-}" == --self-test ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  printf '12345' > "$fx/small.log"
  rotate "$fx/small.log" 5
  tap_is "a log at the limit stays" "$(cat "$fx/small.log") $([[ -e "$fx/small.log.1" ]] && echo rotated)" "12345 "
  printf '123456' > "$fx/big.log"; echo old > "$fx/big.log.1"
  rotate "$fx/big.log" 5
  tap_is "a log past the limit becomes .1, replacing the one before" \
    "$([[ -e "$fx/big.log" ]] && echo kept) $(cat "$fx/big.log.1")" " 123456"
  rotate "$fx/none.log" 5
  tap_is "a log that is not there is nothing to do" "$(compgen -G "$fx/none*" | wc -l)" 0
  "$self" "$fx/big.log.1" 3; tap_is "the script rotates at the size it is given" "$([[ -e "$fx/big.log.1.1" ]] && echo yes)" yes
  printf 'x' > "$fx/one.log"; "$self" "$fx/one.log"
  tap_is "one argument rotates at the default size, and a log under it exits 0" "$? $(cat "$fx/one.log")" "0 x"
  "$self" "$fx/absent.log"; tap_is "a log that is not there exits 0" "$?" 0
  "$self" >/dev/null 2>&1; tap_is "no log is a usage error" "$?" 2
  "$self" "$fx/x" 12k >/dev/null 2>&1; tap_is "a size that is not a whole number is a usage error" "$?" 2
  tap_end
fi

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: log_rotate.sh <log> [<max-bytes>]" >&2; exit 2; }
max=${2:-$MAX_DEFAULT}
[[ "$max" =~ ^[0-9]+$ ]] || { echo "log_rotate.sh: $max is not a whole number of bytes" >&2; exit 2; }
rotate "$1" "$max"
