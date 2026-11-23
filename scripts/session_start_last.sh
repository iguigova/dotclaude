#!/usr/bin/env bash
# session_start_last.sh — SessionStart hook: show what ran while nobody was here.
#
# Usage:
#   session_start_last.sh              # reads the hook payload on stdin
#   session_start_last.sh --help
#   session_start_last.sh --self-test
#
# The harness puts what this prints into the session's context. It prints, whole,
# each report an unattended run left in the project's .claude/:
#   memory_check.last  the facts the nightly check deleted, whose text survives
#                      only there and in the journal
#   session_end.last   what the SessionEnd hook's unattended /notes placed, left
#                      open and committed
#   git_sweep.last     the daily git sweep's verdict on every branch, stash and
#                      worktree, and its exit status; a record with no `run
#                      finished` line is a run that was killed
# and then moves each to ~/.claude/state/last/<project>/, so each is shown once.
# Their writers add to an unread report rather than replace it.
#
# It also prints ~/.claude/memory_check.last: the stores the nightly check
# skipped or failed on and the facts it left unchecked, each since the night it
# was first left so. That is the checker's current state, which it reads back
# and removes once nothing is left to report, so it is shown while it exists and
# never moved.
#
# The project is the one the payload's cwd lies in (project_file.sh --root),
# found by its history. It exits 0 on every path, since a session starts
# whether or not a report is readable, and prints nothing for an unattended run
# (CLAUDE_TOOLING_UNATTENDED), which is nobody's session.
# SESSION_START_LAST_STATE names another folder for the moved reports, and
# SESSION_START_LAST_GLOBAL another global report.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=journal_lib.sh
. "$SELF_DIR/journal_lib.sh"
REPORTS=(memory_check.last session_end.last git_sweep.last)
STATE="${SESSION_START_LAST_STATE:-$HOME/.claude/state/last}"
GLOBAL="${SESSION_START_LAST_GLOBAL:-$HOME/.claude/memory_check.last}"
HEADING="What ran while nobody was here. Tell the user what each report says before other work."

show() { printf '== %s%s ==\n%s\n\n' "$1" "$2" "$(<"$1")"; }  # <file> <note>

# project_reports <claude-dir> — show each report there, then move it aside.
project_reports() {
  local dir=$1 aside="$STATE/${1//\//_}" name
  for name in "${REPORTS[@]}"; do
    [[ -s "$dir/$name" ]] || continue
    show "$dir/$name" ""
    mkdir -p "$aside" && mv -f -- "$dir/$name" "$aside/$name"
  done
}

# reports — every report for the project at $PWD, then the global one.
reports() {
  local hist
  hist=$(journal_hist session_start_last.sh 2>/dev/null) && project_reports "$(dirname "$hist")"
  [[ -s "$GLOBAL" ]] && show "$GLOBAL" " (the nightly check's current state, shown until it clears)"
}

# main — the reports under one heading, or nothing at all. Its status is
# never read: the hook exits 0 whatever happened.
main() {
  local payload cwd out
  [[ -n "${CLAUDE_TOOLING_UNATTENDED:-}" ]] && return
  payload=$(timeout 2 cat 2>/dev/null)
  cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
  [[ -d "$cwd" ]] && { cd "$cwd" || return; }
  out=$(reports)
  [[ -n "$out" ]] && printf '%s\n\n%s\n' "$HEADING" "$out"
}

self_test() {
  # shellcheck source=tap.sh
  . "$SELF_DIR/tap.sh"
  local fx out self="$SELF_DIR/session_start_last.sh"
  fx=$(mktemp -d); trap 'rm -rf "$fx"' RETURN
  unset CLAUDE_TOOLING_UNATTENDED JOURNAL_HIST
  # A cwd that is gone leaves the hook where it was started: start it in the
  # fixture, so no case can reach a real project's reports.
  cd "$fx" || return 1
  mkdir -p "$fx/p/.claude" "$fx/p/sub" "$fx/q/.claude"; tap_project "$fx/p"; tap_project "$fx/q"
  : > "$fx/p/.claude/session_history.md"; : > "$fx/q/.claude/session_history.md"
  printf 'deleted x\n' > "$fx/p/.claude/memory_check.last"
  printf 'git_sweep 2026: p\nrun finished rc=0\n' > "$fx/p/.claude/git_sweep.last"
  : > "$fx/p/.claude/session_end.last"
  printf 'skipped store y\n' > "$fx/global"
  hook() {  # <cwd> [<env>…] — the hook, as the harness invokes it
    local cwd=$1; shift
    printf '{"cwd":"%s","source":"startup"}' "$cwd" \
      | env SESSION_START_LAST_STATE="$fx/state" SESSION_START_LAST_GLOBAL="$fx/global" "$@" "$self"
  }

  out=$(hook "$fx/p/sub")
  tap_is "the heading comes first, telling the session to report" "${out%%$'\n'*}" "$HEADING"
  tap_is "each report is shown whole, under its path" \
    "$(grep -c "^== $fx/p/.claude/memory_check.last ==$" <<<"$out") $(grep -c '^deleted x$' <<<"$out") $(grep -c '^run finished rc=0$' <<<"$out")" "1 1 1"
  tap_is "an empty report is not shown" "$(grep -c 'session_end.last' <<<"$out")" 0
  tap_is "the global report is shown as the checker's current state" \
    "$(grep -c "^== $fx/global (the nightly check's current state" <<<"$out") $(grep -c '^skipped store y$' <<<"$out")" "1 1"
  tap_is "a shown report is moved aside, and the global one stays" \
    "$([[ ! -e "$fx/p/.claude/memory_check.last" && -s "$fx/state/${fx//\//_}_p_.claude/memory_check.last" && -s "$fx/global" ]] && echo moved)" moved
  tap_is "so the next start shows only the global one" "$(hook "$fx/p" | grep -c '^== ')" 1
  rm "$fx/global"
  tap_is "with nothing to show it prints nothing" "$(hook "$fx/p")" ""
  printf 'deleted z\n' > "$fx/q/.claude/memory_check.last"
  tap_is "an unattended run's start prints nothing and moves nothing" \
    "$(hook "$fx/q" CLAUDE_TOOLING_UNATTENDED=1)$([[ -s "$fx/q/.claude/memory_check.last" ]] && echo kept)" kept
  tap_is "a folder in no project, or a cwd that is gone, prints nothing and exits 0" \
    "$(hook /; echo "rc=$?")$(hook "$fx/gone"; echo "rc=$?")" "rc=0rc=0"
  tap_is "a payload that is not JSON exits 0" "$(printf 'nope' | "$self"; echo "rc=$?")" "rc=0"
  tap_is "--help prints the header" "$("$self" --help | head -1)" \
    "session_start_last.sh — SessionStart hook: show what ran while nobody was here."
}

[[ "${1:-}" == --self-test ]] && { self_test; tap_end; }
main
exit 0
