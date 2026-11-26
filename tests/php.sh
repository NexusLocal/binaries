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
    grep -qx "$module" <<< "$modules" || missing="$missing $module"
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
        redis|memcached) flags+=(-d "extension=igbinary" -d "extension=$name") ;;
        *) flags+=(-d "extension=$name") ;;
    esac

    output="$("$php" "${flags[@]}" -m 2>&1)" || true
    if ! grep -qx "$(module_name "$name")" <<< "$output"; then
        sed -n 1,5p <<< "$output"
        echo "error: the shared extension $name does not load" >&2
        exit 1
    fi

    # Composer reads the version of an extension. A source from git can give a text there instead.
    version="$("$php" "${flags[@]}" -r "echo phpversion('$(module_name "$name")');" 2>/dev/null)" || true
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+ ]]; then
        echo "error: the shared extension $name gives the version '$version'" >&2
        exit 1
    fi
    echo "==> the shared extension $name loads, version $version"
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

echo "==> mailparse reads the parts of a mail"
"$php" -n -d "extension_dir=$extensions" -d extension=mailparse -r '
$mail = mailparse_msg_create();
mailparse_msg_parse($mail, "From: Ann <ann@example.test>\r\nSubject: Hi\r\nContent-Type: text/plain\r\n\r\nHello\r\n");
$headers = mailparse_msg_get_part_data($mail)["headers"];
$address = mailparse_rfc822_parse_addresses($headers["from"])[0]["address"];
if ($headers["subject"] !== "Hi" || $address !== "ann@example.test") {
    fwrite(STDERR, "error: mailparse read the mail wrong\n");
    exit(1);
}
echo "  mailparse ", phpversion("mailparse"), "\n";
'

echo "==> gmp calculates with large numbers"
"$php" -n -d "extension_dir=$extensions" -d extension=gmp -r '
$power = gmp_strval(gmp_powm("123456789012345678901234567890", "65537", "340282366920938463463374607431768211507"));
$factorial = gmp_strval(gmp_fact(30));
if ($power !== bcpowmod("123456789012345678901234567890", "65537", "340282366920938463463374607431768211507") || $factorial !== "265252859812191058636308480000000") {
    fwrite(STDERR, "error: gmp gave $power and $factorial\n");
    exit(1);
}
echo "  GMP ", GMP_VERSION, "\n";
'
otool -L "$extensions/gmp.so" | grep "@rpath/libgmp" > /dev/null || { echo "error: gmp.so does not use the shared library of GMP" >&2; exit 1; }

echo "==> igbinary stores a nested value and reads it back"
"$php" -n -d "extension_dir=$extensions" -d extension=igbinary -r '
$value = ["name" => "shop", "items" => [1, 2.5, true, null, ["deep" => str_repeat("x", 300)]], "when" => new DateTimeImmutable("2026-11-26 10:00:00")];
$copy = igbinary_unserialize(igbinary_serialize($value));

if ($copy != $value) {
    fwrite(STDERR, "error: igbinary did not give the same value back\n");
    exit(1);
}
echo "  igbinary ", phpversion("igbinary"), "\n";
'

echo "==> memcached stores a value with igbinary on a server that speaks the text protocol"
"$php" -n -d "extension_dir=$extensions" -d extension=igbinary -d extension=memcached -r '
$server = stream_socket_server("tcp://127.0.0.1:0");
$port = (int) substr(strrchr(stream_socket_get_name($server, false), ":"), 1);
$pid = pcntl_fork();

if ($pid === -1) {
    fwrite(STDERR, "error: the memcached server of the test did not start\n");
    exit(1);
}

if ($pid === 0) {
    $stored = [];
    $connection = stream_socket_accept($server, 20);
    while (($line = fgets($connection)) !== false) {
        $words = explode(" ", rtrim($line));
        if ($words[0] === "set") {
            $stored[$words[1]] = [$words[2], rtrim(stream_get_contents($connection, (int) $words[4] + 2), "\r\n")];
            fwrite($connection, "STORED\r\n");
        } elseif (in_array($words[0], ["get", "gets"], true)) {
            [$flags, $data] = $stored[$words[1]] ?? ["0", ""];
            fwrite($connection, isset($stored[$words[1]]) ? "VALUE {$words[1]} $flags " . strlen($data) . "\r\n$data\r\nEND\r\n" : "END\r\n");
        } elseif ($words[0] === "quit") {
            break;
        }
    }
    posix_kill(posix_getpid(), SIGKILL);
}

$client = new Memcached();
$client->addServer("127.0.0.1", $port);
$value = ["name" => "Ann", "numbers" => [1, 2, 3]];
$stored = $client->set("key", $value);
$read = $client->get("key");
$message = $client->getResultMessage();
posix_kill($pid, SIGKILL);
pcntl_waitpid($pid, $status);

if ($client->getOption(Memcached::OPT_SERIALIZER) !== Memcached::SERIALIZER_IGBINARY || !$stored || $read !== $value) {
    fwrite(STDERR, "error: memcached did not store and read a value: $message\n");
    exit(1);
}
echo "  memcached ", phpversion("memcached"), "\n";
'
undefined="$(nm -u "$extensions/memcached.so")"
! echo "$undefined" | grep -E "memcached_|hashkit_" || { echo "error: memcached.so needs libmemcached from outside" >&2; exit 1; }

echo "==> mongodb has TLS, zlib and SRV records, and no client-side encryption"
"$php" -n -d "extension_dir=$extensions" -d extension=mongodb --ri mongodb > "$base/mongodb.txt"
for line in "libmongoc SSL => enabled" "libmongoc SSL library => OpenSSL" "libmongoc crypto => enabled" \
    "libmongoc SRV => enabled" "libmongoc compression => enabled" "libmongoc compression zlib => enabled" \
    "libmongoc SASL => disabled" "libmongocrypt => disabled"; do
    grep -qxF "$line" "$base/mongodb.txt" || { cat "$base/mongodb.txt"; echo "error: mongodb does not have: $line" >&2; exit 1; }
done

echo "==> mongodb sends a command to a server that speaks its protocol"
"$php" -n -d "extension_dir=$extensions" -d extension=mongodb -r '
use MongoDB\BSON\Document;
use MongoDB\Driver\Command;
use MongoDB\Driver\Manager;

$server = stream_socket_server("tcp://127.0.0.1:0");
$port = (int) substr(strrchr(stream_socket_get_name($server, false), ":"), 1);
$pid = pcntl_fork();

if ($pid === -1) {
    fwrite(STDERR, "error: the mongodb server of the test did not start\n");
    exit(1);
}

if ($pid === 0) {
    $read = function ($connection, int $length): string {
        $data = "";
        while (strlen($data) < $length && ($part = fread($connection, $length - strlen($data))) !== false && $part !== "") {
            $data .= $part;
        }
        return $data;
    };
    $clients = [];
    while (true) {
        $ready = [$server, ...$clients];
        $none = null;
        if (! stream_select($ready, $none, $none, 20)) {
            posix_kill(posix_getpid(), SIGKILL);
        }
        foreach ($ready as $connection) {
            if ($connection === $server) {
                $clients[] = stream_socket_accept($server, 20);
                continue;
            }
            $header = $read($connection, 16);
            if (strlen($header) < 16) {
                unset($clients[array_search($connection, $clients, true)]);
                continue;
            }
            ["length" => $length, "id" => $id, "opcode" => $opcode] = unpack("Vlength/Vid/Vto/Vopcode", $header);
            $body = $read($connection, $length - 16);
            $hello = ["ok" => 1.0, "isWritablePrimary" => true, "ismaster" => true, "minWireVersion" => 0, "maxWireVersion" => 25, "maxBsonObjectSize" => 16777216, "maxMessageSizeBytes" => 48000000, "maxWriteBatchSize" => 100000];
            $isPing = $opcode === 2013 && array_key_first((array) Document::fromBSON(substr($body, 5))->toPHP(["root" => "array"])) === "ping";
            $answer = (string) Document::fromPHP($isPing ? ["ok" => 1.0, "answer" => "pong"] : $hello);
            $message = $opcode === 2013 ? pack("V", 0) . "\0" . $answer : pack("VPVV", 8, 0, 0, 1) . $answer;
            fwrite($connection, pack("VVVV", 16 + strlen($message), 1, $id, $opcode === 2013 ? 2013 : 1) . $message);
        }
    }
}

try {
    $manager = new Manager("mongodb://127.0.0.1:$port/?serverSelectionTimeoutMS=10000");
    $answer = $manager->executeCommand("admin", new Command(["ping" => 1]))->toArray()[0]->answer ?? "nothing";
} catch (Throwable $exception) {
    $answer = $exception->getMessage();
}
posix_kill($pid, SIGKILL);
pcntl_waitpid($pid, $status);

$bson = Document::fromJSON("{\"name\": \"Ann\", \"id\": {\"\$oid\": \"5f5f5f5f5f5f5f5f5f5f5f5f\"}}");
if ($answer !== "pong" || $bson->get("name") !== "Ann" || (string) $bson->get("id") !== "5f5f5f5f5f5f5f5f5f5f5f5f") {
    fwrite(STDERR, "error: mongodb gave the answer $answer\n");
    exit(1);
}
echo "  mongodb ", phpversion("mongodb"), "\n";
'
undefined="$(nm -u "$extensions/mongodb.so")"
! echo "$undefined" | grep -E "_(mongoc|bson|kms|utf8proc|SSL|EVP|X509|BIO|CRYPTO|ERR|RAND|OPENSSL)_" || { echo "error: mongodb.so needs a library from outside" >&2; exit 1; }
linked="$(otool -L "$extensions/mongodb.so")"
! echo "$linked" | tail -n +2 | grep -E "ssl|crypto|snappy|zstd|sasl" || { echo "error: mongodb.so links a library that the package does not have" >&2; exit 1; }

licenses="php openssl icu libintl oniguruma libsodium libzip libpng libjpeg-turbo libwebp freetype
libyaml openldap libpq imagemagick igbinary redis xdebug pcov apcu yaml imagick mailparse gmp gmp-gpl
libmemcached libmemcached-md5 memcached fastlz memcached-g-fmt zend-asm tsrm php-fpm libbcmath timelib libmagic
libmbfl libavifinfo pcre2 libgd xxhash dynasm mongodb mongodb-third-party mongodb-source-notices jsonsl"
# From PHP 8.6 on, the LICENSE of PHP also covers the Zend Engine. So it has no zend license.
case "$(basename "$root")" in
    php-8.2.*|php-8.3.*) licenses="$licenses zend" ;;
    php-8.4.*) licenses="$licenses zend opcache-jit-ir lexbor lexbor-notice" ;;
    php-8.5.*) licenses="$licenses zend opcache-jit-ir lexbor lexbor-notice uriparser" ;;
    *) licenses="$licenses opcache-jit-ir lexbor lexbor-notice uriparser" ;;
esac
missing=""
for name in $licenses; do
    [ -s "$root/licenses/$name.txt" ] || missing="$missing $name"
done
[ -z "$missing" ] || { echo "error: licenses are missing:$missing" >&2; exit 1; }
for author in "International Business Machines" "Internet Software Consortium" "Troy D. Hanson" "Steven G. Johnson" "University of California"; do
    grep -qF "$author" "$root/licenses/mongodb-source-notices.txt" || { echo "error: the notices of mongodb do not name $author" >&2; exit 1; }
done
echo "==> the package has all $(echo $licenses | wc -w | tr -d ' ') license files"

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
