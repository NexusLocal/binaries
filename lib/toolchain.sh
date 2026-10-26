ensure_cmake() {
    local version
    version="$(source_version cmake)"

    if [ -f "$TOOLS_DIR/cmake/.version" ] && [ "$(cat "$TOOLS_DIR/cmake/.version")" = "$version" ]; then
        return
    fi

    log "Installing cmake $version into the build tools"

    local dir
    dir="$(unpack cmake)"
    rm -rf "$TOOLS_DIR/cmake"
    mv "$dir" "$TOOLS_DIR/cmake"
    echo "$version" > "$TOOLS_DIR/cmake/.version"

    printf '#!/bin/bash\nexec "%s/cmake/CMake.app/Contents/bin/cmake" "$@"\n' "$TOOLS_DIR" > "$TOOLS_DIR/bin/cmake"
    chmod +x "$TOOLS_DIR/bin/cmake"
}

ensure_ninja() {
    local version
    version="$(source_version ninja)"

    if [ -f "$TOOLS_DIR/.ninja-version" ] && [ "$(cat "$TOOLS_DIR/.ninja-version")" = "$version" ]; then
        return
    fi

    log "Installing ninja $version into the build tools"

    local dir
    dir="$(unpack ninja)"
    install -m 755 "$dir/ninja" "$TOOLS_DIR/bin/ninja"
    echo "$version" > "$TOOLS_DIR/.ninja-version"
}

build_gnu_tool() {
    local name="$1" version dir
    version="$(source_version "$name")"

    if [ -f "$TOOLS_DIR/.$name-version" ] && [ "$(cat "$TOOLS_DIR/.$name-version")" = "$version" ]; then
        return
    fi

    log "Building $name $version for the build tools"

    dir="$(unpack "$name")"
    (
        cd "$dir"
        run_logged configure.log ./configure --prefix="$TOOLS_DIR"
        run_logged make.log make -j"$JOBS"
        run_logged install.log make install
    )
    echo "$version" > "$TOOLS_DIR/.$name-version"
}

ensure_autoconf() {
    build_gnu_tool m4
    build_gnu_tool autoconf
}

ensure_pkgconf() {
    local version
    version="$(source_version pkgconf)"

    if [ -f "$TOOLS_DIR/.pkgconf-version" ] && [ "$(cat "$TOOLS_DIR/.pkgconf-version")" = "$version" ]; then
        return
    fi

    log "Building pkgconf $version for the build tools"

    local dir
    dir="$(unpack pkgconf)"
    (
        cd "$dir"
        ./configure --prefix="$TOOLS_DIR" --disable-shared --with-pkg-config-dir="$STAGE_DIR/lib/pkgconfig" > configure.log
        make -j"$JOBS" > make.log
        make install > install.log
    )
    ln -sf pkgconf "$TOOLS_DIR/bin/pkg-config"
    echo "$version" > "$TOOLS_DIR/.pkgconf-version"
}
