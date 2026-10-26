NEXUS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${NEXUS_BUILD_ROOT:-/tmp/nexus-build}"

case "$BUILD_ROOT" in
    *" "*)
        echo "error: NEXUS_BUILD_ROOT must not contain spaces, because many configure scripts fail on them: $BUILD_ROOT" >&2
        exit 1
        ;;
esac

CACHE_DIR="$BUILD_ROOT/cache"
WORK_DIR="$BUILD_ROOT/work"
TOOLS_DIR="$BUILD_ROOT/tools"
STAGE_DIR="$BUILD_ROOT/stage"
PACKAGE_ROOT="$BUILD_ROOT/package"
OUT_DIR="$BUILD_ROOT/out"

MACOS_MIN=27.0
JOBS="$(sysctl -n hw.ncpu)"

export PATH="$TOOLS_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
export CC=/usr/bin/clang
export CXX=/usr/bin/clang++
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=$MACOS_MIN"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$STAGE_DIR/include"
export LDFLAGS="-L$STAGE_DIR/lib -arch arm64 -mmacosx-version-min=$MACOS_MIN"
export PKG_CONFIG_LIBDIR="$STAGE_DIR/lib/pkgconfig"
export PKG_CONFIG_PATH=""

mkdir -p "$CACHE_DIR" "$WORK_DIR" "$TOOLS_DIR/bin" "$STAGE_DIR/include" "$STAGE_DIR/lib/pkgconfig" "$PACKAGE_ROOT" "$OUT_DIR"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
