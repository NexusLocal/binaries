#!/bin/bash
#
# Tests a MySQL or MariaDB package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus:
#
#   tests/mysql.sh /tmp/nexus-build/out/mysql-8.4.13-macos-arm64.tar.xz
#
# Set NEXUS_TEST_DUMP to an SQL dump to also restore that dump into the new server.

set -euo pipefail

archive="${1:?usage: tests/mysql.sh <archive>}"
base="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/*-*)"
data="$base/Nexus Test/data"
socket="$base/mysql.sock"

if [ -x "$root/bin/mariadbd" ]; then
    server="$root/bin/mariadbd"
    client="$root/bin/mariadb"
    dump="$root/bin/mariadb-dump"
    adminbin="$root/bin/mariadb-admin"
    extra=()
    dump_flags=()
else
    server="$root/bin/mysqld"
    client="$root/bin/mysql"
    dump="$root/bin/mysqldump"
    adminbin="$root/bin/mysqladmin"
    extra=(--mysqlx=OFF)
    # MySQL 9 turns GTIDs on, and a dump with GTID_PURGED cannot go back into the same server.
    dump_flags=(--set-gtid-purged=OFF)
fi

admin=("$adminbin" --no-defaults -uroot -h127.0.0.1 -P"$port")
sql=("$client" --no-defaults -uroot -h127.0.0.1 -P"$port")
trap '"${admin[@]}" shutdown > /dev/null 2>&1 || true; sleep 2; rm -rf "$base"' EXIT

if [ -x "$root/bin/mariadbd" ]; then
    # mariadb-install-db breaks on a space in --basedir, so it runs from the package folder
    # with --basedir=. The data folder may have a space.
    (cd "$root" && ./scripts/mariadb-install-db --no-defaults --basedir=. --datadir="$data" \
        --auth-root-authentication-method=normal) > "$base/install.log" 2>&1 \
        || { cat "$base/install.log"; echo "error: mariadb-install-db failed" >&2; exit 1; }
else
    "$server" --no-defaults --basedir="$root" --datadir="$data" --initialize-insecure \
        --log-error="$base/install.log" \
        || { cat "$base/install.log" 2> /dev/null; echo "error: mysqld --initialize-insecure failed" >&2; exit 1; }
fi

echo "==> $("$server" --version)"
echo "==> start the server on port $port"
"$server" --no-defaults --basedir="$root" --datadir="$data" --port="$port" \
    --bind-address=127.0.0.1 --socket="$socket" --log-error="$base/error.log" \
    --pid-file="$base/server.pid" ${extra[@]+"${extra[@]}"} &

for attempt in $(seq 1 60); do
    "${admin[@]}" ping > /dev/null 2>&1 && break
    sleep 1
done
"${admin[@]}" ping > /dev/null 2>&1 || { tail -20 "$base/error.log"; echo "error: the server did not start" >&2; exit 1; }

"${sql[@]}" -e "create database nexus_test; create table nexus_test.items (id int primary key, name varchar(20)); insert into nexus_test.items values (1, 'één'), (2, 'two');"
[ "$("${sql[@]}" -N -e "select count(*) from nexus_test.items")" = "2" ] || { echo "error: the insert failed" >&2; exit 1; }

echo "==> dump and restore a database"
"$dump" --no-defaults -uroot -h127.0.0.1 -P"$port" --single-transaction ${dump_flags[@]+"${dump_flags[@]}"} nexus_test > "$base/dump.sql"
"${sql[@]}" -e "create database nexus_copy"
"${sql[@]}" nexus_copy < "$base/dump.sql"
[ "$("${sql[@]}" -N -e "select name from nexus_copy.items where id = 1")" = "één" ] || { echo "error: the restored copy differs" >&2; exit 1; }

if [ -n "${NEXUS_TEST_DUMP:-}" ]; then
    echo "==> restore $(basename "$NEXUS_TEST_DUMP")"
    "${sql[@]}" -e "create database nexus_import"
    "${sql[@]}" nexus_import < "$NEXUS_TEST_DUMP"
    echo "    $("${sql[@]}" -N -e "select count(*) from information_schema.tables where table_schema = 'nexus_import'") tables restored"
fi

echo "==> all database tests passed"
