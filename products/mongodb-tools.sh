# ./build.sh mongodb-tools
#
# Nexus uses the MongoDB Database Tools to make a backup of a MongoDB database and to restore it.
# They have the Apache License 2.0. MongoDB, Inc. publishes signed Go binaries for macOS on Apple
# silicon. So the package holds the official binaries, as cloudflared does. There is no build. The
# package holds only mongodump and mongorestore. The zip has one top folder and macOS files with
# names that start with "._". The build copies only the files that it needs. THIRD-PARTY-NOTICES
# in the zip gives the license of each Go module in the binaries. So the build downloads no Go
# module. The version starts with 100, for example 100.20.1. The first number is the line.

build_product() {
    local version src package tool

    version="$(source_version mongodb-tools)"
    src="$(unpack mongodb-tools)/mongodb-database-tools-macos-arm64-$version"
    [ -d "$src" ] || fail "the archive of the MongoDB Database Tools $version has no folder ${src##*/}"

    log "Packaging the MongoDB Database Tools $version"
    package="$(new_package_dir mongodb-tools "$version")"
    mkdir -p "$package/bin"

    for tool in mongodump mongorestore; do
        [ -f "$src/bin/$tool" ] || fail "the archive of the MongoDB Database Tools $version has no file bin/$tool"
        install -m 755 "$src/bin/$tool" "$package/bin/$tool"
    done

    add_license "$package" mongodb-tools "$src/LICENSE.md"
    add_license "$package" mongodb-tools-third-party-notices "$src/THIRD-PARTY-NOTICES"
    write_source_file "$package" mongodb-tools

    PACKAGE_LINE="${version%%.*}" archive_package mongodb-tools "$version" Apache-2.0
}
