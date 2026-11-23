#!/bin/bash
#
# Prints one line for each new version line upstream that Nexus does not offer yet, for example
# PHP 8.6, Node.js 27 or Mailpit 2:
#
#   scripts/check-lines.sh
#
# A new line needs a choice of the owner (D12 in the Nexus decision record), so the update
# workflow opens an issue for it and changes nothing. Old lines that Nexus left out on purpose
# do not count: only a line newer than the newest line of support.lock does. MySQL and MariaDB
# count only with a long-term support release, because their other releases come each quarter.
# MongoDB counts only with a new major version such as 10.0, because Nexus offers only its major
# lines. cloudflared has no report here. Its one line 1 takes each release, also in a new year. A
# library and the MongoDB Database Tools count with a line newer than their line in sources.lock.
#
# Needs curl and jq. It uses GH_TOKEN for the GitHub API when it is set.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/upstream.sh"

newest_known() {
    awk -v name="$1" '$1 == name { print $2 }' "$root/support.lock" | sort -V | tail -1
}

# endoflife.date product, the name in support.lock, the title, and a filter:
#   lts     only long-term support lines
#   major   only a new major version, because a Redis line follows the newest minor version and
#           Nexus offers only the major lines of MongoDB
#   stable  only an even minor version, because an odd one is the mainline of nginx
report_cycles() {
    local product="$1" name="$2" title="$3" filter="${4:-}" known cycles
    known="$(newest_known "$name")"
    cycles="$(curl -fsS --max-time 30 "https://endoflife.date/api/$product.json" | jq -r --arg filter "$filter" \
        '.[] | select($filter != "lts" or (.lts != false)) | .cycle')"

    for cycle in $cycles; do
        case "$filter" in
            major)
                [ "${cycle%%.*}" -gt "${known%%.*}" ] 2>/dev/null && echo "- $title ${cycle%%.*}"
                ;;
            stable)
                [ $(( $(echo "$cycle" | cut -d. -f2) % 2 )) -eq 0 ] && [ -n "$known" ] && newer "$cycle" "$known" && echo "- $title $cycle"
                ;;
            *)
                [ -n "$known" ] && newer "$cycle" "$known" && echo "- $title $cycle"
                ;;
        esac
    done | sort -u
}

# A GitHub release with a new major version, for a package with one line.
report_major() {
    local repo="$1" name="$2" title="$3" prefix="${4:-v}" known latest
    known="$(newest_known "$name")"
    latest="$(github_api "repos/$repo/releases/latest" | jq -r .tag_name | sed -E "s/^$prefix//")"

    if [ -n "$latest" ] && [ "$latest" != "null" ] && [ "${latest%%.*}" -gt "${known%%.*}" ] 2>/dev/null; then
        echo "- $title ${latest%%.*}"
    fi
}

# The source name in sources.lock, the title, the number of fields in its version line and the
# newest version of all lines.
report_library() {
    local known newest
    known="$(pinned_line "$1" "$3")"
    newest="$(echo "$4" | cut -d. -f"1-$3")"

    if [ -n "$known" ] && [ -n "$newest" ] && newer "$newest" "$known"; then
        echo "- $2 $newest"
    fi
}

report_cycles php php PHP
report_cycles mysql mysql MySQL lts
report_cycles mariadb mariadb MariaDB lts
report_cycles postgresql postgresql PostgreSQL
report_cycles mongodb mongodb MongoDB major
report_cycles nodejs node Node.js
report_cycles redis redis Redis major
report_cycles nginx nginx nginx stable
report_cycles apache-http-server httpd "Apache httpd"
report_major axllent/mailpit mailpit Mailpit
report_major wp-cli/wp-cli wp-cli WP-CLI
report_major composer/composer composer Composer ""
report_library icu ICU 1 "$(github_latest unicode-org/icu release-)"
report_library libpng libpng 2 "$(github_line_tag pnggroup/libpng v)"
report_library libwebp libwebp 1 "$(github_latest_tag webmproject/libwebp)"
report_library freetype FreeType 1 "$(listed_latest https://download.savannah.gnu.org/releases/freetype/ freetype)"
report_library gettext gettext 1 "$(listed_latest https://ftp.gnu.org/gnu/gettext/ gettext)"
report_library openldap OpenLDAP 2 "$(listed_latest https://www.openldap.org/software/download/OpenLDAP/openldap-release/ openldap)"
report_library postgis PostGIS 2 "$(listed_latest https://download.osgeo.org/postgis/source/ postgis)"
report_library pgrouting pgRouting 2 "$(github_latest pgRouting/pgrouting)"
report_library geos GEOS 1 "$(listed_latest https://download.osgeo.org/geos/ geos)"
report_library proj PROJ 1 "$(github_latest OSGeo/PROJ "")"
report_library json-c json-c 1 "$(json_c_latest | tail -1)"
report_library protobuf-c protobuf-c 2 "$(github_latest protobuf-c/protobuf-c)"
report_library apr APR 2 "$(listed_latest https://archive.apache.org/dist/apr/ apr)"
report_library apr-util APR-util 2 "$(listed_latest https://archive.apache.org/dist/apr/ apr-util)"
report_library headers-more headers-more 1 "$(github_latest_tag openresty/headers-more-nginx-module)"
report_library mongodb-tools "MongoDB Database Tools" 1 "$(mongodb_tools_latest)"
report_library pkgconf pkgconf 1 "$(listed_latest https://distfiles.ariadne.space/pkgconf/ pkgconf)"
report_library m4 m4 1 "$(listed_latest https://ftp.gnu.org/gnu/m4/ m4)"
report_library autoconf autoconf 1 "$(listed_latest https://ftp.gnu.org/gnu/autoconf/ autoconf)"
