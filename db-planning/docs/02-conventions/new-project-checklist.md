# 새 프로젝트 체크리스트

## A. 시작 전 (린 검증)
- [ ] DB가 정말 필요한가? (노코드·로컬·파일로 검증 가능한가)
- [ ] 랜딩페이지/사전예약으로 수요 확인했는가
- [ ] 정부지원사업·바우처 활용 가능한 항목인가

## B. 유형 결정
- [ ] `docs/00-overview/decision-flow.md`로 유형 결정
- [ ] 유형: org / user / isolated / local

## C. 생성
- [ ] `./scripts/new-project.sh <유형> <slug> "<이름>"`
- [ ] `project.yaml` 채우기 (owner_column, public_read, sensitive 등)
- [ ] README의 ER 다이어그램 수정
- [ ] `schema.draft.sql` 검토

## D. 보안
- [ ] 모든 테이블 RLS 활성
- [ ] 서비스 스키마 간 FK 없음
- [ ] 민감 컬럼 암호화 / 감사 로그 (격리형)
- [ ] 비밀값 커밋 없음

## E. 마무리
- [ ] `./scripts/validate.sh` 통과
- [ ] `registry/projects.yaml` 확인
- [ ] `CHANGELOG.md` 기록
