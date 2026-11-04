#!/usr/bin/env bash
# Export the publishable part of ~/.claude into a clone of the public dotclaude
# repo, and commit it there. ~/.claude stays local-only: its history, session
# histories and memory never leave it.
#
# Usage:
#   dotclaude_export.sh [-m "<message>"] <target-clone>
#   dotclaude_export.sh --self-test
#
# The copy is the allowlist below as committed at the source's HEAD, read with
# `git archive`, so another session's uncommitted work is never exported. It
# holds what only the public repo has too: index.html, the page GitHub Pages
# serves, README.md, LICENSE, and .github, the workflow that runs the
# self-tests on every push and publishes the page with what they printed. The
# target must be clean, so a refusal can restore it exactly. It keeps only its
# .git and .claude, the clone's own session history, which the clone's
# .git/info/exclude ignores, so it is never read and never published; every
# other file is replaced by the copy, so a file removed from the source is
# removed from the target too.
#
# The copy is refused, and nothing is committed, when any of these hit:
#   - a line of the denylist: one extended regex per line, matched without
#     case. It lives in the source as dotclaude_denylist.txt and is not on the
#     allowlist, because it names exactly what must not be published.
#   - a token shape: GitHub, Slack, AWS, Google OAuth, Anthropic keys, or a
#     private key block. AWS's documented example key is a fixture and passes.
#   - an email address outside the example domains, the top-level domains
#     reserved for examples (.example, .invalid, .test, .localhost) and the
#     commit trailer's.
#   - a binary file, which the checks above read as text and cannot see into.
# A hit is reported as path:line and its reason, never the line, since the hit
# may be the secret itself. The copy's own `scripts/selftest.sh --copy` must
# then pass on it. The page's claims are judged by the reader's browser alone.
#
# The commit message names the source commit. This script never pushes.
#
# DOTCLAUDE_SRC overrides the source repo (default ~/.claude).
# Exit 0 committed or nothing to commit, 1 refused, 2 usage.
set -uo pipefail

ALLOW=(CLAUDE.md credo.md '*_guidelines.md' statusline.sh settings.json skills scripts
       index.html README.md LICENSE .github)
KEEP=(.git .claude)
TOKENS='gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|GOCSPX-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
TOKEN_OK=AKIAIOSFODNN7EXAMPLE  # AWS's documented example key, used as a fixture
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
EMAIL_OK='@(example\.(com|org|net)|test\.com|([A-Za-z0-9-]+\.)*(example|invalid|test|localhost))$|^git@github\.com$|^noreply@anthropic\.com$'

die()   { echo "dotclaude_export.sh: $*" >&2; exit 1; }
usage() { echo "usage: dotclaude_export.sh [-m <message>] <target-clone>" >&2; exit 2; }

# files <dir> — every file `git add -A` would leave in the commit, as a path
# under <dir>: tracked or untracked, never ignored. The scan reads exactly
# these, so the clone's own ignored .claude is never read and never refuses,
# and a kept README or a new file the clone forgot to ignore is still read.
files() { git -C "$1" ls-files -co --exclude-standard | sed "s|^|$1/|"; }

# report <dir> <reason> <grep flags>… — print each matching line as
# path:line [reason], never the line itself, since a hit may be a secret.
# Status 1 on any hit. Each file is grepped alone, so a colon in a path such as
# skills/review:bot cannot be mistaken for the line-number separator.
report() {
  local dir=$1 reason=$2 hit=0 f n; shift 2
  while IFS= read -r f; do
    while IFS= read -r n; do
      printf '%s:%s [%s]\n' "${f#"$dir/"}" "$n" "$reason"; hit=1
    done < <(grep -nI "$@" "$f" | cut -d: -f1)
  done < <(files "$dir" | xargs -r -d '\n' grep -slI "$@")
  return "$hit"
}

# scan <dir> <denylist> — print every hit as path:line [reason]; status 1 on any.
scan() {
  local dir=$1 deny=$2 hits=0 re f n e
  # A NUL byte is what grep takes for binary, and binary is what -I skips.
  while IFS= read -r f; do
    printf '%s [binary]\n' "${f#"$dir/"}"; hits=1
  done < <(files "$dir" | xargs -r -d '\n' grep -slaP '\x00')
  if [[ -s "$deny" ]]; then
    while IFS= read -r re; do
      [[ -z "$re" || "$re" == \#* ]] && continue
      report "$dir" denylist -iE -e "$re" || hits=1
    done < "$deny"
  fi
  while IFS= read -r f; do
    while IFS=: read -r n e; do
      [[ "$e" == "$TOKEN_OK" ]] && continue
      printf '%s:%s [token shape]\n' "${f#"$dir/"}" "$n"; hits=1
    done < <(grep -noIE -e "$TOKENS" "$f")
  done < <(files "$dir" | xargs -r -d '\n' grep -slIE -e "$TOKENS")
  while IFS= read -r f; do
    while IFS=: read -r n e; do
      grep -qE "$EMAIL_OK" <<<"$e" && continue
      printf '%s:%s [email]\n' "${f#"$dir/"}" "$n"; hits=1
    done < <(grep -noIE -e "$EMAIL" "$f")
  done < <(files "$dir" | xargs -r -d '\n' grep -slIE -e "$EMAIL")
  return "$hits"
}

# refuse <target> <reason> — put the clean target back as it was, index
# included, then exit 1.
refuse() {
  git -C "$1" reset -q --hard; git -C "$1" clean -qfd
  die "refused: $2; the target is restored"
}

export_to() {  # <src> <target> <message>
  local src=$1 dst=$2 msg=$3 sha k f
  git -C "$src" rev-parse --verify -q HEAD >/dev/null || die "$src is not a git repo with a commit"
  git -C "$dst" rev-parse --git-dir >/dev/null 2>&1 || die "$dst is not a git clone"
  [[ "$(git -C "$dst" rev-parse --show-toplevel)" == "$(realpath "$dst")" ]] || die "$dst is not the root of its clone"
  [[ -z "$(git -C "$dst" status --porcelain)" ]] || die "$dst has uncommitted changes; commit or remove them first"
  sha=$(git -C "$src" rev-parse --short HEAD)

  for f in "$dst"/* "$dst"/.[!.]*; do
    [[ -e "$f" ]] || continue
    for k in "${KEEP[@]}"; do [[ "$(basename "$f")" == "$k" ]] && continue 2; done
    rm -rf -- "$f"
  done
  git -C "$src" archive HEAD -- "${ALLOW[@]}" | tar -x -C "$dst" || die "git archive of $src failed"

  scan "$dst" "$src/dotclaude_denylist.txt" >&2 || refuse "$dst" "the copy holds the hits above"
  [[ -x "$dst/scripts/selftest.sh" ]] || refuse "$dst" "the copy has no executable scripts/selftest.sh"
  # Staged before the selftest runs, so what the selftest leaves in the tree,
  # bytecode or a scratch file, is put back out and never committed.
  git -C "$dst" add -A
  "$dst/scripts/selftest.sh" --copy >/dev/null 2>&1 || refuse "$dst" "scripts/selftest.sh fails on the copy"
  git -C "$dst" checkout -q -- .; git -C "$dst" clean -qfd

  git -C "$dst" diff --cached --quiet && { echo "nothing to commit: the target matches $sha"; return 0; }
  git -C "$dst" commit -q -m "${msg:-Export from ~/.claude}" -m "Source commit: $sha" || die "commit failed"
  git -C "$dst" rev-parse --short HEAD
}

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local out head f
  FX=$(mktemp -d); trap 'rm -rf "$FX"' EXIT
  local fx=$FX
  g() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }

  mkdir -p "$fx/src/scripts" "$fx/src/skills/a" "$fx/src/commands" "$fx/src/projects"
  for f in credo.md statusline.sh settings.json commands/c.md; do echo "$f" > "$fx/src/$f"; done
  # It leaves bytecode behind, as a Python selftest does.
  printf '%s\n' '#!/usr/bin/env bash' 'mkdir -p "${0%/*}/__pycache__"; : > "${0%/*}/__pycache__/x.pyc"' \
    > "$fx/src/scripts/selftest.sh"
  chmod +x "$fx/src/scripts/selftest.sh"
  echo "rules" > "$fx/src/CLAUDE.md"; echo "go" > "$fx/src/go_coding_guidelines.md"
  echo "skill" > "$fx/src/skills/a/SKILL.md"; echo "private" > "$fx/src/projects/history.md"
  echo "secret-co" > "$fx/src/dotclaude_denylist.txt"
  echo "page" > "$fx/src/index.html"; echo "readme" > "$fx/src/README.md"; echo "mit" > "$fx/src/LICENSE"
  mkdir -p "$fx/src/.github/workflows"; echo "on: push" > "$fx/src/.github/workflows/selftest.yml"
  g "$fx/src" init -q; g "$fx/src" add -A; g "$fx/src" commit -qm one
  g "$fx" init -q dst; echo "stale" > "$fx/dst/old.md"; echo "stale" > "$fx/dst/.gitignore"
  g "$fx/dst" add -A; g "$fx/dst" commit -qm init
  mkdir "$fx/dst/.claude"; echo "history" > "$fx/dst/.claude/session_history.md"
  echo ".claude/" >> "$fx/dst/.git/info/exclude"

  run() { (export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
           export_to "$fx/src" "$fx/dst" "$1") 2>&1; }

  out=$(run "first export") && tap_ok "a clean export succeeds" || tap_not_ok "a clean export succeeds" "$out"
  [[ -f "$fx/dst/CLAUDE.md" && -f "$fx/dst/go_coding_guidelines.md" && -f "$fx/dst/skills/a/SKILL.md" ]] && tap_ok "the allowlist is copied" || tap_not_ok "the allowlist is copied" "allowlist missing"
  [[ -f "$fx/dst/index.html" && -f "$fx/dst/README.md" && -f "$fx/dst/.github/workflows/selftest.yml" ]] \
    && tap_ok "the page, the README and the workflow are copied from the source" || tap_not_ok "the page, the README and the workflow are copied from the source" "public files missing"
  [[ ! -e "$fx/dst/projects" && ! -e "$fx/dst/dotclaude_denylist.txt" ]] && tap_ok "paths off the allowlist stay behind" || tap_not_ok "paths off the allowlist stay behind" "an unlisted path was exported"
  [[ ! -e "$fx/dst/old.md" && ! -e "$fx/dst/.gitignore" ]] && tap_ok "a file the source does not hold is removed, dotfiles too" || tap_not_ok "a file the source does not hold is removed, dotfiles too" "a stale file survived"
  [[ -f "$fx/dst/.claude/session_history.md" && -z "$(git -C "$fx/dst" ls-files .claude)" ]] \
    && tap_ok "the clone's ignored .claude is kept and not committed" || tap_not_ok "the clone's ignored .claude is kept and not committed" ".claude removed or committed"
  [[ -z "$(git -C "$fx/dst" ls-files scripts/__pycache__)" && -z "$(git -C "$fx/dst" status --porcelain)" ]] \
    && tap_ok "what the selftest leaves behind is neither committed nor left" || tap_not_ok "what the selftest leaves behind is neither committed nor left" "selftest leftovers reached the target"
  grep -q "Source commit: $(git -C "$fx/src" rev-parse --short HEAD)" <<<"$(g "$fx/dst" log -1 --format=%B)" && tap_ok "the commit names the source commit" || tap_not_ok "the commit names the source commit" "no source commit in message"

  out=$(run "again"); [[ "$out" == nothing\ to\ commit* ]] && tap_ok "a second export with no change commits nothing" || tap_not_ok "a second export with no change commits nothing" "rerun: $out"

  head=$(git -C "$fx/dst" rev-parse HEAD)
  expect_refusal() {  # <file> <content> <reason> <case, as it prints>
    mkdir -p "$(dirname "$fx/src/$1")"; echo "$2" > "$fx/src/$1"; g "$fx/src" add -A; g "$fx/src" commit -qm "$4"
    out=$(run "$4") && tap_not_ok "$4" "$4: it exported" || { grep -q "$3" <<<"$out" && tap_ok "$4" || tap_not_ok "$4" "$4: $out"; }
    [[ "$(git -C "$fx/dst" rev-parse HEAD)" == "$head" && -z "$(git -C "$fx/dst" status --porcelain)" ]] \
      && tap_ok "$4, and the target is left as it was" || tap_not_ok "$4, and the target is left as it was"
    g "$fx/src" rm -q "$1"; g "$fx/src" commit -qm "undo $4"
  }
  expect_refusal scripts/a.sh "works at Secret-Co" "scripts/a.sh:1 \[denylist\]" "a denylist name is refused"
  grep -q "Secret-Co" <<<"$out" && tap_not_ok "a denylist hit prints its place, not its line" || tap_ok "a denylist hit prints its place, not its line"
  expect_refusal "skills/review:bot/x.md" $'one\nsecret-co' "skills/review:bot/x.md:2 \[denylist\]" "a hit in a path with a colon is refused"
  tok="ghp_$(printf 'a%.0s' {1..36})"
  expect_refusal scripts/b.sh "t=$tok" "scripts/b.sh:1 \[token shape\]" "a GitHub token is refused"
  grep -q "$tok" <<<"$out" && tap_not_ok "a token hit never prints the token" || tap_ok "a token hit never prints the token"
  expect_refusal scripts/c.sh "mail me@realmail$(printf .)org" "scripts/c.sh:1 \[email\]" "a real email is refused"
  grep -q "realmail" <<<"$out" && tap_not_ok "an email hit never prints the address" || tap_ok "an email hit never prints the address"
  echo "fixtures use alice@example.com, ssh://git@gh.example and AKIAIOSFODNN7EXAMPLE" > "$fx/src/scripts/d.sh"; g "$fx/src" add -A; g "$fx/src" commit -qm d
  printf 'a\0b' > "$fx/src/scripts/e.bin"; g "$fx/src" add -A; g "$fx/src" commit -qm bin
  out=$(run "binary") && tap_not_ok "a binary file is refused" "a binary file exported" || { grep -q "scripts/e.bin \[binary\]" <<<"$out" && tap_ok "a binary file is refused" || tap_not_ok "a binary file is refused" "binary: $out"; }
  g "$fx/src" rm -q scripts/e.bin; g "$fx/src" commit -qm "undo bin"
  out=$(run "example email") && tap_ok "an example domain, a reserved TLD and AWS's example key pass" || tap_not_ok "an example domain, a reserved TLD and AWS's example key pass" "examples refused: $out"
  echo "secret-co" >> "$fx/dst/.claude/session_history.md"
  out=$(run "ignored hit") && tap_ok "a hit in the clone's ignored .claude is never read" || tap_not_ok "a hit in the clone's ignored .claude is never read" "ignored .claude refused: $out"
  echo "draft" > "$fx/dst/NOTES.md"; echo "edited" >> "$fx/dst/README.md"
  out=$(run "dirty") && tap_not_ok "a dirty target is refused" "a dirty target was exported into" || { grep -q "uncommitted changes" <<<"$out" && tap_ok "a dirty target is refused" || tap_not_ok "a dirty target is refused" "dirty: $out"; }
  [[ -f "$fx/dst/NOTES.md" && "$(tail -1 "$fx/dst/README.md")" == edited ]] && tap_ok "and its uncommitted work is untouched" || tap_not_ok "and its uncommitted work is untouched" "dirty: work lost"
  rm "$fx/dst/NOTES.md"; g "$fx/dst" checkout -q -- README.md

  printf '#!/usr/bin/env bash\nexit 1\n' > "$fx/src/scripts/selftest.sh"; g "$fx/src" commit -qam red
  head=$(git -C "$fx/dst" rev-parse HEAD)
  out=$(run "red") && tap_not_ok "a failing selftest is refused" "a failing selftest exported" || { grep -q "selftest.sh fails" <<<"$out" && tap_ok "a failing selftest is refused" || tap_not_ok "a failing selftest is refused" "red: $out"; }
  [[ "$(git -C "$fx/dst" rev-parse HEAD)" == "$head" ]] && tap_ok "a failing selftest commits nothing" || tap_not_ok "a failing selftest commits nothing"
  [[ -z "$(git -C "$fx/dst" status --porcelain)" ]] && tap_ok "a refusal after staging leaves nothing staged" || tap_not_ok "a refusal after staging leaves nothing staged" "red: the copy is left staged"
}

[[ "${1:-}" == "--self-test" ]] && { self_test; tap_end; }
msg=""
while getopts "m:" o; do case $o in m) msg=$OPTARG ;; *) usage ;; esac; done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || usage
export_to "${DOTCLAUDE_SRC:-$HOME/.claude}" "$1" "$msg"
