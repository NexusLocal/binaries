# The compiled-in ServerRoot is a folder that only root can create. Nexus always starts httpd
# with -d for the ServerRoot and -f for the configuration file.
HTTPD_PREFIX=/var/empty/nexus/httpd
COMPILED_PREFIX="$HTTPD_PREFIX"

HTTPD_SOURCES="httpd apr apr-util pcre2 openssl nghttp2 brotli"

build_product() {
    local version src install package

    ensure_pkgconf
    ensure_cmake
    ensure_ninja
    write_system_pkgconfigs

    build_openssl
    build_autotools_dependency pcre2 --enable-jit
    build_cmake_dependency brotli -DBROTLI_DISABLE_TESTS=ON
    build_cmake_dependency nghttp2 \
        -DENABLE_LIB_ONLY=ON -DBUILD_STATIC_LIBS=ON -DENABLE_DOC=OFF -DBUILD_TESTING=OFF

    version="$(source_version httpd)"
    src="$(unpack httpd)"
    rm -rf "$src/srclib/apr" "$src/srclib/apr-util"
    mv "$(unpack apr)" "$src/srclib/apr"
    mv "$(unpack apr-util)" "$src/srclib/apr-util"
    install="$WORK_DIR/httpd-install-$version"

    log "Configuring Apache httpd $version"
    (
        cd "$src"
        run_logged configure.log ./configure \
            --prefix="$HTTPD_PREFIX" \
            --with-included-apr \
            --disable-util-dso \
            --with-crypto \
            --with-openssl="$STAGE_DIR" \
            --with-expat="$SDK_DIR/usr" \
            --without-sqlite2 --without-sqlite3 --without-pgsql --without-mysql \
            --without-oracle --without-odbc --without-freetds --without-berkeley-db --without-gdbm \
            --without-ndbm --without-ldap \
            --with-pcre="$STAGE_DIR/bin/pcre2-config" \
            --with-ssl="$STAGE_DIR" \
            --with-nghttp2="$STAGE_DIR" \
            --with-brotli="$STAGE_DIR" \
            --with-libxml2="$SDK_DIR/usr/include/libxml2" \
            --enable-mpms-shared=all \
            --enable-mods-shared=reallyall \
            --disable-lua \
            --disable-md \
            --disable-socache-dc

        log "Building Apache httpd $version"
        run_logged make.log make -j"$JOBS"

        rm -rf "$install"
        run_logged install.log make install DESTDIR="$install"
    )

    package="$(new_package_dir httpd "$version")"
    cp -R "$install$HTTPD_PREFIX/." "$package/"
    rm -rf "$package/build" "$package/include" "$package/man" "$package/manual" \
        "$package/htdocs" "$package/cgi-bin" "$package/logs" "$package/bin/apxs" \
        "$package/bin/apachectl" "$package/bin/envvars" "$package/bin/envvars-std" \
        "$package/bin/dbmmanage" "$package/lib/pkgconfig"
    rm -f "$package"/lib/*.la "$package"/lib/*.a "$package"/lib/*.exp "$package"/modules/mod_example_*.so

    add_license "$package" httpd "$src/LICENSE"
    add_license "$package" httpd-notice "$src/NOTICE"
    add_license "$package" apr "$src/srclib/apr/LICENSE"
    add_license "$package" apr-util "$src/srclib/apr-util/LICENSE"
    add_license "$package" pcre2 "$WORK_DIR/pcre2-$(source_version pcre2)/LICENCE.md"
    add_license "$package" openssl "$WORK_DIR/openssl-$(source_version openssl)/LICENSE.txt"
    add_license "$package" nghttp2 "$WORK_DIR/nghttp2-$(source_version nghttp2)/COPYING"
    add_license "$package" brotli "$WORK_DIR/brotli-$(source_version brotli)/LICENSE"
    write_source_file "$package" $HTTPD_SOURCES

    archive_package httpd "$version" "Apache-2.0"
}
