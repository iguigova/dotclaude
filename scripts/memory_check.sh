#!/usr/bin/env bash
# memory_check.sh — re-check every stored fact and act on the evidence.
#
# It checks the store of the project it is run in (memory_lib.sh finds it), or
# with --all every store under ~/.claude/projects, each in a run of its own. A
# store's project is the working directory its sessions record; a store whose
# sessions name none is skipped and said so. --all is what cron runs.
#
# A fact its `verify:` contradicts is deleted, file and index line, with no
# tombstone: a failing check is evidence a fact is false and never evidence of
# what is true instead, so there is nothing to rewrite it to. Deleting is the
# only thing this script writes. A fact that holds is left exactly as it was, and
# a fact whose check could not run, got no answer, or has no `verify:` for the
# lint to reject, is left alone and reported.
#
# It runs unattended, so it says no on anything it is unsure of:
#   * a fact reading a repository is checked only against a ref just fetched,
#     and is left unchecked when the fetch failed — a stale ref answers about
#     a past the claim was never about — with git's reason for the failure;
#   * a contradiction must reproduce, because a verdict that does not repeat
#     is not evidence, and the fact it would delete may be true;
#   * an empty store is a missing store — a volume not mounted, say — so the
#     run ends having touched nothing, report included. --all never sees a
#     store whose folder is a link to an unmounted volume.
#
# A run that deletes writes what it deleted to <project>/.claude/memory_check.last
# and the project's journal, the only places the text survives. A run of --all
# writes ~/.claude/memory_check.last when it skipped a store, left a fact
# unchecked, or a store's run or its own fixtures failed, and removes it when
# none of these happened.
#
# Usage: memory_check.sh [--all] [--dry-run] [--self-test]
#   --all        every store, not only this project's
#   --dry-run    report what would change, delete nothing
#   --self-test  run the fixtures alone and exit
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./memory_lib.sh
. "$SCRIPTS_DIR/memory_lib.sh"

DRY=0; SELFTEST=0; ALL=0
for a in "$@"; do case "$a" in
  --all)       ALL=1 ;;
  --dry-run)   DRY=1 ;;
  --self-test) SELFTEST=1 ;;
  *) echo "memory_check: unknown argument $a" >&2; exit 2 ;;
esac; done

TODAY=$(date -u +%F)
REPORT="$MEM_CLAUDE_DIR/memory_check.last"
ALL_REPORT="$HOME/.claude/memory_check.last"

# --- Evidence ---------------------------------------------------------------

# mc_run_one FILE — exit status of one run of the fact's verify command.
mc_run_one() { mem_verify "$(mem_field "$1" verify)"; }

# mc_verify FILE — ok | unrun | unanswered | contradicted.
# 126 and 127 mean the shell never reached the command, and 75 means the command
# ran but got no answer about the claim, so none of the three says anything about
# it. Every other non-zero exit does — once it has said so twice, because a
# verdict that does not repeat is not evidence and this run deletes on it.
mc_verify() {
  local rc
  mc_run_one "$1"; rc=$?
  case "$rc" in
    0)       echo ok; return ;;
    75)      echo unanswered; return ;;
    126|127) echo unrun; return ;;
  esac
  mc_run_one "$1"; rc=$?
  case "$rc" in
    0)       echo flaky ;;
    75)      echo unanswered ;;
    126|127) echo unrun ;;
    *)       echo contradicted ;;
  esac
}

# --- Fetching ---------------------------------------------------------------
# A verify reading a file at `origin/<branch>` reads the local object database,
# so its verdict is only as current as the last fetch. The run fetches every
# repository any fact reads, and a repository it could not reach makes every
# fact reading it unchecked rather than false.

declare -A MC_STALE=()   # repository -> why it was not fetched

# mc_repos_of FILE — the repositories this fact's verify reads, one per line:
# the <repo> of `git_fact.sh <repo>` and of `git -C <repo>`.
mc_repos_of() {
  grep -oE '(git_fact\.sh|git -C) [^ ]+' <<<"$(mem_field "$1" verify)" | awk '{ print $NF }'
}

mc_fetch_repos() {
  local f repo path err fetch
  local -A repos=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    while read -r repo; do
      [[ -n "$repo" ]] && repos["$repo"]=1
    done < <(mc_repos_of "$f")
  done < <(mem_facts)

  for repo in "${!repos[@]}"; do
    path=$repo; [[ "$path" == /* ]] || path="$MEM_PROJECT_ROOT/$repo"
    if [[ ! -e "$path/.git" ]]; then
      MC_STALE["$repo"]="no checkout at $path"; continue
    fi
    fetch=(timeout 120 git -C "$path" fetch --quiet --prune origin)
    err=$("${fetch[@]}" 2>&1 >/dev/null) \
      || MC_STALE["$repo"]=$(mc_fetch_error "$?" "$err")
  done
}

# mc_fetch_error STATUS STDERR — why a fetch failed, in one line: git's first
# fatal or error line, else its last line, else the exit status. A fetch
# killed by the timeout says nothing, so it is named.
mc_fetch_error() {
  local line
  [[ "$1" -eq 124 ]] && { printf 'timed out after 120s'; return; }
  line=$(grep -m1 -E '^(fatal|error): ' <<<"$2" \
    || grep -v '^[[:space:]]*$' <<<"$2" | tail -1)
  line=${line#fatal: }; line=${line#error: }
  printf '%s' "${line:-git fetch exited $1}"
}

# mc_stale_repo FILE — the name of a repository this fact reads that was not
# fetched, or nothing.
mc_stale_repo() {
  local repo
  while read -r repo; do
    [[ -n "$repo" && -n "${MC_STALE[$repo]:-}" ]] && { printf '%s' "$repo"; return; }
  done < <(mc_repos_of "$1")
}

# mc_store_present — true while the memory directory holds at least one fact.
# An empty store is a missing store: a memory directory can be a link into a
# volume that is not mounted.
mc_store_present() { [[ -n "$(mem_facts)" ]]; }

mc_delete() {   # FILE — remove the fact and its index line, leaving no trace
  [[ "$DRY" -eq 1 ]] && return
  local b; b=$(basename "$1")
  grep -vF -- "($b)" "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"
  rm -f "$1"
}

# --- Every store ------------------------------------------------------------

# mc_root_of FOLDER — the project a harness folder belongs to: the working
# directory one of its sessions recorded that encodes to FOLDER. Nothing when no
# session does. Each transcript is read only to its first cwd.
mc_root_of() {
  local r
  while IFS= read -r r; do
    [[ "$(mem_project_folder "$r")" == "$1" ]] && { printf '%s' "$r"; return; }
  done < <(grep -m1 -oh '"cwd":"[^"]*"' "$1"/*.jsonl 2>/dev/null | cut -d'"' -f4 | sort -u)
}

# mc_all_report TEXT — what a run of --all could not do, written where a session
# reads it, or the stale report removed when TEXT is empty. A dry run writes
# nothing.
mc_all_report() {
  [[ "$DRY" -eq 1 ]] && return
  if [[ -n "$1" ]]; then
    printf 'memory_check --all %s\n\n%s' "$TODAY" "$1" > "$ALL_REPORT"
  else
    rm -f "$ALL_REPORT"
  fi
}

# mc_all — one run of this script per store, each told its project. Exits
# non-zero when any run did. A fact left unchecked is reported with the night it
# was first left unchecked, carried from the last report, so one that stays
# unchecked night after night reads as such; a store skipped tonight keeps last
# night's lines, since skipping it learned nothing.
mc_all() {
  local mem folder root st out line rc=0 problems="" args=()
  local -A since=() kept=()
  [[ "$DRY" -eq 1 ]] && args+=(--dry-run)
  # A line is "unchecked since DATE: NAME in ROOT — REASON". A name holds no
  # space, and the root runs to the first " — ", wherever else a reason has one.
  local re_prev='^unchecked since ([0-9-]+): ([a-z0-9-]+) in (.+)$'
  local re_run='^  unchecked  ([a-z0-9-]+) — (.*)$'
  if [[ -f "$ALL_REPORT" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ $re_prev ]] || continue
      root=${BASH_REMATCH[3]%% — *}
      since["$root/${BASH_REMATCH[2]}"]=${BASH_REMATCH[1]}
      kept["$(mem_project_folder "$root")"]+="$line"$'\n'
    done < "$ALL_REPORT"
  fi
  for folder in "$HOME"/.claude/projects/*; do
    # A folder linked into a volume that is not mounted holds no store to see.
    if [[ -L "$folder" && ! -e "$folder" ]]; then
      echo "memory_check: $folder links to $(readlink "$folder"), which is not there; skipped"
      problems+="skipped $folder — its store is not mounted"$'\n'"${kept[$folder]:-}"
      continue
    fi
    mem="$folder/memory/MEMORY.md"
    [[ -f "$mem" ]] || continue
    root=$(mc_root_of "$folder")
    if [[ -z "$root" ]]; then
      echo "memory_check: no session in $folder names its project; skipped"
      problems+="skipped $folder — no session names its project"$'\n'"${kept[$folder]:-}"
      continue
    fi
    echo "== $root"
    out=$(MEM_PROJECT_ROOT="$root" MEMORY_FILE="$mem" "$SCRIPTS_DIR/memory_check.sh" "${args[@]}" 2>&1)
    st=$?
    printf '%s\n' "$out"
    while IFS= read -r line; do
      [[ "$line" =~ $re_run ]] || continue
      problems+="unchecked since ${since["$root/${BASH_REMATCH[1]}"]:-$TODAY}: ${BASH_REMATCH[1]} in $root — ${BASH_REMATCH[2]}"$'\n'
    done <<<"$out"
    [[ "$st" -eq 0 ]] || { rc=1; problems+="failed $root — its run exited $st"$'\n'; }
  done
  mc_all_report "$problems"
  return $rc
}

# --- The run ----------------------------------------------------------------
# Prints one line per fact that needs saying, and sets the counters. A fact that
# holds says nothing: silence is the good case.

held=0; deleted=0; unchecked=0; deleted_text=""

mc_run() {
  held=0; deleted=0; unchecked=0; deleted_text=""
  local f name stale
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    name=$(basename "$f" .md)

    if [[ -z "$(mem_field "$f" verify)" ]]; then
      echo "  unchecked  $name — no verify; memory_lint rejects this fact"
      unchecked=$((unchecked + 1)); continue
    fi

    stale=$(mc_stale_repo "$f")
    if [[ -n "$stale" ]]; then
      echo "  unchecked  $name — $stale was not fetched (${MC_STALE[$stale]}), so its ref answers about a past"
      unchecked=$((unchecked + 1)); continue
    fi

    case "$(mc_verify "$f")" in
      ok)    held=$((held + 1)) ;;
      unrun) echo "  unchecked  $name — its verify never ran"; unchecked=$((unchecked + 1)) ;;
      unanswered) echo "  unchecked  $name — its verify got no answer, so nothing was learned"
             unchecked=$((unchecked + 1)) ;;
      flaky) echo "  unchecked  $name — its verify failed once and passed once; not evidence"
             unchecked=$((unchecked + 1)) ;;
      contradicted)
        deleted_text+="$name: $(mem_field "$f" description)"$'\n'
        deleted_text+="$(sed '1,/^---$/d; 1,/^---$/d' "$f")"$'\n\n'
        echo "  DELETED    $name — verify contradicted it"
        mc_delete "$f"; deleted=$((deleted + 1)) ;;
    esac
  done < <(mem_facts)
}

# --- Fixtures ---------------------------------------------------------------
# The checker deletes on a verdict it computed, so it proves itself against known
# outcomes before it trusts one. Twice in one session a fault in the runner
# reported every credential fact as contradicted while all were true.

mc_fixture() {  # DIR NAME [VERIFY]
  {
    printf -- '---\nname: %s\ndescription: "fixture %s"\nmetadata:\n  type: reference\n' "$2" "$2"
    [[ -n "${3:-}" ]] && printf '  verify: %s\n' "$3"
    printf -- '---\n\nfixture body\n'
  } > "$1/$2.md"
  echo "- [$2]($2.md) — fixture" >> "$1/MEMORY.md"
}

mc_self_test() {
  local d out why rc=0
  d=$(mktemp -d) || return 2
  echo "# fixtures" > "$d/MEMORY.md"
  mc_fixture "$d" holds        'true'
  mc_fixture "$d" contradicted 'false'
  mc_fixture "$d" unrunnable   'no-such-command-e3f1a'
  mc_fixture "$d" unanswered   'exit 75'
  mc_fixture "$d" noverify
  # Fails, then passes: the verdict that must never delete anything.
  mc_fixture "$d" flaky        "n=\$(cat $d/n 2>/dev/null || echo 0); echo \$((n+1)) > $d/n; [ \$((n%2)) -eq 1 ]"
  mc_fixture "$d" needsfetch   'git -C api/zzq-fixture show origin/main:x'
  mc_fixture "$d" factfetch    'git_fact.sh api/zzq-fixture origin/main x y'
  # A pipeline whose producer is killed once the reader has what it needs.
  mc_fixture "$d" sigpipe      'yes | head -1 | grep -q y'

  # A subshell, so the fixture paths cannot leak into the run over the real
  # store: assignments before a word that is itself an assignment are not a
  # temporary environment, they are permanent.
  # $out is read by the `check` expressions below, which are eval'd strings.
  # shellcheck disable=SC2034
  out=$(
    MEMORY_FILE="$d/MEMORY.md"; MEM_DIR="$d"; DRY=0
    # the fetch this run could not do, and git's reason
    MC_STALE=([api/zzq-fixture]="Could not resolve host: zzq")
    mc_run
    echo "COUNTS $held $deleted $unchecked"
  )

  check() { # DESCRIPTION CONDITION
    if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1" >&2; rc=1; fi
  }
  check "a fact that holds is left alone"        '[[ -f "$d/holds.md" ]]'
  check "a contradicted fact is deleted"         '[[ ! -f "$d/contradicted.md" ]]'
  check "its index line goes with it"            '! grep -q "(contradicted.md)" "$d/MEMORY.md"'
  check "a check that never ran deletes nothing" '[[ -f "$d/unrunnable.md" ]]'
  check "a check that got no answer deletes nothing" '[[ -f "$d/unanswered.md" ]]'
  check "a check that got no answer is not counted as held" 'grep -q "unanswered — its verify got no answer" <<<"$out"'
  check "a fact with no verify is never run"     '[[ -f "$d/noverify.md" ]]'
  check "a contradiction that does not repeat deletes nothing" '[[ -f "$d/flaky.md" ]]'
  check "a fact whose repository was not fetched is left alone" '[[ -f "$d/needsfetch.md" ]]'
  check "so is one reading it through git_fact.sh" '[[ -f "$d/factfetch.md" ]] && grep -q "factfetch — api/zzq-fixture was not fetched" <<<"$out"'
  check "an unfetched fact says why the fetch failed" \
    'grep -q "not fetched (Could not resolve host: zzq), so" <<<"$out"'
  why=$(mc_fetch_error 128 $'warning: w\nfatal: f1\nfatal: f2\n\nPlease x')
  check "a failed fetch is named by git's first fatal line" '[[ "$why" == f1 ]]'
  why=$(mc_fetch_error 1 $'a\nb\n\n')
  check "else by its last line" '[[ "$why" == b ]]'
  why=$(mc_fetch_error 1 "")
  check "else by its exit status" '[[ "$why" == "git fetch exited 1" ]]'
  why=$(mc_fetch_error 124 "")
  check "a fetch the timeout killed says so" '[[ "$why" == "timed out after 120s" ]]'
  # A checkout whose origin is not there: the real fetch, failing.
  git init -q "$d/proj/api/zzq-fixture"
  git -C "$d/proj/api/zzq-fixture" remote add origin "$d/nowhere"
  # $why is read by the eval'd `check` below, as $out is above.
  # shellcheck disable=SC2034
  why=$(
    MEM_PROJECT_ROOT="$d/proj"; MEM_DIR="$d"
    mc_fetch_repos; printf '%s' "${MC_STALE[api/zzq-fixture]}"
  )
  check "a fetch that fails records git's reason" \
    '[[ "$why" == "'\''$d/nowhere'\'' does not appear to be a git repository" ]]'
  check "both forms name the repository to fetch" \
    '[[ "$(MEM_DIR="$d"; mc_repos_of "$d/factfetch.md") $(MEM_DIR="$d"; mc_repos_of "$d/needsfetch.md")" == "api/zzq-fixture api/zzq-fixture" ]]'
  check "a producer killed by SIGPIPE is not a contradiction" '[[ -f "$d/sigpipe.md" ]]'
  check "an empty store reads as a missing store" '! ( MEM_DIR="$d/none"; mc_store_present )'
  check "the counts are 2 held, 1 deleted, 6 unchecked" 'grep -q "COUNTS 2 1 6" <<<"$out"'

  rm -rf "$d"
  return $rc
}

# mc_e2e_test — the script itself, run over a store that is only fixtures.
# Separate from mc_self_test because the real run calls that one as its gate, and
# a gate that spawned this would recurse. What it covers is the main path:
# argument handling, --dry-run, and the report that is the deleted text's only
# remaining copy.
mc_e2e_test() {
  local rc=0 fx out st
  fx=$(mktemp -d) || return 2
  mkdir -p "$fx/proj" "$fx/mem" "$fx/home"
  local self="$SCRIPTS_DIR/memory_check.sh"
  local report="$fx/proj/.claude/memory_check.last"

  check2() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then echo "  ok   $1"
    else printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$1" "$2" "$3" >&2; rc=1; fi
  }
  # HOME is redirected so the journal call on a deletion cannot reach the real
  # history; it is silenced and non-fatal, and a test must not write one.
  mc() { HOME="$fx/home" MEM_PROJECT_ROOT="$fx/proj" MEMORY_FILE="$fx/mem/MEMORY.md" "$self" "$@"; }
  seed() {
    rm -f "$fx"/mem/*.md
    echo "# fixtures" > "$fx/mem/MEMORY.md"
    mc_fixture "$fx/mem" e2eholds 'true'
    [[ "${1:-}" == with-bad ]] && mc_fixture "$fx/mem" e2egone 'false'
    return 0
  }

  seed with-bad
  out=$(mc --dry-run 2>&1); st=$?
  check2 "a dry run exits 0" 0 "$st"
  check2 "a dry run deletes nothing" 'true' "$([[ -f "$fx/mem/e2egone.md" ]] && echo true || echo false)"
  check2 "a dry run leaves the index alone" 'true' \
    "$(grep -q '(e2egone.md)' "$fx/mem/MEMORY.md" && echo true || echo false)"
  check2 "a dry run writes no report" 'true' "$([[ ! -f "$report" ]] && echo true || echo false)"
  check2 "and it still reports the counts it would apply" 'true' \
    "$(grep -q '1 held, 1 deleted, 0 unchecked' <<<"$out" && echo true || echo false)"

  out=$(mc 2>&1); st=$?
  check2 "a real run exits 0" 0 "$st"
  check2 "the contradicted fact is gone" 'true' "$([[ ! -f "$fx/mem/e2egone.md" ]] && echo true || echo false)"
  check2 "the fact that holds is untouched" 'true' "$([[ -f "$fx/mem/e2eholds.md" ]] && echo true || echo false)"
  check2 "the index line goes with it" 'true' \
    "$(grep -q '(e2egone.md)' "$fx/mem/MEMORY.md" && echo false || echo true)"
  # The report is the only place a deleted fact's text survives.
  check2 "the report records what was deleted" 'true' \
    "$(grep -q 'e2egone' "$report" 2>/dev/null && echo true || echo false)"

  seed
  mc >/dev/null 2>&1
  check2 "a run that deletes nothing clears the stale report" 'true' \
    "$([[ ! -f "$report" ]] && echo true || echo false)"

  rm -f "$fx"/mem/*.md; echo "# empty" > "$fx/mem/MEMORY.md"
  out=$(mc 2>&1); st=$?
  check2 "an empty store is not an error" 0 "$st"
  check2 "and it says the store is not mounted rather than deleting" 'true' \
    "$(grep -q 'not mounted' <<<"$out" && echo true || echo false)"

  mc --bogus >/dev/null 2>&1; st=$?
  check2 "an unknown argument is refused" 2 "$st"

  # --all finds the store from HOME alone, and its project from a session's cwd.
  local folder; folder="$fx/home/.claude/projects/${fx//[^a-zA-Z0-9]/-}-proj"
  mkdir -p "$folder/memory" "$fx/home/.claude/projects/-orphan/memory"
  printf '{"cwd":"%s"}\n' "$fx/proj" > "$folder/s.jsonl"
  echo "# fixtures" > "$folder/memory/MEMORY.md"
  mc_fixture "$folder/memory" allheld 'true'
  echo "# none" > "$fx/home/.claude/projects/-orphan/memory/MEMORY.md"
  out=$(HOME="$fx/home" "$self" --all --dry-run 2>&1); st=$?
  check2 "--all exits 0" 0 "$st"
  check2 "--all checks a store under the project its session names" 'true' \
    "$(grep -q "== $fx/proj" <<<"$out" && grep -q '1 held, 0 deleted' <<<"$out" && echo true || echo false)"
  check2 "--all skips a store no session names, and says so" 'true' \
    "$(grep -q 'orphan names its project; skipped' <<<"$out" && echo true || echo false)"
  local all_report="$fx/home/.claude/memory_check.last"
  check2 "a dry run of --all writes no report" 'true' "$([[ ! -f "$all_report" ]] && echo true || echo false)"
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "--all reports the store it skipped where a session reads" 'true' \
    "$(grep -q 'skipped .*-orphan — no session names its project' "$all_report" 2>/dev/null && echo true || echo false)"
  rm -rf "$fx/home/.claude/projects/-orphan"
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "an --all run with nothing to say removes the stale report" 'true' \
    "$([[ ! -f "$all_report" ]] && echo true || echo false)"

  ln -s "$fx/unmounted/data" "$fx/home/.claude/projects/-unmounted"
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "--all reports a store linked to a volume that is not mounted" 'true' \
    "$(grep -q 'skipped .*-unmounted — its store is not mounted' "$all_report" 2>/dev/null && echo true || echo false)"
  rm "$fx/home/.claude/projects/-unmounted"

  mc_fixture "$folder/memory" allwait 'exit 75'
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "--all reports an unchecked fact from tonight" 'true' \
    "$(grep -q "^unchecked since $(date -u +%F): allwait in $fx/proj — its verify got no answer" "$all_report" 2>/dev/null && echo true || echo false)"
  sed -i 's/^unchecked since [0-9-]*:/unchecked since 2026-01-01:/' "$all_report"
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "and keeps the night it was first unchecked" 'true' \
    "$(grep -q "^unchecked since 2026-01-01: allwait in $fx/proj" "$all_report" 2>/dev/null && echo true || echo false)"
  sed -i 's/ — .*/ — a reason — with a dash in it/' "$all_report"
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "a reason holding a dash keeps the night too" 'true' \
    "$(grep -q "^unchecked since 2026-01-01: allwait in $fx/proj — its verify" "$all_report" 2>/dev/null && echo true || echo false)"
  mv "$folder" "$fx/store"; ln -s "$fx/unmounted/data" "$folder"
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "a store skipped tonight keeps last night's unchecked lines" 'true' \
    "$(grep -q "skipped .* — its store is not mounted" "$all_report" && grep -q "^unchecked since 2026-01-01: allwait in $fx/proj" "$all_report" 2>/dev/null && echo true || echo false)"
  rm "$folder"; mv "$fx/store" "$folder"
  rm "$folder/memory/allwait.md"; sed -i '/(allwait.md)/d' "$folder/memory/MEMORY.md"
  HOME="$fx/home" "$self" --all >/dev/null 2>&1
  check2 "a fact checked again leaves the report" 'true' \
    "$([[ ! -f "$all_report" ]] && echo true || echo false)"

  rm -rf "$fx"
  return $rc
}

# --- Main -------------------------------------------------------------------

if [[ "$SELFTEST" -eq 1 ]]; then
  echo "memory_check --self-test"
  st=0
  mc_self_test || st=1
  mc_e2e_test  || st=1
  [[ $st -eq 0 ]] && echo "memory_check: self-test PASS" || echo "memory_check: self-test FAIL" >&2
  exit $st
fi

# The only gate. The store shares a volume with the facts it checks, so a run
# that reaches here has both or neither. The network needs no gate: a verify
# asking a live system exits 75 when nobody answers, and 75 deletes nothing.
if ! mc_self_test >/dev/null 2>&1; then
  echo "memory_check: own fixtures failed — refusing to touch the store" >&2
  [[ "$ALL" -eq 1 ]] && mc_all_report "failed — memory_check's own fixtures, so no store was checked"$'\n'
  exit 2
fi

if [[ "$ALL" -eq 1 ]]; then mc_all; exit $?; fi

if ! mc_store_present; then
  echo "memory_check: no facts under $MEM_DIR — the store is not mounted; nothing touched" >&2
  exit 0
fi

[[ "$DRY" -eq 1 ]] && echo "memory_check $TODAY (dry run)" || echo "memory_check $TODAY"
mc_fetch_repos
for r in "${!MC_STALE[@]}"; do
  echo "  not fetched $r — ${MC_STALE[$r]}; every fact reading it is left unchecked"
done
mc_run
echo "memory_check: $held held, $deleted deleted, $unchecked unchecked"

# Only a deletion is worth reporting, because only a deletion changed anything,
# and the deleted text survives nowhere else.
if [[ "$DRY" -eq 0 && "$deleted" -gt 0 ]]; then
  mkdir -p "$MEM_CLAUDE_DIR"
  {
    echo "memory_check $TODAY: $deleted deleted, $held held, $unchecked unchecked"
    echo; echo "Deleted:"; echo "$deleted_text"
  } > "$REPORT"
  # From the project, since the journal writer takes the history nearest its
  # working directory.
  ( cd "$MEM_PROJECT_ROOT" && "$HOME/.claude/scripts/journal.sh" \
    -t "chore: memory_check $TODAY" \
    -b "$deleted facts deleted, $held held, $unchecked unchecked." \
    -b "Deleted, and this is the only remaining copy: ${deleted_text//$'\n'/ }" ) >/dev/null 2>&1
elif [[ "$DRY" -eq 0 ]]; then
  rm -f "$REPORT"
fi
exit 0
