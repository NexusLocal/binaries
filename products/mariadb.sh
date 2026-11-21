# ./build.sh mariadb 10.11 | 11.4 | 11.8 | 12.3
#
# MariaDB publishes no builds for macOS, so it is compiled. The heavy optional engines and
# plugins (ColumnStore, RocksDB, Mroonga, Spider, CONNECT, OQGraph, S3, Galera and the
# compression providers) are left out. InnoDB, Aria, MyISAM, MEMORY, CSV and ARCHIVE stay.

COMPILED_PREFIX=/var/empty/nexus/mariadb

# Revision 2 adds the licenses of the libraries in the package and the THIRDPARTY file of MariaDB.
# It also takes the header library fmt from sources.lock.
MARIADB_REVISION=2

# mariadb-install-db needs my_print_defaults and resolveip. The mysql* names are links to these
# programs, so tools that call mysqldump keep working.
MARIADB_PROGRAMS="mariadbd mariadb mariadb-dump mariadb-admin mariadb-check mariadb-import
mariadb-show mariadb-binlog mariadb-upgrade mariadb-tzinfo-to-sql my_print_defaults resolveip
perror"

keep_only_listed_programs() {
    local bin="$1" path name

    for path in "$bin"/*; do
        name="$(basename "$path")"
        [ -L "$path" ] && continue
        case " $(echo $MARIADB_PROGRAMS) " in
            *" $name "*) ;;
            *) rm -f "$path" ;;
        esac
    done

    for path in "$bin"/*; do
        if [ -L "$path" ] && [ ! -e "$path" ]; then
            rm -f "$path"
        fi
    done
}

strip_local_symbols() {
    local path

    macho_files "$1" | while IFS= read -r path; do
        chmod u+w "$path"
        strip -x "$path" 2> /dev/null || true
    done
}

# THIRDPARTY lists the code from other projects in the source of MariaDB. InnoDB has code from
# Google and Percona, and the HandlerSocket plugin and the sys schema have their own license
# files. libmariadb is the client library with the LGPL. OpenSSL and PCRE2 are linked
# statically. fmt is a header library in the server. The bundled zlib and readline are not
# built, because the package uses those of macOS.
add_mariadb_licenses() {
    local package="$1" src="$2" fmt="$3" pcre2
    pcre2="$WORK_DIR/pcre2-$(source_version pcre2)"

    add_license "$package" mariadb "$src/COPYING"
    add_license "$package" mariadb-thirdparty "$src/THIRDPARTY"
    add_license "$package" innodb-google "$src/storage/innobase/COPYING.Google"
    add_license "$package" innodb-percona "$src/storage/innobase/COPYING.Percona"
    add_license "$package" handlersocket "$src/plugin/handler_socket/handlersocket/COPYRIGHT.txt"
    add_license "$package" libhsclient "$src/plugin/handler_socket/libhsclient/COPYRIGHT.txt"
    add_license "$package" server-audit "$src/plugin/server_audit/COPYING"
    add_license "$package" test-sql-service "$src/plugin/test_sql_service/COPYING"
    add_license "$package" sys-schema "$src/scripts/sys_schema/LICENSE"
    add_license "$package" sys-schema-copying "$src/scripts/sys_schema/COPYING"
    add_license "$package" libmariadb "$src/libmariadb/COPYING.LIB"
    add_license "$package" openssl "$WORK_DIR/openssl-$(source_version openssl)/LICENSE.txt"
    add_license "$package" pcre2 "$pcre2/LICENCE.md"
    add_license "$package" pcre2-sljit "$pcre2/deps/sljit/LICENSE"
    add_license "$package" fmt "$fmt/LICENSE"
}

# Without WITH_LIBFMT=system the build of MariaDB downloads fmt itself, outside sources.lock and
# with only an MD5 check. So the build gets the fmt of sources.lock. It must be the version that
# cmake/libfmt.cmake of MariaDB names.
unpack_fmt() {
    local src="$1" version dir
    version="$(source_version fmt)"

    grep -q "fmt/releases/download/$version/fmt-$version.zip" "$src/cmake/libfmt.cmake" ||
        fail "sources.lock has fmt $version, but cmake/libfmt.cmake of MariaDB names another version. Both need the same version."

    dir="$(unpack fmt)"
    [ -f "$dir/fmt-$version/include/fmt/args.h" ] || fail "the archive of fmt $version has no fmt-$version/include/fmt/args.h"
    printf '%s\n' "$dir/fmt-$version"
}

mariadb_source() {
    case "$1" in
        10.11|11.4|11.8|12.3) echo "mariadb-$1" ;;
        *) fail "usage: ./build.sh mariadb <10.11|11.4|11.8|12.3>" ;;
    esac
}

build_product() {
    local source_name version src fmt install package

    source_name="$(mariadb_source "${1:-}")"
    version="$(source_version "$source_name")"

    ensure_pkgconf
    ensure_cmake
    ensure_ninja
    write_system_pkgconfigs
    build_openssl
    build_autotools_dependency pcre2 --enable-jit

    src="$(unpack "$source_name")"
    fmt="$(unpack_fmt "$src")"
    install="$WORK_DIR/mariadb-install-$version"

    log "Configuring MariaDB $version"
    (
        cd "$src"
        run_logged configure.log cmake -S . -B nexus-build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$COMPILED_PREFIX" \
            -DINSTALL_LAYOUT=STANDALONE \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_PREFIX_PATH="$STAGE_DIR" \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/Applications/MAMP/Library" \
            -DWITH_SSL="$STAGE_DIR" \
            -DWITH_PCRE=system \
            -DWITH_ZLIB=system \
            -DWITH_LIBFMT=system \
            -DLIBFMT_INCLUDE_DIR="$fmt/include" \
            -DWITH_UNIT_TESTS=OFF \
            -DWITH_EMBEDDED_SERVER=OFF \
            -DWITH_WSREP=OFF \
            -DWITH_SYSTEMD=no \
            -DPLUGIN_COLUMNSTORE=NO \
            -DPLUGIN_ROCKSDB=NO \
            -DPLUGIN_MROONGA=NO \
            -DPLUGIN_SPIDER=NO \
            -DPLUGIN_OQGRAPH=NO \
            -DPLUGIN_CONNECT=NO \
            -DPLUGIN_S3=NO \
            -DPLUGIN_TOKUDB=NO \
            -DPLUGIN_SPHINX=NO \
            -DPLUGIN_AUTH_GSSAPI=NO \
            -DPLUGIN_AUTH_PAM=NO \
            -DPLUGIN_AUTH_PAM_V1=NO \
            -DPLUGIN_HASHICORP_KEY_MANAGEMENT=NO \
            -DPLUGIN_PROVIDER_BZIP2=NO \
            -DPLUGIN_PROVIDER_LZ4=NO \
            -DPLUGIN_PROVIDER_LZMA=NO \
            -DPLUGIN_PROVIDER_LZO=NO \
            -DPLUGIN_PROVIDER_SNAPPY=NO

        log "Building MariaDB $version"
        run_logged build.log cmake --build nexus-build

        rm -rf "$install"
        export DESTDIR="$install"
        run_logged install.log cmake --install nexus-build
    )

    package="$(new_package_dir mariadb "$version")"
    cp -a "$install$COMPILED_PREFIX/." "$package/"
    rm -rf "$package/mysql-test" "$package/mariadb-test" "$package/sql-bench" "$package/include" \
        "$package/man" "$package/docs" "$package/lib/pkgconfig" "$package/support-files/systemd"
    rm -f "$package"/lib/*.a
    keep_only_listed_programs "$package/bin"
    strip_local_symbols "$package"

    add_mariadb_licenses "$package" "$src" "$fmt"
    write_source_file "$package" "$source_name" openssl pcre2 fmt

    PACKAGE_REVISION="$MARIADB_REVISION" archive_package mariadb "$version" "GPL-2.0-only"
}
