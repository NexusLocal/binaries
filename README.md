# Nexus binaries

The packages that the [Nexus](https://github.com/NexusLocal/nexus) app installs, and the scripts
that build them. Each package is for macOS 27 on Apple silicon.

- **Packages:** PHP 8.2 to 8.5, nginx, Apache, MySQL, MariaDB, PostgreSQL with pgvector and PostGIS,
  Redis, Mailpit, cloudflared and the MongoDB Database Tools. See [Packages](#packages).
- **From the publisher:** Node, the MongoDB server, Composer and WP-CLI. Nexus downloads them from
  their publisher. The manifest gives the SHA-256 of each file.
- **Signed:** the owner signs each manifest outside GitHub. Nexus installs nothing from a manifest
  without a valid signature. See [Releases and the manifest](#releases-and-the-manifest).
- **Checked sources:** each source must match the checksum or the PGP signature of its publisher.
- **Clean builds:** each build starts with an empty environment. Each package contains the license
  of each program in it. See [Rules](#rules).
- **Up to date:** a workflow looks for new versions every 6 hours and builds the packages that
  changed.
  See [Automatic updates](#automatic-updates).

## Build a package

```sh
./build.sh nginx
tests/nginx.sh /tmp/nexus-build/out/nginx-*-macos-arm64.tar.xz

./build.sh php 8.5
tests/php.sh /tmp/nexus-build/out/php-8.5.*-macos-arm64.tar.xz
tests/wp-cli.sh /tmp/nexus-build/out/php-8.5.*-macos-arm64.tar.xz

./build.sh httpd
tests/httpd.sh /tmp/nexus-build/out/httpd-*-macos-arm64.tar.xz
```

The build uses `/tmp/nexus-build`. Set `NEXUS_BUILD_ROOT` to use another folder. The path must
not contain spaces, because many configure scripts fail on them.

A package is a `.tar.xz` file in `out/`, with a `.json` file next to it that gives its SHA-256
and its size.

## Releases and the manifest

After every successful build on `main`, CI publishes each new package as the release
`<name>-<version>-r<revision>`, with the package, its JSON file and every source archive it was
built from. A release that exists already never changes. A recipe sets `PACKAGE_REVISION` higher
when it changes and the upstream version stays the same. When only a source such as OpenSSL
changes, `scripts/publish.sh` gives the package the next revision by itself.

`manifest.json` lists every package with its version line, URL, SHA-256 and license. A release
cannot change after it is published. So each manifest is a new release.
`scripts/release-manifest.sh` adds it as a draft release that waits for the signature of the
owner. `scripts/sign-manifest.sh` runs on the Mac of the owner. It shows the packages that changed,
checks the SHA-256 of each one and the attestation of the workflow Build, and signs the bytes of
`manifest.json` with an Ed25519 key in the Keychain. Then it publishes the draft as the latest
release with
[`manifest.signed.json`](https://github.com/NexusLocal/binaries/releases/latest/download/manifest.signed.json),
which holds the same bytes and the signature. The Nexus app installs only from a manifest with a
valid signature. Versions of Nexus before the signature read `manifest.json` of the same release.
Node, the MongoDB server, Composer and WP-CLI are in the manifest too. Nexus downloads them from
nodejs.org, fastdl.mongodb.org, getcomposer.org and the GitHub releases of WP-CLI, with the SHA-256
from `sources.lock`.

NexusLocal does not give out the MongoDB server 7.0, 8.0 and 9.0, because its license is the SSPL.
The file of MongoDB is a `.tgz`. The manifest gives the format `tar.xz`, because an older Nexus
cannot read a manifest with an unknown format. `/usr/bin/tar -xf` reads both formats.

`support.lock` gives the support of each version line: whether it is a long-term support
release, and the last day of security fixes from endoflife.date. The manifest has them as `lts`
and `security_end`, and Nexus marks a version without security fixes. After a change of
`support.lock`, the workflow Manifest adds the new data to the published manifest without a new
build. `scripts/check-updates.sh` reports a date that endoflife.date changed.

`scripts/publish.sh` does this work. `NEXUS_DRY_RUN=1 scripts/publish.sh <folder>` shows what it
would publish and writes the manifest into the folder, without a change on GitHub. A package
whose build or publication failed keeps its package of the newest manifest. So one failure does
not hold back the updates of the other packages. An old run of Build that somebody starts again
fails and publishes nothing when `main` has a newer commit that starts a Build.

The workflow Build makes only the packages that changed after the last successful Build of `main`.
`scripts/plan-build.sh` chooses them from `packages.json`. A change in `lib`, `licenses`, `build.sh`,
the Build workflow or a tool of the build makes all packages. A person can start Build by hand with
the choice `all`.

## Automatic updates

The workflow Updates runs every 6 hours. `scripts/update-sources.sh` updates `sources.lock` to the
newest release in each version line, and `support.lock` to the newest end of security fixes. It
checks each download against the checksum that upstream publishes. MySQL, nginx, GNU, FreeType,
libwebp and OpenLDAP publish no checksum, but a PGP signature. The signature must verify with a key
in [`keys/`](keys/README.md). Some sources have neither: PECL, libpng, pkgconf, GEOS and the
archives of GitHub tags and commits. The script downloads such a source twice. Both downloads must
be the same.

A package with a source archive of its own (MySQL, Mailpit and cloudflared) gets both in one update.
fmt gets the version that the newest MariaDB releases name in `cmake/libfmt.cmake`, in the same
update as MariaDB. ICU, libpng, OpenLDAP, APR and some other libraries stay in their version line of
`sources.lock`, for example OpenLDAP 2.6. The MongoDB Database Tools stay in their line 100 too.
ngx_brotli has no releases. So it gets the newest commit.
GMP, Boost and protobuf change rarely. So a person updates them. Then the workflow commits, pushes
and starts the build. Each new manifest then waits for the signature of the owner.

The owner gets an issue, and so an email, in four cases:

- **A manifest waits for its signature:** run `scripts/sign-manifest.sh`. One run signs the newest
  draft, which holds the changes of each older draft.
- **Automatic update failed:** a download, a checksum or a signature failed, or a package has a new
  major version.
- **Build failed:** a build, a test or a publication failed on `main`.
- **New version line:** `scripts/check-lines.sh` found a new line upstream, for example PHP 8.6
  or Node.js 27. A new line needs a choice of the owner, so the workflow adds nothing.

## Rules

- **A clean environment.** `build.sh` starts again with an empty environment and the PATH
  `/usr/bin:/bin:/usr/sbin:/sbin`. Tools and libraries from MAMP, Homebrew or the PATH of the
  user cannot get into a package.
- **Own build tools.** cmake, ninja and Go come from their official releases. pkgconf is built
  from source. All of them go in the build folder. Go compiles no package. It only gets
  the licenses of the Go modules in the binaries of Mailpit and cloudflared.
- **Pinned sources.** `sources.lock` gives the version, the SHA-256 and the URL of every source.
  The build stops when a download has a different SHA-256.
- **A second try.** A server can fail for a short time, for example with HTTP status 504 or a
  file that stops halfway. So each download of the build, the tests and the workflows tries again
  (`lib/download.sh`). curl tries again after each error. A file with a different checksum comes
  one more time, and `gh release download` and `go mod download` run a second time.
- **Relocatable packages.** Every link to a library in the package becomes an `@rpath` link.
  Every Mach-O file is signed again, because macOS on Apple silicon does not run an unsigned
  binary.
- **A dependency check.** The build fails when a Mach-O file links a library outside the package
  and the system, or keeps an rpath into the build folder.
- **Licenses.** Each package has a `licenses/` folder with the license of every program in it,
  and a `SOURCE` file with the sources it was built from. A Go binary also has the license of Go
  and the license files of each Go module in it, in `licenses/go-modules/`. The build takes the
  modules from the build information of the binary. Each module must have the same hash as in
  `go.sum` of the source of the same tag. The Mailpit package also has the license files of the
  npm packages of its web UI, in `licenses/npm-packages/`. The build downloads the packages that
  `package-lock.json` of the source names. Each download must have the SHA-512 of that file.
  The MongoDB Database Tools have `THIRD-PARTY-NOTICES` of MongoDB instead of
  `licenses/go-modules/`. That file gives the license of each Go module in the binaries.

## Packages

| Package | Versions | State |
| --- | --- | --- |
| nginx | 1.30 | Static OpenSSL 3.5, PCRE2 and zlib. Dynamic modules: stream, mail, headers-more, brotli, geoip2 and njs. |
| PHP | 8.2, 8.3, 8.4, 8.5 | CLI and FPM. See [PHP](#php). |
| Apache httpd | 2.4 | All modules as shared modules, the event, worker and prefork MPMs, mod_ssl and mod_http2. APR and APR-util are shared libraries in the package. Not included: mod_lua, mod_md and the LDAP modules. |
| Redis | 7.2, 8.2, newest 8 | redis-server, redis-cli and redis-benchmark, without TLS. 7.2 has the BSD license. Redis 8 is given out under the AGPLv3, one of its three licenses. 7.4 is not built, because its only licenses are RSALv2 and SSPLv1. |
| Mailpit | 1 | The official darwin-arm64 binary of Mailpit, repackaged as tar.xz with its MIT license and the licenses of its Go modules and npm packages. Nexus uses it to catch the mail of the local sites. |
| cloudflared | 1 | The official darwin-arm64 binary of cloudflared, repackaged as tar.xz with its Apache-2.0 license and the licenses of its Go modules. The build signs it again with an ad hoc signature. Nexus uses it for public links. The line 1 takes each release, because the version starts with the year. |
| MongoDB Database Tools | 100 | The official macOS arm64 binaries mongodump and mongorestore of MongoDB, repackaged as tar.xz with their Apache-2.0 license and `THIRD-PARTY-NOTICES`. The build signs them again with an ad hoc signature. Nexus uses them to make a backup of a MongoDB database and to restore it. The MongoDB server is not a package. See [Releases and the manifest](#releases-and-the-manifest). |
| MySQL | 8.0, 8.4, 9.7 | The official Oracle builds for macOS on Apple silicon, repackaged: without the debug server, the test and MyISAM tools, the static libraries and the headers. Each release also carries the matching source archive. |
| MariaDB | 10.11, 11.4, 11.8, 12.3 | Compiled, because MariaDB publishes no macOS builds. Without ColumnStore, RocksDB, Mroonga, Spider, CONNECT, OQGraph, S3, Galera and the compression providers. The package keeps the server and the client tools, with links under the mysql* names. Run `scripts/mariadb-install-db` from the package folder with `--basedir=.`, because the script breaks on a space in the path. |
| PostgreSQL | 14, 15, 16, 17, 18, 19 | With ICU, libxml2, uuid and all contrib modules (pgcrypto, uuid-ossp, citext, hstore, pg_stat_statements and more). From 15 on also with pgvector, PostGIS 3.7 (with topology and vector tiles, without raster) and pgRouting 4.0. OpenSSL, ICU, GEOS, PROJ and GMP are shared libraries in the package. libpq refuses a static OpenSSL. GEOS and GMP have the LGPL license. From 15 on the license of the package is PostgreSQL and GPL-3.0-or-later. |

## PHP

- **Built in:** bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd (with
  FreeType, JPEG, PNG and WebP), gettext, iconv, intl, ldap, mbstring, mysqli, mysqlnd, openssl,
  pcntl, PDO, pdo_mysql, pdo_sqlite, posix, readline (libedit), session, SimpleXML, soap,
  sockets, sodium, sqlite3, tokenizer, xml, xmlreader, xmlwriter, xsl, zip and zlib.
- **Shared, turned on in php.ini:** apcu, gmp, igbinary, imagick, mailparse, memcached (with
  igbinary, without SASL), mongodb (with OpenSSL and zlib, without client-side encryption), pcov,
  pgsql, pdo_pgsql, redis (with igbinary), xdebug, yaml, and opcache for 8.2 to 8.4. In 8.5 opcache
  is always built in. pgsql and pdo_pgsql contain a static libpq 18 with its own OpenSSL. imagick
  contains a static ImageMagick 7 with PNG, JPEG, WebP and FreeType, built with zero configuration.
  memcached contains a static libmemcached. mongodb contains libmongoc from its own source.
- **From macOS:** libxml2, libxslt, curl, sqlite, libedit, iconv, zlib and bzip2.
- **In the package:** OpenSSL 3.5, ICU, libintl and GMP (shared), and oniguruma, libsodium, libzip,
  libpng, libjpeg-turbo, libwebp, FreeType, libyaml and the OpenLDAP client (static).
- **Paths:** the compiled-in prefix is `/var/empty/nexus/php`, a folder that only root can
  create. So a PHP that runs without `-c` cannot load a php.ini that another user put there.
  `php-config` and `phpize` find the package folder from their own location.

Known choices:

- **OpenLDAP:** the LDAP framework of macOS 27 no longer exports `ldap_destroy`, the sort and
  VLV controls, the password policy control and `ldap_exop_passwd`, which PHP 8.4 and newer
  need. So the package has its own OpenLDAP 2.6 client.
- **No libargon2:** libsodium and libargon2 both export `blake2b_init`, `blake2b_update` and
  `blake2b_final`. In a static link that made Argon2 overflow its stack. ext/sodium provides
  `PASSWORD_ARGON2I` and `PASSWORD_ARGON2ID` itself.
- **igbinary for PHP 8.5:** 3.2.16 is the newest stable release, and it does not compile
  against PHP 8.5. PHP 8.5 uses the release candidate 3.2.17RC1 until a stable release exists.
- **ImageMagick formats:** no TIFF, HEIC, JPEG XL, color profiles (lcms) or SVG rendering. Each
  one needs another library in the package.

## License

The build scripts have the MIT license. Each package contains the licenses of the programs in it.
