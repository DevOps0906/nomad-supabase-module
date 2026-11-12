#!/usr/bin/env bash
# 사용법: ./scripts/new-project.sh <org|user|isolated|local> <slug> "<표시 이름>"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TYPE="${1:-}"; SLUG="${2:-}"; NAME="${3:-}"
if [[ -z "$TYPE" || -z "$SLUG" || -z "$NAME" ]]; then
  echo "사용법: $0 <org|user|isolated|local> <slug> \"<표시 이름>\"" >&2; exit 1; fi
case "$TYPE" in org|user|isolated|local) ;; *) echo "유형은 org|user|isolated|local 중 하나" >&2; exit 1;; esac
[[ "$SLUG" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || { echo "slug는 소문자 kebab-case (예: my-service)" >&2; exit 1; }
DEST="$ROOT/projects/$TYPE/$SLUG"
for t in org user isolated local; do
  [[ -e "$ROOT/projects/$t/$SLUG" ]] && { echo "이미 존재: projects/$t/$SLUG" >&2; exit 1; }
done
case "$TYPE" in
  org)      DB=supabase-a; TEN=multi-tenant; OWN=org_id;  SENS=false; TPL=org-service;;
  user)     DB=supabase-a; TEN=single-user;  OWN=user_id; SENS=false; TPL=user-service;;
  isolated) DB=supabase-b; TEN=isolated;     OWN=role;    SENS=true;  TPL=isolated-project;;
  local)    DB=none;       TEN=none;         OWN=-;       SENS=false; TPL=local-only;;
esac
SCHEMA_SLUG="${SLUG//-/_}"
mkdir -p "$DEST"
fill() { sed -e "s/__SCHEMA__/$SCHEMA_SLUG/g" -e "s/__SLUG__/$SLUG/g" -e "s/__NAME__/$NAME/g" -e "s/__TYPE__/$TYPE/g" -e "s/__DB__/$DB/g" \
  -e "s/__TENANCY__/$TEN/g" -e "s/__OWNER__/$OWN/g" -e "s/__SENSITIVE__/$SENS/g" -e "s/__DATE__/$(date +%F)/g" "$1"; }
fill "$ROOT/projects/_template/project.yaml" > "$DEST/project.yaml"
fill "$ROOT/projects/_template/README.md"    > "$DEST/README.md"
if [[ "$TYPE" != local ]]; then
  sed "s/{{slug}}/$SCHEMA_SLUG/g" "$ROOT/templates/$TPL/schema.template.sql" > "$DEST/schema.draft.sql"
else
  sed -i '/^## ER 다이어그램/,/^## 접근 규칙/{/^## 접근 규칙/!d}' "$DEST/README.md"
  sed -i "s/^schema: .*/schema: -/" "$DEST/project.yaml"
fi
cat >> "$ROOT/registry/projects.yaml" <<REG
  - slug: $SLUG
    name: $NAME
    type: $TYPE
    account: DevOps0906
    status: draft
    db: $DB
    path: projects/$TYPE/$SLUG
REG
echo "생성 완료: projects/$TYPE/$SLUG"
echo "다음: README의 ER 다이어그램과 schema.draft.sql을 수정 후 ./scripts/validate.sh"
