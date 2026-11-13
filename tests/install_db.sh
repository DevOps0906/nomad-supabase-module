#!/usr/bin/env bash
# scripts/install-db.sh 계약 테스트. 임시 폴더만 사용하고 종료 시 지운다.
# 실행: bash tests/install_db.sh (저장소 루트)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/install-db.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
OUT=""; RC=0

ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
check() { # check <설명> <조건 명령...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
run() { OUT="$(bash "$INSTALL" "$@" 2>&1)"; RC=$?; }
expect_rc() { if [ "$RC" -eq "$2" ]; then ok "$1 (exit $2)"; else bad "$1 (exit $RC, 기대 $2)"; echo "      $(printf '%s' "$OUT" | head -3 | tr '\n' '|')"; fi; }
has()  { printf '%s' "$OUT" | grep -q -- "$1"; }
mk_target() { mkdir -p "$TMP/$1/supabase/migrations"; echo "$TMP/$1"; }
lockfiles() { grep -v '^#' "$1/supabase/nomad.lock" | awk 'NF{print $1}'; }

if [ ! -f "$INSTALL" ]; then
  echo "FAIL  scripts/install-db.sh 없음"; echo "결과: PASS 0 / FAIL 1"; exit 1
fi

# 원본 변경 감지용 지문
src_sum() { (cd "$ROOT" && find supabase scripts -type f | sort | xargs sha256sum | sha256sum); }
SRC_BEFORE="$(src_sum)"

# 1. 첫 설치
T="$(mk_target t1)"
run "$T"
expect_rc "첫 설치" 0
M="$T/supabase/migrations"
check "core 복사됨" test -n "$(ls "$M"/*_nomad_core.sql 2>/dev/null)"
check "accounts 없음" test -z "$(ls "$M"/*_nomad_core_accounts.sql 2>/dev/null)"
check "example 없음" test -z "$(ls "$M"/*_contentflow_example.sql 2>/dev/null)"
check "lock 생성" test -f "$T/supabase/nomad.lock"
check "lock에 core 기록" grep -q '_nomad_core.sql' "$T/supabase/nomad.lock"
check "lock에 # flags 줄" grep -q '^# flags' "$T/supabase/nomad.lock"
check "완료 문구 ✓" has '✓'

# 2. 재실행: 바뀐 것 없음
cp "$T/supabase/nomad.lock" "$TMP/lock1"
run "$T"
expect_rc "재실행" 0
check "재실행 후 파일 수 동일" test "$(ls "$M" | wc -l)" -eq 2
check "재실행 '= ' 표시" has '^= '

# 3. --check 최신
run "$T" --check
expect_rc "--check 최신" 0

# 4. 새 파일 흉내: 대상 lock에서 한 줄 지우고 파일 삭제 → --check 1
F="$(ls "$M"/*_nomad_core.sql | head -1)"; FN="$(basename "$F")"
cp "$T/supabase/nomad.lock" "$TMP/lock_bak"
grep -v "$FN" "$TMP/lock_bak" > "$T/supabase/nomad.lock"
rm -f "$F"
run "$T" --check
expect_rc "--check 새 파일 있음" 1
check "--check는 파일을 쓰지 않음" test ! -e "$F"
# 실제 실행하면 복원
run "$T"
expect_rc "복원 설치" 0
check "복원됨" test -f "$F"

# 5. 사본 수정 → exit 2, 파일 미변경
echo "-- local edit" >> "$F"
H_BEFORE="$(sha256sum "$F" | cut -d' ' -f1)"
run "$T" --with-accounts
expect_rc "수정된 사본" 2
check "어긋남 ✗ 표시" has '✗'
check "'아무 파일도 쓰지 않았습니다.' 출력" has '아무 파일도 쓰지 않았습니다.'
check "수정 파일 미변경" test "$(sha256sum "$F" | cut -d' ' -f1)" = "$H_BEFORE"
check "전부 아니면 전무: accounts 미복사" test -z "$(ls "$M"/*_nomad_core_accounts.sql 2>/dev/null)"
run "$T" --check
expect_rc "--check 어긋남" 2

# 6. CRLF 사본은 어긋남 아님
T2="$(mk_target t2)"; M2="$T2/supabase/migrations"
run "$T2"; expect_rc "CRLF 준비 설치" 0
F2="$(ls "$M2"/*_nomad_core.sql | head -1)"
sed -i 's/$/\r/' "$F2"
check "CRLF로 변환됨" test "$(od -An -c "$F2" | grep -c '\r')" -gt 0
run "$T2" --check
expect_rc "CRLF 사본 --check" 0
run "$T2"
expect_rc "CRLF 사본 재설치" 0

# 7. --with-accounts 기록 유지
T3="$(mk_target t3)"; M3="$T3/supabase/migrations"
run "$T3" --with-accounts
expect_rc "--with-accounts 설치" 0
check "accounts 복사됨" test -n "$(ls "$M3"/*_nomad_core_accounts.sql 2>/dev/null)"
check "flags에 --with-accounts" grep -q '^# flags.*--with-accounts' "$T3/supabase/nomad.lock"
check "accounts 안내 경고 !" has '^!'
rm -f "$M3"/*_nomad_core_accounts.sql
run "$T3"
expect_rc "플래그 없이 재실행" 0
check "accounts 계속 추적(재복사)" test -n "$(ls "$M3"/*_nomad_core_accounts.sql 2>/dev/null)"
check "flags 유지" grep -q '^# flags.*--with-accounts' "$T3/supabase/nomad.lock"

# 8. --product
T4="$(mk_target t4)"; M4="$T4/supabase/migrations"
run "$T4" --product contentflow
expect_rc "--product contentflow" 0
check "contentflow 복사됨" test -n "$(ls "$M4"/*_contentflow.sql 2>/dev/null)"
check "flags에 --product contentflow" grep -q '^# flags.*--product contentflow' "$T4/supabase/nomad.lock"
rm -f "$M4"/*_contentflow.sql
run "$T4"
check "제품 기록 재실행 때 유지" test -n "$(ls "$M4"/*_contentflow.sql 2>/dev/null)"
T5="$(mk_target t5)"
run "$T5" --product hospital
expect_rc "--product hospital (확정 없음)" 64
check "hospital 안내 문구" has '확정 마이그레이션 없음'
check "hospital 실패 시 lock 없음" test ! -e "$T5/supabase/nomad.lock"

# 8b. 부분 설치: --product humscore → humscore 2개 + core(기본 플랜 포함), 다른 제품 없음
T9="$(mk_target t9)"; M9="$T9/supabase/migrations"
run "$T9" --product humscore
expect_rc "--product humscore 부분 설치" 0
check "humscore 파일 2개(청사진+기능 잠금)" test "$(ls "$M9"/*_humscore.sql 2>/dev/null | wc -l)" -eq 2
check "core 복사됨" test -n "$(ls "$M9"/*_nomad_core.sql 2>/dev/null)"
check "core 기본 플랜 파일 복사됨" test -n "$(ls "$M9"/*_nomad_core_default_plan.sql 2>/dev/null)"
check "다른 제품 파일 없음" test -z "$(ls "$M9" | grep -E '_(contentflow|flora|knowflow|classroom|analytics|sceneflow|commerce|jangter|baedal|personal)\.sql$')"
check "총 4개 파일(core 2 + humscore 2)" test "$(ls "$M9" | wc -l)" -eq 4

# 9. --with-example
T6="$(mk_target t6)"
run "$T6" --with-example
expect_rc "--with-example" 0
check "example 복사됨" test -n "$(ls "$T6"/supabase/migrations/*_contentflow_example.sql 2>/dev/null)"

# 10. 오류 입력
mkdir -p "$TMP/noinit"
run "$TMP/noinit"
expect_rc "init 없는 대상" 64
check "supabase init 안내" has 'supabase init'
run "$T" --bogus
expect_rc "알 수 없는 옵션" 64
run
expect_rc "대상 인자 누락" 64
run "$T" --product
expect_rc "--product 값 누락" 64

# 11. auth.users 트리거 경고 + 순서 경고
T7="$(mk_target t7)"
cat > "$T7/supabase/migrations/29990101000000_app_signup.sql" <<'SQL'
create trigger on_signup after insert on auth.users
  for each row execute function public.handle_new_user();
SQL
run "$T7" --with-accounts
expect_rc "트리거 경고는 복사를 막지 않음" 0
check "auth.users 트리거 경고(파일명 포함)" has '29990101000000_app_signup.sql'
check "경고는 ! 로 시작" has '^!.*auth.users\|auth.users.*'
check "순서 경고 + include-all 안내" has 'include-all'
T8="$(mk_target t8)"
echo "select 1;" > "$T8/supabase/migrations/20200101000000_app.sql"
run "$T8"
expect_rc "이른 타임스탬프 아닌 경우" 0
check "순서 경고 없음(대상이 더 오래됨)" bash -c "! printf '%s' \"\$0\" | grep -q include-all" "$OUT"
check "auth.users 경고 없음(accounts 미선택)" bash -c "! printf '%s' \"\$0\" | grep -q 'auth.users'" "$OUT"

# 12. 원본 불변
check "원본 저장소 미변경" test "$(src_sum)" = "$SRC_BEFORE"

echo "NOTE  설치 대상의 로컬 DB begin…rollback 적용 항목은 이미 적용된 스키마와 충돌하므로 건너뜀"
echo "결과: PASS $PASS / FAIL $FAIL"
[ "$FAIL" -eq 0 ]
