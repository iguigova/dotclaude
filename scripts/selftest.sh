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
# --keep DIR writes what each self-test of check 3 printed to DIR/<script>.txt,
# its `ok` and `FAIL` lines, one per case. The showcase page reads them from the
# run GitHub publishes with it, so each claim shows how its own case went.
set -uo pipefail
copy=0; keep=
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) copy=1; shift ;;
    --keep) [ -n "${2:-}" ] || { echo "selftest.sh: --keep needs a directory" >&2; exit 2; }
            mkdir -p "$2" && keep=$(cd "$2" && pwd) || exit 2; shift 2 ;;
    *) echo "selftest.sh: unknown argument: $1 (takes --copy, --keep DIR)" >&2; exit 2 ;;
  esac
done
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2   # → ~/.claude/scripts
fail=0

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

echo "== 1. bash -n =="
is_python() { head -1 "$1" 2>/dev/null | grep -q python; }  # a python script wearing .sh

for f in ./*.sh; do
  [ -e "$f" ] || continue
  is_python "$f" && continue
  bash -n "$f" && echo "  ok  $f" || { echo "  FAIL bash -n: $f"; fail=1; }
done

echo "== 2. shellcheck =="
if need shellcheck "the shell lint"; then
  for f in ./*.sh; do
    [ -e "$f" ] || continue
    is_python "$f" && continue
    shellcheck -S warning "$f" && echo "  ok  $f" || { echo "  FAIL shellcheck: $f"; fail=1; }
  done
fi

echo "== 3. every script that offers --self-test =="
# A sweep, not a list: a script's --self-test is enforced the moment it lands,
# with no registration step to forget. Naming them here instead is how a script
# with a perfectly good self-test ends up never being run by the gate.
for f in ./*.sh ./*.py; do
  [ -e "$f" ] || continue
  grep -q -- '--self-test' "$f" || continue
  [ "$(basename "$f")" = "selftest.sh" ] && continue
  if [[ "$f" == *.py ]] || head -1 "$f" | grep -q python; then runner=python3; else runner=bash; fi
  printed=/dev/null; [ -n "$keep" ] && printed="$keep/$(basename "$f").txt"
  if timeout 120 "$runner" "$f" --self-test >"$printed" 2>&1; then
    echo "  ok  $f"
  else
    echo "  FAIL $f --self-test"; fail=1
  fi
done

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
