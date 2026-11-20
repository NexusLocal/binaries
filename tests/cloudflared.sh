#!/bin/bash
#
# Tests a cloudflared package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus. cloudflared gets an empty HOME. So a cloudflared of the
# user and its files in ~/.cloudflared have no effect on the test. The test opens no tunnel and
# no port:
#
#   tests/cloudflared.sh /tmp/nexus-build/out/cloudflared-2026.11.0-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/cloudflared.sh <archive>}"
base="$(mktemp -d)"
trap 'rm -rf "$base"' EXIT

mkdir -p "$base/Nexus Test" "$base/home"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/cloudflared-*)"
version="${root##*/cloudflared-}"

grep -q "Apache License" "$root/licenses/cloudflared.txt" || { echo "error: the package has no Apache license" >&2; exit 1; }
[ "$(grep -cE ' [0-9a-f]{64} ' "$root/SOURCE")" = 2 ] || { echo "error: SOURCE does not name the binary and the source archive" >&2; exit 1; }

output="$(HOME="$base/home" "$root/bin/cloudflared" --version)"
echo "==> $output"

case "$output" in
    *"$version"*) ;;
    *) echo "error: the binary is not cloudflared $version" >&2; exit 1 ;;
esac

HOME="$base/home" "$root/bin/cloudflared" tunnel --help > /dev/null

echo "==> all cloudflared tests passed"
