#!/bin/bash
#
# Builds one Nexus package from source.
#
#   ./build.sh nginx
#   NEXUS_BUILD_ROOT=/tmp/nexus-build ./build.sh nginx
#
# The script starts again in an empty environment, so tools and libraries from MAMP, Homebrew
# or the PATH of the user cannot end up in a package.

set -euo pipefail

if [ "${NEXUS_CLEAN_ENV:-}" != "1" ]; then
    exec /usr/bin/env -i \
        HOME="$HOME" \
        TERM="${TERM:-dumb}" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        NEXUS_CLEAN_ENV=1 \
        NEXUS_BUILD_ROOT="${NEXUS_BUILD_ROOT:-/tmp/nexus-build}" \
        /bin/bash "$0" "$@"
fi

product="${1:-}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$product" ] || [ ! -f "$repo/products/$product.sh" ]; then
    echo "usage: ./build.sh <product>" >&2
    echo "products: $(cd "$repo/products" && ls -1 *.sh | sed 's/\.sh$//' | tr '\n' ' ')" >&2
    exit 1
fi

source "$repo/lib/env.sh"
source "$repo/lib/fetch.sh"
source "$repo/lib/toolchain.sh"
source "$repo/lib/relocate.sh"
source "$repo/lib/check.sh"
source "$repo/lib/package.sh"
source "$repo/products/$product.sh"

build_product
