#!/bin/bash
#
# Tests a PostgreSQL package in a folder with a space in its path, the same as
# ~/Library/Application Support/Nexus:
#
#   tests/postgresql.sh /tmp/nexus-build/out/postgresql-18.6-macos-arm64.tar.xz

set -euo pipefail

archive="${1:?usage: tests/postgresql.sh <archive>}"
base="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))

mkdir -p "$base/Nexus Test"
tar -xf "$archive" -C "$base/Nexus Test"
root="$(ls -d "$base/Nexus Test"/postgresql-*)"
data="$base/Nexus Test/data"
trap '"$root/bin/pg_ctl" -D "$data" -m fast stop > /dev/null 2>&1 || true; rm -rf "$base"' EXIT

echo "==> $("$root/bin/postgres" --version)"

"$root/bin/initdb" -D "$data" -U postgres --auth=trust --encoding=UTF8 --locale-provider=icu \
    --icu-locale=en-US > "$base/initdb.log" 2>&1 \
    || "$root/bin/initdb" -D "$data" -U postgres --auth=trust --encoding=UTF8 --locale=C > "$base/initdb.log" 2>&1 \
    || { cat "$base/initdb.log"; echo "error: initdb failed" >&2; exit 1; }

echo "==> start the server on port $port"
"$root/bin/pg_ctl" -D "$data" -l "$base/server.log" -w \
    -o "-p $port -k $base -c listen_addresses=127.0.0.1" start > /dev/null \
    || { cat "$base/server.log"; echo "error: the server did not start" >&2; exit 1; }

psql=("$root/bin/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$port" -U postgres)

"${psql[@]}" -c "create database nexus_test"
"${psql[@]}" -d nexus_test -c "create extension pgcrypto; create extension \"uuid-ossp\"; create extension citext;
create table items (id uuid primary key default gen_random_uuid(), name citext, other uuid default uuid_generate_v4());
insert into items (name) values ('één'), ('Two');"
[ "$("${psql[@]}" -At -d nexus_test -c "select count(*) from items where name = 'two'")" = "1" ] \
    || { echo "error: citext did not compare without case" >&2; exit 1; }

echo "==> dump and restore a database"
"$root/bin/pg_dump" -h 127.0.0.1 -p "$port" -U postgres -Fc nexus_test > "$base/dump.pgdump"
"${psql[@]}" -c "create database nexus_copy"
"$root/bin/pg_restore" -h 127.0.0.1 -p "$port" -U postgres -d nexus_copy "$base/dump.pgdump"
[ "$("${psql[@]}" -At -d nexus_copy -c "select count(*) from items")" = "2" ] \
    || { echo "error: the restored copy differs" >&2; exit 1; }

echo "==> copy a database with a template"
"${psql[@]}" -c "create database nexus_template_copy template nexus_copy"
[ "$("${psql[@]}" -At -d nexus_template_copy -c "select name from items order by name limit 1")" = "één" ] \
    || [ "$("${psql[@]}" -At -d nexus_template_copy -c "select count(*) from items")" = "2" ] \
    || { echo "error: the template copy differs" >&2; exit 1; }

echo "==> all PostgreSQL tests passed"
