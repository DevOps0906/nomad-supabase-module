# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 현재 작업: task-003 DB 설치기 — 상태: 완료(푸시됨). task-002 서비스 11개 마이그레이션 완료
- 마지막으로 한 일: scripts/install-db.sh + tests/install_db.sh(55/55), codex 리뷰 반영(임시 파일 후 mv), 설치 결과를 빈 스키마에 순서 적용 확인
- 다음 한 걸음: feat/db-installer → master PR, 이후 요금 플랜·기능 카탈로그 + has_feature 잠금(수치 확정 필요)
- 열린 결정: 요금 플랜 수치(billing-credits 미확정), 규칙3 보류 컬럼(주석 없는 status) 값 목록
- 확정 결정(2026-11-13): 제품 잠금 없이 멤버십·역할만 · 장터/배달 두 당사자 설계 · 서비스 스키마 API 비노출 · 격리형 2개 제외
- 주의: 다른 로컬 Supabase 프로젝트가 543xx·553xx 등 포트를 씀 → 이 저장소는 581xx. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- SDLC 단계: 06 구현
- 담당 모델/역할: 팀장 Opus 5.5 · builder ×3 · tester
- 수정 파일: scripts/install-db.sh, tests/install_db.sh, docs/INTEGRATION.md, README.md, AGENTS.md, tasks/task-003-db-installer.md
- 테스트 상태: tenant_access·accounts·services_access·install_db 모두 통과
- 남은 작업: PR, 격리형 2개(별도 프로젝트), 플랜·기능 카탈로그, 보류 컬럼 정리
