#!/usr/bin/env bash
# 사용: bash products/classroom/run_check.sh  (로컬 nomad-supabase-module DB, 항상 rollback)
# 청사진 nomad_classroom(supabase/migrations *_classroom.sql)은 같은 스키마 이름이라 트랜잭션 안에서 drop 한 뒤 적용한다(D9).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
{
  echo "begin;"
  echo "drop schema if exists nomad_classroom cascade;"
  for f in "$D"/org/0001_classroom.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_org.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "classroom check_org: PASS (rolled back)"
