#!/usr/bin/env bash
# NOMAD 로컬 키트 설치기: 대상 저장소에 supabase/config.toml(전용 project_id·10단위 포트·Studio)과 docs/runbooks/local-dev.md 를 만든다(DB 접속 없음).
# 사용법: bash scripts/install-local.sh <대상 저장소> --product <slug>... [--site-url URL] [--check] [--force]
#   config: 없으면 생성 · 첫 줄 표식(# nomad-local: managed)이 있으면 재생성 · 표식 없는 기존 파일은 건드리지 않고 supabase/config.nomad.toml 제안본만 쓴다(exit 2). --force 는 .bak 백업 후 덮어쓴다.
#   runbook: 없으면 생성 · 표식이 있으면 재생성 · 표식 없는 기존 파일은 docs/runbooks/local-dev.nomad.md 제안본(exit 2 아님).
#   포트는 local/ports.yaml(첫 --product 기준), [api] schemas 는 모든 --product 의 nomad_<slug>. supabase/nomad.lock 에 `# local <slug> <포트> <해시>` 를 기록한다.
# 종료 코드: 0 정상·최신 / 1 --check 에서 만들거나 갱신할 파일 있음 / 2 표식 없는 기존 config 가 있음 / 64 사용법·대상 오류
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_DIR="$ROOT/local"
# shellcheck source=../local/render.sh
source "$LOCAL_DIR/render.sh"
USAGE="사용법: $0 <대상 저장소> --product <slug>... [--site-url URL] [--check] [--force]"
die() { echo "$1" >&2; exit 64; }

TARGET=""; CHECK=0; FORCE=0; SITE=""; SLUGS=()
while (($#)); do
  case "$1" in
    --check) CHECK=1;;
    --force) FORCE=1;;
    --site-url) [[ $# -ge 2 && "$2" != --* ]] || die "--site-url에 주소가 필요합니다."; SITE="$2"; shift;;
    --product) [[ $# -ge 2 && "$2" != --* ]] || die "--product에 slug가 필요합니다."; SLUGS+=("${2%%:*}"); shift;;
    -*) echo "알 수 없는 옵션: $1" >&2; die "$USAGE";;
    *) [[ -z "$TARGET" ]] || die "대상 저장소는 하나만 지정합니다."; TARGET="$1";;
  esac
  shift
done
[[ -n "$TARGET" ]] || die "$USAGE"
((${#SLUGS[@]})) || die "--product 가 필요합니다(포트 블록 배정용). $USAGE"
[[ -d "$TARGET" ]] || die "대상 폴더가 없습니다: $TARGET"
for s in "${SLUGS[@]}"; do
  [[ "$s" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "$s: 제품 slug 형식이 아닙니다."
  [[ -d "$ROOT/products/$s" ]] || die "$s: products/$s 없음"
done
FIRST="${SLUGS[0]}"
BASE="$(port_of "$FIRST")"
[[ "$BASE" =~ ^[0-9]+$ ]] || die "$FIRST: local/ports.yaml 에 포트 블록이 없습니다."
if [[ -n "$SITE" ]]; then [[ "$SITE" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || die "--site-url 형식이 아닙니다: $SITE"; fi

CFG="$TARGET/supabase/config.toml"
MD="$TARGET/docs/runbooks/local-dev.md"
LOCK="$TARGET/supabase/nomad.lock"
# site_url: 옵션 > 기존 관리 config 의 값 > 기본
if [[ -z "$SITE" && -f "$CFG" ]] && [[ "$(head -n1 "$CFG" | tr -d '\r')" == "$MARK_CFG" ]]; then
  SITE="$(tr -d '\r' < "$CFG" | sed -n 's/^site_url = "\(.*\)"$/\1/p' | head -n1)"
fi
[[ -n "$SITE" ]] || SITE="http://localhost:3000"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render_tmpl "$LOCAL_DIR/config.toml.tmpl" "${SLUGS[*]}" "$SITE" > "$TMP/config.toml"
render_tmpl "$LOCAL_DIR/local-dev.md.tmpl" "${SLUGS[*]}" "$SITE" > "$TMP/local-dev.md"

# 판정: 각 파일의 동작 = new(생성) | same | regen(표식 있음, 내용 다름) | conflict(표식 없는 기존)
judge() { # <대상> <렌더> <표식>
  if [[ ! -e "$1" ]]; then echo new
  elif [[ "$(head -n1 "$1" | tr -d '\r')" != "$3" ]]; then echo conflict
  elif [[ "$(lhash "$1")" == "$(lhash "$2")" ]]; then echo same
  else echo regen; fi
}
C="$(judge "$CFG" "$TMP/config.toml" "$MARK_CFG")"
M="$(judge "$MD" "$TMP/local-dev.md" "$MARK_MD")"
if [[ "$C" == conflict && $FORCE == 1 ]]; then C=force; fi
if [[ "$M" == conflict && $FORCE == 1 ]]; then M=force; fi
sym() { case "$1" in new) echo "+";; same) echo "=";; regen|force) echo "~";; conflict) echo "✗";; esac; }
echo "$(sym "$C") supabase/config.toml ($C)"
echo "$(sym "$M") docs/runbooks/local-dev.md ($M)"

if ((CHECK)); then
  if [[ "$C" == conflict ]]; then
    echo "supabase/config.toml 은 NOMAD 표식이 없는 기존 파일입니다. 쓰기 없음(--check). 제안본은 --check 없이 실행하면 config.nomad.toml 로 씁니다." >&2; exit 2; fi
  [[ "$C" == same && ( "$M" == same || "$M" == conflict ) ]] && { echo "최신 상태입니다."; exit 0; }
  exit 1
fi

RC=0
mkdir -p "$TARGET/supabase/migrations" "$TARGET/docs/runbooks"
put() { # <렌더> <대상> <동작> <제안본 경로>
  case "$3" in
    new|regen) cp "$1" "$2";;
    force) cp "$2" "$2.bak"; cp "$1" "$2";;
    conflict) cp "$1" "$4";;
  esac
}
put "$TMP/config.toml" "$CFG" "$C" "$TARGET/supabase/config.nomad.toml"
put "$TMP/local-dev.md" "$MD" "$M" "$TARGET/docs/runbooks/local-dev.nomad.md"
if [[ "$C" == conflict ]]; then
  echo "! supabase/config.toml 은 표식 없는 기존 파일이라 그대로 뒀습니다. 제안본: supabase/config.nomad.toml (직접 병합하거나 --force 로 덮어쓰기, 원본은 .bak)." >&2; RC=2; fi
[[ "$M" == conflict ]] && echo "! docs/runbooks/local-dev.md 는 기존 파일이라 그대로 뒀습니다. 제안본: docs/runbooks/local-dev.nomad.md"

# 잠금: 기존 `# local` 줄을 지우고 새로 기록(없으면 파일을 만든다). config 가 충돌로 남으면 해시는 제안본 기준이 아니라 기록하지 않는다.
if [[ "$C" != conflict ]]; then
  line="# local $FIRST $BASE $(lhash "$CFG")"
  if [[ -f "$LOCK" ]]; then
    { grep -v '^# local ' "$LOCK" | tr -d '\r' | awk -v l="$line" 'NR==1{print; print l; next} {print}'; } > "$LOCK.tmp"
    [[ -s "$LOCK.tmp" ]] || echo "$line" > "$LOCK.tmp"
  else
    { echo "# nomad-supabase-module install-db.sh 가 씁니다. 손으로 고치지 마세요."; echo "$line"; } > "$LOCK.tmp"
  fi
  mv "$LOCK.tmp" "$LOCK"
fi
echo "✓ 로컬 키트: 프로젝트 $FIRST-dev · Studio http://127.0.0.1:$((BASE+3)) (npx supabase@3.2.0 start)"
exit $RC
