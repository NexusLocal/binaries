SDK_DIR="$(xcrun --show-sdk-path)"

dependency_built() {
    [ -f "$STAGE_DIR/.built/$1-$(source_version "$1")" ]
}

mark_built() {
    mkdir -p "$STAGE_DIR/.built"
    touch "$STAGE_DIR/.built/$1-$(source_version "$1")"
}

build_autotools_dependency() {
    local name="$1" dir
    shift

    dependency_built "$name" && return 0
    log "Building $name $(source_version "$name") (static)"

    dir="$(unpack "$name")"
    (
        cd "$dir"
        run_logged configure.log ./configure --prefix="$STAGE_DIR" --libdir="$STAGE_DIR/lib" --disable-shared --enable-static "$@"
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install
    )
    mark_built "$name"
}

build_cmake_dependency() {
    local name="$1" dir
    shift

    dependency_built "$name" && return 0
    log "Building $name $(source_version "$name") (static)"

    ensure_cmake
    ensure_ninja

    dir="$(unpack "$name")"
    (
        cd "$dir"
        run_logged configure.log cmake -S . -B nexus-build -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$STAGE_DIR" \
            -DCMAKE_INSTALL_LIBDIR=lib \
            -DCMAKE_PREFIX_PATH="$STAGE_DIR" \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/Applications/MAMP/Library" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
            -DBUILD_SHARED_LIBS=OFF \
            "$@"
        run_logged build.log cmake --build nexus-build
        run_logged install.log cmake --install nexus-build
    )
    mark_built "$name"
}

build_openssl() {
    dependency_built openssl && return 0
    log "Building openssl $(source_version openssl) (static)"

    local dir
    dir="$(unpack openssl)"
    (
        cd "$dir"
        run_logged configure.log ./Configure darwin64-arm64-cc no-shared no-tests no-docs \
            --prefix="$STAGE_DIR" --libdir=lib --openssldir=/private/etc/ssl
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install_sw
    )
    mark_built openssl
}

# A shared OpenSSL in its own folder, so the other packages keep linking the static one. libpq
# refuses a static OpenSSL: its build checks that libpq calls no function that ends the process,
# and a static libcrypto brings atexit and pthread_exit into libpq.
OPENSSL_SHARED_DIR="$STAGE_DIR/openssl-shared"

build_openssl_shared() {
    [ -f "$OPENSSL_SHARED_DIR/.built-$(source_version openssl)" ] && return 0
    log "Building openssl $(source_version openssl) (shared)"

    local dir
    dir="$(unpack openssl)"
    (
        cd "$dir"
        run_logged configure.log ./Configure darwin64-arm64-cc shared no-tests no-docs \
            --prefix="$OPENSSL_SHARED_DIR" --libdir=lib --openssldir=/private/etc/ssl
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install_sw
    )
    touch "$OPENSSL_SHARED_DIR/.built-$(source_version openssl)"
}

# A static libpq for the pgsql and pdo_pgsql extensions of PHP, from the newest PostgreSQL. Only
# the static library is built, so the check of the PostgreSQL build against a static OpenSSL in
# the shared libpq does not apply. One combined libpq.a in its own folder holds libpq,
# libpgcommon, libpgport and OpenSSL, so -lpq alone links everything.
LIBPQ_DIR="$STAGE_DIR/libpq"

build_libpq() {
    local version stamp dir build
    version="$(source_version postgresql-18)"
    stamp="$LIBPQ_DIR/.built-$version"

    [ -f "$stamp" ] && return 0
    log "Building libpq $version (static)"

    dir="$(unpack postgresql-18)"
    build="$WORK_DIR/libpq-install"
    rm -rf "$LIBPQ_DIR" "$build"
    mkdir -p "$LIBPQ_DIR/include" "$LIBPQ_DIR/lib"
    (
        cd "$dir"
        run_logged configure.log ./configure --prefix="$build" \
            --with-openssl --without-icu --without-readline --without-zlib --without-lz4 --without-zstd \
            --with-includes="$STAGE_DIR/include" --with-libraries="$STAGE_DIR/lib"
        run_logged make-headers.log make -C src/backend generated-headers
        run_logged make-port.log make -j"$JOBS" -C src/port
        run_logged make-common.log make -j"$JOBS" -C src/common
        run_logged make-libpq.log make -j"$JOBS" -C src/interfaces/libpq all-static-lib
        install -m 644 src/interfaces/libpq/libpq-fe.h src/interfaces/libpq/libpq-events.h \
            src/include/postgres_ext.h "$LIBPQ_DIR/include/"
        mkdir -p "$LIBPQ_DIR/include/libpq"
        install -m 644 src/include/libpq/libpq-fs.h "$LIBPQ_DIR/include/libpq/"
        run_or_fail /usr/bin/libtool -static -o "$LIBPQ_DIR/lib/libpq.a" \
            src/interfaces/libpq/libpq.a src/common/libpgcommon_shlib.a src/port/libpgport_shlib.a \
            "$STAGE_DIR/lib/libssl.a" "$STAGE_DIR/lib/libcrypto.a"
    )
    touch "$stamp"
}

# ICU stays a shared library, so the CLI and FPM binaries of PHP share one copy of its 30 MB of
# data. The relocation step changes its links to @rpath.
build_icu() {
    dependency_built icu && return 0
    log "Building icu $(source_version icu) (shared)"

    local dir
    dir="$(unpack icu)"
    (
        cd "$dir/source"
        run_logged configure.log ./runConfigureICU MacOSX \
            --prefix="$STAGE_DIR" --libdir="$STAGE_DIR/lib" \
            --enable-shared --disable-static \
            --disable-tests --disable-samples --disable-extras --disable-layoutex \
            --with-data-packaging=library
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install
    )
    mark_built icu
}

# ICU gives its libraries bare install names such as libicuuc.79.dylib, so a program that
# configure builds and runs cannot find them. Absolute names into the stage folder fix that, and
# the relocation step later changes them to @rpath links.
use_absolute_icu_install_names() {
    local library dependency

    for library in "$STAGE_DIR"/lib/libicu*.dylib; do
        [ -L "$library" ] && continue

        run_or_fail install_name_tool -id "$STAGE_DIR/lib/$(basename "$(otool -D "$library" | tail -n 1)")" "$library"

        otool -L "$library" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
            case "$dependency" in
                libicu*) run_or_fail install_name_tool -change "$dependency" "$STAGE_DIR/lib/$dependency" "$library" ;;
            esac
        done

        run_or_fail codesign --force --sign - "$library"
    done
}

# libintl has the LGPL license, so it stays a shared library that a user can replace.
build_gettext() {
    dependency_built gettext && return 0
    log "Building gettext $(source_version gettext) (libintl, shared)"

    local dir
    dir="$(unpack gettext)"
    (
        cd "$dir/gettext-runtime"
        run_logged configure.log ./configure --prefix="$STAGE_DIR" --libdir="$STAGE_DIR/lib" \
            --enable-shared --disable-static --disable-java --disable-csharp --disable-libasprintf \
            --without-libiconv-prefix --without-libintl-prefix
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install
    )
    mark_built gettext
}

write_system_pkgconfig() {
    local name="$1" version="$2" cflags="$3" libs="$4"

    cat > "$STAGE_DIR/lib/pkgconfig/$name.pc" <<EOF
Name: $name
Description: $name from the macOS SDK
Version: $version
Cflags: $cflags
Libs: $libs
EOF
}

# pkg-config files for the libraries that macOS provides, so configure scripts find the SDK
# copies and never a copy from MAMP or Homebrew.
write_system_pkgconfigs() {
    local include="$SDK_DIR/usr/include"

    write_system_pkgconfig libxml-2.0 2.9.13 "-I$include/libxml2" "-lxml2"
    write_system_pkgconfig libxslt 1.1.35 "-I$include/libxml2" "-lxslt -lxml2"
    write_system_pkgconfig libexslt 0.8.20 "-I$include/libxml2" "-lexslt -lxslt -lxml2"
    write_system_pkgconfig libcurl 8.7.1 "" "-lcurl"
    write_system_pkgconfig sqlite3 3.54.0 "" "-lsqlite3"
    write_system_pkgconfig zlib 1.2.12 "" "-lz"
    write_system_pkgconfig libedit 3.0 "" "-ledit -lncurses"
}

# The LDAP framework of macOS 27 no longer exports ldap_destroy, the sort and VLV controls,
# the password policy control and ldap_exop_passwd, and PHP 8.4 and newer need them. So PHP
# gets its own OpenLDAP client libraries, linked to the OpenSSL in the stage folder.
build_openldap() {
    dependency_built openldap && return 0
    log "Building openldap $(source_version openldap) (client libraries, static)"

    local dir
    dir="$(unpack openldap)"
    (
        cd "$dir"
        run_logged configure.log ./configure --prefix="$STAGE_DIR" --libdir="$STAGE_DIR/lib" \
            --disable-shared --enable-static --disable-slapd --disable-debug \
            --with-tls=openssl --without-cyrus-sasl --without-fetch
        run_logged depend.log make depend
        run_logged make.log make -j"$JOBS" -C include
        run_logged make-libraries.log make -j"$JOBS" -C libraries
        run_logged install-include.log make -C include install
        run_logged install-libraries.log make -C libraries install
    )
    mark_built openldap
}
