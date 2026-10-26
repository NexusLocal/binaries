package_dir() {
    printf '%s/%s-%s\n' "$PACKAGE_ROOT" "$1" "$2"
}

new_package_dir() {
    local dir
    dir="$(package_dir "$1" "$2")"
    rm -rf "$dir"
    mkdir -p "$dir/licenses"
    printf '%s\n' "$dir"
}

add_license() {
    local package="$1" name="$2" file="$3"
    [ -f "$file" ] || fail "license file not found for $name: $file"
    cp "$file" "$package/licenses/$name.txt"
}

write_source_file() {
    local package="$1" name
    shift

    {
        echo "This package was built from these sources. Each line gives the name, the version,"
        echo "the SHA-256 of the source archive and its URL."
        echo
        for name in "$@"; do
            printf '%s %s %s %s\n' "$name" "$(source_version "$name")" "$(source_sha256 "$name")" "$(source_url "$name")"
        done
    } > "$package/SOURCE"
}

# Writes <name>-<version>-macos-arm64.tar.xz and a JSON file next to it with the SHA-256 and the
# size. The manifest of the release is made from these JSON files.
#
# PACKAGE_LINE is the version line that Nexus offers, such as 8.5, or 8 for the newest Redis 8.
# Without it, the line is the first two parts of the version. PACKAGE_REVISION goes up when a
# recipe changes and the upstream version stays the same. The release tag is
# <name>-<version>-r<revision>.
archive_package() {
    local name="$1" version="$2" license="$3" package archive sha256 size line revision

    package="$(package_dir "$name" "$version")"
    archive="$OUT_DIR/$name-$version-macos-arm64.tar.xz"

    relocate_package "$package"
    check_package "$package"

    rm -f "$archive"
    tar -cJf "$archive" -C "$PACKAGE_ROOT" "$(basename "$package")"

    sha256="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    size="$(stat -f %z "$archive")"
    line="${PACKAGE_LINE:-$(echo "$version" | cut -d. -f1-2)}"
    revision="${PACKAGE_REVISION:-1}"

    cat > "${archive%.tar.xz}.json" <<EOF
{
  "name": "$name",
  "version": "$version",
  "line": "$line",
  "revision": $revision,
  "tag": "$name-$version-r$revision",
  "file": "$(basename "$archive")",
  "sha256": "$sha256",
  "size": $size,
  "minimum_macos": "$MACOS_MIN",
  "architecture": "arm64",
  "license": "$license"
}
EOF

    cp "$package/SOURCE" "${archive%.tar.xz}.sources.txt"

    log "Package ready: $archive ($((size / 1024 / 1024)) MB)"
}
