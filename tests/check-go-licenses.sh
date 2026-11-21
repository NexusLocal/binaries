#!/bin/bash
#
# Checks that a package with a Go binary has the license of Go and a license file for each Go
# module in the binary. tests/mailpit.sh and tests/cloudflared.sh run it. The binary has the
# list of its modules as text in its build information. So this check needs no Go:
#
#   tests/check-go-licenses.sh <package folder> <binary>

set -euo pipefail

root="${1:?usage: tests/check-go-licenses.sh <package folder> <binary>}"
binary="${2:?usage: tests/check-go-licenses.sh <package folder> <binary>}"

grep -q "The Go Authors" "$root/licenses/go.txt" || { echo "error: the package has no license of Go" >&2; exit 1; }
[ -s "$root/licenses/go-patents.txt" ] || { echo "error: the package has no PATENTS file of Go" >&2; exit 1; }

# A line "=>" follows the line "dep" of a module that the build replaced with another module.
modules="$(LC_ALL=C grep -a -o -E $'(dep|=>)\t[^\t]+\t[^\t]+' "$binary" | awk -F '\t' '
    $1 == "dep" { if (line != "") print line; line = $2 "@" $3; next }
    $1 == "=>" { line = $2 "@" $3 }
    END { if (line != "") print line }
' | sort -u)"
[ -n "$modules" ] || { echo "error: $binary has no Go modules in its build information" >&2; exit 1; }

missing=""
for module in $modules; do
    [ -n "$(find "$root/licenses/go-modules/$module" -type f -size +0 2> /dev/null | head -1)" ] || missing="$missing $module"
done
[ -z "$missing" ] || { echo "error: license files are missing for these Go modules:$missing" >&2; exit 1; }

echo "==> the package has the license of Go and license files for all $(echo "$modules" | wc -l | tr -d ' ') Go modules"
