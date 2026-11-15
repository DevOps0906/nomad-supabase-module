#!/usr/bin/env bash
# 사용: bash products/lottolab/run_check.sh [user|org]  (인자 없으면 둘 다)  (로컬 nomad-supabase-module DB, 항상 rollback)
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
for V in ${1:-user org}; do
{
  echo "begin;"
  echo "drop schema if exists nomad_lottolab cascade; drop schema if exists nomad_lottolab_private cascade;"
  echo "create or replace function nomad_core.touch_updated_at() returns trigger language plpgsql set search_path = '' as \$f\$ begin new.updated_at := clock_timestamp(); return new; end; \$f\$;"
  for f in "$D/$V"/0001_lottolab.sql "$D"/app/0001_app_tables.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_$V.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q
echo "check_$V: PASS (rolled back)"
done
