# The compiled-in prefix is a folder that only root can create, so a PHP that runs without -c
# can never load a php.ini that another user put there. Nexus always passes the php.ini and the
# extension folder itself.
PHP_PREFIX=/var/empty/nexus/php

# There is no libargon2. libsodium and libargon2 both export blake2b_init, blake2b_update and
# blake2b_final, so in a static link argon2 called the libsodium versions with a smaller struct
# and overflowed its stack. ext/sodium provides PASSWORD_ARGON2I and PASSWORD_ARGON2ID itself.
PHP_LIBRARIES="openssl icu oniguruma libsodium libzip libpng libjpeg-turbo libwebp freetype gettext libyaml openldap"
PHP_EXTENSIONS="redis xdebug pcov apcu yaml"

# igbinary 3.2.16 is the newest stable release and does not compile against PHP 8.5, which
# moved php_smart_string.h. Only the release candidate 3.2.17RC1 supports PHP 8.5.
igbinary_source() {
    if [ "$1" = "8.5" ]; then
        echo pecl-igbinary-rc
        return
    fi

    echo pecl-igbinary
}

build_php_dependencies() {
    ensure_pkgconf
    ensure_cmake
    ensure_ninja
    ensure_autoconf
    write_system_pkgconfigs

    build_openssl
    build_icu
    use_absolute_icu_install_names
    build_autotools_dependency oniguruma
    build_autotools_dependency libsodium
    build_cmake_dependency libzip \
        -DENABLE_COMMONCRYPTO=ON -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=OFF \
        -DENABLE_BZIP2=ON -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
        -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF
    build_autotools_dependency libpng
    build_cmake_dependency libjpeg-turbo -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF
    build_autotools_dependency libwebp \
        --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
    build_autotools_dependency freetype \
        --without-harfbuzz --without-brotli --without-bzip2 --without-png --with-zlib=yes
    build_gettext
    build_autotools_dependency libyaml
    build_openldap
}

make_script_relocatable() {
    local file="$1"

    # PHP 8.2 and 8.3 write extension_dir='...' in single quotes, where ${prefix} would not
    # expand, so such a line becomes double quoted.
    awk -v old="$PHP_PREFIX" '
        !done && /^prefix=/ { print "prefix=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\""; done = 1; next }
        index($0, old) && /^[a-z_]+='\''[^'\''"$`]*'\''$/ { sub(/='\''/, "=\""); sub(/'\''$/, "\"") }
        { gsub(old, "${prefix}"); print }
    ' "$file" > "$file.new"
    mv "$file.new" "$file"
    chmod 755 "$file"

    if grep -q "$PHP_PREFIX" "$file"; then
        fail "$(basename "$file") still contains $PHP_PREFIX"
    fi
}

build_pecl_extension() {
    local package="$1" source_name="$2" dir
    shift 2

    log "Building the PECL extension ${source_name#pecl-} $(source_version "$source_name")"

    dir="$(unpack "$source_name")"
    (
        cd "$dir"
        run_logged phpize.log "$package/bin/phpize"
        run_logged configure.log ./configure --with-php-config="$package/bin/php-config" "$@"
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install
    )
}

build_product() {
    local minor="${1:-}" source_name version src install package opcache=""

    [ -n "$minor" ] || fail "usage: ./build.sh php <8.2|8.3|8.4|8.5>"
    source_name="php-$minor"
    version="$(source_version "$source_name")"

    build_php_dependencies

    src="$(unpack "$source_name")"
    install="$WORK_DIR/php-install-$version"

    if [ "$minor" != "8.5" ]; then
        opcache="--enable-opcache"
    fi

    log "Configuring PHP $version"
    (
        cd "$src"
        export PKG_CONFIG="pkg-config --static"
        export CXXFLAGS="$CXXFLAGS -std=c++17"
        export LIBS="-framework CoreFoundation -lresolv"
        run_logged configure.log ./configure \
            --prefix="$PHP_PREFIX" \
            --with-config-file-path="$PHP_PREFIX/etc" \
            --with-config-file-scan-dir="$PHP_PREFIX/etc/conf.d" \
            --disable-cgi \
            --disable-phpdbg \
            --enable-fpm \
            --without-pear \
            --enable-bcmath \
            --with-bz2="$SDK_DIR/usr" \
            --enable-calendar \
            --with-curl \
            --enable-exif \
            --enable-ftp \
            --enable-gd \
            --with-freetype \
            --with-jpeg \
            --with-webp \
            --with-gettext="$STAGE_DIR" \
            --with-iconv="$SDK_DIR/usr" \
            --enable-intl \
            --with-ldap="$STAGE_DIR" \
            --enable-mbstring \
            --with-mysqli=mysqlnd \
            --with-pdo-mysql=mysqlnd \
            --with-openssl \
            --enable-pcntl \
            --with-pdo-sqlite \
            --with-sqlite3 \
            --with-libedit \
            --enable-soap \
            --enable-sockets \
            --with-sodium \
            --with-xsl \
            --with-zip \
            --with-zlib \
            $opcache

        log "Building PHP $version"
        run_logged make.log make -j"$JOBS"

        rm -rf "$install"
        run_logged install.log make install INSTALL_ROOT="$install"
    )

    package="$(new_package_dir php "$version")"
    cp -R "$install$PHP_PREFIX/." "$package/"
    rm -rf "$package/php/man" "$package/etc"
    mkdir -p "$package/share" "$package/lib"
    cp "$src/php.ini-development" "$src/php.ini-production" "$package/share/"
    for library in icuuc icui18n icuio icudata intl; do
        cp -a "$STAGE_DIR/lib/lib$library".*dylib "$STAGE_DIR/lib/lib$library.dylib" "$package/lib/"
    done

    make_script_relocatable "$package/bin/php-config"
    make_script_relocatable "$package/bin/phpize"

    if [ "$("$package/bin/php-config" --prefix)" != "$package" ]; then
        fail "php-config --prefix does not give the package folder"
    fi

    case "$("$package/bin/php-config" --extension-dir)" in
        "$package"/lib/php/extensions/*) ;;
        *) fail "php-config --extension-dir does not give a folder in the package" ;;
    esac

    build_pecl_extension "$package" "$(igbinary_source "$minor")"
    build_pecl_extension "$package" pecl-redis --enable-redis-igbinary --disable-redis-lz4 --disable-redis-zstd
    build_pecl_extension "$package" pecl-xdebug
    build_pecl_extension "$package" pecl-pcov
    build_pecl_extension "$package" pecl-apcu
    build_pecl_extension "$package" pecl-yaml --with-yaml="$STAGE_DIR"

    add_license "$package" php "$src/LICENSE"
    write_source_file "$package" "$source_name" $PHP_LIBRARIES "$(igbinary_source "$minor")" \
        $(for name in $PHP_EXTENSIONS; do echo "pecl-$name"; done)

    archive_package php "$version" "PHP-3.01"
}
