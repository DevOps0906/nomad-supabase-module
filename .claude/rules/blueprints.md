---
paths:
  - "blueprints/**"
---
# 청사진 영역 규칙 (blueprints/** 작업 때만 로드)
- 새 청사진은 `scripts/new-blueprint.sh`로 만들고 `blueprints/<org|user|isolated>/<slug>/` 밖에 두지 않는다. 변경 후 `bash scripts/validate-blueprints.sh` 통과.
- 서비스 스키마(`nomad_<slug>`)끼리 외래키·조인 금지. 참조는 `nomad_core`·`auth`만(격리형은 `auth`만).
- 조직형 테이블은 `organization_id uuid not null references nomad_core.organizations(id)`, 개인형은 소유자 컬럼(`user_id`)을 가진다.
- 격리형(병원·학교)은 설계 문서만 둔다. 실제 개인정보·접속정보는 커밋하지 않는다.
- 청사진은 초안이다. `nomad_core` 컬럼 의미를 바꾸지 않고, 확정 SQL은 `supabase/migrations/` 새 날짜 파일로 옮긴다.
- 요금 수치는 `docs/design/01-architecture/billing-credits.md` 기준. 청사진 추가·유형 변경 시 `registry.yaml`도 갱신.
