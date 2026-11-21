# The compiled-in prefix is a folder that only root can create, so a PHP that runs without -c
# can never load a php.ini that another user put there. Nexus always passes the php.ini and the
# extension folder itself.
PHP_PREFIX=/var/empty/nexus/php

# There is no libargon2. libsodium and libargon2 both export blake2b_init, blake2b_update and
# blake2b_final, so in a static link argon2 called the libsodium versions with a smaller struct
# and overflowed its stack. ext/sodium provides PASSWORD_ARGON2I and PASSWORD_ARGON2ID itself.
PHP_LIBRARIES="openssl icu oniguruma libsodium libzip libpng libjpeg-turbo libwebp freetype gettext libyaml openldap postgresql-18 imagemagick"
PHP_EXTENSIONS="redis xdebug pcov apcu yaml imagick mailparse"

# Revision 2 added mailparse. Revision 3 added the license of each program in the package.
# Revision 4 adds the licenses of the libraries in the source of PHP.
PHP_REVISION=4

# The license files of the programs in the package besides PHP and igbinary. Each line gives the
# name in licenses/, the source in sources.lock and the file in that source. The extensions,
# OpenSSL, ICU, libintl, libpq and the static libraries are all in the package. So their licenses
# go with it. FreeType offers two licenses. The package uses the FreeType License (FTL). The BDF
# and PCF drivers of FreeType have their own license in their README.
PHP_LICENSES="
openssl openssl LICENSE.txt
icu icu LICENSE
libintl gettext gettext-runtime/intl/COPYING.LIB
oniguruma oniguruma COPYING
libsodium libsodium LICENSE
libzip libzip LICENSE
libpng libpng LICENSE
libjpeg-turbo libjpeg-turbo LICENSE.md
libjpeg-turbo-ijg libjpeg-turbo README.ijg
libwebp libwebp COPYING
freetype freetype LICENSE.TXT
freetype-ftl freetype docs/FTL.TXT
freetype-bdf freetype src/bdf/README
freetype-pcf freetype src/pcf/README
libyaml libyaml License
openldap openldap LICENSE
openldap-copyright openldap COPYRIGHT
libpq postgresql-18 COPYRIGHT
imagemagick imagemagick LICENSE
imagemagick-notice imagemagick NOTICE
redis pecl-redis LICENSE
xdebug pecl-xdebug LICENSE
pcov pecl-pcov LICENSE
apcu pecl-apcu LICENSE
apcu-notice pecl-apcu NOTICE
yaml pecl-yaml LICENSE
imagick pecl-imagick LICENSE
mailparse pecl-mailparse LICENSE
"

# igbinary 3.2.16 is the newest stable release and does not compile against PHP 8.5, which
# moved php_smart_string.h. Only the release candidate 3.2.17RC1 supports PHP 8.5.
igbinary_source() {
    if [ "$1" = "8.5" ]; then
        echo pecl-igbinary-rc
        return
    fi

    echo pecl-igbinary
}

add_php_licenses() {
    local package="$1" src="$2" minor="$3" name source_name file

    add_license "$package" php "$src/LICENSE"

    while read -r name source_name file; do
        [ -n "$name" ] || continue
        add_license "$package" "$name" "$WORK_DIR/$source_name-$(source_version "$source_name")/$file"
    done <<< "$PHP_LICENSES"

    source_name="$(igbinary_source "$minor")"
    add_license "$package" igbinary "$WORK_DIR/$source_name-$(source_version "$source_name")/COPYING"

    add_php_source_licenses "$package" "$src" "$minor"
}

# The libraries in the source of PHP that the package contains. PCRE2, libgd and xxHash have their
# license only in a comment. DynASM, the assembler of the JIT, has it in a string in dynasm.lua.
# libudis86 is only for the JIT on Intel, and oci8 is not built. So their licenses stay out.
add_php_source_licenses() {
    local package="$1" src="$2" minor="$3" ir="$2/ext/opcache/jit/ir" dynasm

    add_license "$package" zend "$src/Zend/LICENSE"
    add_license "$package" zend-asm "$src/Zend/asm/LICENSE"
    add_license "$package" tsrm "$src/TSRM/LICENSE"
    add_license "$package" php-fpm "$src/sapi/fpm/LICENSE"
    add_license "$package" libbcmath "$src/ext/bcmath/libbcmath/LICENSE"
    add_license "$package" timelib "$src/ext/date/lib/LICENSE.rst"
    add_license "$package" libmagic "$src/ext/fileinfo/libmagic/LICENSE"
    add_license "$package" libmbfl "$src/ext/mbstring/libmbfl/LICENSE"
    add_license "$package" libavifinfo "$src/ext/standard/libavifinfo/LICENSE"
    add_license_from_comment "$package" pcre2 "$src/ext/pcre/pcre2lib/pcre2.h" "Redistribution and use"
    add_license_from_comment "$package" libgd "$src/ext/gd/libgd/gd.h" "Permission to use"
    add_license_from_comment "$package" xxhash "$src/ext/hash/xxhash/xxhash.h" "Redistribution and use"

    case "$minor" in
        8.2|8.3)
            dynasm="$src/ext/opcache/jit/dynasm/dynasm.lua"
            ;;
        8.4)
            dynasm="$ir/dynasm/dynasm.lua"
            add_license "$package" opcache-jit-ir "$ir/LICENSE"
            add_license "$package" lexbor "$src/ext/dom/lexbor/LICENSE"
            add_license "$package" lexbor-notice "$src/ext/dom/lexbor/NOTICE"
            ;;
        *)
            dynasm="$ir/dynasm/dynasm.lua"
            add_license "$package" opcache-jit-ir "$ir/LICENSE"
            add_license "$package" lexbor "$src/ext/lexbor/LICENSE"
            add_license "$package" lexbor-notice "$src/ext/lexbor/NOTICE"
            add_license "$package" uriparser "$src/ext/uri/uriparser/COPYING.BSD-3-Clause"
            ;;
    esac

    [ -f "$dynasm" ] || fail "license file not found for dynasm: $dynasm"
    awk '/^  copyright =/ { inside = 1; next } inside && /^\]\]/ { exit } inside' "$dynasm" \
        > "$package/licenses/dynasm.txt"
    grep -q "Permission is hereby granted" "$package/licenses/dynasm.txt" \
        || fail "no license text for DynASM in $dynasm"
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
    build_libpq
    build_imagemagick
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
        export PGSQL_CFLAGS="-I$LIBPQ_DIR/include"
        export PGSQL_LIBS="-L$LIBPQ_DIR/lib -lpq"
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
            --with-pgsql="shared,$LIBPQ_DIR" \
            --with-pdo-pgsql="shared,$LIBPQ_DIR" \
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
    PKG_CONFIG="pkg-config --static" build_pecl_extension "$package" pecl-imagick --with-imagick="$STAGE_DIR"
    build_pecl_extension "$package" pecl-mailparse

    add_php_licenses "$package" "$src" "$minor"
    write_source_file "$package" "$source_name" $PHP_LIBRARIES "$(igbinary_source "$minor")" \
        $(for name in $PHP_EXTENSIONS; do echo "pecl-$name"; done)

    PACKAGE_REVISION="$PHP_REVISION" archive_package php "$version" "PHP-3.01"
}
