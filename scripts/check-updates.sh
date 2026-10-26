#!/bin/bash
#
# Compares the versions in sources.lock with the newest upstream release of the same version
# line, and prints one line for each source that has a newer release:
#
#   scripts/check-updates.sh
#
# It changes nothing. A new version needs a new pinned SHA-256 in sources.lock, and a person
# checks that against the upstream checksum.
#
# Needs curl and jq.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pinned() {
    awk -v name="$1" '$1 == name { print $2 }' "$root/sources.lock"
}

report() {
    local name="$1" newest="$2" current
    current="$(pinned "$name")"

    if [ -z "$newest" ] || [ "$newest" = "null" ]; then
        echo "- $name: the newest version could not be read"
        return
    fi

    if [ "$current" != "$newest" ]; then
        echo "- $name: $current -> $newest"
    elif [ "${NEXUS_SHOW_ALL:-}" = "1" ]; then
        echo "  $name: $current is the newest"
    fi
}

endoflife_latest() {
    curl -fsS --max-time 30 "https://endoflife.date/api/$1.json" | jq -r --arg cycle "$2" '.[] | select(.cycle == $cycle) | .latest'
}

github_latest() {
    curl -fsS --max-time 30 "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name | sed -E "s/^${2:-v}//"
}

pecl_latest() {
    curl -fsS --max-time 30 "https://pecl.php.net/rest/r/$1/stable.txt"
}

node_latest() {
    curl -fsS --max-time 30 https://nodejs.org/dist/index.json | jq -r --arg major "v$1." '[.[] | select(.version | startswith($major))][0].version' | sed 's/^v//'
}

for line in 8.2 8.3 8.4 8.5; do report "php-$line" "$(endoflife_latest php "$line")"; done
for line in 8.0 8.4 9.7; do report "mysql-$line" "$(endoflife_latest mysql "$line")"; done
for line in 10.11 11.4 11.8 12.3; do report "mariadb-$line" "$(endoflife_latest mariadb "$line")"; done
for line in 14 15 16 17 18; do report "postgresql-$line" "$(endoflife_latest postgresql "$line")"; done
report redis-7.2 "$(endoflife_latest redis 7.2)"
report redis-8.2 "$(endoflife_latest redis 8.2)"
report redis-8 "$(github_latest redis/redis "")"
report nginx "$(endoflife_latest nginx "$(pinned nginx | cut -d. -f1-2)")"
report httpd "$(endoflife_latest apache-http-server 2.4)"
report openssl "$(endoflife_latest openssl 3.5)"
for line in 22 24 26; do report "node-$line" "$(node_latest "$line")"; done
report composer "$(curl -fsS --max-time 30 https://getcomposer.org/versions | jq -r '.stable[0].version')"

report pcre2 "$(github_latest PCRE2Project/pcre2 pcre2-)"
report zlib "$(github_latest madler/zlib)"
report brotli "$(github_latest google/brotli)"
report nghttp2 "$(github_latest nghttp2/nghttp2)"
report libmaxminddb "$(github_latest maxmind/libmaxminddb "")"
report geoip2 "$(github_latest leev/ngx_http_geoip2_module "")"
report njs "$(github_latest nginx/njs "")"
report libsodium "$(github_latest jedisct1/libsodium "" | sed 's/-RELEASE$//')"
report libzip "$(github_latest nih-at/libzip)"
report libjpeg-turbo "$(github_latest libjpeg-turbo/libjpeg-turbo "")"
report oniguruma "$(github_latest kkos/oniguruma)"
report libyaml "$(github_latest yaml/libyaml "")"
report imagemagick "$(github_latest ImageMagick/ImageMagick "")"
report cmake "$(github_latest Kitware/CMake)"
report ninja "$(github_latest ninja-build/ninja)"
for extension in xdebug pcov redis apcu yaml imagick; do report "pecl-$extension" "$(pecl_latest "$extension")"; done
