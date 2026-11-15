#!/usr/bin/env bash
# 사용: bash products/school/run_check.sh  (로컬 nomad-supabase-module DB, 항상 rollback)
# check_org.sql 앞부분(준비) → org/0001 → check_org.sql @@APPLY 이후(검사) → org/0002 → rollback 을 한 트랜잭션으로 실행한다.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
{
  sed '/^-- @@APPLY/,$d' "$D/check_org.sql"
  sed '/^begin;$/d;/^commit;$/d' "$D/org/0001_school.sql"
  sed -n '/^-- @@APPLY/,$p' "$D/check_org.sql"
  sed '/^begin;$/d;/^commit;$/d' "$D/org/0002_ai.sql"
  echo 'rollback;'
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "school check_org: PASS (rolled back)"
