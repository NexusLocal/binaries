#!/bin/bash
#
# Tests a PHP package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus:
#
#   tests/php.sh /tmp/nexus-build/out/php-8.5.12-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/php.sh <archive>}"
base="$(mktemp -d)"
trap 'kill "$(cat "$base/php-fpm.pid" 2> /dev/null)" 2> /dev/null || true; rm -rf "$base"' EXIT

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/php-*)"
php="$root/bin/php"
extensions="$(ls -d "$root"/lib/php/extensions/no-debug-non-zts-*)"

export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

echo "==> $("$php" -n -v | head -1)"

built_in="bcmath bz2 calendar Core ctype curl date dom exif fileinfo filter ftp gd gettext hash iconv intl
json ldap libxml mbstring mysqli mysqlnd openssl pcntl pcre PDO pdo_mysql pdo_sqlite Phar posix random
readline Reflection session SimpleXML soap sockets sodium SPL sqlite3 standard tokenizer xml xmlreader
xmlwriter xsl zip zlib"

modules="$("$php" -n -m)"
missing=""
for module in $built_in; do
    echo "$modules" | grep -qx "$module" || missing="$missing $module"
done
[ -z "$missing" ] || { echo "error: built-in extensions are missing:$missing" >&2; exit 1; }
echo "==> all $(echo $built_in | wc -w | tr -d ' ') built-in extensions are present"

module_name() {
    case "$1" in
        xdebug) echo "Xdebug" ;;
        opcache) echo "Zend OPcache" ;;
        *) echo "$1" ;;
    esac
}

for file in "$extensions"/*.so; do
    name="$(basename "$file" .so)"
    flags=(-n -d "extension_dir=$extensions")
    case "$name" in
        xdebug|opcache) flags+=(-d "zend_extension=$name") ;;
        redis) flags+=(-d "extension=igbinary" -d "extension=redis") ;;
        *) flags+=(-d "extension=$name") ;;
    esac

    output="$("$php" "${flags[@]}" -m 2>&1)" || true
    if ! echo "$output" | grep -qx "$(module_name "$name")"; then
        echo "$output" | head -5
        echo "error: the shared extension $name does not load" >&2
        exit 1
    fi
    echo "==> the shared extension $name loads"
done

echo "==> functional checks"
"$php" -n -d "extension_dir=$extensions" <<'PHP'
<?php
$checks = [
    'intl formats a number' => fn () => (new NumberFormatter('nl_NL', NumberFormatter::CURRENCY))->formatCurrency(1234.5, 'EUR') !== false,
    'gd writes webp, jpeg and png' => function () {
        $image = imagecreatetruecolor(16, 16);
        foreach (['imagewebp', 'imagejpeg', 'imagepng'] as $writer) {
            ob_start();
            $writer($image);
            if (strlen(ob_get_clean()) === 0) {
                return false;
            }
        }
        return true;
    },
    'gd uses freetype' => fn () => gd_info()['FreeType Support'] === true,
    'openssl uses the macOS CA file' => fn () => openssl_get_cert_locations()['default_cert_file'] === '/private/etc/ssl/cert.pem',
    'curl has TLS' => fn () => curl_version()['ssl_version'] !== '',
    'mbstring has regex' => fn () => mb_ereg('ä', 'bär') === true,
    'sodium encrypts' => fn () => strlen(sodium_crypto_secretbox('x', random_bytes(24), random_bytes(32))) > 0,
    'zip writes an archive' => function () {
        $file = tempnam(sys_get_temp_dir(), 'zip');
        $zip = new ZipArchive();
        $zip->open($file, ZipArchive::OVERWRITE);
        $zip->addFromString('a.txt', 'a');
        $ok = $zip->close();
        unlink($file);
        return $ok;
    },
    'argon2id hashes' => fn () => str_starts_with(password_hash('secret', PASSWORD_ARGON2ID), '$argon2id$'),
    'iconv transliterates' => fn () => iconv('UTF-8', 'ASCII//TRANSLIT', 'café') !== false,
    'xsl transforms' => fn () => class_exists(XSLTProcessor::class),
    'pdo_sqlite queries' => fn () => (new PDO('sqlite::memory:'))->query('select 1')->fetchColumn() == 1,
    'gettext works' => fn () => gettext('hello') === 'hello',
    'a forked child can use intl and gettext' => function () {
        $pid = pcntl_fork();
        if ($pid === 0) {
            $ok = gettext('x') === 'x' && (new NumberFormatter('de_DE', NumberFormatter::DECIMAL))->format(1.5) === '1,5';
            exit($ok ? 0 : 1);
        }
        pcntl_waitpid($pid, $status);
        return pcntl_wexitstatus($status) === 0;
    },
];

$failed = 0;
foreach ($checks as $name => $check) {
    $ok = false;
    try {
        $ok = $check();
    } catch (Throwable $exception) {
        echo "  {$name}: {$exception->getMessage()}\n";
    }
    echo ($ok ? '  ok      ' : '  FAILED  ') . $name . "\n";
    $failed += $ok ? 0 : 1;
}
exit($failed === 0 ? 0 : 1);
PHP

echo "==> imagick writes PNG, JPEG and WebP"
"$php" -n -d "extension_dir=$extensions" -d extension=imagick -r '
foreach (["png", "jpeg", "webp"] as $format) {
    $image = new Imagick();
    $image->newImage(16, 16, "red");
    $image->setImageFormat($format);
    if (strlen($image->getImageBlob()) === 0) {
        fwrite(STDERR, "error: imagick wrote no $format\n");
        exit(1);
    }
}
echo "  ImageMagick ", Imagick::getVersion()["versionString"], "\n";
'

echo "==> php-config gives paths inside the package"
prefix="$("$root/bin/php-config" --prefix)"
[ "$prefix" = "$root" ] || { echo "error: php-config --prefix gives $prefix" >&2; exit 1; }
[ "$("$root/bin/php-config" --extension-dir)" = "$extensions" ] || { echo "error: php-config --extension-dir is wrong" >&2; exit 1; }

echo "==> php-fpm checks its configuration and starts"
cat > "$base/php-fpm.conf" <<EOF
[global]
pid = $base/php-fpm.pid
error_log = $base/php-fpm.log

[test]
listen = $base/php-fpm.sock
pm = static
pm.max_children = 1
EOF
"$root/sbin/php-fpm" -n -y "$base/php-fpm.conf" -t
"$root/sbin/php-fpm" -n -y "$base/php-fpm.conf"
sleep 1
[ -S "$base/php-fpm.sock" ] || { cat "$base/php-fpm.log"; echo "error: php-fpm made no socket" >&2; exit 1; }

echo "==> all PHP tests passed"
