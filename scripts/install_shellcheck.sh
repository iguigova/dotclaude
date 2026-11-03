#!/usr/bin/env bash
# install_shellcheck.sh — put the pinned shellcheck binary on PATH.
#
# Usage:
#   install_shellcheck.sh [--dir <bindir>]   # default ~/.local/bin
#   install_shellcheck.sh --self-test
#
# selftest.sh treats a missing shellcheck as a FAIL, because a lint that does not
# run is indistinguishable from a lint that found nothing. This is the one
# command that clears it, on a machine with no root: the release tarball is a
# static binary, so nothing is built and nothing is installed system-wide.
#
# The download is verified against SHA256 below, which is not an upstream
# publication — koalaman publishes no checksums with the release. It is the
# digest of the bytes GitHub served over HTTPS on 2026-09-18, recorded here so
# that a later download of different bytes fails loudly instead of installing
# whatever arrives. Re-pin deliberately, never by pasting in whatever mismatched.
#
# Only x86_64 carries a pin. Another architecture exits 3 rather than install
# unverified: an unchecked binary is worse than an absent one, which at least
# fails honestly.

set -euo pipefail

VERSION=v0.10.0
SHA256_linux_x86_64=6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87
BINDIR="${HOME}/.local/bin"

url_for() {  # <os> <arch>
  printf 'https://github.com/koalaman/shellcheck/releases/download/%s/shellcheck-%s.%s.%s.tar.xz' \
    "$VERSION" "$VERSION" "$1" "$2"
}

if [[ "${1:-}" == "--self-test" ]]; then
  # shellcheck source=tap.sh
  . "$(dirname "${BASH_SOURCE[0]}")/tap.sh"
  tap_like "VERSION is a pinned release tag" "$VERSION" "v[0-9]*.[0-9]*.[0-9]*"
  tap_run "the x86_64 pin is a sha256" grep -qxE '[0-9a-f]{64}' <<<"$SHA256_linux_x86_64"
  tap_like "url_for builds the documented asset name" "$(url_for linux x86_64)" \
    "*/download/$VERSION/shellcheck-$VERSION.linux.x86_64.tar.xz"
  # An installed shellcheck that is not the pinned one means the lint everyone
  # shares is not the lint this pin describes — the drift the pin exists to catch.
  have=$(shellcheck --version 2>/dev/null | awk '/^version:/ {print "v" $2}')
  tap_is "the installed shellcheck is the pinned one" "$have" "$VERSION"
  tap_end
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) BINDIR="${2:?--dir needs a path}"; shift 2 ;;
    *) echo "Usage: $0 [--dir <bindir>] | --self-test" >&2; exit 1 ;;
  esac
done

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
sha_var="SHA256_${os}_${arch}"
want="${!sha_var:-}"
if [[ -z "$want" ]]; then
  echo "no pinned checksum for $os.$arch — refusing to install an unverified binary" >&2
  echo "add one to $0 after verifying it, or install shellcheck from your package manager" >&2
  exit 3
fi

if command -v shellcheck >/dev/null 2>&1 \
   && [[ "$(shellcheck --version | awk '/^version:/ {print "v" $2}')" == "$VERSION" ]]; then
  echo "shellcheck $VERSION already on PATH at $(command -v shellcheck)"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/sc.tar.xz" "$(url_for "$os" "$arch")"
got=$(sha256sum "$tmp/sc.tar.xz" | cut -d' ' -f1)
if [[ "$got" != "$want" ]]; then
  echo "checksum mismatch for shellcheck $VERSION $os.$arch" >&2
  echo "  pinned:   $want" >&2
  echo "  received: $got" >&2
  exit 4
fi
tar -xJf "$tmp/sc.tar.xz" -C "$tmp"
mkdir -p "$BINDIR"
install -m 755 "$tmp/shellcheck-$VERSION/shellcheck" "$BINDIR/shellcheck"
echo "installed shellcheck $VERSION -> $BINDIR/shellcheck"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "note: $BINDIR is not on PATH — add it, or selftest.sh will still report shellcheck missing" ;;
esac
