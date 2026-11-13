# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 브랜치: feat/task-005-status-values (master에서 chore/tasks-sync 위에 분기, 미푸시)
- 현재 작업: task-009 platform-docs 코어·제품 16개 대응표 — 단계: 기획(planner 작성 중) → docs/design/03-port/platform-docs-mapping.md
- 마지막으로 한 일: task-005 완료·커밋(c7153ba, 테스트 5종 통과, code·contract ACCEPT). task-008 병원 보류(사람 결정 4개), school은 조직형으로 이식 대상 전환
- 다음 한 걸음: 대응표 검토 → 사용자 결정 → task-006(수량 한도, 저쪽 설계 반영) + 제품 이식 웨이브 병렬
- 사용자 지시(2026-11-13): 005 끝나면 006 이어서 · platform-docs(github.com/DevOps0906/platform-docs, 로컬 D:\WorkSpace\DEV\platform-docs) 제품 16개를 이 저장소로 이식(nomad_core 정본), 가능하면 병렬 · 병원만 격리
- 열린 결정: 가격·좌석 수치(billing-credits), 병원 앱 접근 경로·검색 해시·admin 부트스트랩·보존 기간
- 확정 결정: 제품 잠금 없이 멤버십·역할만 · 장터/배달 두 당사자 · 서비스 스키마 API 비노출 · 기존 데이터 백필 금지(위반 시 중단)
- 주의: 이 저장소 로컬 포트 581xx. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- SDLC 단계: 06 구현(005 완료) / 02 기획(009)
- 테스트 상태: tenant_access·accounts·services_access·feature_gating·install_db 통과(c7153ba)
- 남은 작업: 009 → 006 → 이식 웨이브, 007, 008(보류)
