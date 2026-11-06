#!/usr/bin/env bash
# selftest.sh — static + round-trip checks for the universal scripts in ~/.claude/scripts,
# and the name lint over the prose this tree changed. gate_lib.sh holds the checks.
# Run after editing anything here. Exit 0 = clean, 1 = a check failed.
#
# --copy runs it on an exported copy (dotclaude_export.sh): check 6 is skipped,
# because the copy's prose was gated by this check at the source on every commit,
# and a copy's own HEAD is the previous export, not a baseline for its names.
#
# Usage:
#   selftest.sh [--copy]
set -uo pipefail
copy=0
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) copy=1; shift ;;
    *) echo "selftest.sh: unknown argument: $1 (takes --copy)" >&2; exit 2 ;;
  esac
done
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2   # → ~/.claude/scripts
# shellcheck source=gate_lib.sh
. ./gate_lib.sh

echo "== 1. syntax =="
gate_syntax ./*.sh ./*.py

echo "== 2. shellcheck =="
gate_shellcheck ./*.sh

echo "== 3. every script that offers --self-test, and the TAP it prints =="
gate_self_tests .

echo "== 4. skill and command frontmatter, and their allowed-tools =="
# The census reads frontmatter leniently so it can describe a malformed file.
# This reads it strictly, so a block that is absent, unparseable, or silently the
# wrong type is a failure rather than a file that quietly stops being routed.
gate_run ./frontmatter_lint.py "$(dirname "$PWD")"
# A command's allowed-tools drift from the commands its steps run, silently:
# a rule too broad never prompts, and a missing one prompts mid-run.
gate_run ./allowed_tools_lint.py "$(dirname "$PWD")"

echo "== 5. permission rules =="
# A rule that matches nothing still prompts, and one that matches everything
# never does; both are silent.
gate_run ./settings_lint.py ../settings.json

echo "== 6. names in changed prose still resolve =="
# Global prose names project-side scripts this tree cannot see, which is why the
# absolute count is not the gate here.
if [ "$copy" -eq 1 ]; then
  echo "  ok  skipped: --copy, the prose was gated at its source"
else
  gate_names_changed .. ':(exclude)projects/*'
fi

gate_end
