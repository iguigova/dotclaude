# shellcheck shell=bash
# flag_value.sh — the one check that a flag is followed by its value, sourced
# by every script that parses a flag taking one.
#
#   flag_value [--may-be-empty] <flag> [<value> …]
#
# Called as `flag_value "$@"` in the flag's case arm, before the arm reads $2
# and shifts 2. A flag with no word after it, or with an empty one, exits the
# script with 2 and "<script>: <flag> needs a value" on stderr; --may-be-empty
# accepts an empty word. Without the check, `shift 2` on a last flag fails and
# shifts nothing, so a parsing loop meets the same flag forever.
#
# flag_lint.py, which gate_lib.sh's gate_flag_values runs in every tooling
# repo's selftest, fails a flag's case arm that shifts 2 without this call.
#
# A global script sources it from beside itself, so a self-test that moves
# $HOME still finds it; a project script from ~/.claude/scripts:
#   . "$(dirname "${BASH_SOURCE[0]}")/flag_value.sh" || exit 1
#   . "$HOME/.claude/scripts/flag_value.sh" || exit 1
#
# Usage:
#   flag_value.sh --self-test

flag_value() {  # [--may-be-empty] <flag> [<value> …]
  local empty=0
  if [[ "${1:-}" == --may-be-empty ]]; then empty=1; shift; fi
  if [[ $# -ge 2 ]] && [[ -n "$2" || "$empty" -eq 1 ]]; then return 0; fi
  echo "${0##*/}: ${1:-a flag} needs a value" >&2
  exit 2
}

# Executed rather than sourced, the file takes one argument, --self-test. The
# guard compares this file with the script being run, so a script sourcing it
# with its own --self-test in $1 never reaches the branch.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${1:-}" == "--self-test" ]] || {
    echo "flag_value.sh: source this file; executed, it takes only --self-test" >&2; exit 2; }
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  # try <args…> — what flag_value says, then how the script ends
  try() { (flag_value "$@"; echo "returned $?") 2>&1; echo "exit $?"; }
  passed=$(printf '%s\n' 'returned 0' 'exit 0')
  refused() { printf '%s\n' "flag_value.sh: $1 needs a value" 'exit 2'; }  # <flag>
  tap_is "a flag followed by its value passes" "$(try --x v)" "$passed"
  tap_is "the words after the value change nothing" "$(try --x v --y)" "$passed"
  tap_is "a last flag exits the script with 2, naming it" "$(try --x)" "$(refused --x)"
  tap_is "an empty value exits the script with 2" "$(try --x '')" "$(refused --x)"
  tap_is "--may-be-empty accepts an empty value" "$(try --may-be-empty --x '')" "$passed"
  tap_is "--may-be-empty still refuses a last flag" "$(try --may-be-empty --x)" "$(refused --x)"
  tap_is "no flag at all is refused too" "$(try)" "$(refused 'a flag')"
  tap_end
fi
