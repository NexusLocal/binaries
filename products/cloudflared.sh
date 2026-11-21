# ./build.sh cloudflared
#
# cloudflared opens the public links of Nexus (group 4 of the Nexus plan). It is one Go binary
# with the Apache License 2.0. So the package holds the official darwin-arm64 binary, as Mailpit
# does. There is no build. The official archive has no top folder. So unpack() and its
# --strip-components do not fit. The release archive holds only the binary. So the license comes
# from the source archive of the same tag. A NOTICE comes from there too when the source has one.
# The version starts with the year, for example 2026.11.0. So the package has the one line 1.
# The binary contains Go modules. Their licenses come from go.sum in the source archive.

# Revision 2 adds the licenses of the Go modules in the binary.
CLOUDFLARED_REVISION=2

build_product() {
    local version source_tag archive src source package

    version="$(source_version cloudflared)"
    source_tag="$(source_version cloudflared-source)"

    if [ "$source_tag" != "$version" ]; then
        fail "sources.lock has cloudflared $version but cloudflared-source $source_tag. Both need the same version."
    fi

    archive="$(fetch cloudflared)"
    src="$WORK_DIR/cloudflared-$version"

    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$archive" -C "$src"
    [ -f "$src/cloudflared" ] || fail "the archive of cloudflared $version has no file cloudflared"

    source="$(unpack cloudflared-source)"

    log "Packaging cloudflared $version"
    package="$(new_package_dir cloudflared "$version")"
    mkdir -p "$package/bin"
    install -m 755 "$src/cloudflared" "$package/bin/cloudflared"
    add_license "$package" cloudflared "$source/LICENSE"

    if [ -f "$source/NOTICE" ]; then
        add_license "$package" cloudflared-notice "$source/NOTICE"
    fi

    add_go_licenses "$package" "$src/cloudflared" "$source"
    write_source_file "$package" cloudflared cloudflared-source

    PACKAGE_LINE=1 PACKAGE_REVISION="$CLOUDFLARED_REVISION" archive_package cloudflared "$version" Apache-2.0
}
