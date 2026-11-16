#!/usr/bin/env bash
# 옛 제품 청사진 정리기(2026-11-16 결정 7): 대상 DB에 적용돼 있는 supabase/migrations 의 옛 청사진(*_<slug>.sql)을 지운다.
# install-db.sh 는 DB 접속 없는 복사기로 남고, DB를 지우는 일은 이 스크립트만 한다.
# 사용: bash scripts/cleanup-legacy-blueprints.sh <대상 DB 주소> [--dry-run]
#   --dry-run   지울 대상·행 수를 보이고, 삭제 SQL을 트랜잭션 안에서 실행한 뒤 되돌린다(확인 질문 없음, 변경 없음).
#   psql 대신 다른 실행기를 쓰려면 PSQL 환경 변수(예: PSQL="docker exec -i <컨테이너> psql -U postgres").
# 지우는 것(모두 한 트랜잭션):
#   1) 스키마 — 이름이 청사진과 정확히 같고, 그 안의 표 목록이 청사진의 표 목록과 정확히 같을 때만 drop schema … cascade.
#      표가 하나라도 다르면(같은 이름의 products/ 이식본일 수 있음) 건드리지 않는다.
#   2) 1)을 지운 제품의 옛 기능 행 — 청사진이 시드한 nomad_core.features 중 products/<slug>/ 이식본 SQL이 이름으로 쓰지 않는 것과
#      그 plan_features. 단품(addon_products·feature_grants)이 참조하는 기능은 남긴다. plans·products·구독은 건드리지 않는다.
# 확인: 실행 전에 docs/BACKUP_RESTORE.md 대로 백업하고, 대화형 터미널에서 확인 문구를 직접 입력해야 한다(비대화 환경은 거부).
# 종료 코드: 0 정상(지울 것 없음 포함) / 1 실행 실패 / 3 비대화 환경·확인 거절 / 64 사용법 오류
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG="$ROOT/supabase/migrations"
USAGE="사용법: $0 <대상 DB 주소> [--dry-run]"

URL=""; DRY=0
while (($#)); do
  case "$1" in
    --dry-run) DRY=1;;
    -*) echo "알 수 없는 옵션: $1" >&2; echo "$USAGE" >&2; exit 64;;
    *) [[ -z "$URL" ]] || { echo "DB 주소는 하나만 지정합니다." >&2; echo "$USAGE" >&2; exit 64; }
       URL="$1";;
  esac
  shift
done
[[ -n "$URL" ]] || { echo "$USAGE" >&2; exit 64; }
read -r -a PSQL_CMD <<<"${PSQL:-psql}"
q() { "${PSQL_CMD[@]}" "$URL" -X -v ON_ERROR_STOP=1 -At -c "$1" | tr -d '\r'; }

cat <<'MSG'
== 옛 청사진 정리 ==
실행 전에 docs/BACKUP_RESTORE.md "보관 대상"·"복구 연습" 절차대로 대상 DB 백업(복구 시각·체크섬 기록)을 먼저 만드세요.
지운 스키마·기능 행은 백업 복구 말고는 되돌릴 수 없습니다.
MSG

# 옛 청사진 slug: supabase/migrations/<14자리>_<slug>.sql 중 core·실습 예시 제외
mapfile -t SLUGS < <(ls "$MIG" | sed -nE 's/^[0-9]{14}_([a-z0-9_]+)\.sql$/\1/p' | grep -vE '^(nomad_core.*|contentflow_example)$' | sort -u)

legacy_files() { ls "$MIG" | grep -E "^[0-9]{14}_$1\.sql$" | sed "s|^|$MIG/|"; }
legacy_schema() { cat $(legacy_files "$1") | tr -d '\r' | sed -nE 's/^create schema (if not exists )?([a-z0-9_]+);.*/\2/p' | head -n1; }
legacy_tables() { cat $(legacy_files "$1") | tr -d '\r' | sed -nE "s/^create table (if not exists )?$2\.([a-z0-9_]+).*/\2/p" | sort -u | paste -sd, -; }
legacy_features() { # 청사진이 시드한 기능 코드
  cat $(legacy_files "$1") | tr -d '\r' | awk -v s="$1" '
    /^insert into nomad_core\.features/ { f=1 }
    f { while (match($0, "\\(\x27" s "\x27, \x27[a-z0-9_]+\x27")) { c=substr($0, RSTART, RLENGTH); sub(/.*, \x27/, "", c); sub(/\x27$/, "", c); print c; $0=substr($0, RSTART+RLENGTH) } }
    f && /;/ { f=0 }' | sort -u
}
port_uses() { # 이식본 SQL이 기능 이름을 쓰는가
  local d="$ROOT/products/$1"
  [[ -d "$d" ]] && grep -rqs --include='*.sql' "'$2'" "$d"
}

SQL=""; SUMMARY=""; N=0
for s in "${SLUGS[@]}"; do
  sch="$(legacy_schema "$s")"; [[ -n "$sch" ]] || continue
  want="$(legacy_tables "$s" "$sch")"
  exists="$(q "select count(*) from pg_namespace where nspname = '$sch'")"
  [[ "$exists" == 1 ]] || continue
  got="$(q "select coalesce(string_agg(tablename, ',' order by tablename), '') from pg_tables where schemaname = '$sch'")"
  if [[ "$got" != "$want" ]]; then
    echo "- $sch: 표 목록이 청사진과 달라 건너뜀(이식본일 수 있음). 청사진[$want] 대상[$got]"
    continue
  fi
  N=$((N+1))
  rows="$(q "select coalesce(string_agg(t || ' ' || n, ' · ' order by t), '') from ($(
      IFS=,; sep=""; for t in $want; do printf "%sselect '%s' t, (select count(*) from %s.%s) n" "$sep" "$t" "$sch" "$t"; sep=" union all "; done
    )) x")"
  SUMMARY+="- 스키마 $sch 삭제 — 표 행 수: ${rows:-표 없음}"$'\n'
  SQL+="do \$g\$ begin
  if (select coalesce(string_agg(tablename, ',' order by tablename), '') from pg_tables where schemaname = '$sch') <> '$want' then
    raise exception '$sch 표 목록이 바뀌었다 — 중단';
  end if;
end \$g\$;
drop schema $sch cascade;
"
  codes=()
  while read -r c; do [[ -n "$c" ]] && ! port_uses "$s" "$c" && codes+=("'$c'"); done < <(legacy_features "$s")
  if ((${#codes[@]})); then
    list="$(IFS=,; echo "${codes[*]}")"
    cond="product_code = '$s' and feature_code in ($list) and not exists (select 1 from nomad_core.addon_products a where a.product_code = '$s' and a.feature_code = x.feature_code) and not exists (select 1 from nomad_core.feature_grants g where g.product_code = '$s' and g.feature_code = x.feature_code)"
    nf="$(q "select (select count(*) from nomad_core.features x where x.product_code = '$s' and x.code in ($list) and not exists (select 1 from nomad_core.addon_products a where a.product_code = '$s' and a.feature_code = x.code) and not exists (select 1 from nomad_core.feature_grants g where g.product_code = '$s' and g.feature_code = x.code)) || ' ' || (select count(*) from nomad_core.plan_features x where $cond)")"
    SUMMARY+="  옛 기능 행($s: ${list//\'/}) — features ${nf% *}행 · plan_features ${nf#* }행"$'\n'
    SQL+="delete from nomad_core.plan_features x where $cond;
delete from nomad_core.features x where x.product_code = '$s' and x.code in ($list)
  and not exists (select 1 from nomad_core.plan_features p where p.product_code = '$s' and p.feature_code = x.code)
  and not exists (select 1 from nomad_core.addon_products a where a.product_code = '$s' and a.feature_code = x.code)
  and not exists (select 1 from nomad_core.feature_grants g where g.product_code = '$s' and g.feature_code = x.code);
"
  fi
done

if ((N == 0)); then echo "지울 옛 청사진이 없습니다."; exit 0; fi
echo "지울 대상:"; printf '%s' "$SUMMARY"

if ((DRY)); then
  printf 'set client_min_messages = warning;\nbegin;\n%srollback;\n' "$SQL" | "${PSQL_CMD[@]}" "$URL" -X -v ON_ERROR_STOP=1 -q >/dev/null || { echo "dry-run 실패"; exit 1; }
  echo "dry-run: 삭제 SQL을 트랜잭션 안에서 실행하고 되돌렸습니다(변경 없음)."
  exit 0
fi

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "비대화 환경이라 거부합니다. 터미널에서 직접 실행해 확인 문구를 입력하세요(미리 보기는 --dry-run)." >&2
  exit 3
fi
WORD="cleanup $N"
read -r -p "백업을 확인했고 위 대상을 지우려면 '$WORD' 를 입력하세요: " ans
[[ "$ans" == "$WORD" ]] || { echo "확인 문구가 달라 중단합니다(변경 없음)." >&2; exit 3; }

printf 'set client_min_messages = warning;\nbegin;\n%scommit;\n' "$SQL" | "${PSQL_CMD[@]}" "$URL" -X -v ON_ERROR_STOP=1 -q >/dev/null || { echo "정리 실패(트랜잭션 롤백, 변경 없음)"; exit 1; }
echo "✓ 옛 청사진 ${N}개 정리 완료. 대상 저장소 supabase/migrations 의 옛 청사진 파일도 지우세요(install-db.sh --check 가 알려 준다)."
