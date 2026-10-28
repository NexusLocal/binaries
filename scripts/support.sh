#!/bin/bash
#
# Adds the LTS flag and the last day of security fixes from support.lock to each package of a
# manifest file. It changes the file in place:
#
#   scripts/support.sh manifest.json
#
# The manifest gets "lts" (true or false) and "security_end" (a date such as 2026-12-31, or
# null). The script stops with an error when a package has no line in support.lock. So a new
# version line cannot get into the manifest without its support data.
#
# Needs jq.

set -euo pipefail

manifest="${1:?usage: scripts/support.sh <manifest.json>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

support="$(awk '
    /^#/ || NF == 0 { next }
    NF != 4 || ($3 != "yes" && $3 != "no") || ($4 != "-" && $4 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
        print "error: support.lock line " NR " is not valid: " $0 > "/dev/stderr"
        exit 1
    }
    {
        lts = $3 == "yes" ? "true" : "false"
        end = $4 == "-" ? "null" : "\"" $4 "\""
        printf "{\"name\":\"%s\",\"line\":\"%s\",\"lts\":%s,\"security_end\":%s}\n", $1, $2, lts, end
    }
' "$root/support.lock" | jq -s .)"

missing="$(jq -r --argjson support "$support" '
    .packages[]
    | select([.name, .line] as $key | $support | map([.name, .line] == $key) | any | not)
    | "\(.name) \(.line)"
' "$manifest")"

if [ -n "$missing" ]; then
    echo "error: support.lock has no line for:" >&2
    echo "$missing" >&2
    exit 1
fi

jq --argjson support "$support" '
    .packages |= map(
        . as $package
        | ($support[] | select(.name == $package.name and .line == $package.line)) as $support_line
        | $package + {lts: $support_line.lts, security_end: $support_line.security_end}
    )
' "$manifest" > "$manifest.new"
mv "$manifest.new" "$manifest"
