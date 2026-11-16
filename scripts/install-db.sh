#!/usr/bin/env bash
# NOMAD DB 설치기: 공통 코어(supabase/migrations)와 제품 이식본(products/<slug>/)을 다른 Supabase 저장소로 복사한다(DB 접속 없음).
# 사용법: bash scripts/install-db.sh <대상 저장소> [--product <slug>[:user|org]]... [--with-accounts] [--with-example] [--check]
#   accounts(가입 트리거·개인 조직)는 core 설치에 항상 포함된다(--with-accounts 는 호환용, 생략해도 같다).
#   제품 파일은 scripts/build-bundles.sh 의 add_product 와 같은 규칙으로 고르고 이름을 붙인다(번들과 같은 파일 목록).
#   기본 안: user/ 가 있으면 user, 없으면 org. 격리형(isolated/, 예: hospital)은 core 없이 단독으로만 설치한다.
#   supabase/migrations 의 옛 제품 청사진(*_<slug>.sql)은 설치하지 않는다(--with-example 의 contentflow_example 만 예외).
# 종료 코드: 0 정상·최신 / 1 --check에서 복사할 새 파일 있음 / 2 대상 파일이 원본과 다름 / 64 사용법·대상 오류
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/supabase/migrations"
USAGE="사용법: $0 <대상 저장소> [--product <slug>[:user|org]]... [--with-accounts] [--with-example] [--check]"

TARGET=""; CHECK=0; ACCOUNTS=0; EXAMPLE=0; PRODUCTS=()
while (($#)); do
  case "$1" in
    --check) CHECK=1;;
    --with-accounts) ACCOUNTS=1;;
    --with-example) EXAMPLE=1;;
    --product)
      [[ $# -ge 2 && "$2" != --* ]] || { echo "--product에 slug가 필요합니다." >&2; echo "$USAGE" >&2; exit 64; }
      PRODUCTS+=("$2"); shift;;
    -*) echo "알 수 없는 옵션: $1" >&2; echo "$USAGE" >&2; exit 64;;
    *) [[ -z "$TARGET" ]] || { echo "대상 저장소는 하나만 지정합니다." >&2; echo "$USAGE" >&2; exit 64; }
       TARGET="$1";;
  esac
  shift
done
[[ -n "$TARGET" ]] || { echo "$USAGE" >&2; exit 64; }
DST="$TARGET/supabase/migrations"
if [[ ! -d "$DST" ]]; then
  echo "대상에 supabase/migrations/가 없습니다. 먼저 대상에서 npx supabase init 을 실행하세요." >&2; exit 64; fi
LOCK="$TARGET/supabase/nomad.lock"

# 잠금 파일에 기록된 옵션을 이번 옵션과 합친다.
if [[ -f "$LOCK" ]]; then
  prev="$(grep '^# flags' "$LOCK" | head -n1 | sed 's/^# flags *//' | tr -d '\r' || true)"
  set -- $prev
  while (($#)); do
    case "$1" in
      --with-accounts) ACCOUNTS=1;;
      --with-example) EXAMPLE=1;;
      --product) [[ $# -ge 2 ]] && { PRODUCTS+=("$2"); shift; };;
    esac
    shift
  done
fi
die() { echo "$1" >&2; exit 64; }

# 제품 지정 정규화: slug[:안] → slug:안 (안 = user | org | isolated)
NORM=()
for p in ${PRODUCTS[@]+"${PRODUCTS[@]}"}; do
  slug="${p%%:*}"; mode=""; [[ "$p" == *:* ]] && mode="${p#*:}"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "$p: 제품 slug 형식이 아닙니다."
  d="$ROOT/products/$slug"
  [[ -d "$d" ]] || die "$slug: products/$slug 없음 (blueprints/ 초안·supabase/migrations 옛 청사진은 설치 대상 아님)"
  if [[ -d "$d/isolated" ]]; then
    [[ -z "$mode" || "$mode" == isolated ]] || die "$slug: 격리형 제품이라 :$mode 안을 고를 수 없습니다."
    mode=isolated
  else
    case "$mode" in
      "") mode=org; [[ -d "$d/user" ]] && mode=user;;
      user|org) [[ -d "$d/$mode" ]] || die "$slug: products/$slug/$mode 없음";;
      *) die "$p: 안은 user 또는 org 입니다.";;
    esac
    [[ -d "$d/$mode" ]] || die "$slug: products/$slug 에 user/·org/·isolated/ 가 없습니다."
  fi
  NORM+=("$slug:$mode")
done
UNIQ=()
if ((${#NORM[@]})); then
  while IFS= read -r p; do UNIQ+=("$p"); done < <(printf '%s
' "${NORM[@]}" | sort -u)
fi
# 같은 제품을 두 안으로 설치하지 않는다
dup="$(for p in ${UNIQ[@]+"${UNIQ[@]}"}; do echo "${p%%:*}"; done | sort | uniq -d | head -n1)"
[[ -z "$dup" ]] || die "$dup: user안과 org안을 함께 설치할 수 없습니다(대상에 이미 기록된 안: supabase/nomad.lock)."
ISOLATED=0
for p in ${UNIQ[@]+"${UNIQ[@]}"}; do [[ "$p" == *:isolated ]] && ISOLATED=1; done
if ((ISOLATED)); then
  ((${#UNIQ[@]} == 1 && !ACCOUNTS && !EXAMPLE)) || die "격리형 제품(${UNIQ[*]})은 다른 제품·--with-accounts·--with-example 과 함께 설치할 수 없습니다(core 없이 단독)."
  for f in "$DST"/*_nomad_core.sql "$DST"/*_nomad_core_*.sql; do
    [[ -e "$f" ]] && die "격리형 제품은 공통 코어가 이미 있는 대상($(basename "$f"))에 설치할 수 없습니다. 별도 프로젝트에 설치하세요."
  done
else
  # core credits·jobs·ai·voice 가 accounts 의 credit_ledger 를 쓰므로 core 설치에는 accounts 가 항상 포함된다(--with-accounts 는 호환용).
  ACCOUNTS=1
fi

# 제품 번호 NN: build-bundles.sh 와 같은 규칙(products/*/ 이름순 · org/ 가 있는 제품만 · 격리형 제외)
SLUGS=()
for d in "$ROOT"/products/*/; do
  s="$(basename "$d")"
  [[ -d "$d/isolated" || ! -d "$d/org" ]] && continue
  SLUGS+=("$s")
done
idx_of() { local i=1 s; for s in "${SLUGS[@]}"; do [[ "$s" == "$1" ]] && { printf '%02d' "$i"; return; }; i=$((i+1)); done; }

# 설치할 파일 고르기: FROM[대상 파일명] = 원본 경로
declare -A FROM
SEL=()
pick() { FROM[$1]="$2"; SEL+=("$1"); }
if ((!ISOLATED)); then
  for f in "$SRC"/*_nomad_core.sql "$SRC"/*_nomad_core_*.sql; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *_nomad_core_accounts.sql ]] && continue
    pick "$(basename "$f")" "$f"
  done
fi
if ((ACCOUNTS)); then for f in "$SRC"/*_nomad_core_accounts.sql; do [[ -f "$f" ]] && pick "$(basename "$f")" "$f"; done; fi
if ((EXAMPLE)); then for f in "$SRC"/*_contentflow_example.sql; do [[ -f "$f" ]] && pick "$(basename "$f")" "$f"; done; fi
for p in ${UNIQ[@]+"${UNIQ[@]}"}; do
  slug="${p%%:*}"; mode="${p#*:}"; m=0
  if [[ "$mode" == isolated ]]; then
    for f in "$ROOT/products/$slug/isolated"/0*.sql; do
      [[ -f "$f" ]] || continue
      m=$((m+1)); pick "202612010000$(printf '%02d' "$m")_${slug}_$(basename "$f")" "$f"
    done
  else
    nn="$(idx_of "$slug")"
    for d in "$mode" app; do
      [[ -d "$ROOT/products/$slug/$d" ]] || continue
      for f in "$ROOT/products/$slug/$d"/0*.sql; do
        [[ -f "$f" ]] || continue
        m=$((m+1)); pick "2026120100${nn}$(printf '%02d' "$m")_${slug}_$(basename "$f")" "$f"
      done
    done
  fi
  ((m)) || die "$slug: products/$slug/$mode 에 SQL 파일이 없습니다."
done
SORTED=()
while IFS= read -r n; do SORTED+=("$n"); done < <(printf '%s
' "${SEL[@]}" | sort -u)

hash() { tr -d '\r' < "$1" | sha256sum | cut -d' ' -f1; }

# 판정(쓰기 전에 전부 검사)
NEW=(); SAME=(); BAD=()
for n in "${SORTED[@]}"; do
  if [[ ! -e "$DST/$n" ]]; then NEW+=("$n"); echo "+ $n"
  elif [[ "$(hash "${FROM[$n]}")" == "$(hash "$DST/$n")" ]]; then SAME+=("$n"); echo "= $n"
  else BAD+=("$n"); echo "✗ $n"; fi
done
if ((${#BAD[@]})); then
  echo "대상 파일이 원본과 다릅니다(적용된 마이그레이션은 수정하지 않습니다). 아무 파일도 쓰지 않았습니다." >&2; exit 2; fi

# 경고(복사는 막지 않음)
is_src() { [[ -n "${FROM[$1]+x}" || -e "$SRC/$1" ]]; }
if ((ACCOUNTS)); then
  echo "! accounts: 가입 트리거(on auth.users)가 새로 생깁니다. 이미 가입한 사용자는 프로필·조직이 자동으로 만들어지지 않으니 백필 마이그레이션을 따로 만드세요."
  echo "! accounts: 백필 전에는 기존 사용자의 업체 소속이 비어 있어 RLS로 데이터가 보이지 않을 수 있습니다."
fi
for p in ${UNIQ[@]+"${UNIQ[@]}"}; do
  key="${p%%:*}"; key="${key//-/_}"
  for f in "$DST"/*_"$key".sql; do
    [[ -e "$f" && -e "$SRC/$(basename "$f")" ]] || continue
    echo "! $(basename "$f"): 옛 청사진(supabase/migrations) 설치본입니다. products/ 이식본과 겹치니 대상에서 정리하세요(DB에 적용됐으면 백업 후 scripts/cleanup-legacy-blueprints.sh <DB 주소>)."
  done
done
LATEST=""
for f in "$DST"/*.sql; do
  [[ -f "$f" ]] || continue
  b="$(basename "$f")"; is_src "$b" && continue
  [[ "$b" > "$LATEST" ]] && LATEST="$b"
  if ((ACCOUNTS)) && grep -qi 'on auth\.users' "$f"; then
    echo "! $b: auth.users 트리거가 이미 있습니다. accounts의 가입 트리거와 겹치는지 확인하세요."; fi
done
if ((${#NEW[@]})) && [[ -n "$LATEST" ]]; then
  for n in "${NEW[@]}"; do
    if [[ "${n:0:14}" < "${LATEST:0:14}" ]]; then
      echo "! $n: 대상의 최신 마이그레이션($LATEST)보다 이전 번호입니다. 이미 적용된 DB에는 npx supabase db push --include-all 로 적용하세요."; fi
  done
fi

if ((CHECK)); then
  ((${#NEW[@]})) && exit 1
  echo "최신 상태입니다."; exit 0
fi

# 복사 + 잠금 기록: 임시 파일에 모두 쓴 뒤 mv로 반영한다. 쓰는 중 실패하면 임시 파일만 지우고 대상은 그대로 둔다.
STAGED=()
cleanup() { for t in ${STAGED[@]+"${STAGED[@]}"}; do rm -f "$t"; done; }
trap cleanup EXIT
for n in ${NEW[@]+"${NEW[@]}"}; do STAGED+=("$DST/.$n.tmp"); cp "${FROM[$n]}" "$DST/.$n.tmp"; done
sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
flags=""
((ACCOUNTS)) && flags+=" --with-accounts"
((EXAMPLE)) && flags+=" --with-example"
for p in ${UNIQ[@]+"${UNIQ[@]}"}; do flags+=" --product $p"; done
{
  echo "# nomad-supabase-module install-db.sh 가 씁니다. 손으로 고치지 마세요."
  echo "# source $sha"
  echo "# flags${flags}"
  for n in "${SORTED[@]}"; do echo "$n  $(hash "${FROM[$n]}")"; done
} > "$LOCK.tmp"
STAGED+=("$LOCK.tmp")
for n in ${NEW[@]+"${NEW[@]}"}; do mv "$DST/.$n.tmp" "$DST/$n"; done
mv "$LOCK.tmp" "$LOCK"
echo "✓ ${#NEW[@]}개 복사 · supabase/nomad.lock 기록"
echo "다음: 대상에서 npx supabase db reset --local 로 순서대로 적용을 확인하세요."
