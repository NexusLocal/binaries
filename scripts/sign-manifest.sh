#!/bin/bash
#
# Signs the newest manifest that waits as a draft release, on the Mac of the owner (group 8), and
# publishes it as the latest release:
#
#   scripts/sign-manifest.sh [--yes]
#
# 1. It downloads the newest draft and the manifest of the latest release.
# 2. It shows each package that changed, with the old and the new version.
# 3. It checks each changed package: its SHA-256, and for a package of this repository the
#    attestation of the Build workflow. A package of upstream has no attestation.
# 4. After a yes, sign_update of Sparkle signs the bytes of manifest.json with the key
#    nexus-packages in the Keychain. manifest.signed.json holds the same bytes and the signature.
# 5. It adds manifest.signed.json to the draft, publishes the draft as the latest release, deletes
#    the older drafts and closes the issue "A manifest waits for its signature".
#
# The first run asks the Keychain for access. Choose "Always Allow" for sign_update.
# NEXUS_SIGN_UPDATE names sign_update when it is not in the build folder of Xcode.
# NEXUS_DRY_RUN=1 checks and signs, but changes nothing on GitHub. It keeps manifest.signed.json
# in the folder that it names.
#
# Needs gh, jq, curl, shasum and sign_update of Sparkle.

set -euo pipefail

repo="${GITHUB_REPOSITORY:-NexusLocal/binaries}"
account="nexus-packages"
waiting_issue="A manifest waits for its signature"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/download.sh"

yes=0
if [ "${1:-}" = "--yes" ]; then
    yes=1
fi

sign_update="${NEXUS_SIGN_UPDATE:-$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1)}"

if [ ! -x "$sign_update" ]; then
    echo "error: sign_update of Sparkle is not there. Build Nexus once in Xcode, or set NEXUS_SIGN_UPDATE." >&2
    exit 1
fi

drafts="$(gh release list --repo "$repo" --limit 1000 --json tagName,isDraft \
    --jq '[.[] | select(.isDraft and (.tagName | startswith("manifest"))) | .tagName] | sort | .[]')"

if [ -z "$drafts" ]; then
    echo "No manifest waits for its signature."
    exit 0
fi

draft="$(echo "$drafts" | tail -1)"
latest="$(gh release list --repo "$repo" --limit 1000 --exclude-drafts --json tagName,publishedAt \
    --jq '[.[] | select(.tagName | startswith("manifest"))] | sort_by(.publishedAt) | last | .tagName // empty')"

mkdir -p "$work/new" "$work/old" "$work/packages"
try_twice gh release download "$draft" --repo "$repo" --pattern manifest.json --dir "$work/new" --clobber

if [ -n "$latest" ]; then
    try_twice gh release download "$latest" --repo "$repo" --pattern manifest.json --dir "$work/old" --clobber
else
    echo '{"packages": []}' > "$work/old/manifest.json"
fi

echo "==> $draft against ${latest:-no earlier manifest}"

# One line for each package whose file changed: the key, the old and the new version, and the
# fields that the check needs.
jq -r --slurpfile old "$work/old/manifest.json" '
    ($old[0].packages | map({key: "\(.name) \(.line)", value: .}) | from_entries) as $before
    | .packages[]
    | . as $new
    | ($before["\(.name) \(.line)"]) as $old
    | select(($old.sha256 // "") != .sha256)
    | [.name, .line, ($old.version // "new"), .version, .url, .sha256, (if .upstream then "upstream" else "built" end)]
    | @tsv' "$work/new/manifest.json" > "$work/changed.tsv"

jq -r --slurpfile new "$work/new/manifest.json" '
    ($new[0].packages | map({key: "\(.name) \(.line)", value: .}) | from_entries) as $after
    | .packages[]
    | select($after["\(.name) \(.line)"] == null)
    | "\(.name) \(.line): \(.version) leaves the manifest"' "$work/old/manifest.json" > "$work/removed.txt"

if [ ! -s "$work/changed.tsv" ] && [ ! -s "$work/removed.txt" ]; then
    echo "==> no package changed, only the support data"
fi

while IFS=$'\t' read -r name line old new url sha256 kind; do
    echo "    $name $line: $old -> $new${kind/built/}"
done < "$work/changed.tsv"
sed 's/^/    /' "$work/removed.txt"

echo "==> the check of each changed package"
problems=0

while IFS=$'\t' read -r name line old new url sha256 kind; do
    file="$work/packages/$(basename "$url")"

    if ! download_file "$url" "$file" "$sha256"; then
        echo "    $name $new: the file does not download with the SHA-256 of the manifest" >&2
        problems=$((problems + 1))
        continue
    fi

    if [ "$kind" = "upstream" ]; then
        echo "    $name $new: SHA-256 matches (a file of upstream, without an attestation)"
    elif gh attestation verify "$file" --repo "$repo" --signer-workflow "$repo/.github/workflows/build.yml" > "$work/attestation.txt" 2>&1; then
        echo "    $name $new: SHA-256 matches, and the Build workflow of $repo made the file"
    else
        echo "    $name $new: no valid attestation of the Build workflow" >&2
        sed 's/^/        /' "$work/attestation.txt" >&2
        problems=$((problems + 1))
    fi

    rm -f "$file"
done < "$work/changed.tsv"

if [ "$problems" -gt 0 ]; then
    echo "error: $problems packages failed the check. Nothing is signed." >&2
    exit 1
fi

if [ "$yes" -ne 1 ]; then
    printf "Sign %s and publish it as the latest release? Type yes: " "$draft"
    read -r answer

    if [ "$answer" != "yes" ]; then
        echo "Nothing is signed."
        exit 0
    fi
fi

# sign_update can change a file whose name looks like release notes. A copy with a neutral name
# keeps the bytes of manifest.json as they are.
cp "$work/new/manifest.json" "$work/manifest.bytes"
signature="$("$sign_update" --account "$account" -p "$work/manifest.bytes")"

if ! cmp -s "$work/new/manifest.json" "$work/manifest.bytes" || ! "$sign_update" --account "$account" --verify "$work/manifest.bytes" "$signature" > /dev/null; then
    echo "error: the signature does not verify. Nothing is published." >&2
    exit 1
fi

jq -n --arg manifest "$(base64 -i "$work/new/manifest.json" | tr -d '\n')" --arg signature "$signature" \
    '{manifest: $manifest, signature: $signature}' > "$work/manifest.signed.json"

if [ "${NEXUS_DRY_RUN:-}" = "1" ]; then
    out="${NEXUS_DRY_RUN_FOLDER:-$PWD}"
    cp "$work/manifest.signed.json" "$out/manifest.signed.json"
    echo "[dry run] signed $draft into $out/manifest.signed.json. GitHub did not change."
    exit 0
fi

try_twice gh release upload "$draft" "$work/manifest.signed.json" --repo "$repo" --clobber
gh release edit "$draft" --repo "$repo" --draft=false --latest

for older in $drafts; do
    if [ "$older" != "$draft" ]; then
        gh release delete "$older" --repo "$repo" --yes
        echo "==> deleted the older draft $older"
    fi
done

number="$(gh issue list --repo "$repo" --state open --search "in:title \"$waiting_issue\"" --json number --jq '.[0].number')"

if [ -n "$number" ]; then
    gh issue close "$number" --repo "$repo" --comment "Signed and published $draft."
fi

echo "==> $draft is signed and is the latest release"
