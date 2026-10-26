NGINX_SOURCES="nginx openssl pcre2 zlib brotli ngx_brotli headers-more geoip2 libmaxminddb njs"

build_libmaxminddb() {
    local dir
    dir="$(unpack libmaxminddb)"

    log "Building libmaxminddb $(source_version libmaxminddb) (static)"
    (
        cd "$dir"
        ./configure --prefix="$STAGE_DIR" --disable-shared --enable-static --disable-tests > configure.log
        make -j"$JOBS" > make.log
        make install > install.log
    )
}

prepare_ngx_brotli() {
    local module brotli
    module="$(unpack ngx_brotli)"
    brotli="$(unpack brotli)"

    log "Building brotli $(source_version brotli) for ngx_brotli (static)" >&2
    rm -rf "$module/deps/brotli"
    mv "$brotli" "$module/deps/brotli"
    (
        cd "$module/deps/brotli"
        cmake -S . -B out -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
            -DBROTLI_DISABLE_TESTS=ON \
            -DCMAKE_C_FLAGS="$CFLAGS -fPIC" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
            -DCMAKE_OSX_ARCHITECTURES=arm64 > configure.log
        cmake --build out --target brotlienc brotlicommon > build.log
    ) >&2

    printf '%s\n' "$module"
}

build_product() {
    local version nginx openssl pcre2 zlib ngx_brotli headers_more geoip2 njs package

    ensure_cmake
    ensure_ninja
    ensure_pkgconf

    version="$(source_version nginx)"
    nginx="$(unpack nginx)"
    openssl="$(unpack openssl)"
    pcre2="$(unpack pcre2)"
    zlib="$(unpack zlib)"
    headers_more="$(unpack headers-more)"
    geoip2="$(unpack geoip2)"
    njs="$(unpack njs)"
    ngx_brotli="$(prepare_ngx_brotli)"
    build_libmaxminddb

    log "Configuring nginx $version"
    (
        cd "$nginx"
        NJS_LIBXSLT=NO NJS_QUICKJS=NO ./configure \
            --prefix=/usr/local/nexus/nginx \
            --sbin-path=sbin/nginx \
            --modules-path=modules \
            --conf-path=conf/nginx.conf \
            --error-log-path=logs/error.log \
            --pid-path=logs/nginx.pid \
            --lock-path=logs/nginx.lock \
            --http-log-path=logs/access.log \
            --http-client-body-temp-path=temp/client_body \
            --http-proxy-temp-path=temp/proxy \
            --http-fastcgi-temp-path=temp/fastcgi \
            --http-uwsgi-temp-path=temp/uwsgi \
            --http-scgi-temp-path=temp/scgi \
            --with-compat \
            --with-threads \
            --with-pcre="$pcre2" \
            --with-pcre-jit \
            --with-zlib="$zlib" \
            --with-openssl="$openssl" \
            --with-openssl-opt="no-shared no-tests no-docs --openssldir=/private/etc/ssl" \
            --with-http_ssl_module \
            --with-http_v2_module \
            --with-http_v3_module \
            --with-http_realip_module \
            --with-http_addition_module \
            --with-http_sub_module \
            --with-http_dav_module \
            --with-http_flv_module \
            --with-http_mp4_module \
            --with-http_gunzip_module \
            --with-http_gzip_static_module \
            --with-http_auth_request_module \
            --with-http_random_index_module \
            --with-http_secure_link_module \
            --with-http_slice_module \
            --with-http_stub_status_module \
            --with-stream=dynamic \
            --with-stream_ssl_module \
            --with-stream_realip_module \
            --with-stream_ssl_preread_module \
            --with-mail=dynamic \
            --with-mail_ssl_module \
            --add-dynamic-module="$headers_more" \
            --add-dynamic-module="$ngx_brotli" \
            --add-dynamic-module="$geoip2" \
            --add-dynamic-module="$njs/nginx" \
            --with-cc-opt="-I$STAGE_DIR/include" \
            --with-ld-opt="-L$STAGE_DIR/lib" > configure.log 2>&1 || { tail -40 configure.log; exit 1; }

        log "Building nginx $version"
        make -j"$JOBS" > make.log 2>&1 || { tail -60 make.log; exit 1; }
    )

    package="$(new_package_dir nginx "$version")"
    mkdir -p "$package/sbin" "$package/modules" "$package/conf"
    install -m 755 "$nginx/objs/nginx" "$package/sbin/nginx"
    install -m 644 "$nginx"/objs/*.so "$package/modules/"
    cp "$nginx"/conf/* "$package/conf/"

    add_license "$package" nginx "$nginx/LICENSE"
    add_license "$package" openssl "$openssl/LICENSE.txt"
    add_license "$package" pcre2 "$pcre2/LICENCE.md"
    add_license "$package" zlib "$zlib/LICENSE"
    add_license "$package" brotli "$ngx_brotli/deps/brotli/LICENSE"
    add_license "$package" ngx_brotli "$ngx_brotli/LICENSE"
    add_license "$package" headers-more "$headers_more/README.markdown"
    add_license "$package" geoip2 "$geoip2/LICENSE"
    add_license "$package" libmaxminddb "$WORK_DIR/libmaxminddb-$(source_version libmaxminddb)/LICENSE"
    add_license "$package" njs "$njs/LICENSE"
    write_source_file "$package" $NGINX_SOURCES

    archive_package nginx "$version" "BSD-2-Clause"
}
