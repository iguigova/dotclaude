#!/usr/bin/env bash
# Source this to get ATLASSIAN_SITE, JIRA_USER, JIRA_TOKEN, and the atlassian_curl
# helper.
#
# Source path:
#   source ~/.claude/scripts/atlassian-auth.sh
#
# Then call:
#   atlassian_curl "${ATLASSIAN_SITE}/rest/api/3/issue/XYZ-1234"
#
# The function adds basic-auth + Accept: application/json automatically.
#
# Executed rather than sourced, it takes one argument, --self-test, which sources
# a copy against a fixture site, fixture dotfiles and a curl that prints its
# arguments, so no network and no real credential is read.

# The guard compares this file with the script being run, so a helper sourcing
# this file with its own `--self-test` in $1 never reaches the branch.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${1:-}" == "--self-test" ]] || {
    echo "atlassian-auth.sh: source this file; executed, it takes only --self-test" >&2; exit 2; }
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/.claude/helpers" "$fx/home" "$fx/bin"
  cp "$0" "$fx/.claude/helpers/atlassian-auth.sh"
  cp "$(dirname "$0")/project_file.sh" "$fx/.claude/helpers/project_file.sh"
  printf 'https://example.invalid\n' > "$fx/.claude/atlassian_site"
  printf 'me@example.invalid\n' > "$fx/home/.jira-email"
  printf 'tok\n' > "$fx/home/.jira-token"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$fx/bin/curl"
  chmod +x "$fx/bin/curl"
  # shellcheck disable=SC2016  # expanded by the inner shell, after the source
  probe='source "$1" || exit $?; printf "%s|%s|%s\n" "$ATLASSIAN_SITE" "$JIRA_USER" "$JIRA_TOKEN"; atlassian_curl "$ATLASSIAN_SITE/x" | paste -sd" "'
  mkdir -p "$fx/.claude/sub/dir"
  got=$(cd "$fx/.claude/sub/dir" && HOME="$fx/home" PATH="$fx/bin:$PATH" bash -c "$probe" _ "$fx/.claude/helpers/atlassian-auth.sh")
  rm "$fx/.claude/atlassian_site"
  site_rc=0; (cd "$fx" && HOME="$fx/home" bash -c "$probe" _ "$fx/.claude/helpers/atlassian-auth.sh") \
    >/dev/null 2>"$fx/err" || site_rc=$?
  want='https://example.invalid|me@example.invalid|tok
-s -u me@example.invalid:tok -H Accept: application/json https://example.invalid/x'
  if [[ "$got" == "$want" && "$site_rc" == 1 ]] && grep -q 'no .claude/atlassian_site at or above' "$fx/err"; then
    echo "atlassian-auth self-test: PASS (site read from the nearest .claude/atlassian_site above \$PWD," \
      "credentials from the dotfiles with newlines trimmed, atlassian_curl" \
      "sends them as basic auth with the JSON Accept header, a missing site" \
      "fails the source)"
    exit 0
  fi
  echo "atlassian-auth self-test: FAIL (want [$want] got [$got]; missing site" \
    "exit $site_rc [$(cat "$fx/err")])" >&2
  exit 1
fi

# The site is the one line in the project's .claude/atlassian_site, so each project
# names its own site.
ATLASSIAN_SITE_FILE=$("$(dirname "${BASH_SOURCE[0]}")/project_file.sh" atlassian_site) || return 1
[[ -s "$ATLASSIAN_SITE_FILE" ]] || {
  echo "atlassian-auth.sh: no site in $ATLASSIAN_SITE_FILE" >&2; return 1; }
ATLASSIAN_SITE=$(tr -d '\n' < "$ATLASSIAN_SITE_FILE")
export ATLASSIAN_SITE

# Single source of truth: the mode-600 dotfiles (~/.jira-email, ~/.jira-token).
# Falls back to the project's .mcp.json only if a dotfile is absent, so a token rotated in the
# canonical place can't silently leave this helper on a stale credential.
if [[ -r "${HOME}/.jira-email" && -r "${HOME}/.jira-token" ]]; then
  JIRA_USER=$(tr -d '\n' < "${HOME}/.jira-email")
  JIRA_TOKEN=$(tr -d '\n' < "${HOME}/.jira-token")
else
  _mcp="$(dirname "$(dirname "$ATLASSIAN_SITE_FILE")")/.mcp.json"
  JIRA_USER=$(jq -r '.mcpServers["mcp-atlassian"].env.JIRA_USERNAME' "$_mcp")
  JIRA_TOKEN=$(jq -r '.mcpServers["mcp-atlassian"].env.JIRA_API_TOKEN' "$_mcp")
  unset _mcp
fi
export JIRA_USER JIRA_TOKEN

atlassian_curl() {
  curl -s -u "${JIRA_USER}:${JIRA_TOKEN}" -H "Accept: application/json" "$@"
}
