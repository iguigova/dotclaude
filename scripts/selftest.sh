#!/usr/bin/env bash
# selftest.sh — static + round-trip checks for the universal scripts in ~/.claude/scripts,
# and the name lint over the prose this tree changed.
# Run after editing anything here. Exit 0 = clean, 1 = a check failed. Every check
# that can fail prints a `FAIL` line naming itself, so the verdict is always
# attributable to one check. A check whose tool is missing is one of those
# failures: see `need` below.
#
# --copy runs it on an exported copy (dotclaude_export.sh): check 6 is skipped,
# because the copy's prose was gated by this check at the source on every commit,
# and a copy's own HEAD is the previous export, not a baseline for its names.
#
# --self-test sweeps a folder of small scripts made to pass and fail in each way
# check 3 tells apart. It never sweeps this folder, so check 3 runs it like any
# other script's self-test, with no recursion.
#
# Usage:
#   selftest.sh [--copy]
#   selftest.sh --self-test
set -uo pipefail
copy=0; self_test=0
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) copy=1; shift ;;
    --self-test) self_test=1; shift ;;
    *) echo "selftest.sh: unknown argument: $1 (takes --copy, --self-test)" >&2; exit 2 ;;
  esac
done
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2   # → ~/.claude/scripts
# shellcheck source=tap.sh
. ./tap.sh
fail=0
JOBS=$(nproc 2>/dev/null || echo 4)

# need — the tool a check runs on, or a FAIL naming what went unchecked.
# A missing tool used to print a `note:` and skip, which is the worst outcome a
# gate has: the check does not run, nothing says FAIL, and the run still ends in
# PASS. Absence is not evidence of cleanliness, so it is reported as the failure
# it is, with the command that fixes it.
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
# <dir>/<file>.st, read afterwards in file order, so what a check prints is the
# same however the jobs interleave.
each() {  # <fn> <dir> <file…>
  local fn=$1 dir=$2 f running=0; shift 2
  for f in "$@"; do
    if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
    { "$fn" "$f" >"$dir/${f##*/}.out" 2>&1; echo $? >"$dir/${f##*/}.st"; } &
    running=$((running + 1))
  done
  wait
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
# with no registration step to forget. Its stdout is held to tap.sh's format,
# and its exit status to what that says. Prints a verdict per script, in file
# order, and under a failed one its failed cases with their details and the
# last lines of its stderr, so a run's output says why; returns 1 when any
# failed.
sweep() {  # <dir>
  local dir=$1 work f name st wrong missed cases rc=0
  local -a tests=()
  for f in "$dir"/*.sh "$dir"/*.py; do
    [ -e "$f" ] && grep -q -- '--self-test' "$f" && tests+=("$f")
  done
  work=$(mktemp -d) || return 1
  each self_test_of "$work" "${tests[@]}"
  for f in "${tests[@]}"; do
    name=${f##*/}; st=$(cat "$work/$name.st")
    wrong=$(tap_verify "$work/$name.tap")
    missed=$(grep -c '^not ok' "$work/$name.tap")
    cases=$(grep -cE '^(not )?ok' "$work/$name.tap")
    if [ -n "$wrong" ]; then
      echo "  FAIL ./$name --self-test does not print TAP: $wrong"
    elif [ "$st" -eq 0 ] && [ "$missed" -eq 0 ]; then
      echo "  ok  ./$name (cases: $cases)"; continue
    elif [ "$st" -ne 0 ] && [ "$missed" -ne 0 ]; then
      echo "  FAIL ./$name --self-test: $missed of $cases cases"
    else
      echo "  FAIL ./$name --self-test exited $st with $missed of $cases cases failed"
    fi
    rc=1
    awk '/^not ok /{p=1; print; next} /^#/{if (p) print; next} {p=0}' "$work/$name.tap" \
      | sed 's/^/      /'
    tail -n 5 "$work/$name.err" | sed 's/^/      /'
  done
  rm -rf "$work"
  return "$rc"
}

if [ "$self_test" -eq 1 ]; then
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
  printf '#!/usr/bin/env bash\necho PASS\n' > "$fx/s/quiet.sh"
  printf '#!/usr/bin/env python3\n# --self-test\nprint("ok 1 - snake\\n1..1")\n' > "$fx/s/snake.sh"
  printf '# --self-test\nprint("ok 1 - py\\n1..1")\n' > "$fx/s/plain.py"
  out=$(sweep "$fx/s"); st=$?
  line() { grep -F " ./$1 " <<<"$out"; }
  tap_is "a self-test that prints TAP and exits 0 passes the sweep" \
    "$(line good.sh)" "  ok  ./good.sh (cases: 1)"
  tap_like "a self-test that does not print TAP fails the sweep" \
    "$(line untap.sh)" "  FAIL ./untap.sh --self-test does not print TAP: *"
  tap_is "a self-test exiting 0 over a failed case fails the sweep" \
    "$(line liar.sh)" "  FAIL ./liar.sh --self-test exited 0 with 1 of 1 cases failed"
  tap_is "a self-test exiting 1 while every case held fails the sweep" \
    "$(line gloom.sh)" "  FAIL ./gloom.sh --self-test exited 1 with 0 of 1 cases failed"
  tap_is "a failed case fails the sweep and is counted" \
    "$(line red.sh)" "  FAIL ./red.sh --self-test: 1 of 2 cases"
  tap_is "a failed case is printed under its verdict, with its details" \
    "$(grep -A2 -F " ./red.sh " <<<"$out" | tail -2)" $'      not ok 2 - y\n      # why'
  tap_is "a self-test that does not print TAP shows the end of its stderr" \
    "$(grep -A1 -F " ./untap.sh " <<<"$out" | tail -1)" "      boom"
  tap_is "a self-test runs with SIGPIPE ignored, as on GitHub's runners" \
    "$(line pipe.sh)" "  ok  ./pipe.sh (cases: 1)"
  tap_is "a script that offers no --self-test is not run" "$(line quiet.sh)" ""
  tap_is "a Python script wearing .sh runs under python3" \
    "$(line snake.sh)" "  ok  ./snake.sh (cases: 1)"
  tap_is "a .py script runs under python3" "$(line plain.py)" "  ok  ./plain.py (cases: 1)"
  tap_is "verdicts print in file order, whatever finishes first" \
    "$(sed -n 's/^  [A-Z ok]* \.\/\([^ ]*\) .*/\1/p' <<<"$out" | paste -sd' ')" \
    "a_slow.sh gloom.sh good.sh liar.sh pipe.sh red.sh snake.sh untap.sh plain.py"
  tap_is "a passing self-test's stderr is not shown" "$(grep -c noise <<<"$out")" 0
  tap_is "a sweep with any failure fails" "$st" 1
  cp "$fx/s/good.sh" "$fx/s/snake.sh" "$fx/green/"
  sweep "$fx/green" >/dev/null; tap_is "a sweep of passing self-tests passes" "$?" 0
  mkdir "$fx/slow"
  for i in 1 2 3 4; do
    printf '#!/usr/bin/env bash\n# --self-test\nsleep 2; printf "ok 1 - n\\n1..1\\n"\n' > "$fx/slow/n$i.sh"
  done
  start=$SECONDS; JOBS=4 sweep "$fx/slow" >/dev/null
  tap_is "self-tests run JOBS at a time: four 2 s tests take under 6 s" \
    "$((SECONDS - start < 6))" 1
  tap_end
fi

scratch=$(mktemp -d) || exit 2; trap 'rm -rf "$scratch"' EXIT

echo "== 1. bash -n =="
for f in ./*.sh; do
  [ -e "$f" ] || continue
  is_python "$f" && continue
  bash -n "$f" && echo "  ok  $f" || { echo "  FAIL bash -n: $f"; fail=1; }
done

echo "== 2. shellcheck =="
lint_of() { shellcheck -S warning "$1"; }  # <script>
if need shellcheck "the shell lint"; then
  shells=()
  for f in ./*.sh; do [ -e "$f" ] && ! is_python "$f" && shells+=("$f"); done
  each lint_of "$scratch" "${shells[@]}"
  for f in "${shells[@]}"; do
    if [ "$(cat "$scratch/${f##*/}.st")" -eq 0 ]; then echo "  ok  $f"
    else cat "$scratch/${f##*/}.out"; echo "  FAIL shellcheck: $f"; fail=1; fi
  done
fi

echo "== 3. every script that offers --self-test, and the TAP it prints =="
sweep . || fail=1

echo "== 4. skill and command frontmatter, and their allowed-tools =="
# The census reads frontmatter leniently so it can describe a malformed file.
# This reads it strictly, so a block that is absent, unparseable, or silently the
# wrong type is a failure rather than a file that quietly stops being routed.
# A pipeline's status is the reader's, so the lint is captured and then shown:
# piping it into sed would report sed's success as the gate's verdict.
fm_out=$(./frontmatter_lint.py "$(dirname "$PWD")") && fm_st=0 || fm_st=$?
printf '%s\n' "$fm_out" | sed 's/^/  /'
[ "$fm_st" -eq 0 ] || fail=1
# A command's allowed-tools drift from the commands its steps run, silently:
# a rule too broad never prompts, and a missing one prompts mid-run.
at_out=$(./allowed_tools_lint.py "$(dirname "$PWD")") && at_st=0 || at_st=$?
[ -z "$at_out" ] || printf '%s\n' "$at_out" | sed 's/^/  /'
[ "$at_st" -eq 0 ] || fail=1

echo "== 5. permission rules =="
# A rule that matches nothing still prompts, and one that matches everything
# never does; both are silent. Captured, then shown, as check 4 is.
sl_out=$(./settings_lint.py ../settings.json) && sl_st=0 || sl_st=$?
printf '%s\n' "$sl_out" | sed 's/^/  /'
[ "$sl_st" -eq 0 ] || fail=1

echo "== 6. names in changed prose still resolve =="
# A skill, a command and a rule carry no `verify:`, so this lint is the only thing
# between them and a stale name — and until now a human had to remember to run it.
# tooling_commit.sh gates on this file, so a round that edits a doc is gated on the
# doc. `--gate` is the form that runs unattended: it compares each file against its
# own HEAD text, so it takes no recorded baseline and passes a name the tree already
# carried. Global prose names project-side scripts this tree cannot see, which is
# why the absolute count is not the gate here. A name broken by deleting its target
# edits no doc, so it is the grep half of the rename rule, not this check.
prose=()
[ "$copy" -eq 1 ] ||
while IFS= read -r p; do [ -n "$p" ] && prose+=("$p"); done < <(
  { git -C .. diff --name-only --diff-filter=ACMR HEAD -- '*.md' ':(exclude)projects/*'
    git -C .. ls-files -o --exclude-standard -- '*.md' ':(exclude)projects/*'
  } | sort -u)
if [ "$copy" -eq 1 ]; then
  echo "  ok  skipped: --copy, the prose was gated at its source"
elif [ "${#prose[@]}" -eq 0 ]; then
  echo "  ok  no prose changed since HEAD"
else
  nl_out=$( (cd .. && ./scripts/name_lint.sh --gate "${prose[@]}") 2>&1 ) && nl_st=0 || nl_st=$?
  printf '%s\n' "$nl_out" | sed 's/^/  /'
  [ "$nl_st" -eq 0 ] || fail=1
fi

echo
[ "$fail" -eq 0 ] && echo "selftest: PASS" || echo "selftest: FAIL"
exit "$fail"
