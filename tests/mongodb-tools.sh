#!/bin/bash
#
# Tests a package of the MongoDB Database Tools in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus. The tools get an empty HOME. So the files of the user have no
# effect on the test. The test checks the license files and the version of mongodump and
# mongorestore. It starts no MongoDB server and opens no connection:
#
#   tests/mongodb-tools.sh /tmp/nexus-build/out/mongodb-tools-100.20.1-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/mongodb-tools.sh <archive>}"
base="$(mktemp -d)"
trap 'rm -rf "$base"' EXIT

mkdir -p "$base/Nexus Test" "$base/home"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/mongodb-tools-*)"
version="${root##*/mongodb-tools-}"

grep -q "Apache License" "$root/licenses/mongodb-tools.txt" || { echo "error: the package has no Apache license" >&2; exit 1; }
grep -q "License notice for" "$root/licenses/mongodb-tools-third-party-notices.txt" || { echo "error: the package has no notices of the Go modules" >&2; exit 1; }
[ "$(grep -cE ' [0-9a-f]{64} ' "$root/SOURCE")" = 1 ] || { echo "error: SOURCE does not name the archive of the tools" >&2; exit 1; }

for tool in mongodump mongorestore; do
    output="$(HOME="$base/home" "$root/bin/$tool" --version)"
    echo "==> $(head -1 <<< "$output")"

    case "$output" in
        *"$tool version: $version"*) ;;
        *) echo "error: the binary is not $tool $version" >&2; exit 1 ;;
    esac
done

echo "==> all MongoDB Database Tools tests passed"
