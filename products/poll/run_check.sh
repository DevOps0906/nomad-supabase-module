#!/usr/bin/env bash
# 사용: bash products/poll/run_check.sh  (로컬 nomad-supabase-module DB, 항상 rollback)
# begin → 임시 touch_updated_at → org/0001·0002(begin·commit 줄 제거) → check_org.sql → rollback 을 한 트랜잭션으로 실행한다.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
{
  echo "begin;"
  echo "drop schema if exists nomad_poll cascade; drop schema if exists nomad_poll_private cascade;"
  echo "create or replace function nomad_core.touch_updated_at() returns trigger language plpgsql set search_path = '' as \$f\$ begin new.updated_at := clock_timestamp(); return new; end; \$f\$;"
  for f in "$D"/org/0*.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_org.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "poll check_org: PASS (rolled back)"
