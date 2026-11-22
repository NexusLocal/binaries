#!/bin/bash
#
# Starts the Build of main again when commits after its last successful run are not built:
#
#   GH_TOKEN=... scripts/retry-build.sh
#
# The daily Updates run calls it when no source has an update. Otherwise a change of a failed Build
# waits for the next push. Needs git with the full history, and gh.

set -euo pipefail

repo="${GITHUB_REPOSITORY:-NexusLocal/binaries}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

active="$(gh run list --repo "$repo" --workflow build.yml --branch main --limit 10 --json status --jq 'map(select(.status != "completed")) | length')"

if [ "$active" -gt 0 ]; then
    echo "A Build runs or waits already."
    exit 0
fi

base="$(gh run list --repo "$repo" --workflow build.yml --branch main --status success --limit 1 --json headSha --jq '.[0].headSha // ""')"

if [ -z "$base" ] || ! git -C "$root" merge-base --is-ancestor "$base" HEAD; then
    echo "The last successful Build is not a commit of main before this one. No Build is started."
    exit 0
fi

waiting="$(git -C "$root" log --format=%h "$base..HEAD" -- build.sh lib licenses packages.json products tests sources.lock scripts/plan-build.sh .github/workflows/build.yml)"

if [ -z "$waiting" ]; then
    echo "Every commit that starts a Build is built."
    exit 0
fi

echo "These commits are not built: $(echo "$waiting" | tr '\n' ' '). The Build starts again."
gh workflow run build.yml --repo "$repo" --ref main
