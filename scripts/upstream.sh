# Functions that read the newest versions upstream. scripts/check-updates.sh and
# scripts/check-lines.sh load this file. They set root, the folder of the repository.
#
# Needs curl and jq. It uses GH_TOKEN for the GitHub API when it is set.

source "$root/lib/download.sh"

pinned() {
    awk -v name="$1" '$1 == name { print $2 }' "$root/sources.lock"
}

# The first fields of the pinned version. They give its version line, for example 2.6 of 2.6.16.
pinned_line() {
    pinned "$1" | cut -d. -f"1-$2"
}

# sort -V puts 8.6.0RC1 after 8.6.0. With a ~ before it, a release candidate comes before its
# release.
newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sed -E 's/[-.]?(alpha|beta|rc|RC)/~&/' | sort -V | tail -1 | sed 's/~//')" = "$1" ]
}

# Without a token, GitHub accepts 60 API requests an hour from one address. The runners of GitHub
# Actions share their addresses. So a request can get "403 Forbidden" before the run made 60. The
# token of the workflow has its own limit of 1,000 requests an hour.
github_api() {
    if [ -n "${GH_TOKEN:-}" ]; then
        read_url --max-time 30 -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/$1"
        return
    fi

    read_url --max-time 30 "https://api.github.com/$1"
}

github_latest() {
    github_api "repos/$1/releases/latest" | jq -r .tag_name | sed -E "s/^${2:-v}//"
}

# For a project that has tags such as v0.8.7 and no releases.
github_latest_tag() {
    github_api "repos/$1/tags?per_page=100" | jq -r '.[].name' | sed -nE 's/^v([0-9]+(\.[0-9]+)+)$/\1/p' | sort -V | tail -1
}

# For a project with many tags. The start of the tag gives the version line, for example v1.6. or
# release-79. The third argument is the part before the version.
github_line_tag() {
    github_api "repos/$1/git/matching-refs/tags/$2" | jq -r '.[].ref' | sed -nE "s#^refs/tags/${3-v}([0-9]+(\.[0-9]+)+)\$#\1#p" | sort -V | tail -1
}

# json-c has tags such as json-c-0.19-20260627 and json-c-0.13.1-20180305. This gives the versions in
# their order.
json_c_latest() {
    github_api 'repos/json-c/json-c/tags?per_page=100' | jq -r '.[].name' | sed -nE 's/^json-c-([0-9]+(\.[0-9]+)+-[0-9]{8})$/\1/p' | sort -V
}

# The newest version in the list of files of a download folder. A file counts only with the suffix of
# the pinned file, for example tar.xz. With a line such as 2.6, only the versions of that line count.
listed_latest() {
    local suffix
    suffix="$(awk -v name="$2" '$1 == name { print $4 }' "$root/sources.lock" | grep -oE '(tar\.[a-z0-9]+|tgz)$')"

    read_url --max-time 30 "$1" | grep -oE "$2-[0-9]+(\.[0-9]+)+\.$suffix" | sed -E "s/^$2-//; s/\.$suffix$//" |
        awk -v line="${3:-}" 'line == "" || index($0, line ".") == 1' | sort -V | tail -1
}

# The newest MongoDB Database Tools with a build for macOS on Apple silicon. The list also has
# pre-releases such as 100.0.0-alpha1. So only a version with three numbers counts. With a line
# such as 100, only the versions of that line count.
mongodb_tools_latest() {
    read_url --max-time 60 https://downloads.mongodb.org/tools/db/full.json |
        jq -r '.versions[] | select(any(.downloads[]?; .name == "macos" and .arch == "arm64")) | .version' |
        grep -xE '[0-9]+\.[0-9]+\.[0-9]+' | awk -v line="${1:-}" 'line == "" || index($0, line ".") == 1' | sort -V | tail -1
}

# The newest release of a PECL extension. The state stable gives only stable releases. The state
# latest also gives an alpha, a beta or a release candidate.
pecl_release() {
    read_url --max-time 30 "https://pecl.php.net/rest/r/$1/$2.txt"
}

# The GitHub project of each PECL extension. A source that follows git reads its commits and tags
# there.
pecl_repository() {
    case "$1" in
        igbinary) echo igbinary/igbinary ;;
        redis) echo phpredis/phpredis ;;
        xdebug) echo xdebug/xdebug ;;
        pcov) echo krakjoe/pcov ;;
        apcu) echo krakjoe/apcu ;;
        yaml) echo php/pecl-file_formats-yaml ;;
        imagick) echo Imagick/imagick ;;
        mailparse) echo php/pecl-mail-mailparse ;;
        memcached) echo php-memcached-dev/php-memcached ;;
        mongodb) echo mongodb/mongo-php-driver ;;
    esac
}

# The PECL name of a source, for example xdebug of pecl-xdebug-php86.
pecl_name() {
    echo "$1" | sed -E 's/^pecl-//; s/-php[0-9]+$//'
}

# The version of a source that follows git is the start of its commit.
is_commit_version() {
    [[ "$1" =~ ^[0-9a-f]{12}$ ]]
}

is_test_release() {
    [[ "$1" =~ (alpha|beta|RC|rc)[0-9]*$ ]]
}

# The tag of a release in the GitHub project: the version, or the version with a v before it.
release_tag() {
    local tag

    for tag in "$2" "v$2"; do
        if github_api "repos/$1/git/matching-refs/tags/$tag" | jq -e --arg ref "refs/tags/$tag" 'any(.[]; .ref == $ref)' > /dev/null; then
            echo "$tag"
            return
        fi
    done
}

# ahead when the second commit or tag comes after the first in git, also identical, behind or
# diverged.
compare_status() {
    github_api "repos/$1/compare/$2...$3" | jq -r .status
}

# The next version of a PECL source that is on a test release or on a commit (owner, 2026-11-26).
# This is the case while no release supports a PHP version, for example pecl-xdebug-php86. The
# order:
#
#   1. the newest stable release, when its tag is the version in use or comes after it in git
#   2. the newest test release, under the same condition
#   3. the newest commit of the default branch, when it comes after the version in use
#
# The default branch is the one that GitHub gives, so main, master or another name. After step 1
# the source is on a stable release. scripts/check-updates.sh then reads only releases for it, so
# it never goes back to git. Prints nothing when there is no next version, and fails when GitHub
# or PECL did not answer.
follow_next() {
    local name="$1" current pecl repo base stable latest candidate tag head status
    current="$(pinned "$name")"
    pecl="$(pecl_name "$name")"
    repo="$(pecl_repository "$pecl")"
    [ -n "$repo" ] || return 1

    if is_commit_version "$current"; then
        base="$current"
    else
        base="$(release_tag "$repo" "$current")"
        [ -n "$base" ] || return 1
    fi

    stable="$(pecl_release "$pecl" stable)" || return 1
    latest="$(pecl_release "$pecl" latest)" || return 1

    for candidate in "$stable" "$latest"; do
        [ -n "$candidate" ] && [ "$candidate" != "$current" ] || continue
        tag="$(release_tag "$repo" "$candidate")"
        [ -n "$tag" ] || continue
        status="$(compare_status "$repo" "$base" "$tag")" || return 1

        case "$status" in
            ahead | identical)
                echo "$candidate"
                return
                ;;
        esac
    done

    head="$(github_api "repos/$repo/commits/HEAD" | jq -r .sha)"
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
    status="$(compare_status "$repo" "$base" "$head")" || return 1

    if [ "$status" = "ahead" ]; then
        echo "${head:0:12}"
    fi
}

# The download URL of a version of a PECL source: a release on pecl.php.net, or a commit as an
# archive on GitHub.
pecl_url() {
    local pecl repo sha
    pecl="$(pecl_name "$1")"

    if ! is_commit_version "$2"; then
        echo "https://pecl.php.net/get/$pecl-$2.tgz"
        return
    fi

    repo="$(pecl_repository "$pecl")"
    sha="$(github_api "repos/$repo/commits/$2" | jq -r .sha)"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "https://github.com/$repo/archive/$sha.tar.gz"
}
