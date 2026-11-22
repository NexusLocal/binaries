#!/bin/bash
#
# Tests a Redis package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus:
#
#   tests/redis.sh /tmp/nexus-build/out/redis-8.10.3-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/redis.sh <archive>}"
base="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))
trap '"$root/bin/redis-cli" -p "$port" shutdown nosave > /dev/null 2>&1 || true; rm -rf "$base"' EXIT

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/redis-*)"
mkdir -p "$root/data"

echo "==> $("$root/bin/redis-server" --version)"

"$root/bin/redis-server" --port "$port" --bind 127.0.0.1 --dir "$root/data" --save "" \
    --appendonly no --daemonize yes --logfile "$root/data/redis.log" --databases 64
sleep 1

cli=("$root/bin/redis-cli" -p "$port")

[ "$("${cli[@]}" ping)" = "PONG" ] || { echo "error: redis-server does not answer" >&2; exit 1; }
"${cli[@]}" -n 42 set nexus-test ok > /dev/null
[ "$("${cli[@]}" -n 42 get nexus-test)" = "ok" ] || { echo "error: database 42 does not keep a key" >&2; exit 1; }
[ "$("${cli[@]}" -n 0 get nexus-test)" = "" ] || { echo "error: database 0 sees a key of database 42" >&2; exit 1; }
[ "$("${cli[@]}" config get databases | tail -1)" = "64" ] || { echo "error: databases is not 64" >&2; exit 1; }

licenses="redis redis-source-notices hiredis linenoise lua hdr_histogram hdr_histogram-copying fpconv"
case "$(basename "$root")" in
    redis-7.2.*) ;;
    redis-8.2.*) licenses="$licenses redis-contributions fast_float" ;;
    *) licenses="$licenses redis-contributions fast_float xxhash tre croaring" ;;
esac
missing=""
for name in $licenses; do
    [ -s "$root/licenses/$name.txt" ] || missing="$missing $name"
done
[ -z "$missing" ] || { echo "error: licenses are missing:$missing" >&2; exit 1; }
echo "==> the package has all $(echo $licenses | wc -w | tr -d ' ') license files"

# One author of each library that has its license only in the source files.
for author in "Marc Alexander Lehmann" "Makoto Matsumoto" "Jean-Philippe Aumasson" "Todd C. Miller" \
    "William Ahern" "Mark Adler" "yinqiwen" "Georges Menie" "Harish Mallipeddi" "Matt Stancliff" \
    "zhenwei pi" "Regents of the University of California" "Mark Pulford" "Mike Pall"; do
    grep -q -F "$author" "$root/licenses/redis-source-notices.txt" ||
        { echo "error: the notice of $author is missing" >&2; exit 1; }
done
echo "==> the package has the notices of the source files"

echo "==> all Redis tests passed"
