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
#   gate_tracked_self_tests <repo>   every script the repo tracks offers --self-test,
#                                    and gate_self_tests over every folder holding one
#   gate_flag_values <file…>         every flag arm that shifts 2 calls flag_value.sh's
#                                    check first (flag_lint.py)
#   gate_run <command…>              a lint: shown, and a FAIL when it exits non-zero
#   gate_names_changed <repo> [<pathspec>…]
#                                    name_lint --gate over the prose changed since HEAD
#   gate_changed_code <repo>         change_gate.py over the code changed since HEAD:
#                                    complexity, and every mutant on a changed line killed
#   gate_layer_names <.claude dir>   no skill name in both layers, and every script
#                                    overriding a global one passes its --self-test
#   gate_verb_contracts <.claude dir> every verb project_verbs.txt lists that the
#                                    project holds states that contract in its --help
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
# that quit early fails here with "Broken pipe", not first on a push. It runs
# under group_run.py, so whatever it starts is stopped once it ends, or once it
# overruns 120s. TMPDIR is a folder of its own, which verdict_of holds empty.
self_test_of() {  # <script>
  local name=${1##*/} runner=bash
  is_python "$1" && runner=python3
  mkdir "$work/$name.tmp" || return 1
  # shellcheck disable=SC2016  # the inner shell expands its own arguments
  (cd "${1%/*}" && TMPDIR="$work/$name.tmp" "$GATE_SCRIPTS/group_run.py" --timeout 120 -- \
    bash -c 'trap "" PIPE; exec "$@"' _ "$runner" "./$name" --self-test) \
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
  local dir=$1 work f rc=0
  local -a tests=()
  for f in "$dir"/*.sh "$dir"/*.py; do
    swept "$f" && tests+=("$f")
  done
  work=$(mktemp -d) || return 1
  each self_test_of "$work" "${tests[@]}"
  for f in "${tests[@]}"; do
    verdict_of "$f" "$work" || rc=1
  done
  rm -rf "$work"
  return "$rc"
}

# swept — whether the sweep runs <file>: a script that offers --self-test, and
# not selftest.sh inside a gate's own self-test.
swept() {  # <file>
  [ -e "$1" ] && grep -q -- '--self-test' "$1" || return 1
  [ "${1##*/}" != selftest.sh ] || [ -z "${GATE_SELF_TEST:-}" ]
}

# verdict_of — one script's line from its TAP and exit status in <work>, and
# under a failure its failed cases and the end of its stderr; 1 on a failure.
# A self-test that leaves anything in its TMPDIR fails: run once per mutant, a
# leaked folder becomes thousands.
verdict_of() {  # <file> <work>
  local f=$1 work=$2 name=${1##*/} st wrong missed cases skipped left
  st=$(cat "$work/${f//\//_}.st")
  wrong=$(tap_verify "$work/$name.tap")
  missed=$(grep -c '^not ok' "$work/$name.tap")
  cases=$(grep -cE '^(not )?ok' "$work/$name.tap")
  skipped=$(grep -cE '^ok [0-9]+ - .* # SKIP ' "$work/$name.tap")
  [ "$skipped" -eq 0 ] || cases="$cases, skipped: $skipped"
  left=$(ls -A "$work/$name.tmp" 2>&1 | head -3 | paste -sd' ')
  if [ -n "$wrong" ]; then
    echo "  FAIL $f --self-test does not print TAP: $wrong"
  elif [ -n "$left" ]; then
    echo "  FAIL $f --self-test left its temp folder holding: $left"
  elif [ "$st" -eq 0 ] && [ "$missed" -eq 0 ]; then
    echo "  ok  $f (cases: $cases)"; return 0
  elif [ "$st" -ne 0 ] && [ "$missed" -ne 0 ]; then
    echo "  FAIL $f --self-test: $missed of $cases cases"
  else
    echo "  FAIL $f --self-test exited $st with $missed of $cases cases failed"
  fi
  awk '/^not ok /{p=1; print; next} /^#/{if (p) print; next} {p=0}' "$work/$name.tap" \
    | sed 's/^/      /'
  tail -n 5 "$work/$name.err" | sed 's/^/      /'
  return 1
}

gate_self_tests() {  # <dir…>
  local dir
  for dir in "$@"; do sweep "$dir" || fail=1; done
}

# gate_tracked_self_tests — the sweep runs every folder holding a script the
# repo tracks, so no script sits where it is never run; a tracked script that
# offers no --self-test fails. Paths are relative to <repo>.
gate_tracked_self_tests() {  # <repo>
  local back=$PWD listed f
  local -a files=() dirs=()
  listed=$(git -C "$1" ls-files -- '*.sh' '*.py') \
    || { echo "  FAIL git ls-files in $1, so no script was swept"; fail=1; return; }
  [ -n "$listed" ] || { echo "  ok  no script tracked"; return; }
  mapfile -t files <<<"$listed"
  for f in "${files[@]}"; do
    [ -e "$1/$f" ] || continue
    grep -q -- '--self-test' "$1/$f" || { echo "  FAIL $f offers no --self-test"; fail=1; }
  done
  mapfile -t dirs < <(dirname -- "${files[@]}" | sort -u)
  cd "$1" && gate_self_tests "${dirs[@]}"
  cd "$back" || fail=1
}

# gate_help_handlers — every executable script the repo tracks answers --help
# from its header: a shell script with a `--help)` case arm or an `== --help`
# test, a Python one with a '--help' test or argparse. The scripts are read,
# never run, since one with no handler would run its real work. Paths are
# relative to <repo>.
GATE_HELP_RE="--help\\)|== --help|['\"]--help['\"]|argparse"
gate_help_handlers() {  # <repo>
  local listed f n=0 bad=0
  listed=$(git -C "$1" ls-files -- '*.sh' '*.py') \
    || { echo "  FAIL git ls-files in $1, so no script was read"; fail=1; return; }
  while IFS= read -r f; do
    [ -n "$f" ] && [ -x "$1/$f" ] || continue
    n=$((n + 1))
    grep -qE -e "$GATE_HELP_RE" "$1/$f" || { echo "  FAIL $f answers no --help"; bad=1; }
  done <<<"$listed"
  [ "$bad" -eq 0 ] && echo "  ok  every one of the $n executable scripts answers --help"
  [ "$bad" -eq 0 ] || fail=1
}

# gate_flag_values — a flag arm that shifts 2 unchecked loops forever when its
# flag is the last word, so the shape is refused before it ships.
gate_flag_values() { gate_run "$GATE_SCRIPTS/flag_lint.py" "$@"; }  # <file…>

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

# gate_changed_code — coding_guidelines.md → Verification's complexity and
# mutation checks over what this round changed, so a tooling repo holds its own
# scripts to the bar it sets for product code. A self-tested script's mutants
# run against its own --self-test.
gate_changed_code() {  # <repo>
  gate_run "$GATE_SCRIPTS/change_gate.py" --base HEAD "$1"
}

# gate_layer_names — a project's .claude/ against ~/.claude. Claude Code loads
# the personal skill over a project skill of the same name, so a shared skill
# name leaves the project's never loaded. A project script that overrides a
# global one keeps its contract, which the global script's own --self-test
# proves when it runs the implementation UNDER_TEST names. Each repo's own
# selftest.sh is its gate, not an override.
LAYER_OWN=selftest.sh

skill_names() {  # <skills dir>
  [ -d "$1" ] && find "$1" -mindepth 2 -maxdepth 2 -name SKILL.md -printf '%h\n' | sed 's#.*/##' | LC_ALL=C sort
}

script_names() {  # <scripts dir>
  [ -d "$1" ] && find "$1" -maxdepth 1 -type f ! -name "$LAYER_OWN" -printf '%f\n' | LC_ALL=C sort
}

override_ok() {  # <global script> <project script>
  grep -q UNDER_TEST "$1" \
    || { echo "  FAIL $2 overrides $1, whose --self-test never reads UNDER_TEST"; return 1; }
  UNDER_TEST=$2 "$1" --self-test >/dev/null 2>&1 \
    || { echo "  FAIL $2 fails $1's --self-test"; return 1; }
  echo "  ok  $2 passes $1's --self-test"
}

gate_layer_names() {  # <project .claude dir>
  local dir=$1 global="$HOME/.claude" name clash=0
  while IFS= read -r name; do
    echo "  FAIL skill $name is in both $global/skills and $dir/skills"; clash=1
  done < <(LC_ALL=C comm -12 <(skill_names "$global/skills") <(skill_names "$dir/skills"))
  while IFS= read -r name; do
    override_ok "$global/scripts/$name" "$dir/scripts/$name" || clash=1
  done < <(LC_ALL=C comm -12 <(script_names "$global/scripts") <(script_names "$dir/scripts"))
  [ "$clash" -eq 0 ] && echo "  ok  no skill in both layers, and every override keeps its contract"
  [ "$clash" -eq 0 ] || fail=1
}

# gate_verb_contracts — project_verbs.txt is the one statement of each verb's
# contract, and the project's --help carries it word for word, so the two
# cannot drift. Whitespace is compared collapsed, so a header may wrap it.
gate_verb_contracts() {  # <project .claude dir>
  local dir=$1 name contract help n=0 bad=0
  while IFS=$'\t' read -r name contract; do
    [ -n "$contract" ] && [ -x "$dir/scripts/$name" ] || continue
    n=$((n + 1))
    help=$("$dir/scripts/$name" --help 2>&1 | tr -s '[:space:]' ' ')
    case "$help" in *"$(printf '%s' "$contract" | tr -s '[:space:]' ' ')"*) continue ;; esac
    echo "  FAIL $name --help does not state its contract in $GATE_SCRIPTS/project_verbs.txt"; bad=1
  done < <(grep -v '^#' "$GATE_SCRIPTS/project_verbs.txt")
  [ "$bad" -eq 0 ] && echo "  ok  every verb of the $n here states its contract from project_verbs.txt"
  [ "$bad" -eq 0 ] || fail=1
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
  fixture skip.sh    'printf "ok 1 - x\nok 2 - y # SKIP no tool\n1..2\n"'
  fixture untap.sh   'echo PASS; echo boom >&2'
  fixture pipe.sh    '[ -n "$(trap -p PIPE)" ] && printf "ok 1 - deaf\n1..1\n"'
  fixture selftest.sh 'printf "ok 1 - gate\n1..1\n"'
  fixture leak.sh    'mktemp -d >/dev/null; printf "ok 1 - x\n1..1\n"'
  fixture tidy.sh    'd=$(mktemp -d); rm -r "$d"; printf "ok 1 - x\n1..1\n"'
  fixture bg.sh      "sleep 300 >/dev/null 2>&1 & echo \$! > $fx/bg.pid; printf 'ok 1 - x\\n1..1\\n'"
  printf '#!/usr/bin/env bash\necho PASS\n' > "$fx/s/quiet.sh"
  printf '#!/usr/bin/env python3\n# --self-test\nprint("ok 1 - snake\\n1..1")\n' > "$fx/s/snake.sh"
  printf '# --self-test\nprint("ok 1 - py\\n1..1")\n' > "$fx/s/plain.py"
  cd "$fx" || exit 2
  out=$(sweep s); st=$?
  line() { grep -F " s/$1 " <<<"$out"; }
  tap_is "a self-test that prints TAP and exits 0 passes the sweep" \
    "$(line good.sh)" "  ok  s/good.sh (cases: 1)"
  tap_is "a skipped case passes the sweep and is counted" \
    "$(line skip.sh)" "  ok  s/skip.sh (cases: 2, skipped: 1)"
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
  tap_like "a self-test that leaves a temp folder behind fails the sweep, naming it" \
    "$(line leak.sh)" "  FAIL s/leak.sh --self-test left its temp folder holding: tmp.*"
  tap_is "a self-test that removes its temp folder passes" "$(line tidy.sh)" "  ok  s/tidy.sh (cases: 1)"
  for _ in $(seq 100); do kill -0 "$(cat "$fx/bg.pid")" 2>/dev/null || break; sleep 0.05; done
  tap_is "a process a passing self-test leaves behind is stopped with it" \
    "$(line bg.sh) $(kill -0 "$(cat "$fx/bg.pid")" 2>/dev/null && echo alive || echo gone)" "  ok  s/bg.sh (cases: 1) gone"
  tap_is "selftest.sh, the gate itself, is swept" \
    "$(line selftest.sh)" "  ok  s/selftest.sh (cases: 1)"
  tap_is "selftest.sh is not swept inside a gate's own self-test" \
    "$(GATE_SELF_TEST=1 sweep s | grep -F " s/selftest.sh ")" ""
  tap_is "a Python script wearing .sh runs under python3" \
    "$(line snake.sh)" "  ok  s/snake.sh (cases: 1)"
  tap_is "a .py script runs under python3" "$(line plain.py)" "  ok  s/plain.py (cases: 1)"
  tap_is "verdicts print in file order, whatever finishes first" \
    "$(sed -n 's/^  [A-Z ok]* s\/\([^ ]*\) .*/\1/p' <<<"$out" | paste -sd' ')" \
    "a_slow.sh bg.sh gloom.sh good.sh leak.sh liar.sh pipe.sh red.sh selftest.sh skip.sh snake.sh tidy.sh untap.sh plain.py"
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
  git init -q tracked; mkdir tracked/sub
  cp s/good.sh tracked/; cp s/snake.sh tracked/sub/deep.sh; cp s/quiet.sh tracked/bare.py
  git -C tracked add -A; rm tracked/bare.py
  tap_is "a tracked script deleted from the tree is not read" \
    "$(run gate_tracked_self_tests tracked)" $'  ok  ./good.sh (cases: 1)\n  ok  sub/deep.sh (cases: 1)\nfail=0'
  tap_is "the folder it ran from is kept" "$(gate_tracked_self_tests tracked >/dev/null; pwd)" "$fx"
  cp s/quiet.sh tracked/quiet.sh; git -C tracked add quiet.sh
  tap_like "a tracked script with no --self-test fails, named" \
    "$(run gate_tracked_self_tests tracked)" "  FAIL quiet.sh offers no --self-test*fail=1"
  git -C tracked rm -q --cached quiet.sh; cp s/red.sh tracked/sub/
  tap_like "a failing self-test outside the first folder fails" \
    "$(run gate_tracked_self_tests tracked)" "*FAIL sub/red.sh --self-test*fail=1"
  mkdir untracked
  tap_is "a folder that is no repo fails, naming why" "$(run gate_tracked_self_tests untracked 2>/dev/null)" \
    $'  FAIL git ls-files in untracked, so no script was swept\nfail=1'
  git init -q empty
  tap_is "a repo tracking no script passes" "$(run gate_tracked_self_tests empty)" $'  ok  no script tracked\nfail=0'
  git init -q helped
  # shellcheck disable=SC2016  # the fixtures are script text, not expansions here
  printf '#!/usr/bin/env bash\ncase "${1:-}" in -h|--help) exit 0 ;; esac\n' > helped/a.sh
  printf '#!/usr/bin/env python3\nif sys.argv[1:2] == ["--help"]: pass\n' > helped/b.py
  printf '# shellcheck shell=bash\nlib() { :; }\n' > helped/lib.sh
  chmod +x helped/a.sh helped/b.py; git -C helped add -A
  tap_is "executable scripts with a handler pass, and a sourced library is not read" \
    "$(run gate_help_handlers helped)" $'  ok  every one of the 2 executable scripts answers --help\nfail=0'
  printf '#!/usr/bin/env bash\necho work\n' > helped/c.sh; chmod +x helped/c.sh; git -C helped add c.sh
  tap_is "an executable script with no handler fails, named" \
    "$(run gate_help_handlers helped)" $'  FAIL c.sh answers no --help\nfail=1'
  tap_is "a folder that is no repo fails the --help read, naming why" "$(run gate_help_handlers untracked 2>/dev/null)" \
    $'  FAIL git ls-files in untracked, so no script was read\nfail=1'
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

  mkdir -p h/.claude/skills/shared h/.claude/skills/solo h/.claude/scripts p/skills/mine p/scripts
  : > h/.claude/skills/shared/SKILL.md; : > h/.claude/skills/solo/SKILL.md; : > p/skills/mine/SKILL.md
  printf '#!/usr/bin/env bash\n"${UNDER_TEST:-true}"\n' > h/.claude/scripts/testable.sh
  printf '#!/usr/bin/env bash\ntrue\n' > h/.claude/scripts/fixed.sh
  printf '#!/usr/bin/env bash\nexit 0\n' > h/.claude/scripts/selftest.sh
  chmod +x h/.claude/scripts/*.sh
  layers() { ( HOME="$fx/h"; run gate_layer_names "$fx/p" ); }
  tap_is "a project sharing no name with the global layer passes" "$(layers)" \
    $'  ok  no skill in both layers, and every override keeps its contract\nfail=0'
  cp h/.claude/scripts/selftest.sh p/scripts/
  tap_like "each repo's own selftest.sh is not an override" "$(layers)" "*fail=0"
  mkdir p/skills/shared; : > p/skills/shared/SKILL.md
  tap_is "a skill in both layers fails, named" "$(layers)" \
    "  FAIL skill shared is in both $fx/h/.claude/skills and $fx/p/skills"$'\nfail=1'
  rm -r p/skills/shared
  printf '#!/usr/bin/env bash\nexit 0\n' > p/scripts/testable.sh; chmod +x p/scripts/testable.sh
  tap_like "an override that passes the global self-test passes" "$(layers)" \
    "  ok  $fx/p/scripts/testable.sh passes $fx/h/.claude/scripts/testable.sh's --self-test*fail=0"
  printf '#!/usr/bin/env bash\nexit 1\n' > p/scripts/testable.sh
  tap_like "an override that fails the global self-test fails" "$(layers)" \
    "  FAIL $fx/p/scripts/testable.sh fails *fail=1"
  rm p/scripts/testable.sh; cp h/.claude/scripts/fixed.sh p/scripts/
  tap_like "an override of a script whose self-test cannot run it fails" "$(layers)" \
    "  FAIL $fx/p/scripts/fixed.sh overrides *never reads UNDER_TEST*fail=1"
  rm p/scripts/fixed.sh
  verbs() { ( GATE_SCRIPTS="$fx/h/.claude/scripts"; run gate_verb_contracts "$fx/p" ); }
  printf '# comment\tnot a verb\nvx.sh\tTakes a  thing,\tproves it. Exit 0 proven.\nabsent.sh\tNever here.\n' \
    > h/.claude/scripts/project_verbs.txt
  printf '#!/usr/bin/env bash\nprintf "vx.sh: the verb.\\n\\nTakes a\\n  thing, proves it.\\nExit 0 proven.\\n"\n' > p/scripts/vx.sh
  chmod +x p/scripts/vx.sh
  tap_is "a verb whose help states its contract, wrapped, passes; one the project lacks is not counted" "$(verbs)" \
    $'  ok  every verb of the 1 here states its contract from project_verbs.txt\nfail=0'
  printf '#!/usr/bin/env bash\necho "vx.sh: takes a thing. Exit 0 done."\n' > p/scripts/vx.sh
  tap_is "a verb whose help has drifted from its contract fails, named" "$(verbs)" \
    "  FAIL vx.sh --help does not state its contract in $fx/h/.claude/scripts/project_verbs.txt"$'\nfail=1'
  tap_end
fi
