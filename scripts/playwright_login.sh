#!/usr/bin/env bash
# playwright_login.sh — refresh the saved logins that every Playwright MCP
# session starts from. It opens a headed Chrome on <url>, already signed in
# with the logins in the state file. You log in by hand and close the window
# (or press Ctrl-C), and that browser's logins then replace the file. The file is the one
# `~/.claude.json` passes the playwright server as --storage-state, so the
# server and this script always name the same file. The file is replaced only
# by a save that holds a cookies list, whatever the browser's exit status:
# Playwright saves on Ctrl-C and then exits 130. The file stays mode 600.
#
# Usage:
#   playwright_login.sh <url>
#   playwright_login.sh --self-test
#
# CLAUDE_JSON (default ~/.claude.json) and PLAYWRIGHT_CLI (default
# `npx -y -p @playwright/mcp playwright`, the copy the MCP server runs) exist
# for the self-test.
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ "${1:-}" == "--self-test" ]]; then
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  me="$HERE/$(basename "$0")"
  # A stand-in for `playwright open`: it records its arguments and writes
  # $FAKE_SAVE to the --save-storage file, then exits $FAKE_EXIT.
  cat > "$fx/pw" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_ARGS"
while [[ $# -gt 0 ]]; do
  [[ "$1" == --save-storage && -n "$FAKE_SAVE" ]] && printf '%s' "$FAKE_SAVE" > "$2"
  shift
done
exit "${FAKE_EXIT:-0}"
EOF
  chmod +x "$fx/pw"
  cfg() { printf '{"mcpServers":{"playwright":{"args":%s}}}' "$1" > "$fx/claude.json"; }
  run() {  # <fake save> <url>
    CLAUDE_JSON="$fx/claude.json" PLAYWRIGHT_CLI="$fx/pw" FAKE_ARGS="$fx/args" \
      FAKE_SAVE="$1" "$me" "$2"
  }
  # shellcheck source=tap.sh
  . "$HERE/tap.sh"
  st="$fx/state.json"
  cfg "[\"-y\",\"@playwright/mcp\",\"--isolated\",\"--storage-state\",\"$st\"]"
  printf '{"cookies":[{"name":"old"}],"origins":[]}' > "$st"; chmod 600 "$st"

  run '{"cookies":[{"name":"new"}],"origins":[]}' https://example.com >&2
  tap_is "a good save replaces the state file" "$(jq -r '.cookies[0].name' "$st")" new
  tap_is "the replaced state file stays mode 600" "$(stat -c %a "$st")" 600
  tap_is "the browser opens the url in Chrome, loading the state file" \
    "$(sed -n '1,5p;8p' "$fx/args" | tr '\n' ' ')" "open --channel chrome --load-storage $st https://example.com "
  tap_is "the browser saves to a temporary file beside the state file" \
    "$(sed -n 6p "$fx/args") $(dirname "$(sed -n 7p "$fx/args")")" "--save-storage $fx"
  tap_fails "a save without a cookies list fails" run '' https://example.com
  tap_is "a failed save leaves the state file as it was" "$(jq -r '.cookies[0].name' "$st")" new
  tap_is "a failed save leaves no temporary file behind" "$(find "$fx" -name 'state.json.*' | wc -l)" 0
  FAKE_EXIT=130 run '{"cookies":[{"name":"ctrl-c"}],"origins":[]}' https://example.com >&2
  tap_is "a save on Ctrl-C, exit 130, replaces the state file" "$(jq -r '.cookies[0].name' "$st")" ctrl-c
  tap_fails "a browser that exits non-zero without saving fails" env FAKE_EXIT=1 \
    CLAUDE_JSON="$fx/claude.json" PLAYWRIGHT_CLI="$fx/pw" FAKE_ARGS="$fx/args" FAKE_SAVE= "$me" https://example.com

  rm "$st"
  run '{"cookies":[],"origins":[]}' https://example.com >&2
  tap_fails "with no state file yet the browser opens without loading one" \
    grep -qx -- --load-storage "$fx/args"
  tap_is "with no state file yet a good save creates it" "$(jq -c .cookies "$st")" '[]'

  cfg '["-y","@playwright/mcp","--isolated"]'
  tap_fails "a server with no --storage-state is refused" run '{"cookies":[]}' https://example.com
  tap_fails "no url is a usage error" "$me"
  tap_end
fi

[[ $# -eq 1 && "$1" == http*://* ]] || { echo "Usage: $0 <url> | --self-test" >&2; exit 2; }
url=$1
cfg_file=${CLAUDE_JSON:-$HOME/.claude.json}
read -ra pw <<< "${PLAYWRIGHT_CLI:-npx -y -p @playwright/mcp playwright}"

state=$(jq -r '.mcpServers.playwright.args // [] | index("--storage-state") as $i
               | if $i == null then empty else .[$i + 1] end' "$cfg_file")
[[ -n "$state" ]] || {
  echo "playwright_login.sh: $cfg_file gives the playwright server no --storage-state file" >&2
  exit 1
}

tmp=$(mktemp "$state.XXXXXX")  # mode 600, beside the file, so the mv is atomic
trap 'rm -f "$tmp"' EXIT
load=()
[[ -e "$state" ]] && load=(--load-storage "$state")
echo "playwright_login.sh: log in, then close the browser window to save to $state" >&2
rc=0
"${pw[@]}" open --channel chrome "${load[@]}" --save-storage "$tmp" "$url" || rc=$?

jq -e '.cookies | type == "array"' "$tmp" > /dev/null 2>&1 || {
  echo "playwright_login.sh: the browser (exit $rc) saved no logins; $state is unchanged" >&2
  exit 1
}
mv "$tmp" "$state"
echo "playwright_login.sh: saved $(jq '.cookies | length' "$state") cookies to $state" >&2
