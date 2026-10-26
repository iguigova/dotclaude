#!/usr/bin/env bash
# Fetch a review bot's findings on a PR into its working directory: the threads
# and notes that may still need an answer (gh-pr-bot-comments.sh) as bot.json,
# and the bot's verdict (gh-pr-bot-score.sh) as score.json, each written whole
# or not at all. /review:bot runs it in §1, and in §8 with --wait after a push,
# so the loop back to triage reads the bot's run on the pushed head.
#
# Usage:
#   gh-pr-bot-fetch.sh <pr-ref> [--wait] [bot-login-substr ...]
#   gh-pr-bot-fetch.sh --self-test
#
# The bot-login substrings go to both helpers unchanged; with none, each keeps
# its own default (any `[bot]` login for the threads, greptile for the score).
#
# --wait polls the score until it is for the PR's head commit and only then
# fetches the threads, so both files describe the bot's run on that commit. It
# gives up after GH_PR_BOT_FETCH_WAIT seconds (default 100, inside a tool call's
# two-minute default), polling every GH_PR_BOT_FETCH_INTERVAL (default 20). A
# bot that gives no score has nothing to wait for, so --wait returns at once.
#
# Prints, on stdout:
#
#   bot:   <dir>/bot.json -- <n> bot threads, <n> human threads open; <n> human notes unanswered; own review <none | nothing asked | answered | unanswered>, <n> own threads open
#   score: <dir>/score.json -- <score>/<max> (at max | below max) for <sha>, current | stale; <n> out-of-diff
#   score: <dir>/score.json -- none from this bot; <n> out-of-diff
#
# Exit: 0 both written; 1 a bad ref or a failed fetch, the previous files kept;
# 3 --wait ran out with the score still for an earlier commit, nothing written
# -- the bot has not re-run on the head yet: run it again.
#
# GH_PR_BOT_COMMENTS and GH_PR_BOT_SCORE replace the two helpers, for --self-test.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fetch() {
  local ref="" wait=0 bots=() dir comments score tb ts interval deadline
  while (($#)); do
    case "$1" in
      --wait) wait=1; shift ;;
      -*) echo "gh-pr-bot-fetch.sh: unknown option $1" >&2; return 1 ;;
      *) if [[ -z "$ref" ]]; then ref="$1"; else bots+=("$1"); fi; shift ;;
    esac
  done
  [[ -n "$ref" ]] || { echo "Usage: gh-pr-bot-fetch.sh <pr-ref> [--wait] [bot-login-substr ...]" >&2; return 1; }
  dir=$("$HERE/gh-pr-workdir.sh" "$ref") || return 1
  comments="${GH_PR_BOT_COMMENTS:-$HERE/gh-pr-bot-comments.sh}"
  score="${GH_PR_BOT_SCORE:-$HERE/gh-pr-bot-score.sh}"
  interval="${GH_PR_BOT_FETCH_INTERVAL:-20}"
  deadline=$((SECONDS + ${GH_PR_BOT_FETCH_WAIT:-100}))
  tb=$(mktemp "$dir/bot.json.XXXXXX")
  ts=$(mktemp "$dir/score.json.XXXXXX")

  while :; do
    if ! "$score" "$ref" "${bots[@]}" > "$ts" || ! jq -e 'type == "object"' "$ts" >/dev/null 2>&1; then
      rm -f "$tb" "$ts"; echo "gh-pr-bot-fetch.sh: score fetch failed for $ref" >&2; return 1
    fi
    ((wait)) || break
    jq -e '.score == null or (.stale | not)' "$ts" >/dev/null && break
    if ((SECONDS + interval >= deadline)); then
      echo "gh-pr-bot-fetch.sh: the score is still for $(jq -r '.reviewed_sha // "no commit"' "$ts"), not the head $(jq -r '.head_sha' "$ts") -- the bot has not re-run yet: run again" >&2
      rm -f "$tb" "$ts"; return 3
    fi
    sleep "$interval"
  done

  if ! "$comments" "$ref" "${bots[@]}" > "$tb" || ! jq -e 'type == "object"' "$tb" >/dev/null 2>&1; then
    rm -f "$tb" "$ts"; echo "gh-pr-bot-fetch.sh: comment fetch failed for $ref" >&2; return 1
  fi
  mv "$tb" "$dir/bot.json"
  mv "$ts" "$dir/score.json"

  jq -r --arg f "$dir/bot.json" '"bot:   \($f) -- \(.open_count) bot threads, \(.human_open_count) human threads open; \([.human_notes[]? | select(.answered | not)] | length) human notes unanswered; own review \(if .own_review == null then "none" elif (.own_review.asks | not) then "nothing asked" elif .own_review.answered then "answered" else "unanswered" end), \(.own_open_count) own threads open"' "$dir/bot.json"
  jq -r --arg f "$dir/score.json" '
    if .score == null then "score: \($f) -- none from this bot; \(.outside_diff_count) out-of-diff"
    else "score: \($f) -- \(.score)/\(.max) (\(if .at_max then "at max" else "below max" end)) for \(.reviewed_sha // "no commit"), \(if .stale then "stale" else "current" end); \(.outside_diff_count) out-of-diff"
    end' "$dir/score.json"
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  export GH_PR_WORKDIR_BASE="$tmp/base" GH_PR_BOT_COMMENTS="$tmp/comments" GH_PR_BOT_SCORE="$tmp/score"
  export GH_PR_BOT_FETCH_INTERVAL=0 GH_PR_BOT_FETCH_WAIT=100
  # The comment stub logs its arguments and the poll it followed; the score stub answers stale until its
  # poll count reaches $tmp/current_at, and fails when $tmp/score_fails exists;
# its "call" never repeats, so a file it overwrote never reads as unchanged.
  cat > "$tmp/comments" <<EOF
#!/bin/sh
echo "\$* after poll \$(cat "$tmp/polls")" >> "$tmp/comments.log"
[ -e "$tmp/comments_fails" ] && { echo partial; exit 1; }
[ -e "$tmp/comments_garbage" ] && { echo partial; exit 0; }
echo '{"open_count":2,"human_open_count":1,"human_notes":[{"answered":false},{"answered":true}],"own_review":{"asks":true,"answered":false},"own_open_count":1,"args":"'"\$*"'"}'
EOF
  cat > "$tmp/score" <<EOF
#!/bin/sh
echo "\$*" >> "$tmp/score.log"
[ -e "$tmp/score_fails" ] && exit 1
n=\$(( \$(cat "$tmp/polls" 2>/dev/null || echo 0) + 1 )); echo \$n > "$tmp/polls"
c=\$(( \$(cat "$tmp/calls" 2>/dev/null || echo 0) + 1 )); echo \$c > "$tmp/calls"
if [ -e "$tmp/no_score" ]; then
  echo '{"head_sha":"h2","score":null,"max":null,"at_max":false,"reviewed_sha":null,"stale":true,"outside_diff_count":0,"call":'\$c'}'
elif [ \$n -ge \$(cat "$tmp/current_at") ]; then
  echo '{"head_sha":"h2","score":5,"max":5,"at_max":true,"reviewed_sha":"h2","stale":false,"outside_diff_count":1,"call":'\$c'}'
else
  echo '{"head_sha":"h2","score":4,"max":5,"at_max":false,"reviewed_sha":"h1","stale":true,"outside_diff_count":1,"call":'\$c'}'
fi
EOF
  chmod +x "$tmp/comments" "$tmp/score"
  ref=Org/repo#7
  dir="$GH_PR_WORKDIR_BASE/Org-repo-7"
  fails=()
  run() { : > "$tmp/polls"; out=$(fetch "$@" 2>"$tmp/err") && code=0 || code=$?; }
  temps() { compgen -G "$dir/*.json.*" >/dev/null; }

  # Without --wait: one poll, both files written, a stale score said so.
  echo 3 > "$tmp/current_at"
  run "$ref" greptile
  [[ $code == 0 ]] || fails+=("plain fetch: exit $code: $(cat "$tmp/err")")
  [[ "$(cat "$tmp/polls")" == 1 ]] || fails+=("plain fetch polled $(cat "$tmp/polls") times, want 1")
  [[ "$(jq -r .args "$dir/bot.json")" == "$ref greptile" ]] || fails+=("the comment fetch was not given the ref and the bot substring")
  [[ "$(tail -1 "$tmp/score.log")" == "$ref greptile" ]] || fails+=("the score fetch was not given the ref and the bot substring")
  [[ "$out" == *"bot:   $dir/bot.json -- 2 bot threads, 1 human threads open; 1 human notes unanswered; own review unanswered, 1 own threads open"* ]] \
    || fails+=("no bot line: $out")
  [[ "$out" == *"score: $dir/score.json -- 4/5 (below max) for h1, stale; 1 out-of-diff"* ]] \
    || fails+=("no stale score line: $out")

  # --wait: polls until the score is for the head, then fetches the threads after it.
  : > "$tmp/comments.log"
  run "$ref" --wait
  [[ $code == 0 && "$(cat "$tmp/polls")" == 3 ]] || fails+=("--wait: exit $code after $(cat "$tmp/polls") polls, want 0 after 3")
  [[ "$out" == *"5/5 (at max) for h2, current"* ]] || fails+=("--wait: no current score line: $out")
  [[ "$(cat "$tmp/comments.log")" == "$ref after poll 3" ]] \
    || fails+=("--wait did not fetch the threads once, after the current score: $(cat "$tmp/comments.log")")
  [[ "$(tail -1 "$tmp/score.log")" == "$ref" ]] || fails+=("no substring given, yet one reached the score fetch")

  # --wait running out: exit 3, the previous files whole, no temp file left.
  echo 99 > "$tmp/current_at"
  GH_PR_BOT_FETCH_WAIT=0 run "$ref" --wait
  [[ $code == 3 ]] || fails+=("--wait timeout: exit $code, want 3")
  grep -q 'still for h1, not the head h2' "$tmp/err" || fails+=("--wait timeout does not name both commits: $(cat "$tmp/err")")
  [[ "$(jq -r .score "$dir/score.json")" == 5 ]] || fails+=("a timed-out wait overwrote score.json")
  temps && fails+=("a timed-out wait left a temp file")

  # A bot that gives no score has nothing to wait for.
  touch "$tmp/no_score"
  GH_PR_BOT_FETCH_WAIT=0 run "$ref" --wait
  [[ $code == 0 && "$out" == *"none from this bot; 0 out-of-diff"* ]] || fails+=("no score: exit $code: $out")
  rm "$tmp/no_score"

  # A failed fetch on either side keeps both previous files and leaves no temp file.
  echo 1 > "$tmp/current_at"
  run "$ref"
  for side in comments score comments_garbage; do
    before=$(cat "$dir/bot.json" "$dir/score.json")
    flag="$tmp/${side}_fails"; [[ $side == *_garbage ]] && flag="$tmp/$side"
    touch "$flag"
    run "$ref"
    [[ $code == 1 ]] || fails+=("failed $side fetch: exit $code, want 1")
    [[ "$(cat "$dir/bot.json" "$dir/score.json")" == "$before" ]] || fails+=("a failed $side fetch changed a file")
    temps && fails+=("a failed $side fetch left a temp file")
    rm "$flag"
  done

  run
  [[ $code == 1 ]] || fails+=("no ref: exit $code, want 1")
  run "$ref" --bogus
  [[ $code == 1 ]] || fails+=("unknown option: exit $code, want 1")

  if ((${#fails[@]})); then
    printf 'gh-pr-bot-fetch self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-bot-fetch self-test: PASS (both files whole or not at all, substrings forwarded, --wait polls to the head then fetches, timeout exit 3, no-score bot not waited on)"
  exit 0
fi

fetch "$@"
