#!/bin/bash
#
# Tests WP-CLI on a PHP package, in a folder with a space in its path. It runs wp --info,
# installs WordPress and reads an option back. The PHP job has no database server. So WordPress
# uses SQLite through the SQLite Database Integration plugin:
#
#   tests/wp-cli.sh /tmp/nexus-build/out/php-8.5.12-macos-arm64.tar.xz
#
# WP-CLI, WordPress and the plugin come from sources.lock. A failed command fails the test. A
# deprecation or a warning of PHP gives a warning in the log of the CI run. The test then passes.

set -euo pipefail

archive="${1:?usage: tests/wp-cli.sh <php archive>}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="$(mktemp -d)"
trap 'rm -rf "$base"' EXIT

lock_field() {
    awk -v name="$1" -v field="$2" '$1 == name { print $field; found = 1 } END { if (!found) exit 1 }' "$repo/sources.lock"
}

download() {
    local name="$1" target="$2" url sha256
    url="$(lock_field "$name" 4)"
    sha256="$(lock_field "$name" 3)"
    curl -fsSL --retry 8 --retry-connrefused -o "$target" "$url"
    echo "$sha256  $target" | shasum -a 256 -c --status || { echo "error: the SHA-256 of $name does not match sources.lock ($url)" >&2; exit 1; }
}

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
php="$(ls -d "$base/Nexus Test"/php-*)/bin/php"
site="$base/Nexus Test/shop"

# WordPress guesses the path of the site URL from the folder of the phar. A phar in a folder above
# the site gives the URL https://shop.test/shop. Nexus keeps the phar in its runtimes folder.
mkdir -p "$base/Nexus Test/runtimes"
phar="$base/Nexus Test/runtimes/wp-cli.phar"

download wp-cli "$phar"
download wordpress "$base/wordpress.zip"
download sqlite-database-integration "$base/sqlite.zip"

export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

wp() {
    if ! "$php" -n -d memory_limit=1024M -d error_reporting=-1 -d display_errors=stderr "$phar" --path="$site" "$@" 2> "$base/stderr.txt"; then
        cat "$base/stderr.txt" >&2
        echo "error: wp $* failed" >&2
        exit 1
    fi

    cat "$base/stderr.txt" >> "$base/stderr.log"
}

version="$(lock_field wp-cli 2)"
echo "==> WP-CLI $version on $("$php" -n -r 'echo PHP_VERSION;')"
info="$(wp --info)"
echo "$info" | grep -q "WP-CLI version:[[:space:]]*$version" || { echo "$info"; echo "error: wp --info does not give WP-CLI $version" >&2; exit 1; }

echo "==> install WordPress $(lock_field wordpress 2) on SQLite"
(cd "$base/Nexus Test" && unzip -q "$base/wordpress.zip" && mv wordpress shop)
(cd "$site/wp-content/plugins" && unzip -q "$base/sqlite.zip")
cp "$site/wp-content/plugins/sqlite-database-integration/db.copy" "$site/wp-content/db.php"

wp config create --dbname=shop --dbuser=shop --dbpass=shop --dbhost=127.0.0.1 --skip-check > /dev/null
wp core install --url=https://shop.test --title=Shop --admin_user=admin --admin_password=secret \
    --admin_email=admin@example.com --skip-email > /dev/null

siteurl="$(wp option get siteurl)"
[ "$siteurl" = "https://shop.test" ] || { echo "error: wp option get siteurl gives $siteurl" >&2; exit 1; }
echo "==> wp option get siteurl gives $siteurl"

if grep -E "(Deprecated|Warning|Notice):" "$base/stderr.log" | sort -u > "$base/problems.txt" && [ -s "$base/problems.txt" ]; then
    while read -r line; do
        echo "::warning title=WP-CLI on PHP $("$php" -n -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')::$line"
    done < "$base/problems.txt"
fi

echo "==> all WP-CLI tests passed"
