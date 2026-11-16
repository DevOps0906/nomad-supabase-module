#!/usr/bin/env bash
# 번들 검증: 각 번들을 빈 로컬 Supabase에 적용(supabase start가 migrations를 적용)하고 제품 check_*.sql을 돌린다.
# 사용: bash tests/bundles.sh [--all | 번들이름...]   (이름: single/<slug> · tenant/<slug> · monorepo · isolated/hospital)
#   인자 없음 = 대표 표본(SAMPLE) · --all = bundles/ 전부(single·tenant 전 제품 + monorepo + isolated/hospital)
# 이 저장소 스택(581xx)과 분리: 임시 폴더 + project_id nsm-bundle-* + 포트 5920x(5432x → 5920x). 로그: .nomad/logs/bundles-*.log
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONO=(contentflow humscore knowflow lottolab shorts)   # build-bundles.sh 의 모노레포 5개와 같게
# 표본: 모노레포 + 새 제품 single 3개(core pg_trgm 마이그레이션에 기대는 news · user안 · 청사진과 같은 스키마 이름) + 격리형
# pg_trgm 은 core *_nomad_core_pg_trgm.sql 이 만들고 knowflow·news 이식본은 extensions 스키마에 있는지만 검사한다(2026-11-16 결정 5)
SAMPLE=(monorepo single/news single/astro single/baedal isolated/hospital)
LOGDIR="$ROOT/.nomad/logs"; mkdir -p "$LOGDIR"
BASE_TMP="$(mktemp -d)"
SX="studio,imgproxy,mailpit,realtime,edge-runtime,logflare,vector,supavisor,postgres-meta,postgrest,kong"

# project_id 기준으로 멈춘다(run_bundle 은 $(…) 서브셸에서 돌아 부모 셸 변수로는 현재 번들을 알 수 없다).
stop_id() { npx supabase stop --no-backup --project-id "$1"; }
bundle_id() { echo "nsm-bundle-$(echo "$1" | tr '/' '-')"; }
cleanup() {
  local n
  for n in "${NAMES[@]}"; do stop_id "$(bundle_id "$n")" >/dev/null 2>&1 || true; done
  rm -rf "$BASE_TMP"
}
NAMES=("$@")
trap cleanup EXIT

bash "$ROOT/scripts/build-bundles.sh" >/dev/null || { echo "build 실패"; exit 1; }

if ((${#NAMES[@]}==0)); then
  NAMES=("${SAMPLE[@]}")
elif [[ "${NAMES[0]}" == --all ]]; then
  NAMES=()
  for d in "$ROOT"/bundles/single/*/; do NAMES+=("single/$(basename "$d")"); done
  for d in "$ROOT"/bundles/tenant/*/; do NAMES+=("tenant/$(basename "$d")"); done
  NAMES+=(monorepo)
  for d in "$ROOT"/bundles/isolated/*/; do NAMES+=("isolated/$(basename "$d")"); done
fi

# 검사 SQL 준비: 청사진 스키마 drop · 임시 touch_updated_at 정의를 빼고(core에 있음) 제품별 틀을 맞춘다.
filter() {
  awk '
    skip { if ($0 ~ /\$[a-z]*\$;/) skip=0; next }
    /^create or replace function nomad_core\.touch_updated_at\(\)/ { if ($0 ~ /\$[a-z]*\$;/) next; skip=1; next }
    /^drop schema if exists nomad_[a-z_]+ cascade;/ { next }
    { print }' "$1" | tr -d '\r'
}
check_file() { # <slug> <안>
  local s="$1" m="$2" d="$ROOT/products/$1"
  if [[ -f "$d/check_$m.sql" ]]; then echo "$d/check_$m.sql"; else echo "$d/$m/check_$m.sql"; fi
}
emit_check() { # <slug> <안>
  local s="$1" m="$2" f; f="$(check_file "$s" "$m")"
  [[ -f "$f" ]] || { echo "check 없음: $f" >&2; return 1; }
  case "$s" in
    knowflow) echo 'begin;'; filter "$ROOT/products/knowflow/check_prelude.sql"; filter "$f";;
    lottolab) echo 'begin;'  # 단일 트랜잭션 검사라 core의 now() 대신 clock_timestamp() 판(검사 안에서만, rollback)
              echo 'create or replace function nomad_core.touch_updated_at() returns trigger language plpgsql set search_path = '"''"' as $fn$ begin new.updated_at := clock_timestamp(); return new; end; $fn$;'
              filter "$f"; echo 'rollback;';;
    *)        # 자체 begin/rollback 이 없는 검사는 트랜잭션으로 감싼다(run_check.sh 와 같은 조건)
              grep -q '^begin;' "$f" || echo 'begin;'
              filter "$f"
              grep -qE '^rollback;' "$f" || echo 'rollback;';;
  esac
}

run_bundle() { # <이름> <포트오프셋>
  local name="$1" dir="$ROOT/bundles/$1" id log tmp n_files dbc rc=0
  id="$(bundle_id "$name")"; dbc="supabase_db_$id"
  log="$LOGDIR/bundles-$(echo "$name" | tr '/' '-').log"; : > "$log"
  tmp="$BASE_TMP/$(echo "$name" | tr '/' '-')"; mkdir -p "$tmp"
  # 서브셸 + `||` 는 set -e 를 무력화하므로 단계마다 결과를 직접 검사한다.
  fail() { echo "$1 실패(로그 $log)"; stop_id "$id" >>"$log" 2>&1; }
  stop_id "$id" >>"$log" 2>&1 || true   # 이전 실행에서 남은 같은 project_id 인스턴스 정리
  cd "$tmp" || { fail "임시 폴더 이동"; return 1; }
  npx supabase init --force </dev/null >>"$log" 2>&1 || { fail "init"; return 1; }
  { rm -rf supabase/migrations && mkdir -p supabase/migrations; } 2>>"$log" || { fail "migrations 폴더"; return 1; }
  cp "$dir"/supabase/migrations/*.sql supabase/migrations/ 2>>"$log" || { fail "마이그레이션 복사"; return 1; }
  sed -i -E "s/^project_id = .*/project_id = \"$id\"/; s/^(port|shadow_port) = 5432([0-9])/\1 = 5920\2/" supabase/config.toml 2>>"$log" || { fail "config 수정"; return 1; }
  grep -q "^project_id = \"$id\"" supabase/config.toml || { fail "project_id 확인"; return 1; }
  npx supabase start -x "$SX" >>"$log" 2>&1 || { fail "start/적용"; return 1; }
  cd "$ROOT" || { fail "루트 복귀"; return 1; }

  n_files=$(ls "$dir"/supabase/migrations/*.sql | wc -l)
  got=$(docker exec "$dbc" psql -U postgres -Atc "select count(*) from supabase_migrations.schema_migrations" 2>>"$log")
  [[ "$got" == "$n_files" ]] || { echo "마이그레이션 $got/$n_files"; rc=1; }

  local jobs=()
  case "$name" in
    monorepo) for s in "${MONO[@]}"; do jobs+=("$s:org"); done;;
    isolated/*) jobs+=("${name#isolated/}:isolated");;
    single/*) s="${name#single/}"; m=org; [[ -d "$ROOT/products/$s/user" ]] && m=user; jobs+=("$s:$m");;
    tenant/*) jobs+=("${name#tenant/}:org");;
  esac
  local j s m
  for j in "${jobs[@]}"; do
    s="${j%%:*}"; m="${j##*:}"
    echo "--- check $s $m" >>"$log"
    if ! emit_check "$s" "$m" | docker exec -i "$dbc" psql -U postgres -v ON_ERROR_STOP=1 -q >>"$log" 2>&1; then
      echo "check $s/$m 실패"; rc=1
    fi
  done
  if [[ "$name" == monorepo ]]; then
    cnt=$(docker exec "$dbc" psql -U postgres -Atc "select count(*) from pg_namespace where nspname in ('nomad_contentflow','nomad_humscore','nomad_knowflow','nomad_lottolab','nomad_shorts')" 2>>"$log")
    [[ "$cnt" == 5 ]] || { echo "스키마 $cnt/5"; rc=1; }
  fi
  stop_id "$id" >>"$log" 2>&1 || { echo "stop 실패(로그 $log)"; rc=1; }
  rm -rf "$tmp"
  return $rc
}

PASS=0; FAIL=0; ROWS=()
for n in "${NAMES[@]}"; do
  msg="$(run_bundle "$n")"; rc=$?
  if ((rc==0)); then PASS=$((PASS+1)); ROWS+=("PASS  $n"); else FAIL=$((FAIL+1)); ROWS+=("FAIL  $n  ${msg//$'\n'/ | }"); fi
  echo "${ROWS[-1]}"
done
echo "=== 결과 ==="; printf '%s\n' "${ROWS[@]}"
echo "$PASS/$((PASS+FAIL)) 통과"
((FAIL==0))
