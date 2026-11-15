#!/usr/bin/env bash
# 사용: bash products/baedal/run_check.sh [user|org]  (인자 없으면 둘 다)  (로컬 nomad-supabase-module DB, 항상 rollback)
# 청사진 nomad_baedal(supabase/migrations *_baedal.sql)은 같은 스키마 이름이라 트랜잭션 안에서 drop 한 뒤 적용한다(D9).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
for V in ${1:-user org}; do
{
  echo "begin;"
  echo "drop schema if exists nomad_baedal cascade; drop schema if exists nomad_baedal_private cascade;"
  for f in "$D/$V"/0*.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_$V.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "baedal check_$V: PASS (rolled back)"
done
