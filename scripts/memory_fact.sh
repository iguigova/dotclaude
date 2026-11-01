#!/usr/bin/env bash
# memory_fact.sh — the writer for the memory store. A fact is a file and a pointer
# line in MEMORY.md, and this moves both together so the store is never half-written.
#
# Usage:
#   memory_fact.sh write <name> <pointer hook>   # the whole fact file on stdin
#   memory_fact.sh remove <name>                 # prints the removed fact to stdout
#   memory_fact.sh verify <name>                 # runs its verify:, exits as it did
#   memory_fact.sh --self-test
#
# `write` creates or replaces, and creates the store for a project's first fact
# inside the folder the harness keeps for it, refusing a directory with none;
# the pointer keeps its position when one exists, and lands at the end when it
# does not. `remove` prints what it deleted, because a fact's text survives
# nowhere else once the file is gone. `verify` runs a fact's check as the writer
# and memory_check.sh do (memory_lib.sh, mem_verify), so its exit status is the
# night's verdict.
#
# Every call ends in memory_lint.sh. A call the lint rejects is rolled back whole,
# so a rejected write leaves the store exactly as it found it and the caller sees
# the lint's own complaint.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./memory_lib.sh
. "$SCRIPTS_DIR/memory_lib.sh"

SELF="$SCRIPTS_DIR/$(basename "${BASH_SOURCE[0]}")"
LINT="$SCRIPTS_DIR/memory_lint.sh"

die() { echo "memory_fact: $1" >&2; exit 1; }

# mf_pointer NAME HOOK — the one pointer grammar, written in one place.
mf_pointer() { printf -- '- [%s](%s.md) — %s\n' "$1" "$1" "$2"; }

# mf_lint — the shape gate, quiet when it passes.
mf_lint() {
  local out
  out=$("$LINT" "$MEMORY_FILE" 2>&1) && return 0
  printf '%s\n' "$out" >&2
  return 1
}

mf_write() {  # NAME HOOK  (fact file on stdin)
  local name="$1" hook="$2" body tmp idx_bak file_bak=""
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || die "a fact name is lowercase letters, digits and dashes, got: $name"
  [[ -n "${hook// }" ]]         || die "a pointer needs a hook — the line that says when this fact matters"
  body=$(cat)
  [[ -n "$body" ]] || die "no fact body on stdin"

  local file="$MEM_DIR/$name.md"
  tmp=$(mktemp); printf '%s\n' "$body" > "$tmp"
  # Validated against the file that will be written, not against the arguments,
  # so a body disagreeing with its own name is caught before either file moves.
  [[ "$(mem_field "$tmp" name)" == "$name" ]] || { rm -f "$tmp"; die "the body's name: is not $name"; }
  # Named before the emptiness check below, which a block scalar would otherwise
  # trip while reporting a missing field rather than an unreadable one.
  local blocks; blocks=$(mem_block_fields "$tmp" | tr '\n' ' ')
  [[ -z "${blocks// }" ]] || { rm -f "$tmp"
    die "a frontmatter value is a single line; these are block scalars: ${blocks% }"; }
  [[ -n "$(mem_field "$tmp" verify)" ]]       || { rm -f "$tmp"; die "the body carries no verify:"; }

  # A fact is admitted because its check passes now, not because it has one.
  # Anything but 0 refuses, 75 included: a claim nobody could confirm is an item
  # still open, not a fact.
  local vrc vcmd
  vcmd=$(mem_field "$tmp" verify)
  mem_verify "$vcmd"
  vrc=$?
  # The command is quoted back because the fault may be the frontmatter's
  # reading of it rather than the claim itself.
  [[ "$vrc" -eq 0 ]] || { rm -f "$tmp"
    die "its verify: exited $vrc, so the claim is not confirmed; leave it open in the queue
  verify: $vcmd"; }

  # A project's first fact starts its store, and a rollback takes the store back.
  # Only inside the folder the harness keeps for the project: with none, no
  # session ever started at $MEM_PROJECT_ROOT, so the working directory is not a
  # project — a store made there is one no session reads.
  local fresh=""
  if [[ ! -f "$MEMORY_FILE" ]]; then
    [[ -d "$(dirname "$MEM_DIR")" ]] || { rm -f "$tmp"
      die "no session has started at $MEM_PROJECT_ROOT, so it has no store to start; run from the project's root"; }
    fresh=1; mkdir -p "$MEM_DIR"; : > "$MEMORY_FILE"
  fi
  idx_bak=$(mktemp); cp "$MEMORY_FILE" "$idx_bak"
  if [[ -f "$file" ]]; then file_bak=$(mktemp); cp "$file" "$file_bak"; fi

  mv "$tmp" "$file"
  if grep -q "^- \[$name\](" "$MEMORY_FILE"; then
    local new; new=$(mf_pointer "$name" "$hook")
    awk -v n="- [$name](" -v line="$new" \
      'index($0, n) == 1 { print line; next } { print }' "$idx_bak" > "$MEMORY_FILE"
  else
    mf_pointer "$name" "$hook" >> "$MEMORY_FILE"
  fi

  if ! mf_lint; then
    cp "$idx_bak" "$MEMORY_FILE"
    if [[ -n "$file_bak" ]]; then cp "$file_bak" "$file"; else rm -f "$file"; fi
    if [[ -n "$fresh" ]]; then rm -f "$MEMORY_FILE"; rmdir "$MEM_DIR" 2>/dev/null; fi
    rm -f "$idx_bak" "$file_bak"
    die "the lint rejected this fact; the store is unchanged"
  fi
  rm -f "$idx_bak" "$file_bak"
  echo "fact written → $name"
}

mf_remove() {  # NAME
  local name="$1" file idx_bak file_bak
  file="$MEM_DIR/$name.md"
  [[ -f "$file" ]] || die "no fact named $name"

  idx_bak=$(mktemp); cp "$MEMORY_FILE" "$idx_bak"
  file_bak=$(mktemp); cp "$file" "$file_bak"

  printf -- '--- removed fact: %s ---\n' "$name"
  cat "$file"

  grep -v "^- \[$name\](" "$idx_bak" > "$MEMORY_FILE"
  rm -f "$file"

  if ! mf_lint; then
    cp "$idx_bak" "$MEMORY_FILE"; cp "$file_bak" "$file"
    rm -f "$idx_bak" "$file_bak"
    die "the lint rejected this removal; the store is unchanged"
  fi
  rm -f "$idx_bak" "$file_bak"
  echo "fact removed → $name" >&2
}

mf_verify() {  # NAME
  local file="$MEM_DIR/$1.md" rc
  [[ -f "$file" ]] || die "no fact named $1"
  mem_verify "$(mem_field "$file" verify)"; rc=$?
  echo "verify: $1 exited $rc"
  return "$rc"
}

# ---------------------------------------------------------------- self-test

# The fixture is a whole store, because a pointer and a fact file are only
# correct relative to each other.
self_test() {
  local d rc=0 out
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  printf '# F\n\n' > "$d/MEMORY.md"
  printf -- '- [keep](keep.md) — an existing fact\n' >> "$d/MEMORY.md"
  printf -- '---\nname: keep\ndescription: "d"\nmetadata:\n  type: reference\n  verify: true\n---\n\nbody\n' > "$d/keep.md"

  run() { MEMORY_FILE="$d/MEMORY.md" "$SELF" "$@"; }
  fact() {  # NAME VERIFY
    printf -- '---\nname: %s\ndescription: "d"\nmetadata:\n  type: reference\n  verify: %s\n---\n\nbody\n' "$1" "$2"
  }
  check() {  # DESCRIPTION CONDITION…
    local t="$1"; shift
    if "$@"; then echo "  ok   $t"; else echo "  FAIL $t" >&2; rc=1; fi
  }
  echo "memory_fact.sh --self-test"

  fact new true | run write new "when it matters" >/dev/null
  check "a new fact writes its file"    test -f "$d/new.md"
  check "and its pointer lands last"    \
    eval '[[ "$(tail -n1 "$d/MEMORY.md")" == "- [new](new.md) — when it matters" ]]'

  fact new 'test -e .' | run write new "a better hook" >/dev/null
  check "a rewrite replaces the pointer in place, not a second one" \
    eval '[[ $(grep -c "^- \[new\](" "$d/MEMORY.md") -eq 1 ]]'
  check "and keeps the store at two pointers" \
    eval '[[ $(grep -c "^- \[" "$d/MEMORY.md") -eq 2 ]]'

  check "a body whose name disagrees is refused" \
    eval '! fact other true | run write new "hook" >/dev/null 2>&1'
  check "a fact whose verify does not pass is refused" \
    eval '! fact failing false | run write failing "hook" >/dev/null 2>&1'
  check "and it leaves no file behind"  test ! -e "$d/failing.md"
  check "a fact whose verify cannot tell (75) is refused too" \
    eval '! fact tempfail "exit 75" | run write tempfail "hook" >/dev/null 2>&1'
  check "a body with no verify is refused" \
    eval '! printf -- "---\nname: v\ndescription: \"d\"\nmetadata:\n  type: reference\n---\n\nb\n" | run write v "hook" >/dev/null 2>&1'
  check "a pointer with no hook is refused" \
    eval '! fact h true | run write h "" >/dev/null 2>&1'
  check "a refused write leaves no file behind" test ! -e "$d/v.md"

  # The lint rejects an unknown type, so this exercises the rollback path itself.
  printf -- '---\nname: bad\ndescription: "d"\nmetadata:\n  type: nonsense\n  verify: true\n---\n\nb\n' \
    | run write bad "hook" >/dev/null 2>&1
  check "a write the lint rejects is rolled back whole" \
    eval '[[ ! -e "$d/bad.md" && $(grep -c "^- \[" "$d/MEMORY.md") -eq 2 ]]'

  # A project with no store yet: the first fact creates it, and a first fact
  # the lint rejects leaves no store behind.
  local e="$d/empty/memory"
  mkdir -p "$d/empty" "$d/none"
  fact first true | MEMORY_FILE="$e/MEMORY.md" "$SELF" write first "hook" >/dev/null
  check "a first fact creates the store, its file and its pointer" \
    eval '[[ -f "$e/first.md" && "$(cat "$e/MEMORY.md")" == "- [first](first.md) — hook" ]]'
  printf -- '---\nname: bad\ndescription: "d"\nmetadata:\n  type: nonsense\n  verify: true\n---\n\nb\n' \
    | MEMORY_FILE="$d/none/memory/MEMORY.md" "$SELF" write bad "hook" >/dev/null 2>&1
  check "a rejected first fact leaves no store" test ! -e "$d/none/memory"
  # A store's own folder as the working directory is how this one was misplaced.
  check "a first fact outside any project folder is refused" \
    eval '! fact stray true | MEMORY_FILE="$d/noproject/memory/MEMORY.md" "$SELF" write stray "hook" >/dev/null 2>&1'
  check "and creates nothing" test ! -e "$d/noproject"

  out=$(run remove new 2>/dev/null)
  check "a removal prints the fact it deleted" \
    eval '[[ "$out" == *"removed fact: new"* && "$out" == *"body"* ]]'
  check "and takes the file and the pointer together" \
    eval '[[ ! -e "$d/new.md" && $(grep -c "^- \[" "$d/MEMORY.md") -eq 1 ]]'
  check "removing what is not there is refused" \
    eval '! run remove nothing >/dev/null 2>&1'
  check "verify runs a fact's check and exits as it did" \
    eval '[[ "$(run verify keep)" == "verify: keep exited 0" ]]'
  check "verifying what is not there is refused" \
    eval '! run verify nothing >/dev/null 2>&1'

  # mem_field reads one scalar: the document's own field or metadata's, with
  # each quoting style's escaping undone and an unquoted one left alone.
  # Outside the store, which the lint sweeps for pointers on every write.
  mkdir -p "$d/fixture"
  printf -- '---\nname: n\ndescription: "say \\"hi\\""\nhook: \047it\047\047s\047\nother:\n  verify: wrong\nmetadata:\n  type: reference\n  verify: test -n "a\\"b"\n---\n\nb\n' > "$d/fixture/f.md"
  field() { mem_field "$d/fixture/f.md" "$1"; }
  check "a top-level field is read"           eval '[[ "$(field name)" == "n" ]]'
  check "a metadata field is read"            eval '[[ "$(field type)" == "reference" ]]'
  check "a field under any other block is not" \
    eval '[[ "$(field verify)" != "wrong" ]]'
  check "an unquoted scalar keeps its backslashes" \
    eval '[[ "$(field verify)" == '\''test -n "a\"b"'\'' ]]'
  check "a double-quoted scalar unescapes its quotes" \
    eval '[[ "$(field description)" == '\''say "hi"'\'' ]]'
  check "a single-quoted scalar undoubles its quotes" \
    eval '[[ "$(field hook)" == "it'\''s" ]]'
  check "a single-line value is not a block scalar" \
    eval '[[ -z "$(mem_block_fields "$d/fixture/f.md")" ]]'

  # Unrefused, this fact stores the indicator itself as its description: a
  # non-empty value every other check accepts, and the text below it is lost.
  printf -- '---\nname: blk\ndescription: |\n  a description over\n  two lines\nmetadata:\n  type: reference\n  verify: true\n---\n\nb\n' \
    | run write blk "hook" >/dev/null 2>&1
  check "a block scalar is refused, not read as its indicator" \
    eval '[[ ! -e "$d/blk.md" ]]'

  # The writer evals what it read, so the shape that broke it is tested whole.
  fact esc 'test -n "a\"b"' | run write esc "hook" >/dev/null 2>&1
  check "a fact whose verify carries escaped quotes is written" test -f "$d/esc.md"

  return $rc
}

# ---------------------------------------------------------------- main

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  write)  [[ $# -eq 3 ]] || die "usage: memory_fact.sh write <name> <pointer hook>  (fact on stdin)"
          mf_write "$2" "$3" ;;
  remove) [[ $# -eq 2 ]] || die "usage: memory_fact.sh remove <name>"
          mf_remove "$2" ;;
  verify) [[ $# -eq 2 ]] || die "usage: memory_fact.sh verify <name>"
          mf_verify "$2" ;;
  *) echo "usage: memory_fact.sh write <name> <hook> | remove <name> | verify <name> | --self-test" >&2; exit 2 ;;
esac
