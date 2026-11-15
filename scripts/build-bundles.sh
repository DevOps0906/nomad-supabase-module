#!/usr/bin/env bash
# 번들 빌더: core + 제품 SQL을 새 Supabase 프로젝트에 바로 `supabase db push` 할 수 있는 묶음으로 만든다.
# 사용: bash scripts/build-bundles.sh   (저장소 루트 어디서든; 결과 bundles/ 는 git 제외·매번 새로 만든다)
#   bundles/single/<slug>/      제품 1개 · user안(없으면 org안)   — products/ 의 전 제품(hospital 제외)
#   bundles/tenant/<slug>/      제품 1개 · org안                  — 〃
#   bundles/monorepo/           우선 5개 제품 · org안(공유 코어)
#   bundles/isolated/hospital/  격리형 hospital 단독(core 없음 · 별도 프로젝트)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG="$ROOT/supabase/migrations"
OUT="$ROOT/bundles"
# products/*/ 자동 수집(이름순 = 번호 NN · org/ 가 있는 제품만 · 격리형 hospital 제외)
SLUGS=()
for d in "$ROOT"/products/*/; do
  s="$(basename "$d")"
  [[ "$s" == hospital || ! -d "$d/org" ]] && continue
  SLUGS+=("$s")
done
MONO=(contentflow humscore knowflow lottolab shorts)   # 모노레포 = 우선 5개

# 제품 SQL(user·org·app·isolated) 내용
product_sql() { cat "$ROOT/products/$1"/{user,org,app,isolated}/0*.sql 2>/dev/null | tr -d '\r'; }

# 확장 메모: SQL 의 create extension 을 grep(생성) + pg_cron 참조만 있으면 선택
scan_ext() {
  local sql created opt=""
  sql="$(product_sql "$1")"
  created="$(grep -oiE 'create extension if not exists [a-z_0-9]+' <<<"$sql" | awk '{print tolower($6)}' | sort -u | paste -sd' ' - | sed 's/ / · /g')" || true
  if [[ " $created " != *" pg_cron "* ]] && grep -qiE 'pg_cron|cron\.schedule' <<<"$sql"; then
    opt="pg_cron 선택(있으면 스케줄 등록 · 없으면 SQL 주석의 스케줄을 워커가 호출)"
  fi
  if [[ -n "$created" ]]; then
    echo "$created (마이그레이션이 생성 — 대시보드 Database > Extensions 에서 사용 가능한 플랜인지 확인)${opt:+; $opt}"
  else
    echo "${opt:-없음}"
  fi
}

# 워커(service_role 로 큐를 처리하는 별도 프로세스)가 있는 제품: core 작업 큐(jobs)를 쓰거나 전용 워커 롤이 있는 제품,
# 그리고 자체 큐 표를 외부 워커가 소비하는 제품(humscore·knowflow)
scan_worker() {
  case "$1" in humscore|knowflow) return 0;; esac
  grep -qE 'nomad_core\.(enqueue_job|claim_job|jobs)|worker_role' <<<"$(product_sql "$1")"
}

# 제품 SQL 은 크므로 한 번만 훑어 둔다
declare -A EXT WORKER
for s in "${SLUGS[@]}" hospital; do
  EXT[$s]="$(scan_ext "$s")"
  if scan_worker "$s"; then WORKER[$s]=1; else WORKER[$s]=0; fi
done
ext_note() { echo "${EXT[$1]}"; }
has_worker() { [[ "${WORKER[$1]}" == 1 ]]; }

idx_of() { local i=1 s; for s in "${SLUGS[@]}"; do [[ "$s" == "$1" ]] && { printf '%02d' "$i"; return; }; i=$((i+1)); done; }

# add_product <대상 migrations 폴더> <slug> <안: user|org>
add_product() {
  local dst="$1" slug="$2" mode="$3" nn m=0 f d
  nn="$(idx_of "$slug")"
  for d in "$mode" app; do
    [[ -d "$ROOT/products/$slug/$d" ]] || continue
    for f in "$ROOT/products/$slug/$d"/0*.sql; do
      [[ -f "$f" ]] || continue
      m=$((m+1))
      cp "$f" "$dst/2026120100${nn}$(printf '%02d' "$m")_${slug}_$(basename "$f")"   # 14자리(core와 같은 형식, core 뒤)
    done
  done
}

add_core() {
  local dst="$1" f
  for f in "$MIG"/*_nomad_core.sql "$MIG"/*_nomad_core_*.sql; do
    [[ -f "$f" ]] && cp "$f" "$dst/"
  done
}

# write_meta <번들 폴더> <제목> <slug들...>
write_meta() {
  local b="$1" title="$2"; shift 2
  local schemas="" s exts="" workers=""
  for s in "$@"; do
    schemas+="\"nomad_$s\", "; exts+="- $s: $(ext_note "$s")"$'\n'
    if has_worker "$s"; then workers+="$s "; fi
  done
  cat > "$b/supabase/config.snippet.toml" <<TOML
# supabase init 으로 만든 supabase/config.toml 에 병합할 부분 · 호스티드는 supabase config push(또는 대시보드)로 반영한다.
# nomad_core · *_private 스키마는 API에 노출하지 않는다.
[api]
schemas = ["public", "graphql_public", ${schemas%, }]

[auth.external.google]
enabled = true
client_id = "env(GOOGLE_CLIENT_ID)"
secret = "env(GOOGLE_CLIENT_SECRET)"

[auth.external.kakao]
enabled = true
client_id = "env(KAKAO_CLIENT_ID)"
secret = "env(KAKAO_CLIENT_SECRET)"

# 필요한 확장
$(for s in "$@"; do echo "# - $s: $(ext_note "$s")"; done)
TOML
  {
    echo "# $title"
    echo
    if [[ "${WITH_CORE:-1}" == 1 ]]; then
      echo "NOMAD 공통 코어(계정 확장 포함) + 제품 DB 묶음. 생성물이다 — 고치지 말고 \`bash scripts/build-bundles.sh\`로 다시 만든다."
    else
      echo "격리형 제품 DB 단독 묶음(NOMAD 공통 코어 없음 · 다른 제품과 프로젝트를 공유하지 않는다). 생성물이다 — 고치지 말고 \`bash scripts/build-bundles.sh\`로 다시 만든다."
    fi
    echo
    echo "## 적용"
    echo "1. 새 Supabase 프로젝트를 만든다(운영 프로젝트와 분리)."
    echo "2. 이 폴더에서 \`supabase init\`(supabase/config.toml 생성) → \`supabase/config.snippet.toml\` 내용을 config.toml 의 같은 절에 병합한다."
    echo "3. \`supabase link --project-ref <ref>\` → \`supabase db push\`."
    echo "4. 병합한 [api] schemas 와 Auth 제공자(google·kakao)를 \`supabase config push\`(또는 대시보드 API·Auth 설정)로 호스티드 프로젝트에 반영한다."
    echo "5. 필요한 확장(아래)을 확인한다."
    echo
    echo "## 확장"
    printf '%s' "$exts"
    if [[ -n "$workers" ]]; then
      echo
      echo "## 워커 DB 역할 (${workers% })"
      echo "워커 역할은 클러스터 롤이라 마이그레이션 밖에서 만든다(비밀번호는 저장소에 넣지 않는다):"
      echo '```sql'
      echo "create role <제품>_worker login password '<비밀번호>' nosuperuser nobypassrls;"
      echo "grant service_role to <제품>_worker;   -- 워커는 SET ROLE service_role 로 nomad_<제품>.* 호출"
      echo '```'
      if [[ " $* " == *" shorts "* ]]; then echo "shorts 는 마이그레이션이 worker_role·worker_login(비밀번호 없음)을 만든다 — \`alter role worker_login password '...'\`만 별도로 설정한다."; fi
    fi
    echo
    echo "## 앱 변경"
    for s in "$@"; do echo "- $s: 저장소 \`products/$s/existing.md\`"; done
  } > "$b/README.md"
}

rm -rf "$OUT"
for slug in "${SLUGS[@]}"; do
  [[ -d "$ROOT/products/$slug" ]] || { echo "products/$slug 없음" >&2; exit 1; }
  # single: user안 우선, 없으면 org안
  mode=org; [[ -d "$ROOT/products/$slug/user" ]] && mode=user
  b="$OUT/single/$slug"; mkdir -p "$b/supabase/migrations"
  add_core "$b/supabase/migrations"; add_product "$b/supabase/migrations" "$slug" "$mode"
  write_meta "$b" "$slug — 단일(${mode}안)" "$slug"
  # tenant: org안
  b="$OUT/tenant/$slug"; mkdir -p "$b/supabase/migrations"
  add_core "$b/supabase/migrations"; add_product "$b/supabase/migrations" "$slug" org
  write_meta "$b" "$slug — 테넌트(org안)" "$slug"
done
b="$OUT/monorepo"; mkdir -p "$b/supabase/migrations"
add_core "$b/supabase/migrations"
for slug in "${MONO[@]}"; do add_product "$b/supabase/migrations" "$slug" org; done
write_meta "$b" "모노레포 — 제품 ${#MONO[@]}개(org안)" "${MONO[@]}"
# 격리형 hospital: core 없이 isolated/ 만
b="$OUT/isolated/hospital"; mkdir -p "$b/supabase/migrations"
m=0
for f in "$ROOT/products/hospital/isolated"/0*.sql; do
  m=$((m+1)); cp "$f" "$b/supabase/migrations/202612010000$(printf '%02d' "$m")_hospital_$(basename "$f")"
done
WITH_CORE=0 write_meta "$b" "hospital — 격리형(isolated)" hospital
echo "번들 $(( ${#SLUGS[@]} * 2 + 2 ))개 생성(single·tenant ${#SLUGS[@]}개씩 · monorepo · isolated/hospital): $OUT"
