#!/usr/bin/env bash
# 사용: bash products/studynote/run_check.sh [user|org]  (인자 없으면 둘 다)  (로컬 nomad-supabase-module DB, 항상 rollback)
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
for V in ${1:-user org}; do
case "$V" in user|org) ;; *) echo "usage: run_check.sh [user|org]" >&2; exit 2;; esac
{
  echo "begin;"
  echo "drop schema if exists nomad_studynote cascade; drop schema if exists nomad_studynote_private cascade;"
  for f in "$D/$V"/0001_studynote.sql "$D/$V"/0002_ai.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
  cat "$D/check_$V.sql"
  echo "rollback;"
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
echo "studynote check_$V: PASS (rolled back)"
done
