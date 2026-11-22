#!/bin/bash
#
# Compares the versions in sources.lock with the newest upstream release of the same version
# line, and prints one line for each source that has a newer release:
#
#   scripts/check-updates.sh
#
# It changes nothing. scripts/update-sources.sh reads this list and updates sources.lock after a
# check of each download against the checksum of upstream.
#
# Needs curl and jq. It uses GH_TOKEN for the GitHub API when it is set.

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

# Without a token, GitHub accepts 60 API requests an hour from one address. The runners of GitHub
# Actions share their addresses. So a request can get "403 Forbidden" before the run made 60. The
# token of the workflow has its own limit of 1,000 requests an hour.
github_api() {
    if [ -n "${GH_TOKEN:-}" ]; then
        curl -fsS --max-time 30 -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/$1"
        return
    fi

    curl -fsS --max-time 30 "https://api.github.com/$1"
}

github_latest() {
    github_api "repos/$1/releases/latest" | jq -r .tag_name | sed -E "s/^${2:-v}//"
}

# For a project that has tags such as v0.8.7 and no releases.
github_latest_tag() {
    github_api "repos/$1/tags?per_page=100" | jq -r '.[].name' | sed -nE 's/^v([0-9]+(\.[0-9]+)+)$/\1/p' | sort -V | tail -1
}

pecl_latest() {
    curl -fsS --max-time 30 "https://pecl.php.net/rest/r/$1/stable.txt"
}

node_latest() {
    curl -fsS --max-time 30 https://nodejs.org/dist/index.json | jq -r --arg major "v$1." '[.[] | select(.version | startswith($major))][0].version' | sed 's/^v//'
}

# The newest fmt that cmake/libfmt.cmake of a MariaDB release names. products/mariadb.sh reads
# the same version. The older version in that file is for an old GCC.
mariadb_fmt() {
    curl -fsS --max-time 30 "https://raw.githubusercontent.com/MariaDB/server/mariadb-$1/cmake/libfmt.cmake" |
        grep -oE 'fmtlib/fmt/releases/download/[0-9.]+/' | cut -d/ -f5 | sort -V | tail -1
}

for line in 8.2 8.3 8.4 8.5; do report "php-$line" "$(endoflife_latest php "$line")"; done
for line in 8.0 8.4 9.7; do report "mysql-$line" "$(endoflife_latest mysql "$line")"; done

# The build of MariaDB stops when fmt in sources.lock is not the fmt of the MariaDB release. So
# fmt gets the newest version that the newest release of a MariaDB line names, in the same update
# as MariaDB. When one release could not be read, fmt is not updated.
fmt_named=""
for line in 10.11 11.4 11.8 12.3; do
    newest="$(endoflife_latest mariadb "$line")"
    report "mariadb-$line" "$newest"
    named="$(mariadb_fmt "$newest")"

    if [ -z "$named" ]; then
        fmt_named="unknown"
    elif [ "$fmt_named" != "unknown" ]; then
        fmt_named="$fmt_named $named"
    fi
done
[ "$fmt_named" != "unknown" ] || fmt_named=""
report fmt "$(printf '%s\n' $fmt_named | sort -V | tail -1)"
for line in 14 15 16 17 18 19; do report "postgresql-$line" "$(endoflife_latest postgresql "$line")"; done
report redis-7.2 "$(endoflife_latest redis 7.2)"
report redis-8.2 "$(endoflife_latest redis 8.2)"
report redis-8 "$(github_latest redis/redis "")"
report nginx "$(endoflife_latest nginx "$(pinned nginx | cut -d. -f1-2)")"
report httpd "$(endoflife_latest apache-http-server 2.4)"
report openssl "$(endoflife_latest openssl 3.5)"
for line in 22 24 26; do report "node-$line" "$(node_latest "$line")"; done
report composer "$(curl -fsS --max-time 30 https://getcomposer.org/versions | jq -r '.stable[0].version')"
report mailpit "$(github_latest axllent/mailpit)"
report cloudflared "$(github_latest cloudflare/cloudflared "")"
report wp-cli "$(github_latest wp-cli/wp-cli)"
report wordpress "$(curl -fsS --max-time 30 https://api.wordpress.org/core/version-check/1.7/ | jq -r '.offers[0].version')"
report sqlite-database-integration "$(curl -fsS --max-time 30 https://api.wordpress.org/plugins/info/1.0/sqlite-database-integration.json | jq -r .version)"

report pcre2 "$(github_latest PCRE2Project/pcre2 pcre2-)"
report zlib "$(github_latest madler/zlib)"
report brotli "$(github_latest google/brotli)"
report nghttp2 "$(github_latest nghttp2/nghttp2)"
report libmaxminddb "$(github_latest maxmind/libmaxminddb "")"
report geoip2 "$(github_latest leev/ngx_http_geoip2_module "")"
report njs "$(github_latest nginx/njs "")"
report pgvector "$(github_latest_tag pgvector/pgvector)"
report libsodium "$(github_latest jedisct1/libsodium "" | sed 's/-RELEASE$//')"
report libzip "$(github_latest nih-at/libzip)"
report libjpeg-turbo "$(github_latest libjpeg-turbo/libjpeg-turbo "")"
report oniguruma "$(github_latest kkos/oniguruma)"
report libyaml "$(github_latest yaml/libyaml "")"
report imagemagick "$(github_latest ImageMagick/ImageMagick "")"
report cmake "$(github_latest Kitware/CMake)"
report ninja "$(github_latest ninja-build/ninja)"
report go "$(curl -fsS --max-time 30 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//')"
for extension in xdebug pcov redis apcu yaml imagick mailparse; do report "pecl-$extension" "$(pecl_latest "$extension")"; done

# The last day of security fixes in support.lock, against endoflife.date. The LTS flags are not
# compared: endoflife.date gives a date for some of them, and the decision record sets them.
endoflife_end() {
    curl -fsS --max-time 30 "https://endoflife.date/api/$1.json" | jq -r --arg cycle "$2" '.[] | select(.cycle == $cycle) | if .eol == false then "-" else .eol end'
}

report_support() {
    local name="$1" line="$2" newest="$3" current
    current="$(awk -v name="$name" -v line="$line" '$1 == name && $2 == line { print $4 }' "$root/support.lock")"

    if [ -z "$newest" ] || [ "$newest" = "null" ]; then
        echo "- support of $name $line: the end of security fixes could not be read"
        return
    fi

    if [ "$current" != "$newest" ]; then
        echo "- support of $name $line: security fixes end on ${current:-nothing} -> $newest"
    fi
}

for line in 8.2 8.3 8.4 8.5; do report_support php "$line" "$(endoflife_end php "$line")"; done
for line in 8.0 8.4 9.7; do report_support mysql "$line" "$(endoflife_end mysql "$line")"; done
for line in 10.11 11.4 11.8 12.3; do report_support mariadb "$line" "$(endoflife_end mariadb "$line")"; done
for line in 14 15 16 17 18 19; do report_support postgresql "$line" "$(endoflife_end postgresql "$line")"; done
report_support redis 7.2 "$(endoflife_end redis 7.2)"
report_support redis 8.2 "$(endoflife_end redis 8.2)"
report_support redis 8 "$(endoflife_end redis "$(pinned redis-8 | cut -d. -f1-2)")"
report_support nginx "$(pinned nginx | cut -d. -f1-2)" "$(endoflife_end nginx "$(pinned nginx | cut -d. -f1-2)")"
report_support httpd 2.4 "$(endoflife_end apache-http-server 2.4)"
for line in 22 24 26; do report_support node "$line" "$(endoflife_end nodejs "$line")"; done
