# ./build.sh postgresql 14 | 15 | 16 | 17 | 18
#
# PostgreSQL finds its share and lib folders relative to its own bin folder, so the package can
# move as long as its layout stays the same. The contrib modules are included (pgcrypto,
# uuid-ossp, hstore, citext, pg_stat_statements and more). ICU is a shared library in the
# package, as in PHP.

COMPILED_PREFIX=/var/empty/nexus/postgresql

postgresql_source() {
    case "$1" in
        14|15|16|17|18) echo "postgresql-$1" ;;
        *) fail "usage: ./build.sh postgresql <14|15|16|17|18>" ;;
    esac
}

build_product() {
    local source_name version src install package library

    source_name="$(postgresql_source "${1:-}")"
    version="$(source_version "$source_name")"

    ensure_pkgconf
    write_system_pkgconfigs
    build_openssl_shared
    build_icu
    use_absolute_icu_install_names

    src="$(unpack "$source_name")"
    install="$WORK_DIR/postgresql-install-$version"

    log "Configuring PostgreSQL $version"
    (
        cd "$src"
        export PKG_CONFIG_LIBDIR="$OPENSSL_SHARED_DIR/lib/pkgconfig:$STAGE_DIR/lib/pkgconfig"
        export CPPFLAGS="-I$OPENSSL_SHARED_DIR/include $CPPFLAGS"
        export LDFLAGS="-L$OPENSSL_SHARED_DIR/lib $LDFLAGS"
        run_logged configure.log ./configure \
            --prefix="$COMPILED_PREFIX" \
            --with-openssl \
            --with-icu \
            --with-libxml \
            --with-uuid=e2fs \
            --with-libedit-preferred \
            --with-includes="$OPENSSL_SHARED_DIR/include:$STAGE_DIR/include:$SDK_DIR/usr/include/libxml2" \
            --with-libraries="$OPENSSL_SHARED_DIR/lib:$STAGE_DIR/lib" \
            --without-perl --without-python --without-tcl --without-gssapi --without-ldap \
            --without-pam --without-bonjour --without-lz4 --without-zstd

        log "Building PostgreSQL $version"
        run_logged make.log make -j"$JOBS" world-bin

        rm -rf "$install"
        run_logged install.log make install-world-bin DESTDIR="$install"
    )

    package="$(new_package_dir postgresql "$version")"
    cp -a "$install$COMPILED_PREFIX/." "$package/"
    rm -rf "$package/include" "$package/lib/pkgconfig"
    rm -f "$package"/lib/*.a

    for library in icuuc icui18n icudata; do
        cp -a "$STAGE_DIR/lib/lib$library".*dylib "$STAGE_DIR/lib/lib$library.dylib" "$package/lib/"
    done
    cp -a "$OPENSSL_SHARED_DIR"/lib/libssl*.dylib "$OPENSSL_SHARED_DIR"/lib/libcrypto*.dylib "$package/lib/"

    add_license "$package" postgresql "$src/COPYRIGHT"
    add_license "$package" openssl "$WORK_DIR/openssl-$(source_version openssl)/LICENSE.txt"
    add_license "$package" icu "$WORK_DIR/icu-$(source_version icu)/LICENSE"
    write_source_file "$package" "$source_name" openssl icu

    PACKAGE_LINE="$1" archive_package postgresql "$version" "PostgreSQL"
}
