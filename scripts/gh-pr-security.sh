#!/usr/bin/env bash
# Fetch the two team-owned sources /review:pr's Security section reviews
# against, and print where each landed:
#
#   classes: the team's incident classes, from the `<owner>/<repo>:<path>` the
#            project names in .claude/security_classes (project_file.sh), at
#            that repository's default branch's current commit; or none
#   persona: the repository's own Teambuild Security persona,
#            .claude/agents/security.md at the PR's head commit, or none
#
# Both are read at run time, never copied, so the review cannot drift from
# the list the team maintains or from the threat model the repository holds.
#
# Usage:
#   gh-pr-security.sh <pr-ref>
#   gh-pr-security.sh --self-test
#
# Output, two lines:
#   classes: <path> @<marketplace commit>   (or: classes: none — <why>)
#   persona: <path>          (or: persona: none — <repo> has no <path> at head)
#
# The classes file lands under <workdir>/security/. The persona comes through
# gh-pr-file.sh, so it lands where every other head-pinned file does.
#
# Exit 0: the classes were read; a repository without a persona is still 0.
# Exit 1: the ref is unrecognized. Exit 2: the classes, or the persona, could
# not be read for a reason other than its absence (auth, network, rate limit):
# the Security section then says so in the review instead of running short.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PF="$HOME/.claude/scripts/project_file.sh"

PERSONA_PATH=.claude/agents/security.md

# gh-pr-file.sh exits 1 for a path absent at head and 2 for a failed fetch.
# Only the first means the repository has no persona.
persona_line() {  # <gh-pr-file rc> <printed path> <repo> -> line, or return 2
  case "$1" in
    0) echo "persona: $2" ;;
    1) echo "persona: none — $3 has no $PERSONA_PATH at head" ;;
    *) return 2 ;;
  esac
}

if [[ "${1:-}" == "--self-test" ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  tap_is "a fetched persona is printed as its path" \
    "$(persona_line 0 /w/head/.claude/agents/security.md o/r)" \
    "persona: /w/head/.claude/agents/security.md"
  tap_is "an absent persona is reported as none" \
    "$(persona_line 1 '' o/r)" "persona: none — o/r has no $PERSONA_PATH at head"
  tap_fails "a failed persona fetch is not an answer" persona_line 2 '' o/r
  # The classes must come from one named commit, raw, or a large file comes
  # back base64-capped and the line cited is not the line read.
  tap_run "the classes fetch pins ?ref=" \
    grep -q 'contents/\$CLASSES_PATH?ref=\$MSHA' "${BASH_SOURCE[0]}"
  tap_run "the raw media type is requested" grep -q 'vnd.github.raw' "${BASH_SOURCE[0]}"
  # The script in a fixture project whose scripts it calls by name are stubs,
  # beside a gh that logs: where it stops, and what it called before.
  sfx=$(mktemp -d); : > "$sfx/calls"; tap_stub "$sfx/bin/gh" "$sfx/calls"
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  stubbed() {  # <args…> -> "<exit> <call>|<call>…"; stdout kept in $sfx/out
    local st=0
    (cd "$sfx" && PATH="$sfx/bin:$PATH" "$me" "$@") > "$sfx/out" 2>/dev/null || st=$?
    echo "$st $(paste -sd'|' "$sfx/calls")"; : > "$sfx/calls"
  }
  stub() { tap_stub "$sfx/.claude/scripts/$1" "$sfx/calls" "${@:2}"; }  # <name> [<status>] [<stdout>]
  stub gh_pr_ref.py 1
  tap_is "a ref gh_pr_ref.py refuses reads nothing, exit 1" "$(stubbed o/r#1)" "1 gh_pr_ref.py o/r#1"
  stub gh_pr_ref.py 0 '{"owner":"o","repo":"r","number":1,"slug":"o/r"}'; stub gh-pr-workdir.sh 1
  tap_is "a work directory that cannot be had reads nothing, exit 1" "$(stubbed o/r#1)" \
    "1 gh_pr_ref.py o/r#1|gh-pr-workdir.sh o/r#1"
  stub gh-pr-workdir.sh 0 "$sfx/w"; stub gh-pr-file.sh 1; stubbed o/r#1 >/dev/null
  tap_like "a persona the head lacks is reported as none" "$(cat "$sfx/out")" "*persona: none — o/r has no *"
  rm -rf "$sfx"
  tap_end
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pr-ref> | --self-test" >&2
  exit 1
fi
REF="$1"

REFJSON=$("$("$PF" --script gh_pr_ref.py)" "$REF") || exit 1
RSLUG="$(jq -er .owner <<<"$REFJSON")/$(jq -er .repo <<<"$REFJSON")"
D=$("$("$PF" --script gh-pr-workdir.sh)" "$REF") || exit 1

mkdir -p "$D/security"
if ! SRC_FILE=$("$PF" security_classes 2>/dev/null); then
  echo "classes: none — the project names no .claude/security_classes"
else
SRC=$(tr -d '\n' < "$SRC_FILE"); MARKETPLACE=${SRC%%:*}; CLASSES_PATH=${SRC#*:}
dest="$D/security/incident-classes.md"
if ! MSHA=$(gh api "repos/$MARKETPLACE/commits/HEAD" --jq .sha 2>&1) \
   || ! gh api "repos/$MARKETPLACE/contents/$CLASSES_PATH?ref=$MSHA" \
          -H "Accept: application/vnd.github.raw" > "$dest" 2>"$D/security/err"; then
  rm -f "$dest"
  echo "classes: unread — $MARKETPLACE:$CLASSES_PATH: ${MSHA:-} $(cat "$D/security/err" 2>/dev/null)" >&2
  exit 2
fi
echo "classes: $dest @${MSHA:0:12}"
fi

rc=0
out=$("$("$PF" --script gh-pr-file.sh)" "$REF" "$PERSONA_PATH" 2>/dev/null) || rc=$?
persona_line "$rc" "$out" "$RSLUG" || {
  echo "persona: unread — the fetch of $PERSONA_PATH at head failed; re-run, or review without it and say so" >&2
  exit 2
}
