# shellcheck shell=bash
# tap.sh — what every self-test prints: TAP, the Test Anything Protocol.
# Sourced by each shell script's --self-test; tap.py is the same for Python.
#
#   ok 1 - <name>         a case that holds
#   not ok 2 - <name>     a case that does not, then its details as `# ` lines
#   1..2                  the plan, printed last by tap_end
#
# selftest.sh refuses a self-test whose stdout is anything else, so whatever
# the code under test prints goes to stderr. The showcase page finds a claim's
# case by its name, so a name is unique in its script, says what holds rather
# than what broke, and holds no `#`, which TAP reads as a directive.
#
# Usage:
#   tap.sh --self-test

TAP_N=0
TAP_FAILED=0

tap_ok() {  # <name>
  TAP_N=$((TAP_N + 1))
  printf 'ok %d - %s\n' "$TAP_N" "$1"
}

tap_not_ok() {  # <name> [detail…]
  TAP_N=$((TAP_N + 1)); TAP_FAILED=$((TAP_FAILED + 1))
  printf 'not ok %d - %s\n' "$TAP_N" "$1"
  shift
  [ $# -eq 0 ] || printf '%s\n' "$@" | sed 's/^/# /'
}

# tap_run — the case holds when the command exits 0. What the command prints
# goes to stderr, so it never reads as a case.
tap_run() {  # <name> <command…>
  if "${@:2}" >&2; then tap_ok "$1"; else tap_not_ok "$1" "exit $?: ${*:2}"; fi
}

# tap_fails — the case holds when the command exits non-zero: a refusal.
tap_fails() {  # <name> <command…>
  if "${@:2}" >&2; then tap_not_ok "$1" "exit 0: ${*:2}"; else tap_ok "$1"; fi
}

# tap_is — the case holds when what was got is what was wanted.
tap_is() {  # <name> <got> <want>
  if [ "$2" = "$3" ]; then tap_ok "$1"
  else tap_not_ok "$1" "got:  $2" "want: $3"; fi
}

# tap_like — the case holds when what was got matches a glob pattern.
tap_like() {  # <name> <got> <pattern>
  # shellcheck disable=SC2053  # the pattern is a glob on purpose
  if [[ "$2" == $3 ]]; then tap_ok "$1"
  else tap_not_ok "$1" "got:  $2" "like: $3"; fi
}

# tap_end — print the plan and exit: 0 when every case held, else 1.
tap_end() {
  printf '1..%d\n' "$TAP_N"
  [ "$TAP_FAILED" -eq 0 ] && exit 0
  exit 1
}

# tap_verify — whether a file is a self-test's stdout as stated above: only
# case, detail and plan lines; cases numbered from 1; one plan, last, counting
# them; at least one case; no name twice. Prints what is wrong, else nothing.
tap_verify() {  # <file>
  awk '
    function bad(why) { print why; wrong = 1; exit }
    /^(not )?ok [0-9]+ - [^#]+$/ {
      if (plan) bad("a case after the plan: " $0)
      n++; num = $0; sub(/^(not )?ok /, "", num); sub(/ .*/, "", num)
      if (num != n) bad("case " num " where " n " was due")
      name = $0; sub(/^(not )?ok [0-9]+ - /, "", name)
      if (name in seen) bad("a name used twice: " name)
      seen[name] = 1; next }
    /^#( |$)/ { next }
    /^1\.\.[0-9]+$/ { if (plan) bad("a second plan"); plan = substr($0, 4); next }
    { bad("not a TAP line: " $0) }
    END {
      if (wrong) exit 1
      if (!n) { print "no cases"; exit 1 }
      if (plan == "") { print "no plan"; exit 1 }
      if (plan != n) { print "a plan of " plan " for " n " cases"; exit 1 }
    }' "$1"
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--self-test" ]; then
  set -uo pipefail
  # The writer is tested by running it in a child and reading what it printed.
  run() { bash -c "source '${BASH_SOURCE[0]}'; $1" 2>/dev/null; }
  out=$(run 'tap_ok one; tap_not_ok two "why" "and why"; tap_end'); st=$?
  want=$'ok 1 - one\nnot ok 2 - two\n# why\n# and why\n1..2'
  tap_is "cases are numbered, details follow theirs, the plan comes last" \
    "$out" "$want"
  tap_is "a failed case makes the run exit 1" "$st" 1
  out=$(run 'tap_ok one; tap_end'); st=$?
  tap_is "a run whose cases all held exits 0" "$st" 0
  out=$(run 'tap_run quiet echo noise; tap_run red false; tap_end')
  tap_is "a command's output goes to stderr, and its exit holds the case" \
    "$out" $'ok 1 - quiet\nnot ok 2 - red\n# exit 1: false\n1..2'
  out=$(run 'tap_fails refused false; tap_fails accepted true; tap_end')
  tap_is "a refusal holds when the command exits non-zero" \
    "$out" $'ok 1 - refused\nnot ok 2 - accepted\n# exit 0: true\n1..2'
  out=$(run 'tap_is same a a; tap_is differ a b; tap_end')
  tap_is "a mismatch names what was got and what was wanted" \
    "$out" $'ok 1 - same\nnot ok 2 - differ\n# got:  a\n# want: b\n1..2'

  out=$(run 'tap_like glob "a b c" "*b*"; tap_like miss abc "*d*"; tap_end')
  tap_is "a glob that misses names the pattern" \
    "$out" $'ok 1 - glob\nnot ok 2 - miss\n# got:  abc\n# like: *d*\n1..2'

  t=$(mktemp); trap 'rm -f "$t"' EXIT
  verdict() { printf '%s\n' "$1" > "$t"; tap_verify "$t"; }
  tap_is "a stream the writer printed is valid TAP" \
    "$(verdict $'ok 1 - a\nnot ok 2 - b\n# why\n#\n1..2')" ""
  tap_is "a line that is not TAP is refused" \
    "$(verdict $'ok 1 - a\n  ok  b\n1..1')" "not a TAP line:   ok  b"
  tap_is "a stream with no plan is refused" \
    "$(verdict 'ok 1 - a')" "no plan"
  tap_is "a plan that miscounts is refused" \
    "$(verdict $'ok 1 - a\n1..2')" "a plan of 2 for 1 cases"
  tap_is "a stream with no cases is refused" "$(verdict '1..0')" "no cases"
  tap_is "a case out of turn is refused" \
    "$(verdict $'ok 2 - a\n1..1')" "case 2 where 1 was due"
  tap_is "a name used twice is refused" \
    "$(verdict $'ok 1 - a\nok 2 - a\n1..2')" "a name used twice: a"
  tap_is "a name holding a hash sign is refused" \
    "$(verdict $'ok 1 - a # SKIP\n1..1')" "not a TAP line: ok 1 - a # SKIP"
  tap_end
fi
