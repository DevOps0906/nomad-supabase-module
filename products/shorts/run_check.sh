#!/usr/bin/env bash
# 사용: bash products/shorts/run_check.sh [user|org]  (로컬 nomad-supabase-module DB, 항상 rollback)
# 인자를 빼면 있는 안을 모두 검사한다. check 파일의 "-- @@APPLY@@" 줄 자리에 <안>/0*.sql 본문(begin/commit 제외)을 끼운다.
# check 파일이 begin 과 청사진(같은 스키마 이름) drop 을 먼저 하고, 끝에서 rollback 한다(실패 시 연결 종료 = rollback).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; P="shorts"
VS="${1:-}"; [ -n "$VS" ] || VS="$(for v in user org; do [ -d "$D/$v" ] && echo "$v"; done)"
for V in $VS; do
  C="$D/check_$V.sql"; [ -f "$C" ] || C="$D/$V/check_$V.sql"
  [ -f "$C" ] || { echo "$P check_$V: 검사 파일 없음" >&2; exit 1; }
  grep -q '^-- @@APPLY' "$C" || { echo "$P check_$V: APPLY 표식 없음" >&2; exit 1; }
  grep -q '^rollback;' "$C" || { echo "$P check_$V: rollback 없음" >&2; exit 1; }
  {
    sed '/^-- @@APPLY/,$d' "$C"
    for f in "$D/$V"/0*.sql; do sed '/^begin;$/d;/^commit;$/d' "$f"; done
    sed -n '/^-- @@APPLY/,$p' "$C"
  } | docker exec -i -e PGOPTIONS=-cclient_min_messages=warning supabase_db_nomad-supabase-module psql -U postgres -v ON_ERROR_STOP=1 -q > /dev/null
  echo "$P check_$V: PASS (rolled back)"
done
