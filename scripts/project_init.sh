#!/usr/bin/env bash
# project_init.sh — make a git repository a project the tooling can run in.
#
# A project keeps its own values, secrets, verbs and records. Claude Code keeps
# a project's sessions and memory under ~/.claude/projects/<slug>, so that
# folder is a link into the project's .claude-project-data/, and git versions
# its memory/ beside the project's code. This makes each piece that is missing
# and changes nothing already right, so a second run reports nothing to do:
#
#   .claude/                  the project layer, re-included by a repository
#                             that ignores everything it does not name
#   .claude/project           the marker that makes the folder a project,
#                             holding its name
#   .secrets/                 mode 700, ignored by git
#   .claude-project-data/     ignored by git, all but memory/
#   ~/.claude/projects/<slug> a link to <project>/.claude-project-data
#   .claude/config_dir        the account, with --account
#
# Every check runs before anything is made, so a refusal changes nothing.
#
#   0   made, or nothing to do
#   1   refused; stderr names what is in the way
#   2   usage
#
# Usage:
#   project_init.sh [--account <config dir>] [<dir>]   # <dir> defaults to $PWD
#   project_init.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

DATA=.claude-project-data

say()    { printf 'project_init: %s\n' "$*"; }
refuse() { printf 'project_init: %s\n' "$*" >&2; exit 1; }

slug_of() { printf '%s\n' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }  # <absolute dir>

link_of() { printf '%s\n' "$HOME/.claude/projects/$(slug_of "$1")"; }  # <dir>

ignored() { git -C "$1" check-ignore -q -- "$2"; }  # <dir> <path>

# ignore_wants <dir> — each .gitignore line the repository lacks, one per line.
# Ignoring the transcripts ignores memory/ too, so its exception comes with them;
# a repository that ignores the data folder itself re-includes it first.
ignore_wants() {
  ignored "$1" .claude/project && echo "!/.claude"
  ignored "$1" .secrets/probe || echo ".secrets/"
  if ignored "$1" "$DATA"; then printf '%s\n' "!/$DATA" "$DATA/*" "!$DATA/memory/"
  elif ! ignored "$1" "$DATA/probe.jsonl"; then printf '%s\n' "$DATA/*" "!$DATA/memory/"
  elif ignored "$1" "$DATA/memory/probe.md"; then echo "!$DATA/memory/"; fi
}

# undo_ignores <dir> <size> — put .gitignore back to its first <size> bytes,
# or remove it when it did not exist.
undo_ignores() {
  if [[ "$2" == none ]]; then rm -f "$1/.gitignore"; else truncate -s "$2" "$1/.gitignore"; fi
}

# check_link <dir> — refuse unless the link is absent or already points home.
check_link() {
  local link target="$1/$DATA"
  link=$(link_of "$1")
  if [[ -e "$link" || -L "$link" ]] && [[ "$(readlink "$link")" != "$target" ]]; then
    refuse "$link is in the way: move its contents into $target, then remove it"
  fi
}

# check_account <dir> <account> — refuse a config_dir naming another account.
check_account() {
  local f="$1/.claude/config_dir"
  if [[ -n "$2" && -e "$f" && "$(cat "$f")" != "$2" ]]; then refuse "$f names $(cat "$f"), not $2"; fi
}

make_dirs() {  # <dir>
  [[ -d "$1/.claude" ]] || { mkdir "$1/.claude" && say "made .claude/"; }
  [[ -d "$1/.secrets" ]] || { mkdir -m 700 "$1/.secrets" && say "made .secrets/"; }
  [[ -d "$1/$DATA/memory" ]] || { mkdir -p "$1/$DATA/memory" && say "made $DATA/memory/"; }
}

# make_ignores <dir> — the lines are added, then checked; a rule that still
# overrides them puts .gitignore back and refuses, so the refusal changes nothing.
make_ignores() {
  local -a wants
  local size=none
  mapfile -t wants < <(ignore_wants "$1")
  [[ "${#wants[@]}" -eq 0 ]] && return 0
  [[ -e "$1/.gitignore" ]] && size=$(stat -c %s "$1/.gitignore")
  printf '%s\n' "${wants[@]}" >> "$1/.gitignore"
  [[ -z "$(ignore_wants "$1")" ]] || { undo_ignores "$1" "$size"
    refuse "$1/.gitignore has a rule the added lines cannot override: ${wants[*]}"; }
  say "added to .gitignore: ${wants[*]}"
}

make_marker() {  # <dir>
  [[ -e "$1/.claude/project" ]] && return 0
  basename "$1" > "$1/.claude/project" && say "wrote .claude/project: $(basename "$1")"
}

make_link() {  # <dir>
  local link
  link=$(link_of "$1")
  [[ -L "$link" ]] && return 0
  mkdir -p "$(dirname "$link")" && ln -s "$1/$DATA" "$link" && say "linked $link"
}

make_account() {  # <dir> <account>
  [[ -z "$2" || -e "$1/.claude/config_dir" ]] && return 0
  printf '%s\n' "$2" > "$1/.claude/config_dir" && say "wrote .claude/config_dir: $2"
}

init() {  # <dir> <account>
  local dir=$1 out
  git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 \
    || refuse "$dir is no git repository, so nothing would version its memory; run git init first"
  check_link "$dir"; check_account "$dir" "$2"
  out=$(make_ignores "$dir" && make_dirs "$dir" && make_marker "$dir" && make_link "$dir" && make_account "$dir" "$2") || exit 1
  [[ -n "$out" ]] && printf '%s\n' "$out" || say "nothing to do in $dir"
}

if [[ "${1:-}" == --self-test ]]; then
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")"
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  run() { HOME="$fx/home" "$self" "$@" 2>&1; }  # <args…>
  mkdir -p "$fx/home" "$fx/p" "$fx/bare" "$fx/w"; git init -q "$fx/p"; git init -q "$fx/w"
  link="$fx/home/.claude/projects/$(slug_of "$fx/p")"
  tap_is "a folder's slug is its path with every other character a dash" "$(slug_of /a/b.c_d-e)" "-a-b-c-d-e"
  tap_is "a fresh repository is made a project" "$(run "$fx/p")" "$(printf 'project_init: %s\n' \
    "added to .gitignore: .secrets/ $DATA/* !$DATA/memory/" "made .claude/" "made .secrets/" \
    "made $DATA/memory/" "wrote .claude/project: p" "linked $link")"
  tap_is "the marker names the project" "$(cat "$fx/p/.claude/project")" p
  tap_is "its memory link points into the project" "$(readlink -f "$link")" "$fx/p/$DATA"
  tap_is ".secrets/ is private" "$(stat -c %a "$fx/p/.secrets")" 700
  tap_run "a secret is ignored by git" git -C "$fx/p" check-ignore -q .secrets/token
  tap_run "a transcript is ignored by git" git -C "$fx/p" check-ignore -q "$DATA/s.jsonl"
  tap_fails "a memory fact is versioned" git -C "$fx/p" check-ignore -q "$DATA/memory/fact.md"
  tap_is "a second run reports nothing to do" "$(run "$fx/p")" "project_init: nothing to do in $fx/p"
  tap_is "it exits 0" "$(run "$fx/p" >/dev/null; echo $?)" 0
  tap_like "an account is written" "$(run --account /a/.claude-x "$fx/p")" "*wrote .claude/config_dir: /a/.claude-x"
  tap_like "another account is refused" "$(run --account /a/.claude-y "$fx/p")" "*names /a/.claude-x, not /a/.claude-y"
  tap_is "and exits 1" "$(run --account /a/.claude-y "$fx/p" >/dev/null; echo $?)" 1
  tap_is "an account alone runs in the current folder" "$(cd "$fx/p" && run --account /a/.claude-x)" \
    "project_init: nothing to do in $fx/p"
  mv "$link" "$fx/aside"; ln -s "$fx/elsewhere" "$link"
  tap_like "a link pointing elsewhere is refused" "$(run "$fx/p")" "*is in the way*"
  rm "$link"; mv "$fx/aside" "$link"
  tap_like "a folder outside git is refused" "$(run "$fx/bare")" "*is no git repository*"
  tap_is "and nothing is made there" "$(find "$fx/bare" -mindepth 1 | wc -l)" 0
  mkdir -p "$fx/home/.claude/projects/$(slug_of "$fx/w")"
  tap_like "a real folder at the link is refused, named" "$(run "$fx/w")" "*$(slug_of "$fx/w") is in the way*"
  tap_is "and nothing is made in the project" "$(find "$fx/w" -mindepth 1 -maxdepth 1 ! -name .git | wc -l)" 0
  printf '/*\n!.gitignore\n' > "$fx/w/.gitignore"; rmdir "$fx/home/.claude/projects/$(slug_of "$fx/w")"
  mkdir -p "$fx/w/$DATA/memory"; echo '*' > "$fx/w/$DATA/memory/.gitignore"
  tap_like "an ignore rule that hides memory is refused" "$(run "$fx/w")" "*has a rule the added lines cannot override*"
  tap_is "and .gitignore is put back" "$(cat "$fx/w/.gitignore")" $'/*\n!.gitignore'
  rm -r "$fx/w/$DATA"
  tap_like "a repository ignoring all it does not name re-includes the layer and the data" "$(run "$fx/w")" \
    "*added to .gitignore: !/.claude !/$DATA $DATA/* !$DATA/memory/*"
  tap_fails "and versions the marker" git -C "$fx/w" check-ignore -q .claude/project
  tap_run "and ignores a transcript" git -C "$fx/w" check-ignore -q "$DATA/s.jsonl"
  tap_fails "and versions a memory fact" git -C "$fx/w" check-ignore -q "$DATA/memory/fact.md"
  mkdir "$fx/n"; echo x > "$fx/n/.gitignore"
  undo_ignores "$fx/n" none; tap_is "a .gitignore the run made is removed on undo" "$(find "$fx/n" -mindepth 1)" ""
  tap_is "a usage error exits 2" "$(run --account 2>/dev/null >/dev/null; echo $?)" 2
  tap_end
fi

account=""
[[ "${1:-}" == --account ]] && { [[ $# -ge 2 && -n "$2" ]] || { echo "Usage: project_init.sh [--account <config dir>] [<dir>]" >&2; exit 2; }; account=$2; shift 2; }
[[ $# -le 1 ]] || { echo "Usage: project_init.sh [--account <config dir>] [<dir>]" >&2; exit 2; }
dir=$(cd "${1:-$PWD}" 2>/dev/null && pwd -P) || refuse "no folder ${1:-$PWD}"
init "$dir" "$account"
