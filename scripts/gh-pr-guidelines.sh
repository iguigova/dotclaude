#!/usr/bin/env bash
# Emit the coding-guideline files relevant to a PR's changed files, so
# /review:pr Reads exactly the right ones instead of running the ext->path
# map by hand. Reads the gh-pr-fetch.sh JSON on stdin (uses .meta.files[].path)
# and prints one absolute guideline path per line — the two that apply to every
# change always, language and markup guidelines only when a matching extension
# is present. Only paths that exist on disk are emitted.
#
# Usage:
#   gh-pr-fetch.sh <ref> > "$D/pr.json"
#   gh-pr-guidelines.sh < "$D/pr.json"
#   gh-pr-guidelines.sh --self-test
#
# Output: newline-separated absolute paths (Read each silently before reviewing).
#
# coding_guidelines.md and style_guidelines.md apply to every change, so both
# are always emitted (~/.claude/CLAUDE.md requires both of every session).
# .rb, .rake and the root Gemfile/Rakefile/config.ru reach the Ruby guidelines.
# .yml maps to nothing beyond the pair.
# .haml/.erb/.slim are Rails markup and reach the accessibility guidelines the
# same way .html does. .clj/.cljs/.cljc/.edn reach the Clojure guidelines.
# .hs, .go and the Clojure extensions are mapped and currently unexercised — no
# repo cloned here tracks them.
#
# GUIDELINES_DIR overrides the directory the paths are resolved in (the
# self-test uses it; leave it unset in normal use).

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

GLOBAL="${GUIDELINES_DIR:-$HOME/.claude}"

select_guidelines() {  # paths on stdin, one per line -> guideline paths on stdout
  declare -A want=()
  want["$GLOBAL/coding_guidelines.md"]=1   # general principles — every change
  want["$GLOBAL/style_guidelines.md"]=1    # style and formatting — every change

  local p
  while IFS= read -r p; do
    case "$p" in
      *.py)
        want["$GLOBAL/python_coding_guidelines.md"]=1 ;;
      *.rb|*.rake|Gemfile|*/Gemfile|Rakefile|*/Rakefile|config.ru|*/config.ru)
        want["$GLOBAL/ruby_coding_guidelines.md"]=1 ;;
      *.ts|*.tsx|*.js|*.jsx|*.html|*.css|*.haml|*.erb|*.slim)
        want["$GLOBAL/accessibility_guidelines.md"]=1 ;;
      *.clj|*.cljs|*.cljc|*.edn)
        want["$GLOBAL/clojure_coding_guidelines.md"]=1 ;;
      *.hs)
        want["$GLOBAL/haskell_coding_guidelines.md"]=1 ;;
      *.go)
        want["$GLOBAL/go_coding_guidelines.md"]=1 ;;
    esac
  done

  # `|| continue`, not `&& echo`: under `set -o pipefail` a trailing false test
  # makes the loop — and so the whole selector — exit 1 and print nothing, which
  # would silently review a PR against no guidelines at all.
  local f
  for f in "${!want[@]}"; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | sort
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  for g in coding_guidelines style_guidelines python_coding_guidelines \
           accessibility_guidelines haskell_coding_guidelines go_coding_guidelines \
           clojure_coding_guidelines ruby_coding_guidelines; do
    : > "$tmp/$g.md"
  done
  GLOBAL="$tmp"
  fails=()

  # <label> <newline-separated changed paths> <expected space-separated basenames>
  check() {
    local got
    got=$(printf '%s\n' "$2" | select_guidelines | sed "s#^$tmp/##" | tr '\n' ' ')
    [[ "$got" == "$3 " ]] || fails+=("$1: got '$got', want '$3 '")
  }

  base="coding_guidelines.md style_guidelines.md"
  check "non-code change gets the always-on pair" "README.md" "$base"
  check "ruby" "app/models/user.rb" "coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"
  check "rake task" "lib/tasks/x.rake" "coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"
  check "root Gemfile" "Gemfile" "coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"
  # A haml file is Rails markup that RuboCop does not lint, so it reaches
  # accessibility and not the Ruby guidelines.
  check "haml is markup, not Ruby" "app/views/x.html.haml" "accessibility_guidelines.md $base"
  check "python" "app/x.py" "coding_guidelines.md python_coding_guidelines.md style_guidelines.md"
  check "haml reaches accessibility" "app/views/x.html.haml" "accessibility_guidelines.md $base"
  check "erb reaches accessibility" "app/views/x.erb" "accessibility_guidelines.md $base"
  check "tsx reaches accessibility" "src/X.tsx" "accessibility_guidelines.md $base"
  check "clojure" "src/core.clj" "clojure_coding_guidelines.md $base"
  check "cljs and edn reach the same file" "$(printf 'src/app.cljs\nresources/config.edn')" \
        "clojure_coding_guidelines.md $base"
  check "mixed rails PR" "$(printf 'app/models/user.rb\napp/views/x.html.haml\nlib/y.py')" \
        "accessibility_guidelines.md coding_guidelines.md python_coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"

  # A guideline file that does not exist on disk is never emitted.
  rm "$tmp/go_coding_guidelines.md"
  got=$(printf 'main.go\n' | select_guidelines | tr '\n' ' ')
  [[ "$got" != *go_coding_guidelines* ]] || fails+=("emitted a guideline file that does not exist")

  # The always-on pair must actually exist where it is resolved, or every review
  # silently runs a file short.
  for f in coding_guidelines.md style_guidelines.md; do
    [ -f "$HOME/.claude/$f" ] || fails+=("$HOME/.claude/$f is missing — the always-on set would be silently short")
  done
  # A language file the selector maps but cannot resolve is skipped without a
  # word, so that language's PRs get reviewed against the general pair only.
  for f in python_coding_guidelines.md clojure_coding_guidelines.md \
           go_coding_guidelines.md haskell_coding_guidelines.md \
           accessibility_guidelines.md ruby_coding_guidelines.md; do
    [ -f "$HOME/.claude/$f" ] || fails+=("$HOME/.claude/$f is mapped but missing — those PRs silently get no language guidance")
  done

  if ((${#fails[@]})); then
    printf 'gh-pr-guidelines self-test: FAIL\n'; printf '  %s\n' "${fails[@]}"; exit 1
  fi
  echo "gh-pr-guidelines self-test: PASS (coding+style always, haml/erb/tsx -> accessibility, clj/cljs/edn -> clojure, rb/rake/Gemfile -> ruby, haml stays markup, absent file skipped, every mapped file resolves)"
  exit 0
fi

# Read and validate stdin fully before emitting anything: piping jq straight into
# the selector printed the always-on pair even for input that was not a fetch
# blob at all, so a broken step 1 looked like a PR that needed no guidelines.
paths=$(jq -r '.meta.files[].path' 2>/dev/null) || {
  echo "Expected gh-pr-fetch.sh JSON on stdin (.meta.files[].path)" >&2
  exit 1
}
printf '%s\n' "$paths" | select_guidelines
