#!/usr/bin/env bash
# 사용: bash products/sceneflow/run_check.sh  (로컬 nomad-supabase-module DB, 항상 rollback)
# 청사진(supabase/migrations/*_sceneflow.sql)과 같은 스키마 이름이라 트랜잭션 안에서 먼저 지운다(rollback 으로 복원).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
{
  echo "begin;"
  echo "drop schema if exists nomad_sceneflow cascade; drop schema if exists nomad_sceneflow_private cascade;"
  for f in "$D"/org/0001_sceneflow.sql "$D"/org/0002_ai.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_org.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "sceneflow check_org: PASS (rolled back)"
