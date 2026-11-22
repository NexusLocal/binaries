# ./build.sh postgresql 14 | 15 | 16 | 17 | 18 | 19
#
# PostgreSQL finds its share and lib folders relative to its own bin folder, so the package can
# move as long as its layout stays the same. The contrib modules are included (pgcrypto,
# uuid-ossp, hstore, citext, pg_stat_statements and more). ICU is a shared library in the
# package, as in PHP.

COMPILED_PREFIX=/var/empty/nexus/postgresql

# Revision 2 added pgvector and the licenses of the code of other authors. Revision 3 adds PostGIS
# and pgRouting.
POSTGRESQL_REVISION=3

# The libraries of PostGIS that the package has as shared libraries: GEOS and GMP have the LGPL
# license, and more than one file uses GEOS and PROJ.
POSTGIS_SHARED_LIBRARIES="geos geos_c proj gmp"
POSTGIS_LIBRARIES="geos proj gmp json-c protobuf-c"

# The license files of PostGIS, pgRouting and their libraries. Each line gives the name in licenses/,
# the source in sources.lock and the file in that source. The text of the LGPL 3 of GMP adds to the
# text of the GPL 3. PostGIS has ryu, uthash, FlatBuffers and wagyu in its source.
POSTGIS_LICENSES="
postgis postgis COPYING
postgis-notice postgis LICENSE.TXT
postgis-ryu postgis deps/ryu/LICENSE
postgis-ryu-apache postgis deps/ryu/LICENSE-Apache2
postgis-ryu-boost postgis deps/ryu/LICENSE-Boost
postgis-uthash postgis deps/uthash/LICENSE
postgis-flatbuffers postgis deps/flatgeobuf/include/flatbuffers/LICENSE
postgis-wagyu postgis deps/wagyu/LICENSE.wagyu
postgis-wagyu-geometry postgis deps/wagyu/LICENSE.geometry
pgrouting pgrouting LICENSE
pgrouting-boost pgrouting BOOST_LICENSE_1_0.txt
boost boost LICENSE_1_0.txt
geos geos COPYING
proj proj COPYING
gmp gmp COPYING.LESSERv3
gmp-gpl gmp COPYINGv3
json-c json-c COPYING
protobuf-c protobuf-c LICENSE
"

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
        *) echo "pgvector postgis pgrouting" ;;
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
        "Rights are granted|You may redistribute|give permission|retained in all copies|copyrighted by|Andrew Gierth|Oliver Elphick"
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

build_postgis_dependencies() {
    build_gmp
    build_geos
    build_proj
    build_cmake_dependency json-c -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DDISABLE_WERROR=ON -DDISABLE_EXTRA_LIBS=ON
    build_protobuf_c
}

# Without raster (it needs GDAL), SFCGAL and the tools with a window. Topology and the vector tiles
# are part of it. protoc-c comes from protobuf-c. The folders of the extensions use a MKDIR_P with a
# path that does not exist there. mandir keeps the manual pages out of /usr/local.
build_postgis() {
    local pg_config="$1" src

    build_postgis_dependencies
    src="$(unpack postgis)"

    log "Building PostGIS $(source_version postgis)"
    (
        cd "$src"
        export PATH="$STAGE_DIR/bin:$PATH"
        run_logged configure.log ./configure \
            --with-pgconfig="$pg_config" \
            --with-geosconfig="$STAGE_DIR/bin/geos-config" \
            --with-projdir="$STAGE_DIR" \
            --with-jsondir="$STAGE_DIR" \
            --with-protobufdir="$STAGE_DIR" \
            --without-raster --without-gui --without-gettext --without-interrupt-tests \
            --without-phony-revision
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install mandir="$src/nexus-man" MKDIR_P="mkdir -p"
    )
}

# Only the headers of Boost. From PostgreSQL 16 on, a module of PostgreSQL has the suffix .dylib.
# Earlier it has .so.
build_pgrouting() {
    local pg_config="$1" line="$2" src suffix=".so"

    [ "$line" -lt 16 ] || suffix=".dylib"
    ensure_cmake
    ensure_ninja
    unpack boost > /dev/null
    src="$(unpack pgrouting)"

    log "Building pgRouting $(source_version pgrouting)"
    (
        cd "$src"
        run_logged configure.log cmake -S . -B nexus-build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/Applications/MAMP/Library" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_SHARED_MODULE_SUFFIX_CXX="$suffix" \
            -DBOOST_ROOT="$WORK_DIR/boost-$(source_version boost)" \
            -DBoost_INCLUDE_DIR="$WORK_DIR/boost-$(source_version boost)" \
            -DPOSTGRESQL_PG_CONFIG="$pg_config" \
            -DWITH_DOC=OFF -DWITH_ALL_DOC=OFF
        run_logged build.log cmake --build nexus-build
        run_logged install.log cmake --install nexus-build
    )
}

add_postgis_licenses() {
    local package="$1" name source_name file

    while read -r name source_name file; do
        [ -n "$name" ] || continue
        add_license "$package" "$name" "$WORK_DIR/$source_name-$(source_version "$source_name")/$file"
    done <<< "$POSTGIS_LICENSES"

    for name in "postgis liblwgeom postgis topology libpgcommon loader deps" "geos src include capi" "proj src include"; do
        set -- $name
        source_name="$1"
        shift
        (
            cd "$WORK_DIR/$source_name-$(source_version "$source_name")"
            find "$@" -type f \( -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.hpp' \)
        ) | add_source_notices "$package" "$source_name-source-notices" "$WORK_DIR/$source_name-$(source_version "$source_name")"
    done
}

build_product() {
    local source_name version src install package library extension extensions license="PostgreSQL"

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
        "build_$extension" "$install$COMPILED_PREFIX/bin/pg_config" "$1"
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

    if [ -n "$extensions" ]; then
        for library in $POSTGIS_SHARED_LIBRARIES; do
            cp -a "$STAGE_DIR/lib/lib$library".*dylib "$STAGE_DIR/lib/lib$library.dylib" "$package/lib/"
        done
        add_license "$package" pgvector "$WORK_DIR/pgvector-$(source_version pgvector)/LICENSE"
        add_postgis_licenses "$package"
        license="PostgreSQL AND GPL-2.0-or-later"
        write_source_file "$package" "$source_name" openssl icu $extensions $POSTGIS_LIBRARIES boost
    else
        write_source_file "$package" "$source_name" openssl icu
    fi

    PACKAGE_LINE="$1" PACKAGE_REVISION="$POSTGRESQL_REVISION" archive_package postgresql "$version" "$license"
}
