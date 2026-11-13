#!/usr/bin/env bash
# 서비스 DB 청사진 생성기.
# 사용법: bash scripts/new-blueprint.sh <org|user|hybrid|isolated> <slug> "<표시 이름>"
# 결과: blueprints/<유형>/<slug>/{blueprint.yaml,README.md,schema.draft.sql} + blueprints/registry.yaml 항목
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BP="$ROOT/blueprints"
TYPE="${1:-}"; SLUG="${2:-}"; NAME="${3:-}"
if [[ -z "$TYPE" || -z "$SLUG" || -z "$NAME" ]]; then
  echo "사용법: $0 <org|user|hybrid|isolated> <slug> \"<표시 이름>\"" >&2; exit 1; fi
case "$TYPE" in org|user|hybrid|isolated) ;; *) echo "유형은 org|user|hybrid|isolated 중 하나" >&2; exit 1;; esac
[[ "$SLUG" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || { echo "slug는 소문자 kebab-case (예: my-service)" >&2; exit 1; }
DEST="$BP/$TYPE/$SLUG"
for t in org user hybrid isolated; do
  [[ -e "$BP/$t/$SLUG" ]] && { echo "이미 존재: blueprints/$t/$SLUG" >&2; exit 1; }
done
case "$TYPE" in
  org)      DB=supabase-a; TEN=multi-tenant; OWN=organization_id; SENS=false;;
  user)     DB=supabase-a; TEN=single-user;  OWN=user_id;         SENS=false;;
  hybrid)   DB=supabase-a; TEN=hybrid;       OWN=user_id;         SENS=false;;
  isolated) DB=supabase-b; TEN=isolated;     OWN=role;            SENS=true;;
esac
SCHEMA_SLUG="${SLUG//-/_}"
mkdir -p "$DEST"
fill() { sed -e "s/__SCHEMA__/$SCHEMA_SLUG/g" -e "s/__SLUG__/$SLUG/g" -e "s/__NAME__/$NAME/g" -e "s/__TYPE__/$TYPE/g" -e "s/__DB__/$DB/g" \
  -e "s/__TENANCY__/$TEN/g" -e "s/__OWNER__/$OWN/g" -e "s/__SENSITIVE__/$SENS/g" -e "s/__DATE__/$(date +%F)/g" "$1"; }
fill "$BP/_templates/blueprint/blueprint.yaml" > "$DEST/blueprint.yaml"
fill "$BP/_templates/blueprint/README.md"      > "$DEST/README.md"
sed "s/{{slug}}/$SCHEMA_SLUG/g" "$BP/_templates/$TYPE/schema.template.sql" > "$DEST/schema.draft.sql"
cat >> "$BP/registry.yaml" <<REG
  - slug: $SLUG
    name: $NAME
    type: $TYPE
    status: draft
    db: $DB
    path: blueprints/$TYPE/$SLUG
REG
echo "생성 완료: blueprints/$TYPE/$SLUG"
echo "다음: README의 ER 다이어그램과 schema.draft.sql을 수정 후 bash scripts/validate-blueprints.sh"
