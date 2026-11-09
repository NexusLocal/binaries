#!/bin/bash
#
# Updates sources.lock to the newest upstream release of each source in the same version line,
# and support.lock to the newest end of security fixes:
#
#   GH_TOKEN=... scripts/update-sources.sh <summary file>
#
# It takes the list of scripts/check-updates.sh. For each update it builds the new URL from the
# old one, downloads the file and checks it against the checksum that upstream publishes:
#
#   - a release asset on GitHub: the digest of the asset in the GitHub API
#   - Node.js: SHASUMS256.txt of the release
#   - PHP: the JSON of the release on php.net
#   - PostgreSQL, Apache httpd and APR: the .sha256 file next to the archive
#   - MariaDB: sha256sums.txt of the release
#   - Redis: the redis-hashes repository
#   - Composer: the .sha256sum file next to the phar
#   - WordPress: the .sha1 file next to the archive
#
# A source without an upstream checksum (PECL, MySQL, nginx, GNU and the tag archives of GitHub)
# is downloaded twice, and both downloads must give the same SHA-256.
#
# The summary file gets one line for each update and one line for each update that failed. The
# exit code is 0 also when an update failed, so the other updates still go out.
#
# Needs gh, jq, curl and shasum.

set -uo pipefail

summary="${1:?usage: scripts/update-sources.sh <summary file>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="$root/sources.lock"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: > "$summary"

first_hex() {
    grep -oE '[0-9a-f]{64}' | head -1
}

fetch() {
    curl -fsSL --max-time 600 --retry 4 --retry-connrefused -o "$2" "$1"
}

# The SHA-256 that upstream publishes for a file, or nothing. A WordPress archive gets its SHA-1
# with the prefix sha1:.
upstream_checksum() {
    local url="$1" version="$2" file="${1##*/}" repo tag

    case "$url" in
        https://github.com/*/releases/download/*)
            repo="$(echo "$url" | cut -d/ -f4-5)"
            tag="$(echo "$url" | cut -d/ -f8)"
            gh api "repos/$repo/releases/tags/$tag" --jq ".assets[] | select(.name == \"$file\") | .digest" 2>/dev/null | sed 's/^sha256://'
            ;;
        https://nodejs.org/dist/*)
            curl -fsS --max-time 60 "${url%/*}/SHASUMS256.txt" | awk -v file="$file" '$2 == file { print $1 }'
            ;;
        https://www.php.net/distributions/*)
            curl -fsS --max-time 60 "https://www.php.net/releases/index.php?json&version=$version" | jq -r --arg file "$file" '.source[]? | select(.filename == $file) | .sha256'
            ;;
        https://ftp.postgresql.org/* | https://archive.apache.org/*)
            curl -fsS --max-time 60 "$url.sha256" | first_hex
            ;;
        https://archive.mariadb.org/*)
            curl -fsS --max-time 60 "${url%/*}/sha256sums.txt" | grep -E " \*?$file\$" | first_hex
            ;;
        https://download.redis.io/*)
            curl -fsS --max-time 60 https://raw.githubusercontent.com/redis/redis-hashes/master/README | grep " $file " | first_hex
            ;;
        https://getcomposer.org/*)
            curl -fsS --max-time 60 "$url.sha256sum" | first_hex
            ;;
        https://downloads.wordpress.org/*)
            curl -fsS --max-time 60 "$url.sha1" | grep -oE '[0-9a-f]{40}' | head -1 | sed 's/^/sha1:/'
            ;;
    esac
}

update_source() {
    local name="$1" current="$2" newest="$3" fields url new_url file sha256 expected method

    # These packages have one line that follows the newest release. A new major version is a new
    # line, and scripts/check-lines.sh reports it.
    case "$name" in
        mailpit | composer | wp-cli | redis-8)
            if [ "${newest%%.*}" != "${current%%.*}" ]; then
                echo "- $name: $newest is a new major version. It needs the choice of the owner." >> "$summary"
                return
            fi
            ;;
    esac

    fields="$(awk -v name="$name" '$1 == name' "$lock")"
    url="$(echo "$fields" | awk '{print $4}')"

    if [ -z "$url" ]; then
        echo "- $name: not in sources.lock, so nothing changed" >> "$summary"
        return
    fi

    new_url="${url//$current/$newest}"
    file="$work/$name-${new_url##*/}"

    if [ "$new_url" = "$url" ] || ! fetch "$new_url" "$file"; then
        echo "- failed: $name $newest. The download of $new_url failed." >> "$summary"
        return
    fi

    sha256="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    expected="$(upstream_checksum "$new_url" "$newest")"

    case "$expected" in
        sha1:*)
            if [ "$(shasum -a 1 "$file" | cut -d' ' -f1)" != "${expected#sha1:}" ]; then
                echo "- failed: $name $newest. The SHA-1 is not the SHA-1 of upstream." >> "$summary"
                return
            fi
            method="the SHA-1 of upstream"
            ;;
        "")
            if ! fetch "$new_url" "$file.second" || [ "$(shasum -a 256 "$file.second" | cut -d' ' -f1)" != "$sha256" ]; then
                echo "- failed: $name $newest. Two downloads gave a different file." >> "$summary"
                return
            fi
            method="no upstream checksum, two downloads were the same"
            ;;
        *)
            if [ "$expected" != "$sha256" ]; then
                echo "- failed: $name $newest. The SHA-256 is not the SHA-256 of upstream ($expected)." >> "$summary"
                return
            fi
            method="the SHA-256 of upstream"
            ;;
    esac

    awk -v name="$name" -v line="$name $newest $sha256 $new_url" '$1 == name { print line; next } { print }' "$lock" > "$work/sources.lock"
    cat "$work/sources.lock" > "$lock"
    echo "- $name: $current -> $newest ($method)" >> "$summary"
}

# The last day of security fixes comes from endoflife.date, as scripts/check-updates.sh reads it.
update_support() {
    local name="$1" line="$2" current="$3" newest="$4"

    awk -v name="$name" -v line="$line" -v end="$newest" '$1 == name && $2 == line && !/^#/ { $4 = end } { print }' "$root/support.lock" > "$work/support.lock"
    cat "$work/support.lock" > "$root/support.lock"
    echo "- support of $name $line: security fixes end on $current -> $newest" >> "$summary"
}

"$root/scripts/check-updates.sh" > "$work/check.txt"

sed -nE 's/^- ([^ :]+): ([^ ]+) -> ([^ ]+)$/\1 \2 \3/p' "$work/check.txt" | while read -r name current newest; do
    update_source "$name" "$current" "$newest"
done

sed -nE 's/^- support of ([^ ]+) ([^ ]+): security fixes end on ([^ ]+) -> ([^ ]+)$/\1 \2 \3 \4/p' "$work/check.txt" | while read -r name line current newest; do
    update_support "$name" "$line" "$current" "$newest"
done

grep -E "could not be read" "$work/check.txt" | sed 's/^- /- failed: /' >> "$summary"

cat "$summary"
