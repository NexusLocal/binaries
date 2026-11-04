#!/bin/bash
#
# Tests a Mailpit package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus. It starts Mailpit with the arguments of Nexus, sends one
# mail with the sendmail mode of Mailpit, and reads it back from the API with its tag:
#
#   tests/mailpit.sh /tmp/nexus-build/out/mailpit-1.33.0-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/mailpit.sh <archive>}"
base="$(mktemp -d)"
smtp=$((20000 + RANDOM % 10000))
web=$((30000 + RANDOM % 10000))
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2> /dev/null; rm -rf "$base"' EXIT

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/mailpit-*)"
mkdir -p "$root/data"

echo "==> $("$root/bin/mailpit" version)"

"$root/bin/mailpit" --smtp "127.0.0.1:$smtp" --listen "127.0.0.1:$web" --database "$root/data/mailpit.db" \
    --smtp-auth-accept-any --smtp-auth-allow-insecure --tags-username --disable-version-check \
    > "$root/data/mailpit.log" 2>&1 &
pid=$!

for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$web/api/v1/messages" > /dev/null 2>&1 && break
    sleep 0.2
done

printf 'From: shop@example.com\nTo: customer@example.com\nSubject: Nexus test\n\nHello\n' |
    "$root/bin/mailpit" sendmail -S "127.0.0.1:$smtp" -t

sleep 1
subject="$(curl -fsS "http://127.0.0.1:$web/api/v1/messages" | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["messages"][0]["Subject"])')"
[ "$subject" = "Nexus test" ] || { echo "error: the inbox has no test mail" >&2; cat "$root/data/mailpit.log" >&2; exit 1; }

echo "==> all Mailpit tests passed"
