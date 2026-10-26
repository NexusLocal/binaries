allowed_dependency() {
    case "$1" in
        /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Fails when a Mach-O file in the package links a library outside the package and the system,
# or keeps an rpath into the build folder. Such a binary works on the build machine and fails
# on every other Mac.
check_package() {
    local package="$1" path dependency rpath problems=0 files=0

    while IFS= read -r path; do
        files=$((files + 1))

        while IFS= read -r dependency; do
            if ! allowed_dependency "$dependency"; then
                echo "  ${path#$package/} links $dependency"
                problems=$((problems + 1))
            fi
        done < <(otool -L "$path" | tail -n +2 | awk '{print $1}')

        while IFS= read -r rpath; do
            case "$rpath" in
                @loader_path/*|@executable_path/*) ;;
                *)
                    echo "  ${path#$package/} has the rpath $rpath"
                    problems=$((problems + 1))
                    ;;
            esac
        done < <(otool -l "$path" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')

        if ! codesign --verify "$path" 2> /dev/null; then
            echo "  ${path#$package/} has no valid signature"
            problems=$((problems + 1))
        fi
    done < <(macho_files "$package")

    if [ "$problems" -gt 0 ]; then
        fail "the dependency check found $problems problems in $files Mach-O files"
    fi

    log "The dependency check passed for $files Mach-O files"
}
