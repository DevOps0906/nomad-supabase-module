# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 현재 작업: task-004 요금 플랜·기능 잠금 — 상태: 완료(푸시). PR #1에 포함
- 마지막으로 한 일: 기능 카탈로그 확정, 구독 없음=C, B·A 테이블 쓰기 잠금, 개인형 user_has_feature(owner 조직), 서버용 org_has_feature
- 다음 한 걸음: PR #1 검토·머지. 후속 후보: 수량 한도, knowflow 대화 크레딧 차감 연결, 보류 status 값 목록
- 열린 결정: 가격·좌석 수치(billing-credits), 수량 한도 필요 여부
- 확정 결정(2026-11-13): 제품 잠금 없이 멤버십·역할만 · 장터/배달 두 당사자 설계 · 서비스 스키마 API 비노출 · 격리형 2개 제외
- 주의: 다른 로컬 Supabase 프로젝트가 543xx·553xx 등 포트를 씀 → 이 저장소는 581xx. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- SDLC 단계: 06 구현
- 담당 모델/역할: 팀장 Opus 5.5 · builder ×3 · tester
- 수정 파일: supabase/migrations/20261116000100~111, tests/feature_gating.sql·services_access.sql·install_db.sh, docs/INTEGRATION.md, docs/design/01-architecture/feature-catalog.md, AGENTS.md
- 테스트 상태: tenant_access·accounts·services_access·feature_gating·install_db(61) 모두 통과
- 남은 작업: PR 머지, 격리형 2개(별도 프로젝트), 수량 한도·크레딧 연결, 보류 컬럼 정리
