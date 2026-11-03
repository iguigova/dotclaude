#!/usr/bin/env bash
# route_latency.sh — time a set of API calls fired in parallel, the way a page
# loader fires them, and split each into time to first byte and total.
#
# TTFB is compute: the server's work before it answers. Total minus TTFB is
# transfer. The split is what tells a compression or payload fix (transfer)
# from an aggregation or query fix (compute).
#
# Usage: route_latency.sh [--runs N] <url>...
#   --runs N       fire the whole set N times, one set after another (default 3)
#   --self-test    offline: times two calls against a local http server
#   -h | --help
#
# Env:
#   TOK            bearer token sent on every call, when set; a project's
#                  token script mints it, e.g. TOK=$(staging_token.sh)
#
# Output, tab-separated, one row per call:
#   run  status  ttfb_ms  total_ms  bytes  encoding  url
# then one summary row per url:
#   summary  first_ttfb_ms  first_total_ms  rest_ttfb_ms  rest_total_ms  url
# where "rest" is the median of runs 2..N.
#
# Calls ask for gzip, as a browser does, so bytes is the wire size and
# encoding is what the server chose ("-" for none). Run 1 is cold only if the
# target was idle before the probe; the probe cannot force a cold start.
# Exit 0 when every call answered, 1 when any call failed to connect.
set -euo pipefail

WRITE_OUT='%{http_code}\t%{time_starttransfer}\t%{time_total}'
WRITE_OUT+='\t%{size_download}\t%header{content-encoding}\n'

## Firing

time_call() {  # <url> → status ttfb_s total_s bytes encoding
  local auth=()
  [ -n "${TOK:-}" ] && auth=(-H "Authorization: Bearer $TOK")
  curl -s -o /dev/null -H 'Accept-Encoding: gzip' "${auth[@]}" \
    -w "$WRITE_OUT" "$1"
}

fire_set() {  # <run> <dir> <url>... — every call at once, rows in url order
  local run="$1" dir="$2" i=0 url
  shift 2
  for url in "$@"; do time_call "$url" >"$dir/$i" & i=$((i + 1)); done
  wait
  i=0
  for url in "$@"; do
    printf '%s\t%s\t%s\n' "$run" "$(cat "$dir/$i")" "$url"
    i=$((i + 1))
  done
}

## Shaping

to_rows() {  # seconds → ms, empty encoding → "-"
  awk -F'\t' -v OFS='\t' '{
    $3 = int($3 * 1000 + 0.5); $4 = int($4 * 1000 + 0.5)
    if ($6 == "") $6 = "-"
    print }'
}

summarise() {  # rows → one summary row per url, in first-seen order
  awk -F'\t' -v OFS='\t' '
    function median(list,   n, a, i, j, t) {
      n = split(list, a, " ")
      if (n == 0) return "-"
      for (i = 2; i <= n; i++)
        for (j = i; j > 1 && a[j-1] + 0 > a[j] + 0; j--)
          { t = a[j]; a[j] = a[j-1]; a[j-1] = t }
      return (n % 2) ? a[(n+1)/2] : int((a[n/2] + a[n/2+1]) / 2 + 0.5)
    }
    !($7 in seen) { seen[$7] = 1; order[++k] = $7 }
    $1 == 1 { ft[$7] = $3; fT[$7] = $4; next }
    { rt[$7] = rt[$7] " " $3; rT[$7] = rT[$7] " " $4 }
    END {
      for (i = 1; i <= k; i++) {
        u = order[i]
        print "summary", ft[u], fT[u], median(rt[u]), median(rT[u]), u
      }
    }'
}

## Entry

probe() {  # <runs> <url>...
  local runs="$1" dir rows run
  shift
  dir=$(mktemp -d)
  rows=$(for run in $(seq 1 "$runs"); do fire_set "$run" "$dir" "$@"; done \
    | to_rows)
  rm -rf "$dir"
  printf '%s\n' "$rows"
  summarise <<<"$rows"
  ! awk -F'\t' '$2 == "000"' <<<"$rows" | grep -q .
}

self_test() {
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  local dir port pid out
  dir=$(mktemp -d)
  head -c 5000 /dev/zero >"$dir/a"
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("", 0));
print(s.getsockname()[1])')
  python3 -m http.server "$port" -b 127.0.0.1 -d "$dir" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/a" && break
    sleep 0.1
  done
  out=$(probe 3 "http://127.0.0.1:$port/a" "http://127.0.0.1:$port/b" || true)
  kill "$pid"
  rm -rf "$dir"
  local calls first_a last_b order median refused=0
  calls=$(grep -cv '^summary' <<<"$out")
  first_a=$(grep -c $'^1\t200\t[0-9]*\t[0-9]*\t5000\t-\thttp.*/a$' <<<"$out")
  last_b=$(grep -c $'^3\t404\t.*/b$' <<<"$out")
  order=$(grep '^summary' <<<"$out" | cut -f6 | sed 's|.*/||' | tr -d '\n')
  median=$(printf '%s\n' $'1\t200\t0\t0\t0\t-\tu' $'2\t200\t10\t1\t0\t-\tu' \
    $'3\t200\t21\t2\t0\t-\tu' | summarise | cut -f4)
  probe 1 "http://127.0.0.1:1/x" >/dev/null || refused=1
  tap_run "six call rows, run 1..3" [ "$calls" = 6 ]
  tap_run "status, bytes and encoding per call" [ "$first_a" = 1 ]
  tap_run "a missing route reports its status, not an error" [ "$last_b" = 1 ]
  tap_run "one summary per url, in url order" [ "$order" = ab ]
  tap_run "the median of an even list rounds the midpoint" [ "$median" = 16 ]
  tap_run "a refused connection exits 1" [ "$refused" = 1 ]
}

main() {
  local runs=3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
        exit 0 ;;
      --self-test) self_test; tap_end ;;
      --runs) runs="${2:?--runs needs a number}"; shift 2 ;;
      -*) echo "route_latency: unknown flag $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  [[ "$runs" =~ ^[1-9][0-9]*$ && "$#" -gt 0 ]] || {
    echo "usage: route_latency.sh [--runs N] <url>..." >&2
    exit 2
  }
  probe "$runs" "$@"
}

main "$@"
