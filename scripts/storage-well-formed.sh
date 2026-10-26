#!/usr/bin/env bash
# Check that a Confluence storage-format body is well-formed XHTML.
#
# Usage:
#   storage-well-formed.sh [file]      # body from the file, or stdin
#   storage-well-formed.sh --self-test
#
# Confluence rejects a malformed body with a generic 400, or stores it
# mangled, so writers check first. Storage uses HTML named entities
# (&mdash;, &nbsp;) and the ac:/ri: macro prefixes without declaring
# either; both are supplied before parsing, so mentions, links and
# symbols pass.
#
# Exit 0 when well-formed; 1 with the parser's reason on stderr otherwise.

set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac

check() {
  python3 -c '
import re, sys, xml.dom.minidom
body = sys.stdin.read()
escaped = re.sub(r"&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)",
                 "&amp;", body)
root = "<root xmlns:ac=\"urn:ac\" xmlns:ri=\"urn:ri\">%s</root>" % escaped
try:
    xml.dom.minidom.parseString(root.encode("utf-8"))
except Exception as error:
    sys.exit("not well-formed storage XHTML: %s" % error)
'
}

self_test() {
  local good=(
    '<p>Reviewed.</p>'
    '<p>A &mdash; B&nbsp;C &lt;id&gt; &amp; &#160;</p>'
    '<p><ac:link><ri:user ri:account-id="x" /></ac:link> reviewed</p>'
    '<ac:structured-macro ac:name="info"><ac:rich-text-body><p>x</p></ac:rich-text-body></ac:structured-macro>'
  )
  local bad=('<p><strong>unclosed</p>' '<p>unclosed' '<ac:link>')
  local body
  for body in "${good[@]}"; do
    printf '%s' "$body" | check 2>/dev/null \
      || { echo "self-test: valid storage refused: $body" >&2; return 1; }
  done
  for body in "${bad[@]}"; do
    if printf '%s' "$body" | check 2>/dev/null; then
      echo "self-test: malformed storage accepted: $body" >&2; return 1
    fi
  done
  # The dispatch below is the whole CLI, and a writer that reads the wrong input
  # silently checks the wrong body.
  local self fx
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  fx=$(mktemp -d); trap 'rm -rf "$fx"' RETURN
  printf '<p>from a file</p>' > "$fx/ok.html"
  printf '<p>unclosed' > "$fx/bad.html"

  "$self" "$fx/ok.html" 2>/dev/null \
    || { echo "self-test: a well-formed file was refused" >&2; return 1; }
  if "$self" "$fx/bad.html" 2>/dev/null; then
    echo "self-test: a malformed file was accepted" >&2; return 1
  fi
  printf '<p>from stdin</p>' | "$self" 2>/dev/null \
    || { echo "self-test: a well-formed body on stdin was refused" >&2; return 1; }
  if printf '<p>unclosed' | "$self" 2>/dev/null; then
    echo "self-test: a malformed body on stdin was accepted" >&2; return 1
  fi
  if "$self" "$fx/absent.html" 2>/dev/null; then
    echo "self-test: a missing file passed as well-formed" >&2; return 1
  fi

  echo "storage-well-formed self-test: PASS"
}

case "${1:-}" in
  --self-test) self_test ;;
  "") check ;;
  *) check < "$1" ;;
esac
