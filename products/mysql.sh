# ./build.sh mysql 8.0 | 8.4 | 9.7
#
# MySQL is not compiled here. Oracle publishes relocatable builds for macOS on Apple silicon, and
# a source build of three MySQL versions takes hours on CI. This recipe repackages the official
# build: it keeps the server, the client programs, the libraries, the plugins and share/, and
# drops the debug server, the test and MyISAM tools, the static libraries and the headers. Every
# file is signed again by the relocation step, so the package has one consistent signature.
#
# The SOURCE file names the official source archive with its SHA-256. A release of a MySQL
# package also carries that archive, as the GPL asks.

COMPILED_PREFIX=/usr/local/mysql

MYSQL_PROGRAMS="mysqld mysql mysqldump mysqladmin mysqlcheck mysqlimport mysqlshow mysqlbinlog
mysqlslap mysql_tzinfo_to_sql my_print_defaults mysql_config_editor perror mysqlpump mysql_upgrade"

mysql_source() {
    case "$1" in
        8.0|8.4|9.7) echo "mysql-$1" ;;
        *) fail "usage: ./build.sh mysql <8.0|8.4|9.7>" ;;
    esac
}

build_product() {
    local source_name version src package program

    source_name="$(mysql_source "${1:-}")"
    version="$(source_version "$source_name")"

    log "Repackaging the official MySQL $version build"
    src="$(unpack "$source_name")"

    package="$(new_package_dir mysql "$version")"
    mkdir -p "$package/bin"

    for program in $MYSQL_PROGRAMS; do
        if [ -f "$src/bin/$program" ]; then
            install -m 755 "$src/bin/$program" "$package/bin/$program"
        fi
    done

    # mysqld links @loader_path/libprotobuf-lite.24.4.0.dylib, and the official bin/ has links
    # from there to lib/.
    for link in "$src"/bin/*.dylib; do
        [ -L "$link" ] && cp -a "$link" "$package/bin/"
    done

    cp -a "$src/lib" "$src/share" "$package/"
    rm -rf "$package/lib/plugin/debug" "$package/lib/mecab" "$package/lib/pkgconfig" \
        "$package/lib/plugin/libpluginmecab.so"
    rm -f "$package"/lib/*.a "$package"/lib/plugin/ha_example.so "$package"/lib/plugin/ha_mock.so \
        "$package"/lib/plugin/rewrite_example.so

    add_license "$package" mysql "$src/LICENSE"
    write_source_file "$package" "$source_name" "$source_name-source"

    archive_package mysql "$version" "GPL-2.0-only"
}
