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

# Some bundled libraries have their license only in a comment of a source file, for example
# linenoise in Redis. This copies the first comment of the file that contains the text: a /* */
# comment or a run of // lines.
add_license_from_comment() {
    local package="$1" name="$2" file="$3" text="$4"
    [ -f "$file" ] || fail "license file not found for $name: $file"

    awk -v text="$text" '
        function check(comment) {
            if (index(comment, text)) { printf "%s", comment; found = 1; exit }
        }
        inside { block = block $0 "\n"; if (/\*\//) { inside = 0; check(block) } next }
        /^[[:space:]]*\/\// { lines = lines $0 "\n"; next }
        lines != "" { check(lines); lines = "" }
        /\/\*/ { block = $0 "\n"; if (/\*\//) check(block); else inside = 1 }
        END {
            if (!found && index(lines, text)) { printf "%s", lines; found = 1 }
            exit found ? 0 : 1
        }
    ' "$file" > "$package/licenses/$name.txt" || fail "no license comment with \"$text\" for $name in $file"
}

# Some programs have code of other authors in their own source files, with its license only in a
# comment. This writes each different notice one time, after the name of its file. The names of the
# files come on the standard input and start from the folder of the source. The last argument is a
# pattern for notices with other words.
add_source_notices() {
    local package="$1" name="$2" src="$3" extra="${4:-^$}"

    (
        cd "$src"
        LC_ALL=C sort | LC_ALL=C xargs awk -v extra="$extra" '
            function check(comment, file) {
                if ((comment ~ /Redistribution and use|Permission is hereby granted|Permission to use, copy|provided .as-is|presented "as is"|To the extent possible under law|[Pp]ublic [Dd]omain|licensed under|MIT license|CC attribution license|available under BSD3 terms|SPDX-License-Identifier|Boost Software License|Apache License|BEER-WARE/ || comment ~ extra) && !seen[comment]++) {
                    printf "%s\n\n%s\n", file, comment
                }
            }
            FNR == 1 { if (lines != "") check(lines, previous); inside = 0; lines = ""; previous = FILENAME }
            inside { block = block $0 "\n"; if (/\*\//) { inside = 0; check(block, FILENAME) } next }
            /^[[:space:]]*(\/\/|\/\*.*\*\/[[:space:]]*$)/ { lines = lines $0 "\n"; next }
            lines != "" { check(lines, FILENAME); lines = "" }
            /\/\*/ { block = $0 "\n"; if (/\*\//) check(block, FILENAME); else inside = 1 }
            END { if (lines != "") check(lines, previous) }
        '
    ) > "$package/licenses/$name.txt" || fail "the notices in the source files of $name could not be read"

    [ -s "$package/licenses/$name.txt" ] || fail "the source files have no notices for $name"
}

# Copies each license file of a Go module or an npm package to a folder of the package. A file in
# a subfolder counts too, because it can be the license of code from another project. Test data,
# nested node_modules and source code such as license.go do not count. Returns 1 when the module
# or package has no license file.
copy_license_files() {
    local from="$1" to="$2" files file

    files="$(cd "$from" && find . -type f | sed 's|^\./||' | LC_ALL=C sort |
        grep -i -E '(^|/)(licen[cs]e|copying|notice|patents|unlicense|third[-_]party[-_]licen[cs]es?)[^/]*$|(^|/)licen[cs]es/[^/]+$|\.licen[cs]e\.txt$' |
        grep -v -E '(^|/)(testdata|node_modules)/' |
        grep -v -i -E '\.([cm]?js|[cm]?ts|jsx|tsx|map|json|go|s|c|h|cc|cpp|py|rb|sh|vue|css|scss)$')" || return 1

    while IFS= read -r file; do
        mkdir -p "$to/$(dirname "$file")" || fail "could not make a folder for $from/$file"

        case "$file" in
            *.gz) gunzip -c "$from/$file" > "$to/${file%.gz}" || fail "could not unpack the license file $from/$file" ;;
            *) cp "$from/$file" "$to/$file" || fail "could not copy the license file $from/$file" ;;
        esac
    done <<< "$files"
}

# A Go binary lists the modules in it with the go.sum hash of each module. Each hash must be the
# same as in go.sum of the source of the same tag. Go downloads each module and checks it against
# the checksum database of Go. The build also checks it against go.sum. Then the license files of
# each module go to licenses/go-modules/<module>@<version>/. The runtime of Go is in each Go
# binary. So the license of Go goes in too. That text is the same in each version of Go.
add_go_licenses() {
    local package="$1" binary="$2" source="$3" work path version sum dir
    work="$WORK_DIR/go-licenses-$(basename "$binary")"

    ensure_go
    rm -rf "$work"
    mkdir -p "$work/empty"

    # A line "=>" follows the line "dep" of a module that the build replaced with another module.
    go_tool version -m "$binary" | awk '
        $1 == "dep" { if (line != "") print line; line = $2 " " $3 " " $4; next }
        $1 == "=>" { line = $2 " " $3 " " $4 }
        END { if (line != "") print line }
    ' > "$work/modules.txt"
    [ -s "$work/modules.txt" ] || fail "$binary has no Go modules in its build information"

    while read -r path version sum; do
        case "$path" in
            .* | /*) fail "$binary has a module from the local folder $path. The build cannot check the license of a local module." ;;
        esac

        [ -n "$sum" ] || fail "$binary has no hash for the module $path $version"
        grep -q -F -x "$path $version $sum" "$source/go.sum" || fail "the hash of $path $version in $binary is not in go.sum of the source"
    done < "$work/modules.txt"

    # Each try writes the file again, so a failed first try leaves no lines in it.
    download_go_modules() {
        (cd "$work/empty" && go_tool mod download -json $(awk '{ print $1 "@" $2 }' "$work/modules.txt")) > "$work/download.json"
    }

    log "Downloading the $(wc -l < "$work/modules.txt" | tr -d ' ') Go modules of $(basename "$binary") for their licenses"
    try_twice download_go_modules ||
        fail "Go could not download and check all modules of $binary: $(/usr/bin/jq -r 'select(.Error) | .Error' "$work/download.json" | head -3)"
    /usr/bin/jq -r '"\(.Path) \(.Version) \(.Sum) \(.Dir)"' "$work/download.json" > "$work/downloaded.txt"

    while read -r path version sum; do
        dir="$(awk -v line="$path $version $sum" 'index($0, line " ") == 1 { print substr($0, length(line) + 2) }' "$work/downloaded.txt")"
        [ -n "$dir" ] || fail "Go downloaded $path $version with another hash than go.sum of the source"
        copy_license_files "$dir" "$package/licenses/go-modules/$path@$version" || fail "the Go module $path $version has no license file"
    done < "$work/modules.txt"

    add_license "$package" go "$TOOLS_DIR/go/LICENSE"
    add_license "$package" go-patents "$TOOLS_DIR/go/PATENTS"
}

# package-lock.json gives each npm package with its SHA-512. Each package that is not only for
# development is downloaded from that URL and checked against that hash. Then its license files
# go to licenses/npm-packages/<package>@<version>/. Some packages have their license only at the
# end of README.md. Then the README.md from the License heading to the end goes in.
# licenses/npm-packages.txt lists the packages. With it a test can find a missing folder.
add_npm_licenses() {
    local package="$1" lock="$2" work key version url integrity name archive dir to

    work="$WORK_DIR/npm-licenses"
    rm -rf "$work"
    mkdir -p "$work"

    # The URL is "link" for a link to a local folder and "bundled" for a package inside another
    # package. The integrity field can have more than one hash. Only the SHA-512 counts.
    /usr/bin/jq -r '.packages | to_entries[] | select(.key != "" and .value.dev != true and .value.devOptional != true)
        | "\(.key) \(.value.version) \(if .value.link then "link" elif .value.inBundle then "bundled" else .value.resolved end) \(.value.integrity // "" | split(" ") | map(select(startswith("sha512-"))) | .[0] // "none")"' \
        "$lock" > "$work/packages.txt"
    [ -s "$work/packages.txt" ] || fail "$lock has no npm packages"

    log "Downloading the $(wc -l < "$work/packages.txt" | tr -d ' ') npm packages of $(basename "$lock") for their licenses"

    while read -r key version url integrity; do
        name="${key##*node_modules/}"
        archive="$work/$(echo "$name" | tr / _)-$version.tgz"
        dir="${archive%.tgz}"
        to="$package/licenses/npm-packages/$name@$version"
        echo "$name@$version" >> "$package/licenses/npm-packages.txt"

        case "$url" in
            link) fail "package-lock.json has the npm package $name as a link to a local folder. The build cannot check its license." ;;
            bundled) fail "package-lock.json has the npm package $name $version inside another package. The build cannot check its license yet." ;;
        esac

        case "$integrity" in
            sha512-*) ;;
            *) fail "package-lock.json has no SHA-512 for the npm package $name $version" ;;
        esac

        download_file "$url" "$archive" "$integrity" ||
            fail "the download of the npm package $name $version failed twice, or its SHA-512 does not match package-lock.json ($url)"

        mkdir -p "$dir"
        tar -xzf "$archive" -C "$dir" --strip-components 1

        copy_license_files "$dir" "$to" && continue

        [ -f "$dir/README.md" ] || fail "the npm package $name $version has no license file and no README.md"
        mkdir -p "$to"
        awk 'tolower($0) ~ /^(#+ *)?licen[cs]e *$/ { found = 1 } found' "$dir/README.md" > "$to/README-license.md"
        grep -q -i -E 'copyright|permission' "$to/README-license.md" || fail "the npm package $name $version has no license file and no license in README.md"
    done < "$work/packages.txt"
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
# <name>-<version>-r<revision>. scripts/publish.sh raises the revision of a package with other
# sources than its newest release. recipe_revision stays the PACKAGE_REVISION of the recipe.
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
  "recipe_revision": $revision,
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
