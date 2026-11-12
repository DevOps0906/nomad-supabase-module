# 새 청사진 체크리스트

## A. 시작 전 (린 검증)
- [ ] DB가 정말 필요한가? (DB 없는 서비스는 이 모듈 대상 아님)
- [ ] 랜딩페이지/사전예약으로 수요 확인했는가
- [ ] 정부지원사업·바우처 활용 가능한 항목인가

## B. 유형 결정
- [ ] [decision-flow](../00-overview/decision-flow.md)로 유형 결정: org / user / isolated

## C. 생성
- [ ] `bash scripts/new-blueprint.sh <org|user|isolated> <slug> "<이름>"`
  - `blueprints/<유형>/<slug>/`에 `blueprint.yaml`·`README.md`·`schema.draft.sql` 생성, `blueprints/registry.yaml`에 항목 추가
- [ ] `blueprint.yaml` 채우기 (tables, repos, sensitive 등)
- [ ] README의 ER 다이어그램 수정
- [ ] `schema.draft.sql` 검토 (스키마 `nomad_<slug>`, 조직형은 `organization_id`)

## D. 보안
- [ ] 모든 테이블 RLS 활성
- [ ] 참조는 `nomad_core`·`auth`·자기 스키마만
- [ ] 민감 컬럼 암호화 / 감사 로그 (격리형)
- [ ] 비밀값 커밋 없음

## E. 마무리
- [ ] `bash scripts/validate-blueprints.sh` 통과
- [ ] 확정 시 [migrations](migrations.md) 절차로 `supabase/migrations/`에 옮김
