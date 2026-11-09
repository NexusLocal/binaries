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
#
# Needs curl and jq.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

newest_known() {
    awk -v name="$1" '$1 == name { print $2 }' "$root/support.lock" | sort -V | tail -1
}

newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# endoflife.date product, the name in support.lock, the title, and a filter:
#   lts     only long-term support lines
#   major   only a new major version, because the line follows the newest minor version
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
    latest="$(curl -fsS --max-time 30 "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name | sed -E "s/^$prefix//")"

    if [ -n "$latest" ] && [ "$latest" != "null" ] && [ "${latest%%.*}" -gt "${known%%.*}" ] 2>/dev/null; then
        echo "- $title ${latest%%.*}"
    fi
}

report_cycles php php PHP
report_cycles mysql mysql MySQL lts
report_cycles mariadb mariadb MariaDB lts
report_cycles postgresql postgresql PostgreSQL
report_cycles nodejs node Node.js
report_cycles redis redis Redis major
report_cycles nginx nginx nginx stable
report_cycles apache-http-server httpd "Apache httpd"
report_major axllent/mailpit mailpit Mailpit
report_major wp-cli/wp-cli wp-cli WP-CLI
report_major composer/composer composer Composer ""
