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
# a copy against a fixture site, fixture secrets and a curl that prints its
# arguments, so no network and no real credential is read.

# The guard compares this file with the script being run, so a helper sourcing
# this file with its own `--self-test` in $1 never reaches the branch.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${1:-}" == "--self-test" ]] || {
    echo "atlassian-auth.sh: source this file; executed, it takes only --self-test" >&2; exit 2; }
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/.claude/helpers" "$fx/home" "$fx/bin"
  cp "$0" "$fx/.claude/helpers/atlassian-auth.sh"
  cp "$(dirname "$0")/project_file.sh" "$(dirname "$0")/secret_file.sh" "$fx/.claude/helpers/"
  mkdir -p "$fx/.secrets"; : > "$fx/.claude/session_history.md"
  printf 'https://example.invalid\n' > "$fx/.claude/atlassian_site"
  printf 'me@example.invalid\n' > "$fx/.secrets/jira-email"
  printf 'tok\n' > "$fx/.secrets/jira-token"
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
  # shellcheck source=tap.sh
  . "$(dirname "$0")/tap.sh"
  tap_is "the site is read from the nearest .claude/atlassian_site above \$PWD" \
    "$(sed -n 1p <<<"$got" | cut -d'|' -f1)" "https://example.invalid"
  tap_is "credentials come from the project's .secrets/, newlines trimmed" \
    "$(sed -n 1p <<<"$got")" "$(sed -n 1p <<<"$want")"
  tap_is "atlassian_curl sends them as basic auth with the JSON Accept header" \
    "$(sed -n 2p <<<"$got")" "$(sed -n 2p <<<"$want")"
  tap_is "a missing site fails the source" "$site_rc" 1
  tap_run "and says where it looked" \
    grep -q 'no .claude/atlassian_site at or above' "$fx/err"
  tap_end
fi

# The site is the one line in the project's .claude/atlassian_site, so each project
# names its own site.
ATLASSIAN_SITE_FILE=$("$(dirname "${BASH_SOURCE[0]}")/project_file.sh" atlassian_site) || return 1
[[ -s "$ATLASSIAN_SITE_FILE" ]] || {
  echo "atlassian-auth.sh: no site in $ATLASSIAN_SITE_FILE" >&2; return 1; }
ATLASSIAN_SITE=$(tr -d '\n' < "$ATLASSIAN_SITE_FILE")
export ATLASSIAN_SITE

# The credential is the project's .secrets/jira-email and .secrets/jira-token
# (secret_file.sh), and nowhere else; a missing one fails here, naming it.
_email=$("$(dirname "${BASH_SOURCE[0]}")/secret_file.sh" jira-email) || return 1
_token=$("$(dirname "${BASH_SOURCE[0]}")/secret_file.sh" jira-token) || return 1
JIRA_USER=$(tr -d '\n' < "$_email")
JIRA_TOKEN=$(tr -d '\n' < "$_token")
unset _email _token
export JIRA_USER JIRA_TOKEN

atlassian_curl() {
  curl -s -u "${JIRA_USER}:${JIRA_TOKEN}" -H "Accept: application/json" "$@"
}
