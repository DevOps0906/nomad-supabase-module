#!/usr/bin/env bash
# 사용: bash products/astro/run_check.sh [user|org]  (인자 없으면 둘 다)  (로컬 nomad-supabase-module DB, 항상 rollback)
# begin → 청사진 drop → <안>/0001·0002 → check_<안>.sql → rollback
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
for V in ${1:-user org}; do
{
  echo "begin;"
  echo "drop schema if exists nomad_astro cascade; drop schema if exists nomad_astro_private cascade;"
  for f in "$D/$V"/0*.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  if [ -f "$D/check_$V.sql" ]; then cat "$D/check_$V.sql"; fi
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "astro check_$V: PASS (rolled back)"
done
