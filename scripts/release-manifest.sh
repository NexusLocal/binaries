#!/bin/bash
#
# A release of this repository cannot change after it is published. So each manifest gets a new
# release, and that release becomes the latest release. The Nexus app reads
# https://github.com/NexusLocal/binaries/releases/latest/download/manifest.json
#
#   scripts/release-manifest.sh download <folder>   puts the newest manifest.json in the folder
#   scripts/release-manifest.sh publish <file>      publishes the file as the newest manifest
#
# Needs gh.

set -euo pipefail

action="${1:?usage: scripts/release-manifest.sh download <folder> | publish <manifest.json>}"
path="${2:?usage: scripts/release-manifest.sh download <folder> | publish <manifest.json>}"
repo="${GITHUB_REPOSITORY:-NexusLocal/binaries}"

# The tag of the first manifest release is "manifest". Each later tag starts with "manifest-".
newest_manifest_tag() {
    gh release list --repo "$repo" --limit 1000 --exclude-drafts --json tagName,createdAt \
        --jq '[.[] | select(.tagName | startswith("manifest"))] | sort_by(.createdAt) | last | .tagName // empty'
}

case "$action" in
download)
    tag="$(newest_manifest_tag)"
    if [ -z "$tag" ]; then
        echo "error: no release has a manifest" >&2
        exit 1
    fi
    gh release download "$tag" --repo "$repo" --pattern manifest.json --dir "$path" --clobber
    ;;
publish)
    if [ "$(basename "$path")" != "manifest.json" ]; then
        echo "error: the file must have the name manifest.json, because Nexus downloads that name" >&2
        exit 1
    fi
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gh release create "manifest-$(date -u +%Y%m%d-%H%M%S)" "$path" --repo "$repo" --latest \
        --title "Manifest $now" \
        --notes "manifest.json lists every package that Nexus can install. Nexus reads the manifest of the latest release."
    ;;
*)
    echo "error: unknown action $action" >&2
    exit 1
    ;;
esac
