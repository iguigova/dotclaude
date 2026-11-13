#!/usr/bin/env bash
# selftest.sh — static + round-trip checks for the universal scripts in ~/.claude/scripts,
# and the name lint over the prose this tree changed. gate_lib.sh holds the checks.
# Run after editing anything here. Exit 0 = clean, 1 = a check failed.
#
# --copy runs it on an exported copy (dotclaude_export.sh): checks 6 and 7 are
# skipped, because the copy's prose and code were gated by them at the source on
# every commit, and a copy's own HEAD is the previous export, not a baseline.
# --root DIR gates the scripts in DIR, a tree's scripts folder, with this
# gate's own checks; --self-test uses it to show the gate fails a broken tree.
#
# Usage:
#   selftest.sh [--copy] [--root DIR]
#   selftest.sh --self-test
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # → ~/.claude/scripts
# shellcheck source=gate_lib.sh
. "$here/gate_lib.sh"

if [ "${1:-}" = --self-test ]; then
  # A gate on a fixture tree, with GATE_SELF_TEST set so it does not sweep this
  # script again. Each case breaks one thing, and the gate must fail naming it.
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/scripts"; echo '{}' > "$fx/settings.json"
  printf '#!/usr/bin/env bash\n# offers --self-test\nprintf "ok 1 - x\\n1..1\\n"\n' > "$fx/scripts/clean.sh"
  git -C "$fx" init -q
  git -C "$fx" add -A && git -C "$fx" -c user.email=t@t -c user.name=t commit -qm base
  gate() { GATE_SELF_TEST=1 "$here/selftest.sh" --root "$fx/scripts" 2>&1; }
  out=$(gate); st=$?
  tap_is "a clean tree passes" "$st $(tail -1 <<<"$out")" "0 selftest: PASS"
  printf 'if\n' > "$fx/scripts/broken.sh"
  tap_like "a syntax error fails the gate, naming the script" "$(gate)" "*FAIL bash -n: ./broken.sh*selftest: FAIL"
  rm "$fx/scripts/broken.sh"
  printf '#!/usr/bin/env bash\n# offers --self-test\nprintf "not ok 1 - x\\n1..1\\n"; exit 1\n' > "$fx/scripts/red.sh"
  tap_like "a failing self-test fails the gate, naming the script" "$(gate)" "*FAIL ./red.sh --self-test*selftest: FAIL"
  rm "$fx/scripts/red.sh"
  mkdir -p "$fx/skills/x"; printf -- '---\nname: [\n---\nbody\n' > "$fx/skills/x/SKILL.md"
  tap_like "a malformed skill frontmatter fails the gate" "$(gate)" "*FAIL frontmatter_lint.py exited*selftest: FAIL"
  rm -r "$fx/skills"
  printf 'run `scripts/no_such_script_here.sh` first\n' > "$fx/notes.md"
  tap_like "changed prose naming a missing script fails the gate" "$(gate)" "*FAIL name_lint.sh exited*selftest: FAIL"
  rm "$fx/notes.md"
  printf '#!/usr/bin/env bash\n# offers --self-test\nbig() { [ "$1" -gt 9 ]; }\nbig 10 || exit 1\nprintf "ok 1 - x\\n1..1\\n"\n' > "$fx/scripts/weak.sh"
  tap_like "a changed script whose self-test lets a mutant live fails the gate" "$(gate)" "*FAIL change_gate.py exited 1*selftest: FAIL"
  rm "$fx/scripts/weak.sh"
  out=$(gate); tap_is "the tree passes again once each break is undone" "$(tail -1 <<<"$out")" "selftest: PASS"
  tap_end
fi

copy=0 root=$here
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) copy=1; shift ;;
    --root) root=${2:?--root needs a folder}; shift 2 ;;
    *) echo "selftest.sh: unknown argument: $1 (takes --copy, --root DIR, --self-test)" >&2; exit 2 ;;
  esac
done
cd "$root" || exit 2

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
gate_run "$GATE_SCRIPTS/frontmatter_lint.py" "$(dirname "$PWD")"
# A command's allowed-tools drift from the commands its steps run, silently:
# a rule too broad never prompts, and a missing one prompts mid-run.
gate_run "$GATE_SCRIPTS/allowed_tools_lint.py" "$(dirname "$PWD")"

echo "== 5. permission rules =="
# A rule that matches nothing still prompts, and one that matches everything
# never does; both are silent.
gate_run "$GATE_SCRIPTS/settings_lint.py" ../settings.json

echo "== 6. names in changed prose still resolve =="
# Global prose names project-side scripts this tree cannot see, which is why the
# absolute count is not the gate here.
if [ "$copy" -eq 1 ]; then
  echo "  ok  skipped: --copy, the prose was gated at its source"
else
  gate_names_changed .. ':(exclude)projects/*'
fi

echo "== 7. changed code: complexity, and every mutant killed =="
if [ "$copy" -eq 1 ]; then
  echo "  ok  skipped: --copy, the code was gated at its source"
else
  gate_changed_code ..
fi

gate_end
