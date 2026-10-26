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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  fails=()
  [[ "$(persona_line 0 /w/head/.claude/agents/security.md o/r)" == "persona: /w/head/.claude/agents/security.md" ]] \
    || fails+=("a fetched persona is not printed as its path")
  [[ "$(persona_line 1 '' o/r)" == "persona: none — o/r has no $PERSONA_PATH at head" ]] \
    || fails+=("an absent persona is not reported as none")
  persona_line 2 '' o/r >/dev/null && fails+=("a failed persona fetch reads as an answer")
  # The classes must come from one named commit, raw, or a large file comes
  # back base64-capped and the line cited is not the line read.
  grep -q 'contents/\$CLASSES_PATH?ref=\$MSHA' "${BASH_SOURCE[0]}" || fails+=("the classes fetch does not pin ?ref=")
  grep -q 'vnd.github.raw' "${BASH_SOURCE[0]}" || fails+=("not requesting the raw media type")
  if ((${#fails[@]})); then
    printf 'gh-pr-security self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-security self-test: PASS (persona present, absent and failed told apart; classes pinned to one commit, raw)"
  exit 0
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pr-ref> | --self-test" >&2
  exit 1
fi
REF="$1"

REFJSON=$("$HERE/gh_pr_ref.py" "$REF") || exit 1
RSLUG="$(jq -er .owner <<<"$REFJSON")/$(jq -er .repo <<<"$REFJSON")"
D=$("$HERE/gh-pr-workdir.sh" "$REF") || exit 1

mkdir -p "$D/security"
if ! SRC_FILE=$("$HERE/project_file.sh" security_classes 2>/dev/null); then
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
out=$("$HERE/gh-pr-file.sh" "$REF" "$PERSONA_PATH" 2>/dev/null) || rc=$?
persona_line "$rc" "$out" "$RSLUG" || {
  echo "persona: unread — the fetch of $PERSONA_PATH at head failed; re-run, or review without it and say so" >&2
  exit 2
}
