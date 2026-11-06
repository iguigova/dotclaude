#!/usr/bin/env bash
# Commit named paths in a tooling repo, gated by that repo's selftest. This is
# the one way agent tooling is committed without asking: a session calls it at
# the end of each verified change, an unattended /notes run included, and
# journal.sh calls it for the session history on every write.
#
# Usage:
#   tooling_commit.sh -m "<message>" -- <path>…
#   tooling_commit.sh --help
#   tooling_commit.sh --self-test
#
# A tooling repo is a local-only repo — no remote — that carries a selftest at
# scripts/selftest.sh or .claude/scripts/selftest.sh. Nothing it holds is
# published, so a commit there is a backup point and needs no approval. A repo
# with a remote is refused: a commit there reaches a team, and stays the user's.
# The user lifts that for one clone with `git config tooling.commit true`. The
# commit stays local, since this script never pushes.
#
# One call is one commit, so every path must be in the same repo. Paths are
# resolved through symlinks first, so a path reached through a link is committed
# in the repo that holds the file. A relative path resolves against the cwd, and
# one that is neither on disk nor tracked in its repo is refused, since it names
# a file that repo never had. The gate runs before anything is staged, and
# a red gate commits nothing. A commit of the session history alone is not
# gated: the gate checks code, and no check reads the history, so it could
# neither pass nor fail on it — gating it would only hold the audit trail back
# behind an unrelated red script. Only the named paths are staged and committed
# (--only), so another session's staged or dirty work is left as it was. A
# deleted path is committed as its deletion.
#
# A commit that changes a skill's or command's description, or its trigger cases,
# also passes those cases through skill_trigger_test.py, whose header states them;
# a description with no cases is refused.
#
# The message's subject, its first line, takes one of two forms: Conventional
# Commits, `type(scope)!: summary` with the scope and the `!` optional and the
# type one of TYPES, or ticket-first, `KEY-123: summary`. A subject in neither
# form is refused before the gate runs, so a guessed form never lands.
#
# Prints the new commit's short sha on stdout. Exit 0 committed, 1 refused, 2
# usage. Every refusal names its reason on stderr.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

GATES=(scripts/selftest.sh .claude/scripts/selftest.sh)
TYPES=(build chore ci docs feat fix perf refactor revert style test)
UNGATED=.claude/session_history.md
SELF=$(realpath -- "${BASH_SOURCE[0]}")

die()   { echo "tooling_commit.sh: $*" >&2; exit 1; }
usage() { echo "usage: tooling_commit.sh -m <message> -- <path>…" >&2; exit 2; }

# ---------------------------------------------------------------- resolve

# nearest_dir PATH — PATH if it is a directory, else its closest existing
# ancestor, so a deleted file still resolves to the repo that tracked it.
nearest_dir() {
  local d="$1"
  while [[ ! -d "$d" ]]; do d=$(dirname "$d"); done
  printf '%s\n' "$d"
}

repo_of() { git -C "$(nearest_dir "$1")" rev-parse --show-toplevel 2>/dev/null; }

# gates_of TOP — every selftest TOP carries, one per line.
gates_of() {
  local g
  for g in "${GATES[@]}"; do [[ -x "$1/$g" ]] && printf '%s\n' "$1/$g"; done
}

# ---------------------------------------------------------------- checks

subject_ok() {  # MESSAGE — its first line is Conventional Commits or ticket-first
  local subject="${1%%$'\n'*}" types
  types=$(IFS='|'; printf '%s' "${TYPES[*]}")
  [[ "$subject" =~ ^($types)(\([^\)]+\))?!?:\ [^[:space:]] \
     || "$subject" =~ ^[A-Z][A-Z0-9]+-[0-9]+:\ [^[:space:]] ]] \
    || die "subject '$subject' is neither Conventional Commits (${TYPES[*]}) nor ticket-first (KEY-123: …)"
}

one_repo() {  # ABS… — the single repo holding every path, or a refusal
  local top p t
  for p in "$@"; do
    t=$(repo_of "$p") || die "$p is not in a git repo"
    [[ -z "${top:-}" || "$t" == "$top" ]] || die "paths span $top and $t; one call is one repo"
    top="$t"
  done
  printf '%s\n' "$top"
}

permitted() {  # TOP — no remote, or a clone the user opted in
  [[ -z "$(git -C "$1" remote)" ]] && return
  [[ "$(git -C "$1" config --bool tooling.commit)" == true ]] \
    || die "$1 has a remote; its commits are the user's (git config tooling.commit true opts it in)"
}

known() {  # TOP REL — on disk, or tracked at HEAD or in the index
  [[ -e "$1/$2" ]] \
    || git -C "$1" cat-file -e "HEAD:$2" 2>/dev/null \
    || git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1
}

# all_known TOP REL… — a relative path resolves against the caller's cwd, so
# one named from the wrong directory lands on a path the repo never had.
all_known() {
  local top="$1" p; shift
  for p in "$@"; do
    known "$top" "$p" \
      || die "$top/$p is neither on disk nor tracked; check the directory a relative path was named from"
  done
}

has_changes() {  # TOP REL…
  local top="$1"; shift
  [[ -n "$(git -C "$top" status --porcelain --untracked-files=all -- "$@")" ]] \
    || die "nothing changed in the named paths"
}

# gated REL… — 0 unless every path is the session history.
gated() {
  local p
  for p in "$@"; do [[ "$p" == "$UNGATED" ]] || return 0; done
  return 1
}

run_gates() {  # TOP
  local -a gates; local g out
  mapfile -t gates < <(gates_of "$1")
  [[ ${#gates[@]} -gt 0 ]] || die "$1 carries no selftest, so nothing gates the commit"
  for g in "${gates[@]}"; do
    out=$(cd "$1" && "$g" 2>&1) \
      || { printf '%s\n' "$out" | tail -20 >&2; die "gate $g is red; nothing committed"; }
  done
}

run_trigger_cases() {  # ABS…
  "$(dirname "$SELF")/skill_trigger_test.py" --changed "$@" >&2 \
    || die "trigger cases did not pass; nothing committed"
}

# ---------------------------------------------------------------- commit

commit() {  # TOP MESSAGE REL…
  local top="$1" msg="$2"; shift 2
  # A path git mv or git rm took out of the index matches nothing for
  # git add, and commit --only drops its staged deletion; restoring its
  # index entry from HEAD lets add -A stage the deletion again.
  local p
  for p in "$@"; do
    [[ -e "$top/$p" ]] || git -C "$top" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 \
      || git -C "$top" reset -q -- "$p" 2>/dev/null || true
  done
  git -C "$top" add -A -- "$@" || die "git add refused in $top"
  git -C "$top" commit -q --only -F - -- "$@" <<<"$msg" || die "git commit refused in $top"
  git -C "$top" rev-parse --short HEAD
}

main() {
  local msg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) [[ $# -ge 2 ]] || usage; msg="$2"; shift 2 ;;
      --) shift; break ;;
      *)  usage ;;
    esac
  done
  [[ -n "$msg" && $# -gt 0 ]] || usage
  subject_ok "$msg"

  local -a abs=() rel=(); local p top
  for p in "$@"; do abs+=("$(realpath -m -- "$p")"); done
  top=$(one_repo "${abs[@]}") || exit 1
  for p in "${abs[@]}"; do rel+=("${p#"$top"/}"); done

  permitted "$top"
  all_known "$top" "${rel[@]}"
  has_changes "$top" "${rel[@]}"
  if gated "${rel[@]}"; then run_gates "$top"; run_trigger_cases "${abs[@]}"
  else echo "tooling_commit.sh: the session history alone; no gate reads it" >&2; fi
  commit "$top" "$msg" "${rel[@]}"
}

# ---------------------------------------------------------------- self-test

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local tmp out
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  mkrepo() {  # DIR [GATE] — a repo with one commit, gated by GATE when given
    mkdir -p "$1"; git -C "$1" init -q
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
    if [[ -n "${2:-}" ]]; then
      mkdir -p "$1/$(dirname "$2")"
      printf '#!/usr/bin/env bash\n[[ ! -e "$(dirname "$0")/RED" ]]\n' > "$1/$2"
      chmod +x "$1/$2"
    fi
    echo base > "$1/base.txt"; git -C "$1" add -A; git -C "$1" commit -qm base
  }
  tc()      { "$SELF" "$@" 2>&1; }
  head_of() { git -C "$1" rev-parse --short HEAD; }
  files_of_head() { git -C "$1" show --no-renames --name-only --format= HEAD | sed '/^$/d' | sort; }

  local r="$tmp/tools"; mkrepo "$r" .claude/scripts/selftest.sh

  echo a > "$r/a.txt"; echo theirs > "$r/theirs.txt"
  echo staged > "$r/staged.txt"; git -C "$r" add staged.txt
  out=$(tc -m "chore: a" -- "$r/a.txt")
  tap_is "prints the sha of the commit it made" "$out" "$(head_of "$r")"
  tap_is "commits the named path alone" "$(files_of_head "$r")" "a.txt"
  tap_is "leaves another session's staged path staged" "$(git -C "$r" status --porcelain -- staged.txt)" \
    "A  staged.txt"
  tap_is "leaves another session's untracked path untracked" "$(git -C "$r" status --porcelain -- theirs.txt)" \
    "?? theirs.txt"
  tap_is "the message is the one given" "$(git -C "$r" log -1 --format=%B)" "chore: a"

  git -C "$r" rm -q --cached staged.txt; rm "$r/staged.txt"
  (cd "$r" && rm base.txt && echo "c d" > "c d.txt" && "$SELF" -m "chore: del" -- base.txt "c d.txt" >/dev/null)
  tap_is "a relative path, a deletion and a space are committed whole" "$(files_of_head "$r")" "base.txt
c d.txt"

  git -C "$r" mv "c d.txt" moved.txt
  tc -m "chore: mv" -- "$r/c d.txt" "$r/moved.txt" >/dev/null
  tap_is "a git mv commits both its paths" "$(files_of_head "$r")" "c d.txt
moved.txt"

  local h; h=$(head_of "$r")
  echo b > "$r/b.txt"; touch "$r/.claude/scripts/RED"
  out=$(tc -m "chore: red" -- "$r/b.txt")
  tap_is "a red gate commits nothing" "$(head_of "$r")" "$h"
  tap_is "and says the gate was red" "$(grep -c 'is red; nothing committed' <<<"$out")" "1"
  rm "$r/.claude/scripts/RED"

  mkdir -p "$r/.claude"; echo "## entry" > "$r/.claude/session_history.md"
  touch "$r/.claude/scripts/RED"
  out=$(tc -m "chore: hist" -- "$r/.claude/session_history.md")
  tap_is "the session history alone commits past a red gate" "$(files_of_head "$r")" \
    ".claude/session_history.md"
  tap_is "and says no gate reads it" "$(grep -c 'no gate reads it' <<<"$out")" "1"
  echo "## more" >> "$r/.claude/session_history.md"; echo c > "$r/code.sh"
  h=$(head_of "$r")
  tc -m "chore: mixed" -- "$r/.claude/session_history.md" "$r/code.sh" >/dev/null
  tap_is "the history beside any other path is gated" "$(head_of "$r")" "$h"
  git -C "$r" checkout -q -- .claude/session_history.md; rm "$r/code.sh" "$r/.claude/scripts/RED"

  local ng2="$tmp/nogate-hist"; mkrepo "$ng2"; mkdir -p "$ng2/.claude"
  echo "## e" > "$ng2/.claude/session_history.md"
  tc -m "chore: h" -- "$ng2/.claude/session_history.md" >/dev/null
  tap_is "a history-only commit needs no selftest" "$(files_of_head "$ng2")" \
    ".claude/session_history.md"

  local g="$tmp/global"; mkrepo "$g" scripts/selftest.sh
  echo x > "$g/x.txt"
  out=$(tc -m "chore: x" -- "$g/x.txt")
  tap_is "a gate at scripts/selftest.sh is found too" "$out" "$(head_of "$g")"

  ln -s "$g" "$tmp/link"; echo y > "$g/y.txt"
  tc -m "chore: y" -- "$tmp/link/y.txt" >/dev/null
  tap_is "a path through a symlink commits in the repo holding the file" "$(files_of_head "$g")" "y.txt"

  local rm_="$tmp/remote"; mkrepo "$rm_" scripts/selftest.sh
  # A remote a push would reach, so a push the script made would show there.
  git init -q --bare "$tmp/origin.git"
  git -C "$rm_" remote add origin "$tmp/origin.git"; echo z > "$rm_/z.txt"
  out=$(tc -m "chore: z" -- "$rm_/z.txt")
  tap_is "a repo with a remote is refused" "$(grep -c 'has a remote' <<<"$out")" "1"
  git -C "$rm_" config tooling.commit true
  out=$(tc -m "chore: z" -- "$rm_/z.txt")
  tap_is "a repo with a remote commits once the clone opts in" "$out" "$(head_of "$rm_")"
  tap_is "and the commit is never pushed" "$(git -C "$tmp/origin.git" for-each-ref)" ""

  local ng="$tmp/nogate"; mkrepo "$ng"; echo z > "$ng/z.txt"
  out=$(tc -m "chore: z" -- "$ng/z.txt")
  tap_is "a repo with no selftest is refused" "$(grep -c 'carries no selftest' <<<"$out")" "1"

  echo p > "$r/p.txt"; echo q > "$g/q.txt"
  out=$(tc -m "chore: pq" -- "$r/p.txt" "$g/q.txt")
  tap_is "paths in two repos are refused" "$(grep -c 'one call is one repo' <<<"$out")" "1"

  out=$(tc -m "chore: none" -- "$r/a.txt")
  tap_is "an unchanged path is refused, not an empty commit" "$(grep -c 'nothing changed' <<<"$out")" \
    "1"

  echo w > "$g/scripts/w.sh"
  out=$(cd "$r" && "$SELF" -m "chore: w" -- scripts/w.sh 2>&1)
  tap_is "a path named from the wrong directory is refused as unknown" "$(grep -c 'neither on disk nor tracked' <<<"$out")" \
    "1"
  rm "$g/scripts/w.sh"

  echo n > "$r/n.txt"; h=$(head_of "$r")
  out=$(tc -m "Update the notes" -- "$r/n.txt")
  tap_is "a subject in neither form commits nothing" "$(head_of "$r")" "$h"
  tap_is "and says which forms it takes" "$(grep -c 'neither Conventional Commits' <<<"$out")" "1"
  out=$(tc -m "credo: n" -- "$r/n.txt")
  tap_is "a type outside TYPES is refused" "$(grep -c 'neither Conventional Commits' <<<"$out")" "1"
  out=$(tc -m "chore:n" -- "$r/n.txt")
  tap_is "a subject with no space after the colon is refused" "$(grep -c 'neither Conventional Commits' <<<"$out")" \
    "1"
  tc -m "XYZ-7: n" -- "$r/n.txt" >/dev/null
  tap_is "a ticket-first subject commits" "$(git -C "$r" log -1 --format=%s)" "XYZ-7: n"
  echo m > "$r/n.txt"
  tc -m $'feat(tc)!: n\n\nthe body is free' -- "$r/n.txt" >/dev/null
  tap_is "a scoped breaking subject commits, and only the first line is judged" \
    "$(git -C "$r" log -1 --format=%s)" "feat(tc)!: n"

  mkdir -p "$r/skills/s"
  printf -- '---\ndescription: old\n---\nbody\n' > "$r/skills/s/SKILL.md"
  h=$(head_of "$r")
  out=$(tc -m "chore: s" -- "$r/skills/s/SKILL.md")
  tap_is "a new description with no trigger cases commits nothing" "$(head_of "$r")" "$h"
  tap_is "and names the file its cases belong in" "$(grep -c 'skill_triggers.json' <<<"$out")" "1"
  mkdir -p "$r/skills/t"; printf 'no frontmatter\n' > "$r/skills/t/SKILL.md"
  out=$(tc -m "chore: t" -- "$r/skills/t/SKILL.md")
  tap_is "a change that leaves no description commits" "$out" "$(head_of "$r")"
  printf 'still none\n' >> "$r/skills/t/SKILL.md"
  out=$(tc -m "chore: t body" -- "$r/skills/t/SKILL.md")
  tap_is "a body edit runs no trigger cases" "$out" "$(head_of "$r")"

  "$SELF" -- "$r/p.txt" >/dev/null 2>&1
  tap_is "no message is a usage error" "$?" "2"
}

[[ "${1:-}" == --self-test ]] && { self_test; tap_end; }
main "$@"
