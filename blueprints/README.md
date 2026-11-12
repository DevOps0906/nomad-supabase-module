# 서비스별 DB 청사진 (blueprints)

이 모듈에 연결할 서비스들의 **DB 설계 초안**을 모아 둔 곳입니다. 정본은 `supabase/migrations/`이고,
여기 SQL은 확정 전 제안입니다. 모든 청사진은 공통 스키마 `nomad_core`를 기준으로 씁니다.

## 유형 (13개)

| 유형 | 개수 | 소유 컬럼 | 청사진 |
|---|---|---|---|
| 조직형 `org` | 7 | `organization_id` | contentflow, flora, knowflow, classroom, analytics, sceneflow, commerce |
| 개인형 `user` | 4 | `user_id` | humscore, jangter, baedal, personal |
| 격리형 `isolated` | 2 | 역할 / 기관 고정 (별도 Supabase 프로젝트) | hospital, school |

DB가 필요 없는 서비스는 이 모듈 대상이 아닙니다. 유형 고르는 법: [decision-flow](../docs/design/00-overview/decision-flow.md)

## 폴더

```
blueprints/
├─ registry.yaml            전체 목록 (생성기가 자동 추가)
├─ _templates/              생성기가 복사하는 뼈대 (직접 수정 금지)
└─ <org|user|isolated>/<slug>/
   ├─ blueprint.yaml        유형 · 스키마(nomad_<slug>) · 소유 컬럼 · 상태
   ├─ README.md             개요 + ER 다이어그램 + 접근 규칙
   └─ schema.draft.sql      테이블 · RLS 초안
```

## 추가 방법

```bash
bash scripts/new-blueprint.sh <org|user|isolated> <slug> "<표시 이름>"
bash scripts/validate-blueprints.sh
```

검증기는 RLS 활성, 조직형 `organization_id`, 참조 범위(`nomad_core`·`auth`·자기 스키마, 격리형은 `auth`·자기 스키마), registry 일치, 비밀값을 검사합니다.

## 확정 절차 (청사진 → 마이그레이션)

1. 서비스 범위가 확정되면 `schema.draft.sql`을 검토하고 `supabase/migrations/YYYYMMDDHHMMSS_<slug>.sql` 새 파일로 옮깁니다.
2. `nomad_core`에 없는 기능(가입 트리거·초대·크레딧 등)을 쓰면 먼저 [반영 후보](../docs/design/01-architecture/core-schema.md#3-반영-후보)를 별도 마이그레이션으로 추가합니다.
3. `tests/`에 접근 검증을 추가하고 `docs/diagrams/erd.mmd`를 갱신합니다.
4. `blueprint.yaml`·`registry.yaml`의 `status`를 갱신합니다.

## 읽는 순서

1. [principles](../docs/design/00-overview/principles.md) 원칙 8가지
2. [decision-flow](../docs/design/00-overview/decision-flow.md) 유형 선택
3. [core-schema](../docs/design/01-architecture/core-schema.md) 공통 계정 계층과 반영 후보
4. [rls-patterns](../docs/design/02-conventions/rls-patterns.md) · [naming](../docs/design/02-conventions/naming.md)
5. [new-project-checklist](../docs/design/02-conventions/new-project-checklist.md) 새 청사진 체크리스트
