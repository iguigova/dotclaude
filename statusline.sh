#!/bin/bash
# Claude Code Status Line — single line
# Fields: context bar, directory, git branch, lines changed, cost, model, version, effort

set -euo pipefail

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
cache_file="/tmp/claude-statusline-git-${session_id}"
branch="–"
now=$(date +%s)

if [[ -f "$cache_file" ]]; then
  cache_age=$(( now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
  if ((cache_age < 5)); then
    branch=$(cat "$cache_file")
  fi
fi

if [[ "$branch" == "–" ]]; then
  branch=$(cd "$work_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "–")
  echo -n "$branch" > "$cache_file" 2>/dev/null || true
fi

# --- Session duration (stamp start on first render) ---
start_file="/tmp/claude-statusline-start-${session_id}"
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
short_dir="${work_dir/#$HOME/~}"
if ((${#short_dir} > 30)); then
  short_dir="…/$(echo "$short_dir" | rev | cut -d'/' -f1-2 | rev)"
fi

# --- Output single line ---
# Order: context, dir, branch, lines, cost, duration, model, version, effort
printf "${ctx_color}%s %3.0f%%${reset}  ${dim}%s${reset}  ${cyan}%s${reset}  ${green}+%s${reset}/${magenta}-%s${reset}  ${yellow}\$%.4f${reset}  ${dim}⏱ %s${reset}  %b  ${cyan}%s${reset} ${dim}v%s${reset} ${blue}[%s]${reset}\n" \
  "$bar" "$used_pct" "$short_dir" "$branch" "$lines_add" "$lines_rm" "$cost" "$duration" "$session_seg" "$model" "$version" "$effort"
