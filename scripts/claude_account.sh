#!/usr/bin/env bash
# claude_account.sh — run a project under its own Claude Code account, sharing
# every piece of the tooling in ~/.claude.
#
# An account is a config directory: Claude Code reads its login from
# $CLAUDE_CONFIG_DIR (default ~/.claude), and keeps its .claude.json there too.
# A project names its account in one line, `.claude/config_dir` at its root
# (e.g. `~/.claude-work`). That directory holds the account's own login and
# a symlink to every other entry of ~/.claude, so rules, skills, scripts, hooks,
# memory and history stay one copy.
#
# Usage:
#   claude_account.sh dir                     # the config dir $PWD's project names, synced
#   claude_account.sh check                   # SessionStart: say so when the session's account is not it
#   claude_account.sh sync <dir>              # build or repair <dir>
#   claude_account.sh --self-test
#
# dir — walks up from $PWD to the first `.claude/config_dir`, syncs that
#   directory and prints it, for the caller to export as CLAUDE_CONFIG_DIR. The
#   `claude` function in ~/.claude/shell/memcap.sh is that caller. It prints nothing
#   with no such file, or with CLAUDE_CONFIG_DIR already set, which is how a
#   nested `claude -p` keeps its parent's account. A sync conflict goes to
#   stderr and the dir is still printed: drift never stops a launch. A blank
#   `config_dir` is refused (exit 1) and prints nothing.
# check — the SessionStart hook. The account a session should run under is the
#   one its project names, else ~/.claude; when CLAUDE_CONFIG_DIR says another,
#   it prints a systemMessage naming both, which the user sees. A session
#   started by anything but the `claude` function (the desktop app, an IDE,
#   `command claude`) is how that happens.
# sync — links each entry of ~/.claude into <dir> except the account-bound ones
#   (ACCOUNT_BOUND below), removes a link of <dir> whose target is gone, and
#   never replaces a real file: one in the way is reported, and the exit is 1.
#   So is a real entry only <dir> has, other than its .claude.json and the
#   account-bound ones: a skill dir, agent or style first made under the
#   account, which the other accounts would never see.
#   Then it mirrors the user-scope mcpServers of ~/.claude.json into
#   <dir>/.claude.json: the default account is their one source, so a server is
#   added there (`claude mcp add -s user` outside any such project). A project's
#   own servers live only in its account (`claude mcp add -s local` inside it).
#   Exit 0 clean, 1 a conflict, 2 usage.
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

# Entries of ~/.claude that belong to one login, so each account keeps its own:
# the credentials, the org's managed settings and policy limits with their
# signatures and stamps, the remote-control daemon and its session registry, the
# .claude.json backups, the account's caches, and .git, which no account reads.
# Each is a glob pattern.
ACCOUNT_BOUND=(.credentials.json 'remote-settings.json*' 'policy-limits.json*'
  daemon daemon-auth-cooldown daemon-auth-status.json sessions backups cache
  stats-cache.json .last-update-result.json .last-cleanup .git)

# shellcheck disable=SC2053  # $b is a pattern, matched unquoted on purpose
bound() { local b; for b in "${ACCOUNT_BOUND[@]}"; do [[ "$1" == $b ]] && return 0; done; return 1; }

ca_sync() {  # DIR
  local dir="$1" shared="$HOME/.claude" rc=0 src name dst
  mkdir -p "$dir" && chmod 700 "$dir" || return 2
  shopt -s dotglob nullglob
  for src in "$shared"/*; do
    name=$(basename "$src"); dst="$dir/$name"
    bound "$name" && continue
    if [[ -L "$dst" ]]; then
      [[ "$(readlink "$dst")" == "$src" ]] && continue
      echo "claude_account: $dst links elsewhere ($(readlink "$dst")); left as it is" >&2; rc=1
    elif [[ -e "$dst" ]]; then
      echo "claude_account: $dst is a real entry, not a link to $src; left as it is" >&2; rc=1
    else
      ln -s "$src" "$dst"
    fi
  done
  for dst in "$dir"/*; do
    name=$(basename "$dst")
    if [[ -L "$dst" ]]; then
      [[ ! -e "$dst" && "$(readlink "$dst")" == "$shared"/* ]] && rm -- "$dst"
    elif [[ ! -e "$shared/$name" && "$name" != .claude.json ]] && ! bound "$name"; then
      echo "claude_account: $dst is only in this account; move it into $shared to share it, or add it to ACCOUNT_BOUND" >&2; rc=1
    fi
  done
  shopt -u dotglob nullglob

  [[ -f "$HOME/.claude.json" ]] || return $rc
  # Written only when the mirror differs, so a running session's own writes to
  # the file are not raced on every launch.
  python3 - "$HOME/.claude.json" "$dir/.claude.json" <<'PY' || rc=1
import json, os, sys
src_path, dst_path = sys.argv[1], sys.argv[2]
want = json.load(open(src_path)).get("mcpServers", {})
dst = json.load(open(dst_path)) if os.path.exists(dst_path) else {}
if dst.get("mcpServers", {}) != want:
    dst["mcpServers"] = want
    tmp = dst_path + ".mirror"
    with open(tmp, "w") as f: json.dump(dst, f, indent=2)
    os.chmod(tmp, 0o600); os.replace(tmp, dst_path)
PY
  return $rc
}

ca_real() { realpath -m -- "$1"; }

# The config dir the first `.claude/config_dir` from DIR up names. Exit 1 when
# there is none, 2 when the file's first line is blank.
ca_find() {  # DIR
  local d="$1" line=""
  while :; do
    if [[ -f "$d/.claude/config_dir" ]]; then
      read -r line < "$d/.claude/config_dir"
      [[ -n "${line// }" ]] || { echo "claude_account: $d/.claude/config_dir is blank; it names no account" >&2; return 2; }
      [[ "$line" == \~/* ]] && line="$HOME/${line#\~/}"
      printf '%s\n' "$line"; return 0
    fi
    [[ "$d" == / ]] && return 1
    d=$(dirname "$d")
  done
}

ca_dir() {
  local dir rc
  [[ -z "${CLAUDE_CONFIG_DIR:-}" ]] || return 0
  dir=$(ca_find "$PWD"); rc=$?
  (( rc == 1 )) && return 0
  (( rc == 0 )) || return 1
  ca_sync "$dir" || echo "claude_account: $dir has a conflict above; starting anyway" >&2
  printf '%s\n' "$dir"
}

# The hook payload's cwd is the session's; $PWD stands in without one.
ca_check() {
  local cwd want have
  cwd=$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null)
  [[ -n "$cwd" ]] || cwd="$PWD"
  want=$(ca_find "$cwd" 2>/dev/null) || want="$HOME/.claude"
  have="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [[ "$(ca_real "$want")" == "$(ca_real "$have")" ]] && return 0
  python3 -c 'import json,sys
print(json.dumps({"systemMessage": "Wrong Claude account: this session runs on %s, but %s uses %s. Quit and start it with the claude shell function from the project." % tuple(sys.argv[1:4])}))' \
    "$have" "$cwd" "$want"
}

# ---------------------------------------------------------------- self-test
# A fake HOME, with a project that names its account and a dir that does not.
self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local d self out
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  unset CLAUDE_CONFIG_DIR  # a session under an account runs this test too
  mkdir -p "$d/home/.claude/skills" "$d/home/.claude/projects" "$d/proj/.claude" "$d/proj/api/x" "$d/other"
  echo rules > "$d/home/.claude/CLAUDE.md"
  echo secret > "$d/home/.claude/.credentials.json"
  cat > "$d/home/.claude.json" <<'J'
{"oauthAccount":{"emailAddress":"me@x"},"mcpServers":{"pw":{}},
 "projects":{"PROJ":{"mcpServers":{"pm":{}}},"PROJ/api/x":{"t":1},"OTHER":{"t":2}}}
J
  sed -i "s|PROJ|$d/proj|g; s|OTHER|$d/other|g" "$d/home/.claude.json"
  # shellcheck disable=SC2088 # the literal tilde the file holds
  echo '~/.acct' > "$d/proj/.claude/config_dir"
  local acct="$d/home/.acct"

  sync() { HOME="$d/home" "$self" sync "$acct" >/dev/null 2>&1; echo $?; }
  json() { python3 -c "import json,sys;d=json.load(open('$acct/.claude.json'));print($1)"; }
  check() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }

  check "a first sync is clean" 0 "$(sync)"
  check "a shared entry is linked" "$d/home/.claude/CLAUDE.md" "$(readlink "$acct/CLAUDE.md")"
  check "a shared directory is linked" "$d/home/.claude/skills" "$(readlink "$acct/skills")"
  check "the credentials are not linked" absent "$([[ -e $acct/.credentials.json ]] && echo present || echo absent)"
  check "the login is not seeded" False "$(json "'oauthAccount' in d")"
  check "the user-scope MCP servers are mirrored" "['pw']" "$(json "list(d['mcpServers'])")"
  check "no project entry is copied" "{}" "$(json "d.get('projects', {})")"
  check "a second sync is clean" 0 "$(sync)"

  python3 -c "import json;p='$acct/.claude.json';d=json.load(open(p));d['mcpServers']={'stale':{}};d['projects']={'P':{'t':3}};json.dump(d,open(p,'w'))"
  sed -i 's/"pw"/"pw2"/' "$d/home/.claude.json"
  check "a re-sync is clean" 0 "$(sync)"
  check "and mirrors the source's servers over a stale copy" "['pw2']" "$(json "list(d['mcpServers'])")"
  check "and keeps the account's own project entries" "{'P': {'t': 3}}" "$(json "d['projects']")"

  mkdir "$d/home/.claude/plans"; echo own > "$acct/plans"
  check "a real entry in the way is a conflict" 1 "$(sync)"
  check "and the entry in the way is kept" own "$(cat "$acct/plans")"
  rm "$acct/plans"

  mkdir "$acct/agents"
  HOME="$d/home" "$self" sync "$acct" >/dev/null 2>"$d/err"; local orc=$?
  check "an entry only the account has is reported" 1 "$orc"
  check "and named on stderr" 0 "$(grep -q 'agents is only in this account' "$d/err" && echo 0 || echo 1)"
  check "and the account's own entry is kept" present "$([[ -d $acct/agents ]] && echo present || echo absent)"
  mkdir "$acct/sessions"; touch "$acct/policy-limits.json.signature.json"
  HOME="$d/home" "$self" sync "$acct" 2>"$d/err" >/dev/null
  check "an account-bound entry is not reported" 1 "$(grep -q 'sessions' "$d/err" && echo 0 || echo 1)"
  check "nor one a bound pattern matches" 1 "$(grep -q 'policy-limits' "$d/err" && echo 0 || echo 1)"
  rmdir "$acct/agents" "$acct/sessions"; rm "$acct/policy-limits.json.signature.json"

  rm -r "$d/home/.claude/skills"
  sync >/dev/null
  check "a link whose target is gone is removed" absent "$([[ -L $acct/skills ]] && echo present || echo absent)"

  rm -r "$acct"
  out=$(cd "$d/proj/api/x" && HOME="$d/home" "$self" dir 2>&1)
  check "dir under a project prints its account" "$acct" "$out"
  check "and builds it" "$d/home/.claude/CLAUDE.md" "$(readlink "$acct/CLAUDE.md")"
  rm "$acct/plans"; echo own > "$acct/plans"
  out=$(cd "$d/proj" && HOME="$d/home" "$self" dir 2>"$d/err")
  check "a conflict still prints the account" "$acct" "$out"
  check "and names the conflict on stderr" 0 "$(grep -q 'plans is a real entry' "$d/err" && echo 0 || echo 1)"
  out=$(cd "$d/other" && HOME="$d/home" "$self" dir 2>&1)
  check "dir outside a project prints nothing" "" "$out"
  out=$(cd "$d/proj" && CLAUDE_CONFIG_DIR=/set HOME="$d/home" "$self" dir 2>&1)
  check "dir prints nothing when a config dir is already set" "" "$out"

  mkdir -p "$d/blank/.claude"; echo '  ' > "$d/blank/.claude/config_dir"
  out=$(cd "$d/blank" && HOME="$d/home" "$self" dir 2>"$d/err"); local brc=$?
  check "a blank config_dir is refused" "1:" "$brc:$out"
  check "and says it is blank" 0 "$(grep -q 'is blank' "$d/err" && echo 0 || echo 1)"

  hook() { printf '{"cwd":"%s"}' "$1" | HOME="$d/home" "$self" check 2>&1; }
  check "check is quiet on the account the project names" "" "$(CLAUDE_CONFIG_DIR="$acct" hook "$d/proj/api/x")"
  check "check is quiet on the default outside a project" "" "$(hook "$d/other")"
  out=$(hook "$d/proj")
  check "check names a project run on the default account" 0 \
    "$([[ "$out" == *systemMessage*"runs on $d/home/.claude"*"uses $acct"* ]] && echo 0 || echo 1)"
  out=$(CLAUDE_CONFIG_DIR="$acct" hook "$d/other")
  check "check names a plain dir run on a project's account" 0 \
    "$([[ "$out" == *"runs on $acct"*"uses $d/home/.claude"* ]] && echo 0 || echo 1)"
  check "check emits JSON the harness can read" 0 \
    "$(python3 -c 'import json,sys;json.loads(sys.argv[1])' "$out" >/dev/null 2>&1 && echo 0 || echo 1)"
}

# ---------------------------------------------------------------- main
case "${1:-}" in
  --self-test) self_test; tap_end ;;
  dir) ca_dir ;;
  check) ca_check ;;
  sync) (( $# == 2 )) || { echo "usage: claude_account.sh sync <dir>" >&2; exit 2; }
        ca_sync "$2"; exit $? ;;
  *) echo "usage: claude_account.sh dir | check | sync <dir> | --self-test" >&2; exit 2 ;;
esac
