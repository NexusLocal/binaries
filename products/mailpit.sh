# ./build.sh mailpit
#
# Mailpit catches the mail of the local sites (Phase 3 of the Nexus plan). It is one Go binary
# with the MIT license, so the package holds the official darwin-arm64 binary and there is no
# build. The official archive has no top folder, so unpack() and its --strip-components do not
# fit. The package is a tar.xz, because a Nexus app of 0.1.1 cannot read another format in the
# manifest.

build_product() {
    local version archive src package

    version="$(source_version mailpit)"
    archive="$(fetch mailpit)"
    src="$WORK_DIR/mailpit-$version"

    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$archive" -C "$src"

    log "Packaging Mailpit $version"
    package="$(new_package_dir mailpit "$version")"
    mkdir -p "$package/bin"
    install -m 755 "$src/mailpit" "$package/bin/mailpit"
    add_license "$package" mailpit "$src/LICENSE"
    write_source_file "$package" mailpit

    PACKAGE_LINE=1 archive_package mailpit "$version" MIT
}
