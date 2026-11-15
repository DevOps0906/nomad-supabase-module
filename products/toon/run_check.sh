#!/usr/bin/env bash
# 사용: bash products/toon/run_check.sh  (로컬 nomad-supabase-module DB, 항상 rollback)
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
{
  echo "begin;"
  echo "drop schema if exists nomad_toon cascade; drop schema if exists nomad_toon_private cascade;"
  for f in "$D"/org/0001_toon.sql "$D"/org/0002_ai.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_org.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "check_org: PASS (rolled back)"
