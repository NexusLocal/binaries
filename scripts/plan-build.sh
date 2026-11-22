#!/bin/bash
#
# Prints the packages of packages.json that a Build has to make, as JSON for the matrix in build.yml:
#
#   GH_TOKEN=... scripts/plan-build.sh <base> [<head>]
#
# base is the commit of the last successful Build on main, or "all". A package is in the list when
# one of these is true:
#
#   - a commit after base changed the recipe, the test or another file of its product
#   - a commit after base changed a shared file (build.sh, lib, licenses, the Build workflow)
#   - a source of the newest published package is not the same as in sources.lock
#   - a commit after base changed a tool of the build, for example CMake
#   - the newest manifest has no package of this line
#
# Each commit counts, also when a later commit takes its change back. A failed run can have
# published the first change. scripts/publish.sh keeps the newest published package of each other line. A run that fails or that
# a newer push stops does not move base. So the next run looks at its changes too.
#
# The reason of each choice goes to standard error. Needs git, jq, curl and gh.

set -euo pipefail

base="${1:?usage: scripts/plan-build.sh <base commit | all> [<head>]}"
head="${2:-HEAD}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say() {
    echo "$*" >&2
}

git_root() {
    git -C "$root" "$@"
}

git_root show "$head:packages.json" > "$work/packages.json"
git_root show "$head:sources.lock" > "$work/sources.lock"

all_packages() {
    say "all packages: $1"
    jq -c '.' "$work/packages.json"
    exit 0
}

[ "$base" != "all" ] || all_packages "asked for"
git_root cat-file -e "$base^{commit}" 2> /dev/null || all_packages "the commit $base is unknown"
git_root merge-base --is-ancestor "$base" "$head" || all_packages "$base is not an ancestor of $head"

changed_files="$(git_root log --format= --name-only --no-renames -m "$base..$head" | sort -u)"
all_products=" $(jq -r '.[].product' "$work/packages.json" | sort -u | tr '\n' ' ') "
products=""

add_products() {
    products="$products $1"
    say "$2 changed, so: $1"
}

add_product_of() {
    local product
    product="$(basename "$1" .sh)"

    [[ "$all_products" == *" $product "* ]] || all_packages "$1 changed, and it is not the file of one product"
    add_products "$product" "$1"
}

while IFS= read -r file; do
    case "$file" in
        build.sh | lib/* | licenses/* | .github/workflows/build.yml | scripts/plan-build.sh) all_packages "$file changed" ;;
        tests/mysql.sh) add_products "mysql mariadb" "$file" ;;
        tests/check-go-licenses.sh) add_products "mailpit cloudflared" "$file" ;;
        tests/wp-cli.sh) add_products "php" "$file" ;;
        products/*.sh | tests/*.sh) add_product_of "$file" ;;
        products/* | tests/*) all_packages "$file changed" ;;
    esac
done <<< "$changed_files"

# The newest manifest names each published package. Its sources.txt is next to it in the release.
manifest="$work/manifest"
mkdir -p "$manifest"
"$root/scripts/release-manifest.sh" download "$manifest" > /dev/null || all_packages "the newest manifest could not be read"

package_sources() {
    local url
    url="$(jq -r --arg name "$1" --arg line "$2" '.packages[] | select(.name == $name and ($line == "" or .line == $line)) | .url' "$manifest/manifest.json" | sed -n 1p)"
    [ -n "$url" ] || return 1
    curl -fsSL --max-time 60 --retry 4 --retry-connrefused "${url%.tar.xz}.sources.txt" | grep -E '^[^ ]+ [^ ]+ [0-9a-f]{64} ' | cut -d' ' -f1-3
}

# Prints the first source of the package that is not the same in sources.lock, or nothing.
changed_source() {
    while read -r name version sha256; do
        if ! awk -v name="$name" -v version="$version" -v sha256="$sha256" \
            '$1 == name && $2 == version && $3 == sha256 { found = 1 } END { exit !found }' "$work/sources.lock"; then
            echo "$name"
            return
        fi
    done
}

: > "$work/used.txt"
mkdir -p "$work/sources"

while read -r name product version; do
    if package_sources "$product" "$version" > "$work/sources/$name"; then
        cut -d' ' -f1 "$work/sources/$name" >> "$work/used.txt"
    else
        rm -f "$work/sources/$name"
        say "$name: the newest manifest has no package, or its sources could not be read"
    fi
done < <(jq -r '.[] | "\(.name) \(.product) \(if .version == "" then "-" else .version end)"' "$work/packages.json" | sed 's/ -$//')

# A source that no package lists is a tool, a download that Nexus gives out as it is, or an input of
# the WP-CLI test. Some tools serve only one or two products.
changed_tools=""

while read -r name; do
    [ -n "$name" ] || continue
    grep -qx "$name" "$work/used.txt" && continue

    case "$name" in
        node-* | composer) say "$name changed. The manifest gets it without a package." ;;
        wp-cli | wordpress | sqlite-database-integration) add_products "php" "$name" ;;
        go) add_products "mailpit cloudflared" "$name" ;;
        m4 | autoconf) add_products "php" "$name" ;;
        protobuf) add_products "postgresql" "$name" ;;
        *) changed_tools="$changed_tools $name" ;;
    esac
done < <(git_root log --format= -p -U0 --no-color -m "$base..$head" -- sources.lock | awk '/^[-+][A-Za-z0-9]/ { print substr($1, 2) }' | sort -u)

[ -z "$changed_tools" ] || all_packages "these sources are not in a package:$changed_tools"

selected="$work/selected.txt"
: > "$selected"

while read -r name product; do
    if [[ " $products " == *" $product "* ]]; then
        echo "$name" >> "$selected"
    elif [ ! -e "$work/sources/$name" ]; then
        echo "$name" >> "$selected"
    else
        changed="$(changed_source < "$work/sources/$name")"

        if [ -n "$changed" ]; then
            say "$name: the source $changed changed"
            echo "$name" >> "$selected"
        fi
    fi
done < <(jq -r '.[] | "\(.name) \(.product)"' "$work/packages.json")

say "packages: $(tr '\n' ' ' < "$selected")"
jq -c --rawfile selected "$selected" '($selected | split("\n")) as $names | map(select(.name as $name | $names | index($name)))' "$work/packages.json"
