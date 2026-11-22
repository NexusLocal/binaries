# ./build.sh postgresql 14 | 15 | 16 | 17 | 18 | 19
#
# PostgreSQL finds its share and lib folders relative to its own bin folder, so the package can
# move as long as its layout stays the same. The contrib modules are included (pgcrypto,
# uuid-ossp, hstore, citext, pg_stat_statements and more). ICU is a shared library in the
# package, as in PHP.

COMPILED_PREFIX=/var/empty/nexus/postgresql

# Revision 2 adds pgvector and the licenses of the code of other authors.
POSTGRESQL_REVISION=2

postgresql_source() {
    case "$1" in
        14|15|16|17|18|19) echo "postgresql-$1" ;;
        *) fail "usage: ./build.sh postgresql <14|15|16|17|18|19>" ;;
    esac
}

# PostgreSQL 14 has no security fixes since 2026-11-12 and gets no extensions. The next pgvector
# does not support it.
postgresql_extensions() {
    case "$1" in
        14) ;;
        *) echo pgvector ;;
    esac
}

# PostgreSQL has code of other authors, for example the regular expressions of Henry Spencer. The
# license of the Snowball stemmers is not in its source. licenses/snowball.txt is COPYING of
# Snowball 3.2.0. The Unicode license of the Unicode tables is in the license of ICU.
add_postgresql_licenses() {
    local package="$1" src="$2"

    add_license "$package" postgresql "$src/COPYRIGHT"
    add_license "$package" postgresql-regex "$src/src/backend/regex/COPYRIGHT"
    add_license "$package" snowball "$NEXUS_REPO/licenses/snowball.txt"
    (
        cd "$src"
        find contrib src -name '*.[chly]' -type f -not -path 'src/test/*' -not -path 'src/tools/*' \
            -not -path 'src/pl/plperl/*' -not -path 'src/pl/plpython/*' -not -path 'src/pl/tcl/*'
    ) | add_source_notices "$package" postgresql-source-notices "$src" \
        "Rights are granted|retained in all copies|copyrighted by|Andrew Gierth|Oliver Elphick"
}

# pg_config gives each path from its own location. So the extension goes into the same folder as
# PostgreSQL. An empty OPTFLAGS is the way of pgvector to build for other Macs than this one.
build_pgvector() {
    local pg_config="$1" src
    src="$(unpack pgvector)"

    log "Building pgvector $(source_version pgvector)"
    (
        cd "$src"
        run_logged make.log make -j"$JOBS" PG_CONFIG="$pg_config" OPTFLAGS=""
        run_logged install.log make install PG_CONFIG="$pg_config" OPTFLAGS=""
    )
}

build_product() {
    local source_name version src install package library extension extensions

    source_name="$(postgresql_source "${1:-}")"
    version="$(source_version "$source_name")"
    extensions="$(postgresql_extensions "$1")"

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

    for extension in $extensions; do
        "build_$extension" "$install$COMPILED_PREFIX/bin/pg_config"
    done

    package="$(new_package_dir postgresql "$version")"
    cp -a "$install$COMPILED_PREFIX/." "$package/"
    rm -rf "$package/include" "$package/lib/pkgconfig"
    rm -f "$package"/lib/*.a

    for library in icuuc icui18n icudata; do
        cp -a "$STAGE_DIR/lib/lib$library".*dylib "$STAGE_DIR/lib/lib$library.dylib" "$package/lib/"
    done
    cp -a "$OPENSSL_SHARED_DIR"/lib/libssl*.dylib "$OPENSSL_SHARED_DIR"/lib/libcrypto*.dylib "$package/lib/"

    add_postgresql_licenses "$package" "$src"
    add_license "$package" openssl "$WORK_DIR/openssl-$(source_version openssl)/LICENSE.txt"
    add_license "$package" icu "$WORK_DIR/icu-$(source_version icu)/LICENSE"
    for extension in $extensions; do
        add_license "$package" "$extension" "$WORK_DIR/$extension-$(source_version "$extension")/LICENSE"
    done
    write_source_file "$package" "$source_name" openssl icu $extensions

    PACKAGE_LINE="$1" PACKAGE_REVISION="$POSTGRESQL_REVISION" archive_package postgresql "$version" "PostgreSQL"
}
