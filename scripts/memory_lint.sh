#!/usr/bin/env bash
# memory_lint.sh — shape gate for the memory store. Deterministic checks only: it
# never judges whether a claim is true or a description is a good retrieval key.
#   ERROR (exit 1): an index line that is not a pointer, a duplicate or dangling
#                   pointer, a fact file with no pointer, a malformed fact file,
#                   a fact with no verify
# Usage: memory_lint.sh [MEMORY_FILE]   (defaults to the resolved MEMORY_FILE)
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./memory_lib.sh
. "$SCRIPTS_DIR/memory_lib.sh"

# Each fixture is a whole store — its own directory, an index named MEMORY.md,
# and the fact files it points at — because the facts linted are the ones beside
# the index.
if [[ "${1:-}" == "--self-test" ]]; then
  # shellcheck source=tap.sh
  . "$SCRIPTS_DIR/tap.sh"
  self="$SCRIPTS_DIR/$(basename "${BASH_SOURCE[0]}")"
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT

  fact() {  # DIR NAME EXTRA-METADATA-LINE
    printf -- '---\nname: %s\ndescription: "d"\nmetadata:\n  type: reference\n%b---\n\nbody\n' \
      "$2" "${3:-}" > "$1/$2.md"
    echo "- [$2]($2.md) — hook" >> "$1/MEMORY.md"
  }
  lint() { MEMORY_FILE="$1/MEMORY.md" "$self" "$1/MEMORY.md" 2>&1; }

  mkdir "$fx/clean"; printf '# F\n\n' > "$fx/clean/MEMORY.md"
  fact "$fx/clean" checked '  verify: true\n'
  clean_out=$(lint "$fx/clean"); clean=$?

  expect() {  # DESCRIPTION DIR PATTERN — the store fails and names its defect
    local out; out=$(lint "$2")
    if [[ $? -eq 1 ]] && grep -q -- "$3" <<<"$out"; then tap_ok "$1"
    else tap_not_ok "$1" "$out"; fi
  }
  broken() {  # NAME — a clean one-fact store to break
    mkdir "$fx/$1"; printf '# F\n\n' > "$fx/$1/MEMORY.md"; fact "$fx/$1" a
  }

  broken inline;   echo '- [b] a fact written into the index' >> "$fx/inline/MEMORY.md"
  expect "fact text in the index is rejected"      "$fx/inline"   'not a pointer line'
  broken dup;      echo '- [a](a.md) — again' >> "$fx/dup/MEMORY.md"
  expect "a duplicate pointer is rejected"         "$fx/dup"      'duplicate pointer'
  broken dangling; echo '- [gone](gone.md) — hook' >> "$fx/dangling/MEMORY.md"
  expect "a dangling pointer is rejected"          "$fx/dangling" 'dangling pointer'
  broken mismatch; echo '- [x](a.md) — hook' >> "$fx/mismatch/MEMORY.md"
  expect "a pointer naming another file is rejected" "$fx/mismatch" 'names x but points at a.md'
  broken orphan;   grep -v '(a.md)' "$fx/orphan/MEMORY.md" > "$fx/orphan/i" && mv "$fx/orphan/i" "$fx/orphan/MEMORY.md"
  expect "a fact with no pointer is rejected"      "$fx/orphan"   'no pointer line'
  broken retired;  fact "$fx/retired" r '  check: auto\n'
  expect "a retired field is rejected"             "$fx/retired"  'check: is not a field'
  broken unverified; fact "$fx/unverified" u
  expect "a fact with no verify is rejected"       "$fx/unverified" 'u.md: no verify'

  if [[ "$clean" -eq 0 ]]; then tap_ok "a clean store passes"
  else tap_not_ok "a clean store passes" "exit $clean: $clean_out"; fi
  tap_end
fi

MF="${1:-$MEMORY_FILE}"
[[ -f "$MF" ]] || { echo "memory_lint: no memory file at $MF" >&2; exit 2; }
MEM_DIR="$(cd "$(dirname "$MF")" && pwd)"

err=0; pointers=0; facts=0
bad() { echo "  ERROR $1" >&2; err=1; }

# --- The index ----------------------------------------------------------------
# A title, blank lines and pointer lines. Anything else is fact text, which the
# index must not hold because it loads whole in every session.
declare -A seen=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == '# '* ]] && continue
  if [[ ! "$line" =~ $MEM_POINTER_RE ]]; then
    bad "not a pointer line: ${line:0:64}"; continue
  fi
  pointers=$((pointers + 1))
  name="${BASH_REMATCH[1]}"; target="${BASH_REMATCH[2]}.md"
  [[ "$name.md" == "$target" ]] || bad "pointer names $name but points at $target"
  [[ -z "${seen[$target]:-}" ]] || bad "duplicate pointer: $target"
  seen[$target]=1
  [[ -f "$MEM_DIR/$target" ]] || bad "dangling pointer: $target"
done < "$MF"

# --- Fact files -----------------------------------------------------------------
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  facts=$((facts + 1))
  b=$(basename "$f"); stem="${b%.md}"

  # A reader taking the rest of the line returns a block scalar's `|` or `>`
  # and loses the text beneath it, so the store holds no such value.
  while IFS= read -r blk; do
    [[ -n "$blk" ]] && bad "$b: $blk: is a block scalar; a value is a single line"
  done < <(mem_block_fields "$f")

  [[ "$(mem_field "$f" name)" == "$stem" ]] || bad "$b: name does not match filename"
  [[ -n "$(mem_field "$f" description)" ]]  || bad "$b: no description"
  ty=$(mem_field "$f" type)
  [[ " $MEM_TYPES " == *" $ty "* ]]          || bad "$b: type '$ty' is not one of $MEM_TYPES"

  # Each retired field stored something the store now reads off verify: alone,
  # so leaving one in place would state a rule nothing applies.
  for dead in source check verified; do
    [[ -z "$(mem_field "$f" "$dead")" ]] || bad "$b: $dead: is not a field"
  done

  [[ -n "${seen[$b]:-}" ]] || bad "$b: no pointer line in $(basename "$MF")"

  [[ -n "$(mem_field "$f" verify)" ]]       || bad "$b: no verify"
done < <(mem_facts)

echo "memory_lint: $pointers pointers, $facts fact files, errors=$err"
[[ "$err" -eq 0 ]] && echo "memory_lint: PASS" || echo "memory_lint: FAIL"
exit "$err"
