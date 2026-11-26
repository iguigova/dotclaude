#!/usr/bin/env bash
# jira-create.sh — create a Jira issue with a wiki-markup description, required-field aware.
#
# Uses the REST v2 /issue endpoint: its `description` accepts Jira wiki markup and
# Jira converts it to ADF cleanly, so callers write `h4.`, `* bullet`, `{{code}}`
# instead of hand-building an ADF tree.
#
# Before POSTing it reads the project and type's createmeta and refuses when a
# required field is unset, naming the flag that sets each one and, for an option
# field, the ids it allows. --points sets the field whose name is the project's
# jira_points_field value (project_file.sh --value), which --points needs.
#
# It then refuses a ticket the project's Definition of Ready fails: the project's
# jira_dor.py verb judges the payload (`jira_dor.py --payload`), and the same
# verb judges a ticket being picked up, so a ticket made here passes there. The
# ticket's shape is that verb's: `jira_dor.py --help` states it, and
# `jira_dor.py --skeleton` prints it. Every item the verb leaves to a person is
# printed, on a create that passes too.
#
# Last, draft_gate.py holds the create until this Claude session has loaded the
# draft skill; a dry run is never held. Every script it calls is resolved by
# name (project_file.sh --script).
#
# Usage:
#   jira-create.sh --project <KEY> --type <name|id> --summary <text> [opts] < description.wiki
#   jira-create.sh --self-test
#
# Required:
#   --project <KEY>        project key
#   --type <name|id>       issue type by name (Bug, "New Feature") or numeric id; a
#                          name the project lacks is refused with the project's types
#   --summary <text>       one-line summary
#   Description            wiki markup on stdin, or --desc-file <path>
#
# Options:
#   --points <n>           the type's story-points field
#   --parent <KEY>         parent or epic (fields.parent)
#   --label <label>        add a label (repeatable)
#   --link <phrase>:<KEY>  after the create, link "<new> <phrase> <KEY>" with
#                          jira-link.sh, e.g. Relates:ABC-1 (repeatable)
#   --field <id>=<json>    any field, its value raw JSON: --field 'priority={"name":"High"}'
#   --dry-run              print the payload and the verdicts; post nothing
#   -h | --help            this header
#
# Exit: 0 created (KEY on stdout); 1 a call failed, the Definition of Ready check
# could not run, or draft_gate.py held the create; 2 usage, or a type or field
# the project lacks; 3 a required field is unset; 4 created (KEY on stdout) but a
# link failed; 5 the ticket fails the Definition of Ready.
set -uo pipefail

PF="$HOME/.claude/scripts/project_file.sh"
# shellcheck source=flag_value.sh
. "$(dirname "${BASH_SOURCE[0]}")/flag_value.sh" || exit 1

usage() { echo "jira-create: $1" >&2; exit 2; }

# build_payload — the {"fields":{...}} create body from PROJECT TYPE_ID SUMMARY
# DESC, and the optional POINTS_FIELD POINTS PARENT LABELS_JSON EXTRA_JSON.
build_payload() {
  python3 <<'PY'
import json, os
env = os.environ
fields = {"project": {"key": env["PROJECT"]}, "issuetype": {"id": env["TYPE_ID"]},
          "summary": env["SUMMARY"], "description": env.get("DESC", "")}
if env.get("POINTS"):
    fields[env["POINTS_FIELD"]] = float(env["POINTS"])
if env.get("PARENT"):
    fields["parent"] = {"key": env["PARENT"]}
labels = json.loads(env.get("LABELS_JSON", "[]"))
if labels:
    fields["labels"] = labels
for pair in json.loads(env.get("EXTRA_JSON", "[]")):
    fid, _, raw = pair.partition("=")
    fields[fid] = json.loads(raw)
print(json.dumps({"fields": fields}))
PY
}

# points_field — the id of the field FIELDS_JSON names POINTS_NAME, or
# nothing when the type has none.
points_field() {
  python3 -c '
import json, os
hit = [f["fieldId"] for f in json.loads(os.environ["FIELDS_JSON"]) if f["name"] == os.environ["POINTS_NAME"]]
print(hit[0] if hit else "")'
}

# missing_required — each required field of FIELDS_JSON absent from PAYLOAD_JSON
# as "id<TAB>name<TAB>hint", the hint naming the flag that sets it. Exit 1 when
# any is missing.
missing_required() {
  python3 <<'PY'
import json, os
always = {"project", "issuetype", "summary", "description", "reporter"}
present = set(json.loads(os.environ["PAYLOAD_JSON"])["fields"]) | always
hint = {os.environ.get("POINTS_FIELD", ""): "--points"}
missing = [f for f in json.loads(os.environ["FIELDS_JSON"]) if f["required"] and f["fieldId"] not in present]
for f in missing:
    allowed = ", ".join(f"{v['id']} ({v['value']})" for v in f["allowed"])
    flag = f"--field '{f['fieldId']}={{\"id\":\"<id>\"}}', <id> one of {allowed}" if allowed else f"--field {f['fieldId']}=<json>"
    print(f"{f['fieldId']}\t{f['name']}\t{hint.get(f['fieldId']) or flag}")
raise SystemExit(1 if missing else 0)
PY
}

# json_list — the arguments as a JSON array of strings, empty ones dropped.
json_list() {  # <item…>
  python3 -c 'import json, sys; print(json.dumps([a for a in sys.argv[1:] if a]))' "$@"
}

# answer — the JSON on stdin when it holds <key>; otherwise Jira's own error
# messages on stderr, exit 1.
answer() {  # <key>
  python3 -c '
import json, sys
d = json.load(sys.stdin)
if sys.argv[1] not in d:
    sys.exit("jira-create: " + "; ".join(d.get("errorMessages") or [json.dumps(d)]))
print(json.dumps(d))' "$1"
}

# type_line — "<id><TAB><name>" of the project's issue type <name|id>; a type
# the project lacks exits 2, listing its types.
type_line() {  # <name|id>
  local types
  types=$(atlassian_curl "${ATLASSIAN_SITE}/rest/api/3/issue/createmeta/${PROJECT}/issuetypes" | answer issueTypes) \
    || return 1
  TYPE_ARG="$1" PROJECT="$PROJECT" python3 -c '
import json, os, sys
types = json.load(sys.stdin)["issueTypes"]
want, project = os.environ["TYPE_ARG"], os.environ["PROJECT"]
hit = [t for t in types if want in (t["name"], t["id"])]
if not hit:
    print(f"jira-create: no issue type {want!r} in {project}; its types: " + ", ".join(t["name"] for t in types), file=sys.stderr)
    sys.exit(2)
print(hit[0]["id"] + "\t" + hit[0]["name"])' <<<"$types"
}

# fields_of — the type's createmeta fields as [{fieldId, name, required, allowed}].
fields_of() {  # <type id>
  local fields
  fields=$(atlassian_curl "${ATLASSIAN_SITE}/rest/api/3/issue/createmeta/${PROJECT}/issuetypes/$1" | answer fields) \
    || return 1
  python3 -c '
import json, sys
print(json.dumps([{"fieldId": f["fieldId"], "name": f["name"], "required": f["required"],
                   "allowed": [{"id": v["id"], "value": v.get("value") or v.get("name")}
                               for v in f.get("allowedValues", [])]}
                  for f in json.load(sys.stdin)["fields"]]))' <<<"$fields"
}

# ready — the Definition of Ready verdict on PAYLOAD, every item a person judges
# printed; 5 when an item fails, 1 when the check could not run.
ready() {  # <type name>
  local out st=0
  out=$(printf '%s' "$PAYLOAD" | "$DOR" --payload - --type-name "$1") || st=$?
  [[ "$st" -le 1 ]] || { echo "jira-create: the Definition of Ready check could not run (exit $st)" >&2; return 1; }
  [[ "$st" -eq 0 ]] || { echo "jira-create: ${PROJECT}/$1 fails the Definition of Ready:" >&2
    printf '%s\n' "$out" | grep -E '^(FAIL|judge)' | sed 's/^/  /' >&2; return 5; }
  printf '%s\n' "$out" | grep '^judge' | sed 's/^/jira-create: /' >&2
  return 0
}

# key_of — the key a create response carries, or nothing.
key_of() {  # <response>
  python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("key", ""))' "$1" 2>/dev/null
}

# link_all — link the new issue as each --link asks; 4 when any link failed.
link_all() {  # <key>
  local spec failed=0
  for spec in "${LINKS[@]}"; do
    "$LINK" "$1" "${spec%%:*}" "${spec#*:}" >&2 || failed=1
  done
  [[ "$failed" -eq 0 ]] || { echo "jira-create: $1 created, but a link failed" >&2; return 4; }
}

# self_test_project — a project whose atlassian-auth.sh answers from fixtures and
# records what would be posted, whose jira_dor.py answers $JC_DOR_OUT with exit
# $JC_DOR_EXIT, and whose jira-link.sh logs its arguments; the run moves into it.
self_test_project() {  # <folder>
  local s="$1/p/.claude/scripts"
  mkdir -p "$s" && tap_project "$1/p" && cd "$1/p" || return 1
  echo "Story Points" > "$1/p/.claude/jira_points_field"
  cat > "$s/atlassian-auth.sh" <<'STUB'
# shellcheck shell=bash
ATLASSIAN_SITE=https://example.invalid
atlassian_curl() {
  local url="${!#}" data="" prev="" a
  for a in "$@"; do [[ "$prev" == "--data" ]] && data="$a"; prev="$a"; done
  case "$url" in
    */createmeta/NOPE/issuetypes) printf '{"errorMessages":["No project NOPE."],"errors":{}}' ;;
    */createmeta/*/issuetypes)
      printf '{"issueTypes":[{"id":"10004","name":"Bug"},{"id":"10001","name":"Task"},{"id":"10000","name":"Epic"}]}' ;;
    */createmeta/*/issuetypes/*) cat "$JC_FIELDS" ;;
    */rest/api/2/issue) printf '%s' "$data" > "$JC_BODY"; cat "$JC_CREATE" ;;
  esac
}
STUB
  printf '#!/usr/bin/env bash\ncat > "$JC_DOR_IN"; echo "$*" > "$JC_DOR_ARGS"\nprintf "%%s\\n" "${JC_DOR_OUT:-pass   x}"\nexit "${JC_DOR_EXIT:-0}"\n' > "$s/jira_dor.py"
  printf '#!/usr/bin/env bash\necho "$*" >> "$JC_LINKS"\nexit "${JC_LINK_EXIT:-0}"\n' > "$s/jira-link.sh"
  chmod +x "$s/jira_dor.py" "$s/jira-link.sh"
}

self_test_pure() {
  local payload
  payload=$(PROJECT=XYZ TYPE_ID=10004 SUMMARY=t DESC=d POINTS_FIELD=cf_9 POINTS=2 PARENT=XYZ-1 \
            LABELS_JSON='["sec"]' EXTRA_JSON='["priority={\"name\":\"High\"}"]' build_payload)
  tap_is "every option reaches the payload" "$(jq -c .fields <<<"$payload")" \
    '{"project":{"key":"XYZ"},"issuetype":{"id":"10004"},"summary":"t","description":"d","cf_9":2.0,"parent":{"key":"XYZ-1"},"labels":["sec"],"priority":{"name":"High"}}'
  tap_is "a bare payload carries the four fields" \
    "$(PROJECT=XYZ TYPE_ID=1 SUMMARY=t build_payload | jq -c '.fields | keys')" '["description","issuetype","project","summary"]'
  tap_is "the story-points field is found by the project's name for it" \
    "$(FIELDS_JSON='[{"fieldId":"cf_1","name":"Sprint"},{"fieldId":"cf_9","name":"Estimate"}]' POINTS_NAME=Estimate points_field)" cf_9
  tap_is "a type without one has none" "$(FIELDS_JSON='[{"fieldId":"cf_1","name":"Sprint"}]' POINTS_NAME=Estimate points_field)" ""
  tap_is "a JSON list drops empty items" "$(json_list a '' b)" '["a", "b"]'
}

self_test_required() {
  local req='[{"fieldId":"cf_9","name":"Story Points","required":true,"allowed":[]},{"fieldId":"cf_2","name":"Size","required":false,"allowed":[]}]'
  local opt='[{"fieldId":"cf_3","name":"CS","required":true,"allowed":[{"id":"7","value":"Yes"},{"id":"8","value":"No"}]}]'
  tap_run "a satisfied requirement does not flag" env PAYLOAD_JSON='{"fields":{"cf_9":1}}' FIELDS_JSON="$req" bash -c "$(declare -f missing_required); missing_required"
  tap_is "an unset required field names the flag that sets it" \
    "$(PAYLOAD_JSON='{"fields":{}}' FIELDS_JSON="$req" POINTS_FIELD=cf_9 missing_required; echo "exit $?")" $'cf_9\tStory Points\t--points\nexit 1'
  tap_is "an unset option field names its allowed ids" \
    "$(PAYLOAD_JSON='{"fields":{}}' FIELDS_JSON="$opt" missing_required)" $'cf_3\tCS\t--field \'cf_3={"id":"<id>"}\', <id> one of 7 (Yes), 8 (No)'
  tap_is "an unset free field names --field" \
    "$(PAYLOAD_JSON='{"fields":{}}' FIELDS_JSON='[{"fieldId":"cf_4","name":"N","required":true,"allowed":[]}]' missing_required)" $'cf_4\tN\t--field cf_4=<json>'
}

# self_test_runs — the whole script in the fixture project.
self_test_runs() {  # <folder>
  local fx=$1 out
  export JC_FIELDS="$fx/fields.json" JC_CREATE="$fx/create.json" JC_BODY="$fx/body.json" \
         JC_LINKS="$fx/links" JC_DOR_IN="$fx/dor.in" JC_DOR_ARGS="$fx/dor.args"
  printf '%s' '{"fields":[{"fieldId":"cf_9","name":"Story Points","required":true},{"fieldId":"summary","name":"Summary","required":true}]}' > "$JC_FIELDS"
  printf '%s' '{"key":"XYZ-9"}' > "$JC_CREATE"
  jc() { CLAUDE_CODE_SESSION_ID="${JC_SESSION:-}" DRAFT_GATE_DIR="$fx/gate" "$SELF" "$@"; }  # <args…>
  out=$(printf 'the body' | jc --project XYZ --type Bug --summary S --points 2 --dry-run 2>&1)
  tap_is "a dry run resolves the type by name and posts nothing" \
    "$(sed -n '/^{/,$p' <<<"$out" | jq -c '[.fields.issuetype.id, .fields.description, .fields.cf_9]')/$([[ -e "$JC_BODY" ]] && echo posted)" \
    '["10004","the body",2.0]/'
  tap_is "the Definition of Ready judges the payload, by type name" "$(jq -c .fields.summary "$JC_DOR_IN") $(cat "$JC_DOR_ARGS")" \
    '"S" --payload - --type-name Bug'
  printf 'from a file' > "$fx/desc.wiki"
  out=$(jc --project XYZ --type 10000 --summary S --points 1 --desc-file "$fx/desc.wiki" --dry-run 2>&1)
  tap_is "--desc-file is the description, and a numeric type passes its name on" \
    "$(sed -n '/^{/,$p' <<<"$out" | jq -r .fields.description) $(cat "$JC_DOR_ARGS")" 'from a file --payload - --type-name Epic'
  tap_like "an item for a person is printed on a passing create" \
    "$(printf x | JC_DOR_OUT=$'pass   a\njudge  Client label — none' jc --project XYZ --type Bug --summary S --points 1 --dry-run 2>&1 >/dev/null)" \
    "jira-create: judge  Client label — none"
  out=$(printf x | JC_DOR_OUT=$'FAIL   User story — none\npass   b\njudge  c' JC_DOR_EXIT=1 jc --project XYZ --type Bug --summary S --points 1 --dry-run 2>&1)
  tap_is "a ticket the Definition of Ready fails is refused, naming each item" "$out; exit $?" \
    $'jira-create: XYZ/Bug fails the Definition of Ready:\n  FAIL   User story — none\n  judge  c; exit 5'
  tap_like "a check that could not run is no verdict on the ticket" \
    "$(printf x | JC_DOR_EXIT=2 jc --project XYZ --type Bug --summary S --points 1 --dry-run 2>&1; echo "exit $?")" \
    "*could not run (exit 2)*exit 1"
}

self_test_refusals() {
  local out
  out=$(printf x | jc --project XYZ --type Bug --summary S --dry-run 2>&1)
  tap_is "an unset required field stops the create, naming its flag" "$out; exit $?" \
    $'jira-create: missing required field(s) for XYZ/Bug:\n  - Story Points (cf_9) — pass --points; exit 3'
  mv .claude/jira_points_field .claude/jira_points_field.kept
  tap_like "--points in a project naming no story-points field stops, naming the value" \
    "$(printf x | jc --project XYZ --type Bug --summary S --points 1 --dry-run 2>&1; echo "exit $?")" "*jira_points_field*exit 1"
  tap_like "without --points such a project hints the field like any other" \
    "$(printf x | jc --project XYZ --type Bug --summary S --dry-run 2>&1; echo "exit $?")" "*Story Points (cf_9) — pass --field cf_9=<json>*exit 3"
  mv .claude/jira_points_field.kept .claude/jira_points_field
  printf '%s' '{"fields":[{"fieldId":"summary","name":"Summary","required":true}]}' > "$JC_FIELDS"
  tap_is "--points on a type with no Story Points field is refused" \
    "$(printf x | jc --project XYZ --type Bug --summary S --points 1 --dry-run 2>&1; echo "exit $?")" \
    $'jira-create: XYZ/Bug has no Story Points field\nexit 2'
  tap_is "an issue type the project lacks is refused, listing its types" \
    "$(printf x | jc --project XYZ --type Nonesuch --summary S 2>&1; echo "exit $?")" \
    $'jira-create: no issue type \'Nonesuch\' in XYZ; its types: Bug, Task, Epic\nexit 2'
  tap_is "a project Jira does not show is Jira's own error, exit 1" \
    "$(printf x | jc --project NOPE --type Bug --summary S 2>&1; echo "exit $?")" $'jira-create: No project NOPE.\nexit 1'
  cp "$JC_FIELDS" "$JC_FIELDS.kept" && printf '%s' '{"errors":{"x":"y"}}' > "$JC_FIELDS"
  tap_is "a field list Jira will not give stops the create, exit 1" \
    "$(printf x | jc --project XYZ --type Bug --summary S 2>&1; echo "exit $?")" $'jira-create: {"errors": {"x": "y"}}\nexit 1'
  mv "$JC_FIELDS.kept" "$JC_FIELDS"
  local want=$'jira-create: usage: jira-create.sh --project <KEY> --type <name|id> --summary <text> [opts] < description.wiki\nexit 2'
  tap_is "a missing --project is a usage error" \
    "$(printf x | jc --type Bug --summary S --dry-run 2>&1; echo "exit $?")" "$want"
  tap_is "a missing --summary is a usage error" \
    "$(printf x | jc --project XYZ --type Bug --dry-run 2>&1; echo "exit $?")" "$want"
  tap_is "a {{monospace}} span the wiki mangles is refused before any read" \
    "$(printf '{{a]b}}' | jc --project XYZ --type Bug --summary S --dry-run >/dev/null 2>&1; echo $?)" 1
  tap_is "a missing --type is a usage error" "$(printf x | jc --project XYZ --summary S >/dev/null 2>&1; echo $?)" 2
  tap_is "an unknown argument is a usage error" "$(jc --project XYZ --type Bug --summary S --bogus x >/dev/null 2>&1; echo $?)" 2
  tap_is "a last flag with no value is a usage error, not a hang" \
    "$(jc --project XYZ --type Bug --summary S --project </dev/null 2>&1; echo "exit $?")" \
    $'jira-create.sh: --project needs a value\nexit 2'
}

self_test_creates() {  # <folder>
  local key
  tap_is "a session that has not loaded draft creates nothing" \
    "$(printf x | JC_SESSION=st jc --project XYZ --type Bug --summary S 2>&1 | grep -c '^draft_gate: load the draft skill'; [[ -e "$JC_BODY" ]] && echo posted)" 1
  key=$(printf x | jc --project XYZ --type Bug --summary S --label a --link Relates:XYZ-1 --link Blocks:XYZ-2 2>/dev/null)
  tap_is "a create prints its key and links it as asked" "$key; $(cat "$JC_LINKS")" \
    $'XYZ-9; XYZ-9 Relates XYZ-1\nXYZ-9 Blocks XYZ-2'
  tap_is "the posted body carries the labels" "$(jq -c .fields.labels "$JC_BODY")" '["a"]'
  key=$(printf x | JC_LINK_EXIT=1 jc --project XYZ --type Bug --summary S --link Relates:XYZ-1 2>/dev/null)
  tap_is "a failed link still prints the key, exit 4" "$key $?" "XYZ-9 4"
  printf '%s' '{"errors":{"summary":"is required"}}' > "$JC_CREATE"
  tap_is "a response with no key is a failed create" \
    "$(printf x | jc --project XYZ --type Bug --summary S 2>&1; echo "exit $?")" \
    $'jira-create: create failed\n{"errors":{"summary":"is required"}}\nexit 1'
}

if [[ "${1:-}" == --self-test ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  fx=$(mktemp -d) || exit 2; trap 'rm -rf "$fx"' EXIT
  SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  self_test_pure
  self_test_required
  self_test_project "$fx" || exit 2
  self_test_runs "$fx"
  self_test_refusals
  self_test_creates "$fx"
  tap_end
fi

case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

PROJECT="" TYPE="" SUMMARY="" POINTS="" PARENT="" DESC_FILE="" DRYRUN=0
LABELS=() LINKS=() EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)   flag_value "$@"; PROJECT="$2"; shift 2 ;;
    --type)      flag_value "$@"; TYPE="$2"; shift 2 ;;
    --summary)   flag_value "$@"; SUMMARY="$2"; shift 2 ;;
    --points)    flag_value "$@"; POINTS="$2"; shift 2 ;;
    --parent)    flag_value "$@"; PARENT="$2"; shift 2 ;;
    --label)     flag_value "$@"; LABELS+=("$2"); shift 2 ;;
    --link)      flag_value "$@"; LINKS+=("$2"); shift 2 ;;
    --field)     flag_value "$@"; EXTRA+=("$2"); shift 2 ;;
    --desc-file) flag_value "$@"; DESC_FILE="$2"; shift 2 ;;
    --dry-run)   DRYRUN=1; shift ;;
    *) usage "unknown argument '$1'" ;;
  esac
done
[[ -n "$PROJECT" && -n "$TYPE" && -n "$SUMMARY" ]] \
  || usage "usage: jira-create.sh --project <KEY> --type <name|id> --summary <text> [opts] < description.wiki"

AUTH=$("$PF" --script atlassian-auth.sh) || exit 1
WIKI_CHECK=$("$PF" --script jira-wiki-check.sh) || exit 1
DOR=$("$PF" --script jira_dor.py) || exit 1
GATE=$("$PF" --script draft_gate.py) || exit 1
LINK=$("$PF" --script jira-link.sh) || exit 1
# shellcheck source=atlassian-auth.sh
. "$AUTH" || exit 1

if [[ -n "$DESC_FILE" ]]; then DESC=$(cat "$DESC_FILE") || exit 2
elif [[ ! -t 0 ]]; then DESC=$(cat)
else DESC=""; fi
printf '%s' "$DESC" | "$WIKI_CHECK" || exit 1

TYPE_LINE=$(type_line "$TYPE") || exit $?
IFS=$'\t' read -r TYPE_ID TYPE_NAME <<<"$TYPE_LINE"
FIELDS_JSON=$(fields_of "$TYPE_ID") || exit 1
# --points needs the project's name for the story-points field. Without it the
# name is read when the project has one, so a required field's hint names
# --points.
POINTS_NAME=""
if [[ -n "$POINTS" ]] || "$PF" jira_points_field >/dev/null 2>&1; then
  POINTS_NAME=$("$PF" --value jira_points_field) || exit 1
fi
POINTS_FIELD=$(FIELDS_JSON="$FIELDS_JSON" POINTS_NAME="$POINTS_NAME" points_field) || exit 1
[[ -z "$POINTS" || -n "$POINTS_FIELD" ]] || usage "${PROJECT}/${TYPE_NAME} has no ${POINTS_NAME} field"
LABELS_JSON=$(json_list "${LABELS[@]}") || exit 1
EXTRA_JSON=$(json_list "${EXTRA[@]}") || exit 1
PAYLOAD=$(PROJECT="$PROJECT" TYPE_ID="$TYPE_ID" SUMMARY="$SUMMARY" DESC="$DESC" POINTS_FIELD="$POINTS_FIELD" \
          POINTS="$POINTS" PARENT="$PARENT" LABELS_JSON="$LABELS_JSON" EXTRA_JSON="$EXTRA_JSON" build_payload) || exit 2

if ! MISS=$(PAYLOAD_JSON="$PAYLOAD" FIELDS_JSON="$FIELDS_JSON" POINTS_FIELD="$POINTS_FIELD" missing_required); then
  echo "jira-create: missing required field(s) for ${PROJECT}/${TYPE_NAME}:" >&2
  while IFS=$'\t' read -r id name hint; do echo "  - $name ($id) — pass $hint" >&2; done <<<"$MISS"
  exit 3
fi
ready "$TYPE_NAME" || exit $?

if [[ "$DRYRUN" -eq 1 ]]; then
  echo "DRY RUN — would POST to ${ATLASSIAN_SITE}/rest/api/2/issue (type ${TYPE_NAME}=${TYPE_ID}):"
  jq . <<<"$PAYLOAD"
  exit 0
fi

"$GATE" check draft || exit 1
RESP=$(atlassian_curl -X POST -H "Content-Type: application/json" --data "$PAYLOAD" "${ATLASSIAN_SITE}/rest/api/2/issue")
KEY=$(key_of "$RESP")
[[ -n "$KEY" ]] || { printf 'jira-create: create failed\n%s\n' "$RESP" >&2; exit 1; }
echo "$KEY"
link_all "$KEY"
