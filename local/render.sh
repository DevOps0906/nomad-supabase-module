#!/usr/bin/env bash
# 로컬 키트 공용 함수(source 해서 쓴다): 포트 등록부 조회 · 템플릿 렌더 · 해시. 상위 스크립트가 LOCAL_DIR(= local/ 경로)을 정한다.
LOCAL_DIR="${LOCAL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
MARK_CFG='# nomad-local: managed'
MARK_MD='<!-- nomad-local: managed -->'

# ports.yaml 에서 slug 의 시작 포트(없으면 빈 값). 줄 형식 `slug: base`, # 주석·CR 허용.
port_of() { tr -d '\r' < "$LOCAL_DIR/ports.yaml" | awk -F: -v s="$1" '/^[[:space:]]*#/ {next} $1==s {gsub(/[[:space:]]/,"",$2); print $2; exit}'; }

lhash() { tr -d '\r' < "$1" | sha256sum | cut -d' ' -f1; }

# render <템플릿> <slug들(첫 제품 기준)> <site_url> : 표준출력으로 렌더 결과
render_tmpl() {
  local tmpl="$1" site="$3" slug first base schemas="" s role
  read -r -a slugs <<<"$2"; first="${slugs[0]}"; base="$(port_of "$first")"
  for s in "${slugs[@]}"; do schemas+=", \"nomad_${s//-/_}\""; done
  role=""; for s in "${slugs[@]}"; do role="$(role_of "$s")"; [[ -n "$role" ]] && break; done
  sed -e "s|@@SLUG@@|$first|g" \
      -e "s|@@PROJECT_ID@@|$first-dev|g" \
      -e "s|@@SCHEMA@@|${first//-/_}|g" \
      -e "s|@@ROLE@@|$role|g" \
      -e "s|@@SHADOW@@|$base|g" -e "s|@@API@@|$((base+1))|g" -e "s|@@DB@@|$((base+2))|g" \
      -e "s|@@STUDIO@@|$((base+3))|g" -e "s|@@MAIL@@|$((base+4))|g" -e "s|@@POOLER@@|$((base+9))|g" \
      -e "s|@@SCHEMAS@@|\"public\", \"graphql_public\"$schemas|g" \
      -e "s|@@SITE_URL@@|$site|g" \
      <(tr -d '\r' < "$tmpl" | awk -v has="$role" '/^@@IF_ROLE@@$/{skip=(has==""); next} /^@@END_ROLE@@$/{skip=0; next} !skip')
}

# 제품 SQL 에 있는 Worker 로그인 역할명(없으면 빈 값). SQL 의 `create role <이름> ... login` 을 우선하고,
# 없으면 build-bundles.sh 의 워커 판정(humscore·knowflow 또는 큐 사용)을 따르는 제품만 `<slug>_worker`(마이그레이션 밖에서 만드는 관례).
role_of() {
  local s="$1" sql r
  sql="$(cat "$LOCAL_DIR/../products/$s"/{user,org,app,isolated}/0*.sql 2>/dev/null | tr -d '\r')" || true
  r="$(grep -iE 'create role [a-z_0-9]+[^;]* login' <<<"$sql" | grep -viE 'nologin' | head -n1 | sed -E 's/.*[Cc][Rr][Ee][Aa][Tt][Ee] [Rr][Oo][Ll][Ee] ([a-z_0-9]+).*/\1/' || true)"
  if [[ -z "$r" ]]; then
    case "$s" in humscore|knowflow) r="${s//-/_}_worker";; *)
      grep -qE 'nomad_core\.(enqueue_job|claim_job|jobs)|worker_role' <<<"$sql" && r="${s//-/_}_worker";; esac
  fi
  echo "$r"
}
