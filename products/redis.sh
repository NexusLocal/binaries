# ./build.sh redis 7.2 | 8.2 | 8
#
# "8" is the newest Redis 8 line. Redis 7.2 has the BSD license. Redis 8 has three licenses to
# choose from, and Nexus gives it out under the AGPLv3 with a link to the source. Redis 7.4 is not
# built: its only licenses are RSALv2 and SSPLv1.

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
    add_license "$package" redis "$license_file"
    write_source_file "$package" "$source_name"

    archive_package redis "$version" "$license"
}
