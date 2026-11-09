# shellcheck shell=bash
# gate_lib.sh — the checks every tooling repo's selftest.sh runs. A selftest.sh
# sources this, runs the checks it needs in the order it wants, adds what only
# its repo has, and ends on gate_end.
#
# Every check that can fail prints a FAIL line naming itself and sets `fail`, so
# the verdict is always attributable to one check. A repo's own check sets `fail`
# the same way.
#
#   need <tool> <what it gates>      the tool, or a FAIL naming what did not run
#   gate_syntax <file…>              bash -n, or compile for Python
#   gate_shellcheck <file…>          shellcheck -S warning on the shell scripts
#   gate_self_tests <dir…>           every script there offering --self-test, its
#                                    stdout held to tap.sh's format; selftest.sh,
#                                    the gate itself, is one of them except while
#                                    GATE_SELF_TEST is set
#   gate_run <command…>              a lint: shown, and a FAIL when it exits non-zero
#   gate_names_changed <repo> [<pathspec>…]
#                                    name_lint --gate over the prose changed since HEAD
#   gate_end                         the verdict line, then exit
#
# Usage:
#   . ~/.claude/scripts/gate_lib.sh     # from a selftest.sh
#   gate_lib.sh --self-test

GATE_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tap.sh
. "$GATE_SCRIPTS/tap.sh"
fail=0
JOBS=$(nproc 2>/dev/null || echo 4)

# need — a missing tool used to print a `note:` and skip, the worst outcome a gate
# has: the check does not run, nothing says FAIL, and the run still ends in PASS.
# Absence is not evidence of cleanliness, so it fails, with the command that fixes it.
need() {  # <tool> <what it gates>
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "  FAIL $1 is not installed, so $2 did not run"
  case "$1" in
    shellcheck) echo "       fix: ~/.claude/scripts/install_shellcheck.sh" ;;
    jq)         echo "       fix: apt install jq" ;;
  esac
  fail=1
  return 1
}

is_python() { [[ "$1" == *.py ]] || head -1 "$1" 2>/dev/null | grep -q python; }  # .py, or python wearing .sh

# each — run <fn> on every file, JOBS at a time, and wait for them all. Its
# stdout and stderr land in <dir>/<file>.out and its exit status in
# <dir>/<file>.st, the file's path with its slashes flattened, read afterwards in
# file order, so what a check prints is the same however the jobs interleave.
each() {  # <fn> <dir> <file…>
  local fn=$1 dir=$2 f running=0; shift 2
  for f in "$@"; do
    if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
    { "$fn" "$f" >"$dir/${f//\//_}.out" 2>&1; echo $? >"$dir/${f//\//_}.st"; } &
    running=$((running + 1))
  done
  wait
}

gate_syntax() {  # <file…>
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    if is_python "$f"; then
      python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$f" \
        && echo "  ok  $f" || { echo "  FAIL syntax: $f"; fail=1; }
    else
      bash -n "$f" && echo "  ok  $f" || { echo "  FAIL bash -n: $f"; fail=1; }
    fi
  done
}

lint_of() { shellcheck -S warning "$1"; }  # <script>

gate_shellcheck() {  # <file…>
  need shellcheck "the shell lint" || return 0
  local f scratch
  local -a shells=()
  for f in "$@"; do [ -e "$f" ] && ! is_python "$f" && shells+=("$f"); done
  scratch=$(mktemp -d) || { echo "  FAIL shellcheck: no scratch folder"; fail=1; return 0; }
  each lint_of "$scratch" "${shells[@]}"
  for f in "${shells[@]}"; do
    if [ "$(cat "$scratch/${f//\//_}.st")" -eq 0 ]; then echo "  ok  $f"
    else cat "$scratch/${f//\//_}.out"; echo "  FAIL shellcheck: $f"; fail=1; fi
  done
  rm -rf "$scratch"
}

# self_test_of — one script's self-test, run in its own folder as ./<name>, so
# a test that calls "$0" finds it. Its TAP and stderr land in $work, sweep's. SIGPIPE
# is ignored, as GitHub's runners ignore it, so a writer cut off by a reader
# that quit early fails here with "Broken pipe", not first on a push.
self_test_of() {  # <script>
  local name=${1##*/} runner=bash
  is_python "$1" && runner=python3
  (trap '' PIPE; cd "${1%/*}" && timeout 120 "$runner" "./$name" --self-test) \
    >"$work/$name.tap" 2>"$work/$name.err"
}

# sweep — every script in <dir> that offers --self-test, run JOBS at a time.
# A sweep, not a list: a script's --self-test is enforced the moment it lands,
# with no registration step to forget. A gate's self-test runs a gate on a
# fixture with GATE_SELF_TEST=1, and that gate skips selftest.sh, so the gate
# is tested once and never recurses into itself. Its stdout is held to tap.sh's format,
# and its exit status to what that says. Prints a verdict per script, in file
# order, and under a failed one its failed cases with their details and the
# last lines of its stderr, so a run's output says why; returns 1 when any
# failed.
sweep() {  # <dir>
  local dir=$1 work f name st wrong missed cases rc=0
  local -a tests=()
  for f in "$dir"/*.sh "$dir"/*.py; do
    [ -e "$f" ] && grep -q -- '--self-test' "$f" || continue
    [ "${f##*/}" = selftest.sh ] && [ -n "${GATE_SELF_TEST:-}" ] && continue
    tests+=("$f")
  done
  work=$(mktemp -d) || return 1
  each self_test_of "$work" "${tests[@]}"
  for f in "${tests[@]}"; do
    name=${f##*/}; st=$(cat "$work/${f//\//_}.st")
    wrong=$(tap_verify "$work/$name.tap")
    missed=$(grep -c '^not ok' "$work/$name.tap")
    cases=$(grep -cE '^(not )?ok' "$work/$name.tap")
    if [ -n "$wrong" ]; then
      echo "  FAIL $f --self-test does not print TAP: $wrong"
    elif [ "$st" -eq 0 ] && [ "$missed" -eq 0 ]; then
      echo "  ok  $f (cases: $cases)"; continue
    elif [ "$st" -ne 0 ] && [ "$missed" -ne 0 ]; then
      echo "  FAIL $f --self-test: $missed of $cases cases"
    else
      echo "  FAIL $f --self-test exited $st with $missed of $cases cases failed"
    fi
    rc=1
    awk '/^not ok /{p=1; print; next} /^#/{if (p) print; next} {p=0}' "$work/$name.tap" \
      | sed 's/^/      /'
    tail -n 5 "$work/$name.err" | sed 's/^/      /'
  done
  rm -rf "$work"
  return "$rc"
}

gate_self_tests() {  # <dir…>
  local dir
  for dir in "$@"; do sweep "$dir" || fail=1; done
}

# gate_run — a lint's output is captured and then shown: piping it into sed would
# report sed's success as the gate's verdict.
gate_run() {  # <command…>
  local out st=0
  out=$("$@" 2>&1) || st=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/  /'
  [ "$st" -eq 0 ] || { echo "  FAIL ${1##*/} exited $st"; fail=1; }
}

# gate_names_changed — a skill, a command and a rule carry no `verify:`, so this
# lint is the only thing between them and a stale name. tooling_commit.sh gates on
# selftest.sh, so a round that edits a doc is gated on the doc. `--gate` compares
# each file against its own HEAD text, so it takes no recorded baseline and passes
# a name the tree already carried. A name broken by deleting its target edits no
# doc: that is the grep half of the rename rule, not this check.
gate_names_changed() {  # <repo> [<pathspec>…]
  local repo=$1; shift
  local -a prose=()
  git -C "$repo" rev-parse -q --verify HEAD >/dev/null \
    || { echo "  FAIL no HEAD in $repo, so the names were not checked"; fail=1; return 0; }
  mapfile -t prose < <({ git -C "$repo" diff --name-only --diff-filter=ACMR HEAD -- '*.md' "$@"
                         git -C "$repo" ls-files -o --exclude-standard -- '*.md' "$@"; } | sort -u)
  if [ "${#prose[@]}" -eq 0 ]; then echo "  ok  no prose changed since HEAD"; return 0; fi
  ( cd "$repo" && gate_run "$GATE_SCRIPTS/name_lint.sh" --gate "${prose[@]}"; exit "$fail" ) || fail=1
}

gate_end() {
  echo
  [ "$fail" -eq 0 ] && echo "selftest: PASS" || echo "selftest: FAIL"
  exit "$fail"
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--self-test" ]; then
  set -uo pipefail
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/s" "$fx/green"
  fixture() {  # <name> <body> — a script that offers --self-test
    printf '#!/usr/bin/env bash\n# --self-test\n%s\n' "$2" > "$fx/s/$1"
  }
  fixture a_slow.sh  'sleep 1; printf "ok 1 - slow\n1..1\n"'
  fixture good.sh    '[ "$0" = ./good.sh ] && [ -f good.sh ] && printf "ok 1 - here\n1..1\n"; echo noise >&2'
  fixture liar.sh    'printf "not ok 1 - x\n1..1\n"; exit 0'
  fixture gloom.sh   'printf "ok 1 - x\n1..1\n"; exit 1'
  fixture red.sh     'printf "ok 1 - x\nnot ok 2 - y\n# why\n1..2\n"; exit 1'
  fixture untap.sh   'echo PASS; echo boom >&2'
  fixture pipe.sh    '[ -n "$(trap -p PIPE)" ] && printf "ok 1 - deaf\n1..1\n"'
  fixture selftest.sh 'printf "ok 1 - gate\n1..1\n"'
  printf '#!/usr/bin/env bash\necho PASS\n' > "$fx/s/quiet.sh"
  printf '#!/usr/bin/env python3\n# --self-test\nprint("ok 1 - snake\\n1..1")\n' > "$fx/s/snake.sh"
  printf '# --self-test\nprint("ok 1 - py\\n1..1")\n' > "$fx/s/plain.py"
  cd "$fx" || exit 2
  out=$(sweep s); st=$?
  line() { grep -F " s/$1 " <<<"$out"; }
  tap_is "a self-test that prints TAP and exits 0 passes the sweep" \
    "$(line good.sh)" "  ok  s/good.sh (cases: 1)"
  tap_like "a self-test that does not print TAP fails the sweep" \
    "$(line untap.sh)" "  FAIL s/untap.sh --self-test does not print TAP: *"
  tap_is "a self-test exiting 0 over a failed case fails the sweep" \
    "$(line liar.sh)" "  FAIL s/liar.sh --self-test exited 0 with 1 of 1 cases failed"
  tap_is "a self-test exiting 1 while every case held fails the sweep" \
    "$(line gloom.sh)" "  FAIL s/gloom.sh --self-test exited 1 with 0 of 1 cases failed"
  tap_is "a failed case fails the sweep and is counted" \
    "$(line red.sh)" "  FAIL s/red.sh --self-test: 1 of 2 cases"
  tap_is "a failed case is printed under its verdict, with its details" \
    "$(grep -A2 -F " s/red.sh " <<<"$out" | tail -2)" $'      not ok 2 - y\n      # why'
  tap_is "a self-test that does not print TAP shows the end of its stderr" \
    "$(grep -A1 -F " s/untap.sh " <<<"$out" | tail -1)" "      boom"
  tap_is "a self-test runs with SIGPIPE ignored, as on GitHub's runners" \
    "$(line pipe.sh)" "  ok  s/pipe.sh (cases: 1)"
  tap_is "a script that offers no --self-test is not run" "$(line quiet.sh)" ""
  tap_is "selftest.sh, the gate itself, is swept" \
    "$(line selftest.sh)" "  ok  s/selftest.sh (cases: 1)"
  tap_is "selftest.sh is not swept inside a gate's own self-test" \
    "$(GATE_SELF_TEST=1 sweep s | grep -F " s/selftest.sh ")" ""
  tap_is "a Python script wearing .sh runs under python3" \
    "$(line snake.sh)" "  ok  s/snake.sh (cases: 1)"
  tap_is "a .py script runs under python3" "$(line plain.py)" "  ok  s/plain.py (cases: 1)"
  tap_is "verdicts print in file order, whatever finishes first" \
    "$(sed -n 's/^  [A-Z ok]* s\/\([^ ]*\) .*/\1/p' <<<"$out" | paste -sd' ')" \
    "a_slow.sh gloom.sh good.sh liar.sh pipe.sh red.sh selftest.sh snake.sh untap.sh plain.py"
  tap_is "a passing self-test's stderr is not shown" "$(grep -c noise <<<"$out")" 0
  tap_is "a sweep with any failure fails" "$st" 1
  cp s/good.sh s/snake.sh green/
  sweep green >/dev/null; tap_is "a sweep of passing self-tests passes" "$?" 0
  mkdir slow
  for i in 1 2 3 4; do
    printf '#!/usr/bin/env bash\n# --self-test\nsleep 2; printf "ok 1 - n\\n1..1\\n"\n' > "slow/n$i.sh"
  done
  start=$SECONDS; JOBS=4 sweep slow >/dev/null
  tap_is "self-tests run JOBS at a time: four 2 s tests take under 6 s" \
    "$((SECONDS - start < 6))" 1

  # A check sets `fail` in the shell that runs it, so each runs in its own, and
  # prints what it set.
  run() { ( fail=0; "$@"; echo "fail=$fail" ); }
  printf 'if\n' > bad.sh; printf 'def\n' > bad.py; printf 'true\n' > ok.sh; printf 'pass\n' > ok.py
  tap_like "a shell syntax error fails" "$(run gate_syntax bad.sh 2>/dev/null)" "*FAIL bash -n: bad.sh*fail=1"
  tap_like "a Python syntax error fails" "$(run gate_syntax bad.py 2>/dev/null)" "*FAIL syntax: bad.py*fail=1"
  tap_is "good files and a glob that matched nothing pass" \
    "$(run gate_syntax ok.sh ok.py 'none/*.sh')" $'  ok  ok.sh\n  ok  ok.py\nfail=0'
  tap_like "a sweep's failure reaches the verdict" "$(run gate_self_tests s)" "*fail=1"
  tap_like "a clean sweep leaves the verdict alone" "$(run gate_self_tests green)" "*fail=0"
  tap_is "a lint that passes is shown" "$(run gate_run echo fine)" $'  fine\nfail=0'
  tap_is "a lint that fails is shown and named" "$(run gate_run sh -c 'echo no; exit 3')" \
    $'  no\n  FAIL sh exited 3\nfail=1'
  tap_like "a missing tool fails and names what did not run" "$(run need no-such-tool "the lint")" \
    "*FAIL no-such-tool is not installed, so the lint did not run*fail=1"
  if command -v shellcheck >/dev/null; then
    printf '#!/bin/bash\necho "$(ls)" `date`\nunset x; cd /tmp\n' > warn.sh
    tap_like "a shellcheck warning fails" "$(run gate_shellcheck warn.sh)" "*FAIL shellcheck: warn.sh*fail=1"
    tap_like "a clean script passes shellcheck" "$(printf '#!/bin/bash\ntrue\n' > clean.sh; run gate_shellcheck clean.sh)" "*fail=0"
    tap_like "two folders' same-named scripts are told apart" \
      "$(mkdir -p p q; printf '#!/bin/bash\ntrue\n' > p/x.sh; printf '#!/bin/bash\necho "$(ls)" `date`\ncd /tmp\n' > q/x.sh; run gate_shellcheck p/x.sh q/x.sh)" \
      "*ok  p/x.sh*FAIL shellcheck: q/x.sh*"
  fi
  tap_is "the verdict fails when a check did" "$( (fail=1; gate_end) | tail -1)" "selftest: FAIL"
  tap_is "the verdict passes when none did" "$( (fail=0; gate_end) | tail -1)" "selftest: PASS"
  ( fail=1; gate_end ) >/dev/null; tap_is "the verdict's exit is the failure" "$?" 1

  git init -q repo
  gate() { ( cd repo && run gate_names_changed . ); }
  tap_is "a repo with no HEAD is unchecked, so it fails" "$(gate)" \
    $'  FAIL no HEAD in ., so the names were not checked\nfail=1'
  git -C repo -c user.email=t@t -c user.name=t commit -qm base --allow-empty
  tap_is "no changed prose passes" "$(gate)" $'  ok  no prose changed since HEAD\nfail=0'
  printf 'run `scripts/no_such_script_here.sh` first\n' > repo/a.md
  tap_like "a changed doc naming what does not exist fails" "$(gate)" "*fail=1"
  printf 'plain words\n' > repo/a.md
  tap_like "a changed doc naming nothing passes" "$(gate)" "*fail=0"
  tap_end
fi
