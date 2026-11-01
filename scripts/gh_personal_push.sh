#!/usr/bin/env bash
# gh_personal_push.sh — git push, run inside one of the user's personal repos,
# authenticated as the `iguigova` GitHub account whatever account `gh` has active.
#
# Every argument goes to `git push` unchanged. For an HTTPS remote on github.com,
# git asks this script for the credential, and it answers with
# `gh auth token -u iguigova`. The token is read only when git asks, and never
# lands on a command line. An SSH remote never asks: it pushes with the SSH key,
# so the same command works for both. No other host is ever given the token.
#
# Exits with git push's status, or 1 when `gh` holds no token for `iguigova`.
#
# Usage:
#   gh_personal_push.sh [<git push args>…]
#   gh_personal_push.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

ACCOUNT=iguigova
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

credential() {  # OPERATION — git's credential-helper protocol; only `get` answers
  [[ "$1" == get ]] || return 0
  cat >/dev/null   # git sends the request on stdin
  local token
  token=$(gh auth token -u "$ACCOUNT" 2>/dev/null) && [[ -n "$token" ]] \
    || { echo "gh_personal_push.sh: gh holds no token for $ACCOUNT (gh auth login)" >&2; return 1; }
  printf 'username=x-access-token\npassword=%s\n' "$token"
}

push() {
  # The empty helper first drops any helper configured elsewhere for this host.
  git -c credential.https://github.com.helper= \
      -c "credential.https://github.com.helper=!$SELF --credential" \
      push "$@"
}

self_test() {
  local tmp fail=0
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  mkdir "$tmp/bin"
  printf '#!/bin/sh\n[ "$4" = %s ] && echo tok-123\n' "$ACCOUNT" > "$tmp/bin/gh"
  chmod +x "$tmp/bin/gh"
  check() {  # NAME ACTUAL EXPECTED
    if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got [$2] want [$3]"; fail=1; fi
  }
  check "get answers with the account's token" \
    "$(PATH="$tmp/bin:$PATH" "$SELF" --credential get </dev/null)" \
    $'username=x-access-token\npassword=tok-123'
  check "store and erase answer nothing" \
    "$(PATH="$tmp/bin:$PATH" "$SELF" --credential store </dev/null)" ""
  printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh"
  PATH="$tmp/bin:$PATH" "$SELF" --credential get </dev/null >/dev/null 2>&1
  check "no token for the account exits 1" "$?" 1
  git init -q --bare "$tmp/remote.git"
  git init -q -b main "$tmp/work"
  git -C "$tmp/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
  (cd "$tmp/work" && "$SELF" -q "$tmp/remote.git" main 2>/dev/null)
  check "arguments reach git push" "$(git -C "$tmp/remote.git" log --format=%s main 2>&1)" one
  local cfg=(-c credential.https://github.com.helper= -c "credential.https://github.com.helper=!$SELF --credential")
  check "github.com gets the helper" \
    "$(git "${cfg[@]}" config --get-urlmatch credential.helper https://github.com/x.git)" "!$SELF --credential"
  check "no other host gets the helper" \
    "$(git "${cfg[@]}" config --get-urlmatch credential.helper https://example.com/x.git | grep -c -- --credential)" 0
  return "$fail"
}

case "${1:-}" in
  --credential) shift; credential "${1:-}" ;;
  --self-test) self_test ;;
  *) push "$@" ;;
esac
