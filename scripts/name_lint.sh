#!/usr/bin/env bash
# name_lint.sh — the gate for anything written as prose: a skill, a command, a
# CLAUDE.md rule. None can carry a `verify:`, but nearly all name something — a
# path, a script, a slash command — and the commonest way one dies is that the
# thing it names is renamed or deleted.
#
# Every name a file mentions must resolve. This catches text going stale; it says
# nothing about whether the text is good advice.
#
# Four outcomes, all printed, so silence means checked:
#   ok         resolved in this tree
#   elsewhere  resolved only in repositories nested under the project, every one
#              of which is named. Not a failure: a skill may document another
#              repo. It is flagged because the name says nothing about which one,
#              and listing them all is what shows whether the intended one holds it.
#   MISSING    looks like a name and resolves nowhere   -> exit 1
#   skipped    not a name, and why
#
# --gate prints one more, `new`: a name this edit left unresolved.
#
# A name is a backticked token ending in `/`, or in a known extension after a
# stem, or a slash command. A namespaced slash command counts outside backticks
# too, because it cannot be mistaken for anything else. A bracket, a quote or a `$` means the token is code or
# a path computed when the step runs, not a fixed name: `(/)` is a pass mark and
# `"$D/pr.json"` is a scratch file. A token holding `://` is a URL, never a path. `origin/main` is a git ref; `memory_check.last`
# is a runtime artifact whose absence is normal; `<KEY>.md` names a shape.
#
# A relative name resolves against one project per run — `--project DIR`, else the
# project holding the first file, else the one above $PWD — then `~/.claude`, then
# $HOME. Nested repositories are searched under that same project, so a clone under
# an unrelated tree cannot resolve a name. Each is read twice: its working tree, and
# its origin default branch, because a clone checked out on a feature branch is not
# what a doc describes. A hit on the default branch alone is marked with that ref.
# The project is taken from the files
# rather than the caller's directory, because a verdict that moves with cwd is not
# a gate. Every verdict rests on the roots, so the run prints them: a global doc
# naming a project's scripts reads MISSING under a run whose project lacks them.
#
# Usage:
#   name_lint.sh [--project DIR] <file> …           report; exit 1 on a missing name
#   name_lint.sh [--project DIR] --gate <file> …    exit 1 on a name this edit
#                                                   left unresolved
#   name_lint.sh --self-test
#
# Exit 0 clean, 1 a name failed the check, 2 the check could not run.
#
# --gate is the form an edit is gated by, and the only form a selftest can run
# unattended: it takes no baseline and needs no project, because it compares a file
# against itself. It reads each file as HEAD holds it and as the tree holds it now,
# and fails only on a name that has become unresolved, naming each. Comparing the
# two sets rather than their sizes catches an edit that fixes one name and breaks
# another. A file HEAD does not hold is gated against nothing, so every unresolved
# name in it is new. Both readings resolve against the tree as it is now, so what
# the gate answers is whether this edit left a name nothing holds — a name broken
# by deleting its target changes no file, and is caught by the grep half of the
# rename rule, not here.
set -uo pipefail

EXTS='sh|py|md|json|yaml|yml'
NL_PROJECT=""   # the run's project; --project names it, else the first file's
NL_TMP=""       # scratch for the HEAD copy --gate reads
# Where a bare basename lives, in this tree and in a nested one alike.
NL_SUBDIRS='scripts helpers .claude/scripts .claude/helpers'
# Harness commands own no file. Verified present in the installed binary.
BUILTINS=' compact clear help config model memory init mcp hooks permissions login bug rename '

# nl_project DIR — the nearest ancestor holding a .claude, or nothing. $HOME is
# never one: the .claude it holds is the global tree, already a root of its own,
# and calling it a project makes every clone under $HOME a nested repository.
nl_project() {
  local d; d=$(cd "$1" 2>/dev/null && pwd) || return
  while [[ "$d" != / ]]; do
    [[ -d "$d/.claude" && "$d" != "$HOME" ]] && { printf '%s\n' "$d"; return; }
    d=$(dirname "$d")
  done
}

# nl_roots FILE — where a relative name may resolve: the project the file belongs
# to, the run's project, then the global tree, then $HOME. Both projects, because
# a global rule may name a project skill and a project doc may be linted from
# outside its own tree.
nl_roots() {
  nl_project "$(dirname "$1")"
  [[ -n "$NL_PROJECT" ]] && printf '%s\n' "$NL_PROJECT"
  printf '%s\n%s\n' "$HOME/.claude" "$HOME"
}

# nl_nested — repositories cloned inside the run's project, found once per run, one
# per line as "<dir> <default ref>"; the ref is empty when origin names no HEAD.
# A single space is "computed, none": empty would re-run the find on every token.
# Depth 4 reaches a clone one level below a grouping directory, such as
# <project>/api/2.0/<repo>/.git; depth 3 stopped at <project>/api/<repo>.
NL_NESTED=""
nl_nested() {
  local r
  [[ -n "$NL_NESTED" ]] && { printf '%s' "$NL_NESTED"; return; }
  [[ -n "$NL_PROJECT" ]] || { NL_NESTED=" "; printf '%s' "$NL_NESTED"; return; }
  NL_NESTED=$(find "$NL_PROJECT" -maxdepth 4 -name .git -not -path "$NL_PROJECT/.git" \
                -printf '%h\n' 2>/dev/null | sort | while read -r r; do
                printf '%s %s\n' "$r" \
                  "$(git -C "$r" rev-parse --abbrev-ref origin/HEAD 2>/dev/null)"
              done)
  : "${NL_NESTED:= }"
  printf '%s' "$NL_NESTED"
}

# nl_held DIR REF PATH… — where the nested repository holds any PATH: "tree" in its
# working tree, the ref when only its default branch holds one, else nothing. The
# branch is asked once for every path, so a miss costs one git per repository.
nl_held() {
  local dir="$1" ref="$2" p; shift 2
  for p in "$@"; do [[ -e "$dir/$p" ]] && { echo tree; return 0; }; done
  [[ -n "$ref" ]] || return 1
  # Captured, not piped into grep -q: under pipefail, grep stopping at the first
  # hit cuts git off by SIGPIPE, and a held name would read as missing.
  local found
  found=$(for p in "$@"; do printf '%s:%s\n' "$ref" "$p"; done \
    | git -C "$dir" cat-file --batch-check 2>/dev/null)
  grep -qvE ' missing$|^$' <<<"$found" && { echo "$ref"; return 0; }
  return 1
}

# nl_elsewhere TOKEN — every nested repository holding the name, comma-separated,
# or nothing. A bare basename is looked for in the same subdirectories as in this
# tree: a script named without its directory is the commonest way a doc cites
# another repo.
nl_elsewhere() {
  local r ref n at
  local -a hits=() paths=("$1")
  [[ "$1" == /* || "$1" == '~'/* ]] && return 1
  [[ "$1" == */* ]] || for n in $NL_SUBDIRS; do paths+=("$n/$1"); done
  while read -r r ref; do
    [[ -n "$r" ]] || continue
    at=$(nl_held "$r" "$ref" "${paths[@]}") || continue
    if [[ "$at" == tree ]]; then hits+=("${r##*/}"); else hits+=("${r##*/} ($at)"); fi
  done <<<"$(nl_nested)"
  (( ${#hits[@]} )) || return 1
  printf '%s' "${hits[0]}"
  (( ${#hits[@]} > 1 )) && printf ', %s' "${hits[@]:1}"
  return 0
}

# nl_resolve TOKEN FILE — 0 when the name exists somewhere it could.
nl_resolve() {
  local t="$1" r n
  # Read whole, once: a loop that returns on the first hit would close a pipe
  # nl_roots is still writing to, and where SIGPIPE is ignored, as on GitHub's
  # runners, its printf reports the broken pipe on stderr.
  local -a roots
  mapfile -t roots < <(nl_roots "$2")
  case "$t" in
    /*)  [[ -e "$t" ]] && return 0 ;;
    '~'/*) [[ -e "${t/#\~/$HOME}" ]] && return 0 ;;
  esac
  # a slash command: a file in either tree, or a harness built-in
  if [[ "$t" =~ ^/[a-z][a-z0-9:_-]*$ ]]; then
    n="${t#/}"
    [[ "$BUILTINS" == *" $n "* ]] && return 0
    for r in "${roots[@]}"; do
      [[ -f "$r/.claude/commands/$n.md" || -f "$r/.claude/skills/$n/SKILL.md" ]] && return 0
      [[ -f "$r/commands/$n.md"         || -f "$r/skills/$n/SKILL.md"         ]] && return 0
    done
    return 1
  fi
  for r in "${roots[@]}"; do
    [[ -e "$r/$t" ]] && return 0
  done
  # a bare basename: the places a script or helper actually lives
  if [[ "$t" != */* ]]; then
    for r in "${roots[@]}"; do
      for n in $NL_SUBDIRS; do
        [[ -e "$r/$n/$t" ]] && return 0
      done
    done
  fi
  return 1
}

# nl_classify TOKEN — "name", or "skip: <reason>".
nl_classify() {
  local t="$1"
  # A fixed name holds no bracket, no quote and no shell expansion, so `(/)` is a
  # pass mark and `"$D/pr.json"` is computed when the step runs.
  [[ "$t" == *[\(\)\"\'\$]* ]] && { echo "skip: code or a runtime path, not a fixed name"; return; }
  # A placeholder or a glob names a shape, not a file: `<KEY>.md`, `*.yml`.
  [[ "$t" == *[\<\>\*\?]* ]] && { echo "skip: a placeholder or glob, not one file"; return; }
  # A URL names a page, not a path in any tree, though it may end in `/`.
  [[ "$t" == *://* ]]                     && { echo "skip: a URL, not a path"; return; }
  [[ "$t" == */ ]]                        && { echo name; return; }
  [[ "$t" =~ ^/[a-z][a-z0-9:_-]*$ ]]      && { echo name; return; }
  # A stem is required: `.py` alone is an extension being discussed, not a file.
  [[ "$t" =~ [^/.]\.($EXTS)$ ]]           && { echo name; return; }
  [[ "$t" == *.* ]] \
    && { echo "skip: a runtime artifact or an extension this lint does not own"; return; }
  [[ "$t" == */* ]] && { echo "skip: not a path — no extension and no trailing slash"; return; }
  echo "skip: prose, not a name"
}

# nl_tokens FILE — every backticked token in FILE, unique, one per line. One
# definition, so a check that counts tokens cannot count them differently.
nl_tokens() {
  { grep -o '`[^`]*`' "$1" | tr -d '`' | tr ' ' '\n' | sed 's/[),.:;]$//'
    # A namespaced slash command is unambiguous outside backticks too, and half the
    # references are written that way. The boundary is what keeps the `main:x` of
    # `origin/main:x` out: a command's slash never follows a word character.
    grep -oE '(^|[^A-Za-z0-9_./<-])/[a-z][a-z0-9_-]*:[a-z0-9_-]+' "$1" | sed 's|^[^/]*/|/|'
  } | sort -u
}

nl_file() {  # FILE
  local f="$1" t verdict where miss=0 okn=0 skipn=0 elsen=0
  echo "name_lint: $f"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    verdict=$(nl_classify "$t")
    if [[ "$verdict" != name ]]; then
      printf '  skipped    %-44s %s\n' "$t" "${verdict#skip: }"; skipn=$((skipn+1)); continue
    fi
    if nl_resolve "$t" "$f"; then printf '  ok         %s\n' "$t"; okn=$((okn+1))
    elif where=$(nl_elsewhere "$t"); then
      printf '  elsewhere  %-44s in %s\n' "$t" "$where"; elsen=$((elsen+1))
    else printf '  MISSING    %s\n' "$t"; miss=$((miss+1)); fi
  done < <(nl_tokens "$f")
  echo "  $okn resolved, $elsen elsewhere, $miss missing, $skipn not names"
  return $(( miss > 0 ))
}

# nl_missing FILE — the names FILE leaves unresolved, one per line.
nl_missing() { nl_file "$1" | sed -n 's/^  MISSING    //p' | sort -u; }

# nl_gate FILE — 0 unless the edit left a name unresolved, 2 when it cannot be
# told. The HEAD copy is read outside the tree, so the run's project is what pins
# its roots: a file's own project is one of them, and a copy of it has none.
nl_gate() {
  local f top rel head before after n
  f=$(realpath -- "$1")
  top=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null) || {
    echo "name_lint: $1 is in no git repo, so nothing states which names it had" >&2
    return 2; }
  rel="${f#"$top"/}"
  head="$NL_TMP/$(basename "$f")"
  if git -C "$top" show "HEAD:$rel" > "$head" 2>/dev/null
  then before=$(nl_missing "$head"); else before=""; fi
  after=$(nl_missing "$f")
  local -a new=()
  while IFS= read -r n; do [[ -n "$n" ]] && new+=("$n"); done < <(
    comm -13 <(printf '%s\n' "$before" | sed '/^$/d') <(printf '%s\n' "$after" | sed '/^$/d'))
  printf 'gate %s: %s unresolved before this edit, %s now\n' "$rel" \
    "$(printf '%s\n' "$before" | grep -c .)" "$(printf '%s\n' "$after" | grep -c .)"
  [[ ${#new[@]} -eq 0 ]] && return 0
  for n in "${new[@]}"; do printf '  new        %s\n' "$n"; done
  return 1
}

# ---------------------------------------------------------------- self-test
self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local d rc=0 out self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  mkdir -p "$d/.claude/scripts" "$d/.claude/skills/probe" "$d/.claude/skills/probe:sub"
  : > "$d/.claude/scripts/real.sh"
  : > "$d/.claude/skills/probe/SKILL.md"
  : > "$d/.claude/skills/probe:sub/SKILL.md"
  mkdir -p "$d/api/other-repo/.git" "$d/api/other-repo/scripts" "$d/api/other-repo/postman"
  : > "$d/api/other-repo/scripts/theirs.py"
  # A real clone checked out on a feature branch that lacks what its default holds.
  local b="$d/api/branchy"
  mkdir -p "$b/postman"; : > "$b/postman/a.json"
  git -C "$b" init -q -b main
  git -C "$b" -c user.email=t@t -c user.name=t add postman
  git -C "$b" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$b" update-ref refs/remotes/origin/main HEAD
  git -C "$b" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$b" checkout -q -b feature
  git -C "$b" rm -rq postman
  git -C "$b" -c user.email=t@t -c user.name=t commit -qm drop
  cat > "$d/doc.md" <<'DOC'
Run `.claude/scripts/real.sh` and then `real.sh`, or `/probe`, or `/compact`.
Directories like `.claude/scripts/` are names too; a page like `https://example.invalid/jobs/` is not.
Never `.claude/scripts/gone.sh`, and `/nosuchcommand` is not there either.
`scripts/theirs.py` belongs to another repository cloned inside this one.
Prose such as `origin/main`, `memory_check.last` and `PLUGIN_TABLE` is not a name.
A results table marks a pass `(/)` and a failure `(x)`.
Runtime paths like `"$D/out.json"`, fragments like `'/def` and code like `send_file("/uploads/`.
Run /probe:sub with no backticks, and read git show origin/main:doc.md, which is a ref.
A bare `theirs.py` names a script the nested repository keeps under scripts/.
`postman/` is in one clone's tree and only on the other's default branch.
DOC
  cat > "$d/other.md" <<'DOC'
Only `scripts/theirs.py`, which another repo owns, and `.claude/scripts/real.sh`.
DOC
  # $out is read by the check expressions below, which are eval'd strings.
  # shellcheck disable=SC2034
  out=$("$self" --project "$d" "$d/doc.md" 2>&1); rc=$?
  check() { if eval "$2"; then tap_ok "$1"; else tap_not_ok "$1"; fi; }
  check "a path under the file's own project resolves" 'grep -q "ok         .claude/scripts/real.sh" <<<"$out"'
  check "a bare script basename resolves"              'grep -q "ok         real.sh" <<<"$out"'
  check "a project slash command resolves"             'grep -q "ok         /probe" <<<"$out"'
  check "a harness built-in resolves"                  'grep -q "ok         /compact" <<<"$out"'
  check "a trailing slash is a directory name"         'grep -q "ok         .claude/scripts/" <<<"$out"'
  check "a URL ending in a slash is not a directory"  'grep -q "skipped    https://example.invalid/jobs/ .*a URL" <<<"$out"'
  check "a deleted script is MISSING"                  'grep -q "MISSING    .claude/scripts/gone.sh" <<<"$out"'
  check "an unknown slash command is MISSING"          'grep -q "MISSING    /nosuchcommand" <<<"$out"'
  check "a missing name fails the run"                 '[[ '"$rc"' -eq 1 ]]'
  check "a git ref is skipped, with the reason"        'grep -q "skipped    origin/main .*no extension" <<<"$out"'
  check "a runtime artifact is skipped, with the reason" 'grep -q "skipped    memory_check.last .*runtime artifact" <<<"$out"'
  check "a bare word is skipped as prose"              'grep -q "skipped    PLUGIN_TABLE .*prose" <<<"$out"'
  check "a bracketed pass mark is not the root directory" \
    'grep -q "skipped    (/ .*not a fixed name" <<<"$out"'
  check "a runtime path is not a fixed name"           'grep -q "out.json.*not a fixed name" <<<"$out"'
  check "a quoted command fragment is not a slash command" \
    'grep -q "skipped    ./def .*not a fixed name" <<<"$out"'
  check "a line of code is not a path"                 'grep -q "send_file.*not a fixed name" <<<"$out"'
  check "a name living only in a nested repo is elsewhere, and names it" \
    'grep -q "elsewhere  scripts/theirs.py .* in other-repo" <<<"$out"'
  check "a bare basename in a nested repo is found where it lives, not only at its root" \
    'grep -q "elsewhere  theirs.py .* in other-repo" <<<"$out"'
  check "a name only on a nested clone's default branch is found, marked with that ref" \
    'grep -q "elsewhere  postman/ .* in branchy (origin/main)" <<<"$out"'
  check "every nested repo holding a name is listed, not only the first" \
    'grep -q "elsewhere  postman/ .* in branchy (origin/main), other-repo$" <<<"$out"'
  check "a name one repo holds lists that repo alone" \
    'grep -q "elsewhere  scripts/theirs.py .* in other-repo$" <<<"$out"'
  check "an unbackticked namespaced command is a name, and resolves" \
    'grep -q "ok         /probe:sub" <<<"$out"'
  check "a git ref is not a namespaced command, so it is never read as one" \
    '! grep -q "main:doc.md" <<<"$out"'
  check "elsewhere is not a failure, so a doc naming another repo passes" \
    '"'"$self"'" --project "'"$d"'" "'"$d"'/other.md" >/dev/null 2>&1'
  mkdir -p "$d/deep"; cp "$d/doc.md" "$d/deep/doc.md"
  check "the home tree is not a project, since ~/.claude is a root of its own" \
    '[[ "$(cd "'"$d"'/deep" && HOME="'"$d"'" "'"$self"'" doc.md 2>&1 | head -1)" \
        == "name_lint: relative names resolve in '"$d"'/.claude '"$d"'" ]]'
  check "the report names the roots every verdict depends on" \
    'grep -q "^name_lint: relative names resolve in .*'"$d"'" <<<"$out"'
  tap_is "the same file and project lint the same from any cwd" \
    "$(cd / && "$self" --project "$d" "$d/doc.md" 2>&1)" "$out"
  check "the project is the linted file's, so no --project is needed from elsewhere" \
    'grep -q "^name_lint: relative names resolve in '"$d"' " \
       <<<"$(cd / && "'"$self"'" "'"$d"'/doc.md" 2>&1)"'
  check "a clone outside the named project resolves no name" \
    '[[ "$(cd / && "'"$self"'" --project "'"$d"'/.claude" "'"$d"'/doc.md" 2>&1 \
        | grep -c "^  MISSING")" == 5 ]]'
  check "a --project that is not a directory is a usage error" \
    '{ "'"$self"'" --project "'"$d"'/nope" "'"$d"'/doc.md" >/dev/null 2>&1; [[ $? -eq 2 ]]; }'
  check "an unknown flag is a usage error, not a filename" \
    '{ "'"$self"'" --nope "'"$d"'/doc.md" >/dev/null 2>&1; [[ $? -eq 2 ]]; }'
  # --gate reads what HEAD holds, so the fixture needs a history.
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  git -C "$d" add doc.md other.md .claude >/dev/null; git -C "$d" commit -qm base
  g() { (cd "$d" && "$self" --project "$d" --gate doc.md 2>&1); }
  check "a file unchanged since HEAD passes, though names are missing in both" \
    'g >/dev/null && grep -q "gate doc.md: 2 unresolved before this edit, 2 now" <<<"$(g)"'
  echo 'And never `.claude/scripts/fresh.sh` either.' >> "$d/doc.md"
  check "a newly unresolved name fails the gate"          '! g >/dev/null'
  check "and the gate names it, so the failure is actionable" \
    'grep -q "^  new        .claude/scripts/fresh.sh$" <<<"$(g)"'
  check "a name already unresolved at HEAD is not reported as new" \
    '[[ "$(grep -c "^  new " <<<"$(g)")" == 1 ]]'
  git -C "$d" checkout -q -- doc.md
  # The rule is "no new unresolved name", which a count cannot express: one name
  # dropped and another broken leaves the count where it was. Both readings
  # resolve against the tree as it is now, so only the text differs.
  sed -i 's|scripts/gone.sh|scripts/real.sh|' "$d/doc.md"
  echo 'Nor `/alsogone`.' >> "$d/doc.md"
  check "one name dropped and another broken fails, at an unchanged count" \
    '! g >/dev/null && grep -q "2 unresolved before this edit, 2 now" <<<"$(g)"'
  git -C "$d" checkout -q -- doc.md
  cp "$d/doc.md" "$d/fresh.md"
  check "a file HEAD does not hold is gated against nothing" \
    '[[ "$(cd "'"$d"'" && "'"$self"'" --project "'"$d"'" --gate fresh.md 2>&1 \
        | grep -c "0 unresolved before this edit, 2 now")" == 1 ]]'
  rm "$d/fresh.md"
  check "a gate that cannot run is refused with 2, not failed with 1" \
    '{ out2=$(cd / && "'"$self"'" --project "'"$d"'" --gate /etc/hostname 2>&1); [[ $? -eq 2 ]]; } \
     && grep -q "is in no git repo" <<<"$out2"'

  check "every token is accounted for, so silence means checked" \
    '[[ $(grep -cE "^  (ok|elsewhere|MISSING|skipped) " <<<"$out") \
        -eq $(nl_tokens "'"$d"'/doc.md" | grep -c .) ]]'
}

# ---------------------------------------------------------------- main
usage() { echo "usage: name_lint.sh [--project DIR] [--gate] <file> …" >&2; exit 2; }

[[ "${1:-}" == "--self-test" ]] && { self_test; tap_end; }

gate=0
while (( $# )); do
  case "$1" in
    --gate)    gate=1;  shift ;;
    --project) [[ $# -ge 2 && -d "${2:-}" ]] || usage; NL_PROJECT=$(cd "$2" && pwd); shift 2 ;;
    --*)       usage ;;
    *)         break ;;
  esac
done
(( $# )) || usage
for f in "$@"; do [[ -f "$f" ]] || { echo "name_lint: no file at $f" >&2; exit 2; }; done
: "${NL_PROJECT:=$(nl_project "$(dirname "$1")")}"
: "${NL_PROJECT:=$(nl_project "$PWD")}"
# Found here, in the run's own shell: every lookup runs in a command substitution,
# whose cache would die with it.
NL_NESTED=$(nl_nested)

# The roots decide every verdict, so a report that does not name them cannot be
# read: one file lints clean under one project and missing under another.
printf 'name_lint: relative names resolve in %s\n' \
  "$(nl_roots "$1" | awk 'NF && !seen[$0]++' | paste -sd' ')"
fail=0
if (( gate )); then
  NL_TMP=$(mktemp -d); trap 'rm -rf "$NL_TMP"' EXIT
  for f in "$@"; do
    nl_gate "$f"; case $? in 0) ;; 2) exit 2 ;; *) fail=1 ;; esac
  done
else
  for f in "$@"; do nl_file "$f" || fail=1; done
fi
exit "$fail"
