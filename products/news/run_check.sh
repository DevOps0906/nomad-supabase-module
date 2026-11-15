#!/usr/bin/env bash
# 사용: bash products/news/run_check.sh  (로컬 nomad-supabase-module DB, 항상 rollback)
# 청사진에 nomad_news 스키마는 없지만 sceneflow 와 같은 형식으로 트랜잭션 안에서 먼저 지운다(rollback 으로 복원).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
{
  echo "begin;"
  echo "drop schema if exists nomad_news cascade;"
  for f in "$D"/org/0001_news.sql "$D"/org/0002_ai.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_org.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "news check_org: PASS (rolled back)"
