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
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"

  # <label> <newline-separated changed paths> <expected space-separated basenames>
  check() {
    local got
    got=$(printf '%s\n' "$2" | select_guidelines | sed "s#^$tmp/##" | tr '\n' ' ')
    tap_is "$1" "$got" "$3 "
  }

  base="coding_guidelines.md style_guidelines.md"
  check "a non-code change gets the always-on pair" "README.md" "$base"
  check "a Ruby file reaches the Ruby guidelines" "app/models/user.rb" "coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"
  check "a rake task reaches the Ruby guidelines" "lib/tasks/x.rake" "coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"
  check "the root Gemfile reaches the Ruby guidelines" "Gemfile" "coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"
  # A haml file is Rails markup that RuboCop does not lint, so it reaches
  # accessibility and not the Ruby guidelines.
  check "a haml file is markup, not Ruby" "app/views/x.html.haml" "accessibility_guidelines.md $base"
  check "a Python file reaches the Python guidelines" "app/x.py" "coding_guidelines.md python_coding_guidelines.md style_guidelines.md"
  check "a haml file reaches accessibility" "app/views/x.html.haml" "accessibility_guidelines.md $base"
  check "an erb file reaches accessibility" "app/views/x.erb" "accessibility_guidelines.md $base"
  check "a tsx file reaches accessibility" "src/X.tsx" "accessibility_guidelines.md $base"
  check "a Clojure file reaches the Clojure guidelines" "src/core.clj" "clojure_coding_guidelines.md $base"
  check "cljs and edn reach the Clojure guidelines too" "$(printf 'src/app.cljs\nresources/config.edn')" \
        "clojure_coding_guidelines.md $base"
  check "a mixed Rails PR reaches every guideline its files need" "$(printf 'app/models/user.rb\napp/views/x.html.haml\nlib/y.py')" \
        "accessibility_guidelines.md coding_guidelines.md python_coding_guidelines.md ruby_coding_guidelines.md style_guidelines.md"

  # A guideline file that does not exist on disk is never emitted.
  rm "$tmp/go_coding_guidelines.md"
  got=$(printf 'main.go\n' | select_guidelines | tr '\n' ' ')
  tap_fails "a guideline file that does not exist is never emitted" \
    grep -q go_coding_guidelines <<<"$got"

  # The always-on pair must actually exist where it is resolved, or every review
  # silently runs a file short.
  for f in coding_guidelines.md style_guidelines.md; do
    tap_run "the always-on $f exists where it is resolved" test -f "$HOME/.claude/$f"
  done
  # A language file the selector maps but cannot resolve is skipped without a
  # word, so that language's PRs get reviewed against the general pair only.
  for f in python_coding_guidelines.md clojure_coding_guidelines.md \
           go_coding_guidelines.md haskell_coding_guidelines.md \
           accessibility_guidelines.md ruby_coding_guidelines.md; do
    tap_run "the mapped $f exists where it is resolved" test -f "$HOME/.claude/$f"
  done

  tap_end
fi

# Read and validate stdin fully before emitting anything: piping jq straight into
# the selector printed the always-on pair even for input that was not a fetch
# blob at all, so a broken step 1 looked like a PR that needed no guidelines.
paths=$(jq -r '.meta.files[].path' 2>/dev/null) || {
  echo "Expected gh-pr-fetch.sh JSON on stdin (.meta.files[].path)" >&2
  exit 1
}
printf '%s\n' "$paths" | select_guidelines
