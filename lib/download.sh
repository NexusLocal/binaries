# The downloads of the build, the tests and the workflows. A server can fail for a short time, for
# example with HTTP status 504 or with a file that stops halfway. So each download tries again.
# build.sh and the scripts load this file.

# Reads a URL. curl tries again after each error, also after an HTTP error and a file that stops
# halfway. The arguments go to curl, for example --max-time 30 or -o file.
read_url() {
    curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 "$@"
}

# The checksum is a SHA-256, sha512-<base64> as npm gives it, or empty for no check.
checksum_ok() {
    case "$2" in
        "") return 0 ;;
        sha512-*) [ "sha512-$(shasum -a 512 "$1" | cut -d' ' -f1 | xxd -r -p | base64)" = "$2" ] ;;
        *) echo "$2  $1" | shasum -a 256 -c --status ;;
    esac
}

# Downloads a URL to a file. A server can also send a broken file with status 200. So a file with
# another checksum comes one more time. A file that fails twice goes away.
download_file() {
    local url="$1" target="$2" checksum="${3:-}" attempt

    for attempt in 1 2; do
        rm -f "$target"

        if read_url -o "$target" "$url" && checksum_ok "$target" "$checksum"; then
            return 0
        fi

        if [ "$attempt" = 1 ]; then
            echo "warning: the download of $url failed, or its checksum does not match. It starts again." >&2
            sleep 10
        fi
    done

    rm -f "$target"
    return 1
}

# Runs a command one more time when it fails, for example gh release download or go mod download.
try_twice() {
    "$@" && return 0

    echo "warning: $1 failed. It runs again." >&2
    sleep 10
    "$@"
}
