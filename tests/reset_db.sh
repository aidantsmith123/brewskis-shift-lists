#!/bin/bash
# Rebuild the test database "bk" the way the live one grew: the first schema and its data, then today's schema on top.
# Test login numbers: Aidan 4821, Jill 1111 (none of them is a real login number).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
P="psql -h /var/tmp -p 54329 -U postgres -q -v ON_ERROR_STOP=1"
$P -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='bk' and pid<>pg_backend_pid()" >/dev/null; $P -c "drop database if exists bk" -c "create database bk" 2>&1 | grep -v NOTICE || true
$P -d bk -f "$HERE/fixtures/schema_v1.sql" 2>&1 | grep -v NOTICE || true
$P -d bk -f "$HERE/fixtures/seed.sql"
$P -d bk -Atc "select admin_set_pin('Aidan','4821'); select admin_set_pin('Jill','1111');" >/dev/null
$P -d bk -f "$HERE/fixtures/realtime_stub.sql" >/dev/null
$P -d bk -f "$REPO/supabase/schema.sql" 2>&1 | grep -v NOTICE || true
