# NOW — 재진입 스냅샷 (30줄 이내, 매 작업 끝에 덮어쓴다)

- 갱신: 2026-11-13
- 브랜치: feat/task-005-status-values (미푸시)
- 현재 작업: 013 번들 리뷰 지적 수정 완료 → 번들 재빌드·tests/bundles.sh 재실행 중(C1 포함) → 통과 시 013 커밋
- 마지막으로 한 일: 010 2단계 SQL 카드 뷰(f3335eb) · 015 P1(0cec74e) · 014 C3 rate limit(d108104) · 014 C1 크레딧(6595ecf)
- 다음 한 걸음: 013 커밋 → 014 2단계 C2 jobs(`…000400`, credit_ledger_id·refund_credits 사용) → 3단계 C5‖C6‖C7 → P1 0002_ai 확정 → P2~P4
- 사용자 지시(2026-11-13): platform-docs 제품 16개를 nomad_core 정본으로 이식, 가능하면 병렬, 병원만 격리 · 대시보드 core SQL 카드 뷰(완료)
- 열린 결정: 가격·좌석 수치, 병원 4건, D7·D10, erp 기능 이용권 연결(export_xlsx와 함께), floria 제품 rate·audit → core 함수 전환 여부, ai_chat·voice 키, poll 입장 한도 300/10분
- 팀장 결정(사용자 확인 대기): 새 기간 지급 전 남은 plan 만료, 만료 기간 plan 차감 환불은 0(pack만), 기간 키는 정렬 가능 형식
- 확정 결정: 제품 잠금 없이 멤버십·역할만 · 장터/배달 두 당사자 · 제품 스키마 API 노출(nomad_core 비노출) · 백필 금지
- 주의: 로컬 포트 581xx, 대시보드 `DASHBOARD_PORT=8766 docker compose up -d --build`(8765는 다른 프로세스 사용). psql은 `docker exec -i supabase_db_nomad-supabase-module psql -U postgres`
- SDLC 단계: 06 구현(013·014·015), 대시보드 http://127.0.0.1:8766
- 테스트 상태: tests 8종 + install_db 68/68 + P1 run_check 4종 통과(6595ecf)
- 남은 작업: 014 C2·C5·C6·C7, 015 P2~P4, 007, 008(보류), 발견한 문제(erp request_join 제한 등)
