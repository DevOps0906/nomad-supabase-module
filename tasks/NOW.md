# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 현재 작업: 없음 — PR #1(task-001~004) master에 머지 완료
- 마지막으로 한 일: PR #1 머지, 작업 표를 실제 이력으로 정리하고 후속 후보 task-005~007 등록
- 다음 한 걸음: task-005(보류 status 값 정리)부터. 작업 파일(`tasks/task-005-*.md`)은 아직 없음 → 착수 시 근거·하지 않을 것부터 작성
- 열린 결정: 가격·좌석 수치(billing-credits) → task-006 수치 의존, 수량 한도 필요 여부
- 확정 결정(2026-11-13): 제품 잠금 없이 멤버십·역할만 · 장터/배달 두 당사자 설계 · 서비스 스키마 API 비노출 · 격리형 2개 제외(별도 프로젝트)
- 주의: 다른 로컬 Supabase 프로젝트가 543xx·553xx 등 포트를 씀 → 이 저장소는 581xx. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- SDLC 단계: 06 구현 (W2 대기)
- 테스트 상태: tenant_access·accounts·services_access·feature_gating·install_db(61) 모두 통과(머지 시점)
- 남은 작업: task-005~007, 격리형 2개(별도 프로젝트)
