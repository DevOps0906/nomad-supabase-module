#!/usr/bin/env bash
# NOMAD DB 설치기: 이 저장소의 확정 마이그레이션을 다른 Supabase 저장소로 복사한다(DB 접속 없음).
# 사용법: bash scripts/install-db.sh <대상 저장소> [--product <slug>]... [--with-accounts] [--with-example] [--check]
# 종료 코드: 0 정상·최신 / 1 --check에서 복사할 새 파일 있음 / 2 대상 파일이 원본과 다름 / 64 사용법·대상 오류
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/supabase/migrations"
USAGE="사용법: $0 <대상 저장소> [--product <slug>]... [--with-accounts] [--with-example] [--check]"

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
UNIQ=()
if ((${#PRODUCTS[@]})); then
  while IFS= read -r p; do UNIQ+=("$p"); done < <(printf '%s\n' "${PRODUCTS[@]}" | sort -u)
fi

# 설치할 파일 고르기(이름 순)
SEL=()
for f in "$SRC"/*_nomad_core.sql "$SRC"/*_nomad_core_*.sql; do
  [[ -f "$f" ]] || continue
  [[ "$f" == *_nomad_core_accounts.sql ]] && continue
  SEL+=("$(basename "$f")")
done
if ((ACCOUNTS)); then for f in "$SRC"/*_nomad_core_accounts.sql; do [[ -f "$f" ]] && SEL+=("$(basename "$f")"); done; fi
if ((EXAMPLE)); then for f in "$SRC"/*_contentflow_example.sql; do [[ -f "$f" ]] && SEL+=("$(basename "$f")"); done; fi
for p in ${UNIQ[@]+"${UNIQ[@]}"}; do
  key="${p//-/_}"; found=0
  for f in "$SRC"/*_"$key".sql; do [[ -f "$f" ]] && { SEL+=("$(basename "$f")"); found=1; }; done
  ((found)) || { echo "$p: 확정 마이그레이션 없음 (blueprints/ 초안은 설치 대상 아님)" >&2; exit 64; }
done
SORTED=()
while IFS= read -r n; do SORTED+=("$n"); done < <(printf '%s\n' "${SEL[@]}" | sort -u)

hash() { tr -d '\r' < "$1" | sha256sum | cut -d' ' -f1; }

# 판정(쓰기 전에 전부 검사)
NEW=(); SAME=(); BAD=()
for n in "${SORTED[@]}"; do
  if [[ ! -e "$DST/$n" ]]; then NEW+=("$n"); echo "+ $n"
  elif [[ "$(hash "$SRC/$n")" == "$(hash "$DST/$n")" ]]; then SAME+=("$n"); echo "= $n"
  else BAD+=("$n"); echo "✗ $n"; fi
done
if ((${#BAD[@]})); then
  echo "대상 파일이 원본과 다릅니다(적용된 마이그레이션은 수정하지 않습니다). 아무 파일도 쓰지 않았습니다." >&2; exit 2; fi

# 경고(복사는 막지 않음)
is_src() { [[ -e "$SRC/$1" ]]; }
if ((ACCOUNTS)); then
  echo "! accounts: 가입 트리거(on auth.users)가 새로 생깁니다. 이미 가입한 사용자는 프로필·조직이 자동으로 만들어지지 않으니 백필 마이그레이션을 따로 만드세요."
  echo "! accounts: 백필 전에는 기존 사용자의 업체 소속이 비어 있어 RLS로 데이터가 보이지 않을 수 있습니다."
fi
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
for n in ${NEW[@]+"${NEW[@]}"}; do STAGED+=("$DST/.$n.tmp"); cp "$SRC/$n" "$DST/.$n.tmp"; done
sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
flags=""
((ACCOUNTS)) && flags+=" --with-accounts"
((EXAMPLE)) && flags+=" --with-example"
for p in ${UNIQ[@]+"${UNIQ[@]}"}; do flags+=" --product $p"; done
{
  echo "# nomad-supabase-module install-db.sh 가 씁니다. 손으로 고치지 마세요."
  echo "# source $sha"
  echo "# flags${flags}"
  for n in "${SORTED[@]}"; do echo "$n  $(hash "$SRC/$n")"; done
} > "$LOCK.tmp"
STAGED+=("$LOCK.tmp")
for n in ${NEW[@]+"${NEW[@]}"}; do mv "$DST/.$n.tmp" "$DST/$n"; done
mv "$LOCK.tmp" "$LOCK"
echo "✓ ${#NEW[@]}개 복사 · supabase/nomad.lock 기록"
echo "다음: 대상에서 npx supabase db reset --local 로 순서대로 적용을 확인하세요."
