# Nexus binaries

Build scripts for the programs that the [Nexus](https://github.com/NexusLocal/nexus) app
downloads: nginx, Apache, PHP, MySQL, MariaDB, PostgreSQL and Redis. Each package is built from
source for macOS 27 on Apple silicon.

## Build a package

```sh
./build.sh nginx
tests/nginx.sh /tmp/nexus-build/out/nginx-1.30.6-macos-arm64.tar.xz

./build.sh php 8.5
tests/php.sh /tmp/nexus-build/out/php-8.5.12-macos-arm64.tar.xz

./build.sh httpd
tests/httpd.sh /tmp/nexus-build/out/httpd-2.4.69-macos-arm64.tar.xz
```

The build uses `/tmp/nexus-build`. Set `NEXUS_BUILD_ROOT` to use another folder. The path must
not contain spaces, because many configure scripts fail on them.

A package is a `.tar.xz` file in `out/`, with a `.json` file next to it that gives its SHA-256
and its size.

## Releases and the manifest

After every successful build on `main`, CI publishes each new package as the release
`<name>-<version>-r<revision>`, with the package, its JSON file and every source archive it was
built from. A release that exists already never changes. A recipe sets `PACKAGE_REVISION` higher
when it changes and the upstream version stays the same.

The Nexus app reads
[`manifest.json`](https://github.com/NexusLocal/binaries/releases/download/manifest/manifest.json),
which lists every package with its version line, URL, SHA-256 and license. Node and Composer are
in the manifest too. Nexus downloads them from nodejs.org and getcomposer.org, with the SHA-256
from `sources.lock`.

`scripts/publish.sh` does this work. `NEXUS_DRY_RUN=1 scripts/publish.sh <folder>` shows what it
would publish and writes the manifest into the folder, without a change on GitHub.

## Rules

- **A clean environment.** `build.sh` starts again with an empty environment and the PATH
  `/usr/bin:/bin:/usr/sbin:/sbin`. Tools and libraries from MAMP, Homebrew or the PATH of the
  user cannot get into a package.
- **Own build tools.** cmake and ninja come from their official releases, and pkgconf is built
  from source. All of them go in the build folder.
- **Pinned sources.** `sources.lock` gives the version, the SHA-256 and the URL of every source.
  The build stops when a download has a different SHA-256.
- **Relocatable packages.** Every link to a library in the package becomes an `@rpath` link.
  Every Mach-O file is signed again, because macOS on Apple silicon does not run an unsigned
  binary.
- **A dependency check.** The build fails when a Mach-O file links a library outside the package
  and the system, or keeps an rpath into the build folder.
- **Licenses.** Each package has a `licenses/` folder with the license of every program in it,
  and a `SOURCE` file with the sources it was built from.

## Packages

| Package | Versions | State |
| --- | --- | --- |
| nginx | 1.30 | Static OpenSSL 3.5, PCRE2 and zlib. Dynamic modules: stream, mail, headers-more, brotli, geoip2 and njs. |
| PHP | 8.2, 8.3, 8.4, 8.5 | CLI and FPM. See [PHP](#php). |
| Apache httpd | 2.4 | All modules as shared modules, the event, worker and prefork MPMs, mod_ssl and mod_http2. APR and APR-util are shared libraries in the package. Not included: mod_lua, mod_md and the LDAP modules. |
| Redis | 7.2, 8.2, newest 8 | redis-server, redis-cli and redis-benchmark, without TLS. 7.2 has the BSD license. Redis 8 is given out under the AGPLv3, one of its three licenses. 7.4 is not built, because its only licenses are RSALv2 and SSPLv1. |
| MySQL | 8.0, 8.4, 9.7 | The official Oracle builds for macOS on Apple silicon, repackaged: without the debug server, the test and MyISAM tools, the static libraries and the headers. Each release also carries the matching source archive. |
| MariaDB | 10.11, 11.4, 11.8, 12.3 | Compiled, because MariaDB publishes no macOS builds. Without ColumnStore, RocksDB, Mroonga, Spider, CONNECT, OQGraph, S3, Galera and the compression providers. The package keeps the server and the client tools, with links under the mysql* names. Run `scripts/mariadb-install-db` from the package folder with `--basedir=.`, because the script breaks on a space in the path. |
| PostgreSQL | 14, 15, 16, 17, 18 | With ICU, libxml2, uuid and all contrib modules (pgcrypto, uuid-ossp, citext, hstore, pg_stat_statements and more). OpenSSL and ICU are shared libraries in the package: libpq refuses a static OpenSSL. |

## PHP

- **Built in:** bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd (with
  FreeType, JPEG, PNG and WebP), gettext, iconv, intl, ldap, mbstring, mysqli, mysqlnd, openssl,
  pcntl, PDO, pdo_mysql, pdo_sqlite, posix, readline (libedit), session, SimpleXML, soap,
  sockets, sodium, sqlite3, tokenizer, xml, xmlreader, xmlwriter, xsl, zip and zlib.
- **Shared, turned on in php.ini:** apcu, igbinary, imagick, pcov, pgsql, pdo_pgsql, redis (with
  igbinary), xdebug, yaml, and opcache for 8.2 to 8.4. In 8.5 opcache is always built in. pgsql
  and pdo_pgsql contain a static libpq 18 with its own OpenSSL. imagick contains a static
  ImageMagick 7 with PNG, JPEG, WebP and FreeType, built with zero configuration.
- **From macOS:** libxml2, libxslt, curl, sqlite, libedit, iconv, zlib and bzip2.
- **In the package:** OpenSSL 3.5, ICU and libintl (shared), and oniguruma, libsodium, libzip,
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
