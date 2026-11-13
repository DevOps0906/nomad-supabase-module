#!/usr/bin/env bash
# 사용: bash products/knowflow/run_check.sh user|org   (로컬 DB 컨테이너 supabase_db_nomad-supabase-module 필요)
# begin → 준비(check_prelude.sql) → 이식 SQL(begin·commit 줄 제거) → check_<안>.sql(끝에 rollback) 을 한 트랜잭션으로 실행한다.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
v="${1:?user 또는 org}"
{
  echo 'begin;'
  cat "$dir/check_prelude.sql"
  for f in "$dir/$v"/0*.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$dir/check_$v.sql"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q
