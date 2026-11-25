#!/usr/bin/env bash
# memory_lib.sh — shared, sourced helpers for the memory scripts. The single owner
# of where memory lives, what a fact file and an index line look like, and which
# files hold durable text, so the lint, the checker and reconcile never re-derive
# them.
#
# Source it; do not execute. It intentionally does NOT set -e/-u (that belongs to
# the executing script).

# --- Where the store is ---------------------------------------------------
# One store per project. The harness keeps a folder for every directory a
# session starts in, ~/.claude/projects/<the path, every character but a letter
# or digit made '-'>, and the store is its memory/ subfolder. The harness
# shortens a name past 200 characters with a hash this does not reproduce, so
# a project that deep finds no store and the lint says so.

# mem_project_folder DIR — the harness folder for a project rooted at DIR.
mem_project_folder() { printf '%s/.claude/projects/%s' "$HOME" "${1//[^a-zA-Z0-9]/-}"; }

# mem_root DIR — the project DIR lies in (project_file.sh --root); DIR itself,
# failing, when it lies in none.
mem_root() {
  (cd "$1" 2>/dev/null && "$MEM_LIB_DIR/project_file.sh" --root 2>/dev/null) || { printf '%s' "$1"; return 1; }
}

# MEM_PROJECT_ROOT names the project when set, which is how memory_check.sh
# --all hands each store to a run of its own; else the working directory finds
# it. MEMORY_FILE overrides the store, for tests. With neither, a folder in no
# project sets MEM_NO_PROJECT: a root keeps no records, so the writer refuses.
MEM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_NO_PROJECT=0
# shellcheck disable=SC2034  # MEM_NO_PROJECT is read by memory_fact.sh
if [[ -z "${MEM_PROJECT_ROOT:-}" ]]; then
  MEM_PROJECT_ROOT=$(mem_root "$PWD") || [[ -n "${MEMORY_FILE:-}" ]] || MEM_NO_PROJECT=1
fi
MEM_CLAUDE_DIR="$MEM_PROJECT_ROOT/.claude"
if [[ -z "${MEMORY_FILE:-}" ]]; then
  MEMORY_FILE="$(mem_project_folder "$MEM_PROJECT_ROOT")/memory/MEMORY.md"
fi
export MEMORY_FILE

# --- Fact files -------------------------------------------------------------
# A fact is one Markdown file in the memory directory holding one claim.
# MEMORY.md is the index: one pointer line per fact, "- [name](name.md) — hook",
# and no fact text.
#
# Every fact carries `verify:`, a command exiting 0 while the claim holds, and
# running it is the whole of how the fact is checked. A command asking a live
# API exits 75 when it gets no answer: only an answer can contradict a fact, and
# a fact nobody could ask about is reported unchecked rather than counted held.
#
# A claim about a file is tested by reading that file, so its command names the
# ref it means and no local checkout can change the verdict.

MEM_DIR="$(dirname "$MEMORY_FILE")"

# --- Running a verify -------------------------------------------------------
# Every verify runs in one environment, built here whatever started the check:
# HOME, the system PATH from /etc/environment, and nothing else of the caller's.
# A fact the writer admits from a session is then a fact the night can check,
# and a tool found only on a session's PATH is refused at the write.
MEM_VERIFY_PATH=$(sed -n 's/^PATH="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/environment 2>/dev/null)
MEM_VERIFY_PATH=${MEM_VERIFY_PATH:-/usr/local/bin:/usr/bin:/bin}

# mem_verify CMD [ERRFILE] — exit status of CMD run once from the project root in
# that environment, its stderr written to ERRFILE, else discarded. Without
# pipefail: a verify is written as `git show … | grep -q …`, whose verdict is
# grep's, and grep -q exiting on its first match kills the producer with
# SIGPIPE, which pipefail would report as the claim being false.
mem_verify() {
  ( cd "$MEM_PROJECT_ROOT" \
    && env -i HOME="$HOME" LOGNAME="${LOGNAME:-$(id -un)}" PATH="$MEM_VERIFY_PATH" LANG=C.UTF-8 \
         bash -c "$1" ) >/dev/null 2>"${2:-/dev/null}"
}

# mem_shallow CMD — true when CMD checks only that a file is there or that a
# script's own self-test passes: every part it joins with && is `test -s|-f|-e
# PATH` or `[VAR=VALUE …] CMD --self-test`. Such a check passes whatever a live
# system does, so it cannot contradict a claim about one.
MEM_SHALLOW_PART='(test -[sfe] [^ &;|]+|([A-Z_]+=[^ ]+ )*[^ ]+ --self-test)'
MEM_SHALLOW_RE="^${MEM_SHALLOW_PART}( && ${MEM_SHALLOW_PART})*\$"
mem_shallow() { [[ "$1" =~ $MEM_SHALLOW_RE ]]; }

# Both constants below are read by the scripts that source this file
# (memory_lint.sh), never here, which a linter cannot see across a `source`.
# shellcheck disable=SC2034
MEM_TYPES='user feedback project reference'

# The one grammar of an index line. The name in brackets is the file's stem.
# shellcheck disable=SC2034
MEM_POINTER_RE='^- \[([a-z0-9-]+)\]\(([a-z0-9-]+)\.md\) — .'

# mem_facts — path of every fact file, one per line.
mem_facts() {
  local f
  for f in "$MEM_DIR"/*.md; do
    [[ -f "$f" && "$(basename "$f")" != MEMORY.md ]] && printf '%s\n' "$f"
  done
}

# mem_stores — print "TYPE<TAB>PATH" for every file holding durable text, one per
# line: a claim is a fact file, a mandate is the CLAUDE.md of its scope, and a
# procedure invoked by name is a skill or a command, project or global. Facts are
# emitted one by one, since MEMORY.md holds pointers and no text.
# settings.local.json states no claim, so it is not here. Vendor skills sit a
# level deeper, under skills/synced/<id>/, beyond this glob's reach.
mem_stores() {
  local s d
  while IFS= read -r s; do
    [[ -n "$s" ]] && printf 'fact\t%s\n' "$s"
  done < <(mem_facts)
  [[ -f "$MEM_PROJECT_ROOT/CLAUDE.md" ]] && printf 'claude-project\t%s\n' "$MEM_PROJECT_ROOT/CLAUDE.md"
  [[ -f "$HOME/.claude/CLAUDE.md" ]]     && printf 'claude-global\t%s\n'  "$HOME/.claude/CLAUDE.md"
  for d in "$MEM_CLAUDE_DIR" "$HOME/.claude"; do
    for s in "$d"/skills/*/SKILL.md; do
      [[ -f "$s" ]] && printf 'skill\t%s\n' "$s"
    done
    for s in "$d"/commands/*.md; do
      [[ -f "$s" ]] && printf 'command\t%s\n' "$s"
    done
  done
}

# mem_field FILE NAME — value of a frontmatter field, either the document's own
# or one under metadata. Prints nothing when absent. Strips one layer of matching
# quotes and undoes that style's own escaping, so a value YAML chose to quote
# reaches the shell as the text that was written.
#
# A value is the rest of its own line, so YAML's multi-line forms would return
# their `|` or `>` indicator and lose the text beneath it. mem_block_fields names
# them, and the writer and the lint both refuse them, so none reaches the store.
mem_field() {
  awk -v want="$2" '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---"      { exit }
    !fm                    { next }
    {
      indent = match($0, /[^ \t]/) - 1
      line = $0; sub(/^[ \t]+/, "", line)
      i = index(line, ":"); if (i == 0) next
      k = substr(line, 1, i - 1)
      v = substr(line, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      # A top-level key with no value opens a block that owns every deeper key,
      # and metadata is the only block whose keys this store reads.
      if (indent == 0) parent = (v == "" ? k : "")
      if (k != want || (indent > 0 && parent != "metadata")) next
      # Each style escapes only its own delimiter — \" within double quotes, a
      # doubled '' within single. An unquoted scalar carries every character
      # literally, backslashes included, as its own shell quoting.
      dq = (v ~ /^".*"$/); sq = (v ~ /^\047.*\047$/)
      if (dq || sq) v = substr(v, 2, length(v) - 2)
      if (dq) gsub(/\\"/, "\"", v)
      if (sq) gsub(/\047\047/, "\047", v)
      print v; exit
    }
  ' "$1"
}

# mem_block_fields FILE — names of the frontmatter fields whose value opens one
# of YAML's multi-line forms (`|` or `>`, with either indicator). One per line,
# nothing when there are none.
mem_block_fields() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---"      { exit }
    !fm                    { next }
    {
      line = $0; sub(/^[ \t]+/, "", line)
      i = index(line, ":"); if (i == 0) next
      v = substr(line, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^[|>][0-9+-]*$/) print substr(line, 1, i - 1)
    }
  ' "$1"
}

# mem_tokens TEXT — content tokens for overlap scoring: lowercase alnum words of
# length ≥ 4, common stopwords removed, de-duplicated, one per line.
mem_tokens() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' \
    | awk 'length($0) >= 4' \
    | grep -ivxE 'this|that|with|from|into|when|then|than|they|them|their|there|here|have|will|shall|your|yours|been|were|what|which|while|where|whom|does|done|also|each|only|some|such|over|under|after|before|about|would|could|should|because|just|like|using|used|use|via|the|and|for|not|but|are|was' \
    | sort -u
}

# --- Self-test ----------------------------------------------------------------
# Executed rather than sourced, the file takes one argument, --self-test, and
# runs every function above over a fixture store. The guard compares this file
# with the script being run, so a script sourcing it with its own --self-test in
# $1 never reaches the branch. It runs last, once every function is defined.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${1:-}" == "--self-test" ]] || {
    echo "memory_lib.sh: source this file; executed, it takes only --self-test" >&2; exit 2; }
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  MEM_PROJECT_ROOT="$fx/proj"; MEM_CLAUDE_DIR="$fx/proj/.claude"; MEM_DIR="$fx/mem"
  HOME="$fx/home"
  mkdir -p "$MEM_DIR" "$MEM_CLAUDE_DIR/skills/s" "$MEM_CLAUDE_DIR/commands" \
    "$HOME/.claude/commands"
  touch "$MEM_PROJECT_ROOT/CLAUDE.md" "$HOME/.claude/CLAUDE.md" \
    "$MEM_CLAUDE_DIR/skills/s/SKILL.md" "$HOME/.claude/commands/c.md" "$MEM_DIR/MEMORY.md"
  cat > "$MEM_DIR/a.md" <<'FACT'
---
name: a
description: "say \"hi\""
other:
  type: wrong
metadata:
  type: reference
  verify: 'it''s here'
  body: |
---
name: not-frontmatter
FACT
  printf -- '---\nname: b\nhook: >-\n---\n' > "$MEM_DIR/b.md"
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  tap_is 'mem_field reads a top-level key' "$(mem_field "$MEM_DIR/a.md" name)" a
  tap_is 'mem_field undoes double quotes' "$(mem_field "$MEM_DIR/a.md" description)" 'say "hi"'
  tap_is 'mem_field reads metadata, not another block' "$(mem_field "$MEM_DIR/a.md" type)" reference
  tap_is 'mem_field undoes single quotes' "$(mem_field "$MEM_DIR/a.md" verify)" "it's here"
  tap_is 'mem_field reads an absent key as empty' "$(mem_field "$MEM_DIR/a.md" nothing)" ''
  tap_is 'mem_block_fields names a | value' "$(mem_block_fields "$MEM_DIR/a.md")" 'body'
  tap_is 'mem_block_fields names a >- value' "$(mem_block_fields "$MEM_DIR/b.md")" 'hook'
  tap_is 'mem_facts skips the index' "$(mem_facts | paste -sd' ')" "$MEM_DIR/a.md $MEM_DIR/b.md"
  tap_is 'mem_tokens lowercases and drops short and stop words' "$(mem_tokens 'This Rails platform: rails PLATFORM, with an API' | paste -sd' ')" 'platform rails'
  tap_is 'mem_stores lists facts, both CLAUDE.md, skills and commands' "$(mem_stores | sed "s#$fx/##; s#mem/##" | tr '\t' ' ' | paste -sd'|')" \
    "fact a.md|fact b.md|claude-project proj/CLAUDE.md|claude-global home/.claude/CLAUDE.md|skill proj/.claude/skills/s/SKILL.md|command home/.claude/commands/c.md"
  tap_project "$fx/proj"; mkdir -p "$fx/proj/sub/deeper/.claude"
  tap_is 'mem_project_folder names the folder the harness keeps' "$(mem_project_folder /a/b.c_d)" "$HOME/.claude/projects/-a-b-c-d"
  tap_is 'mem_root walks up from a clone to its project' "$(mem_root "$fx/proj/sub/deeper")" "$fx/proj"
  tap_is 'mem_root in no project answers the directory it was given' "$(mem_root "$fx/none")" "$fx/none"
  tap_fails 'and fails' mem_root "$fx/none"
  mkdir -p "$fx/none"
  # where <dir> [VAR=value…] — the project and the no-project flag a source there sets.
  where() {
    (cd "$1" && env -u MEM_PROJECT_ROOT -u MEMORY_FILE "${@:2}" \
      bash -c '. "$1"; printf "%s %s" "$MEM_PROJECT_ROOT" "$MEM_NO_PROJECT"' _ "$MEM_LIB_DIR/memory_lib.sh")
  }
  tap_is 'the store is the project a clone lies in' "$(where "$fx/proj/sub/deeper")" "$fx/proj 0"
  tap_is 'a folder in no project sets the flag' "$(where "$fx/none")" "$fx/none 1"
  tap_is 'MEMORY_FILE names the store, so no project is needed' "$(where "$fx/none" MEMORY_FILE=/x/MEMORY.md)" "$fx/none 0"
  tap_is 'MEM_PROJECT_ROOT names the project' "$(where "$fx/none" MEM_PROJECT_ROOT=/p)" "/p 0"
  export MEM_LEAK=x
  mem_verify 'test -z "${MEM_LEAK:-}"'; tap_is 'mem_verify passes none of the caller environment' "$?" 0
  mem_verify "test \"\$PATH\" = '$MEM_VERIFY_PATH' && test \"\$PWD\" = '$MEM_PROJECT_ROOT'"
  tap_is 'mem_verify runs on the declared PATH from the project root' "$?" 0
  mem_verify 'exit 75'; tap_is 'mem_verify returns the exit status' "$?" 75
  mem_verify 'echo out; echo said >&2' "$fx/err"
  tap_is 'mem_verify writes stderr alone to the file it is given' "$(cat "$fx/err")" said
  tap_is 'and discards it with none given' "$(mem_verify 'echo said >&2' 2>&1)" ''
  mem_verify 'yes | head -1 | grep -q y'; tap_is 'mem_verify runs without pipefail' "$?" 0
  tap_is 'mem_shallow names a presence or self-test chain, and nothing that reads a source' \
    "$(for c in 'test -s .secrets/a && test -f b' 'X=1 .claude/scripts/a.sh --self-test' 'test -e a && b.sh --self-test' \
                'scripts/git_fact.sh r ref p pat' 'test -f a && ! git -C r cat-file -e x' \
                'aws configure get region' 'test -s a; curl x'; do
         mem_shallow "$c" && echo y || echo n; done | paste -sd' ')" 'y y y n n n n'
  tap_end
fi
