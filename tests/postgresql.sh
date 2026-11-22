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

licenses="postgresql postgresql-regex postgresql-source-notices snowball openssl icu"
extensions=""
case "$(basename "$root")" in
    postgresql-14.*) ;;
    *)
        extensions="vector postgis postgis_topology pgrouting"
        licenses="$licenses pgvector postgis postgis-notice postgis-ryu postgis-ryu-apache postgis-ryu-boost
        postgis-uthash postgis-flatbuffers postgis-wagyu postgis-wagyu-geometry postgis-geobuf postgis-vector-tile
        postgis-source-notices pgrouting pgrouting-boost boost geos geos-source-notices proj proj-source-notices
        gmp gmp-gpl json-c json-c-source-notices protobuf-c"
        ;;
esac

# With enable_seqscan off, the plan of the query uses the index.
test_vector_index() {
    local database="$1" column="$2" index="$3" query plan
    query="select id from embeddings order by $column <-> '[3,1,2]' limit 1"
    plan="$("${psql[@]}" -At -d "$database" -c "set enable_seqscan = off; explain $query")"

    grep -q "$index" <<< "$plan" || { echo "error: vector does not use $index in $database: $plan" >&2; exit 1; }
    [ "$("${psql[@]}" -At -d "$database" -c "set enable_seqscan = off; $query")" = "2" ] \
        || { echo "error: vector did not find the nearest row with $index in $database" >&2; exit 1; }
}

test_vector() {
    test_vector_index "$1" value embeddings_hnsw
    test_vector_index "$1" half embeddings_ivfflat
}

# The tower of Amersfoort is the point 155000, 463000 of the Dutch grid (EPSG 28992). PROJ has no grid
# files. So the formula gives the point with an error of some meters.
test_spatial() {
    local database="$1" distance

    distance="$("${psql[@]}" -At -d "$database" -c "select round(st_distance(st_transform(place, 28992), st_setsrid(st_point(155000, 463000), 28992))) from towns where name = 'Amersfoort'")"
    [ -n "$distance" ] && [ "${distance%.*}" -le 5 ] \
        || { echo "error: the point in the Dutch grid is $distance meters away in $database" >&2; exit 1; }

    [ "$("${psql[@]}" -At -d "$database" -c "select name from towns order by place <-> st_setsrid(st_point(4.9, 52.37), 4326) limit 1")" = "Amsterdam" ] \
        || { echo "error: PostGIS did not find the nearest town in $database" >&2; exit 1; }

    [ "$("${psql[@]}" -At -d "$database" -c "select st_x(st_geomfromgeojson('{\"type\":\"Point\",\"coordinates\":[5,52]}'))")" = "5" ] \
        || { echo "error: PostGIS did not read GeoJSON in $database" >&2; exit 1; }

    [ "$("${psql[@]}" -At -d "$database" -c "select length(st_asmvt(tile, 'towns')) > 0 from (select name, st_asmvtgeom(st_transform(place, 3857), st_tileenvelope(0, 0, 0)) as geom from towns) tile")" = "t" ] \
        || { echo "error: PostGIS made no vector tile in $database" >&2; exit 1; }

    [ "$("${psql[@]}" -At -d "$database" -c "select string_agg(node::text, ',' order by seq) from pgr_dijkstra('select id, source, target, cost from roads', 1, 4)")" = "1,2,4" ] \
        || { echo "error: pgRouting did not find the shortest route in $database" >&2; exit 1; }

    [ "$("${psql[@]}" -At -d "$database" -c "select topology.topogeo_addpoint('net', st_setsrid(st_point(1, 1), 4326)) > 0")" = "t" ] \
        || { echo "error: the topology does not work in $database" >&2; exit 1; }
}

# The programs of PostGIS must run from a folder with a space in its path.
test_spatial_programs() {
    "$root/bin/pgsql2shp" -f "$base/towns.shp" -h 127.0.0.1 -p "$port" -u postgres nexus_test towns > "$base/pgsql2shp.log" 2>&1 \
        || { cat "$base/pgsql2shp.log"; echo "error: pgsql2shp failed" >&2; exit 1; }
    [ "$("$root/bin/shp2pgsql" -s 4326 "$base/towns.shp" towns_copy 2> /dev/null | grep -c "INSERT INTO")" = "2" ] \
        || { echo "error: shp2pgsql did not read the file" >&2; exit 1; }
    output="$("$root/bin/pgtopo_export" --help 2>&1 < /dev/null || true)"
    grep -qi usage <<< "$output" || { echo "error: pgtopo_export does not run: $output" >&2; exit 1; }
}

if [ -n "$extensions" ]; then
    "${psql[@]}" -d nexus_test -c "create extension postgis; create extension postgis_topology; create extension pgrouting;
    create table towns (name text, place geometry(Point, 4326));
    insert into towns values ('Amersfoort', st_setsrid(st_point(5.38720621, 52.15517440), 4326)), ('Amsterdam', st_setsrid(st_point(4.9, 52.37), 4326));
    create index towns_place on towns using gist (place);
    select topology.createtopology('net', 4326);
    create table roads (id int, source int, target int, cost float);
    insert into roads values (1, 1, 2, 1), (2, 2, 4, 1), (3, 1, 3, 1), (4, 3, 4, 5);" > /dev/null
    test_spatial nexus_test
    test_spatial_programs
    echo "==> $("${psql[@]}" -At -d nexus_test -c "select 'PostGIS ' || postgis_lib_version() || ' and pgRouting ' || pgr_version()") work"

    "${psql[@]}" -d nexus_test -c "create extension vector;
    create table embeddings (id int primary key, value vector(3), half halfvec(3));
    insert into embeddings values (1, '[1,2,3]', '[1,2,3]'), (2, '[3,1,2]', '[3,1,2]'), (3, '[9,9,9]', '[9,9,9]');
    create index embeddings_hnsw on embeddings using hnsw (value vector_l2_ops);
    create index embeddings_ivfflat on embeddings using ivfflat (half halfvec_l2_ops) with (lists = 1);"
    test_vector nexus_test
    echo "==> vector $("${psql[@]}" -At -d nexus_test -c "select extversion from pg_extension where extname = 'vector'") finds the nearest row with its index"
fi

echo "==> dump and restore a database"
"$root/bin/pg_dump" -h 127.0.0.1 -p "$port" -U postgres -Fc nexus_test > "$base/dump.pgdump"
"${psql[@]}" -c "create database nexus_copy"
"$root/bin/pg_restore" -h 127.0.0.1 -p "$port" -U postgres -d nexus_copy "$base/dump.pgdump"
[ "$("${psql[@]}" -At -d nexus_copy -c "select count(*) from items")" = "2" ] \
    || { echo "error: the restored copy differs" >&2; exit 1; }
if [ -n "$extensions" ]; then
    test_vector nexus_copy
    test_spatial nexus_copy
fi

echo "==> copy a database with a template"
"${psql[@]}" -c "create database nexus_template_copy template nexus_copy"
[ "$("${psql[@]}" -At -d nexus_template_copy -c "select name from items order by name limit 1")" = "één" ] \
    || [ "$("${psql[@]}" -At -d nexus_template_copy -c "select count(*) from items")" = "2" ] \
    || { echo "error: the template copy differs" >&2; exit 1; }

missing=""
for name in $licenses; do
    [ -s "$root/licenses/$name.txt" ] || missing="$missing $name"
done
[ -z "$missing" ] || { echo "error: licenses are missing:$missing" >&2; exit 1; }
echo "==> the package has all $(echo $licenses | wc -w | tr -d ' ') license files"

# One author of each part of PostgreSQL that has its license only in the source files.
while IFS= read -r author; do
    grep -q -F "$author" "$root/licenses/postgresql-source-notices.txt" ||
        { echo "error: the notice of $author is missing" >&2; exit 1; }
done <<'EOF'
Ulf Adams
Aaron D. Gifford
Todd C. Miller
Marko Kreen
Solar Designer
David Burren
Hideaki Ohno
Joe Conway
Tatsuo Ishii
Philip Warner
Whitley
Eric P. Allman
EOF
case "$(basename "$root")" in
    postgresql-14.*)
        grep -q -F "Martin Birgmeier" "$root/licenses/postgresql-source-notices.txt" ||
            { echo "error: the notice of Martin Birgmeier is missing" >&2; exit 1; }
        ;;
esac
echo "==> the package has the notices of the source files"

echo "==> all PostgreSQL tests passed"
