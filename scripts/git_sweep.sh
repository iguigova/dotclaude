#!/usr/bin/env bash
# git_sweep.sh — remove the git state that is proven finished, and raise the
# rest as notes. Universal across projects, for clones whose origin is on
# GitHub: a PR is looked up with gh, so any other origin is a skip.
#
# Usage:
#   git_sweep.sh ROOT [--apply]
#   git_sweep.sh --self-test
#
# ROOT is scanned for clones down to CLONE_DEPTH levels. A clone is a
# repository with an origin: a local-only repository has no PR to prove a
# branch against, and is not scanned. A linked worktree's `.git` is a file,
# so only main clones are found. Without --apply nothing is
# changed and each line says what --apply would do. Output is one TSV line per
# item: verdict, clone, kind, name, reason.
#
# The layout it enforces: a clone's main checkout holds the work, and a clone
# has no linked worktrees. Every linked worktree is a note; one whose
# directory is gone is pruned.
#
# Verdicts:
#   delete  proven finished; --apply removes it
#   note    needs a person; --apply opens one note in the /notes queue,
#           unless an open note already carries its key
#   keep    live: an open PR; also a branch a linked worktree holds, whose
#           note is the tree's; also every branch of a clone whose origin
#           you cannot push to, such as a pinned SDK, which holds no work
#           of yours for a PR to prove
#   skip    could not be decided now (a PR or permission lookup failed);
#           nothing is done
#   close   an open sweep note whose item this run no longer notes: the item
#           is gone, kept or deleted; --apply closes the note `-`. Only a
#           note whose clone this run scanned is judged.
#
# A branch's PRs are those whose head is that branch in the origin's own
# owner. `gh pr list --head` matches the branch name in every fork, so a
# stranger's closed PR from a fork branch named `stable` is not this branch's.
#
# A branch is proven finished when its tip equals or precedes the head commit
# of a merged PR, no linked worktree holds it, and no stash names it. When it
# is the main checkout's branch, that tree must also be clean, and --apply
# switches it to the default branch, fast-forwarded to origin, before the
# delete. Nothing is lost, because every commit on the branch is in the
# merged PR. The tree is checked again at the moment of the switch, so one
# dirtied since the proof is left alone.
#
# Ancestry to the default branch is not the test: a squash or rebase merge
# writes new commits, so a finished branch is never an ancestor of it. The
# deletion is a compare-and-delete on the tip that was proven, so a commit
# landing between the proof and the delete makes it fail instead of losing
# that commit.
#
# --apply journals what it removed and the notes it opened and closed in one entry,
# through journal.sh, in the history nearest ROOT. It refuses to start when
# there is no such history, because a deletion must not go unrecorded.
#
# Environment (the self-test sets these):
#   GIT_SWEEP_GH           the gh command (default: gh)
#   JOURNAL_HIST           passed through to journal.sh
#
# Exit: 0 done; 1 an item was skipped or an action failed; 2 usage.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${GIT_SWEEP_GH:-gh}"
CLONE_DEPTH=4
TAB=$'\t'

# ---------------------------------------------------------------- git facts

clones() {  # <root> -> every main clone under root, sorted
  local c
  while IFS= read -r c; do
    git -C "$c" remote get-url origin >/dev/null 2>&1 && echo "$c"
  done < <(repos "$1")
}

repos() {  # <root> -> every main repository under root, sorted
  find "$1" -maxdepth "$CLONE_DEPTH" -name .git -type d -prune 2>/dev/null \
    | sed 's|/\.git$||' | sort
}

default_branch() {  # <clone> -> origin's default branch name
  local b
  b=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  [[ -n "$b" ]] && { echo "${b#origin/}"; return; }
  git -C "$1" ls-remote --symref origin HEAD 2>/dev/null \
    | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2 }'
}

origin_slug() {  # <clone> -> owner/repo
  git -C "$1" remote get-url origin 2>/dev/null \
    | sed -E 's#.*github\.com[:/]##; s#\.git$##'
}

branches() {  # <clone> -> "<branch>\t<tip>" for every local branch
  git -C "$1" for-each-ref --format="%(refname:short)${TAB}%(objectname)" \
    refs/heads
}

# The state, live or prunable, precedes the branch, which is empty for a
# detached tree: read collapses adjacent tabs, so an empty field must be last.
worktrees() {  # <clone> -> "<path>\t<state>\t<branch>" per linked tree
  git -C "$1" worktree list --porcelain | awk -v OFS="\t" '
    /^worktree /   { if (n++) print p, x, b; p = substr($0, 10); b = ""; x = "live" }
    /^branch /     { b = substr($0, 19) }
    /^prunable/    { x = "prunable" }
    END            { if (n) print p, x, b }' | tail -n +2
}

stashes() {  # <clone> -> "<sha>\t<selector>\t<date>\t<message>"
  git -C "$1" stash list --format="%H${TAB}%gd${TAB}%cs${TAB}%gs"
}

checked_out_in() {  # <clone> <branch> -> path of the tree holding it
  git -C "$1" worktree list --porcelain | awk -v want="branch refs/heads/$2" '
    /^worktree / { p = substr($0, 10) }
    $0 == want   { print p; exit }'
}

stash_names() {  # <clone> <branch> -> succeeds when a stash names the branch
  git -C "$1" stash list --format=%gs \
    | awk -v b="$2" 'index($0, "WIP on " b ":") == 1 \
                     || index($0, "On " b ":") == 1 { f = 1 } END { exit !f }'
}

has_object() {  # <clone> <sha>
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null
}

precedes() {  # <clone> <tip> <head> <pr> -> tip equals or precedes head
  [[ "$2" == "$3" ]] && return 0
  has_object "$1" "$3" \
    || git -C "$1" fetch --quiet origin "pull/$4/head" 2>/dev/null
  git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null
}

# `|| continue` rather than `&& printf`: a while loop exits with its last
# iteration's status, so a final fork row would fail the pipeline and read as
# a failed lookup.
pr_rows() {  # <clone> <branch> -> "<number>\t<state>\t<head>" per own PR
  local slug owner n state head who
  slug=$(origin_slug "$1"); owner=${slug%/*}
  "$GH" pr list -R "$slug" --head "$2" --state all \
    --json number,state,headRefOid,headRepositoryOwner \
    --jq '.[] | "\(.number)\t\(.state)\t\(.headRefOid)\t\(.headRepositoryOwner.login)"' \
  | while IFS="$TAB" read -r n state head who; do
      [[ "${who,,}" == "${owner,,}" ]] || continue
      printf '%s\t%s\t%s\n' "$n" "$state" "$head"
    done
}

# GitHub's permission names; only these three can push a branch.
pushable() {  # <clone> -> succeeds when you can push to origin
  local p
  p=$("$GH" repo view "$(origin_slug "$1")" --json viewerPermission \
        --jq .viewerPermission) || return 2
  [[ "$p" =~ ^(ADMIN|MAINTAIN|WRITE)$ ]]
}

current() {  # <clone> <branch> -> the main checkout is on branch
  [[ "$(git -C "$1" branch --show-current)" == "$2" ]]
}

clean() {  # <tree> -> nothing changed or untracked
  [[ -z "$(git -C "$1" status --porcelain --untracked-files=all)" ]]
}

# ---------------------------------------------------------------- classify
# Each record is "verdict\tclone\tkind\tname\treason\ttarget"; the target is
# what --apply acts on: a proven tip.

record() {  # <verdict> <clone> <kind> <name> <reason> [target]
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "${2#"$ROOT"/}" "$3" "$4" "$5" "${6:-}"
}

merged_blocker() {  # <clone> <branch> -> why a merged branch must stay
  stash_names "$1" "$2" && { echo "a stash names it"; return; }
  current "$1" "$2" && ! clean "$1" \
    && echo "it is checked out with uncommitted changes"
}

merged_verdict() {  # <clone> <branch> <pr> -> verdict\treason
  local blocker
  blocker=$(merged_blocker "$1" "$2")
  [[ -n "$blocker" ]] \
    && { printf 'note\tmerged in #%s, but %s\n' "$3" "$blocker"; return; }
  current "$1" "$2" || { printf 'delete\tmerged in #%s\n' "$3"; return; }
  printf 'delete\tmerged in #%s; checkout moves to %s\n' "$3" \
    "$(default_branch "$1")"
}

branch_verdict() {  # <clone> <branch> <tip> <pr rows> -> verdict\treason
  local c=$1 b=$2 tip=$3 rows=$4 n state head merged="" stale=""
  local closed=""
  while IFS="$TAB" read -r n state head; do
    [[ -n "$n" ]] || continue
    case "$state" in
      OPEN)   printf 'keep\topen PR #%s\n' "$n"; return ;;
      MERGED) if precedes "$c" "$tip" "$head" "$n"
              then merged=$n; else stale=$n; fi ;;
      CLOSED) closed=$n ;;
    esac
  done <<<"$rows"
  [[ -n "$merged" ]] && { merged_verdict "$c" "$b" "$merged"; return; }
  [[ -n "$stale" ]] && { printf 'note\tcommits after #%s merged\n' "$stale"; return; }
  [[ -n "$closed" ]] && { printf 'note\tPR #%s closed unmerged\n' "$closed"; return; }
  printf 'note\tno PR\n'
}

classify_branches() {  # <clone>
  local c=$1 def b tip rows v held push=0
  def=$(default_branch "$c")
  pushable "$c" 2>/dev/null || push=$?
  while IFS="$TAB" read -r b tip; do
    [[ "$b" == "$def" ]] && continue
    case "$push" in
      1) record keep "$c" branch "$b" "origin $(origin_slug "$c") is read-only to you"
         continue ;;
      2) record skip "$c" branch "$b" "permission lookup failed"; continue ;;
    esac
    held=$(checked_out_in "$c" "$b")
    if [[ -n "$held" && "$held" != "$c" ]]; then
      record keep "$c" branch "$b" "held by worktree $(basename "$held")"
      continue
    fi
    if ! rows=$(pr_rows "$c" "$b" 2>/dev/null); then
      record skip "$c" branch "$b" "PR lookup failed"; continue
    fi
    v=$(branch_verdict "$c" "$b" "$tip" "$rows")
    record "${v%%"$TAB"*}" "$c" branch "$b" "${v#*"$TAB"}" "$tip"
  done < <(branches "$c")
}

worktree_record() {  # <clone> <path> <state> <branch>
  local name
  name=$(basename "$2")
  [[ "$3" == prunable ]] \
    && { record delete "$1" worktree "$name" "directory missing"; return; }
  record note "$1" worktree "$name" "a linked worktree${4:+, holds $4}"
}

classify_worktrees() {  # <clone>
  local p x b
  while IFS="$TAB" read -r p x b; do
    worktree_record "$1" "$p" "$x" "$b"
  done < <(worktrees "$1")
}

classify_stashes() {  # <clone>
  local sha sel date msg
  while IFS="$TAB" read -r sha sel date msg; do
    record note "$1" stash "${sha:0:7}" "$sel from $date: $msg"
  done < <(stashes "$1")
}

classify() {  # every record under ROOT
  local c
  while IFS= read -r c; do
    classify_branches "$c"
    classify_worktrees "$c"
    classify_stashes "$c"
  done < <(clones "$ROOT")
}

# ---------------------------------------------------------------- apply

history_of() {  # <dir> -> the session history journal.sh would write
  local d
  [[ -n "${JOURNAL_HIST:-}" ]] && { echo "$JOURNAL_HIST"; return; }
  d=$(cd "$1" && pwd)
  while [[ "$d" != / ]]; do
    [[ -f "$d/.claude/session_history.md" ]] \
      && { echo "$d/.claude/session_history.md"; return; }
    d=$(dirname "$d")
  done
  return 1
}

leave_branch() {  # <clone> <branch> -> the main checkout is off branch
  local def
  current "$1" "$2" || return 0
  clean "$1" || return 1
  def=$(default_branch "$1")
  git -C "$1" switch --quiet "$def" 2>/dev/null || return 1
  fast_forward "$1" "$def"
}

fast_forward() {  # <clone> <default> -> the checkout matches origin
  git -C "$1" fetch --quiet origin "$2" 2>/dev/null \
    && git -C "$1" merge --quiet --ff-only "origin/$2" >/dev/null 2>&1 \
    || echo "git_sweep: ${1#"$ROOT"/} stays at its local $2;" \
            "it does not fast-forward to origin" >&2
  return 0
}

delete_branch() {  # <clone> <branch> <proven tip>
  leave_branch "$1" "$2" || return 1
  git -C "$1" update-ref -d "refs/heads/$2" "$3" 2>/dev/null || return 1
  git -C "$1" config --remove-section "branch.$2" 2>/dev/null
  return 0
}

prune_worktrees() {  # <clone>
  git -C "$1" worktree prune
}

note_key() {  # <clone> <kind> <name>
  printf 'sweep:%s/%s/%s' "$1" "$2" "$3"
}

note_text() {  # <clone> <kind> <name> <reason>
  local title="Sweep $2: $3"
  printf '%.60s — %s in %s: %s (%s)' "$title" "$2" "$1" "$4" \
    "$(note_key "$1" "$2" "$3")"
}

already_noted() {  # <key> <open queue>
  grep -qF -- "($1)" <<<"$2"
}

note_id_key() {  # <open queue> -> "<id>\t<key>" per open sweep note
  local id text
  while IFS="$TAB" read -r id _ _ _ text; do
    [[ "$text" == *" (sweep:"*")" ]] || continue
    text=${text##*" (sweep:"}
    printf '%s\tsweep:%s\n' "$id" "${text%)}"
  done <<<"$1"
}

# A sweep note is the sweep's own claim that an item needs a person, so the
# sweep withdraws it once its own check stops saying so: the item is gone,
# or it is now kept or deleted. Only a note whose clone this run scanned is
# judged; any other key (a clone removed, or one keyed under another ROOT)
# proves nothing and stays open. An item still noted, skipped or failed
# keeps its note.
stale_notes() {  # <outcome records> <open queue> -> close records
  local v c k n r id key rest kind
  local -A now=()
  local -a scanned=()
  while IFS="$TAB" read -r v c k n r; do
    [[ -n "$v" ]] && now[$(note_key "$c" "$k" "$n")]="$v$TAB$r"
  done <<<"$1"
  while IFS= read -r c; do scanned+=("${c#"$ROOT"/}"); done < <(clones "$ROOT")
  while IFS="$TAB" read -r id key; do
    [[ -n "$id" ]] || continue
    for c in "${scanned[@]}"; do
      rest=${key#"sweep:$c/"}
      [[ "$rest" != "$key" ]] || continue
      kind=${rest%%/*}
      [[ "$kind" =~ ^(branch|worktree|stash)$ ]] || continue
      v=${now[$key]:-}
      case "${v%%"$TAB"*}" in
        "")                r="no longer in $c" ;;
        keep|delete|deleted) r="${v%%"$TAB"*}: ${v#*"$TAB"}" ;;
        *)                 continue 2 ;;
      esac
      printf 'close\t%s\t%s\t%s\tnote %s: %s\n' "$c" "$kind" "${rest#*/}" "$id" "$r"
      continue 2
    done
  done < <(note_id_key "$2")
}

act() {  # <verdict> <clone> <kind> <name> <target> -> outcome
  case "$1:$3" in
    delete:branch)   delete_branch "$ROOT/$2" "$4" "$5" \
                       && echo deleted || echo failed ;;
    delete:worktree) prune_worktrees "$ROOT/$2" \
                       && echo deleted || echo failed ;;
    *)               echo "$1" ;;
  esac
}

open_queue() {
  (cd "$ROOT" && "$SCRIPTS_DIR/journal_queue.sh" 2>/dev/null)
}

apply() {  # <records> -> outcome records, and one journal entry
  local queue v c k n r t out outcomes="" stale id closed=0
  local -a bullets=() notes=() closes=()
  queue=$(open_queue)
  while IFS="$TAB" read -r v c k n r t; do
    [[ -n "$v" ]] || continue
    out=$(act "$v" "$c" "$k" "$n" "$t")
    if [[ "$out" == note ]]; then
      if already_noted "$(note_key "$c" "$k" "$n")" "$queue"
      then out=noted-before
      else out=noted; notes+=(-n "$(note_text "$c" "$k" "$n" "$r")"); fi
    fi
    [[ "$out" == deleted ]] && bullets+=(-b "Deleted $k $n in $c: $r")
    outcomes+=$(printf '%s\t%s\t%s\t%s\t%s' "$out" "$c" "$k" "$n" "$r")$'\n'
  done <<<"$1"
  stale=$(stale_notes "$outcomes" "$queue")
  while IFS="$TAB" read -r v c k n r; do
    [[ -n "$v" ]] || continue
    id=${r#note }; id=${id%%:*}
    closes+=(--placed "$id: - — ${r#*: }"); closed=$((closed + 1))
    outcomes+=$(printf 'closed\t%s\t%s\t%s\t%s' "$c" "$k" "$n" "$r")$'\n'
  done <<<"$stale"
  printf '%s' "$outcomes"
  (( ${#bullets[@]} + ${#notes[@]} + ${#closes[@]} )) || return 0
  (( ${#bullets[@]} )) || bullets=(-b "Deleted nothing; opened ${#notes[@]} notes, closed $closed")
  (cd "$ROOT" && "$SCRIPTS_DIR/journal.sh" -t "chore: git sweep" \
     "${bullets[@]}" "${notes[@]}" "${closes[@]}" >&2)
}

# ---------------------------------------------------------------- main

usage() {
  sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 2
}

parse_args() {
  ROOT="" APPLY=0
  while (( $# )); do
    case "$1" in
      --apply)        APPLY=1 ;;
      -h|--help)      usage ;;
      -*)             echo "git_sweep: unknown option $1" >&2; exit 2 ;;
      *)              ROOT=$1 ;;
    esac
    shift
  done
  [[ -d "$ROOT" ]] || { echo "git_sweep: ROOT is not a directory" >&2; exit 2; }
  ROOT=$(cd "$ROOT" && pwd)
}

main() {
  local records out
  parse_args "$@"
  if (( APPLY )) && ! history_of "$ROOT" >/dev/null; then
    echo "git_sweep: no session history at or above $ROOT; refusing" >&2
    exit 2
  fi
  records=$(classify)
  if (( APPLY )); then out=$(apply "$records")
  else
    out=$(cut -f1-5 <<<"$records")
    out+=$'\n'$(stale_notes "$records" "$(open_queue)")
    out=$(grep -v '^$' <<<"$out")
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out"
  ! grep -qE '^(skip|failed)\b' <<<"$out"
}

# ---------------------------------------------------------------- self-test

self_test() {
  local tmp fail=0 out
  tmp=$(mktemp -d) || return 2
  trap 'rm -rf "$tmp"' RETURN
  local -a G=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false)
  g() { git "${G[@]}" -C "$r" "$@" >/dev/null 2>&1; }
  commit() { echo "$1" >"$r/$1"; g add -A; g commit -m "$1"; }
  tip() { git -C "$r" rev-parse "$1"; }
  # A row's head owner is the test origin's own, "$tmp"; `fork` writes a row
  # whose head is in someone else's fork.
  fixture() {
    if [[ "$2" == FAIL ]]; then echo FAIL >"$tmp/prs/$1"
    else printf '%s\t%s\n' "$2" "$tmp" >"$tmp/prs/$1"; fi
  }
  fork() { printf '%s\tstranger\n' "$2" >"$tmp/prs/$1"; }
  expect() {  # <description> <ERE over the output>
    if grep -qE -- "$2" <<<"$out"; then echo "  ok  $1"
    else echo "  FAIL $1: no line matches /$2/"; fail=1; fi
  }
  check() {  # <description> <command…>
    if "${@:2}" >/dev/null 2>&1; then echo "  ok  $1"
    else echo "  FAIL $1"; fail=1; fi
  }

  echo "== git_sweep self-test =="
  mkdir -p "$tmp/root/.claude" "$tmp/prs"
  : >"$tmp/root/.claude/session_history.md"
  git init -q -b main "$tmp/root"
  git "${G[@]}" -C "$tmp/root" commit -q --allow-empty -m local
  git -C "$tmp/root" branch stray
  cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "repo view" ]]; then
  p="$GIT_SWEEP_PRS/perm_${3##*/}"
  [[ -f "$p" ]] && cat "$p" || echo WRITE
  exit 0
fi
while (( $# )); do [[ "$1" == --head ]] && h=$2; shift; done
f="$GIT_SWEEP_PRS/${h//\//_}"
[[ -f "$f" ]] || exit 0
[[ "$(cat "$f")" == FAIL ]] && exit 1
cat "$f"
EOF
  chmod +x "$tmp/gh"

  git "${G[@]}" -c init.defaultBranch=main init --bare -q "$tmp/remote.git"
  git "${G[@]}" clone -q "$tmp/remote.git" "$tmp/root/repo" 2>/dev/null
  local r="$tmp/root/repo"
  g checkout -b main; commit base; g push -u origin main
  g remote set-head origin main

  # squashed: merged by squash, so never an ancestor of main
  g checkout -b squashed main; commit s1
  fixture squashed "7${TAB}MERGED${TAB}$(tip squashed)"
  g checkout main; commit s1-squash; g push origin main
  # behind: the PR gained a commit after the local tip
  g checkout -b behind main; commit b1; g checkout -b tmp; commit b2
  fixture behind "8${TAB}MERGED${TAB}$(tip tmp)"
  g checkout main; g branch -D tmp
  # after: a local commit made after the merged head
  g checkout -b after main; commit a1
  fixture after "9${TAB}MERGED${TAB}$(tip after)"
  commit a2
  g checkout -b open main; commit o1; fixture open "10${TAB}OPEN${TAB}x"
  g checkout -b nopr main; commit n1
  g checkout -b closed main; commit c1
  fixture closed "11${TAB}CLOSED${TAB}$(tip closed)"
  # forked: the only PR with this head name is from a stranger's fork
  g checkout -b forked main; commit k1
  fork forked "16${TAB}CLOSED${TAB}$(tip forked)"
  g checkout -b feat/slash main; commit f1; fixture feat_slash FAIL
  g checkout -b stashed main; commit st1
  fixture stashed "12${TAB}MERGED${TAB}$(tip stashed)"
  g checkout main
  echo dirty >>"$r/base"
  g stash store -m "On stashed: wip" "$(git -C "$r" stash create)"
  g checkout -- base
  g checkout -b current main; commit cu1
  fixture current "13${TAB}MERGED${TAB}$(tip current)"
  # repo2: a merged branch checked out in a tree with uncommitted changes
  git "${G[@]}" clone -q "$tmp/remote.git" "$tmp/root/repo2" 2>/dev/null
  r="$tmp/root/repo2"
  g remote set-head origin main; g checkout -b dirtied main; commit d1
  fixture dirtied "14${TAB}MERGED${TAB}$(tip dirtied)"
  echo x >"$r/untracked"
  # sdk: a clone of a repository you can only read, on a non-default branch
  git "${G[@]}" -c init.defaultBranch=main init --bare -q "$tmp/upstream.git"
  git "${G[@]}" clone -q "$tmp/upstream.git" "$tmp/root/sdk" 2>/dev/null
  r="$tmp/root/sdk"
  g checkout -b main; commit u0; g push -u origin main
  g remote set-head origin main; g checkout -b stable main; commit u1
  echo READ >"$tmp/prs/perm_upstream"
  fixture stable "17${TAB}CLOSED${TAB}x"
  r="$tmp/root/repo"

  # origin's main moves on, so a switch to main has something to catch up
  git "${G[@]}" clone -q "$tmp/remote.git" "$tmp/pusher" 2>/dev/null
  r="$tmp/pusher"; commit later; g push origin HEAD:main
  r="$tmp/root/repo"

  local wt="$tmp/root/repo-worktrees"
  g worktree add --detach "$wt/detached" main
  g worktree add --detach "$wt/gone" main; rm -rf "$wt/gone"
  g worktree add -b held "$wt/held" main

  export GIT_SWEEP_GH="$tmp/gh" GIT_SWEEP_PRS="$tmp/prs"
  local me
  me="$SCRIPTS_DIR/$(basename "$0")"
  local sweep=(bash "$me" "$tmp/root")

  out=$("${sweep[@]}" 2>&1)
  check "dry run exits 1 when a lookup failed" test $? -eq 1
  expect "squash-merged branch → delete" '^delete	repo	branch	squashed	'
  expect "tip behind merged head → delete" '^delete	repo	branch	behind	'
  expect "commits after merge → note" '^note	repo	branch	after	commits after'
  expect "open PR → keep" '^keep	repo	branch	open	'
  expect "no PR → note" '^note	repo	branch	nopr	no PR'
  expect "closed PR → note" '^note	repo	branch	closed	PR #11 closed'
  expect "a fork's PR is not the branch's → no PR" '^note	repo	branch	forked	no PR'
  expect "read-only origin → keep" '^keep	sdk	branch	stable	origin .* is read-only'
  expect "failed lookup → skip" '^skip	repo	branch	feat/slash	'
  expect "merged but stashed → note" '^note	repo	branch	stashed	.*stash names'
  expect "merged, checked out, clean → delete" \
    '^delete	repo	branch	current	.*checkout moves to main'
  expect "merged, checked out, dirty → note" \
    '^note	repo2	branch	dirtied	.*uncommitted'
  expect "stash → note" '^note	repo	stash	[0-9a-f]{7}	stash@\{0\}'
  check "a repository with no origin is not scanned" \
    bash -c "! grep -qE '	stray	' <<<'$out'"
  expect "detached worktree → note" '^note	repo	worktree	detached	a linked'
  expect "missing worktree → delete" '^delete	repo	worktree	gone	directory missing'
  expect "branch worktree → note" '^note	repo	worktree	held	.*holds held'
  expect "its branch defers to it" '^keep	repo	branch	held	held by worktree'
  check "dry run changed nothing" git -C "$r" rev-parse -q --verify squashed

  check "a moved tip is not deleted" \
    bash -c "! git -C '$r' update-ref -d refs/heads/squashed $(tip nopr)"

  check "apply refuses without a history" \
    bash -c "! bash '$me' '$tmp/remote.git' --apply 2>/dev/null"

  out=$(cd "$tmp" && JOURNAL_HIST="$tmp/root/.claude/session_history.md" \
        CLAUDE_CODE_SESSION_ID="" "${sweep[@]}" --apply 2>/dev/null)
  expect "apply deletes the squashed branch" '^deleted	repo	branch	squashed'
  expect "apply opens notes" '^noted	repo	branch	nopr'
  check "squashed ref is gone" \
    bash -c "! git -C '$r' rev-parse -q --verify squashed"
  check "behind ref is gone" bash -c "! git -C '$r' rev-parse -q --verify behind"
  check "and main caught up with origin" \
    test "$(tip main)" = "$(git -C "$tmp/remote.git" rev-parse main)"
  check "checkout moved to main" \
    test "$(git -C "$r" branch --show-current)" = main
  check "checked-out ref is gone" \
    bash -c "! git -C '$r' rev-parse -q --verify current"
  check "dirty checkout stays put" \
    test "$(git -C "$tmp/root/repo2" branch --show-current)" = dirtied
  check "open ref stays" git -C "$r" rev-parse -q --verify open
  check "linked worktree stays" test -d "$wt/detached"
  check "missing worktree is pruned" \
    bash -c "! git -C '$r' worktree list | grep -q '$wt/gone'"
  check "journal records a deletion" \
    grep -q "Deleted branch squashed" "$tmp/root/.claude/session_history.md"

  out=$(cd "$tmp" && JOURNAL_HIST="$tmp/root/.claude/session_history.md" \
        CLAUDE_CODE_SESSION_ID="" "${sweep[@]}" --apply 2>/dev/null)
  expect "a second apply finds the note open" '^noted-before	repo	branch	nopr'
  check "a second apply opens no note" \
    bash -c "! grep -q '^noted	' <<<'$out'"

  # the nopr branch and the stash go, the closed PR reopens, and a note keyed
  # under a clone this run does not scan is left alone
  g branch -D nopr; g stash drop
  fixture closed "15${TAB}OPEN${TAB}x"
  (cd "$tmp" && JOURNAL_HIST="$tmp/root/.claude/session_history.md" \
     CLAUDE_CODE_SESSION_ID="" "$SCRIPTS_DIR/journal.sh" -t "chore: test" \
     -b "a foreign sweep note" -n "Sweep branch: x (sweep:elsewhere/branch/x)" \
     >/dev/null 2>&1)
  out=$("${sweep[@]}" 2>&1)
  expect "dry run: a gone branch's note → close" \
    '^close	repo	branch	nopr	note [a-z0-9]{4}: no longer in repo'
  expect "dry run: a gone stash's note → close" '^close	repo	stash	[0-9a-f]{7}	'
  expect "dry run: a now-open PR's note → close" '^close	repo	branch	closed	.*keep: open PR #15'
  check "dry run: a still-noted item's note stays" \
    bash -c "! grep -qE '^close	repo	branch	after	' <<<'$out'"
  check "dry run: a foreign note stays" bash -c "! grep -q elsewhere <<<'$out'"
  out=$(cd "$tmp" && JOURNAL_HIST="$tmp/root/.claude/session_history.md" \
        CLAUDE_CODE_SESSION_ID="" "${sweep[@]}" --apply 2>/dev/null)
  expect "apply closes the gone branch's note" '^closed	repo	branch	nopr	'
  local open
  open=$(cd "$tmp/root" && JOURNAL_HIST="$tmp/root/.claude/session_history.md" \
         "$SCRIPTS_DIR/journal_queue.sh" 2>/dev/null)
  check "the closed notes left the queue" \
    bash -c "! grep -qE 'sweep:repo/(branch/(nopr|closed)|stash/)' <<<'$open'"
  check "the still-noted item's note is open" grep -q 'sweep:repo/branch/after' <<<"$open"
  check "the foreign note is open" grep -q 'sweep:elsewhere/branch/x' <<<"$open"

  (( fail == 0 )) && echo "git_sweep self-test: PASS"
  return "$fail"
}

[[ "${1:-}" == --self-test ]] && { self_test; exit $?; }
main "$@"
