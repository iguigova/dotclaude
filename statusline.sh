#!/bin/bash
# Claude Code Status Line — single line
# Fields: context bar, directory, git branch, lines changed, cost, model, version, effort, account
#
# The account is the emailAddress of the login in $CLAUDE_CONFIG_DIR/.claude.json
# (~/.claude.json when unset), – when there is none.
#
# Usage:
#   statusline.sh               # reads the status JSON Claude Code sends on stdin
#   statusline.sh --self-test
#
# Its git and start-time caches live in TMPDIR, /tmp when unset.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

if [[ "${1:-}" == --self-test ]]; then
  set +e
  # The account comes from the fixture's login unless a case names another config dir.
  unset CLAUDE_CONFIG_DIR
  # shellcheck source=scripts/tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/scripts/tap.sh"
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  self=$(cd "$(dirname "$0")" && pwd)/${0##*/}
  line() {  # <json> — the line it prints, colours stripped, in a sandbox HOME and TMPDIR
    raw "$1" | sed 's/\x1b\[[0-9;]*m//g'
  }
  raw() { (cd "$fx" && printf '%s' "$1" | HOME="$fx" TMPDIR="$fx" bash "$self"); }  # <json>
  git init -q -b feat "$fx/repo"
  now=$(date +%s)
  login() { printf '{"oauthAccount":{"emailAddress":"%s"}}' "$1" > "$2/.claude.json"; }  # <email> <dir>
  login me@example.test "$fx"
  full='{"model":{"display_name":"Opus"},"version":"2.1","context_window":{"used_percentage":35},
    "cost":{"total_cost_usd":0.12345,"total_lines_added":7,"total_lines_removed":3},"session_id":"s1",
    "workspace":{"current_dir":"'"$fx"'/repo"},"effort_level":"high"}'
  out=$(line "$full")
  tap_like "every field is shown, in order" "$out" "████░░░░░░  35%  ~/repo  feat  +7/-3  \$0.1235  ⏱ *Opus v2.1 \[high\]  me@example.test"
  tap_like "the git and start caches go to TMPDIR" "$(ls "$fx")" "*claude-statusline-git-s1*claude-statusline-start-s1*"
  printf 'cached' > "$fx/claude-statusline-git-s1"
  tap_like "a branch cached under 5s ago is reused" "$(line "$full")" "*  cached  *"
  tap_like "a context under 60% is green" "$(raw "$full")" $'\033[32m████*'
  tap_like "a context of 60% is yellow" "$(raw '{"context_window":{"used_percentage":60}}')" $'\033[33m██████░░░░*'
  tap_like "a context of 80% is red" "$(raw '{"context_window":{"used_percentage":80}}')" $'\033[31m████████░░*'
  echo $((now - 3700)) > "$fx/claude-statusline-start-s2"
  tap_like "a session over an hour old shows hours and minutes" "$(line '{"session_id":"s2"}')" "*⏱ 1h01m *"
  echo $((now - 75)) > "$fx/claude-statusline-start-s3"
  tap_like "a session over a minute old shows minutes and seconds" "$(line '{"session_id":"s3"}')" "*⏱ 1m1?s *"
  tap_like "missing fields fall back, and effort to – with no settings" "$(line '{}')" "░░░░░░░░░░   0%  .  –  +0/-0  \$0.0000  ⏱ *s    unknown v? \[–\]  me@example.test"
  mkdir -p "$fx/.claude"; printf '{"effortLevel":"low"}' > "$fx/.claude/settings.json"
  tap_like "with no effort in the input, settings.json's is shown" "$(line '{}')" "* \[low\]  me@example.test"
  mkdir "$fx/other"; login other@example.test "$fx/other"
  tap_like "CLAUDE_CONFIG_DIR names the account's login" "$(CLAUDE_CONFIG_DIR="$fx/other" line '{}')" "* \[low\]  other@example.test"
  printf 'not json' > "$fx/other/.claude.json"
  tap_like "an unreadable login file shows –" "$(CLAUDE_CONFIG_DIR="$fx/other" line '{}')" "* \[low\]  –"
  printf '{}' > "$fx/other/.claude.json"
  tap_like "a login file with no account shows –" "$(CLAUDE_CONFIG_DIR="$fx/other" line '{}')" "* \[low\]  –"
  tap_like "a config dir with no login file shows –" "$(CLAUDE_CONFIG_DIR="$fx/none" line '{}')" "* \[low\]  –"
  tap_like "the 5-hour window shows what is left and when it resets" \
    "$(line '{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'$((now + 7290))'}}}')" "*  5h:70%/2h01m  *"
  tap_like "a 5-hour window with no reset time shows what is left" \
    "$(line '{"rate_limits":{"five_hour":{"used_percentage":30}}}')" "*  5h:70%  *"
  git init -q -b main "$fx/new"
  tap_like "a repo with no commit yet shows its branch on the one line" \
    "$(line '{"workspace":{"current_dir":"'"$fx"'/new"}}')" "*  ~/new  main  +0/-0 *"
  git -C "$fx/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  git -C "$fx/repo" checkout -q --detach
  tap_like "a detached HEAD shows no branch" \
    "$(line '{"session_id":"s4","workspace":{"current_dir":"'"$fx"'/repo"}}')" "*  ~/repo  –  +0/-0 *"
  tap_like "a long directory keeps its last two parts" \
    "$(line '{"workspace":{"current_dir":"/aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dddd"}}')" "*  …/cccccccccc/dddd  *"
  tap_end
fi

# Read JSON from stdin
input=$(cat)

# --- Parse fields with null handling ---
model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
version=$(echo "$input" | jq -r '.version // "?"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
lines_add=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_rm=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
session_id=$(echo "$input" | jq -r '.session_id // ""')
work_dir=$(echo "$input" | jq -r '.workspace.current_dir // "."')
five_h_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

# Effort level: try JSON first, fall back to settings.json
effort=$(echo "$input" | jq -r '.effort_level // empty' 2>/dev/null)
if [[ -z "$effort" ]]; then
  effort=$(jq -r '.effortLevel // "–"' ~/.claude/settings.json 2>/dev/null || echo "–")
fi

# Account: the login of the config dir this session runs under
account=$(jq -r '.oauthAccount.emailAddress // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null) || account=""
[[ -n "$account" ]] || account="–"

# --- Context bar (10 chars wide) ---
filled=$(awk "BEGIN { printf \"%.0f\", $used_pct / 10 }")
bar=""
for ((i = 0; i < 10; i++)); do
  if ((i < filled)); then
    bar+="█"
  else
    bar+="░"
  fi
done

# Context color: green < 60%, yellow 60-80%, red > 80%
if awk "BEGIN { exit ($used_pct >= 80) ? 0 : 1 }"; then
  ctx_color="\033[31m"
elif awk "BEGIN { exit ($used_pct >= 60) ? 0 : 1 }"; then
  ctx_color="\033[33m"
else
  ctx_color="\033[32m"
fi

# --- Git branch (cached 5s) ---
cache_file="${TMPDIR:-/tmp}/claude-statusline-git-${session_id}"
branch="–"
now=$(date +%s)

if [[ -f "$cache_file" ]]; then
  cache_age=$(( now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
  if ((cache_age < 5)); then
    branch=$(cat "$cache_file")
  fi
fi

if [[ "$branch" == "–" ]]; then
  branch=$(git -C "$work_dir" branch --show-current 2>/dev/null) || branch=""
  [[ -n "$branch" ]] || branch="–"
  echo -n "$branch" > "$cache_file" 2>/dev/null || true
fi

# --- Session duration (stamp start on first render) ---
start_file="${TMPDIR:-/tmp}/claude-statusline-start-${session_id}"
if [[ -n "$session_id" && ! -f "$start_file" ]]; then
  date +%s > "$start_file" 2>/dev/null || true
fi
start_ts=$(cat "$start_file" 2>/dev/null || echo "$now")
elapsed=$(( now - start_ts ))
if ((elapsed >= 3600)); then
  duration=$(printf "%dh%02dm" $((elapsed / 3600)) $(((elapsed % 3600) / 60)))
elif ((elapsed >= 60)); then
  duration=$(printf "%dm%02ds" $((elapsed / 60)) $((elapsed % 60)))
else
  duration=$(printf "%ds" "$elapsed")
fi

# --- Colors ---
reset="\033[0m"
dim="\033[2m"
cyan="\033[36m"
magenta="\033[35m"
green="\033[32m"
yellow="\033[33m"
blue="\033[34m"

# --- 5-hour session window (Pro/Max only; silently skipped otherwise) ---
session_seg=""
if [[ -n "$five_h_pct" ]]; then
  remaining_pct=$(awk "BEGIN { printf \"%.0f\", 100 - $five_h_pct }")
  if awk "BEGIN { exit ($five_h_pct >= 80) ? 0 : 1 }"; then
    sess_color="\033[31m"
  elif awk "BEGIN { exit ($five_h_pct >= 60) ? 0 : 1 }"; then
    sess_color="\033[33m"
  else
    sess_color="\033[32m"
  fi
  if [[ -n "$five_h_reset" ]]; then
    secs_left=$(( five_h_reset - now ))
    if ((secs_left > 0)); then
      reset_str=$(printf "%dh%02dm" $((secs_left / 3600)) $(((secs_left % 3600) / 60)))
    else
      reset_str="0m"
    fi
    session_seg=$(printf "${sess_color}5h:%s%%/%s${reset}" "$remaining_pct" "$reset_str")
  else
    session_seg=$(printf "${sess_color}5h:%s%%${reset}" "$remaining_pct")
  fi
fi

# --- Shorten directory ---
short_dir="${work_dir/#"$HOME"/\~}"
if ((${#short_dir} > 30)); then
  short_dir="…/$(echo "$short_dir" | rev | cut -d'/' -f1-2 | rev)"
fi

# --- Output single line ---
# Order: context, dir, branch, lines, cost, duration, model, version, effort, account
printf "${ctx_color}%s %3.0f%%${reset}  ${dim}%s${reset}  ${cyan}%s${reset}  ${green}+%s${reset}/${magenta}-%s${reset}  ${yellow}\$%.4f${reset}  ${dim}⏱ %s${reset}  %b  ${cyan}%s${reset} ${dim}v%s${reset} ${blue}[%s]${reset}  ${dim}%s${reset}\n" \
  "$bar" "$used_pct" "$short_dir" "$branch" "$lines_add" "$lines_rm" "$cost" "$duration" "$session_seg" "$model" "$version" "$effort" "$account"
