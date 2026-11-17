#!/usr/bin/env bash
# 사용: bash products/knowflow/run_check.sh [user|org|upgrade-user|upgrade-org ...]  (인자 없으면 user org upgrade-user upgrade-org)
# (로컬 DB 컨테이너 supabase_db_nomad-supabase-module 필요)
# user|org: begin → 준비(check_prelude.sql) → 이식 SQL 전부(begin·commit 줄 제거) → check_<안>.sql(끝에 rollback) 을 한 트랜잭션으로 실행한다.
# upgrade-<안>: begin → 준비 → 0001~0004 → check_upgrade_<안>.sql 앞부분(기존 데이터) → 0005 이후 → 뒷부분(백필 확인, rollback).
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
strip() { sed '/^begin;$/d;/^commit;$/d' "$1"; }
for mode in ${@:-user org upgrade-user upgrade-org}; do
  v="${mode#upgrade-}"
  case "$v" in user|org) ;; *) echo "알 수 없는 인자: $mode" >&2; exit 2;; esac
{
  echo 'begin;'
  cat "$dir/check_prelude.sql"
  if [ "$mode" = "$v" ]; then
    for f in "$dir/$v"/0*.sql; do strip "$f"; done
    cat "$dir/check_$v.sql"
  else
    for f in "$dir/$v"/000[1-4]_*.sql; do strip "$f"; done
    sed '/^-- @@apply-0005@@$/,$d' "$dir/check_upgrade_$v.sql"
    for f in "$dir/$v"/0*.sql; do case "$(basename "$f")" in 000[1-4]_*) ;; *) strip "$f";; esac; done
    sed -n '/^-- @@apply-0005@@$/,$p' "$dir/check_upgrade_$v.sql"
  fi
} | docker exec -i supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q
done
