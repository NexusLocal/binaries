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

links_into_package() {
    case "$1" in
        "$BUILD_ROOT"/*|"$2"/*) return 0 ;;
        */*) return 1 ;;
        *) return 0 ;;
    esac
}

# Changes every link to a library inside the package into an @rpath link, removes rpaths into
# the build folder, gives each binary an rpath to the lib folder of the package, and signs every
# Mach-O file again. install_name_tool breaks the old signature, and macOS on Apple silicon does
# not run an unsigned binary. A link without a folder (ICU uses libicuuc.79.dylib) also counts
# as a link into the package.
relocate_package() {
    local package="$1" path dependency rpath id

    macho_files "$package" | while IFS= read -r path; do
        chmod u+w "$path"

        if file -b "$path" | grep -q "dynamically linked shared library"; then
            id="$(otool -D "$path" | tail -n 1)"
            run_or_fail install_name_tool -id "@rpath/$(basename "$id")" "$path"
        fi

        otool -L "$path" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
            if links_into_package "$dependency" "$package"; then
                run_or_fail install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$path"
            fi
        done

        otool -l "$path" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | while IFS= read -r rpath; do
            case "$rpath" in
                @*) ;;
                *) run_or_fail install_name_tool -delete_rpath "$rpath" "$path" ;;
            esac
        done

        if [ -d "$package/lib" ]; then
            local rpath="@loader_path/$(relative_path "$package/lib" "$(dirname "$path")")"
            if ! otool -l "$path" | grep -A2 LC_RPATH | grep -q "path $rpath "; then
                run_or_fail install_name_tool -add_rpath "$rpath" "$path"
            fi
        fi

        run_or_fail codesign --force --sign - "$path"
    done
}
