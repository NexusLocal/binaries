# ./build.sh redis 7.2 | 8.2 | 8
#
# "8" is the newest Redis 8 line. Redis 7.2 has the BSD license. Redis 8 has three licenses to
# choose from, and Nexus gives it out under the AGPLv3 with a link to the source. Redis 7.4 is not
# built: its only licenses are RSALv2 and SSPLv1.

# Revision 2 adds the licenses of the libraries that Redis builds into its programs. Revision 3 adds
# the notices in the source files and REDISCONTRIBUTIONS.txt.
REDIS_REVISION=3

# The libraries in deps/ that the Makefile of Redis builds, and fast_float in src/ of the newest
# Redis 8. jemalloc is not built, because the build uses MALLOC=libc. linenoise and fast_float
# have their license only in a comment of their source.
add_redis_licenses() {
    local package="$1" src="$2" license_file="$3" dependency

    add_license "$package" redis "$license_file"

    for dependency in $(sed -n 's/^DEPENDENCY_TARGETS=//p' "$src/src/Makefile"); do
        case "$dependency" in
            hiredis) add_license "$package" hiredis "$src/deps/hiredis/COPYING" ;;
            linenoise) add_license_from_comment "$package" linenoise "$src/deps/linenoise/linenoise.c" "Redistribution and use" ;;
            lua) add_license "$package" lua "$src/deps/lua/COPYRIGHT" ;;
            hdr_histogram)
                add_license "$package" hdr_histogram "$src/deps/hdr_histogram/LICENSE.txt"
                add_license "$package" hdr_histogram-copying "$src/deps/hdr_histogram/COPYING.txt"
                ;;
            fpconv) add_license "$package" fpconv "$src/deps/fpconv/LICENSE.txt" ;;
            fast_float) add_license_from_comment "$package" fast_float "$src/deps/fast_float/fast_float.h" "MIT License" ;;
            xxhash) add_license "$package" xxhash "$src/deps/xxhash/LICENSE" ;;
            tre) add_license "$package" tre "$src/deps/tre/LICENSE" ;;
            croaring) add_license "$package" croaring "$src/deps/croaring/LICENSE" ;;
            *) fail "Redis builds deps/$dependency, and products/redis.sh has no license for it" ;;
        esac
    done

    if grep -q 'fast_float_strtod\.o' "$src/src/Makefile"; then
        add_license_from_comment "$package" fast_float "$src/src/fast_float_strtod.c" "MIT License"
    fi

    # Some code in Redis 8 keeps the BSD license. Its files name REDISCONTRIBUTIONS.txt.
    if [ -f "$src/REDISCONTRIBUTIONS.txt" ]; then
        add_license "$package" redis-contributions "$src/REDISCONTRIBUTIONS.txt"
    fi

    add_redis_source_notices "$package" "$src"
}

# Redis has code of other authors in its own files, for example LZF and SipHash. Their licenses are
# only in comments. redis-source-notices.txt has each different notice one time, after the name of
# its file.
add_redis_source_notices() {
    local package="$1" src="$2" folders="src" dependency

    if [ -d "$src/modules/vector-sets" ]; then
        folders="$folders modules/vector-sets"
    fi

    for dependency in $(sed -n 's/^DEPENDENCY_TARGETS=//p' "$src/src/Makefile"); do
        folders="$folders deps/$dependency"
    done

    (
        cd "$src"
        find $folders -name '*.[ch]' -type f | LC_ALL=C sort | LC_ALL=C xargs awk '
            function check(comment, file) {
                if (comment ~ /Redistribution and use|Permission is hereby granted|Permission to use, copy|provided .as-is|presented "as is"|To the extent possible under law|[Pp]ublic [Dd]omain|licensed under|MIT license/ && !seen[comment]++) {
                    printf "%s\n\n%s\n", file, comment
                }
            }
            FNR == 1 { if (lines != "") check(lines, previous); inside = 0; lines = ""; previous = FILENAME }
            inside { block = block $0 "\n"; if (/\*\//) { inside = 0; check(block, FILENAME) } next }
            /^[[:space:]]*\/\// { lines = lines $0 "\n"; next }
            lines != "" { check(lines, FILENAME); lines = "" }
            /\/\*/ { block = $0 "\n"; if (/\*\//) check(block, FILENAME); else inside = 1 }
            END { if (lines != "") check(lines, previous) }
        '
    ) > "$package/licenses/redis-source-notices.txt" || fail "the notices in the source files of Redis could not be read"
}

redis_source() {
    case "$1" in
        7.2) echo redis-7.2 ;;
        8.2) echo redis-8.2 ;;
        8) echo redis-8 ;;
        *) fail "usage: ./build.sh redis <7.2|8.2|8>" ;;
    esac
}

build_product() {
    local source_name version src package license_file license

    source_name="$(redis_source "${1:-}")"
    version="$(source_version "$source_name")"
    src="$(unpack "$source_name")"

    log "Building Redis $version"
    (
        cd "$src"
        run_logged make.log make -j"$JOBS" -C src BUILD_TLS=no MALLOC=libc CC="$CC" V=1 \
            redis-server redis-cli redis-benchmark
    )

    package="$(new_package_dir redis "$version")"
    mkdir -p "$package/bin" "$package/share"
    for program in redis-server redis-cli redis-benchmark; do
        install -m 755 "$src/src/$program" "$package/bin/$program"
    done
    ln -s redis-server "$package/bin/redis-check-aof"
    ln -s redis-server "$package/bin/redis-check-rdb"
    ln -s redis-server "$package/bin/redis-sentinel"
    cp "$src/redis.conf" "$src/sentinel.conf" "$package/share/"

    if [ -f "$src/COPYING" ]; then
        license_file="$src/COPYING"
        license="BSD-3-Clause"
    else
        license_file="$src/LICENSE.txt"
        license="AGPL-3.0-only"
    fi
    add_redis_licenses "$package" "$src" "$license_file"
    write_source_file "$package" "$source_name"

    PACKAGE_LINE="$1" PACKAGE_REVISION="$REDIS_REVISION" archive_package redis "$version" "$license"
}
