#!/bin/bash
#
# Publishes the packages in a folder as GitHub releases and writes the manifest that the Nexus
# app reads:
#
#   GH_TOKEN=... scripts/publish.sh dist
#
# Each package gets the release <name>-<version>-r<revision> with the package, its JSON file and
# every source archive it was built from. A release that exists already stays as it is. When the
# newest release of a version has the same recipe and the same sources, the manifest uses its
# files. Otherwise the package gets the next revision. So a package that the manifest names never
# changes afterwards.
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

tag_revisions_highest_first() {
    gh api --paginate "repos/$repo/git/matching-refs/tags/$1-r" --jq '.[].ref' |
        sed -nE "s|^refs/tags/$1-r([0-9]+)\$|\1|p" | sort -rn
}

release_exists() {
    local answer
    answer="$(gh api "repos/$repo/releases/tags/$1" --jq .tag_name 2>&1)" && return 0

    case "$answer" in
        *"HTTP 404"*) return 1 ;;
    esac

    echo "error: GitHub did not say if the release $1 exists: $answer" >&2
    exit 1
}

# The first of the revisions that has a release, or nothing. A tag can stay when somebody deletes
# its release.
newest_released() {
    local version="$1" revision
    shift

    for revision in "$@"; do
        if release_exists "$version-r$revision"; then
            echo "$revision"
            return
        fi
    done
}

source_lines() {
    grep -E '^[^ ]+ [^ ]+ [0-9a-f]{64} ' "$1"
}

# An older release has no recipe_revision. Its revision is the revision of its recipe.
recipe_revision() {
    jq -er '.recipe_revision // .revision' "$1"
}

# Two packages with the same text come from the same recipe and the same sources. The URL of a
# source does not count, because its SHA-256 says what is in it.
build_identity() {
    local json="$1" recipe sources
    recipe="$(recipe_revision "$json")" || return 1
    sources="$(source_lines "${json%.json}.sources.txt" | cut -d' ' -f1-3 | sort)" || return 1

    printf '%s\n%s\n' "$recipe" "$sources"
}

create_release() {
    local json="$1" package_sources="$2" tag file sources name version url sha256 source_file
    tag="$(jq -r .tag "$json")"
    file="$(jq -r .file "$json")"

    echo "==> create the release $tag"
    sources="$work/sources-$tag"
    mkdir -p "$sources"

    source_lines "$package_sources" | while read -r name version sha256 url; do
        source_file="$sources/source-$name-$version-${url##*/}"
        download_verified "$url" "$sha256" "$source_file"
    done

    gh release create "$tag" --repo "$repo" --latest=false \
        --title "$(jq -r '.name + " " + .version + " (revision " + (.revision | tostring) + ")"' "$json")" \
        --notes "Built from the sources attached to this release. See ${file%.tar.xz}.sources.txt for their SHA-256 and URLs." \
        "$dist/$file" "$json" "$package_sources" "$sources"/*
}

add_entry() {
    local json="$1" tag file
    tag="$(jq -r .tag "$json")"
    file="$(jq -r .file "$json")"

    jq -c --arg url "https://github.com/$repo/releases/download/$tag/$file" \
        '{name, version, line, revision, url: $url, sha256, size, format: "tar.xz", minimum_macos, architecture, license}' \
        "$json" >> "$entries"
}

# A new library gives a package with the version and the recipe revision of a release that exists.
# Such a package gets the next revision. Otherwise the update would wait for the next release of
# PHP or PostgreSQL.
publish_package() {
    local json="$1" base version revisions newest released identity released_identity revision recipe
    base="$(basename "$json" .json)"
    version="$(jq -r '.name + "-" + .version' "$json")"
    revisions="$(tag_revisions_highest_first "$version")"
    newest="$(newest_released "$version" $revisions)"

    if [ -n "$newest" ]; then
        released="$work/released/$version-r$newest"
        gh release download "$version-r$newest" --repo "$repo" --pattern "$base.json" --pattern "$base.sources.txt" --dir "$released" --clobber
        identity="$(build_identity "$json")"
        released_identity="$(build_identity "$released/$base.json")"

        if [ "$identity" = "$released_identity" ]; then
            echo "==> $version-r$newest has the same recipe and sources, the manifest keeps its files"
            add_entry "$released/$base.json"
            return
        fi
    fi

    recipe="$(recipe_revision "$json")"
    revision="$(echo "$revisions" | head -1)"
    revision=$((${revision:-0} + 1))
    if [ "$recipe" -gt "$revision" ]; then
        revision="$recipe"
    fi

    mkdir -p "$work/new"
    jq --argjson revision "$revision" --arg tag "$version-r$revision" '.revision = $revision | .tag = $tag' "$json" > "$work/new/$base.json"
    create_release "$work/new/$base.json" "$dist/$base.sources.txt"
    add_entry "$work/new/$base.json"
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

# NEXUS_DRY_RUN=1 changes nothing on GitHub. It reads the releases and downloads no source. The
# manifest goes to <folder>/manifest.json.
if [ "${NEXUS_DRY_RUN:-}" = "1" ]; then
    gh() {
        case "$1 $2" in
            "api "* | "release download") command gh "$@" ;;
            *) echo "[dry run] gh $1 $2 $3 ..." >&2 ;;
        esac
    }
    download_verified() {
        echo "[dry run] download $1" >&2
        : > "$3"
    }
fi

# Somebody can start an old run of the Build workflow again. Its packages are older than the
# packages of a newer commit. So it publishes nothing when main has a newer commit that starts a
# Build. These are the paths in build.yml. The run fails, because the Build of the newer commit can
# be missing too. Then the owner gets an issue.
stop_old_build() {
    local commit changes
    commit="${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD)}"

    if ! changes="$(gh api "repos/$repo/compare/$commit...main" --jq '.files[] | .filename, (.previous_filename // empty)')"; then
        echo "error: GitHub could not compare $commit with main. Nothing is published." >&2
        exit 1
    fi

    # GitHub gives at most 300 files.
    if [ "$(wc -l <<< "$changes")" -ge 300 ]; then
        echo "error: main changed too many files since $commit. This run publishes nothing." >&2
        exit 1
    fi

    if grep -qE '^(build\.sh|packages\.json|scripts/plan-build\.sh|sources\.lock|\.github/workflows/build\.yml|(lib|licenses|products|tests)/.+)$' <<< "$changes"; then
        echo "error: main has a newer commit that starts a Build. This run of $commit publishes nothing." >&2
        exit 1
    fi
}

if [ "${NEXUS_DRY_RUN:-}" != "1" ]; then
    stop_old_build
fi

# A server of a source can refuse a download. Then that package keeps its package of the newest
# manifest and the others still get their update. bash ignores set -e in a condition. So the status
# comes from $? and not from an if.
failed=""
for json in "$dist"/*-macos-arm64.json; do
    [ -e "$json" ] || continue

    set +e
    (set -e; publish_package "$json")
    status=$?
    set -e

    if [ "$status" -ne 0 ]; then
        failed="$failed $(basename "$json" -macos-arm64.json)"
    fi
done

add_upstream_entry node-22 node 22 tar.xz
add_upstream_entry node-24 node 24 tar.xz
add_upstream_entry node-26 node 26 tar.xz
add_upstream_entry composer composer 2 phar
add_upstream_entry wp-cli wp-cli 2 phar

# The lines of packages.json that the manifest of this run does not have.
missing_lines() {
    jq -rs --slurpfile packages "$root/packages.json" '
        . as $entries
        | [$packages[0][] | select(. as $package | $entries | any(.name == $package.product and ($package.version == "" or .line == $package.version)) | not) | .name]
        | join(" ")' "$entries"
}

# A build that failed gives no package. That line keeps the package of the newest manifest, so a
# problem of one package does not hold back the updates of the others. Only a line of
# support.lock stays, so a line that Nexus no longer offers goes away.
keep_previous_entries() {
    local previous="$work/previous" status=0
    mkdir -p "$previous"

    "$root/scripts/release-manifest.sh" download "$previous" > /dev/null || status=$?

    if [ "$status" -eq 3 ] && [ -z "$failed" ]; then
        # A Build makes only some packages. Without an earlier manifest, each other line would go away.
        missing="$(missing_lines)"

        if [ -n "$missing" ]; then
            echo "error: no earlier manifest has these lines, and this run has no package of them: $missing. No manifest is published." >&2
            exit 1
        fi

        echo "==> no earlier manifest, so no package is kept"
        return
    fi

    if [ "$status" -ne 0 ]; then
        echo "error: the newest manifest could not be read. No manifest is published." >&2
        exit 1
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

if [ -n "$failed" ]; then
    echo "error: these packages were not published:$failed" >&2
    exit 1
fi
