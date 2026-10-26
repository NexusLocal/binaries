#!/bin/bash
#
# Tests an nginx package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus:
#
#   tests/nginx.sh /tmp/nexus-build/out/nginx-1.30.6-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/nginx.sh <archive>}"
base="$(mktemp -d)"
trap 'kill "$(cat "$root/logs/nginx.pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$base"' EXIT

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/nginx-*)"
nginx="$root/sbin/nginx"
mkdir -p "$root/logs" "$root/temp"

echo "==> nginx -V"
"$nginx" -V 2>&1 | sed 's/--/\n  --/g' | grep -E "version|built with|http_v3|with-compat|add-dynamic-module" | sed -E 's|=/[^ ]*/work/|=|'

port=$((20000 + RANDOM % 20000))

{
    for module in ngx_stream_module.so ngx_mail_module.so; do
        echo "load_module modules/$module;"
    done
    for module in "$root"/modules/*.so; do
        name="$(basename "$module")"
        case "$name" in
            ngx_stream_module.so|ngx_mail_module.so) ;;
            *) echo "load_module modules/$name;" ;;
        esac
    done

    cat <<EOF
worker_processes 1;
pid logs/nginx.pid;

events {
    worker_connections 64;
}

http {
    include mime.types;
    access_log logs/access.log;
    client_body_temp_path temp/client_body;
    proxy_temp_path temp/proxy;
    fastcgi_temp_path temp/fastcgi;
    uwsgi_temp_path temp/uwsgi;
    scgi_temp_path temp/scgi;

    brotli on;
    brotli_types text/plain;

    server {
        listen 127.0.0.1:$port;
        more_set_headers "X-Nexus-Test: ok";

        location / {
            default_type text/plain;
            return 200 "Nexus test page. Nexus test page. Nexus test page. Nexus test page.\n";
        }
    }
}

stream {
}
EOF
} > "$root/conf/test.conf"

echo "==> nginx -t with $(ls "$root"/modules/*.so | wc -l | tr -d ' ') dynamic modules"
"$nginx" -p "$root/" -c conf/test.conf -e logs/error.log -t

echo "==> start nginx on port $port"
"$nginx" -p "$root/" -c conf/test.conf -e logs/error.log
sleep 1

headers="$(curl -fsS -D - -o /dev/null -H 'Accept-Encoding: br' "http://127.0.0.1:$port/")"
echo "$headers" | grep -qi "^HTTP/1.1 200" || { echo "$headers"; echo "error: no 200 response" >&2; exit 1; }
echo "$headers" | grep -qi "^X-Nexus-Test: ok" || { echo "$headers"; echo "error: headers-more did not set the header" >&2; exit 1; }
echo "$headers" | grep -qi "^Content-Encoding: br" || { echo "$headers"; echo "error: brotli did not compress the response" >&2; exit 1; }

"$nginx" -p "$root/" -c conf/test.conf -e logs/error.log -s quit

echo "==> all nginx tests passed"
