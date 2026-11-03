#!/usr/bin/env bash
# memory_reconcile.sh — deterministic cross-store candidate retrieval. Given a
# candidate fact, find every existing line in the stores `mem_stores` names —
# fact files, both CLAUDE.md, every SKILL.md, every command — that shares
# content tokens with it, ranked.
# It RETRIEVES candidates so a person or the agent can judge new / update /
# contradiction / redundant. It does not decide.
#
# A fact's `description` is what the harness recalls on, so a hit there outranks
# a hit of the same score in a fact body or in any other store.
#
# Usage:
#   memory_reconcile.sh --text "the candidate fact text"
#   memory_reconcile.sh --key aws-profile     # seed tokens from a fact name
#   memory_reconcile.sh [--top N] [--min M] --text "…"
#
# Output (stdout): JSON array, best first:
#   [ { "score":3, "store":"fact", "file":"…/aws-profile.md", "line":3,
#       "fact":"aws-profile"|null, "field":"description"|"body"|null, "snippet":"…" }, … ]
set -uo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./memory_lib.sh
. "$SCRIPTS_DIR/memory_lib.sh"

# Retrieval is only useful if it separates overlap from novelty, and ranks the
# description above the body. All three are asserted — a matcher that returns
# everything passes the first alone.
if [[ "${1:-}" == "--self-test" ]]; then
  command -v jq >/dev/null 2>&1 || { echo "memory_reconcile --self-test: needs jq" >&2; exit 2; }
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  check() {  # DESCRIPTION WANT GOT
    if [[ "$2" == "$3" ]]; then tap_ok "$1"
    else tap_not_ok "$1" "want: $2" "got:  $3"; fi
  }

  # Every store is a fixture — the project, HOME and the memory — so the run
  # never reads a real CLAUDE.md or skill, whose edits would move the counts.
  fx=$(mktemp -d); trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/proj/.claude/skills/zzq-skill" \
           "$fx/proj/.claude/commands" "$fx/home/.claude" "$fx/mem"
  self="$SCRIPTS_DIR/memory_reconcile.sh"

  RARE="wibblewobble frobnicate plughxyzzy"
  printf -- '- [zzq-a](zzq-a.md) — hook\n- [zzq-b](zzq-b.md) — hook\n' > "$fx/mem/MEMORY.md"
  printf -- '---\nname: zzq-a\ndescription: "plain words"\nmetadata:\n  type: reference\n---\n\n%s\n' \
    "$RARE" > "$fx/mem/zzq-a.md"
  printf -- '---\nname: zzq-b\ndescription: "%s"\nmetadata:\n  type: reference\n---\n\nplain body\n' \
    "$RARE" > "$fx/mem/zzq-b.md"
  printf -- '# Project\n\n- a rule about %s, recorded under zzq-b\n' "$RARE" > "$fx/proj/CLAUDE.md"
  printf -- '# Global\n\n- a global rule about %s\n' "$RARE" > "$fx/home/.claude/CLAUDE.md"
  printf -- '---\nname: zzq-skill\n---\n\nA step mentioning %s\n' "$RARE" > "$fx/proj/.claude/skills/zzq-skill/SKILL.md"
  printf -- '# zzq-cmd\n\nIt handles %s\n' "$RARE" > "$fx/proj/.claude/commands/zzq-cmd.md"

  run() { HOME="$fx/home" MEM_PROJECT_ROOT="$fx/proj" MEMORY_FILE="$fx/mem/MEMORY.md" "$self" "$@"; }
  stores() { run --text "$RARE" | jq -r "[.[] | select(.store == \"$1\")] | length"; }

  check "both facts are found" 2 "$(stores fact)"
  check "the description outranks the body" '["zzq-b","description"]' \
    "$(run --text "$RARE" | jq -c '[.[] | select(.store == "fact")][0] | [.fact, .field]')"
  # A retriever that reads only the memory store cannot find the rule that
  # already covers a note, which is the question /notes asks it.
  check "the project CLAUDE.md is searched" 1 "$(stores claude-project)"
  check "the global CLAUDE.md is searched"  1 "$(stores claude-global)"
  check "skills are searched"               1 "$(stores skill)"
  check "commands are searched"             1 "$(stores command)"

  check "a seed sharing nothing returns an empty array, not an error" '[]' \
    "$(run --text 'snorglewip quxbarbaz zindlefop' | jq -c .)"
  check "bare words are taken as the text" 2 \
    "$(run wibblewobble frobnicate plughxyzzy | jq -r '[.[] | select(.store == "fact")] | length')"
  # A key is seeded two ways, and only the literal survives a short name:
  # mem_tokens drops anything under four characters, so "zzq" and "b" vanish.
  check "--key seeds from the name's words" 'true' \
    "$(test "$(run --key wibblewobble-frobnicate | jq 'length')" -gt 0 && echo true || echo false)"
  check "--key also matches the literal name" 'claude-project' \
    "$(run --key zzq-b | jq -r '.[0].store')"
  check "--top caps the result" 1 "$(run --text "$RARE" --top 1 | jq 'length')"
  # The floor is what separates overlap from coincidence; without it every line
  # sharing one common word ranks.
  check "--min raises the floor above a single shared token" 0 \
    "$(run --text "$RARE plain" --min 4 | jq 'length')"
  run >/dev/null 2>&1 && st=0 || st=$?
  check "a run with no seed is refused" 1 "$st"

  tap_end
fi

TEXT="" ; KEY="" ; TOPN=12 ; MIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --text) TEXT="$2"; shift 2 ;;
    --key)  KEY="$2";  shift 2 ;;
    --top)  TOPN="$2"; shift 2 ;;
    --min)  MIN="$2";  shift 2 ;;
    *) TEXT="${TEXT:+$TEXT }$1"; shift ;;   # bare words → text
  esac
done

# A --key seeds tokens from its words and counts the literal name as a token.
[[ -n "$KEY" ]] && TEXT="$TEXT ${KEY//-/ }"
[[ -n "${TEXT// }" ]] || { echo "memory_reconcile: need --text or --key" >&2; exit 1; }

mapfile -t TOKARR < <(mem_tokens "$TEXT")
[[ -n "$KEY" ]] && TOKARR+=("$KEY")
if [[ ${#TOKARR[@]} -eq 0 ]]; then echo '[]'; exit 0; fi
toks="${TOKARR[*]}"

# Default floor: require ≥2 shared tokens when the seed is token-rich, else ≥1.
if [[ "$MIN" -eq 0 ]]; then [[ ${#TOKARR[@]} -ge 3 ]] && MIN=2 || MIN=1; fi

tsv=$(mktemp); trap 'rm -f "$tsv"' EXIT
while IFS=$'\t' read -r type file; do
  [[ -f "$file" ]] || continue
  fact="null"; [[ "$type" == fact ]] && fact=$(basename "$file" .md)
  awk -v type="$type" -v file="$file" -v fact="$fact" -v toks="$toks" -v min="$MIN" '
    BEGIN { ntok = split(toks, T, " ") }
    type == "fact" && FNR == 1 && $0 == "---" { fm = 1; next }
    type == "fact" && fm && $0 == "---"      { fm = 0; next }
    type == "fact" && fm && $0 !~ /^description:/ { next }
    {
      low = tolower($0); score = 0
      for (i = 1; i <= ntok; i++) if (T[i] != "" && index(low, T[i]) > 0) score++
      if (score < min) next
      field = "null"; rank = 1
      if (type == "fact") { field = fm ? "description" : "body"; if (fm) rank = 0 }
      snip = $0; gsub(/\t/, " ", snip); sub(/^[- ]+/, "", snip)
      if (length(snip) > 140) snip = substr(snip, 1, 137) "..."
      printf "%d\t%d\t%s\t%s\t%d\t%s\t%s\t%s\n", score, rank, type, file, FNR, fact, field, snip
    }
  ' "$file"
done < <(mem_stores) >> "$tsv"

sort -t"$(printf '\t')" -k1,1nr -k2,2n "$tsv" | head -n "$TOPN" | jq -R -s '
  split("\n") | map(select(length > 0)) | map(split("\t")) |
  map({ score: (.[0] | tonumber), store: .[2], file: .[3], line: (.[4] | tonumber),
        fact:  (if .[5] == "null" then null else .[5] end),
        field: (if .[6] == "null" then null else .[6] end), snippet: .[7] })
'
