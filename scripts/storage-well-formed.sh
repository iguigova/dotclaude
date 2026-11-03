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
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  well() { printf '%s' "$2" | check 2>/dev/null && tap_ok "$1" || tap_not_ok "$1"; }
  ill() { printf '%s' "$2" | check 2>/dev/null && tap_not_ok "$1" || tap_ok "$1"; }
  well "a paragraph is well-formed" '<p>Reviewed.</p>'
  well "named and numeric entities are well-formed" \
    '<p>A &mdash; B&nbsp;C &lt;id&gt; &amp; &#160;</p>'
  well "a user link is well-formed" \
    '<p><ac:link><ri:user ri:account-id="x" /></ac:link> reviewed</p>'
  well "a macro with a rich-text body is well-formed" \
    '<ac:structured-macro ac:name="info"><ac:rich-text-body><p>x</p></ac:rich-text-body></ac:structured-macro>'
  ill "an unclosed element inside a closed one is refused" '<p><strong>unclosed</p>'
  ill "an unclosed paragraph is refused" '<p>unclosed'
  ill "an unclosed macro element is refused" '<ac:link>'
  # The dispatch below is the whole CLI, and a writer that reads the wrong input
  # silently checks the wrong body.
  local self fx
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  fx=$(mktemp -d); trap 'rm -rf "$fx"' RETURN
  printf '<p>from a file</p>' > "$fx/ok.html"
  printf '<p>unclosed' > "$fx/bad.html"
  runs() { "$self" "$@" 2>/dev/null; }
  fails() { ! "$self" "$@" 2>/dev/null; }
  tap_run "a well-formed file is accepted" runs "$fx/ok.html"
  tap_run "a malformed file is refused" fails "$fx/bad.html"
  tap_run "a well-formed body on stdin is accepted" runs <<<'<p>from stdin</p>'
  tap_run "a malformed body on stdin is refused" fails <<<'<p>unclosed'
  tap_run "a missing file is refused" fails "$fx/absent.html"
}

case "${1:-}" in
  --self-test) self_test; tap_end ;;
  "") check ;;
  *) check < "$1" ;;
esac
