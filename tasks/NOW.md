# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 브랜치: feat/task-005-status-values (master에서 chore/tasks-sync 위에 분기, 미푸시)
- 현재 작업: 최우선 5개 제품 DB(계획 ~/.claude/plans/transient-singing-eich.md) — task-011 challenger 중, task-012 builder 5개 병렬(products/<slug>/)
- 마지막으로 한 일: task-006 완료(3396e7f). 5개 레포 조사 docs/design/04-products/survey-*.md. 결정: 실제 레포 기준·제품 스키마 API 노출·테넌트안 org·소셜 로그인·BYOK(Vault)
- 다음 한 걸음: task-010 대시보드 디자인(designer)+Docker(builder) → 사용자 확인 / task-011·012 리뷰·커밋 → task-013 번들
- 사용자 지시(2026-11-13): 005 끝나면 006 이어서 · platform-docs(github.com/DevOps0906/platform-docs, 로컬 D:\WorkSpace\DEV\platform-docs) 제품 16개를 이 저장소로 이식(nomad_core 정본), 가능하면 병렬 · 병원만 격리
- 열린 결정: 가격·좌석 수치, 병원 4건, 대응표 D4·D5·D7~D11
- 확정 결정: 제품 잠금 없이 멤버십·역할만 · 장터/배달 두 당사자 · 제품 스키마 API 노출(nomad_core는 비노출, 2026-11-13 변경) · 기존 데이터 백필 금지(위반 시 중단)
- 주의: 이 저장소 로컬 포트 581xx. psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- SDLC 단계: 06 구현(011·012)
- 테스트 상태: 기존 5종 + install_db 통과(3396e7f)
- 남은 작업: 011·012 → 013 → 010 대시보드 → C1~C7 → P1~P4 이식 웨이브, 007, 008(보류)
