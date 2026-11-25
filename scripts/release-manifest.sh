#!/bin/bash
#
# A release of this repository cannot change after it is published. So each manifest gets a new
# release. A new manifest waits as a draft release until the owner signs it on the Mac of the owner
# with scripts/sign-manifest.sh. A draft is not public. The sign script publishes the draft as the
# latest release. The Nexus app reads
# https://github.com/NexusLocal/binaries/releases/latest/download/manifest.signed.json
# Versions of Nexus before the signature read manifest.json of the same release.
#
#   scripts/release-manifest.sh download <folder>   puts the newest manifest.json in the folder: the
#                                                   newest draft, else the latest release
#   scripts/release-manifest.sh draft <file>        adds the file as a draft that waits for its
#                                                   signature, and opens or updates the issue
#
# The exit code of download is 3 when no release has a manifest.
#
# Needs gh.

set -euo pipefail

action="${1:?usage: scripts/release-manifest.sh download <folder> | draft <manifest.json>}"
path="${2:?usage: scripts/release-manifest.sh download <folder> | draft <manifest.json>}"
repo="${GITHUB_REPOSITORY:-NexusLocal/binaries}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/download.sh"

waiting_issue="A manifest waits for its signature"

# The tag of the first manifest release is "manifest". Each later tag is manifest-<date>-<time>.
# createdAt is the date of the commit, and a draft has no publishedAt. So the tag gives the newest
# draft, and publishedAt gives the newest release. A draft is newer than each release, because the
# sign script deletes the older drafts when it publishes one.
newest_manifest_tag() {
    gh release list --repo "$repo" --limit 1000 --json tagName,isDraft,publishedAt \
        --jq '[.[] | select(.tagName | startswith("manifest"))]
            | ([.[] | select(.isDraft)] | sort_by(.tagName) | last)
              // ([.[] | select(.isDraft | not)] | sort_by(.publishedAt) | last)
            | .tagName // empty'
}

# The owner gets an email for each manifest that waits for its signature.
report_waiting_draft() {
    local tag="$1" body number
    body="The manifest $tag waits for its signature. Run scripts/sign-manifest.sh on the Mac of the owner. Nexus installs no new package until then."
    number="$(gh issue list --repo "$repo" --state open --search "in:title \"$waiting_issue\"" --json number --jq '.[0].number')"

    if [ -n "$number" ]; then
        gh issue comment "$number" --repo "$repo" --body "$body"
    else
        gh issue create --repo "$repo" --title "$waiting_issue" --body "$body" --assignee RoodFruit
    fi
}

case "$action" in
download)
    tag="$(newest_manifest_tag)"
    if [ -z "$tag" ]; then
        echo "error: no release has a manifest" >&2
        exit 3
    fi
    try_twice gh release download "$tag" --repo "$repo" --pattern manifest.json --dir "$path" --clobber
    ;;
draft)
    if [ "$(basename "$path")" != "manifest.json" ]; then
        echo "error: the file must have the name manifest.json, because Nexus downloads that name" >&2
        exit 1
    fi
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tag="manifest-$(date -u +%Y%m%d-%H%M%S)"
    gh release create "$tag" "$path" --repo "$repo" --draft \
        --title "Manifest $now" \
        --notes "manifest.json lists every package that Nexus can install. manifest.signed.json holds the same bytes with the signature of the owner. Nexus reads the manifest of the latest release."
    report_waiting_draft "$tag"
    ;;
*)
    echo "error: unknown action $action" >&2
    exit 1
    ;;
esac
