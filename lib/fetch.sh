source_field() {
    awk -v name="$1" -v field="$2" '
        $1 == name { print $field; found = 1 }
        END { if (!found) exit 1 }
    ' "$NEXUS_REPO/sources.lock"
}

source_version() {
    source_field "$1" 2 || fail "no source named $1 in sources.lock"
}

source_sha256() {
    source_field "$1" 3 || fail "no source named $1 in sources.lock"
}

source_url() {
    source_field "$1" 4 || fail "no source named $1 in sources.lock"
}

checksum_matches() {
    echo "$1  $2" | shasum -a 256 -c --status
}

fetch() {
    local name="$1" url sha256 archive

    url="$(source_url "$name")"
    sha256="$(source_sha256 "$name")"
    archive="$CACHE_DIR/$name-$(source_version "$name")-${url##*/}"

    if [ ! -f "$archive" ] || ! checksum_matches "$sha256" "$archive"; then
        log "Downloading $name from $url" >&2
        curl -fsSL --retry 3 -o "$archive.part" "$url"
        mv "$archive.part" "$archive"
    fi

    checksum_matches "$sha256" "$archive" || fail "the SHA-256 of $name does not match sources.lock ($url)"

    printf '%s\n' "$archive"
}

unpack() {
    local name="$1" archive dir

    archive="$(fetch "$name")"
    dir="$WORK_DIR/$name-$(source_version "$name")"

    rm -rf "$dir"
    mkdir -p "$dir"

    case "$archive" in
        *.zip) (cd "$dir" && unzip -q "$archive") ;;
        *) tar -xf "$archive" -C "$dir" --strip-components 1 ;;
    esac

    printf '%s\n' "$dir"
}
