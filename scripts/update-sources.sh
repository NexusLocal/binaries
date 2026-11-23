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
#   - Go: the JSON of the downloads on go.dev
#   - MongoDB and the MongoDB Database Tools: full.json of the downloads on downloads.mongodb.org
#   - PostGIS: the .md5 file next to the archive, and the SHA-256 of two downloads
#
# Some sources have no upstream checksum: PECL, MySQL, nginx, GNU, FreeType, libpng, libwebp,
# OpenLDAP, pkgconf, GEOS and the archives of GitHub tags and commits. Such a source is downloaded twice.
# Both downloads must give the same SHA-256.
#
# A package with a source archive of its own (<name>-source) gets both in one update.
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

source "$root/lib/download.sh"

first_hex() {
    grep -oE '[0-9a-f]{64}' | sed -n 1p
}

fetch() {
    download_file "$1" "$2"
}

# The SHA-256 that upstream publishes for a file, or nothing. A WordPress archive gets its SHA-1
# with the prefix sha1:, and a PostGIS archive gets its MD5 with the prefix md5:. full.json of
# MongoDB can name one file two times. Two different checksums give two lines, and then the check
# fails.
upstream_checksum() {
    local url="$1" version="$2" file="${1##*/}" repo tag

    case "$url" in
        https://github.com/*/releases/download/*)
            repo="$(echo "$url" | cut -d/ -f4-5)"
            tag="$(echo "$url" | cut -d/ -f8)"
            try_twice gh api "repos/$repo/releases/tags/$tag" --jq ".assets[] | select(.name == \"$file\") | .digest" 2>/dev/null | sed 's/^sha256://'
            ;;
        https://nodejs.org/dist/*)
            read_url --max-time 60 "${url%/*}/SHASUMS256.txt" | awk -v file="$file" '$2 == file { print $1 }'
            ;;
        https://www.php.net/distributions/*)
            read_url --max-time 60 "https://www.php.net/releases/index.php?json&version=$version" | jq -r --arg file "$file" '.source[]? | select(.filename == $file) | .sha256'
            ;;
        https://ftp.postgresql.org/* | https://archive.apache.org/*)
            read_url --max-time 60 "$url.sha256" | first_hex
            ;;
        https://archive.mariadb.org/*)
            read_url --max-time 60 "${url%/*}/sha256sums.txt" | grep -E " \*?$file\$" | first_hex
            ;;
        https://download.redis.io/*)
            read_url --max-time 60 https://raw.githubusercontent.com/redis/redis-hashes/master/README | grep " $file " | first_hex
            ;;
        https://getcomposer.org/*)
            read_url --max-time 60 "$url.sha256sum" | first_hex
            ;;
        https://downloads.wordpress.org/*)
            read_url --max-time 60 "$url.sha1" | grep -oE '[0-9a-f]{40}' | sed -n '1s/^/sha1:/p'
            ;;
        https://download.osgeo.org/postgis/*)
            read_url --max-time 60 "$url.md5" | grep -oE '[0-9a-f]{32}' | sed -n '1s/^/md5:/p'
            ;;
        https://go.dev/dl/*)
            read_url --max-time 60 'https://go.dev/dl/?mode=json&include=all' | jq -r --arg file "$file" '.[].files[] | select(.filename == $file) | .sha256'
            ;;
        https://fastdl.mongodb.org/tools/db/*)
            read_url --max-time 60 https://downloads.mongodb.org/tools/db/full.json | jq -r --arg url "$url" '[.versions[].downloads[]? | select(.archive.url == $url) | .archive.sha256] | unique | .[]'
            ;;
        https://fastdl.mongodb.org/osx/*)
            read_url --max-time 120 https://downloads.mongodb.org/full.json | jq -r --arg url "$url" '[.versions[].downloads[]? | select(.archive.url == $url) | .archive.sha256] | unique | .[]'
            ;;
    esac
}

# Downloads the new version of one source and checks it against the checksum of upstream. Prints
# the new line of sources.lock, a tab and the method of the check. A failure goes to the summary
# and prints nothing.
checked_line() {
    local name="$1" current="$2" newest="$3" url new_url file sha256 expected method commit

    url="$(awk -v name="$name" '$1 == name { print $4 }' "$lock")"
    new_url="${url//$current/$newest}"

    # The URL of a project without releases has the whole commit. Its version is only the start.
    if [[ "$url" =~ /archive/([0-9a-f]{40})\. ]]; then
        commit="$(try_twice gh api "repos/$(echo "$url" | cut -d/ -f4-5)/commits/$newest" --jq .sha 2>/dev/null | grep -xE '[0-9a-f]{40}')"

        if [ -z "$commit" ]; then
            echo "- failed: $name $newest. The commit could not be read." >> "$summary"
            return
        fi

        new_url="${url/${BASH_REMATCH[1]}/$commit}"
    fi

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
        md5:*)
            if [ "$(openssl dgst -md5 "$file" | awk '{ print $NF }')" != "${expected#md5:}" ]; then
                echo "- failed: $name $newest. The MD5 is not the MD5 of upstream." >> "$summary"
                return
            fi

            if ! fetch "$new_url" "$file.second" || [ "$(shasum -a 256 "$file.second" | cut -d' ' -f1)" != "$sha256" ]; then
                echo "- failed: $name $newest. Two downloads gave a different file." >> "$summary"
                return
            fi
            method="the MD5 of upstream, two downloads were the same"
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

    printf '%s %s %s %s\t%s\n' "$name" "$newest" "$sha256" "$new_url" "$method"
}

replace_line() {
    awk -v name="$1" -v line="$2" '$1 == name { print line; next } { print }' "$lock" > "$work/sources.lock"
    cat "$work/sources.lock" > "$lock"
}

update_source() {
    local name="$1" current="$2" newest="$3" result source_current source_result

    # These packages have one line that follows the newest release. A new major version is a new
    # line, and scripts/check-lines.sh reports it. A new major version of a PECL extension can drop a
    # PHP version or break the library of a site. cloudflared is not in this list. Its version starts
    # with the year. Its one line 1 takes each release.
    case "$name" in
        mailpit | composer | wp-cli | redis-8 | pecl-*)
            if [ "${newest%%.*}" != "${current%%.*}" ]; then
                echo "- $name: $newest is a new major version. It needs the choice of the owner." >> "$summary"
                return
            fi
            ;;
    esac

    if [ -z "$(awk -v name="$name" '$1 == name { print $4 }' "$lock")" ]; then
        echo "- $name: not in sources.lock, so nothing changed" >> "$summary"
        return
    fi

    result="$(checked_line "$name" "$current" "$newest")"
    [ -n "$result" ] || return

    # A package with a source archive of its own (MySQL, Mailpit and cloudflared) gets both in one
    # update.
    # So the SOURCE file of the package always names the source of the same version. The source
    # line can have an older version than its package. So the new URL starts from its own version.
    source_current="$(awk -v name="$name-source" '$1 == name { print $2 }' "$lock")"

    if [ -n "$source_current" ] && [ "$source_current" != "$newest" ]; then
        source_result="$(checked_line "$name-source" "$source_current" "$newest")"
        [ -n "$source_result" ] || return
        replace_line "$name-source" "${source_result%%$'\t'*}"
    fi

    replace_line "$name" "${result%%$'\t'*}"
    echo "- $name: $current -> $newest (${result#*$'\t'})" >> "$summary"
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
