#!/usr/bin/env bash
# 번들 빌더: core + 제품 SQL을 새 Supabase 프로젝트에 바로 `supabase db push` 할 수 있는 묶음으로 만든다.
# 사용: bash scripts/build-bundles.sh   (저장소 루트 어디서든; 결과 bundles/ 는 git 제외·매번 새로 만든다)
#   bundles/single/<slug>/    제품 1개 · user안(없으면 org안)
#   bundles/tenant/<slug>/    제품 1개 · org안
#   bundles/monorepo/         제품 5개 · org안(공유 코어)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG="$ROOT/supabase/migrations"
OUT="$ROOT/bundles"
SLUGS=(contentflow humscore knowflow lottolab shorts)   # 순서 고정 = 번호 NN(01~05)

# 제품별 메모(확장·로그인)
ext_note() {
  case "$1" in
    knowflow) echo "pg_trgm (마이그레이션이 extensions 스키마에 자동 생성)";;
    shorts)   echo "pgmq · pg_cron · pg_net (마이그레이션이 생성 — 대시보드 Database > Extensions 에서 사용 가능한 플랜인지 확인)";;
    lottolab) echo "pg_cron (있으면 스케줄 등록, 없으면 건너뜀)";;
    *)        echo "없음";;
  esac
}

# 워커(별도 DB 역할)가 있는 제품
has_worker() { case "$1" in knowflow|shorts|humscore) return 0;; *) return 1;; esac; }

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
    echo "NOMAD 공통 코어(계정 확장 포함) + 제품 DB 묶음. 생성물이다 — 고치지 말고 \`bash scripts/build-bundles.sh\`로 다시 만든다."
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
for slug in "${SLUGS[@]}"; do add_product "$b/supabase/migrations" "$slug" org; done
write_meta "$b" "모노레포 — 제품 5개(org안)" "${SLUGS[@]}"
echo "번들 11개 생성: $OUT"
