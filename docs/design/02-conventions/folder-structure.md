# 폴더 구조 규칙 (확장 규칙)

서비스 청사진이 계속 쌓이므로 **위치만 보고 유형을 알 수 있게** 한다.

```
supabase/migrations/           정본 마이그레이션 (nomad_core + 확정된 서비스)
tests/                         합성 데이터 접근 테스트
docs/design/                   설계 기획 (00-overview · 01-architecture · 02-conventions)
docs/diagrams/*.mmd            Mermaid 구조도
blueprints/
├─ README.md                   청사진 안내
├─ registry.yaml               전체 청사진 목록 (new-blueprint.sh가 항목 추가)
├─ _templates/
│  ├─ blueprint/               README.md · blueprint.yaml 뼈대 (직접 수정 금지)
│  └─ org/ · user/ · isolated/ 유형별 schema.template.sql
├─ org/<slug>/                 조직형
├─ user/<slug>/                개인형
└─ isolated/<slug>/            격리형
scripts/new-blueprint.sh       청사진 생성기
scripts/validate-blueprints.sh 청사진 규칙 검증기
```

## 청사진 폴더 내부 (고정)
```
<slug>/
├─ blueprint.yaml              메타데이터 (유형, 스키마, 소유 컬럼, 상태)
├─ README.md                   개요 + Mermaid ER 다이어그램 + 접근 규칙
└─ schema.draft.sql            테이블·RLS 초안 (스키마 nomad_<slug>)
```

## 규칙
1. 폴더명 = `blueprint.yaml`의 `slug`, 스키마는 `nomad_<slug>`(하이픈은 `_`).
2. 유형이 바뀌면 폴더를 이동(`git mv`)하고 `blueprint.yaml`·`registry.yaml`의 `type`을 수정한다.
3. 하나의 서비스가 여러 레포를 쓰면 `blueprint.yaml`의 `repos:`에 나열한다.
4. 보관 처리는 삭제하지 않고 `status: archived`로 표시한다.
5. 확정된 SQL은 청사진 폴더가 아니라 `supabase/migrations/`에 날짜 형식 파일로 둔다([migrations](migrations.md)).
