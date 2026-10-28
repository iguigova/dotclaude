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
  if gated "${rel[@]}"; then run_gates "$top"
  else echo "tooling_commit.sh: the session history alone; no gate reads it" >&2; fi
  commit "$top" "$msg" "${rel[@]}"
}

# ---------------------------------------------------------------- self-test

self_test() {
  local rc=0 tmp out
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  check() {  # DESCRIPTION WANT GOT
    if [[ "$3" == "$2" ]]; then echo "  ok   $1"
    else printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3" >&2; rc=1; fi
  }
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
  echo "tooling_commit.sh --self-test"

  local r="$tmp/tools"; mkrepo "$r" .claude/scripts/selftest.sh

  echo a > "$r/a.txt"; echo theirs > "$r/theirs.txt"
  echo staged > "$r/staged.txt"; git -C "$r" add staged.txt
  out=$(tc -m "chore: a" -- "$r/a.txt")
  check "prints the sha of the commit it made" "$(head_of "$r")" "$out"
  check "commits the named path alone" "a.txt" "$(files_of_head "$r")"
  check "leaves another session's staged path staged" "A  staged.txt" \
    "$(git -C "$r" status --porcelain -- staged.txt)"
  check "leaves another session's untracked path untracked" "?? theirs.txt" \
    "$(git -C "$r" status --porcelain -- theirs.txt)"
  check "the message is the one given" "chore: a" "$(git -C "$r" log -1 --format=%B)"

  git -C "$r" rm -q --cached staged.txt; rm "$r/staged.txt"
  (cd "$r" && rm base.txt && echo "c d" > "c d.txt" && "$SELF" -m "chore: del" -- base.txt "c d.txt" >/dev/null)
  check "a relative path, a deletion and a space are committed whole" "base.txt
c d.txt" "$(files_of_head "$r")"

  git -C "$r" mv "c d.txt" moved.txt
  tc -m "chore: mv" -- "$r/c d.txt" "$r/moved.txt" >/dev/null
  check "a git mv commits both its paths" "c d.txt
moved.txt" "$(files_of_head "$r")"

  local h; h=$(head_of "$r")
  echo b > "$r/b.txt"; touch "$r/.claude/scripts/RED"
  out=$(tc -m "chore: red" -- "$r/b.txt")
  check "a red gate commits nothing" "$h" "$(head_of "$r")"
  check "and says the gate was red" "1" "$(grep -c 'is red; nothing committed' <<<"$out")"
  rm "$r/.claude/scripts/RED"

  mkdir -p "$r/.claude"; echo "## entry" > "$r/.claude/session_history.md"
  touch "$r/.claude/scripts/RED"
  out=$(tc -m "chore: hist" -- "$r/.claude/session_history.md")
  check "the session history alone commits past a red gate" ".claude/session_history.md" \
    "$(files_of_head "$r")"
  check "and says no gate reads it" "1" "$(grep -c 'no gate reads it' <<<"$out")"
  echo "## more" >> "$r/.claude/session_history.md"; echo c > "$r/code.sh"
  h=$(head_of "$r")
  tc -m "chore: mixed" -- "$r/.claude/session_history.md" "$r/code.sh" >/dev/null
  check "the history beside any other path is gated" "$h" "$(head_of "$r")"
  git -C "$r" checkout -q -- .claude/session_history.md; rm "$r/code.sh" "$r/.claude/scripts/RED"

  local ng2="$tmp/nogate-hist"; mkrepo "$ng2"; mkdir -p "$ng2/.claude"
  echo "## e" > "$ng2/.claude/session_history.md"
  tc -m "chore: h" -- "$ng2/.claude/session_history.md" >/dev/null
  check "a history-only commit needs no selftest" ".claude/session_history.md" \
    "$(files_of_head "$ng2")"

  local g="$tmp/global"; mkrepo "$g" scripts/selftest.sh
  echo x > "$g/x.txt"
  check "a gate at scripts/selftest.sh is found too" "$(tc -m "chore: x" -- "$g/x.txt")" "$(head_of "$g")"

  ln -s "$g" "$tmp/link"; echo y > "$g/y.txt"
  tc -m "chore: y" -- "$tmp/link/y.txt" >/dev/null
  check "a path through a symlink commits in the repo holding the file" "y.txt" "$(files_of_head "$g")"

  local rm_="$tmp/remote"; mkrepo "$rm_" scripts/selftest.sh
  git -C "$rm_" remote add origin https://example.invalid/r.git; echo z > "$rm_/z.txt"
  out=$(tc -m "chore: z" -- "$rm_/z.txt")
  check "a repo with a remote is refused" "1" "$(grep -c 'has a remote' <<<"$out")"
  git -C "$rm_" config tooling.commit true
  out=$(tc -m "chore: z" -- "$rm_/z.txt")
  check "a repo with a remote commits once the clone opts in" "$(head_of "$rm_")" "$out"

  local ng="$tmp/nogate"; mkrepo "$ng"; echo z > "$ng/z.txt"
  out=$(tc -m "chore: z" -- "$ng/z.txt")
  check "a repo with no selftest is refused" "1" "$(grep -c 'carries no selftest' <<<"$out")"

  echo p > "$r/p.txt"; echo q > "$g/q.txt"
  out=$(tc -m "chore: pq" -- "$r/p.txt" "$g/q.txt")
  check "paths in two repos are refused" "1" "$(grep -c 'one call is one repo' <<<"$out")"

  out=$(tc -m "chore: none" -- "$r/a.txt")
  check "an unchanged path is refused, not an empty commit" "1" \
    "$(grep -c 'nothing changed' <<<"$out")"

  echo w > "$g/scripts/w.sh"
  out=$(cd "$r" && "$SELF" -m "chore: w" -- scripts/w.sh 2>&1)
  check "a path named from the wrong directory is refused as unknown" "1" \
    "$(grep -c 'neither on disk nor tracked' <<<"$out")"
  rm "$g/scripts/w.sh"

  echo n > "$r/n.txt"; h=$(head_of "$r")
  out=$(tc -m "Update the notes" -- "$r/n.txt")
  check "a subject in neither form commits nothing" "$h" "$(head_of "$r")"
  check "and says which forms it takes" "1" "$(grep -c 'neither Conventional Commits' <<<"$out")"
  out=$(tc -m "credo: n" -- "$r/n.txt")
  check "a type outside TYPES is refused" "1" "$(grep -c 'neither Conventional Commits' <<<"$out")"
  out=$(tc -m "chore:n" -- "$r/n.txt")
  check "a subject with no space after the colon is refused" "1" \
    "$(grep -c 'neither Conventional Commits' <<<"$out")"
  tc -m "XYZ-7: n" -- "$r/n.txt" >/dev/null
  check "a ticket-first subject commits" "XYZ-7: n" "$(git -C "$r" log -1 --format=%s)"
  echo m > "$r/n.txt"
  tc -m $'feat(tc)!: n\n\nthe body is free' -- "$r/n.txt" >/dev/null
  check "a scoped breaking subject commits, and only the first line is judged" \
    "feat(tc)!: n" "$(git -C "$r" log -1 --format=%s)"

  "$SELF" -- "$r/p.txt" >/dev/null 2>&1
  check "no message is a usage error" "2" "$?"
  return $rc
}

[[ "${1:-}" == --self-test ]] && { self_test; exit $?; }
main "$@"
