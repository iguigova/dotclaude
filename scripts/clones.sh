#!/usr/bin/env bash
# clones.sh — list, report and fetch the git repositories a project works in.
#
# A project lists its clones in .claude/clones, which `project_file.sh
# --clones` reads; the project is the one $PWD lies in.
#
#   (none)       report each clone through dev_setup.sh, which fetches first;
#                --dry-run reports from local refs. A clone that is missing,
#                or whose origin is not its listed remote, is named.
#   --add <path> [<name>]
#                list the repository whose folder is <path>, below the
#                project, as <name> (its folder's name by default) with its
#                path from the project's folder and its origin. A name listed
#                for another line is refused; the same line changes nothing.
#   --sync       clone each missing clone from its remote.
#
#   0   ready, listed, or synced
#   1   a clone needs a decision, is missing or is not its remote, or a
#       clone or an add was refused; the report or stderr names it
#   2   usage
#
# Usage:
#   clones.sh [--dry-run]
#   clones.sh --add <path> [<name>]
#   clones.sh --sync
#   clones.sh --self-test
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$SELF_DIR/project_file.sh"
NAME_RE='^[A-Za-z0-9._-]+$'

say()    { printf 'clones: %s\n' "$*"; }
refuse() { printf 'clones: %s\n' "$*" >&2; exit 1; }
usage()  { echo "Usage: clones.sh [--dry-run] | --add <path> [<name>] | --sync | --self-test" >&2; exit 2; }

# listed — the manifest's clones, or nothing when the project has no manifest.
listed() {  # <project>
  [[ -e "$1/.claude/clones" ]] || return 0
  "$PF" --clones
}

# repo_folder — <dir> is the top folder of a git repository.
repo_folder() {  # <dir>
  [[ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$1" && pwd -P)" ]]
}

# clone_at — <dir>\t<path from the project>\t<origin> of the repository at <path>.
clone_at() {  # <project> <path>
  local dir rel remote
  dir=$(cd "$2" 2>/dev/null && pwd) || refuse "no folder $2"
  rel=${dir#"$1"/}
  [[ "$rel" != "$dir" ]] || refuse "$dir is not below the project $1"
  repo_folder "$dir" || refuse "$dir is no git repository's folder"
  remote=$(git -C "$dir" remote get-url origin 2>/dev/null) || refuse "$dir has no origin"
  printf '%s\t%s\t%s\n' "$dir" "$rel" "$remote"
}

add_clone() {  # <path> [<name>]
  local r found dir rel remote name all have
  r=$("$PF" --root) && found=$(clone_at "$r" "$1") || exit 1
  IFS=$'\t' read -r dir rel remote <<<"$found"
  name=${2:-$(basename "$rel")}
  [[ "$name" =~ $NAME_RE ]] || refuse "a clone's name is letters, digits, dots, dashes and underscores: $name"
  all=$(listed "$r") || exit 1
  have=$(awk -F'\t' -v n="$name" '$1 == n' <<<"$all")
  [[ "$have" == "$name"$'\t'"$dir"$'\t'"$remote" ]] && { say "already listed: $name $rel $remote"; return 0; }
  [[ -z "$have" ]] || refuse "$r/.claude/clones lists $name already, as ${have//$'\t'/ }"
  printf '%s %s %s\n' "$name" "$rel" "$remote" >> "$r/.claude/clones" && say "listed: $name $rel $remote"
}

report() {  # [--dry-run]
  local all name dir remote st=0
  all=$("$PF" --clones) || exit 1
  while IFS=$'\t' read -r -u 3 name dir remote; do
    echo "== $name"
    if [[ ! -d "$dir" ]]; then echo "missing: $dir; clones.sh --sync clones it"; st=1; continue; fi
    "$PF" --clone "$name" >/dev/null || { st=1; continue; }
    "$("$PF" --script dev_setup.sh)" "$dir" "$@" || st=1
  done 3<<<"$all"
  return "$st"
}

sync_clones() {
  local all name dir remote st=0
  all=$("$PF" --clones) || exit 1
  while IFS=$'\t' read -r -u 3 name dir remote; do
    if [[ -d "$dir" ]]; then "$PF" --clone "$name" >/dev/null || st=1; continue; fi
    if git clone --quiet "$remote" "$dir" </dev/null; then say "cloned $name into $dir"
    else echo "clones: cloning $name from $remote failed" >&2; st=1; fi
  done 3<<<"$all"
  return "$st"
}

if [[ "${1:-}" == --self-test ]]; then
  # shellcheck source=tap.sh
  . "$SELF_DIR/tap.sh"
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  fx=$(cd "$fx" && pwd -P)
  self="$SELF_DIR/clones.sh"
  G=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main)
  in_p() { (cd "$fx/p" && "$self" "$@" 2>&1); }  # <args…>
  st_p() { (cd "$fx/p" && "$self" "$@" >/dev/null 2>&1; echo $?); }  # <args…>
  for n in a b; do
    git "${G[@]}" init -q "$fx/src-$n" && git "${G[@]}" -C "$fx/src-$n" commit -q --allow-empty -m one
    git clone -q --bare "$fx/src-$n" "$fx/$n.git"
  done
  tap_project "$fx/p"; mkdir -p "$fx/p/api/plain" "$fx/outside"
  git clone -q "$fx/a.git" "$fx/p/api/a"; git clone -q "$fx/b.git" "$fx/p/api/other"
  git "${G[@]}" init -q "$fx/p/api/bare"; git init -q "$fx/outside/repo"
  git -C "$fx/outside/repo" remote add origin "$fx/a.git"
  tap_is "a clone is listed by its folder's name, path and origin" "$(in_p --add api/a)" \
    "clones: listed: a api/a $fx/a.git"
  tap_is "the manifest holds its line" "$(cat "$fx/p/.claude/clones")" "a api/a $fx/a.git"
  tap_is "listing it again changes nothing" "$(in_p --add api/a; cat "$fx/p/.claude/clones")" \
    "clones: already listed: a api/a $fx/a.git"$'\n'"a api/a $fx/a.git"
  tap_is "and exits 0" "$(st_p --add api/a)" 0
  tap_like "a name listed for another line is refused" "$(in_p --add api/other a)" "*lists a already, as a $fx/p/api/a*"
  tap_like "a folder that is no repository is refused" "$(in_p --add api/plain)" "*no git repository's folder"
  tap_like "a repository with no origin is refused" "$(in_p --add api/bare)" "*has no origin"
  tap_like "a folder outside the project is refused" "$(in_p --add ../outside/repo)" "*is not below the project*"
  tap_like "a name with a space is refused" "$(in_p --add api/a 'a b')" "*a clone's name is*"
  tap_is "a refused add exits 1" "$(st_p --add api/plain)" 1
  tap_like "a clone ready to work is reported" "$(in_p --dry-run)" "== a*repo      $fx/p/api/a*ready"
  tap_is "and the report exits 0" "$(st_p --dry-run)" 0
  printf 'b api/b %s\n' "$fx/b.git" >> "$fx/p/.claude/clones"
  tap_like "a missing clone is named" "$(in_p --dry-run)" "*missing: $fx/p/api/b; clones.sh --sync clones it"
  tap_is "and the report of it exits 1" "$(st_p --dry-run)" 1
  tap_is "sync clones the missing one" "$(in_p --sync)" "clones: cloned b into $fx/p/api/b"
  tap_is "from its remote" "$(git -C "$fx/p/api/b" remote get-url origin)" "$fx/b.git"
  tap_is "a second sync has nothing to do" "$(in_p --sync; st_p --sync)" 0
  printf 'c api/c %s\n' "$fx/nonesuch.git" >> "$fx/p/.claude/clones"
  tap_like "a clone that cannot be cloned is named" "$(in_p --sync)" "*cloning c from $fx/nonesuch.git failed"
  tap_is "and that sync exits 1" "$(st_p --sync)" 1
  printf 'a api/a %s\nb api/a %s\n' "$fx/a.git" "$fx/b.git" > "$fx/p/.claude/clones"
  tap_like "a folder with another origin is named in the report" "$(in_p --dry-run)" "*is no clone of $fx/b.git*"
  tap_is "and the report exits 1" "$(st_p --dry-run)" 1
  tap_is "and sync exits 1" "$(st_p --sync)" 1
  tap_is "outside a project the report exits 1" "$(cd "$fx/outside" && "$self" >/dev/null 2>&1; echo $?)" 1
  tap_is "an add outside a project exits 1" "$(cd "$fx/outside" && "$self" --add repo >/dev/null 2>&1; echo $?)" 1
  tap_is "a sync outside a project exits 1" "$(cd "$fx/outside" && "$self" --sync >/dev/null 2>&1; echo $?)" 1
  tap_is "--add with no path is a usage error" "$(st_p --add)" 2
  tap_is "--sync takes no argument" "$(st_p --sync x)" 2
  tap_is "an unknown flag is a usage error" "$(st_p --nonesuch)" 2
  tap_end
fi

case "${1:-}" in
  --add)          [[ $# -ge 2 && $# -le 3 ]] || usage; add_clone "$2" "${3:-}" ;;
  --sync)         [[ $# -eq 1 ]] || usage; sync_clones ;;
  --dry-run|"")   [[ $# -le 1 ]] || usage; report "$@" ;;
  *)              usage ;;
esac
