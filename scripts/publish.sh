#!/bin/bash
#
# Publishes the packages in a folder as GitHub releases and writes the manifest that the Nexus
# app reads:
#
#   GH_TOKEN=... scripts/publish.sh dist
#
# Each package gets the release <name>-<version>-r<revision> with the package, its JSON file and
# every source archive it was built from. A release that exists already stays as it is, and the
# manifest uses its files. So a package that the manifest names never changes afterwards.
#
# scripts/release-manifest.sh publishes the manifest as a new release, which becomes the latest
# release:
# https://github.com/NexusLocal/binaries/releases/latest/download/manifest.json
#
# scripts/support.sh adds the support data of each version line from support.lock.
#
# Needs gh, jq, curl and shasum.

set -euo pipefail

dist="${1:?usage: scripts/publish.sh <folder with packages>}"
repo="${GITHUB_REPOSITORY:-NexusLocal/binaries}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

entries="$work/entries.jsonl"
: > "$entries"

lock_line() {
    awk -v name="$1" '$1 == name { print; found = 1 } END { if (!found) exit 1 }' "$root/sources.lock"
}

download_verified() {
    local url="$1" sha256="$2" target="$3"
    curl -fsSL --retry 8 --retry-connrefused -o "$target" "$url"
    echo "$sha256  $target" | shasum -a 256 -c --status || { echo "error: SHA-256 mismatch for $url" >&2; exit 1; }
}

publish_package() {
    local json="$1" tag file sources name version url sha256 source_file
    tag="$(jq -r .tag "$json")"
    file="$(jq -r .file "$json")"

    if gh release view "$tag" --repo "$repo" > /dev/null 2>&1; then
        echo "==> $tag exists already, the manifest keeps its files"
        gh release download "$tag" --repo "$repo" --pattern "${file%.tar.xz}.json" --dir "$work/released" --clobber
        json="$work/released/${file%.tar.xz}.json"
    else
        echo "==> create the release $tag"
        sources="$work/sources-$tag"
        mkdir -p "$sources"

        grep -E '^[^ ]+ [^ ]+ [0-9a-f]{64} ' "$dist/${file%.tar.xz}.sources.txt" | while read -r name version sha256 url; do
            source_file="$sources/source-$name-$version-${url##*/}"
            download_verified "$url" "$sha256" "$source_file"
        done

        gh release create "$tag" --repo "$repo" --latest=false \
            --title "$(jq -r '.name + " " + .version + " (revision " + (.revision | tostring) + ")"' "$json")" \
            --notes "Built from the sources attached to this release. See ${file%.tar.xz}.sources.txt for their SHA-256 and URLs." \
            "$dist/$file" "$json" "$dist/${file%.tar.xz}.sources.txt" "$sources"/*
    fi

    jq -c --arg url "https://github.com/$repo/releases/download/$tag/$file" \
        '{name, version, line, revision, url: $url, sha256, size, format: "tar.xz", minimum_macos, architecture, license}' \
        "$json" >> "$entries"
}

add_upstream_entry() {
    local source_name="$1" name="$2" line="$3" format="$4" fields version sha256 url
    fields="$(lock_line "$source_name")"
    version="$(echo "$fields" | awk '{print $2}')"
    sha256="$(echo "$fields" | awk '{print $3}')"
    url="$(echo "$fields" | awk '{print $4}')"

    jq -nc --arg name "$name" --arg version "$version" --arg line "$line" --arg url "$url" \
        --arg sha256 "$sha256" --arg format "$format" \
        '{name: $name, version: $version, line: $line, revision: 1, url: $url, sha256: $sha256, format: $format, minimum_macos: "27.0", architecture: "arm64", upstream: true}' \
        >> "$entries"
}

# NEXUS_DRY_RUN=1 changes nothing on GitHub: every release counts as new, nothing is downloaded,
# and the manifest is written to <folder>/manifest.json.
if [ "${NEXUS_DRY_RUN:-}" = "1" ]; then
    gh() {
        if [ "$1 $2" = "release view" ]; then
            return 1
        fi
        echo "[dry run] gh $1 $2 $3 ..." >&2
    }
    download_verified() {
        echo "[dry run] download $1" >&2
        : > "$3"
    }
fi

for json in "$dist"/*-macos-arm64.json; do
    [ -e "$json" ] || continue
    publish_package "$json"
done

add_upstream_entry node-22 node 22 tar.xz
add_upstream_entry node-24 node 24 tar.xz
add_upstream_entry node-26 node 26 tar.xz
add_upstream_entry composer composer 2 phar
add_upstream_entry wp-cli wp-cli 2 phar

# A build that failed gives no package. That line keeps the package of the newest manifest, so a
# problem of one package does not hold back the updates of the others. Only a line of
# support.lock stays, so a line that Nexus no longer offers goes away.
keep_previous_entries() {
    local previous="$work/previous"
    mkdir -p "$previous"

    if ! "$root/scripts/release-manifest.sh" download "$previous" > /dev/null; then
        echo "==> no earlier manifest, so no package is kept"
        return
    fi

    jq -c '.packages[]' "$previous/manifest.json" | while read -r entry; do
        local name line
        name="$(echo "$entry" | jq -r .name)"
        line="$(echo "$entry" | jq -r .line)"

        if jq -e --arg name "$name" --arg line "$line" 'select(.name == $name and .line == $line)' "$entries" > /dev/null; then
            continue
        fi

        if ! awk -v name="$name" -v line="$line" '$1 == name && $2 == line { found = 1 } END { exit !found }' "$root/support.lock"; then
            continue
        fi

        echo "==> $name $line keeps $(echo "$entry" | jq -r .version) of the newest manifest"
        echo "$entry" | jq -c 'del(.security_end, .lts)' >> "$entries"
    done
}

if [ "${NEXUS_DRY_RUN:-}" != "1" ]; then
    keep_previous_entries
fi

jq -s --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repository "$repo" \
    '{schema: 1, generated: $generated, repository: $repository, packages: (sort_by(.name, .line))}' \
    "$entries" > "$work/manifest.json"
"$root/scripts/support.sh" "$work/manifest.json"

if [ "${NEXUS_DRY_RUN:-}" = "1" ]; then
    echo "[dry run] scripts/release-manifest.sh publish manifest.json" >&2
    cp "$work/manifest.json" "$dist/manifest.json"
else
    "$root/scripts/release-manifest.sh" publish "$work/manifest.json"
fi

echo "==> the manifest lists $(jq '.packages | length' "$work/manifest.json") packages"
