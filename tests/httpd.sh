#!/bin/bash
#
# Tests an Apache httpd package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus:
#
#   tests/httpd.sh /tmp/nexus-build/out/httpd-2.4.69-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/httpd.sh <archive>}"
base="$(mktemp -d)"
trap 'kill "$(cat "$root/logs/httpd.pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$base"' EXIT

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/httpd-*)"
httpd="$root/bin/httpd"
mkdir -p "$root/logs" "$root/test-docs"

echo "==> $("$httpd" -v | head -1)"

# Modules that other modules need come first. Only one MPM can load, and mod_cgid replaces
# mod_cgi under the event MPM.
first="mod_unixd mod_authn_core mod_authz_core mod_watchdog mod_proxy mod_dav mod_cache
mod_session mod_socache_shmcb mod_slotmem_shm mod_proxy_balancer mod_xml2enc mod_mpm_event"

port=$((20000 + RANDOM % 20000))
printf 'Nexus test page. Nexus test page. Nexus test page. Nexus test page.\n' > "$root/test-docs/index.txt"

{
    for module in $first; do
        echo "LoadModule ${module#mod_}_module modules/$module.so"
    done
    for file in "$root"/modules/*.so; do
        module="$(basename "$file" .so)"
        case " $(echo $first) " in *" $module "*) continue ;; esac
        case "$module" in
            mod_mpm_*|mod_cgi) continue ;;
        esac
        echo "LoadModule ${module#mod_}_module modules/$module.so"
    done

    cat <<EOF
ServerRoot "$root"
ServerName localhost
Listen 127.0.0.1:$port
PidFile logs/httpd.pid
ErrorLog logs/error.log
LogLevel warn
DocumentRoot "$root/test-docs"
Protocols h2c http/1.1
TypesConfig conf/mime.types
AddOutputFilterByType BROTLI_COMPRESS text/plain
Header set X-Nexus-Test ok
RewriteEngine on
RewriteRule ^/old$ /index.txt [R=302,L]

<Directory "$root/test-docs">
    Require all granted
</Directory>
EOF
} > "$root/conf/test.conf"

echo "==> httpd -t with $(grep -c '^LoadModule' "$root/conf/test.conf") modules"
"$httpd" -d "$root" -f conf/test.conf -t

echo "==> start httpd on port $port"
"$httpd" -d "$root" -f conf/test.conf -k start
sleep 1

headers="$(curl -fsS -D - -o /dev/null -H 'Accept-Encoding: br' "http://127.0.0.1:$port/index.txt")"
echo "$headers" | grep -qi "^HTTP/1.1 200" || { echo "$headers"; echo "error: no 200 response" >&2; exit 1; }
echo "$headers" | grep -qi "^X-Nexus-Test: ok" || { echo "$headers"; echo "error: mod_headers did not set the header" >&2; exit 1; }
echo "$headers" | grep -qi "^Content-Encoding: br" || { echo "$headers"; echo "error: mod_brotli did not compress the response" >&2; exit 1; }

redirect="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "http://127.0.0.1:$port/old")"
case "$redirect" in
    "302 http://127.0.0.1:$port/index.txt") ;;
    *) echo "error: mod_rewrite gave $redirect" >&2; exit 1 ;;
esac

version="$(curl -sS -o /dev/null -w '%{http_version}' --http2-prior-knowledge "http://127.0.0.1:$port/index.txt")"
[ "$version" = "2" ] || { echo "error: mod_http2 answered with HTTP/$version" >&2; exit 1; }

"$httpd" -d "$root" -f conf/test.conf -k stop

echo "==> all httpd tests passed"
