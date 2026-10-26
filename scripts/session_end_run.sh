#!/usr/bin/env bash
# The detached half of the SessionEnd hook: hold the lock, run the placer, then
# report what it did. session_end_notes.sh decides and detaches.
#
# Usage:
#   session_end_run.sh LOCK LOG CWD PREFIX CMD…
#   session_end_run.sh --self-test
#
# The lock is non-blocking and held by fd 9 for this process's whole life, so a
# crashed run cannot leave it held: a dead process holds no descriptors.
#
# The run commits its own work through tooling_commit.sh, as /notes requires of
# every run; this script commits nothing. It reports what the run committed —
# every commit between each repo's HEAD before and after — and what the run left
# uncommitted: every path dirty after that was not dirty before. Comparing against
# the before-snapshot is what keeps another session's in-flight edits out of the
# report.
#
# A rename shows in porcelain output as two records, and only the first carries a
# status prefix, so a renamed path is not matched here. Nothing this run writes is
# a rename — facts, journal entries and skills are created or edited in place.
#
# Everything lives inside main() because bash reads a script from disk as it goes:
# a run takes minutes, and editing this file mid-run once left a completed run
# with no report, because bash resumed reading at an offset that no longer meant
# anything. A function body is parsed as one unit before it runs, so an edit
# during the run cannot reach it.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_ENV="${SESSION_END_REPOS:-}"   # self-test override; empty means the real two

stamp() { printf '%s %s %s\n' "$(date -u +%FT%TZ)" "${PFX:-}" "$*" >> "$LOG"; }

# dirty REPO — every changed or untracked path in REPO, one per line, sorted.
dirty() {
  local rec
  while IFS= read -r -d '' rec; do
    [[ ${#rec} -gt 3 ]] && printf '%s\n' "${rec:3}"
  done < <(git -C "$1" status --porcelain -z --untracked-files=all 2>/dev/null) | sort
}

head_of() { git -C "$1" rev-parse -q --verify HEAD 2>/dev/null; }

# commits_since REPO HEAD — one "<repo> <sha> <subject>" line per commit since HEAD.
commits_since() {
  git -C "$1" log --reverse --format="$1 %h %s" "$2..HEAD" 2>/dev/null
}

# left_since REPO BEFORE — one "<repo>: <path>" line per path dirty now and not
# dirty BEFORE: what the run changed and did not commit.
left_since() {
  comm -13 <(printf '%s\n' "$2") <(dirty "$1") | sed '/^$/d' | sed "s|^|$1: |"
}

open_ids() {  # SID — the ids of SID's notes still open, one per line
  "$SCRIPTS_DIR/journal_queue.sh" --opened-by "$1" --ids 2>/dev/null
}

main() {
  LOCK="$1"; LOG="$2"; CWD="$3"; PFX="$4"; shift 4

  exec 9>"$LOCK" || { stamp "the lock file could not be opened, skipped"; return 0; }
  flock -n 9     || { stamp "another run holds the lock, skipped"; return 0; }
  cd "$CWD"      || { stamp "cwd is gone, skipped"; return 0; }

  local sid="${PFX##*session=}"; sid="${sid%% *}"
  local -a repos
  if [[ -n "$REPOS_ENV" ]]; then IFS=: read -r -a repos <<<"$REPOS_ENV"
  else repos=("$CWD" "$HOME/.claude"); fi

  declare -A before=() heads=()
  local r
  for r in "${repos[@]}"; do before["$r"]=$(dirty "$r"); heads["$r"]=$(head_of "$r"); done

  # The queue before and after is what says how much the run placed. A count the
  # run reported itself would be the run marking its own homework.
  local -a open_before=()
  local id
  while IFS= read -r id; do [[ -n "$id" ]] && open_before+=(--open "$id"); done \
    < <(open_ids "$sid")

  stamp "run started"
  "$@" >> "$LOG" 2>&1
  local rc=$?
  stamp "run finished rc=$rc"

  local -a report=("$SCRIPTS_DIR/session_end_report.sh"
                   --session "$sid" --rc "$rc"
                   "${open_before[@]}" --after "$(open_ids "$sid" | grep -c .)"
                   --dir "$CWD" --log "$LOG")
  local line
  for r in "${repos[@]}"; do
    while IFS= read -r line; do [[ -n "$line" ]] && report+=(--commit "$line"); done \
      < <([[ -n "${heads[$r]}" ]] && commits_since "$r" "${heads[$r]}")
    while IFS= read -r line; do [[ -n "$line" ]] && report+=(--left "$line"); done \
      < <(left_since "$r" "${before[$r]}")
  done
  "${report[@]}" || stamp "the record could not be written; the run's work stands"
  return 0
}

# ---------------------------------------------------------------- self-test

self_test() {
  local rc=0 tmp repo out
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  check() {  # DESCRIPTION WANT GOT
    if [[ "$3" == "$2" ]]; then echo "  ok   $1"
    else printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3" >&2; rc=1; fi
  }
  mkrepo() {  # DIR
    mkdir -p "$1/.claude"; git -C "$1" init -q
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
    echo base > "$1/base.txt"; git -C "$1" add -A; git -C "$1" commit -q -m base
  }
  echo "session_end_run.sh --self-test"

  repo="$tmp/r"; mkrepo "$repo"
  echo theirs > "$repo/theirs.txt"
  local before h; before=$(dirty "$repo"); h=$(head_of "$repo")
  check "an untracked file counts as dirty, so it is seen before the run" "theirs.txt" "$before"

  echo ours > "$repo/ours.txt"; echo left > "$repo/left.txt"
  git -C "$repo" add ours.txt; git -C "$repo" commit -q -m "chore: ours"
  check "a commit the run made is reported with its subject" "$repo $(git -C "$repo" rev-parse --short HEAD) chore: ours" \
    "$(commits_since "$repo" "$h")"
  check "a path the run left uncommitted is reported, another session's is not" "$repo: left.txt" \
    "$(left_since "$repo" "$before")"

  # End to end through main, as the hook invokes it — the half no other case
  # reaches, and the half where a real run once died silently.
  local e2e="$tmp/e2e"; mkrepo "$e2e"
  # Two notes of the ending session: one still open, and one another session
  # closed before the run, which the report must not credit to the run.
  local hist="$e2e/.claude/session_history.md" gone; : > "$hist"
  JOURNAL_HIST="$hist" CLAUDE_CODE_SESSION_ID=sid-e2e "$SCRIPTS_DIR/journal.sh" \
    -t "chore: x" -b b -n "Kept open" -n "Swept stash — gone" >/dev/null
  gone=$(JOURNAL_HIST="$hist" "$SCRIPTS_DIR/journal_queue.sh" | grep -F Swept | cut -f1)
  JOURNAL_HIST="$hist" CLAUDE_CODE_SESSION_ID=s-other "$SCRIPTS_DIR/journal.sh" \
    -t "chore: git sweep" -b b --placed "$gone: - — no longer there" >/dev/null
  local h0; h0=$(head_of "$e2e")
  : > "$tmp/e2e.log"
  SESSION_END_REPOS="$e2e" \
    "$0" "$tmp/e2e.lock" "$tmp/e2e.log" "$e2e" "reason=other session=sid-e2e" \
    bash -c 'echo I-RAN; echo placed > placed.txt; git add placed.txt; git commit -qm "chore: placed"; echo stray > stray.txt'
  out=$(<"$tmp/e2e.log")
  check "main runs the command and its output reaches the log" "1" "$(grep -c I-RAN <<<"$out")"
  check "main records the run finishing" "1" "$(grep -c 'run finished rc=0' <<<"$out")"
  check "main commits nothing itself" "1" \
    "$(git -C "$e2e" rev-list --count "$h0..HEAD")"
  check "the report names the run's commit" "1" \
    "$(grep -c 'chore: placed' "$e2e/.claude/session_end.last" 2>/dev/null || echo 0)"
  check "and the path the run left uncommitted" "1" \
    "$(grep -c 'stray.txt' "$e2e/.claude/session_end.last" 2>/dev/null || echo 0)"
  check "the report counts only the notes open when the run started" \
    "1 open at the end, 0 placed by the run, 1 still open. Run exit 0." \
    "$(sed -n 2p "$e2e/.claude/session_end.last" 2>/dev/null)"
  check "and lists a note closed before the run as placed before it" "1" \
    "$(sed -n '/^Placed before the run:/,$p' "$e2e/.claude/session_end.last" | grep -c "^  | $gone ")"
  return $rc
}

[[ "${1:-}" == --self-test ]] && { self_test; exit $?; }
main "$@"; exit $?
