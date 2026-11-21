# ./build.sh mailpit
#
# Mailpit catches the mail of the local sites (Phase 3 of the Nexus plan). It is one Go binary
# with the MIT license, so the package holds the official darwin-arm64 binary and there is no
# build. The official archive has no top folder, so unpack() and its --strip-components do not
# fit. The package is a tar.xz, because a Nexus app of 0.1.1 cannot read another format in the
# manifest.
#
# The binary contains Go modules and the JavaScript of the web UI from npm packages. The build
# downloads each module and package for its licenses. So the build needs proxy.golang.org and
# registry.npmjs.org. go.sum and package-lock.json in the source archive of the same tag give the
# hash that each download must have.

# Revision 2 adds the licenses of the Go modules and the npm packages in the binary.
MAILPIT_REVISION=2

build_product() {
    local version source_tag archive src source package

    version="$(source_version mailpit)"
    source_tag="$(source_version mailpit-source)"

    if [ "$source_tag" != "$version" ]; then
        fail "sources.lock has mailpit $version but mailpit-source $source_tag. Both need the same version."
    fi

    archive="$(fetch mailpit)"
    src="$WORK_DIR/mailpit-$version"

    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$archive" -C "$src"

    source="$(unpack mailpit-source)"

    log "Packaging Mailpit $version"
    package="$(new_package_dir mailpit "$version")"
    mkdir -p "$package/bin"
    install -m 755 "$src/mailpit" "$package/bin/mailpit"
    add_license "$package" mailpit "$src/LICENSE"
    add_go_licenses "$package" "$src/mailpit" "$source"
    add_npm_licenses "$package" "$source/package-lock.json"
    write_source_file "$package" mailpit mailpit-source

    PACKAGE_LINE=1 PACKAGE_REVISION="$MAILPIT_REVISION" archive_package mailpit "$version" MIT
}
