#!/usr/bin/env bash
# 사용: bash products/hospital/run_check.sh  (로컬 nomad-supabase-module DB, 항상 rollback)
# 격리형: 별도 Supabase 프로젝트용 파일을 로컬 DB 트랜잭션 안에서 적용→검사→rollback(스택 따로 띄우지 않음).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
SQL="$D/isolated/0001_hospital.sql"
# 공용 스키마 참조 0 (주석 포함)
if grep -n 'nomad_core' "$SQL"; then echo "hospital check_isolated: FAIL (nomad_core 참조)" >&2; exit 1; fi
{
  echo "begin;"
  echo "drop schema if exists nomad_hospital cascade;"
  sed '/^begin;$/d;/^commit;$/d' "$SQL"
  cat "$D/check_isolated.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "hospital check_isolated: PASS (rolled back)"
