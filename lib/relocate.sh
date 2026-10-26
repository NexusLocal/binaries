is_macho() {
    [ -f "$1" ] && [ ! -L "$1" ] && file -b "$1" | grep -q "Mach-O"
}

macho_files() {
    find "$1" -type f -print0 | while IFS= read -r -d '' path; do
        if is_macho "$path"; then
            printf '%s\n' "$path"
        fi
    done
}

relative_path() {
    local target="$1" base="$2" up=""

    while [ "${target#"$base"/}" = "$target" ] && [ "$target" != "$base" ]; do
        base="$(dirname "$base")"
        up="../$up"
    done

    if [ "$target" = "$base" ]; then
        printf '%s\n' "${up%/}"
        return
    fi

    printf '%s%s\n' "$up" "${target#"$base"/}"
}

# Changes every link to a library inside the package into an @rpath link, gives each binary an
# rpath to the lib folder of the package, and signs every Mach-O file again. install_name_tool
# breaks the old signature, and macOS on Apple silicon does not run an unsigned binary.
relocate_package() {
    local package="$1" path dependency name

    macho_files "$package" | while IFS= read -r path; do
        chmod u+w "$path"

        if file -b "$path" | grep -q "dynamically linked shared library"; then
            install_name_tool -id "@rpath/$(basename "$path")" "$path" 2> /dev/null
        fi

        otool -L "$path" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
            case "$dependency" in
                "$BUILD_ROOT"/*|"$package"/*)
                    name="$(basename "$dependency")"
                    install_name_tool -change "$dependency" "@rpath/$name" "$path" 2> /dev/null
                    ;;
            esac
        done

        if [ -d "$package/lib" ]; then
            local rpath="@loader_path/$(relative_path "$package/lib" "$(dirname "$path")")"
            if ! otool -l "$path" | grep -A2 LC_RPATH | grep -q "path $rpath "; then
                install_name_tool -add_rpath "$rpath" "$path" 2> /dev/null || true
            fi
        fi

        codesign --force --sign - "$path" 2> /dev/null
    done
}
