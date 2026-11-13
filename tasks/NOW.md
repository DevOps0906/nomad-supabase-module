# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 브랜치: feat/task-005-status-values (master에서 chore/tasks-sync 위에 분기, 미푸시)
- 현재 작업: task-006 플랜별 수량 한도 구조 — 단계: 계획 공격(challenger) → builder
- 마지막으로 한 일: task-009 대응표 완료(9fe1367), 결정 D1 계약만·D2 버킷 분리·D3 정규화(B)·D6 AI 코어 이식. tasks/task-006-plan-limits.md 작성
- 다음 한 걸음: challenger 반영 → builder 구현 → codex-reviewer(code)+reviewer(security) → 커밋. 이후 C1(크레딧 버킷)·C4 병렬
- 사용자 지시(2026-11-13): 005 끝나면 006 이어서 · platform-docs(github.com/DevOps0906/platform-docs, 로컬 D:\WorkSpace\DEV\platform-docs) 제품 16개를 이 저장소로 이식(nomad_core 정본), 가능하면 병렬 · 병원만 격리
- 열린 결정: 가격·좌석 수치, 병원 4건, 대응표 D4·D5·D7~D11
- 확정 결정: 제품 잠금 없이 멤버십·역할만 · 장터/배달 두 당사자 · 서비스 스키마 API 비노출 · 기존 데이터 백필 금지(위반 시 중단)
- 주의: 이 저장소 로컬 포트 581xx. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- SDLC 단계: 06 구현(006)
- 테스트 상태: tenant_access·accounts·services_access·feature_gating·install_db 통과(c7153ba)
- 남은 작업: 006 → 010(스키마 대시보드, 사용자 요청 2026-11-13) → C1~C7 → P1~P4 이식 웨이브, 007, 008(보류)
