#!/usr/bin/env bash
# Refuse Jira wiki markup whose {{monospace}} spans Jira will mis-render.
#
# Inside {{…}}, Jira still parses { } [ ] and -- as markup: {{{"a":1}}} renders
# its braces literally instead of in monospace, a [ starts a link, which
# renders as an error span when no link follows, and a -- closes a
# -strikethrough- opened earlier on the line, so {{--only x}} with
# {{--from 1}} renders struck through. A single - ({{-b}}) renders as typed.
# Each must be escaped with a backslash: {{\{"a": \[1\]\}}}, {{\-\-flag}}.
# {code} and {noformat} blocks are not parsed, so their contents are not
# checked.
#
# Usage:
#   jira-wiki-check.sh [file]    # body from file, or stdin if omitted
#   jira-wiki-check.sh --self-test
#
# jira-comment.sh, jira-description.sh and jira-create.sh run it on every body
# before sending it.
#
# Exit 0 when the body is clean; 1 with each offending line on stderr.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

if [[ "${1:-}" == --self-test ]]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  ok() { printf '%s\n' "$1" | "$self" >/dev/null 2>&1 || { echo "self-test: refused clean markup: $1" >&2; exit 1; }; }
  bad() { if printf '%s\n' "$1" | "$self" >/dev/null 2>&1; then echo "self-test: accepted bad markup: $1" >&2; exit 1; fi; }
  ok '{{"status":"pending"}} and [PR|https://x/1]'
  ok '{{\{"a": \[1\]\}}}'
  ok $'{code:json}\n{"a": [1]}\n{code}'
  ok $'{noformat}\n{{{x}}}\n{noformat}'
  bad '{{{"a":1}}}'
  bad '{{\{"ids":["x"]\}}}'
  bad '{{a]b}}'
  bad '{{--only x}} with {{--from 1}}'
  bad '{{--execute}}'
  ok '{{\-\-only x}} with {{\-\-from 1 \-\-to 2}}'
  ok '{{2026-10-22}} and {{a-b}}'
  ok '{{-b}} and {{-c}}'
  echo "jira-wiki-check self-test: PASS"
  exit 0
fi

exec python3 -I -c '
import re, sys
body = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()
# Blank out the unparsed blocks, keeping the line count.
body = re.sub(r"\{(code|noformat)[^}]*\}.*?\{\1\}",
              lambda m: "\n" * m.group(0).count("\n"), body, flags=re.S)
span = re.compile(r"\{\{((?:\\.|[^}\\])*?)\}\}")
bad = []
for n, line in enumerate(body.split("\n"), 1):
    if "{{{" in line or any(re.search(r"(?<!\\)[\[\]{]|--", s) for s in span.findall(line)):
        bad.append(f"  line {n}: {line.strip()}")
if bad:
    print("Unescaped { } [ ] or -- inside a {{monospace}} span; write each as \\{ \\} \\[ \\] \\-\\-:", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
' "$@"
