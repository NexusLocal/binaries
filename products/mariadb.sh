# ./build.sh mariadb 10.11 | 11.4 | 11.8 | 12.3
#
# MariaDB publishes no builds for macOS, so it is compiled. The heavy optional engines and
# plugins (ColumnStore, RocksDB, Mroonga, Spider, CONNECT, OQGraph, S3, Galera and the
# compression providers) are left out. InnoDB, Aria, MyISAM, MEMORY, CSV and ARCHIVE stay.

COMPILED_PREFIX=/var/empty/nexus/mariadb

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

mariadb_source() {
    case "$1" in
        10.11|11.4|11.8|12.3) echo "mariadb-$1" ;;
        *) fail "usage: ./build.sh mariadb <10.11|11.4|11.8|12.3>" ;;
    esac
}

build_product() {
    local source_name version src install package

    source_name="$(mariadb_source "${1:-}")"
    version="$(source_version "$source_name")"

    ensure_pkgconf
    ensure_cmake
    ensure_ninja
    write_system_pkgconfigs
    build_openssl
    build_autotools_dependency pcre2 --enable-jit

    src="$(unpack "$source_name")"
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

    add_license "$package" mariadb "$src/COPYING"
    write_source_file "$package" "$source_name" openssl pcre2

    archive_package mariadb "$version" "GPL-2.0-only"
}
