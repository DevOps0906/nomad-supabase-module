#!/usr/bin/env bash
# scripts/install-local.sh · install-db.sh 로컬 키트 연동 계약 테스트. 임시 폴더만 사용하고 종료 시 지운다(Docker 불필요).
# 실행: bash tests/install_local.sh (저장소 루트)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="$ROOT/scripts/install-local.sh"; DB="$ROOT/scripts/install-db.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; OUT=""; RC=0
ok() { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
rl() { OUT="$(bash "$LOCAL" "$@" 2>&1)"; RC=$?; }
rd() { OUT="$(bash "$DB" "$@" 2>&1)"; RC=$?; }
rc_is() { if [ "$RC" -eq "$2" ]; then ok "$1 (exit $2)"; else bad "$1 (exit $RC, 기대 $2)"; echo "      $(printf '%s' "$OUT" | head -3 | tr '\n' '|')"; fi; }
SRC_BEFORE="$(cd "$ROOT" && find supabase scripts local -type f | sort | xargs sha256sum | sha256sum)"

# 1. 등록부: 형식·중복 없음·products 전부 등록·고정값
P="$ROOT/local/ports.yaml"
body() { tr -d '\r' < "$P" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'; }
check "ports.yaml 줄 형식 slug: base" bash -c "! tr -d '\r' < '$P' | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*\$' | grep -vE '^[a-z0-9][a-z0-9_-]*: [0-9]+\$'"
check "slug 중복 없음" test -z "$(body | cut -d: -f1 | sort | uniq -d)"
check "포트 블록 겹침 없음(10 간격 이상)" bash -c "body() { tr -d '\r' < '$P' | grep -vE '^[[:space:]]*(#|\$)' | awk -F': ' '{print \$2}' | sort -n; }; body | awk 'NR>1 && \$1-prev<10 {bad=1} {prev=\$1} END{exit bad}'"
check "module 58120 · knowflow 56520 고정" bash -c "grep -qx 'module: 58120' '$P' && grep -qx 'knowflow: 56520' '$P'"
miss=""; for d in "$ROOT"/products/*/; do s="$(basename "$d")"; [ "$s" = docs ] && continue; grep -q "^$s: " "$P" || miss="$miss $s"; done
check "products 전 제품 등록(누락:${miss:- 없음})" test -z "$miss"

# 2. 빈 대상 생성
T="$TMP/t1"; mkdir -p "$T"
rl "$T" --product knowflow; rc_is "빈 대상 생성" 0
check "config.toml 생성" test -f "$T/supabase/config.toml"
check "표식 첫 줄" grep -qx '# nomad-local: managed' "$T/supabase/config.toml"
check "project_id knowflow-dev" grep -qx 'project_id = "knowflow-dev"' "$T/supabase/config.toml"
check "Studio 포트 56523" grep -qx 'port = 56523' "$T/supabase/config.toml"
check "api schemas nomad_knowflow" grep -q 'schemas = \[.*"nomad_knowflow"' "$T/supabase/config.toml"
check "runbook 생성" test -f "$T/docs/runbooks/local-dev.md"
check "migrations 폴더 생성" test -d "$T/supabase/migrations"
check "lock # local 줄" grep -qE '^# local knowflow 56520 [0-9a-f]{64}$' "$T/supabase/nomad.lock"
check "비밀 값 없음" bash -c "! grep -riE 'service_role_key *=|eyJ' '$T/supabase/config.toml' '$T/docs/runbooks/local-dev.md'"

# 3. 멱등·--check
cp "$T/supabase/config.toml" "$TMP/c1"; cp "$T/supabase/nomad.lock" "$TMP/l1"
rl "$T" --product knowflow; rc_is "재실행" 0
check "재실행 config 동일" cmp -s "$TMP/c1" "$T/supabase/config.toml"
check "재실행 lock 동일" cmp -s "$TMP/l1" "$T/supabase/nomad.lock"
rl "$T" --product knowflow --check; rc_is "--check 최신" 0
rl "$T" --product knowflow --site-url https://dev.example.com:3000
check "--site-url 반영" grep -qx 'site_url = "https://dev.example.com:3000"' "$T/supabase/config.toml"
rl "$T" --product knowflow
check "site_url 재실행 유지" grep -qx 'site_url = "https://dev.example.com:3000"' "$T/supabase/config.toml"
rm "$T/docs/runbooks/local-dev.md"
rl "$T" --product knowflow --check; rc_is "runbook 없으면 --check 1" 1
rl "$T" --product 'x;y'; rc_is "잘못된 slug" 64
rl "$T" --product knowflow --site-url 'http://a"b'; rc_is "잘못된 site-url" 64
rl "$T"; rc_is "--product 누락" 64
rl "$T" --product nope-zzz; rc_is "없는 제품" 64

# 4. 표식 없는 기존 config 보존
U="$TMP/t2"; mkdir -p "$U/supabase" "$U/docs/runbooks"
printf 'project_id = "mine"\r\n[api]\r\nport = 1\r\n' > "$U/supabase/config.toml"; echo "내 runbook" > "$U/docs/runbooks/local-dev.md"
cp "$U/supabase/config.toml" "$TMP/mine"
rl "$U" --product knowflow --check; rc_is "기존 config --check" 2
check "--check는 쓰기 없음" test ! -e "$U/supabase/config.nomad.toml"
rl "$U" --product knowflow; rc_is "기존 config 보존" 2
check "원본 config 그대로" cmp -s "$TMP/mine" "$U/supabase/config.toml"
check "제안본 config.nomad.toml" test -f "$U/supabase/config.nomad.toml"
check "기존 runbook 그대로" grep -qx '내 runbook' "$U/docs/runbooks/local-dev.md"
check "runbook 제안본" test -f "$U/docs/runbooks/local-dev.nomad.md"
check "충돌 시 lock에 # local 미기록" bash -c "! grep -q '^# local' '$U/supabase/nomad.lock' 2>/dev/null"
rl "$U" --product knowflow --force; rc_is "--force 덮어쓰기" 0
check "--force 원본 .bak" cmp -s "$TMP/mine" "$U/supabase/config.toml.bak"
check "--force 후 표식" grep -qx '# nomad-local: managed' "$U/supabase/config.toml"

# 5. install-db 연동
D="$TMP/t3"; mkdir -p "$D"
rd "$D" --product knowflow:user; rc_is "install-db 빈 대상(init 없이)" 0
check "migrations 복사됨" test -n "$(ls "$D"/supabase/migrations/*_knowflow_*.sql 2>/dev/null)"
check "config.toml 함께 생성" grep -qx '# nomad-local: managed' "$D/supabase/config.toml"
check "lock에 flags와 # local 공존" bash -c "grep -q '^# flags' '$D/supabase/nomad.lock' && grep -q '^# local knowflow ' '$D/supabase/nomad.lock'"
rd "$D" --product knowflow:user; rc_is "install-db 재실행" 0
check "재실행 후 # local 유지" grep -q '^# local knowflow ' "$D/supabase/nomad.lock"
rd "$D" --product knowflow:user --check; rc_is "install-db --check" 0
check "--check 안내 한 줄" bash -c "printf '%s' \"\$0\" | grep -q 'install-local.sh'" "$OUT"
N="$TMP/t4"; mkdir -p "$N"
rd "$N" --product knowflow:user --no-local; rc_is "--no-local" 0
check "--no-local config 없음" test ! -e "$N/supabase/config.toml"
M="$TMP/t5"; mkdir -p "$M"
rd "$M"; rc_is "제품 없이 migrations 없음" 64
E="$TMP/t6"; mkdir -p "$E/supabase"; echo 'project_id = "mine"' > "$E/supabase/config.toml"
rd "$E" --product knowflow:user; rc_is "install-db 기존 config 충돌" 2
check "충돌에도 migrations 복사" test -n "$(ls "$E"/supabase/migrations/*_knowflow_*.sql 2>/dev/null)"


# 5b. 기준 제품: 정렬 순서가 아니라 사용자가 준 첫 --product, 이미 있으면 lock 의 기준 유지
O="$TMP/t7"; mkdir -p "$O"
rd "$O" --product shorts --product analytics; rc_is "첫 --product 기준 설치" 0
check "shorts 블록(56740)" grep -qE '^# local shorts 56740 ' "$O/supabase/nomad.lock"
check "project_id shorts-dev" grep -qx 'project_id = "shorts-dev"' "$O/supabase/config.toml"
check "schemas 에 두 제품" grep -q '"nomad_shorts".*"nomad_analytics"' "$O/supabase/config.toml"
rd "$O" --product analytics; rc_is "다른 제품 추가 재실행" 0
check "기준 제품 유지(shorts)" grep -qx 'project_id = "shorts-dev"' "$O/supabase/config.toml"

# 5c. Worker 역할: SQL 의 실제 역할명, 역할 없는 제품은 안내 절 생략
check "shorts runbook: worker_login" grep -q 'alter role worker_login password' "$O/docs/runbooks/local-dev.md"
check "shorts runbook: <slug>_worker 아님" bash -c "! grep -q shorts_worker '$O/docs/runbooks/local-dev.md'"
check "knowflow runbook: knowflow_worker" grep -q 'alter role knowflow_worker password' "$D/docs/runbooks/local-dev.md"
Q="$TMP/t8"; mkdir -p "$Q"; rl "$Q" --product analytics
check "역할 없는 제품: Worker 절 생략" bash -c "! grep -qi 'worker' '$Q/docs/runbooks/local-dev.md'"
check "역할 없는 제품: 스키마 절 유지" grep -q '^## 3. 스키마' "$Q/docs/runbooks/local-dev.md"
check ".gitattributes *.sh eol=lf" grep -qx '\*\.sh text eol=lf' "$ROOT/.gitattributes"
# 6. 원본 불변
SRC_AFTER="$(cd "$ROOT" && find supabase scripts local -type f | sort | xargs sha256sum | sha256sum)"
check "원본(supabase·scripts·local) 변경 없음" test "$SRC_BEFORE" = "$SRC_AFTER"
echo "결과: PASS $PASS / FAIL $FAIL"; [ "$FAIL" -eq 0 ]
