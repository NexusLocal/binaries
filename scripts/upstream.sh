# Functions that read the newest versions upstream. scripts/check-updates.sh and
# scripts/check-lines.sh load this file. They set root, the folder of the repository.
#
# Needs curl and jq. It uses GH_TOKEN for the GitHub API when it is set.

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
        curl -fsS --max-time 30 -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/$1"
        return
    fi

    curl -fsS --max-time 30 "https://api.github.com/$1"
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
    github_api "repos/$1/git/matching-refs/tags/$2" | jq -r '.[].ref' | sed -nE "s#^refs/tags/${3:-v}([0-9]+(\.[0-9]+)+)\$#\1#p" | sort -V | tail -1
}

# The newest version in the list of files of a download folder. With a line such as 2.6, only the
# versions of that line count.
listed_latest() {
    curl -fsSL --max-time 30 "$1" | grep -oE "$2-[0-9]+(\.[0-9]+)+\.(tar\.(xz|bz2)|tgz)" | sed -E "s/^$2-//; s/\.(tar\.(xz|bz2)|tgz)$//" |
        awk -v line="${3:-}" 'line == "" || index($0, line ".") == 1' | sort -V | tail -1
}
